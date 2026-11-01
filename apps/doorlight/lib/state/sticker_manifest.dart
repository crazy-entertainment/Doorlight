import 'dart:convert';

final class BuiltInSticker {
  const BuiltInSticker({
    required this.id,
    required this.path,
    required this.mime,
    required this.width,
    required this.height,
    required this.encodedBytes,
    required this.sha256,
    required this.label,
    required this.hologramEligible,
  });

  final String id;
  final String path;
  final String mime;
  final int width;
  final int height;
  final int encodedBytes;
  final String sha256;
  final String label;
  final bool hologramEligible;
  int get frames => 1;
}

final class StickerManifest {
  StickerManifest._(List<BuiltInSticker> entries)
    : entries = List.unmodifiable(entries);
  final List<BuiltInSticker> entries;
  static const assetPath = 'assets/stickers/manifest.json';
  static const maximumBytes = 64 * 1024;
  static const maximumEntries = 128;
  static final _id = RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)*$');
  static final _path = RegExp(
    r'^assets/stickers/(?:[a-z0-9_]+/)*[a-z0-9_]+\.(?:png|webp)$',
  );
  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  BuiltInSticker? byId(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  static StickerManifest? parse(String source) {
    if (source.length > maximumBytes ||
        utf8.encode(source).length > maximumBytes) {
      return null;
    }
    try {
      final value = jsonDecode(source);
      if (value is! Map ||
          value.length != 2 ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['stickers'] is! List) {
        return null;
      }
      final raw = value['stickers'] as List;
      if (raw.isEmpty || raw.length > maximumEntries) return null;
      final entries = <BuiltInSticker>[];
      final ids = <String>{};
      final paths = <String>{};
      var totalBytes = 0;
      for (final item in raw) {
        if (item is! Map || item.length != 10) return null;
        final id = item['id'];
        final path = item['path'];
        final mime = item['mime'];
        final width = item['width'];
        final height = item['height'];
        final bytes = item['bytes'];
        final hash = item['sha256'];
        final label = item['label'];
        final hologram = item['hologramEligible'];
        if (id is! String ||
            id.length > 128 ||
            !_id.hasMatch(id) ||
            !ids.add(id) ||
            path is! String ||
            path.length > 256 ||
            !_path.hasMatch(path) ||
            !paths.add(path) ||
            (mime != 'image/png' && mime != 'image/webp') ||
            !path.endsWith(mime == 'image/png' ? '.png' : '.webp') ||
            width is! int ||
            height is! int ||
            width < 1 ||
            height < 1 ||
            width > 512 ||
            height > 512 ||
            width > height * 4 ||
            height > width * 4 ||
            bytes is! int ||
            bytes < 1 ||
            bytes > 1024 * 1024 ||
            hash is! String ||
            !_hash.hasMatch(hash) ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 128 ||
            label.runes.any((rune) => rune < 32 || rune == 127) ||
            item['frames'] is! int ||
            item['frames'] != 1 ||
            hologram is! bool) {
          return null;
        }
        totalBytes += bytes;
        if (totalBytes > 16 * 1024 * 1024) return null;
        entries.add(
          BuiltInSticker(
            id: id,
            path: path,
            mime: mime as String,
            width: width,
            height: height,
            encodedBytes: bytes,
            sha256: hash,
            label: label,
            hologramEligible: hologram,
          ),
        );
      }
      return StickerManifest._(entries);
    } on FormatException {
      return null;
    }
  }
}
