import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'gif_library.dart';
import 'gif_recents.dart';
import 'gif_validation.dart';
import 'rich_content.dart';

enum GifLibraryResult {
  saved,
  alreadyBundled,
  removed,
  invalid,
  full,
  unavailable,
  stale,
}

/// Private media only, outside the identity archive. Mutations are serialized;
/// the index is published after bytes, and removal unlinks only after indexing.
final class GifLibraryStore {
  GifLibraryStore(this.directory);
  final Future<Directory?> Function() directory;
  Future<void> _tail = Future<void>.value();
  GifLibraryIndex _index = GifLibraryIndex.empty();
  GifLibraryIndex get index => _index;
  GifRecents _recents = GifRecents.empty();
  GifRecents get recents => _recents;
  bool _recentsWritable = true;
  bool _available = false;
  bool get available => _available;
  String? _directoryPath;
  String? pathFor(String hash) => _available && _index.entries.containsKey(hash)
      ? '$_directoryPath${Platform.pathSeparator}$hash.gif'
      : null;

  Future<bool> matchesCopy(String hash, String path) async {
    if (!_available || !_index.entries.containsKey(hash)) return false;
    try {
      final bytes = await _read(File(path), ValidatedGif.maximumBytes);
      return bytes != null && sha256.convert(bytes).toString() == hash;
    } catch (_) {
      return false;
    }
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Directory?> _root() async {
    final root = await directory();
    if (root == null) return null;
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
    }
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    _directoryPath = root.path;
    return root;
  }

  File _file(Directory root, String leaf) =>
      File('${root.path}${Platform.pathSeparator}$leaf');

  Future<Uint8List?> _read(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final handle = await file.open();
    try {
      final length = await handle.length();
      if (length < 1 || length > limit) return null;
      final bytes = await handle.read(length);
      return bytes.length == length && await handle.length() == length
          ? bytes
          : null;
    } finally {
      await handle.close();
    }
  }

  Future<bool> reload() => _serial(_reload);

  Future<bool> _reload() async {
    _available = false;
    _index = GifLibraryIndex.empty();
    try {
      final root = await _root();
      if (root == null) return false;
      _recents = GifRecents.empty();
      final recentFile = _file(root, 'recent.json');
      final recentType = await FileSystemEntity.type(
        recentFile.path,
        followLinks: false,
      );
      final recentBytes = await _read(recentFile, GifRecents.maximumBytes);
      final recent = recentBytes == null
          ? null
          : GifRecents.parse(String.fromCharCodes(recentBytes));
      _recentsWritable =
          recentType == FileSystemEntityType.notFound || recent != null;
      if (recent != null) _recents = recent;
      final file = _file(root, 'index.json');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        // A missing index with existing media is interrupted/corrupt storage,
        // not an empty library whose byte limit may be reset.
        if (await root.list(followLinks: false).isEmpty) {
          await _publish(root, _index);
          _available = true;
          return true;
        }
        return false;
      }
      final bytes = await _read(file, GifLibraryIndex.maximumIndexBytes);
      if (bytes == null) return false;
      final parsed = GifLibraryIndex.parse(String.fromCharCodes(bytes));
      if (parsed == null) return false;
      for (final entry in parsed.entries.values) {
        if (await _validatedBytes(root, entry) == null) return false;
      }
      // These are unpublished copies from an interrupted import, or bytes
      // whose explicit removal committed before the process stopped.
      await for (final item in root.list(followLinks: false)) {
        final leaf = item.path.split(Platform.pathSeparator).last;
        if (RegExp(r'^[0-9a-f]{64}\.gif$').hasMatch(leaf) &&
            !parsed.entries.containsKey(leaf.substring(0, 64))) {
          if (item is! File) return false;
          await item.delete();
        }
      }
      _index = parsed;
      _available = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> _validatedBytes(
    Directory root,
    GifLibraryEntry entry,
  ) async {
    final bytes = await _read(
      _file(root, entry.fileName),
      ValidatedGif.maximumBytes,
    );
    if (bytes == null ||
        bytes.length != entry.bytes ||
        sha256.convert(bytes).toString() != entry.hash) {
      return null;
    }
    final gif = await validateGifDecode(bytes);
    if (gif == null) return null;
    final decodedMedia = GifMediaContent(
      gif.width,
      gif.height,
      gif.frames,
      gif.cycleMilliseconds,
    );
    if (decodedMedia.encode() != entry.media.encode()) return null;
    return bytes;
  }

  Future<Uint8List?> read(String hash) => _serial(() async {
    if (!await _reload()) return null;
    final entry = _index.entries[hash];
    if (entry == null) return null;
    try {
      final root = await _root();
      return root == null ? null : await _validatedBytes(root, entry);
    } catch (_) {
      return null;
    }
  });

  Future<bool> _publish(
    Directory root,
    GifLibraryIndex next, {
    bool Function()? isCurrent,
  }) => _publishText(root, 'index.json', next.encode(), isCurrent: isCurrent);

  Future<bool> _publishText(
    Directory root,
    String leaf,
    String text, {
    bool Function()? isCurrent,
  }) async {
    // An unpredictable transaction directory prevents an old partial write or
    // link from becoming the next index. Rename is the visibility boundary.
    final transaction = await root.createTemp('index-');
    final temporary = _file(transaction, leaf);
    try {
      await temporary.writeAsString(text, flush: true);
      if (isCurrent != null && !isCurrent()) return false;
      await temporary.rename(_file(root, leaf).path);
      return true;
    } finally {
      if (await temporary.exists()) await temporary.delete();
      await transaction.delete();
    }
  }

  Future<bool> recordUsed(String hash) => _serial(() async {
    try {
      if (!await _reload() || !_recentsWritable) return false;
      final next = _recents.use(hash);
      final root = await _root();
      if (next == null || root == null) return false;
      await _publishText(root, 'recent.json', next.encode());
      _recents = next;
      return true;
    } catch (_) {
      return false;
    }
  });

  Future<GifLibraryResult> import(
    String sourcePath, {
    bool Function()? isCurrent,
    Future<bool> Function(GifLibraryEntry entry)? authorize,
    Set<String> bundledHashes = const {},
  }) => _serial(() async {
    try {
      if (isCurrent != null && !isCurrent()) return GifLibraryResult.stale;
      if (!await _reload()) return GifLibraryResult.unavailable;
      final root = await _root();
      if (root == null) return GifLibraryResult.unavailable;
      final bytes = await _read(File(sourcePath), ValidatedGif.maximumBytes);
      if (bytes == null) return GifLibraryResult.invalid;
      final gif = await validateGifDecode(bytes);
      if (gif == null) return GifLibraryResult.invalid;
      final entry = GifLibraryEntry(
        hash: sha256.convert(bytes).toString(),
        bytes: bytes.length,
        media: GifMediaContent(
          gif.width,
          gif.height,
          gif.frames,
          gif.cycleMilliseconds,
        ),
      );
      if (authorize != null && !await authorize(entry)) {
        return GifLibraryResult.invalid;
      }
      if (isCurrent != null && !isCurrent()) return GifLibraryResult.stale;
      if (bundledHashes.contains(entry.hash)) {
        return GifLibraryResult.alreadyBundled;
      }
      final next = _index.add(entry);
      if (next == null) return GifLibraryResult.full;
      if (identical(next, _index)) return GifLibraryResult.saved;
      // Account for interrupted imports/removals before accepting more bytes.
      var physicalBytes = 0;
      var physicalEntries = 0;
      await for (final item in root.list(followLinks: false)) {
        final leaf = item.path.split(Platform.pathSeparator).last;
        if (!RegExp(r'^[0-9a-f]{64}\.gif$').hasMatch(leaf)) continue;
        if (item is! File) return GifLibraryResult.unavailable;
        physicalBytes += await item.length();
        physicalEntries++;
      }
      final destination = _file(root, entry.fileName);
      final exists =
          await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (!exists &&
          (physicalEntries >= GifLibraryIndex.maximumEntries ||
              physicalBytes + bytes.length > GifLibraryIndex.maximumBytes)) {
        return GifLibraryResult.full;
      }
      if (exists) {
        if (await _validatedBytes(root, entry) == null) {
          return GifLibraryResult.unavailable;
        }
      } else {
        await destination.create(exclusive: true);
        await destination.writeAsBytes(bytes, flush: true);
      }
      if (authorize != null && !await authorize(entry)) {
        return GifLibraryResult.invalid;
      }
      if (!await _publish(root, next, isCurrent: isCurrent)) {
        return GifLibraryResult.stale;
      }
      _index = next;
      return GifLibraryResult.saved;
    } catch (_) {
      _available = false;
      return GifLibraryResult.unavailable;
    }
  });

  Future<GifLibraryResult> remove(String hash) => _serial(() async {
    try {
      if (!await _reload()) return GifLibraryResult.unavailable;
      final entry = _index.entries[hash];
      if (entry == null) return GifLibraryResult.invalid;
      final root = await _root();
      if (root == null) return GifLibraryResult.unavailable;
      final next = _index.remove(hash);
      await _publish(root, next);
      _index = next;
      await _file(root, entry.fileName).delete();
      return GifLibraryResult.removed;
    } catch (_) {
      _available = false;
      return GifLibraryResult.unavailable;
    }
  });
}
