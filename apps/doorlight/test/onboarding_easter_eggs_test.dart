import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/doorlight_brand.dart';
import 'package:sybl/ui/playful_door.dart';
import 'package:sybl/ui/onboarding_surface.dart';
import 'package:sybl/ui/spinning_word.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'InstrumentSerif': 'assets/fonts/InstrumentSerif-Italic.ttf',
      'Pacifico': 'assets/fonts/Pacifico-Regular.ttf',
      'Anton': 'assets/fonts/Anton-Regular.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  Future<void> open(WidgetTester tester, {bool reduced = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Material(
            child: Center(
              child: RepaintBoundary(
                key: const ValueKey('egg-surface'),
                child: Material(
                  child: SizedBox(
                    width: 350,
                    height: 260,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const PlayfulDoor(
                          size: 130,
                          openness: 1.4,
                          illumination: 1,
                          thresholdPhase: .5,
                        ),
                        const SizedBox(height: 16),
                        SpinningWord(
                          words: const ['chatting', 'vibing', 'memeing'],
                          style: const TextStyle(fontSize: 26, height: 1.2),
                          styles: const [
                            TextStyle(
                              fontFamily: 'InstrumentSerif',
                              fontSize: 32,
                            ),
                            TextStyle(fontFamily: 'Pacifico', fontSize: 26),
                            TextStyle(fontFamily: 'Anton', fontSize: 26),
                          ],
                          strutStyle: StrutStyle.fromTextStyle(
                            const TextStyle(fontSize: 26, height: 1.2),
                            forceStrutHeight: true,
                          ),
                          running: true,
                          interactive: true,
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
  }

  DoorlightDoorMark mark(WidgetTester tester) =>
      tester.widget(find.byType(DoorlightDoorMark));

  Future<void> capture(WidgetTester tester, String name) async {
    const dir = String.fromEnvironment('EGG_CAPTURE_DIR');
    if (dir.isEmpty) return;
    await tester.runAsync(() async {
      final surface = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('egg-surface')),
      );
      final image = await surface.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$dir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('door slams, flickers and reopens without moving the reel', (
    tester,
  ) async {
    await open(tester);
    final reel = find.byKey(const ValueKey('spinning-word'));
    final bounds = tester.getRect(reel);
    await tester.tap(find.byType(PlayfulDoor));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(mark(tester).openness, 0);
    await capture(tester, 'door-closed');
    final dim = mark(tester).illumination!;
    await tester.pump(const Duration(milliseconds: 240));
    expect(mark(tester).openness, 0);
    expect(mark(tester).illumination, greaterThan(dim));
    await capture(tester, 'door-flicker');
    await tester.pump(const Duration(milliseconds: 550));
    expect(mark(tester).openness, inExclusiveRange(0, 1.4));
    await capture(tester, 'door-reopening');
    await tester.pump(const Duration(milliseconds: 500));
    expect(mark(tester).openness, closeTo(1.4, .001));
    expect(mark(tester).illumination, 1);
    expect(tester.getRect(reel), bounds);
    await capture(tester, 'door-open');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('spam ramps the reel up then idle time restores normal speed', (
    tester,
  ) async {
    await open(tester);
    final target = find.byType(SpinningWord);
    String word() => tester
        .widget<Text>(
          find.descendant(of: target, matching: find.byType(Text)).last,
        )
        .data!;
    for (var i = 0; i < 24; i++) {
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 16));
    }
    var changes = 0;
    var last = word();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (word() != last) changes++;
      last = word();
      if (frame == 10) await capture(tester, 'reel-turbo');
      expect(tester.takeException(), isNull);
    }
    expect(changes, greaterThanOrEqualTo(7));
    for (var frame = 0; frame < 250; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    changes = 0;
    last = word();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (word() != last) changes++;
      last = word();
    }
    expect(changes, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a knock interrupts reopening from its current angle', (
    tester,
  ) async {
    await open(tester);
    final door = find.byType(PlayfulDoor);
    await tester.tap(door);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    final angle = mark(tester).openness;
    expect(angle, inExclusiveRange(0, 1.4));
    await tester.tap(door);
    await tester.pump();
    expect(mark(tester).openness, closeTo(angle, .001));
    await tester.pump(const Duration(milliseconds: 150));
    expect(mark(tester).openness, 0);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(mark(tester).openness, 1.4);
    for (final detector in tester.widgetList<FocusableActionDetector>(
      find.byType(FocusableActionDetector),
    )) {
      expect(detector.mouseCursor, SystemMouseCursors.basic);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('few reel clicks give a modest boost', (tester) async {
    await open(tester);
    final target = find.byType(SpinningWord);
    for (var i = 0; i < 4; i++) {
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 16));
    }
    String word() => tester
        .widget<Text>(
          find.descendant(of: target, matching: find.byType(Text)).last,
        )
        .data!;
    final initial = word();
    await tester.pump(const Duration(milliseconds: 650));
    expect(word(), initial);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Offset handle(WidgetTester tester) {
    final door = mark(tester);
    return tester.getTopLeft(find.byType(DoorlightDoorMark)) +
        DoorlightDoorMark.handlePosition(door.openness) * (door.size / 100);
  }

  Future<int?> leftFloorLight(WidgetTester tester) => tester.runAsync(() async {
    final point =
        tester.getTopLeft(find.byType(DoorlightDoorMark)) +
        Offset(mark(tester).size * .1, mark(tester).size * .82) -
        tester.getTopLeft(find.byKey(const ValueKey('egg-surface')));
    final surface = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('egg-surface')),
    );
    final image = await surface.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return bytes!.getUint8(
        (point.dy.round() * image.width + point.dx.round()) * 4,
      );
    } finally {
      image.dispose();
    }
  });

  testWidgets('a stationary press stays a click even after a long wait', (
    tester,
  ) async {
    await open(tester);
    final press = await tester.startGesture(handle(tester));
    await tester.pump(const Duration(seconds: 1));
    expect(mark(tester).openness, 1.4);
    await press.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(mark(tester).openness, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('immediate drag can open an initially closed door', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: const Material(
          child: Center(
            child: PlayfulDoor(
              size: 130,
              openness: 0,
              illumination: 1,
              thresholdPhase: .5,
            ),
          ),
        ),
      ),
    );
    final pointer = await tester.startGesture(handle(tester));
    await pointer.moveBy(const Offset(-200, 0));
    await tester.pump();
    expect(mark(tester).openness, DoorlightDoorMark.maxOpenness);
    await pointer.up();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'immediate drag reaches 180 degrees and slowly returns without a slam',
    (tester) async {
      await open(tester);
      final pointer = await tester.startGesture(handle(tester));
      expect(mark(tester).openness, 1.4);
      await pointer.moveBy(const Offset(26, 0));
      await tester.pump();
      expect(mark(tester).openness, closeTo(.7, .01));
      final angle = mark(tester).openness;
      await pointer.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(mark(tester).openness, inExclusiveRange(angle, 1.4));
      await tester.pump(const Duration(milliseconds: 2000));
      expect(mark(tester).openness, 1.4);
      final close = await tester.startGesture(handle(tester));
      await close.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(mark(tester).openness, 0);
      await close.up();
      final reopen = await tester.startGesture(handle(tester));
      await reopen.moveBy(const Offset(-200, 0));
      await tester.pump();
      expect(mark(tester).openness, DoorlightDoorMark.maxOpenness);
      // The completed left side of the cone remains visible after opening.
      expect(
        await leftFloorLight(tester),
        greaterThan((Warm.cozy.bg.r * 255).round() + 30),
      );
      await capture(tester, 'door-180');
      await reopen.up();
      await tester.tapAt(handle(tester));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(mark(tester).openness, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'handle drag interrupts reopening; other drags do not move the door',
    (tester) async {
      await open(tester);
      await tester.tap(find.byType(PlayfulDoor));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      final pointer = await tester.startGesture(handle(tester));
      await pointer.moveBy(const Offset(-26, 0));
      await tester.pump();
      final angle = mark(tester).openness;
      expect(angle, inExclusiveRange(0, 1.4));
      await tester.pump(const Duration(milliseconds: 600));
      expect(mark(tester).openness, angle);
      await pointer.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2500));
      expect(mark(tester).openness, 1.4);
      final other = await tester.startGesture(
        tester.getTopLeft(find.byType(PlayfulDoor)) + const Offset(5, 5),
      );
      await other.moveBy(const Offset(100, 0));
      await other.up();
      await tester.pump();
      expect(mark(tester).openness, 1.4);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('mouse can catch the door during its slow return', (
    tester,
  ) async {
    await open(tester);
    final drag = await tester.startGesture(
      handle(tester),
      kind: ui.PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(-200, 0));
    await tester.pump();
    expect(mark(tester).openness, DoorlightDoorMark.maxOpenness);
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final returning = mark(tester).openness;
    expect(returning, inExclusiveRange(1.4, DoorlightDoorMark.maxOpenness));
    final catchDoor = await tester.startGesture(
      handle(tester),
      kind: ui.PointerDeviceKind.mouse,
    );
    await catchDoor.moveBy(const Offset(-3, 0));
    await tester.pump();
    final caught = mark(tester).openness;
    expect(caught, inExclusiveRange(returning, DoorlightDoorMark.maxOpenness));
    await tester.pump(const Duration(milliseconds: 400));
    expect(mark(tester).openness, caught);
    await catchDoor.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2400));
    expect(mark(tester).openness, 1.4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('knocks escalate content shake, then window shake, and stop', (
    tester,
  ) async {
    final commands = <bool>[];
    Widget surface(bool disabled) => MaterialApp(
      theme: Warm.theme(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disabled),
        child: OnboardingSurface(
          onWindowShake: commands.add,
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
    );
    await tester.pumpWidget(surface(false));
    final door = find.byType(PlayfulDoor);
    double displacement() => tester
        .widget<Transform>(
          find.byKey(const ValueKey('onboarding-content-shake')),
        )
        .transform
        .storage[12]
        .abs();
    await tester.tap(door);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));
    final first = displacement();
    expect(first, greaterThan(0));
    for (var i = 0; i < 6; i++) {
      await tester.tap(door);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(displacement(), greaterThan(first));
    expect(commands, isEmpty);
    await tester.tap(door);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(commands, [true]);
    await tester.pumpWidget(surface(true));
    expect(commands, [true, false]);
    expect(displacement(), 0);
    await tester.tap(door);
    await tester.pump(const Duration(seconds: 3));
    expect(commands, [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyboard activates door; reduced motion skips both eggs', (
    tester,
  ) async {
    await open(tester);
    FocusScope.of(tester.element(find.byType(PlayfulDoor))).nextFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(mark(tester).openness, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, reduced: true);
    await tester.tap(find.byType(PlayfulDoor));
    await tester.tap(find.byType(SpinningWord));
    await tester.pump(const Duration(seconds: 6));
    expect(mark(tester).openness, 1.4);
    expect(find.text('chatting'), findsOneWidget);
    expect(find.text('vibing'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
