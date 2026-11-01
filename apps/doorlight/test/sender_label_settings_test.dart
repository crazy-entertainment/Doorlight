import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/sender_label_settings.dart';

void main() {
  setUpAll(() async {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  for (final width in [320.0, 700.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('sender comparison at $width and $scale selects both modes', (
        tester,
      ) async {
        tester.view
          ..physicalSize = Size(width, 900)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        try {
          var repeat = true;
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: Warm.theme(),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: boundary,
                  child: Scaffold(
                    body: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: StatefulBuilder(
                          builder: (context, update) => SenderLabelSettings(
                            value: repeat,
                            enabled: true,
                            onChanged: (value) => update(() => repeat = value),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.text('Alex'), findsNWidgets(3));
          final once = find.byKey(const ValueKey('sender-label-false'));
          final again = find.byKey(const ValueKey('sender-label-true'));
          if (scale == 1) {
            expect(tester.getRect(again).top, tester.getRect(once).top);
            expect(tester.getSize(again).height, tester.getSize(once).height);
            expect(tester.getRect(once).bottom, lessThan(230));
          }
          await tester.tap(once);
          await tester.pumpAndSettle();
          expect(repeat, isFalse);
          expect(
            tester
                .getSemantics(find.bySemanticsLabel('On sender change'))
                .getSemanticsData()
                .hasAction(ui.SemanticsAction.tap),
            isTrue,
          );
          await tester.tap(again);
          await tester.pumpAndSettle();
          expect(repeat, isTrue);
          expect(tester.takeException(), isNull);
          if (Platform.environment['SENDER_CAPTURES'] == '1') {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final capture = await render.toImage();
              final bytes = await capture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File('../../local/tmp/sender-labels/sender-$width-$scale.png')
                ..createSync(recursive: true)
                ..writeAsBytesSync(bytes!.buffer.asUint8List());
              capture.dispose();
            });
          }
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('disabled comparison preserves its selection', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SenderLabelSettings(
            value: false,
            enabled: false,
            onChanged: (_) => fail('disabled selection changed'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('sender-label-true')));
    expect(tester.takeException(), isNull);
  });
}
