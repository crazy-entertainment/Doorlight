import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../state/sticker_manifest.dart';

/// One verified, bundled catalog; never a network or peer-selected file path.
final Future<StickerManifest?> bundledStickerManifest = _load();

Future<StickerManifest?> _load() async {
  try {
    final manifest = StickerManifest.parse(
      await rootBundle.loadString(StickerManifest.assetPath),
    );
    if (manifest == null) return null;
    for (final entry in manifest.entries) {
      final data = await rootBundle.load(entry.path);
      if (data.lengthInBytes != entry.encodedBytes) return null;
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (sha256.convert(bytes).toString() != entry.sha256) return null;
    }
    return manifest;
  } catch (_) {
    return null;
  }
}
