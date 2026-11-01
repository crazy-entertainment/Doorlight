import 'dart:convert';

/// Bounded, derived ordering only: no account, conversation, path or message IDs.
final class GifRecents {
  GifRecents._(Iterable<String> hashes) : hashes = List.unmodifiable(hashes);
  factory GifRecents.empty() => GifRecents._(const []);
  static const maximumEntries = 12;
  static const maximumBytes = 1024;
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  final List<String> hashes;

  GifRecents? use(String hash) => !_hash.hasMatch(hash)
      ? null
      : GifRecents._(
          [
            hash,
            ...hashes.where((value) => value != hash),
          ].take(maximumEntries),
        );

  List<T> order<T>(Iterable<T> entries, String Function(T) hashOf) {
    final remaining = {for (final entry in entries) hashOf(entry): entry};
    final result = <T>[];
    for (final hash in hashes) {
      final entry = remaining.remove(hash);
      if (entry != null) result.add(entry);
    }
    return [...result, ...remaining.values];
  }

  String encode() => jsonEncode({'v': 1, 'hashes': hashes});
  static GifRecents? parse(String text) {
    if (utf8.encode(text).length > maximumBytes) return null;
    try {
      final value = jsonDecode(text);
      if (value is! Map ||
          value.length != 2 ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['hashes'] is! List) {
        return null;
      }
      final raw = value['hashes'] as List;
      if (raw.length > maximumEntries) return null;
      final hashes = <String>{};
      for (final hash in raw) {
        if (hash is! String || !_hash.hasMatch(hash) || !hashes.add(hash)) {
          return null;
        }
      }
      return GifRecents._(hashes);
    } catch (_) {
      return null;
    }
  }
}
