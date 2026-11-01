import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/windows_chrome.dart';

class _LayoutJami extends JamiClient {
  @override
  bool get usesNativeAppSettingsStore => false;
}

void main() {
  setUpAll(() async {
    for (final entry in {
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
      'Fraunces': 'assets/fonts/Fraunces-Variable.ttf',
      'InstrumentSerif': 'assets/fonts/InstrumentSerif-Italic.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  for (final scene in [
    (
      name: 'desktop-small',
      size: const Size(675, 490),
      scale: 1.0,
      desktop: true,
    ),
    (
      name: 'desktop-wide',
      size: const Size(1024, 640),
      scale: 1.0,
      desktop: true,
    ),
    (
      name: 'desktop-large',
      size: const Size(1440, 900),
      scale: 1.0,
      desktop: true,
    ),
    (
      name: 'desktop-short',
      size: const Size(600, 360),
      scale: 1.0,
      desktop: true,
    ),
    (
      name: 'desktop-text200',
      size: const Size(1024, 640),
      scale: 2.0,
      desktop: true,
    ),
    (name: 'mobile', size: const Size(390, 844), scale: 1.0, desktop: false),
  ]) {
    testWidgets('${scene.name} keeps both setup paths accessible', (
      tester,
    ) async {
      tester.view.physicalSize = scene.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final jami = _LayoutJami();
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      const surface = ValueKey('onboarding-layout-surface');
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: Warm.theme().copyWith(
            platform: scene.desktop
                ? TargetPlatform.windows
                : TargetPlatform.android,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
              size: scene.size,
              textScaler: TextScaler.linear(scene.scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: surface,
            child: scene.desktop
                ? WindowsChrome(
                    jami: jami,
                    onboarding: true,
                    child: OnboardingScreen(state: state),
                  )
                : OnboardingScreen(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      const captureDir = String.fromEnvironment('ONBOARDING_CAPTURE_DIR');
      Future<void> capture(String step) async {
        if (captureDir.isEmpty) return;
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(surface),
          );
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$captureDir/${scene.name}-$step.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('welcome');
      for (final key in [
        'onboarding-create-choice',
        'onboarding-existing-choice',
      ]) {
        final choice = find.byKey(ValueKey(key));
        await tester.ensureVisible(choice);
        await tester.pumpAndSettle();
        expect(choice.hitTestable(), findsOneWidget);
      }
      final existing = find.byKey(const ValueKey('onboarding-existing-choice'));
      await tester.tap(existing);
      await tester.pumpAndSettle();
      expect(find.text('Link this device'), findsOneWidget);
      await capture('existing');
      await tester.tap(find.byKey(const ValueKey('onboarding-back')));
      await tester.pumpAndSettle();
      final create = find.byKey(const ValueKey('onboarding-create-choice'));
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('onboarding-name-field')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture('name');
    });
  }
}
