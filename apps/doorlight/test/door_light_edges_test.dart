import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/doorlight_brand.dart';

void main() {
  testWidgets('edge-on leaf stays within the doorway height', (tester) async {
    final restingAngle = math.acos((45 - 8 * 1.4) / 45);
    final edgeOn = 1.4 + math.pi / 2 - restingAngle;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('edge-on-door'),
            child: ColoredBox(
              color: Warm.cozy.bg,
              child: DoorlightDoorMark(
                size: 400,
                openness: edgeOn,
                illumination: 1,
              ),
            ),
          ),
        ),
      ),
    );
    final pixels = await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('edge-on-door')),
          )
          .toImage();
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    });
    // The leaf should disappear into the jamb rather than protrude above it.
    expect(pixels!.getUint8((40 * 400 + 108) * 4), lessThan(80));
  });

  testWidgets('door paint remains inside its declared bounds in every pose', (
    tester,
  ) async {
    for (final openness in [0.0, 1.4, 2.7, DoorlightDoorMark.maxOpenness]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Center(child: DoorlightDoorMark(size: 200, openness: openness)),
        ),
      );
      final painted = find.descendant(
        of: find.byType(DoorlightDoorMark),
        matching: find.byType(CustomPaint),
      );
      final painter = tester.widget<CustomPaint>(painted).painter!;
      final size = tester.getSize(painted);
      Future<Uint8List> raster(bool clipped) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..translate(80, 80);
        if (clipped) canvas.clipRect(Offset.zero & size);
        painter.paint(canvas, size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.ceil() + 160,
          size.height.ceil() + 160,
        );
        try {
          return (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
        } finally {
          image.dispose();
          picture.dispose();
        }
      }

      final same = await tester.runAsync(() async {
        final unclipped = await raster(false);
        final clipped = await raster(true);
        return listEquals(unclipped, clipped);
      });
      expect(
        same,
        isTrue,
        reason: 'paint escapes canvas at openness $openness',
      );
    }
  });

  testWidgets('left floor light fills the fixed outline with a blurred edge', (
    tester,
  ) async {
    const surface = ValueKey('left-door-light-surface');
    const width = 560;
    for (final openness in [2.7, DoorlightDoorMark.maxOpenness]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Center(
            child: RepaintBoundary(
              key: surface,
              child: ColoredBox(
                color: Warm.cozy.bg,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 80),
                  child: DoorlightDoorMark(
                    size: 400,
                    openness: openness,
                    illumination: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(surface),
      );
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          const dir = String.fromEnvironment('CONE_CAPTURE_DIR');
          if (dir.isNotEmpty) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$dir/left-$openness.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          }
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      final background = pixels!.getUint8(0);
      int red(int x, int y) => pixels.getUint8((y * width + x) * 4);
      if (openness == DoorlightDoorMark.maxOpenness) {
        // Fill the outlined area between the jamb and the fixed outer curve,
        // with a soft left boundary rather than following the leaf's corner.
        // The extension uses the original radial fade, without an extra edge fade.
        expect(red(104, 308), greaterThan(background + 80));
        expect(red(120, 308), greaterThan(background + 30));
        expect(red(96, 308), lessThan(red(120, 308)));
        expect(red(120, 308), lessThan(red(144, 308)));
        expect(red(28, 308), background);
        expect(red(40, 320), background);
      } else {
        expect(red(144, 320), greaterThan(background + 30));
        // At a partial opening, light must continue smoothly across the join.
        expect((red(150, 328) - red(148, 328)).abs(), lessThan(8));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing cone stays fixed while its left side is revealed', (
    tester,
  ) async {
    const surface = ValueKey('door-light-edge-surface');
    const size = 400;
    final edges = <List<int>>[];
    final fixedFloor = <List<int>>[];
    final poses = [
      0.0,
      1.4,
      (1.4 + DoorlightDoorMark.maxOpenness) / 2,
      DoorlightDoorMark.maxOpenness,
    ];
    for (var pose = 0; pose < poses.length; pose++) {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Center(
            child: RepaintBoundary(
              key: surface,
              child: ColoredBox(
                color: Warm.cozy.bg,
                child: DoorlightDoorMark(
                  size: size.toDouble(),
                  openness: poses[pose],
                  illumination: 1,
                  thresholdPhase: 0,
                ),
              ),
            ),
          ),
        ),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(surface),
      );
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          const dir = String.fromEnvironment('CONE_CAPTURE_DIR');
          if (dir.isNotEmpty) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$dir/pose-$pose.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          }
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      if (pose == 0) continue;
      fixedFloor.add([
        for (var y = 360; y < 396; y++)
          for (var x = 0; x < 400; x++)
            for (var channel = 0; channel < 4; channel++)
              pixels!.getUint8((y * size + x) * 4 + channel),
      ]);
      final background = pixels!.getUint8(0);
      edges.add([
        for (final y in [320, 328, 336, 344])
          [
            for (var x = 288; x < size; x++)
              if (pixels.getUint8((y * size + x) * 4) > background + 3) x,
          ].last,
      ]);
    }
    for (final poseEdges in edges.skip(1)) {
      for (var row = 0; row < poseEdges.length; row++) {
        expect(poseEdges[row], closeTo(edges.first[row], 1));
      }
    }
    for (final floor in fixedFloor.skip(1)) {
      expect(
        listEquals(floor, fixedFloor.first),
        isTrue,
        reason: 'Opening the leaf must not move or reshape the existing spill',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
