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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('intensity changes scene activity independently of opacity', () async {
    for (final vibe in AmbientVibe.values.where((v) => v != AmbientVibe.none)) {
      final totals = <int>[];
      for (final intensity in [0.0, .35, 1.0]) {
        final recorder = ui.PictureRecorder();
        VibePainter(
          vibe,
          Warm.palette(AppearancePreset.midnight),
          intensity: intensity,
        ).paint(Canvas(recorder), const Size(320, 360));
        final picture = recorder.endRecording();
        final image = await picture.toImage(320, 360);
        final data = (await image.toByteData())!.buffer.asUint8List();
        var alpha = 0;
        for (var i = 3; i < data.length; i += 4) {
          alpha += data[i];
        }
        totals.add(alpha);
        image.dispose();
        picture.dispose();
      }
      if (vibe != AmbientVibe.halloween) expect(totals.first, 0);
      expect(totals[1], greaterThan(totals[0]), reason: '$vibe');
      expect(totals[2], greaterThan(totals[1]), reason: '$vibe');
    }
  });

  test('opacity scales every scene and zero paints nothing', () async {
    for (final vibe in AmbientVibe.values.where((v) => v != AmbientVibe.none)) {
      final totals = <int>[];
      for (final opacity in [0.0, .35, 1.0]) {
        final recorder = ui.PictureRecorder();
        VibePainter(
          vibe,
          Warm.palette(AppearancePreset.midnight),
          opacity: opacity,
        ).paint(Canvas(recorder), const Size(320, 360));
        final picture = recorder.endRecording();
        final image = await picture.toImage(320, 360);
        final data = (await image.toByteData())!.buffer.asUint8List();
        var alpha = 0;
        for (var offset = 3; offset < data.length; offset += 4) {
          alpha += data[offset];
        }
        totals.add(alpha);
        image.dispose();
        picture.dispose();
      }
      expect(totals[0], 0, reason: '$vibe');
      expect(totals[1], greaterThan(0), reason: '$vibe');
      expect(totals[1], lessThan(totals[2]), reason: '$vibe');
    }
  });

  testWidgets('zero opacity stops motion and restores when raised', (
    tester,
  ) async {
    final theme = Warm.theme();
    Widget scene(double opacity, {double intensity = 1}) => MaterialApp(
      theme: theme,
      home: AmbientVibeSurface(
        vibe: AmbientVibe.rain,
        animationsEnabled: true,
        opacity: opacity,
        intensity: intensity,
        child: const SizedBox.expand(),
      ),
    );
    await tester.pumpWidget(scene(0));
    expect(find.byKey(const ValueKey('ambient-vibe-rain')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(scene(.5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('ambient-vibe-rain')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(scene(.5, intensity: 0));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(scene(.5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  test('rain travels along its streak direction between edge wraps', () {
    const size = Size(700, 500);
    var checked = 0;
    for (var i = 0; i < 40; i++) {
      final before = VibePainter.rainPosition(size, i, .35);
      final after = VibePainter.rainPosition(size, i, .3501);
      final delta = after - before;
      if (delta.dx.abs() > 10 || delta.dy.abs() > 10) continue;
      expect(delta.dy, greaterThan(0));
      expect(delta.dx, lessThan(0));
      expect(delta.dx / delta.dy, closeTo(VibePainter.rainDirection.dx, 1e-8));
      checked++;
    }
    expect(checked, greaterThan(35));
  });

  test(
    'ambient layers are visible over the app background and keep centres quiet',
    () async {
      for (final vibe in AmbientVibe.values) {
        List<int>? previous;
        for (final phase in [.1, .35, .7]) {
          final recorder = ui.PictureRecorder();
          final colors = Warm.palette(AppearancePreset.midnight);
          final canvas = Canvas(recorder)..drawColor(colors.bg, BlendMode.src);
          VibePainter(
            vibe,
            colors,
            motion: AlwaysStoppedAnimation(phase),
          ).paint(canvas, const Size(320, 360));
          final picture = recorder.endRecording();
          final image = await picture.toImage(320, 360);
          final data = (await image.toByteData())!.buffer.asUint8List();
          var peak = 0;
          var centrePeak = 0;
          for (var y = 0; y < 360; y++) {
            for (var x = 0; x < 320; x++) {
              final offset = (y * 320 + x) * 4;
              final alpha = [
                (data[offset] - (colors.bg.r * 255).round()).abs(),
                (data[offset + 1] - (colors.bg.g * 255).round()).abs(),
                (data[offset + 2] - (colors.bg.b * 255).round()).abs(),
              ].reduce((a, b) => a > b ? a : b);
              if (alpha > peak) peak = alpha;
              if (x > 112 &&
                  x < 208 &&
                  y > 126 &&
                  y < 234 &&
                  alpha > centrePeak) {
                centrePeak = alpha;
              }
            }
          }
          expect(peak, lessThanOrEqualTo(40), reason: '$vibe at $phase');
          expect(
            centrePeak,
            lessThanOrEqualTo(10),
            reason: '$vibe centre at $phase',
          );
          expect(
            peak,
            vibe == AmbientVibe.none ? 0 : greaterThanOrEqualTo(8),
            reason: "$vibe must be visible over the actual background",
          );
          if (previous != null && vibe != AmbientVibe.none) {
            var changed = 0;
            for (var i = 0; i < data.length; i += 4) {
              if ((data[i] - previous[i]).abs() > 1 ||
                  (data[i + 1] - previous[i + 1]).abs() > 1 ||
                  (data[i + 2] - previous[i + 2]).abs() > 1) {
                changed++;
              }
            }
            expect(
              changed,
              greaterThan(20),
              reason: '$vibe must visibly move between frames',
            );
          }
          previous = data;
          image.dispose();
          picture.dispose();
        }
      }
    },
  );

  testWidgets(
    'selected vibe preview demonstrates motion without OS suppression',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const SizedBox(
              width: 64,
              height: 56,
              child: VibePreview(AmbientVibe.snow, animated: true),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      VibePainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('ambient-vibe-snow')),
                  )
                  .painter!
              as VibePainter;
      final before = painter().motion!.value;
      await tester.pump(const Duration(milliseconds: 250));
      expect(painter().motion!.value, greaterThan(before));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('vibe scenes and previews render at actual compact size', (
    tester,
  ) async {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
      'Fraunces': 'assets/fonts/Fraunces-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
    tester.view
      ..physicalSize = const Size(700, 620)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    for (final phase in [.1, .35, .7]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(AppearancePreset.midnight),
          home: RepaintBoundary(
            key: boundary,
            child: Builder(
              builder: (context) => Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SettingsChoices<AmbientVibe>(
                        title: 'Vibe',
                        values: AmbientVibe.values,
                        value: AmbientVibe.none,
                        label: vibeLabel,
                        preview: (vibe) => VibePreview(vibe),
                        onChanged: (_) {},
                        enabled: true,
                        maxTileWidth: 64,
                        allPreviews: true,
                        previewHeight: 56,
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            for (final vibe in [
                              AmbientVibe.rain,
                              AmbientVibe.snow,
                              AmbientVibe.halloween,
                            ])
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: ColoredBox(
                                    color: context.syblColors.surface,
                                    child: CustomPaint(
                                      foregroundPainter: VibePainter(
                                        vibe,
                                        context.syblColors,
                                        motion: AlwaysStoppedAnimation(phase),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(vibeLabel(vibe)),
                                            const Spacer(),
                                            const Text('Alex'),
                                            const SizedBox(height: 8),
                                            const Text(
                                              'Are we still meeting this evening?',
                                            ),
                                            const SizedBox(height: 20),
                                            const Text(
                                              'Yes, see you at seven.',
                                            ),
                                            const Spacer(),
                                            const Text('Message Alex'),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
      if (output != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/vibes-$phase.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
  });
}
