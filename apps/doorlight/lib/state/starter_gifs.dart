import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'gif_validation.dart';

/// Read-only bundled media. These entries never consume personal library slots.
final class StarterGif {
  const StarterGif(this.id, this.name, this.hash, this.length);
  final String id;
  final String name;
  final String hash;
  final int length;
  String get asset => 'assets/gifs/doorlight/$id.gif';

  bool matches(Uint8List bytes) =>
      bytes.length == length && sha256.convert(bytes).toString() == hash;

  Future<Uint8List?> load() async {
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return matches(bytes) && await validateGifDecode(bytes) != null
          ? bytes
          : null;
    } catch (_) {
      return null;
    }
  }
}

final Future<List<StarterGif>> bundledStarterGifs = _load();

Future<List<StarterGif>> _load() async {
  try {
    final text = await rootBundle.loadString(
      'assets/gifs/doorlight/manifest.json',
    );
    if (text.length > 64 * 1024) return const [];
    final document = jsonDecode(text) as Map<String, dynamic>;
    if (document['version'] != 1) return const [];
    final entries = document['assets'] as List<dynamic>;
    if (entries.length != 16) return const [];
    final ids = <String>{};
    final hashes = <String>{};
    final result = <StarterGif>[];
    for (final raw in entries) {
      final entry = raw as Map<String, dynamic>;
      final id = entry['id'] as String;
      final name = entry['name'] as String;
      final hash = entry['sha256'] as String;
      final length = entry['bytes'] as int;
      if (!RegExp(r'^[a-z]{1,20}$').hasMatch(id) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
          !ids.add(id) ||
          !hashes.add(hash) ||
          name.isEmpty ||
          name.length > 48 ||
          length < 1 ||
          length > ValidatedGif.maximumBytes ||
          entry['asset'] != 'assets/gifs/doorlight/$id.gif') {
        return const [];
      }
      result.add(StarterGif(id, name, hash, length));
    }
    return List.unmodifiable(result);
  } catch (_) {
    return const [];
  }
}
