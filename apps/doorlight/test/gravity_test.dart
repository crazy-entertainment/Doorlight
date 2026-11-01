import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/gravity.dart';

void main() {
  final sounds = <(String, double)>[];
  setUp(() {
    sounds.clear();
    gravityImpactSound = (asset, volume) => sounds.add((asset, volume));
  });
  tearDown(() => gravityMode.value = false);

  Future<void> settle(WidgetTester tester, {int frames = 400}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a clipped piece falls to the window bottom and stays usable', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ClipRect(
              child: SizedBox(
                height: 60,
                child: Gravity(
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('Call'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final start = tester.getRect(find.text('Call'));

    gravityMode.value = true;
    await tester.pump();
    expect(tester.getRect(find.text('Call')), start);
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final fallen = tester.getCenter(find.text('Call'));
    expect(fallen.dy, greaterThan(500));
    await tester.tapAt(fallen);
    expect(taps, 1);

    gravityMode.value = false;
    await tester.pump();
    expect(tester.getRect(find.text('Call')), start);
    await tester.tap(find.text('Call'));
    expect(taps, 2);
  });

  testWidgets('a piece keeps its own state while fallen and after return', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Gravity(child: _Counter())),
      ),
    );
    await tester.tap(find.text('0'));
    await tester.pump();

    gravityMode.value = true;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getCenter(find.text('1')).dy, greaterThan(500));
    await tester.tap(find.text('1'));
    await tester.pump();

    gravityMode.value = false;
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
  });
  testWidgets('a piece nested in another piece rides along with it', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Gravity(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('bubble'),
                Gravity(child: Text('receipt')),
              ],
            ),
          ),
        ),
      ),
    );
    gravityMode.value = true;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getTopLeft(find.text('bubble')).dy, greaterThan(500));
    expect(gravityDebug().bodies, 1);
  });
  testWidgets('a piece under IgnorePointer stays untappable after falling', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IgnorePointer(
            child: Gravity(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('Locked'),
              ),
            ),
          ),
        ),
      ),
    );
    gravityMode.value = true;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final fallen = tester.getCenter(find.text('Locked'));
    expect(fallen.dy, greaterThan(500));
    await tester.tapAt(fallen);
    expect(taps, 0);
  });

  testWidgets('two pieces at the same x stack without overlapping', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Gravity(
                child: SizedBox(width: 120, height: 40, child: Text('a')),
              ),
              Gravity(
                child: SizedBox(width: 120, height: 40, child: Text('b')),
              ),
            ],
          ),
        ),
      ),
    );
    gravityMode.value = true;
    await settle(tester);

    expect(gravityDebug().awake, 0);
    final a = tester.getRect(find.text('a'));
    final b = tester.getRect(find.text('b'));
    final low = a.bottom > b.bottom ? a : b, high = low == a ? b : a;
    expect(low.bottom, closeTo(600, 2.5));
    expect(high.bottom, lessThanOrEqualTo(low.top + 1));
    expect(high.bottom, greaterThan(low.top - 2));
    expect(a.intersect(b).height, lessThanOrEqualTo(1));
    expect(sounds, isNotEmpty);
  });

  testWidgets('weight scales body mass', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Gravity(
                key: ValueKey('heavy'),
                weight: 4,
                child: SizedBox(width: 50, height: 50),
              ),
              Gravity(
                key: ValueKey('light'),
                child: SizedBox(width: 50, height: 50),
              ),
              Gravity(key: ValueKey('text'), child: Text('word')),
            ],
          ),
        ),
      ),
    );
    gravityMode.value = true;
    await settle(tester, frames: 250);
    final masses = gravityDebug().masses;
    expect(
      masses[const ValueKey('heavy')]! / masses[const ValueKey('light')]!,
      closeTo(4, .01),
    );
    final word = tester.getSize(find.text('word'));
    expect(
      masses[const ValueKey('text')]!,
      closeTo(.5 * word.width * word.height / 1e4, 1e-6),
    );
  });

  testWidgets('a new message enters from below and lifts the pile', (
    tester,
  ) async {
    final show = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Gravity(
                child: SizedBox(width: 300, height: 60, child: Text('old')),
              ),
              ValueListenableBuilder(
                valueListenable: show,
                builder: (_, show, _) => show
                    ? const Gravity(
                        entry: GravityEntry.fromBelow,
                        child: SizedBox(
                          width: 200,
                          height: 50,
                          child: Text('new'),
                        ),
                      )
                    : const SizedBox(),
              ),
            ],
          ),
        ),
      ),
    );
    gravityMode.value = true;
    await settle(tester);
    expect(tester.getRect(find.text('old')).bottom, closeTo(600, 2.5));

    show.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(find.text('new')).top, greaterThanOrEqualTo(599));
    await settle(tester);

    final enteredRect = tester.getRect(find.text('new'));
    final old = tester.getRect(find.text('old'));
    expect(enteredRect.bottom, closeTo(600, 2.5));
    expect(old.bottom, lessThanOrEqualTo(enteredRect.top + 1));
    expect(gravityDebug().awake, 0);
  });

  testWidgets('a fallen text field takes focus and typing', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: Gravity(
                child: TextField(controller: controller, focusNode: focus),
              ),
            ),
          ),
        ),
      ),
    );
    gravityMode.value = true;
    await settle(tester);
    expect(tester.getCenter(find.byType(TextField)).dy, greaterThan(500));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), 'hello');
    expect(controller.text, 'hello');
  });

  testWidgets('300 pieces settle and fall asleep', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: [
              for (var i = 0; i < 300; i++)
                Gravity(child: SizedBox(width: 20 + i % 5 * 6.0, height: 14)),
            ],
          ),
        ),
      ),
    );
    gravityRandom = math.Random(7);
    final before = gravityDebug();
    gravityMode.value = true;
    var frames = 0;
    // 3 s of staggered drops, then at most 12 s to come to rest.
    await settle(tester, frames: 190);
    while (gravityDebug().awake > 0 && frames < 750) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    final after = gravityDebug();
    expect(after.bodies, 300);
    expect(after.awake, 0);
    final steps = after.steps - before.steps;
    // ignore: avoid_print
    print(
      '300 pieces asleep ${frames * 16} ms after the last drop; '
      'mean step ${(after.stepMicros - before.stepMicros) ~/ steps} us',
    );
    gravityMode.value = false;
    await tester.pump();
    expect(gravityDebug().bodies, 0);
  });

  group('usable area', () {
    Future<void> fall(WidgetTester tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Gravity(
                child: SizedBox(width: 120, height: 40, child: Text('p')),
              ),
            ),
          ),
        ),
      );
      gravityMode.value = true;
      await settle(tester);
    }

    testWidgets('a fallen piece rests above the keyboard and nav bar', (
      tester,
    ) async {
      tester.view
        ..viewPadding = const FakeViewPadding(top: 24, bottom: 48)
        ..viewInsets = const FakeViewPadding(bottom: 300);
      await fall(tester);
      expect(tester.getRect(find.text('p')).bottom, closeTo(300, 2.5));
    });

    testWidgets('an opening keyboard lifts the pile and its close drops it', (
      tester,
    ) async {
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      await fall(tester);
      expect(tester.getRect(find.text('p')).bottom, closeTo(552, 2.5));
      expect(gravityDebug().awake, 0);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await settle(tester, frames: 120);
      expect(tester.getRect(find.text('p')).bottom, closeTo(300, 2.5));

      tester.view.resetViewInsets();
      await settle(tester, frames: 120);
      expect(tester.getRect(find.text('p')).bottom, closeTo(552, 2.5));
    });

    testWidgets('upward sensor gravity piles pieces under the status bar', (
      tester,
    ) async {
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
      await fall(tester);
      expect(gravityDebug().awake, 0);

      gravitySensorSample(0, -9.8);
      await settle(tester, frames: 150);
      expect(tester.getRect(find.text('p')).top, closeTo(24, 2.5));
    });
  });

  group('dragging', () {
    Future<void> land(WidgetTester tester, List<Widget> pieces) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: pieces),
            ),
          ),
        ),
      );
      gravityMode.value = true;
      await settle(tester);
    }

    const box = Gravity(
      child: SizedBox(width: 100, height: 40, child: Text('box')),
    );

    testWidgets('a dragged piece follows the pointer and falls on release', (
      tester,
    ) async {
      await land(tester, [box]);
      final rest = tester.getRect(find.text('box'));
      expect(rest.bottom, closeTo(600, 2.5));

      final gesture = await tester.startGesture(rest.center);
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(10, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester, frames: 60);
      final held = tester.getCenter(find.text('box'));
      expect(held.dx, closeTo(rest.center.dx + 200, 15));
      expect(held.dy, closeTo(rest.center.dy - 200, 15));
      expect(gravityDebug().awake, 1);

      await gesture.up();
      await settle(tester);
      expect(tester.getRect(find.text('box')).bottom, closeTo(600, 2.5));
      expect(gravityDebug().awake, 0);
    });

    testWidgets('a fling up throws the piece before it falls back', (
      tester,
    ) async {
      await land(tester, [box]);
      final rest = tester.getRect(find.text('box'));
      await tester.fling(find.text('box'), const Offset(0, -100), 3000);
      var top = rest.top;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        top = math.min(top, tester.getRect(find.text('box')).top);
      }
      expect(top, lessThan(rest.top - 150));
      await settle(tester);
      expect(tester.getRect(find.text('box')).bottom, closeTo(600, 2.5));
    });

    testWidgets('a tap on a fallen button fires once and leaves it put', (
      tester,
    ) async {
      var taps = 0;
      await land(tester, [
        Gravity(
          child: TextButton(onPressed: () => taps++, child: const Text('Tap')),
        ),
      ]);
      final rest = tester.getRect(find.text('Tap'));
      await tester.tap(find.text('Tap'));
      await settle(tester, frames: 30);
      expect(taps, 1);
      expect(tester.getRect(find.text('Tap')), rest);
      expect(gravityDebug().awake, 0);
    });

    testWidgets('a dragged piece pushes its neighbour', (tester) async {
      await land(tester, [
        box,
        const SizedBox(width: 60),
        const Gravity(
          child: SizedBox(width: 100, height: 40, child: Text('other')),
        ),
      ]);
      final mine = tester.getRect(find.text('box'));
      final other = tester.getRect(find.text('other'));
      expect(other.left - mine.right, closeTo(60, 3));

      final gesture = await tester.startGesture(mine.center);
      for (var i = 0; i < 30; i++) {
        await gesture.moveBy(const Offset(8, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await settle(tester);

      final pushed = tester.getRect(find.text('other'));
      expect(pushed.left, greaterThan(other.left + 50));
      final now = tester.getRect(find.text('box'));
      final overlap = now.intersect(pushed);
      expect(
        overlap.width <= 1 || overlap.height <= 1,
        isTrue,
        reason: '$now overlaps $pushed',
      );
      expect(gravityDebug().awake, 0);
    });
  });

  testWidgets('a crowded sidebar settles with no piece inside another', (
    tester,
  ) async {
    // Slow frames (30 fps) on a tall window, as on a busy desktop.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.reset);
    Widget row(int i) => Stack(
      children: [
        Positioned.fill(
          child: Gravity(
            child: ColoredBox(color: i.isEven ? Colors.grey : Colors.white),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(7),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 42,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Gravity(
                      weight: 3,
                      child: SizedBox.square(dimension: 38),
                    ),
                    // Name text laid out over the avatar's corner.
                    Positioned(
                      left: 30,
                      top: 24,
                      child: Gravity(child: Text('Friend $i')),
                    ),
                    const Positioned(
                      right: -2,
                      bottom: -1,
                      child: Gravity(child: SizedBox(width: 18, height: 18)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 60),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Gravity(
                      child: Text('online', style: TextStyle(fontSize: 11)),
                    ),
                    Gravity(child: Text('now', style: TextStyle(fontSize: 10))),
                  ],
                ),
              ),
              const Gravity(child: SizedBox.square(dimension: 8)),
            ],
          ),
        ),
      ],
    );
    for (final seed in [1, 2, 3]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                child: Column(children: [for (var i = 0; i < 15; i++) row(i)]),
              ),
            ),
          ),
        ),
      );
      gravityRandom = math.Random(seed);
      gravityMode.value = true;
      var frames = 0;
      while ((frames < 100 || gravityDebug().awake > 0) && frames < 900) {
        await tester.pump(const Duration(milliseconds: 33));
        frames++;
      }
      final shapes = gravityDebug().shapes;
      expect(shapes, hasLength(15 * 7));
      expect(gravityDebug().awake, 0, reason: 'seed $seed never settled');
      for (var i = 0; i < shapes.length; i++) {
        for (var j = i + 1; j < shapes.length; j++) {
          expect(
            _penetration(shapes[i], shapes[j]),
            lessThanOrEqualTo(1),
            reason: 'seed $seed: ${shapes[i]} overlaps ${shapes[j]}',
          );
        }
      }
      gravityMode.value = false;
      await tester.pump();
    }
  });

  group('reset', () {
    const reset = ValueKey('gravity-reset');
    final shift = ValueNotifier(0.0);
    tearDown(() => shift.value = 0);
    const names = ['first', 'second piece', 'third'];

    Future<Map<String, Rect>> land(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: shift,
              builder: (_, shift, _) => Padding(
                padding: EdgeInsets.only(left: 40 + shift, top: 30 + shift),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Gravity(child: Text('first')),
                    Gravity(child: Text('second piece')),
                    Padding(
                      padding: EdgeInsets.only(left: 100),
                      child: Gravity(child: Text('third')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final before = {for (final n in names) n: tester.getRect(find.text(n))};
      gravityMode.value = true;
      return before;
    }

    Map<String, Rect> rects(WidgetTester tester) => {
      for (final n in names) n: tester.getRect(find.text(n)),
    };

    void expectAt(Map<String, Rect> now, Map<String, Rect> spots, String when) {
      for (final n in names) {
        final (a, b) = (now[n]!, spots[n]!);
        for (final (x, y) in [
          (a.left, b.left),
          (a.top, b.top),
          (a.right, b.right),
          (a.bottom, b.bottom),
        ]) {
          expect(x, closeTo(y, .5), reason: '$n $when: $a vs $b');
        }
      }
    }

    /// Presses reset and runs the trip home; returns the rects on the last
    /// animated frame and the frame count.
    Future<(Map<String, Rect>, int, Rect)> goHome(WidgetTester tester) async {
      await tester.tap(find.byKey(reset));
      var frames = 0;
      var last = rects(tester);
      var middle = Rect.zero;
      while (gravityMode.value && frames < 100) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
        if (frames == 25) middle = tester.getRect(find.text('first'));
        if (gravityMode.value) last = rects(tester);
      }
      expect(gravityMode.value, isFalse);
      return (last, frames, middle);
    }

    testWidgets('the button shows after 3 s and carries pieces home', (
      tester,
    ) async {
      final before = await land(tester);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byKey(reset), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(reset), findsOneWidget);
      await settle(tester);
      final rest = tester.getRect(find.text('first'));
      expect(rest.bottom, greaterThan(500));
      // The button never falls.
      final button = tester.getRect(find.byKey(reset));
      expect(button.top, lessThan(20));
      expect(button.right, greaterThan(780));

      final (last, frames, middle) = await goHome(tester);
      // About 0.8 s in flight, passing between the pile and home.
      expect(frames, inInclusiveRange(49, 53));
      expect(middle.top, lessThan(rest.top - 20));
      expect(middle.top, greaterThan(before['first']!.top + 5));
      expectAt(last, before, 'on the last animated frame');
      expectAt(rects(tester), before, 'once handed back');
      await tester.pump(const Duration(milliseconds: 16));
      expectAt(rects(tester), before, 'a frame later');
      expect(find.byKey(reset), findsNothing);
      expect(gravityDebug().bodies, 0);
    });

    testWidgets('the hand-back to the layout is pixel-identical', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1.25
        ..physicalSize = const Size(1000, 750);
      addTearDown(tester.view.reset);
      const surface = ValueKey('surface');
      Widget bubble(String text) => Gravity(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.amber,
            border: Border.all(color: Colors.black26),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(text),
        ),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: ListView(
                padding: const EdgeInsets.fromLTRB(18.3, 17.7, 18.3, 0),
                children: [
                  for (final n in names)
                    Align(alignment: Alignment.centerLeft, child: bubble(n)),
                  const Gravity(child: Icon(Icons.settings_outlined)),
                ],
              ),
            ),
          ),
        ),
      );
      final region = names
          .map((n) => tester.getRect(find.text(n)).inflate(14))
          .reduce((a, b) => a.expandToInclude(b));
      Future<List<int>> pixels() async {
        final box = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(surface),
        );
        final bytes = (await tester.runAsync(() async {
          final image = await box.toImage(pixelRatio: 1.25);
          final data = await image.toByteData();
          image.dispose();
          return data!;
        }))!;
        final width = (box.size.width * 1.25).round();
        return [
          for (
            var y = (region.top * 1.25).floor();
            y < (region.bottom * 1.25).ceil();
            y++
          )
            for (
              var x = (region.left * 1.25).floor();
              x < (region.right * 1.25).ceil();
              x++
            )
              bytes.getUint32((y * width + x) * 4),
        ];
      }

      final before = rects(tester);
      final laidOut = await pixels();
      gravityMode.value = true;
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      await tester.tap(find.byKey(reset));
      List<int>? last;
      var lastRects = before;
      for (var i = 0; gravityMode.value && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (gravityMode.value) {
          last = await pixels();
          lastRects = rects(tester);
        }
      }
      expect(gravityMode.value, isFalse);
      final handed = await pixels();
      expectAt(lastRects, before, 'on the last animated frame');
      expectAt(rects(tester), before, 'once handed back');
      expect(handed, laidOut, reason: 'handed back vs laid out');
      expect(last, handed, reason: 'last animated frame vs handed back');
    });

    testWidgets('pieces go home to where the layout is now', (tester) async {
      final before = await land(tester);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      shift.value = 25;
      await tester.pump();
      final moved = {
        for (final n in names) n: before[n]!.shift(const Offset(25, 25)),
      };
      final (last, _, _) = await goHome(tester);
      expectAt(last, moved, 'on the last animated frame');
      expectAt(rects(tester), moved, 'once handed back');
    });

    testWidgets('with reduced motion pieces go home at once', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final before = await land(tester);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      await tester.tap(find.byKey(reset));
      await tester.pump();
      expect(gravityMode.value, isFalse);
      expectAt(rects(tester), before, 'at once');
    });
  });

  group('message entry', () {
    final show = ValueNotifier<GravityEntry?>(null);
    tearDown(() => show.value = null);

    Future<void> chat(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Gravity(
                  child: SizedBox(width: 300, height: 60, child: Text('old')),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: ValueListenableBuilder(
                      valueListenable: show,
                      builder: (_, entry, _) => entry == null
                          ? const SizedBox()
                          : Gravity(
                              entry: entry,
                              child: const SizedBox(
                                width: 200,
                                height: 50,
                                child: Text('new'),
                              ),
                            ),
                    ),
                  ),
                ),
                // The composer: x 100..500, y 540..600.
                Padding(
                  padding: const EdgeInsets.only(left: 100, right: 300),
                  child: GravityPlatform(
                    spout: true,
                    color: Colors.grey,
                    builder: (_, _) => const SizedBox(height: 60, width: 1000),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      gravityMode.value = true;
      await settle(tester);
    }

    testWidgets('an own message squeezes out of the composer top', (
      tester,
    ) async {
      await chat(tester);
      show.value = GravityEntry.fromComposer;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      var rect = tester.getRect(find.text('new'));
      expect(rect.bottom, closeTo(540, .5));
      expect(rect.height, lessThan(12));
      expect(rect.left, greaterThanOrEqualTo(100));
      expect(rect.right, lessThanOrEqualTo(500));

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      rect = tester.getRect(find.text('new'));
      expect(rect.bottom, closeTo(540, .5));
      expect(rect.height, inExclusiveRange(20, 50));

      await settle(tester);
      rect = tester.getRect(find.text('new'));
      expect(rect.height, closeTo(50, .5));
      expect(gravityDebug().awake, 0);
      expect(rect.bottom, lessThanOrEqualTo(600.5));
    });

    testWidgets('an own message shoves the pile up as it grows', (
      tester,
    ) async {
      await chat(tester);
      // Hold the old piece just above the spout while the message grows.
      final old = tester.getRect(find.text('old'));
      final gesture = await tester.startGesture(old.center);
      final step = (const Offset(300, 505) - old.center) / 30;
      for (var i = 0; i < 30; i++) {
        await gesture.moveBy(step);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester, frames: 60);
      final held = tester.getRect(find.text('old'));
      expect(held.bottom, closeTo(535, 3));
      show.value = GravityEntry.fromComposer;
      await tester.pump();
      var highest = held.top;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        highest = math.min(highest, tester.getRect(find.text('old')).top);
      }
      await gesture.up();
      expect(highest, lessThan(held.top - 20));
    });

    testWidgets('an incoming message drops in from above the window', (
      tester,
    ) async {
      await chat(tester);
      show.value = GravityEntry.fromAbove;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final rect = tester.getRect(find.text('new'));
      expect(rect.bottom, lessThan(10));
      expect(rect.height, 50);
      await settle(tester);
      expect(tester.getRect(find.text('new')).bottom, greaterThan(500));
      expect(gravityDebug().awake, 0);
    });
  });

  group('platform', () {
    final typed = TextEditingController();
    tearDown(typed.clear);
    const field = ValueKey('field'), send = ValueKey('send');

    // The region spans x 100..500 and is 60 px tall under the pieces; its
    // line is the top edge. The field (x 100..300) and the send button sit
    // inside it.
    // [exposed] lays the field out left of and below the region instead,
    // held still but not under the line, so a mere fall hits it hard.
    Future<void> stage(
      WidgetTester tester,
      List<String> names, {
      bool exposed = false,
    }) async {
      gravityRandom = math.Random(3);
      final fieldPiece = Gravity(
        child: TextField(key: field, controller: typed),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(left: 100),
              child: SizedBox(
                width: 400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final name in names)
                          Gravity(
                            weight: 3,
                            child: SizedBox(
                              width: 60,
                              height: 30,
                              child: Text(name),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 280),
                    GravityPlatform(
                      color: Colors.grey,
                      builder: (_, broken) => Container(
                        height: 60,
                        padding: const EdgeInsets.only(top: 20),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: broken ? Colors.transparent : Colors.black,
                            ),
                          ),
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 200,
                                  child: exposed ? null : fieldPiece,
                                ),
                                Gravity(
                                  child: IconButton(
                                    key: send,
                                    onPressed: () {},
                                    icon: const Icon(Icons.send),
                                  ),
                                ),
                                Text(broken ? 'broken' : 'whole'),
                              ],
                            ),
                            if (exposed)
                              Positioned(
                                left: -100,
                                top: 150,
                                width: 90,
                                child: fieldPiece,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    ({double damage, int cracks, int shards, double left}) line() =>
        gravityDebug().platforms.single;

    Rect regionOf(WidgetTester tester) =>
        tester.getRect(find.byType(GravityPlatform));

    /// Carries [name] up to y 60 (over [x]) and lets go without throwing it.
    Future<void> lift(WidgetTester tester, String name, {double? x}) async {
      final from = tester.getCenter(find.text(name));
      final gesture = await tester.startGesture(from);
      final step = (Offset(x ?? from.dx, 60) - from) / 20;
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(step);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
    }

    /// Carries [name] up and throws it straight down.
    Future<void> hurl(WidgetTester tester, String name) async {
      await lift(tester, name);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.flingFrom(
        tester.getCenter(find.text(name)),
        const Offset(0, 80),
        3000,
      );
    }

    /// Throws [name] until the line shatters; returns the throw count.
    Future<int> breakLine(WidgetTester tester, String name) async {
      var throws = 0;
      var cracks = 0;
      while (line().shards == 0 && throws < 10) {
        await hurl(tester, name);
        throws++;
        await settle(tester, frames: 60);
        expect(line().cracks, greaterThanOrEqualTo(cracks));
        cracks = line().cracks;
      }
      return throws;
    }

    testWidgets('pieces pile on the line and only leave hairlines', (
      tester,
    ) async {
      await stage(tester, [for (var i = 0; i < 10; i++) 'p$i']);
      final controls = [
        tester.getRect(find.byKey(field)),
        tester.getRect(find.byKey(send)),
      ];
      final inside = regionOf(tester).deflate(2);
      gravityMode.value = true;
      // No piece ever gets into the region while the line holds.
      void outside() {
        for (var i = 0; i < 10; i++) {
          final rect = tester.getRect(find.text('p$i'));
          expect(rect.overlaps(inside), isFalse, reason: 'p$i $rect');
        }
      }

      for (var i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        outside();
      }
      // The line holds the pile (one may tumble over its end).
      expect([
        for (var i = 0; i < 10; i++)
          if (tester.getRect(find.text('p$i')).bottom < inside.top) i,
      ], hasLength(greaterThanOrEqualTo(9)));
      for (var i = 0; i < 10; i++) {
        await lift(tester, 'p${i % 3}');
        for (var f = 0; f < 90; f++) {
          await tester.pump(const Duration(milliseconds: 16));
          outside();
        }
      }
      expect(line().cracks, greaterThan(0));
      expect(line().damage, lessThanOrEqualTo(.45));
      expect(line().shards, 0);
      expect(find.text('whole'), findsOneWidget);
      // Everything inside stays exactly in place.
      expect(gravityDebug().held, 2);
      expect(tester.getRect(find.byKey(field)), controls[0]);
      expect(tester.getRect(find.byKey(send)), controls[1]);
    });

    testWidgets(
      'hard throws break the line onto the controls; reset mends it',
      (tester) async {
        await stage(tester, ['rock', 'sitter']);
        final laidOut = {
          for (final n in ['rock', 'sitter']) n: tester.getRect(find.text(n)),
        };
        final fieldRect = tester.getRect(find.byKey(field));
        final sendRect = tester.getRect(find.byKey(send));
        final top = regionOf(tester).top;
        gravityMode.value = true;
        await settle(tester);
        expect(tester.getRect(find.text('sitter')).bottom, closeTo(top, 2.5));

        expect(await breakLine(tester, 'rock'), inInclusiveRange(2, 6));
        expect(line().shards, inInclusiveRange(3, 6));
        expect(sounds.map((s) => s.$1), contains('sounds/gravity_crack.wav'));
        expect(find.text('broken'), findsOneWidget);
        await settle(tester);
        // Nothing holds the controls any more: they fell with the line, and
        // the sitter fell through to the pile below.
        expect(gravityDebug().held, 0);
        expect(tester.getRect(find.byKey(field)).bottom, greaterThan(500));
        expect(tester.getRect(find.byKey(send)).bottom, greaterThan(500));
        expect(tester.getRect(find.text('sitter')).bottom, greaterThan(500));

        // The trip home heals the cracks as the pieces fly.
        await tester.pump(const Duration(seconds: 3));
        await tester.tap(find.byKey(const ValueKey('gravity-reset')));
        var left = line().left;
        expect(left, 1);
        var frames = 0;
        while (gravityMode.value && frames < 100) {
          await tester.pump(const Duration(milliseconds: 16));
          frames++;
          if (!gravityMode.value) break;
          expect(line().left, lessThanOrEqualTo(left));
          left = line().left;
          if (frames == 25) {
            expect(left, inExclusiveRange(0, 1));
            expect(find.text('broken'), findsOneWidget);
          }
        }
        // Mended on the last animated frame, so the hand-back changes nothing.
        expect(left, 0);
        expect(gravityMode.value, isFalse);
        await tester.pump();
        expect(find.text('whole'), findsOneWidget);
        expect(gravityDebug().platforms, isEmpty);
        for (final n in laidOut.keys) {
          expect(tester.getRect(find.text(n)), laidOut[n]);
        }
        expect(tester.getRect(find.byKey(field)), fieldRect);
        expect(tester.getRect(find.byKey(send)), sendRect);

        gravityMode.value = true;
        await settle(tester);
        expect(line().shards, 0);
        expect(line().damage, lessThanOrEqualTo(.45));
        expect(
          tester.getRect(find.text('sitter')).bottom,
          lessThanOrEqualTo(top + 2),
        );
      },
    );

    testWidgets('only a hard hit knocks a control loose; it stays typeable', (
      tester,
    ) async {
      await stage(tester, ['rock'], exposed: true);
      final laidOut = tester.getRect(find.byKey(field));
      gravityMode.value = true;
      await settle(tester);
      expect(gravityDebug().held, 2);

      // Carried over the field and dropped: a fall, not a throw.
      await lift(tester, 'rock', x: laidOut.center.dx);
      await settle(tester, frames: 200);
      expect(gravityDebug().held, 2);
      expect(
        tester.getRect(find.text('rock')).bottom,
        closeTo(laidOut.top, 2.5),
      );
      expect(tester.getRect(find.byKey(field)), laidOut);

      await hurl(tester, 'rock');
      await settle(tester);
      expect(gravityDebug().held, 1);
      // Loose, it fell to the window bottom and still takes typing.
      expect(tester.getRect(find.byKey(field)).bottom, greaterThan(500));
      await tester.tap(find.byKey(field));
      await tester.pump();
      await tester.enterText(find.byKey(field), 'still here');
      expect(typed.text, 'still here');
    });
  });

  testWidgets('the sensor is only listened to while gravity is on', (
    tester,
  ) async {
    const channel = MethodChannel('syb.l/gravity');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Gravity(child: Text('s'))),
      ),
    );
    await settle(tester, frames: 60);
    expect(calls, isEmpty);

    gravityMode.value = true;
    await settle(tester, frames: 200);
    expect(calls, ['listen']);

    // A sample arriving through the channel steers the pile upward.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeSuccessEnvelope([0.0, -9.8]),
      (_) {},
    );
    await settle(tester);
    expect(tester.getRect(find.text('s')).top, closeTo(0, 2.5));

    gravityMode.value = false;
    await tester.pump();
    expect(calls, ['listen', 'cancel']);
  });

  group('device and window motion', () {
    /// Lands one piece laid out at [alignment] on the floor of an 800×600
    /// window; returns its resting rect.
    Future<Rect> land(
      WidgetTester tester, {
      Alignment alignment = Alignment.topCenter,
      double weight = 1,
    }) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: alignment,
              child: Gravity(
                weight: weight,
                child: const SizedBox(width: 120, height: 40, child: Text('p')),
              ),
            ),
          ),
        ),
      );
      gravityMode.value = true;
      await settle(tester);
      expect(gravityDebug().awake, 0);
      final rest = tester.getRect(find.text('p'));
      expect(rest.bottom, closeTo(600, 2.5));
      return rest;
    }

    testWidgets('a phone tilted 10° from flat slides the resting pile', (
      tester,
    ) async {
      await land(tester, alignment: Alignment.topLeft);
      // Lying nearly flat, raised 10° on its left edge: the pull is right.
      gravitySensorSample(9.81 * math.sin(10 * math.pi / 180), 0);
      expect(gravityDebug().awake, 1);
      await settle(tester, frames: 200);
      expect(tester.getRect(find.text('p')).right, closeTo(800, 2.5));
    });

    testWidgets('a small turn of the phone wakes the pile', (tester) async {
      await land(tester);
      final turn = 2 * math.pi / 180;
      gravitySensorSample(9.81 * math.sin(turn), 9.81 * math.cos(turn));
      expect(gravityDebug().awake, 1);
    });

    testWidgets('a flatter phone pulls weaker and flat keeps the direction', (
      tester,
    ) async {
      final rest = await land(tester);
      Future<double> rise(double pull) async {
        final from = tester.getRect(find.text('p')).top;
        gravitySensorSample(0, -pull);
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final travel = from - tester.getRect(find.text('p')).top;
        await settle(tester, frames: 200);
        return travel;
      }

      // Upright and upside down: the full pull.
      final upright = await rise(9.81);
      expect(tester.getRect(find.text('p')).top, closeTo(0, 2.5));
      gravitySensorSample(0, 9.81);
      await settle(tester, frames: 200);
      expect(tester.getRect(find.text('p')).bottom, closeTo(rest.bottom, 2.5));
      // About 6° from flat: a quarter of it.
      final flatter = await rise(1);
      expect(flatter, greaterThan(0));
      expect(flatter, lessThan(upright / 2));
      // Flat (under ~3°): the last direction stays and the pile rests.
      expect(gravityDebug().awake, 0);
      gravitySensorSample(.3, .1);
      await settle(tester, frames: 60);
      expect(tester.getRect(find.text('p')).top, closeTo(0, 2.5));
      expect(gravityDebug().awake, 0);
    });

    testWidgets('a shake of the phone jostles the pile', (tester) async {
      final rest = await land(tester);
      // A gentle sway does nothing.
      gravitySensorSample(0, 9.81, 2, 0);
      await settle(tester, frames: 30);
      expect(tester.getRect(find.text('p')), rest);
      expect(gravityDebug().awake, 0);
      // A jerk to the left: the piece lags behind, to the right.
      gravitySensorSample(0, 9.81, -20, 0);
      var right = rest.left;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        right = math.max(right, tester.getRect(find.text('p')).left);
      }
      expect(right, greaterThan(rest.left + 40));
      await settle(tester);
      expect(gravityDebug().awake, 0);
      expect(tester.getRect(find.text('p')).bottom, closeTo(600, 2.5));
    });

    testWidgets('dragging the window right slides the pile left, then it '
        'settles', (tester) async {
      final rest = await land(tester);
      // The first report only says where the window is.
      gravityWindowAt(const Offset(100, 100));
      expect(gravityDebug().awake, 0);
      var left = rest.left;
      for (var i = 1; i <= 10; i++) {
        gravityWindowAt(Offset(100 + 15.0 * i, 100));
        await tester.pump(const Duration(milliseconds: 16));
        left = math.min(left, tester.getRect(find.text('p')).left);
      }
      expect(left, lessThan(rest.left - 40));
      await settle(tester);
      expect(gravityDebug().awake, 0);
      final now = tester.getRect(find.text('p'));
      expect(now.bottom, closeTo(600, 2.5));
      expect(now.left, lessThan(rest.left - 40));
      // A jump (another screen, maximize) is no drag.
      gravityWindowAt(const Offset(2000, 100));
      expect(gravityDebug().awake, 0);
    });

    testWidgets('a heavy piece bumping a wall at a crawl is silent', (
      tester,
    ) async {
      final rest = await land(tester, alignment: Alignment.topLeft, weight: 6);
      expect(rest.left, closeTo(0, 2.5));
      var window = Offset.zero;
      gravityWindowAt(window);
      Future<void> nudge(double dx) async {
        gravityWindowAt(window += Offset(dx, 0));
        await settle(tester, frames: 120);
        expect(gravityDebug().awake, 0);
      }

      // Off the wall, then slid back into it slowly.
      await nudge(-20);
      expect(tester.getRect(find.text('p')).left, greaterThan(4));
      sounds.clear();
      await nudge(22);
      expect(tester.getRect(find.text('p')).left, closeTo(0, 2.5));
      expect(sounds, isEmpty);
      // Off again and back hard: audible.
      await nudge(-20);
      await nudge(60);
      expect(sounds, isNotEmpty);
    });

    testWidgets('a hand-held phone keeps a settled pile quiet', (tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      gravityRandom = math.Random(1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                for (var i = 0; i < 16; i++)
                  Gravity(
                    weight: i.isEven ? 3 : 1,
                    child: SizedBox(
                      width: 80.0 + i % 5 * 30,
                      height: 50,
                      child: Text('m$i'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      gravityMode.value = true;
      final noise = math.Random(7);
      // Held at ~45°, swaying a few degrees and trembling, at 30 Hz.
      Future<void> hold(int frames) async {
        for (var i = 0; i < frames; i++) {
          if (i.isEven) {
            final a =
                (8 * math.sin(2 * math.pi * .3 * i * .016) +
                    (noise.nextDouble() - .5) * 3) *
                math.pi /
                180;
            gravitySensorSample(7 * math.sin(a), 7 * math.cos(a));
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await hold(300);
      expect(sounds, isNotEmpty);
      sounds.clear();
      await hold(600);
      expect(sounds, isEmpty);
    });
  });

  group('scrolled out of view', () {
    testWidgets(
      'a piece waits off screen, then hangs from a corner and falls',
      (tester) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = const Size(800, 600);
        addTearDown(tester.view.reset);
        gravityRandom = math.Random(5);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Gravity(
                      child: SizedBox(
                        width: 100,
                        height: 40,
                        child: Text('near'),
                      ),
                    ),
                    SizedBox(height: 1200),
                    Padding(
                      padding: EdgeInsets.only(left: 300),
                      child: Gravity(
                        child: SizedBox(
                          width: 120,
                          height: 40,
                          child: Text('far'),
                        ),
                      ),
                    ),
                    SizedBox(height: 400),
                  ],
                ),
              ),
            ),
          ),
        );
        final laidOut = tester.getRect(find.text('far'));
        gravityMode.value = true;
        await settle(tester);
        expect(gravityDebug().bodies, 1);
        expect(tester.getRect(find.text('far')), laidOut);
        expect(tester.getRect(find.text('near')).bottom, closeTo(600, 2.5));

        scroll.jumpTo(1000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final spot = laidOut.shift(const Offset(0, -1000));
        expect(gravityDebug().bodies, 2);
        expect(gravityDebug().pins, 2);
        List<Offset> far() =>
            gravityDebug().shapes.firstWhere((shape) => shape.first.dx > 200);
        // Held in place by both top corners.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (gravityDebug().pins < 2) break;
          expect((far()[0] - spot.topLeft).distance, lessThan(1));
          expect((far()[1] - spot.topRight).distance, lessThan(1));
        }
        var frames = 0;
        while (gravityDebug().pins == 2 && frames++ < 200) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(gravityDebug().pins, 1);
        // Then it swings from the one corner still pinned.
        var turned = 0.0;
        var drift = [0.0, 0.0];
        while (gravityDebug().pins == 1 && frames++ < 400) {
          final shape = far();
          drift = [
            math.max(drift[0], (shape[0] - spot.topLeft).distance),
            math.max(drift[1], (shape[1] - spot.topRight).distance),
          ];
          final edge = shape[1] - shape[0];
          turned = math.max(turned, math.atan2(edge.dy, edge.dx).abs());
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(drift.reduce(math.min), lessThanOrEqualTo(1));
        expect(drift.reduce(math.max), greaterThan(20));
        expect(turned, greaterThan(.5));
        expect(gravityDebug().pins, 0);
        await settle(tester);
        expect(tester.getRect(find.text('far')).bottom, greaterThan(500));
      },
    );
  });

  group('crushing', () {
    const surface = ValueKey('surface');
    const victim = ValueKey('victim'), box = ValueKey('victim-box');

    /// Lands an 80x20 red victim and a 60x60 slab of [weight], then sets the
    /// slab down on the victim.
    Future<void> load(WidgetTester tester, double weight) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  const Align(
                    alignment: Alignment.bottomLeft,
                    child: Gravity(
                      key: victim,
                      child: ColoredBox(
                        key: box,
                        color: Color(0xFFFF0000),
                        child: SizedBox(width: 80, height: 20),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: Gravity(
                      weight: weight,
                      child: const SizedBox(
                        width: 60,
                        height: 60,
                        child: Text('slab'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      gravityMode.value = true;
      await settle(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('slab')),
      );
      final step =
          (const Offset(40, 548) - tester.getCenter(find.text('slab'))) / 40;
      for (var i = 0; i < 40; i++) {
        await gesture.moveBy(step);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester, frames: 30);
      await gesture.up();
    }

    Future<int> reds(WidgetTester tester) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(surface),
      );
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!;
      }))!;
      var count = 0;
      for (var i = 0; i < bytes.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) > 200 &&
            bytes.getUint8(i + 1) < 60 &&
            bytes.getUint8(i + 2) < 60) {
          count++;
        }
      }
      return count;
    }

    testWidgets('a heavily loaded piece cracks, then shatters into chunks of '
        'itself', (tester) async {
      gravityRandom = math.Random(2);
      await load(tester, 200);
      expect(await reds(tester), greaterThan(1400));
      var cracked = false;
      for (var i = 0; i < 200 && gravityDebug().broken == 0; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final damage = gravityDebug().damage[victim] ?? 0;
        if (damage >= .2 && damage < 1) {
          cracked = true;
          // The cracks show over it.
          expect(
            tester
                .widgetList<CustomPaint>(
                  find.ancestor(
                    of: find.byKey(box),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .any((paint) => paint.foregroundPainter != null),
            isTrue,
          );
        }
      }
      expect(cracked, isTrue);
      expect(gravityDebug().broken, 1);
      expect(gravityDebug().chunks, inInclusiveRange(6, 14));
      expect(sounds.map((s) => s.$1), contains('sounds/gravity_crack.wav'));
      await tester.pump(const Duration(milliseconds: 16));
      // The piece itself hides; its chunks show its own red paint.
      expect(find.byKey(box).hitTestable(), findsNothing);
      expect(await reds(tester), greaterThan(800));
      // They fade away after a while; the piece flies home whole on reset.
      await settle(tester, frames: 400);
      expect(gravityDebug().chunks, 0);
      expect(await reds(tester), 0);
      await tester.tap(find.byKey(const ValueKey('gravity-reset')));
      for (var i = 0; gravityMode.value && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(gravityMode.value, isFalse);
      expect(tester.getRect(find.byKey(box)).bottom, 600);
      expect(await reds(tester), 1600);
    });

    testWidgets('a lightly loaded piece takes no damage', (tester) async {
      gravityRandom = math.Random(2);
      await load(tester, 1);
      await settle(tester);
      expect(gravityDebug().damage[victim], 0);
      expect(gravityDebug().broken, 0);
    });

    testWidgets('a piece resting over the reset button shatters', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: Gravity(
                key: victim,
                child: SizedBox(width: 120, height: 40, child: Text('lid')),
              ),
            ),
          ),
        ),
      );
      gravityMode.value = true;
      gravitySensorSample(0, -9.8);
      await settle(tester, frames: 150);
      expect(gravityDebug().damage[victim], 0);
      final lid = tester.getRect(find.text('lid'));
      expect(lid.top, closeTo(0, 2.5));
      expect(lid.right, closeTo(800, 2.5));
      await tester.pump(const Duration(seconds: 3));
      await settle(tester, frames: 200);
      expect(gravityDebug().broken, 1);
    });
  });

  testWidgets('pieces never cross a wall, which follows its layout', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final rail = ValueNotifier(300.0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: rail,
            builder: (_, width, _) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: width,
                  child: const Align(
                    alignment: Alignment.topLeft,
                    child: Gravity(
                      child: SizedBox(
                        width: 100,
                        height: 40,
                        child: Text('west'),
                      ),
                    ),
                  ),
                ),
                const GravityWall(child: SizedBox(width: 1, height: 600)),
                const Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Gravity(
                      child: SizedBox(
                        width: 100,
                        height: 40,
                        child: Text('east'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    gravityMode.value = true;
    var wall = 300.0;
    Future<void> watch(int frames) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getRect(find.text('west')).right,
          lessThanOrEqualTo(wall + 1),
        );
        expect(
          tester.getRect(find.text('east')).left,
          greaterThanOrEqualTo(wall),
        );
      }
    }

    await watch(250);
    // Pulled right, the sidebar's piece stops at the wall.
    gravitySensorSample(9.81, 0);
    await watch(150);
    expect(tester.getRect(find.text('west')).right, closeTo(300, 2.5));
    // Thrown hard at it, it still stays out.
    await tester.fling(find.text('west'), const Offset(-150, 0), 1000);
    await watch(30);
    await tester.fling(find.text('west'), const Offset(150, 0), 5000);
    await watch(100);
    // Pulled left, the pane's piece stops at the wall, which moves with the
    // layout and pushes it along.
    gravitySensorSample(-9.81, 0);
    await watch(150);
    expect(tester.getRect(find.text('east')).left, closeTo(301, 2.5));
    rail.value = 400;
    wall = 400;
    await tester.pump();
    await watch(150);
    expect(tester.getRect(find.text('east')).left, closeTo(401, 2.5));
  });

  group('trip home', () {
    const reset = ValueKey('gravity-reset');

    testWidgets('the reset button has no tooltip', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Gravity(child: Text('p'))),
        ),
      );
      gravityMode.value = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(reset), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(reset), matching: find.byType(Tooltip)),
        findsNothing,
      );
    });

    testWidgets('pieces stack in layout order as they set off and each lands '
        'with a click', (tester) async {
      // Lifted out of order: c, a, b.
      gravityRandom = math.Random(4);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                for (final (i, n) in ['a', 'b', 'c'].indexed)
                  Positioned(
                    left: 100 + i * 20.0,
                    top: 100,
                    child: Gravity(
                      child: SizedBox(width: 100, height: 40, child: Text(n)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      List<String?> painted() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList();
      gravityMode.value = true;
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      expect(painted(), isNot(['a', 'b', 'c']));
      sounds.clear();
      await tester.tap(find.byKey(reset));
      await tester.pump(const Duration(milliseconds: 16));
      expect(painted(), ['a', 'b', 'c']);
      for (var i = 0; gravityMode.value && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final lands = [
        for (final (asset, volume) in sounds)
          if (asset.startsWith('sounds/gravity_land_')) volume,
      ];
      expect(lands, hasLength(3));
      expect(lands.toSet(), hasLength(3));
    });

    testWidgets('a big pile lands with a rate-limited patter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                for (var i = 0; i < 80; i++)
                  const Gravity(child: SizedBox(width: 30, height: 14)),
              ],
            ),
          ),
        ),
      );
      gravityMode.value = true;
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      sounds.clear();
      await tester.tap(find.byKey(reset));
      for (var i = 0; gravityMode.value && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final lands = sounds.where(
        (s) => s.$1.startsWith('sounds/gravity_land_'),
      );
      expect(lands.length, inInclusiveRange(5, 11));
    });
  });

  group('platform break', () {
    testWidgets('all held controls fall the moment the line breaks', (
      tester,
    ) async {
      gravityRandom = math.Random(3);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      const surface = ValueKey('surface');
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.only(left: 100),
                child: SizedBox(
                  width: 400,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Gravity(
                        weight: 3,
                        child: SizedBox(
                          width: 60,
                          height: 30,
                          child: Text('rock'),
                        ),
                      ),
                      const SizedBox(height: 280),
                      GravityPlatform(
                        color: Colors.grey,
                        builder: (_, _) => Container(
                          height: 60,
                          padding: const EdgeInsets.only(top: 20),
                          color: const Color(0xFF00FF00),
                          child: const Row(
                            children: [
                              Gravity(child: Icon(Icons.attach_file)),
                              Gravity(child: Icon(Icons.mood)),
                              Gravity(child: Icon(Icons.mic)),
                              Gravity(child: Icon(Icons.send)),
                            ],
                          ),
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
      gravityMode.value = true;
      await settle(tester);
      expect(gravityDebug().held, 4);
      ({double damage, int cracks, int shards, double left}) line() =>
          gravityDebug().platforms.single;
      var throws = 0;
      while (line().shards == 0 && throws++ < 10) {
        final from = tester.getCenter(find.text('rock'));
        final gesture = await tester.startGesture(from);
        for (var i = 0; i < 20; i++) {
          await gesture.moveBy((Offset(from.dx, 60) - from) / 20);
          await tester.pump(const Duration(milliseconds: 16));
          if (line().shards > 0) break;
          expect(gravityDebug().held, 4);
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.flingFrom(
          tester.getCenter(find.text('rock')),
          const Offset(0, 80),
          3000,
        );
        for (var f = 0; f < 60; f++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (line().shards > 0) break;
          expect(gravityDebug().held, 4);
        }
      }
      // On the frame the line is gone, every control is loose.
      expect(line().shards, greaterThan(0));
      expect(gravityDebug().held, 0);
      expect(gravityDebug().bodies, 5);
      await settle(tester);
      for (final icon in [
        Icons.attach_file,
        Icons.mood,
        Icons.mic,
        Icons.send,
      ]) {
        expect(tester.getRect(find.byIcon(icon)).bottom, greaterThan(500));
      }
      // The shards show the region's own green paint, not a bare line.
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(surface),
      );
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!;
      }))!;
      var green = 0;
      for (var i = 400 * 800 * 4; i < bytes.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) < 60 &&
            bytes.getUint8(i + 1) > 200 &&
            bytes.getUint8(i + 2) < 60) {
          green++;
        }
      }
      expect(green, greaterThan(100));
    });
  });

  test('impact volume follows the speed of the lighter moving body', () {
    // A heavy piece nudged at a crawl: a large impulse, yet silent.
    expect(gravityImpactVolume(.3, 2, 0), 0);
    expect(gravityImpactVolume(.3, 2, 3), 0);
    // The same impulse moves a light piece fast.
    expect(gravityImpactVolume(.3, .1, 0), closeTo(3 / 8, 1e-9));
    expect(gravityImpactVolume(.3, .1, 2), closeTo(3 / 8, 1e-9));
    // Louder with speed, up to full.
    expect(
      gravityImpactVolume(.5, .1, 0),
      greaterThan(gravityImpactVolume(.3, .1, 0)),
    );
    expect(gravityImpactVolume(100, .1, 0), 1);
    expect(gravityImpactVolume(1, 0, 0), 0);
  });

  testWidgets('a piece mostly hidden behind a clip still falls', (
    tester,
  ) async {
    gravityImpactSound = (_, _) {};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ClipRect(
              child: SizedBox(
                width: 100,
                height: 6,
                child: OverflowBox(
                  alignment: Alignment.bottomLeft,
                  maxHeight: 60,
                  child: Gravity(
                    child: Container(
                      key: const ValueKey('sliver'),
                      width: 100,
                      height: 60,
                      color: const Color(0xFF884422),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    gravityMode.value = true;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.getRect(find.byKey(const ValueKey('sliver'))).top,
      greaterThan(400),
    );
  });
}

/// Depth in pixels by which two convex polygons overlap (0 when apart).
double _penetration(List<Offset> a, List<Offset> b) {
  var least = double.infinity;
  for (final poly in [a, b]) {
    for (var i = 0; i < poly.length; i++) {
      final edge = poly[(i + 1) % poly.length] - poly[i];
      final n = Offset(-edge.dy, edge.dx) / edge.distance;
      double dot(Offset v) => v.dx * n.dx + v.dy * n.dy;
      final overlap =
          math.min(a.map(dot).reduce(math.max), b.map(dot).reduce(math.max)) -
          math.max(a.map(dot).reduce(math.min), b.map(dot).reduce(math.min));
      least = math.min(least, overlap);
    }
  }
  return math.max(0, least);
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => _count++),
    child: Text('$_count'),
  );
}
