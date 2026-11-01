import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// One read-only message line kept after a friend removed you.
final class ArchivedChatItem {
  const ArchivedChatItem({
    required this.mine,
    required this.at,
    required this.topic,
    this.text,
    this.stickerId,
    this.fileName,
    this.fileSize,
    this.fileDownloaded = false,
  });

  final bool mine;
  final DateTime at;
  final String topic;
  final String? text;
  final String? stickerId;
  final String? fileName;
  final int? fileSize;
  final bool fileDownloaded;

  Map<String, Object?> toJson() => {
    'mine': mine,
    'at': at.millisecondsSinceEpoch,
    'topic': topic,
    if (text != null) 'text': text,
    if (stickerId != null) 'stickerId': stickerId,
    if (fileName != null)
      'file': {
        'name': fileName,
        if (fileSize != null) 'size': fileSize,
        'downloaded': fileDownloaded,
      },
  };

  static ArchivedChatItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final mine = value['mine'];
    final at = value['at'];
    final topic = value['topic'];
    final text = value['text'];
    final sticker = value['stickerId'];
    final file = value['file'];
    if (mine is! bool || at is! int || topic is! String) return null;
    if (text != null && text is! String) return null;
    if (sticker != null && sticker is! String) return null;
    String? fileName;
    int? fileSize;
    var downloaded = false;
    if (file != null) {
      if (file is! Map ||
          file['name'] is! String ||
          (file['size'] != null && file['size'] is! int) ||
          file['downloaded'] is! bool) {
        return null;
      }
      fileName = file['name'] as String;
      fileSize = file['size'] as int?;
      downloaded = file['downloaded'] as bool;
    }
    if ((text == null ? 0 : 1) +
            (sticker == null ? 0 : 1) +
            (fileName == null ? 0 : 1) !=
        1) {
      return null;
    }
    return ArchivedChatItem(
      mine: mine,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      topic: topic,
      text: text as String?,
      stickerId: sticker as String?,
      fileName: fileName,
      fileSize: fileSize,
      fileDownloaded: downloaded,
    );
  }
}

final class ArchivedChat {
  const ArchivedChat({
    required this.peerLabel,
    required this.archivedAt,
    required this.topics,
    required this.items,
  });

  final String peerLabel;
  final DateTime archivedAt;
  final Map<String, String> topics;
  final List<ArchivedChatItem> items;

  String encode() => jsonEncode({
    'v': 1,
    'peerLabel': peerLabel,
    'archivedAt': archivedAt.millisecondsSinceEpoch,
    'topics': topics,
    'items': [for (final item in items) item.toJson()],
  });

  static ArchivedChat? parse(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map ||
          decoded['v'] != 1 ||
          decoded['peerLabel'] is! String ||
          decoded['archivedAt'] is! int ||
          decoded['topics'] is! Map ||
          decoded['items'] is! List) {
        return null;
      }
      final topics = <String, String>{};
      for (final entry in (decoded['topics'] as Map).entries) {
        if (entry.key is! String || entry.value is! String) return null;
        topics[entry.key as String] = entry.value as String;
      }
      final raw = decoded['items'] as List;
      if (raw.length > ChatArchiveStore.maximumItems) return null;
      final items = <ArchivedChatItem>[];
      for (final value in raw) {
        final item = ArchivedChatItem.fromJson(value);
        if (item == null) return null;
        items.add(item);
      }
      return ArchivedChat(
        peerLabel: decoded['peerLabel'] as String,
        archivedAt: DateTime.fromMillisecondsSinceEpoch(
          decoded['archivedAt'] as int,
          isUtc: true,
        ),
        topics: Map.unmodifiable(topics),
        items: List.unmodifiable(items),
      );
    } catch (_) {
      return null;
    }
  }
}

/// One stored archive. [chat] is null when the file is unreadable.
typedef ArchivedChatEntry = ({String id, ArchivedChat? chat});

enum ChatArchiveWriteResult { saved, tooLarge, full, unavailable }

/// Read-only chat snapshots kept by an explicit owner decision outside the
/// daemon history: private app storage, excluded from identity backup, wiped
/// on reset. Mutations are serialized; a file becomes visible only by rename.
final class ChatArchiveStore {
  ChatArchiveStore(this.directory);

  static const maximumItems = 10000;
  static const maximumBytes = 4 * 1024 * 1024;
  static const maximumArchives = 32;
  static final RegExp _accountId = RegExp(r'^[A-Za-z0-9]{1,64}$');
  static final RegExp _archiveLeaf = RegExp(r'^[0-9a-f]{64}\.json$');

  final Future<Directory?> Function() directory;
  Future<void> _tail = Future<void>.value();

  static String idFor(String peerId) =>
      sha256.convert(utf8.encode(peerId)).toString();

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Directory?> _accountRoot(String accountId, {bool create = false}) async {
    if (!_accountId.hasMatch(accountId)) return null;
    final root = await directory();
    if (root == null) return null;
    final account = Directory(
      '${root.path}${Platform.pathSeparator}$accountId',
    );
    final type = await FileSystemEntity.type(account.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      await account.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      return null;
    }
    return account;
  }

  File _file(Directory root, String id) =>
      File('${root.path}${Platform.pathSeparator}$id.json');

  Future<ChatArchiveWriteResult> write(
    String accountId,
    String peerId,
    ArchivedChat chat,
  ) => _serial(() async {
    if (chat.items.length > maximumItems) return ChatArchiveWriteResult.tooLarge;
    final text = chat.encode();
    if (utf8.encode(text).length > maximumBytes) {
      return ChatArchiveWriteResult.tooLarge;
    }
    try {
      final root = await _accountRoot(accountId, create: true);
      if (root == null) return ChatArchiveWriteResult.unavailable;
      final id = idFor(peerId);
      final destination = _file(root, id);
      final exists =
          await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (!exists && (await _ids(root)).length >= maximumArchives) {
        return ChatArchiveWriteResult.full;
      }
      final transaction = await root.createTemp('write-');
      final temporary = File(
        '${transaction.path}${Platform.pathSeparator}$id.json',
      );
      try {
        await temporary.writeAsString(text, flush: true);
        await temporary.rename(destination.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
        await transaction.delete();
      }
      return ChatArchiveWriteResult.saved;
    } catch (_) {
      return ChatArchiveWriteResult.unavailable;
    }
  });

  Future<List<String>> _ids(Directory root) async {
    final ids = <String>[];
    await for (final item in root.list(followLinks: false)) {
      final leaf = item.path.split(Platform.pathSeparator).last;
      if (item is File && _archiveLeaf.hasMatch(leaf)) {
        ids.add(leaf.substring(0, 64));
      }
    }
    return ids;
  }

  Future<ArchivedChat?> _read(Directory root, String id) async {
    final file = _file(root, id);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > maximumBytes) {
      return null;
    }
    return ArchivedChat.parse(await file.readAsString());
  }

  /// Newest first. Unreadable files are listed with a null chat.
  Future<List<ArchivedChatEntry>?> list(String accountId) => _serial(() async {
    try {
      final root = await _accountRoot(accountId);
      if (root == null) return const <ArchivedChatEntry>[];
      final entries = <ArchivedChatEntry>[];
      for (final id in await _ids(root)) {
        ArchivedChat? chat;
        try {
          chat = await _read(root, id);
        } catch (_) {
          chat = null;
        }
        entries.add((id: id, chat: chat));
      }
      entries.sort((left, right) {
        final l = left.chat?.archivedAt.millisecondsSinceEpoch ?? 0;
        final r = right.chat?.archivedAt.millisecondsSinceEpoch ?? 0;
        return r != l ? r.compareTo(l) : left.id.compareTo(right.id);
      });
      return entries;
    } catch (_) {
      return null;
    }
  });

  Future<bool> delete(String accountId, String id) => _serial(() async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) return false;
    try {
      final root = await _accountRoot(accountId);
      if (root == null) return true;
      final file = _file(root, id);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await file.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  });

  /// Removes every archive of [accountId]. True when nothing remains.
  Future<bool> deleteAccount(String accountId) => _serial(() async {
    try {
      final root = await _accountRoot(accountId);
      if (root == null) return _accountId.hasMatch(accountId);
      await root.delete(recursive: true);
      return !await root.exists();
    } catch (_) {
      return false;
    }
  });
}
