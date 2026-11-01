import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/onboarding_surface.dart';
import 'package:sybl/ui/playful_door.dart';

void main() {
  testWidgets('original broad light follows the door after layout moves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const surface = ValueKey('light-capture');
    Widget scene(double left, double top) => MaterialApp(
      theme: Warm.theme(),
      home: RepaintBoundary(
        key: surface,
        child: OnboardingSurface(
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: PlayfulDoor(
                    size: 100,
                    openness: 0,
                    illumination: 0,
                    thresholdPhase: .5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Future<int> redAt(int x, int y) => tester
        .runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(surface),
          );
          final image = await boundary.toImage();
          try {
            final pixels = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return pixels!.getUint8((y * image.width + x) * 4);
          } finally {
            image.dispose();
          }
        })
        .then((value) => value!);
    final background = (Warm.cozy.bg.r * 255).round();
    await tester.pumpWidget(scene(80, 130));
    // These points are above the door, clear of its leaf and floor light.
    expect(
      await redAt(130, 66),
      inInclusiveRange(background + 12, background + 18),
    );
    expect(await redAt(410, 166), lessThanOrEqualTo(background + 8));
    await tester.pumpWidget(scene(360, 230));
    expect(
      await redAt(410, 166),
      inInclusiveRange(background + 12, background + 18),
    );
    expect(await redAt(130, 66), lessThanOrEqualTo(background + 8));
    expect(tester.takeException(), isNull);
  });
}
