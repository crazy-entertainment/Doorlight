import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/sticker_image.dart';

void main() {
  testWidgets('known sticker uses bundled artwork and an accessible label', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StickerImage(assetId: 'sybl.chubby-cats.angry.v1'),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Angry cat');
    expect(image.image, isA<AssetImage>());
    expect(
      (image.image as AssetImage).assetName,
      'assets/stickers/chubby_cats/angry.webp',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unknown sticker remains a neutral placeholder at 200 percent text',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: SizedBox(
                width: 220,
                child: StickerImage(assetId: 'sybl.unknown.v1'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sticker unavailable'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
