import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/account_share.dart';

void main() {
  for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('link QR keeps crisp square pixels at scale $ratio', (
      tester,
    ) async {
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = const Size(801, 601);
      addTearDown(tester.view.reset);
      const boundaryKey = ValueKey('qr-pixels');
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundaryKey,
            child: Center(
              child: PairingOfferQr(
                offer: 'jami-auth://${'b' * 64}/123456/doorlight-v1',
                dimension: 280,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('pairing-offer-qr')),
      );
      await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
            .toImage(pixelRatio: ratio);
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var black = 0;
          for (
            var y = (rect.top * ratio).ceil() + 1;
            y < (rect.bottom * ratio).floor() - 1;
            y++
          ) {
            for (
              var x = (rect.left * ratio).ceil() + 1;
              x < (rect.right * ratio).floor() - 1;
              x++
            ) {
              final red = pixels.getUint8((y * image.width + x) * 4);
              expect(
                red,
                anyOf(0, 255),
                reason:
                    'QR squares must not be blurred by fractional scaling or placement',
              );
              if (red == 0) black++;
            }
          }
          expect(black, greaterThan(1000));
        } finally {
          image.dispose();
        }
      });
    });
  }
}
