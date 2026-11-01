import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:sybl/ui/bounded_attachment_preview.dart';

void main() {
  test('a completed static image becomes a small bounded PNG', () async {
    final pixels = image.Image(width: 8, height: 8)
      ..clear(image.ColorRgb8(40, 80, 120));
    final preview = await loadBoundedAttachmentPreview(
      null,
      Uint8List.fromList(image.encodePng(pixels)),
    );
    expect(preview, isNotNull);
    expect(preview!.gif, isFalse);
    expect(preview.bytes.length, lessThanOrEqualTo(48 * 1024));
    expect(image.decodePng(preview.bytes)?.width, 96);
  });

  test('a GIF renamed to PNG keeps the bounded GIF path', () async {
    final directory = await Directory.systemTemp.createTemp('sybl-preview-');
    try {
      final file = File('${directory.path}/renamed.png');
      await file.writeAsBytes(
        image.encodeGif(image.Image(width: 2, height: 2)),
      );
      final preview = await loadBoundedAttachmentPreview(file.path, null);
      expect(preview, isNotNull);
      expect(preview!.gif, isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'oversized source and oversized dimensions have no automatic preview',
    () async {
      expect(
        await loadBoundedAttachmentPreview(
          null,
          Uint8List(4 * 1024 * 1024 + 1),
        ),
        isNull,
      );
      final oversized = image.Image(width: 4097, height: 2);
      expect(
        await loadBoundedAttachmentPreview(
          null,
          Uint8List.fromList(image.encodePng(oversized)),
        ),
        isNull,
      );
    },
  );
}
