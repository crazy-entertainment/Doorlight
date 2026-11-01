import 'dart:convert';

import 'rich_content.dart';

final class GifLibraryEntry {
  const GifLibraryEntry({
    required this.hash,
    required this.bytes,
    required this.media,
  });
  final String hash;
  final int bytes;
  final GifMediaContent media;

  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  String get fileName => '$hash.gif';
  Map<String, Object> toMap() => {
    'hash': hash,
    'bytes': bytes,
    'media': media.encode(),
  };

  static GifLibraryEntry? parse(Object? value) {
    if (value is! Map || value.length != 3) return null;
    final hash = value['hash'];
    final bytes = value['bytes'];
    final media = FileMediaContent.parse(value['media']);
    if (hash is! String ||
        !_hashPattern.hasMatch(hash) ||
        bytes is! int ||
        bytes < 1 ||
        bytes > 4 * 1024 * 1024 ||
        media is! GifMediaContent) {
      return null;
    }
    return GifLibraryEntry(hash: hash, bytes: bytes, media: media);
  }
}

/// Only local imported GIFs: this index has no account, conversation or message
/// data. Storage must validate the referenced bytes before exposing an entry.
final class GifLibraryIndex {
  GifLibraryIndex._(Map<String, GifLibraryEntry> entries)
    : entries = Map.unmodifiable(entries);
  factory GifLibraryIndex.empty() => GifLibraryIndex._({});

  static const maximumEntries = 32;
  static const maximumBytes = 64 * 1024 * 1024;
  static const maximumIndexBytes = 32 * 1024;
  final Map<String, GifLibraryEntry> entries;
  int get totalBytes =>
      entries.values.fold(0, (total, entry) => total + entry.bytes);

  /// Duplicate imports preserve the existing entry and cannot refresh or
  /// replace its content. Capacity is refused; nothing is silently evicted.
  GifLibraryIndex? add(GifLibraryEntry entry) {
    if (GifLibraryEntry.parse(entry.toMap()) == null) return null;
    final existing = entries[entry.hash];
    if (existing != null) {
      return existing.bytes == entry.bytes &&
              existing.media.encode() == entry.media.encode()
          ? this
          : null;
    }
    if (entries.length >= maximumEntries ||
        totalBytes + entry.bytes > maximumBytes) {
      return null;
    }
    return GifLibraryIndex._({...entries, entry.hash: entry});
  }

  GifLibraryIndex remove(String hash) {
    final next = Map<String, GifLibraryEntry>.of(entries)..remove(hash);
    return GifLibraryIndex._(next);
  }

  String encode() => jsonEncode({
    'v': 1,
    'entries': entries.values.map((entry) => entry.toMap()).toList(),
  });

  static GifLibraryIndex? parse(String source) {
    if (source.length > maximumIndexBytes ||
        utf8.encode(source).length > maximumIndexBytes) {
      return null;
    }
    try {
      final value = jsonDecode(source);
      if (value is! Map ||
          value.length != 2 ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['entries'] is! List) {
        return null;
      }
      final raw = value['entries'] as List;
      if (raw.length > maximumEntries) return null;
      var result = GifLibraryIndex.empty();
      for (final item in raw) {
        final entry = GifLibraryEntry.parse(item);
        if (entry == null || result.entries.containsKey(entry.hash)) {
          return null;
        }
        final next = result.add(entry);
        if (next == null) return null;
        result = next;
      }
      return result;
    } on FormatException {
      return null;
    }
  }
}
