import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/state/sonar_combat.dart';
import 'package:sybl/ui/sonar_button.dart';
import 'package:sybl/ui/sonar_warp.dart';

void main() {
  Future<List<Offset>> pump(
    WidgetTester tester, {
    DateTime? until,
    TargetPlatform? platform,
    List<Offset>? pulses,
    List<bool>? holding,
  }) async {
    final reveals = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: platform),
        home: SonarWarp(
          child: Scaffold(
            body: Center(
              child: SonarButton(
                label: 'Peer',
                imageBase64: '',
                visibleUntil: until,
                window: const Duration(minutes: 5),
                onReveal: reveals.add,
                onPulse: pulses?.add,
                onStop: () {},
                onHolding: holding?.add,
              ),
            ),
          ),
        ),
      ),
    );
    return reveals;
  }

  testWidgets('a destroyed sonar cracks, refuses holds, then heals', (
    tester,
  ) async {
    final reveals = <Offset>[];
    DateTime? rearmAt = DateTime.now().add(const Duration(seconds: 10));
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SonarButton(
                  label: 'Peer',
                  imageBase64: '',
                  visibleUntil: null,
                  window: const Duration(minutes: 5),
                  rearmAt: rearmAt,
                  onReveal: reveals.add,
                  onStop: () {},
                );
              },
            ),
          ),
        ),
      ),
    );
    double crack() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('nearby-sonar-crack')),
        )
        .opacity;
    expect(crack(), 1);
    expect(find.byKey(const ValueKey('nearby-rearm')), findsOneWidget);
    expect(find.textContaining('re-arming in 10s'), findsOneWidget);
    expect(find.byKey(const ValueKey('nearby-hold-hint')), findsNothing);
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(SonarButton.holdDuration * 2);
    await gesture.up();
    await tester.pump();
    expect(reveals, isEmpty, reason: 'holding a cracked sonar does nothing');

    rebuild(() => rearmAt = null);
    await tester.pumpAndSettle();
    expect(crack(), 0, reason: 'healed');
    expect(find.byKey(const ValueKey('nearby-hold-hint')), findsOneWidget);
    // A fresh hold works again.
    final again = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(SonarButton.holdDuration);
    await tester.pump(const Duration(milliseconds: 50));
    await again.up();
    await tester.pumpAndSettle();
    expect(reveals, hasLength(1));
  });

  testWidgets('a short touch never reveals; a full hold does once', (
    tester,
  ) async {
    final holding = <bool>[];
    final reveals = await pump(tester, holding: holding);
    final button = find.byKey(const ValueKey('nearby-sonar-button'));

    var gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reveals, isEmpty, reason: 'a brush in a pocket is not a reveal');
    expect(holding, [true, false]);

    gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(SonarButton.holdDuration);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reveals, hasLength(1));
    expect(holding, [true, false, true, false]);
    expect(reveals.single, tester.getCenter(button));
  });

  testWidgets('death floods after impact and clears with the recording', (
    tester,
  ) async {
    await pump(tester);
    tester.state<SonarWarpState>(find.byType(SonarWarp)).death();
    await tester.pump();
    final effect = find.byKey(const ValueKey('sonar-death'));
    expect(effect, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(effect, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(effect, findsOneWidget);
    await tester.pump(SonarCombat.deathDuration - const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      effect,
      findsNothing,
      reason: 'removed on the frame ending the recording',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fatal hit cracks the sonar at the one-second impact cue', (
    tester,
  ) async {
    late StateSetter change;
    DateTime? hitAt, rearmAt;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: StatefulBuilder(
          builder: (context, setState) {
            change = setState;
            return SonarButton(
              label: 'You',
              imageBase64: '',
              visibleUntil: null,
              window: const Duration(minutes: 5),
              hitAt: hitAt,
              rearmAt: rearmAt,
              onReveal: (_) {},
              onStop: () {},
            );
          },
        ),
      ),
    );
    change(() {
      hitAt = DateTime.now();
      rearmAt = hitAt!.add(SonarCombat.deathDuration);
    });
    await tester.pump();
    double crack() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('nearby-sonar-crack')),
        )
        .opacity;
    expect(crack(), 0);
    await tester.pump(const Duration(milliseconds: 1016));
    expect(crack(), 1);
  });

  testWidgets('the ring stays full from the hold into the countdown', (
    tester,
  ) async {
    DateTime? until;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => SonarButton(
                label: 'Peer',
                imageBase64: '',
                visibleUntil: until,
                window: const Duration(minutes: 5),
                onReveal: (_) => setState(
                  () => until = DateTime.now().add(const Duration(minutes: 5)),
                ),
                onStop: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    double sweep() {
      final painter =
          tester
                  .widget<CustomPaint>(
                    find
                        .descendant(
                          of: button,
                          matching: find.byType(CustomPaint),
                        )
                        .first,
                  )
                  .painter
              as dynamic;
      return math.max(painter.hold as double, painter.remaining as double);
    }

    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(SonarButton.holdDuration);
    // The controller reports completion on the tick after its last value.
    await tester.pump(const Duration(milliseconds: 16));
    for (var frame = 0; frame < 6; frame++) {
      expect(sweep(), greaterThan(.9), reason: 'frame $frame');
      // The completed hold paints a calm avatar for the wave's capture.
      expect(find.byType(ColorFiltered), findsNothing);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(until, isNotNull);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tap while visible bounces the picture', (tester) async {
    await pump(
      tester,
      until: DateTime.now().add(const Duration(minutes: 4)),
      pulses: [],
    );
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    double scale() => tester
        .widget<AnimatedScale>(
          find.descendant(of: button, matching: find.byType(AnimatedScale)),
        )
        .scale;
    expect(scale(), 1);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(), lessThan(1));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(scale(), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the avatar glitches harder as the hold closes', (tester) async {
    await pump(tester);
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    final ghosts = find.descendant(
      of: button,
      matching: find.byType(ColorFiltered),
    );
    expect(ghosts, findsNothing);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final early = tester.widget<Opacity>(
      find.ancestor(of: ghosts.first, matching: find.byType(Opacity)).first,
    );
    await tester.pump(const Duration(milliseconds: 400));
    final late = tester.widget<Opacity>(
      find.ancestor(of: ghosts.first, matching: find.byType(Opacity)).first,
    );
    expect(ghosts, findsNWidgets(2));
    expect(late.opacity, greaterThan(early.opacity));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ghosts, findsNothing);
  });

  testWidgets('reduced motion does not shorten the hold', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final reveals = await pump(tester);
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    var gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 500));
    // Reduced motion keeps the picture still while holding.
    expect(find.byType(ColorFiltered), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reveals, isEmpty);

    gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(SonarButton.holdDuration);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    expect(reveals, hasLength(1));
  });

  testWidgets('while visible it counts down and cannot be held again', (
    tester,
  ) async {
    final reveals = await pump(
      tester,
      until: DateTime.now().add(const Duration(minutes: 4, seconds: 30)),
    );
    expect(find.byKey(const ValueKey('nearby-countdown')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^0[34]:[0-5]\d left$')),
      findsOneWidget,
    );
    expect(find.byTooltip('Turn off'), findsOneWidget);
    expect(find.byKey(const ValueKey('nearby-stop')), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('nearby-sonar-button'))),
    );
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    expect(reveals, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tap while visible pulses; revealing keeps the avatar still', (
    tester,
  ) async {
    final pulses = <Offset>[];
    await pump(tester, pulses: pulses);
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    final hidden = tester.getCenter(button);

    // The finger that completes the hold lifts after the button turns
    // visible; that lift is not a pulse.
    final gesture = await tester.startGesture(hidden);
    await tester.pump();
    await tester.pump(SonarButton.holdDuration);
    await pump(
      tester,
      pulses: pulses,
      until: DateTime.now().add(const Duration(minutes: 5)),
    );
    await gesture.up();
    await tester.pump();
    expect(pulses, isEmpty);
    expect(tester.getCenter(button), hidden, reason: 'no jump on reveal');

    await tester.tap(button);
    await tester.pump();
    expect(pulses, [hidden]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the reveal wave runs and leaves nothing behind', (tester) async {
    await pump(tester);
    final warp = tester.state<SonarWarpState>(find.byType(SonarWarp));
    await tester.runAsync(() => warp.reveal(const Offset(100, 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('sonar-reveal')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sonar-reveal')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows reveals the desktop ripple and cancels it on teardown', (
    tester,
  ) async {
    const channel = MethodChannel('syb.l/sonar');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pump(tester, platform: TargetPlatform.windows);
    final warp = tester.state<SonarWarpState>(find.byType(SonarWarp));
    await tester.runAsync(() => warp.reveal(const Offset(100, 120)));
    await tester.pump();
    expect(calls.map((call) => call.method), ['reveal']);
    expect(calls.single.arguments, {
      'x': 100.0,
      'y': 120.0,
      'color': Warm.cozy.amber.toARGB32() & 0xffffff,
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.map((call) => call.method), ['reveal', 'cancel']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a manual pulse stays in the app over the live screen', (
    tester,
  ) async {
    const channel = MethodChannel('syb.l/sonar');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pump(tester, platform: TargetPlatform.windows);
    final warp = tester.state<SonarWarpState>(find.byType(SonarWarp));
    await tester.runAsync(
      () => warp.reveal(const Offset(100, 120), full: false),
    );
    await tester.pump();
    expect(calls, isEmpty);
    final painter = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('sonar-reveal')),
    );
    // No snapshot, so live pulses underneath keep moving.
    expect((painter.painter as dynamic).snapshot, isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a manual pulse shakes the live screen a little', (tester) async {
    await pump(tester);
    final warp = tester.state<SonarWarpState>(find.byType(SonarWarp));
    final shake = find.descendant(
      of: find.byType(SonarWarp),
      matching: find.byType(Transform),
    );
    Offset nudge() {
      final v = tester
          .widget<Transform>(shake.first)
          .transform
          .getTranslation();
      return Offset(v.x, v.y);
    }

    await tester.runAsync(
      () => warp.reveal(const Offset(100, 120), full: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final moved = nudge();
    expect(moved, isNot(Offset.zero));
    expect(moved.distance, lessThan(4));
    await tester.pumpAndSettle();
    expect(nudge(), Offset.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled motion never starts a desktop ripple', (tester) async {
    const channel = MethodChannel('syb.l/sonar');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pump(tester, platform: TargetPlatform.windows);
    await tester
        .state<SonarWarpState>(find.byType(SonarWarp))
        .reveal(const Offset(100, 120));
    await tester.pump();
    expect(calls, isEmpty);
    expect(find.byKey(const ValueKey('sonar-reveal')), findsNothing);
  });

  testWidgets('the phone shakes harder and faster through the hold', (
    tester,
  ) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester);
    final button = find.byKey(const ValueKey('nearby-sonar-button'));
    final gesture = await tester.startGesture(tester.getCenter(button));
    final firstHalf = <String>[];
    for (var ms = 0; ms <= 750; ms += 25) {
      await tester.pump(const Duration(milliseconds: 25));
      if (ms == 375) firstHalf.addAll(haptics);
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final ramp = haptics.where((h) => h != 'HapticFeedbackType.heavyImpact');
    expect(ramp.length, greaterThanOrEqualTo(10));
    expect(firstHalf.length, lessThan(ramp.length - firstHalf.length));
    expect(ramp.last, 'HapticFeedbackType.mediumImpact');
    expect(ramp.first, 'HapticFeedbackType.selectionClick');
  });
}
