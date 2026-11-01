import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/screens/home.dart';

import 'app_state_test.dart' show FakeJami;

void main() {
  setUpAll(() async {
    await (FontLoader('HankenGrotesk')..addFont(
        rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf'))).load();
    await (FontLoader('Fraunces')..addFont(
        rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(
        rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final (size, scale) in [(const Size(390, 844), 2.0), (const Size(1280, 800), 1.0)]) {
    testWidgets('restore microphone warning and choice at $size scale $scale', (tester) async {
      tester.view..devicePixelRatio = 1..physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({'appSettings': jsonEncode(
          const AppSettingsCodec().encode(AppSettings(microphoneReviewRequired: true)))});
      final state = (await tester.runAsync(() async {
        final value = AppState(FakeJami()..accountExists = false,
            await SharedPreferences.getInstance());
        await value.init();
        return value;
      }))!;
      addTearDown(state.dispose);
      state.screen = Screen.home;
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(theme: Warm.theme(),
        home: MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: boundary, child: ListenableBuilder(
              listenable: state, builder: (context, _) => HomeScreen(state: state))))));
      final warning = find.byKey(const ValueKey('restore-microphone-review'));
      await tester.pumpAndSettle();
      expect(warning, findsOneWidget);
      expect(tester.getRect(warning).top, greaterThanOrEqualTo(0));
      expect(tester.getRect(warning).bottom, lessThan(size.height));
      expect(tester.widget<Text>(warning).maxLines, isNull);
      expect(tester.takeException(), isNull);
      final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
      if (output != null) {
        await tester.runAsync(() async {
          final surface = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await surface.toImage();
          try {
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$output/restore-microphone-${size.width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
          } finally { image.dispose(); }
        });
      }
      await tester.ensureVisible(find.text('Push-to-talk'));
      await tester.tap(find.text('Push-to-talk'));
      await tester.pumpAndSettle();
      expect(state.appSettings.microphoneReviewRequired, isFalse);
      expect(state.appSettings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
      expect(warning, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
