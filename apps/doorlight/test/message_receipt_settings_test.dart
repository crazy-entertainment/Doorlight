import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/message_receipt_settings.dart';

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
      testWidgets('receipt choices fit $width at $scale and save preferences', (
        tester,
      ) async {
        tester.view
          ..physicalSize = Size(width, 800)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var style = MessageReceiptStyle.whatsapp;
        var visibility = MessageReceiptVisibility.always;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundary,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: StatefulBuilder(
                        builder: (context, update) => MessageReceiptSettings(
                          style: style,
                          visibility: visibility,
                          enabled: true,
                          onStyleChanged: (value) =>
                              update(() => style = value),
                          onVisibilityChanged: (value) =>
                              update(() => visibility = value),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byTooltip('About message status'), findsNothing);
        final dropdown = find.byKey(const ValueKey('message-status-style'));
        final ink = find.descendant(
          of: dropdown,
          matching: find.byType(InkWell),
        );
        final surface = find
            .ancestor(of: dropdown, matching: find.byType(Material))
            .first;
        expect(
          tester.getRect(ink),
          tester.getRect(surface),
          reason:
              'Hover/focus must cover the outlined control, including its padding',
        );
        await tester.tap(find.byKey(const ValueKey('message-status-style')));
        await tester.pumpAndSettle();
        for (final label in ['Checks', 'Arrows', 'Circles & picture']) {
          expect(find.text(label), findsWidgets);
        }
        await tester.tap(find.text('Circles & picture').last);
        await tester.pumpAndSettle();
        expect(style, MessageReceiptStyle.messenger);
        await tester.tap(find.byKey(const ValueKey('message-status-delay')));
        await tester.pumpAndSettle();
        expect(visibility, MessageReceiptVisibility.afterPause);
        expect(tester.takeException(), isNull);
        if (Platform.environment['RECEIPT_CAPTURES'] == '1') {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final capture = await render.toImage();
            final bytes = await capture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File('../../local/tmp/receipt-settings/receipt-$width-$scale.png')
              ..createSync(recursive: true)
              ..writeAsBytesSync(bytes!.buffer.asUint8List());
            capture.dispose();
          });
        }
        await tester.tap(find.byKey(const ValueKey('message-status-delay')));
        await tester.pumpAndSettle();
        expect(visibility, MessageReceiptVisibility.always);
      });
    }
  }

  testWidgets('unavailable settings cannot change preferences', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: MessageReceiptSettings(
            style: MessageReceiptStyle.sybl,
            visibility: MessageReceiptVisibility.afterPause,
            enabled: false,
            onStyleChanged: (_) => fail('disabled style changed'),
            onVisibilityChanged: (_) => fail('disabled timing changed'),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<DropdownButton<MessageReceiptStyle>>(
            find.byKey(const ValueKey('message-status-style')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('message-status-delay')),
          )
          .onChanged,
      isNull,
    );
  });
}
