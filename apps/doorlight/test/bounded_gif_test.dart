import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/bounded_gif.dart';

import 'gif_validation_test.dart' show gif;

Future<void> loaded(WidgetTester tester, int count) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.byTooltip('Play GIF').evaluate().length == count) return;
  }
  expect(find.byTooltip('Play GIF'), findsNWidgets(count));
}

void main() {
  testWidgets('receipt validation gates decoding and every play', (
    tester,
  ) async {
    var valid = false;
    var checks = 0;
    Widget preview(String key) => MaterialApp(
      home: BoundedGif(
        key: ValueKey(key),
        bytes: gif(frames: 3),
        size: 100,
        validate: () async {
          checks++;
          return valid;
        },
      ),
    );
    await tester.pumpWidget(preview('blocked'));
    await tester.pump();
    expect(checks, 1);
    expect(find.byType(RawImage), findsNothing);
    expect(find.byTooltip('Play GIF'), findsNothing);
    valid = true;
    await tester.pumpWidget(preview('valid'));
    await loaded(tester, 1);
    valid = false;
    await tester.tap(find.byTooltip('Play GIF'));
    await tester.pump();
    expect(checks, 3);
    expect(find.byTooltip('Pause GIF'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('authority loss releases the active GIF', (tester) async {
    var current = true;
    await tester.pumpWidget(
      MaterialApp(
        home: BoundedGif(
          bytes: gif(frames: 3, delay: 100),
          size: 100,
          isCurrent: () => current,
        ),
      ),
    );
    await loaded(tester, 1);
    await tester.tap(find.byTooltip('Play GIF'));
    await tester.pump();
    current = false;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Pause GIF'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'reduced motion stays still, explicit play replaces the active GIF',
    (tester) async {
      final bytes = gif(frames: 3, delay: 20);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(800, 600),
              disableAnimations: true,
            ),
            child: Row(
              children: [
                BoundedGif(bytes: bytes, size: 100),
                BoundedGif(bytes: bytes, size: 100),
              ],
            ),
          ),
        ),
      );
      await loaded(tester, 2);
      expect(find.byTooltip('Pause GIF'), findsNothing);
      await tester.tap(find.byTooltip('Play GIF').first);
      await tester.pump();
      expect(find.byTooltip('Pause GIF'), findsOneWidget);
      await tester.tap(find.byTooltip('Play GIF'));
      await tester.pump();
      expect(find.byTooltip('Pause GIF'), findsOneWidget);
      expect(find.byTooltip('Play GIF'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byTooltip('Pause GIF'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scrolling a retained preview out of its viewport stops playback',
    (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 150,
              child: SingleChildScrollView(
                controller: controller,
                child: Column(
                  children: [
                    BoundedGif(bytes: gif(frames: 3, delay: 100), size: 100),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await loaded(tester, 1);
      await tester.tap(find.byTooltip('Play GIF'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      controller.jumpTo(300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.byTooltip('Pause GIF'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('malformed and over-limit input never exposes Play', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            BoundedGif(bytes: gif(width: 513), size: 100),
            BoundedGif(bytes: Uint8List.fromList([1, 2, 3]), size: 100),
          ],
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(find.byTooltip('Play GIF'), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });
}
