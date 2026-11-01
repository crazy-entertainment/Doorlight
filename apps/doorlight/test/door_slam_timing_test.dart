import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/doorlight_brand.dart';
import 'package:sybl/ui/onboarding_surface.dart';
import 'package:sybl/ui/playful_door.dart';

void main() {
  final door = find.byType(PlayfulDoor);
  DoorlightDoorMark mark(WidgetTester tester) =>
      tester.widget(find.byType(DoorlightDoorMark));
  Offset handle(WidgetTester tester) =>
      tester.getTopLeft(find.byType(DoorlightDoorMark)) +
      DoorlightDoorMark.handlePosition(mark(tester).openness) * 1.3;
  double shake(WidgetTester tester) => tester
      .widget<Transform>(find.byKey(const ValueKey('onboarding-content-shake')))
      .transform
      .storage[12];

  Future<void> open(WidgetTester tester, List<int> impacts) =>
      tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: OnboardingSurface(
            child: NotificationListener<DoorKnockNotification>(
              onNotification: (event) {
                expect(mark(tester).openness, 0);
                impacts.add(event.count);
                return false;
              },
              child: const Center(
                child: PlayfulDoor(
                  size: 130,
                  openness: 1.4,
                  illumination: 1,
                  thresholdPhase: .5,
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('fully open door shakes only after it closes', (tester) async {
    final impacts = <int>[];
    await open(tester, impacts);
    final drag = await tester.startGesture(handle(tester));
    await drag.moveBy(const Offset(-200, 0));
    await tester.pump();
    expect(mark(tester).openness, DoorlightDoorMark.maxOpenness);
    await drag.up();
    await tester.tapAt(handle(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    expect(mark(tester).openness, greaterThan(0));
    expect(impacts, isEmpty);
    expect(shake(tester), 0);
    await tester.pump(const Duration(milliseconds: 11));
    expect(mark(tester).openness, 0);
    expect(impacts, [1]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(shake(tester), isNot(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(impacts, [1]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('grabbing a closing door cancels its pending impact', (
    tester,
  ) async {
    final impacts = <int>[];
    await open(tester, impacts);
    await tester.tap(door);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final drag = await tester.startGesture(handle(tester));
    await drag.moveBy(const Offset(-20, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(mark(tester).openness, greaterThan(0));
    expect(impacts, isEmpty);
    expect(shake(tester), 0);
    await drag.up();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final movement in [
    (
      name: 'fast rightward',
      firstDx: -3.0,
      dx: 80.0,
      milliseconds: 20,
      slams: true,
    ),
    (
      name: 'short fast rightward',
      firstDx: -3.0,
      dx: 24.0,
      milliseconds: 5,
      slams: false,
    ),
    (
      name: 'ordinary rightward',
      firstDx: -3.0,
      dx: 24.0,
      milliseconds: 20,
      slams: false,
    ),
    (
      name: 'slow rightward',
      firstDx: -3.0,
      dx: 80.0,
      milliseconds: 200,
      slams: false,
    ),
    (
      name: 'fast leftward',
      firstDx: -3.0,
      dx: -48.0,
      milliseconds: 20,
      slams: false,
    ),
    (
      name: 'fast rightward after closing',
      firstDx: 100.0,
      dx: 80.0,
      milliseconds: 20,
      slams: true,
    ),
  ]) {
    testWidgets('${movement.name} mouse drag slam behavior', (tester) async {
      final impacts = <int>[];
      await open(tester, impacts);
      final drag = await tester.startGesture(
        handle(tester),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(
        Offset(movement.firstDx, 0),
        timeStamp: const Duration(milliseconds: 11),
      );
      await drag.moveBy(
        Offset(movement.dx, 0),
        timeStamp: Duration(milliseconds: 11 + movement.milliseconds),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 141));
      expect(impacts, movement.slams ? [1] : isEmpty);
      if (movement.slams) {
        expect(mark(tester).openness, 0);
        // Continuing to move while held must not start a second impact.
        await drag.moveBy(
          const Offset(24, 0),
          timeStamp: const Duration(milliseconds: 300),
        );
      }
      await drag.up(timeStamp: const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(impacts, movement.slams ? [1] : isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final dx in [4.0, 20.0]) {
    testWidgets('fast mouse samples of $dx pixels require enough travel', (
      tester,
    ) async {
      final impacts = <int>[];
      await open(tester, impacts);
      final drag = await tester.startGesture(
        handle(tester),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(
        const Offset(-3, 0),
        timeStamp: const Duration(milliseconds: 11),
      );
      for (var i = 1; i <= 4; i++) {
        await drag.moveBy(
          Offset(dx, 0),
          timeStamp: Duration(milliseconds: 11 + i * (dx / 4).round()),
        );
      }
      // Releasing immediately must not bypass the minimum travel requirement.
      await drag.up(timeStamp: Duration(milliseconds: 12 + dx.round()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 141));
      expect(impacts, dx == 20 ? [1] : isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
