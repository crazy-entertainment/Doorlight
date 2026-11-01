import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/desktop_settings_scrubber.dart';

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.animations = true});
  final bool animations;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = ScrollController();
  final viewport = GlobalKey();
  final rail = GlobalKey<DesktopSettingsScrubberState>();
  final sections = List.generate(8, (_) => GlobalKey());

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
    home: Scaffold(
      body: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          rail.currentState?.refreshMetrics();
          return false;
        },
        child: Stack(
          key: viewport,
          children: [
            SingleChildScrollView(
              controller: controller,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: (event) =>
                    rail.currentState?.handlePointerSignal(event),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < 8; i++)
                      SizedBox(
                        key: sections[i],
                        height: [
                          300,
                          640,
                          230,
                          190,
                          190,
                          190,
                          290,
                          200,
                        ][i].toDouble(),
                        child: Text('Section $i'),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 8,
              width: 64,
              child: DesktopSettingsScrubber(
                key: rail,
                controller: controller,
                sectionKeys: sections,
                viewportKey: viewport,
                animationsEnabled: widget.animations,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

void main() {
  Future<_HarnessState> mount(
    WidgetTester tester, {
    bool animations = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, animations: animations));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets(
    'unfocused dots have consistent raster brightness at desktop scales',
    (tester) async {
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final scale in [1.0, 1.25, 1.5, 2.0]) {
        tester.view.devicePixelRatio = scale;
        tester.view.physicalSize = Size(800 * scale, 500 * scale);
        final harness = GlobalKey<_HarnessState>();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: _Harness(key: harness),
          ),
        );
        await tester.pumpAndSettle();
        harness.currentState!.controller.jumpTo(276);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 180));
        final centers = [
          for (var i = 4; i < 7; i++)
            tester.getCenter(
                  find.byKey(ValueKey('settings-section-dot-1-$i')),
                ) *
                scale,
        ];
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: scale);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int light(int x, int y) {
            final offset = (y * image.width + x) * 4;
            return bytes.getUint8(offset) +
                bytes.getUint8(offset + 1) +
                bytes.getUint8(offset + 2);
          }

          final brightness = <int>[];
          for (final center in centers) {
            var total = 0;
            final x = center.dx.round(), y = center.dy.round();
            for (var row = y - 3; row <= y + 3; row++) {
              final background = light(x - 8, row);
              for (var col = x - 3; col <= x + 3; col++) {
                total += (light(col, row) - background).clamp(0, 765);
              }
            }
            brightness.add(total);
          }
          brightness.sort();
          expect(brightness.first, greaterThan(0));
          expect(
            brightness.last / brightness.first,
            lessThan(1.06),
            reason:
                'Equally unfocused dots should not alternate bright/dark at scale $scale.',
          );
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('wheel is eased and consumed exactly once', (tester) async {
    final harness = await mount(tester);
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(400, 200),
        scrollDelta: Offset(0, 180),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(harness.controller.offset, greaterThan(0));
    expect(harness.controller.offset, lessThan(180));
    await tester.pumpAndSettle();
    expect(harness.controller.offset, closeTo(180, .01));
    expect(find.byKey(const ValueKey('settings-scroll-thumb')), findsNothing);
  });

  testWidgets('the app animation setting controls wheel and category motion', (
    tester,
  ) async {
    final harness = await mount(tester, animations: false);
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(400, 200),
        scrollDelta: Offset(0, 180),
      ),
    );
    await tester.pump();
    expect(harness.controller.offset, 180);
    await tester.tap(find.byKey(const ValueKey('settings-jump-appearance')));
    await tester.pumpAndSettle();
    expect(harness.controller.offset, 276);
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle rail fades and returns to rest within 650 milliseconds', (
    tester,
  ) async {
    final harness = await mount(tester);
    double span() =>
        tester
            .getCenter(find.byKey(const ValueKey('settings-jump-advanced')))
            .dy -
        tester
            .getCenter(find.byKey(const ValueKey('settings-jump-profile')))
            .dy;
    Future<void> frames(int milliseconds) async {
      for (var elapsed = 0; elapsed < milliseconds; elapsed += 10) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    final restingSpan = span();
    harness.controller.jumpTo(400);
    await tester.pump();
    await frames(400);
    expect(span(), greaterThan(restingSpan + 50));
    final dot = find.byKey(const ValueKey('settings-section-dot-1-0'));
    double opacity() => tester
        .widget<Opacity>(
          find.ancestor(of: dot, matching: find.byType(Opacity)).first,
        )
        .opacity;
    expect(opacity(), greaterThan(.9));
    await frames(250);
    expect(span(), closeTo(restingSpan, .01));
    expect(opacity(), 0);
  });

  testWidgets('scroll resumption and held drag cancel idle collapse', (
    tester,
  ) async {
    final harness = await mount(tester);
    double span() =>
        tester
            .getCenter(find.byKey(const ValueKey('settings-jump-advanced')))
            .dy -
        tester
            .getCenter(find.byKey(const ValueKey('settings-jump-profile')))
            .dy;
    Future<void> frames(int milliseconds) async {
      for (var elapsed = 0; elapsed < milliseconds; elapsed += 10) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    final restingSpan = span();
    harness.controller.jumpTo(400);
    await tester.pump();
    await frames(500);
    harness.controller.jumpTo(410);
    await tester.pump();
    await frames(200);
    expect(span(), greaterThan(restingSpan + 50));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('settings-jump-appearance'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await frames(700);
    expect(span(), greaterThan(restingSpan + 50));
    expect(find.byKey(const ValueKey('settings-drag-dot')), findsOneWidget);
    await gesture.cancel();
    await tester.pump();
    await frames(650);
    expect(span(), closeTo(restingSpan, .01));
    expect(find.byKey(const ValueKey('settings-drag-dot')), findsNothing);
  });

  testWidgets('dot stays under pointer while temporary pin redistributes', (
    tester,
  ) async {
    final harness = await mount(tester);
    harness.controller.jumpTo(350);
    await tester.pumpAndSettle();
    final appearance = find.byKey(const ValueKey('settings-jump-appearance'));
    final start = tester.getCenter(appearance);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 32));
    await tester.pump();
    final dot = find.byKey(const ValueKey('settings-drag-dot'));
    expect(tester.getCenter(dot).dy, closeTo(start.dy + 32, .01));
    final content = harness.controller.offset;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getCenter(dot).dy, closeTo(start.dy + 32, .01));
    expect(harness.controller.offset, closeTo(content, .01));
    await tester.pump(const Duration(milliseconds: 180));
    final centers = [
      for (final section in DesktopSettingsScrubberState.sections)
        tester
            .getCenter(find.byKey(ValueKey('settings-jump-${section.$1}')))
            .dy,
    ];
    for (var i = 1; i < centers.length; i++) {
      expect(centers[i] - centers[i - 1], greaterThanOrEqualTo(47.9));
    }
    await gesture.moveBy(const Offset(0, -8));
    await tester.pump();
    expect(tester.getCenter(dot).dy, closeTo(start.dy + 24, .01));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fading section dots keep their own progress across checkpoints',
    (tester) async {
      final harness = await mount(tester);
      double dotWidth(int index) => tester
          .getSize(find.byKey(ValueKey('settings-section-dot-1-$index')))
          .width;
      harness.controller.jumpTo(915);
      await tester.pumpAndSettle();
      expect(dotWidth(6), greaterThan(dotWidth(0)));
      harness.controller.jumpTo(917);
      await tester.pump();
      expect(
        dotWidth(6),
        greaterThan(dotWidth(0)),
        reason: 'The outgoing Appearance dots must not restart at the top.',
      );
      harness.controller.jumpTo(915);
      await tester.pump();
      expect(
        dotWidth(6),
        greaterThan(dotWidth(0)),
        reason: 'Upward entry into Appearance starts at its bottom.',
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'upward drag enters the previous section at its bottom and keeps it on release',
    (tester) async {
      final harness = await mount(tester);
      harness.controller.jumpTo(1000);
      await tester.pumpAndSettle();
      final start = tester.getCenter(
        find.byKey(const ValueKey('settings-jump-notifications')),
      );
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 280));
      await gesture.moveTo(start - const Offset(0, 4));
      await tester.pump();
      final progress = find.byKey(const ValueKey('settings-section-progress'));
      expect(tester.getSemantics(progress).label, 'Appearance, remaining');
      expect(tester.getSemantics(progress).value, '0');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getSemantics(progress).label, 'Appearance, remaining');
      expect(tester.getSemantics(progress).value, '0');
    },
  );

  testWidgets('checkpoint handoff cannot skip on a stationary pointer', (
    tester,
  ) async {
    final harness = await mount(tester);
    harness.controller.jumpTo(350);
    await tester.pumpAndSettle();
    final start = tester.getCenter(
      find.byKey(const ValueKey('settings-jump-appearance')),
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 280));
    final next = tester.getCenter(
      find.byKey(const ValueKey('settings-jump-notifications')),
    );
    await gesture.moveTo(Offset(start.dx, next.dy + 3));
    await tester.pump();
    final scroll = harness.controller.offset;
    final selected = tester.getSemantics(
      find.byKey(const ValueKey('settings-section-progress')),
    );
    expect(selected.label, 'Notifications, remaining');
    expect(selected.value, '100');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.controller.offset, closeTo(scroll, .01));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('settings-section-progress')))
          .label,
      'Notifications, remaining',
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
