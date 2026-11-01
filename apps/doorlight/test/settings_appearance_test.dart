import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/ambient_vibe.dart';
import 'package:sybl/ui/settings_previews.dart';
import 'package:sybl/ui/message_time_settings.dart';
import 'package:sybl/ui/sender_label_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
  });
  const codec = AppSettingsCodec();
  test(
    'edge spacing is strict, migrates to close and survives settings copies',
    () {
      for (final spacing in WindowEdgeSpacing.values) {
        final settings = AppSettings()
            .withWindowEdgeSpacing(spacing)
            .withAmbientVibe(AmbientVibe.rain)
            .withRememberDefaultWindowPosition(true);
        final decoded = codec.decode(codec.encode(settings));
        expect(decoded.settings, settings);
        expect(decoded.settings.hashCode, settings.hashCode);
        expect(decoded.needsRewrite, isFalse);
      }
      expect(
        AppSettings().withWindowEdgeSpacing(WindowEdgeSpacing.floating),
        isNot(AppSettings()),
      );
      final old = codec.encode(AppSettings())..['schemaVersion'] = 19;
      (old['appearance'] as Map).remove('windowEdgeSpacing');
      final migrated = codec.decode(old);
      expect(migrated.settings.windowEdgeSpacing, WindowEdgeSpacing.close);
      expect(migrated.needsRewrite, isTrue);
      for (final invalid in [null, 24, 'other']) {
        final document = codec.encode(AppSettings());
        document['appearance'] = <String, Object?>{
          ...document['appearance'] as Map<String, Object?>,
          'windowEdgeSpacing': invalid,
        };
        expect(() => codec.decode(document), throwsFormatException);
      }
    },
  );
  test(
    'vibe and window placement survive every settings copy and migration',
    () {
      for (final vibe in AmbientVibe.values) {
        for (final remember in [false, true]) {
          final settings = AppSettings()
              .withAmbientVibe(vibe)
              .withRememberDefaultWindowPosition(remember)
              .withChatMotionEnabled(false)
              .withAppearancePreset(AppearancePreset.midnight);
          final decoded = codec.decode(codec.encode(settings));
          expect(decoded.settings, settings);
          expect(decoded.settings.hashCode, settings.hashCode);
          expect(decoded.needsRewrite, isFalse);
        }
      }
      final previous = codec.encode(AppSettings())..['schemaVersion'] = 18;
      (previous['appearance'] as Map)
        ..remove('vibe')
        ..remove('rememberDefaultWindowPosition');
      final migrated = codec.decode(previous);
      expect(migrated.needsRewrite, isTrue);
      expect(migrated.settings.ambientVibe, AmbientVibe.none);
      expect(migrated.settings.rememberDefaultWindowPosition, isFalse);
      for (final invalid in [null, 1, 'unrecognised']) {
        final document = codec.encode(AppSettings());
        document['appearance'] = {
          ...document['appearance'] as Map,
          'vibe': invalid,
        };
        expect(() => codec.decode(document), throwsFormatException);
      }
      final invalidPosition = codec.encode(AppSettings());
      (invalidPosition['appearance'] as Map)['rememberDefaultWindowPosition'] =
          'yes';
      expect(() => codec.decode(invalidPosition), throwsFormatException);
    },
  );

  testWidgets(
    'vibe obeys app motion, pauses in background and never takes input',
    (tester) async {
      var taps = 0;
      Future<void> mount(bool animations, AmbientVibe vibe) =>
          tester.pumpWidget(
            MaterialApp(
              theme: Warm.theme(),
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: AmbientVibeSurface(
                  vibe: vibe,
                  animationsEnabled: animations,
                  child: Scaffold(
                    body: TextButton(
                      onPressed: () => taps++,
                      child: const Text('Tap'),
                    ),
                  ),
                ),
              ),
            ),
          );
      Animation<double> motion() =>
          (tester
                      .widget<CustomPaint>(
                        find.byKey(const ValueKey('ambient-vibe-rain')),
                      )
                      .painter!
                  as VibePainter)
              .motion!;
      await mount(true, AmbientVibe.rain);
      await tester.pump(const Duration(milliseconds: 200));
      final before = motion().value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(motion().value, greaterThan(before));
      await tester.tap(find.text('Tap'));
      expect(taps, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final paused = motion().value;
      await tester.pump(const Duration(seconds: 1));
      expect(motion().value, paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await mount(false, AmbientVibe.rain);
      final still = motion().value;
      await tester.pump(const Duration(seconds: 1));
      expect(motion().value, still);
      await mount(true, AmbientVibe.none);
      expect(find.byKey(const ValueKey('ambient-vibe-rain')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('settings headings have no help buttons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Column(
            children: const [
              SettingsHeading('Vibe'),
              SettingsHeading('Receipts'),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('help-Vibe')), findsNothing);
    expect(find.text('Receipts'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
  });

  for (final width in [320.0, 700.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('visual settings fit width $width at text $scale', (
        tester,
      ) async {
        tester.view
          ..physicalSize = Size(width, 900)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        var selected = MessageTimestampStyle.inward;
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundary,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: StatefulBuilder(
                        builder: (context, setState) => Column(
                          children: [
                            SettingsChoices<WindowEdgeSpacing>(
                              title: 'Edge spacing',
                              values: WindowEdgeSpacing.values,
                              value: WindowEdgeSpacing.close,
                              label: (v) => v == WindowEdgeSpacing.close
                                  ? 'Close'
                                  : 'Floating',
                              preview: (v) => WindowEdgeSpacingPreview(v),
                              enabled: true,
                              onChanged: (_) {},
                            ),
                            MessageTimeSettings(
                              value: selected,
                              enabled: true,
                              onChanged: (v) => setState(() => selected = v),
                            ),
                            SenderLabelSettings(
                              value: true,
                              enabled: true,
                              onChanged: (_) {},
                            ),
                            SettingsChoices<AmbientVibe>(
                              title: 'Vibe',
                              maxTileWidth: 64,
                              allPreviews: true,
                              previewHeight: 56,
                              values: AmbientVibe.values,
                              value: AmbientVibe.none,
                              label: vibeLabel,
                              preview: (v) => VibePreview(v),
                              enabled: true,
                              onChanged: (_) {},
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('message-time-placement')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Beside the bubble').last);
        await tester.pumpAndSettle();
        expect(selected, MessageTimestampStyle.inward);
        expect(find.byKey(const ValueKey('help-Message times')), findsNothing);
        expect(tester.takeException(), isNull);
        final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
        if (output != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/settings-choices-${width.toInt()}-${scale}x.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
      });
    }
  }
}
