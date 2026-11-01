import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sybl/core/invite_link.dart';
import 'package:sybl/ui/friend_qr_scanner.dart';
import 'package:zxing2/qrcode.dart' show Encoder, ErrorCorrectionLevel;

const _id = 'a7c42e0123456789abcdef0123456789ab91bd08';

img.Image _qrScreenshot(String text) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  const scale = 6, quiet = 4 * scale, margin = 80;
  final size = matrix.width * scale + 2 * quiet;
  // A dark app background around a white QR card, like a screenshot.
  final image = img.Image(width: size + 2 * margin, height: size + 2 * margin)
    ..clear(img.ColorRgb8(28, 26, 24));
  img.fillRect(
    image,
    x1: margin,
    y1: margin,
    x2: margin + size,
    y2: margin + size,
    color: img.ColorRgb8(255, 255, 255),
  );
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) != 1) continue;
      img.fillRect(
        image,
        x1: margin + quiet + x * scale,
        y1: margin + quiet + y * scale,
        x2: margin + quiet + (x + 1) * scale - 1,
        y2: margin + quiet + (y + 1) * scale - 1,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
  }
  return image;
}

void main() {
  test('reads the friend invite from a QR screenshot', () {
    final invite = SyblInviteLink.create(jamiId: _id, displayName: 'PC')!;
    final png = img.encodePng(_qrScreenshot(invite.shareUri().toString()));
    final read = friendInviteFromQrImage(png);
    expect(read?.jamiId, _id);
    expect(read?.displayName, 'PC');
  });

  test('a bare Friend ID QR still resolves', () {
    final jpg = img.encodeJpg(_qrScreenshot(_id));
    expect(friendInviteFromQrImage(jpg)?.jamiId, _id);
  });

  test('rejects images without a Doorlight QR', () {
    expect(
      friendInviteFromQrImage(img.encodePng(_qrScreenshot('hello'))),
      isNull,
    );
    expect(
      friendInviteFromQrImage(img.encodePng(img.Image(width: 64, height: 64))),
      isNull,
    );
    expect(friendInviteFromQrImage(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
