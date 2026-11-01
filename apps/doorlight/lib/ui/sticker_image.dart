import 'package:flutter/material.dart';

import '../state/sticker_manifest.dart';
import '../core/sticker_assets.dart';
export '../core/sticker_assets.dart' show bundledStickerManifest;

/// Only a bundled manifest entry can select an asset. Unknown IDs have no
/// network fallback and no effect beyond this neutral timeline placeholder.
class StickerImage extends StatelessWidget {
  const StickerImage({super.key, required this.assetId, this.extent = 160});
  final String? assetId;
  final double extent;

  @override
  Widget build(BuildContext context) => FutureBuilder<StickerManifest?>(
    future: bundledStickerManifest,
    builder: (context, snapshot) {
      final entry = assetId == null ? null : snapshot.data?.byId(assetId!);
      if (entry == null) {
        return const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Sticker unavailable'),
        );
      }
      return Image.asset(
        entry.path,
        width: extent,
        height: extent,
        fit: BoxFit.contain,
        semanticLabel: entry.label,
        errorBuilder: (_, _, _) => const Text('Sticker unavailable'),
      );
    },
  );
}
