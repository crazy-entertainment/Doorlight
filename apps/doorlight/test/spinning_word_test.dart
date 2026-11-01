import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/spinning_word.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'InstrumentSerif': 'assets/fonts/InstrumentSerif-Italic.ttf',
      'Pacifico': 'assets/fonts/Pacifico-Regular.ttf',
      'Anton': 'assets/fonts/Anton-Regular.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('word reveal stays still across faces at text scale $scale', (
      tester,
    ) async {
      const surface = ValueKey('reel-surface');
      const style = TextStyle(fontSize: 26, height: 1.2, color: Colors.white);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: RepaintBoundary(
                key: surface,
                child: Material(
                  color: const Color(0xff15100c),
                  child: SizedBox(
                    width: 420,
                    height: 160,
                    child: Center(
                      child: SpinningWord(
                        words: const ['chatting', 'vibing', 'memeing'],
                        style: style,
                        styles: [
                          TextStyle(
                            fontFamily: 'InstrumentSerif',
                            fontSize: 32,
                          ),
                          style.copyWith(fontFamily: 'Pacifico'),
                          style.copyWith(fontFamily: 'Anton'),
                        ],
                        strutStyle: StrutStyle.fromTextStyle(
                          style,
                          forceStrutHeight: true,
                        ),
                        alignment: Alignment.centerLeft,
                        maxWidth: 300,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final reel = find.byKey(const ValueKey('spinning-word'));
      final bounds = tester.getRect(reel);
      // Observe every transition, including the frame where the outgoing
      // child's removal used to shrink the mask and crop the new face.
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.getRect(reel), bounds);
        expect(tester.takeException(), isNull);
        const captureDir = String.fromEnvironment('SPINNER_CAPTURE_DIR');
        if (captureDir.isNotEmpty && frame >= 33 && frame <= 42) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(surface),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('$captureDir/reel-$scale-$frame.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('reduced motion keeps the first word stationary', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const SpinningWord(
            words: ['chatting', 'vibing'],
            style: TextStyle(fontSize: 26),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('chatting'), findsOneWidget);
    expect(find.text('vibing'), findsNothing);
  });
}
