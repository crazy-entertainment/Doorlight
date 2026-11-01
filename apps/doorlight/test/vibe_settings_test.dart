import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/settings_previews.dart';
import 'package:sybl/ui/vibe_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('compact opacity control previews and commits at text $scale', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(320, 700)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var saved = 100;
      var intensity = 100;
      final intensityWrites = <int>[];
      final writes = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 700),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: StatefulBuilder(
                  builder: (context, update) => VibeSettings(
                    value: AmbientVibe.rain,
                    opacity: saved,
                    intensity: intensity,
                    animated: false,
                    enabled: true,
                    onChanged: (_) {},
                    onIntensityChanged: (value) async {
                      intensityWrites.add(value);
                      update(() => intensity = value);
                      return true;
                    },
                    onOpacityChanged: (value) async {
                      writes.add(value);
                      update(() => saved = value);
                      return true;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Intensity'), findsNothing);
      expect(find.text('Opacity'), findsNothing);
      final samples = find.byType(VibePreview);
      final adjustment = find.byKey(const ValueKey('vibe-adjustments'));
      expect(
        tester.getBottomLeft(adjustment).dy,
        lessThan(tester.getTopLeft(samples.first).dy),
      );
      for (var index = 1; index < 4; index++) {
        expect(
          tester.getTopLeft(samples.at(index)).dy,
          tester.getTopLeft(samples.first).dy,
        );
      }
      final opacityButton = find.byKey(const ValueKey('vibe-opacity-button'));
      await tester.tap(opacityButton);
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      final slider = find.byKey(const ValueKey('vibe-opacity-slider'));
      expect(
        SliderTheme.of(tester.element(slider)).showValueIndicator,
        ShowValueIndicator.never,
      );
      expect(find.text('Opacity'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(-35, 0));
      await tester.pump();
      expect(writes, isEmpty);
      expect(tester.widget<VibePreview>(samples.at(1)).opacity, lessThan(1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(saved, inInclusiveRange(0, 99));
      expect(tester.widget<VibePreview>(samples.at(1)).opacity, saved / 100);
      final beforeKeyboard = saved;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(saved, greaterThan(beforeKeyboard));
      expect(writes, hasLength(2));
      final opacityBeforeIntensity = saved;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      expect(
        tester.widget<IconButton>(opacityButton).focusNode!.hasFocus,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('vibe-intensity-button')));
      await tester.pumpAndSettle();
      final activity = find.byKey(const ValueKey('vibe-intensity-slider'));
      await tester.tapAt(
        tester.getRect(activity).centerLeft + const Offset(12, 0),
      );
      await tester.pumpAndSettle();
      expect(intensityWrites, hasLength(1));
      expect(intensity, lessThan(100));
      expect(
        tester.widget<VibePreview>(samples.at(1)).intensity,
        intensity / 100,
      );
      expect(writes, hasLength(2));
      expect(
        saved,
        opacityBeforeIntensity,
        reason: 'Intensity must not change opacity',
      );
      await tester.tapAt(const Offset(8, 600));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      // At large text, keyboard/scroll navigation still reaches the final card.
      final halloween = find.byKey(const ValueKey('choice-Vibe-halloween'));
      await tester.ensureVisible(halloween);
      await tester.pumpAndSettle();
      expect(halloween.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide vibe controls stay with the choices', (tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: VibeSettings(
            value: AmbientVibe.none,
            opacity: 63,
            intensity: 100,
            animated: false,
            enabled: true,
            onChanged: (_) {},
            onOpacityChanged: (_) async => true,
            onIntensityChanged: (_) async => true,
          ),
        ),
      ),
    );
    final controls = tester.getRect(
      find.byKey(const ValueKey('vibe-adjustments')),
    );
    final lastChoice = tester.getRect(
      find.byKey(const ValueKey('choice-Vibe-halloween')),
    );
    expect(controls.left - lastChoice.right, closeTo(8, 1));
    expect(controls.center.dy, closeTo(lastChoice.center.dy, 1));
    final intensityButton = tester.getRect(
      find.byKey(const ValueKey('vibe-intensity-button')),
    );
    final opacityRect = tester.getRect(
      find.byKey(const ValueKey('vibe-opacity-button')),
    );
    expect(intensityButton.center.dx, opacityRect.center.dx);
    expect(intensityButton.bottom, lessThanOrEqualTo(opacityRect.top));
    expect(controls.width, 44);
    expect(intensityButton.height, greaterThanOrEqualTo(44));
    expect(opacityRect.height, greaterThanOrEqualTo(44));
    final label = tester.renderObject<RenderParagraph>(find.text('Halloween'));
    expect(label.size.height, lessThan(20));
    final opacityButton = find.byKey(const ValueKey('vibe-opacity-button'));
    await tester.tap(opacityButton);
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('vibe-opacity-slider'));
    tester.widget<Slider>(slider).onChanged!(42);
    await tester.pump();
    tester.view.physicalSize = const Size(280, 700);
    await tester.pumpAndSettle();
    // Flutter dismisses menus on a window resize; discard the unsaved preview.
    expect(find.byType(Slider), findsNothing);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('vibe-adjustments'))).dy,
      lessThan(tester.getTopLeft(find.byType(VibePreview).first).dy),
    );
    await tester.tap(opacityButton);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 63);
    await tester.tap(find.byKey(const ValueKey('vibe-intensity-button')));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byKey(const ValueKey('vibe-intensity-slider')), findsOneWidget);
    expect(slider, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stacked icons expose names on hover and long press', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: VibeSettings(
            value: AmbientVibe.rain,
            opacity: 63,
            intensity: 80,
            animated: false,
            enabled: true,
            onChanged: (_) {},
            onOpacityChanged: (_) async => true,
            onIntensityChanged: (_) async => true,
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    try {
      expect(find.text('Intensity'), findsNothing);
      expect(find.text('Opacity'), findsNothing);
      expect(find.bySemanticsLabel('Intensity'), findsOneWidget);
      expect(find.bySemanticsLabel('Opacity'), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('vibe-intensity-button'))),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Intensity · 80%'), findsOneWidget);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Intensity · 80%'), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('vibe-opacity-button')));
      await tester.pumpAndSettle();
      expect(find.text('Opacity · 63%'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Opacity · 63%'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  for (final preset in AppearancePreset.values) {
    for (final (width, scale) in [(360.0, 1.0), (280.0, 2.0)]) {
      testWidgets('vibe adjustments ${preset.name} at $width text $scale', (
        tester,
      ) async {
        tester.view
          ..physicalSize = Size(width, 360)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(preset),
            debugShowCheckedModeBanner: false,
            builder: (context, child) => RepaintBoundary(
              key: const ValueKey('vibe-capture'),
              child: child!,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 360),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: VibeSettings(
                  value: AmbientVibe.rain,
                  opacity: 63,
                  intensity: 80,
                  animated: false,
                  enabled: true,
                  onChanged: (_) {},
                  onOpacityChanged: (_) async => true,
                  onIntensityChanged: (_) async => true,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('vibe-opacity-button')));
        await tester.pumpAndSettle();
        final slider = find.byKey(const ValueKey('vibe-opacity-slider'));
        expect(tester.getSize(slider).width, lessThanOrEqualTo(196));
        expect(tester.getSize(slider).height, greaterThanOrEqualTo(44));
        expect(tester.getRect(slider).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(slider).right, lessThanOrEqualTo(width));
        await expectLater(
          find.byKey(const ValueKey('vibe-capture')),
          matchesGoldenFile(
            'goldens/vibe_adjustments_${preset.name}_${width.round()}_text${(scale * 100).round()}.png',
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'failed saves restore previews and disabled controls cannot open',
    (tester) async {
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return VibeSettings(
                  value: AmbientVibe.snow,
                  opacity: 80,
                  intensity: 60,
                  animated: false,
                  enabled: enabled,
                  onChanged: (_) {},
                  onOpacityChanged: (_) async => false,
                  onIntensityChanged: (_) async => false,
                );
              },
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('vibe-opacity-button'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('vibe-opacity-slider'));
      await tester.tapAt(
        tester.getRect(slider).centerLeft + const Offset(12, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 80);
      expect(
        tester.widget<VibePreview>(find.byType(VibePreview).first).opacity,
        .8,
      );
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      update(() => enabled = true);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
