import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'package:sybl/ui/doorlight_brand.dart';

class _MountProbe extends StatefulWidget {
  const _MountProbe(this.onMount);
  final VoidCallback onMount;
  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets('desktop door opens before shrinking and moving', (tester) async {
    tester.view.physicalSize = const Size(675, 490);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: OnboardingScreen(state: state),
      ),
    );
    final door = find.byType(DoorlightDoorMark);
    final start = tester.getCenter(door);
    await tester.tap(door);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<DoorlightDoorMark>(door).openness,
      inExclusiveRange(0, 1.4),
    );
    expect(tester.widget<DoorlightDoorMark>(door).size, 196);
    expect(tester.getCenter(door), start);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<DoorlightDoorMark>(door).openness, 1.4);
    expect(tester.widget<DoorlightDoorMark>(door).size, 196);
    expect(tester.getCenter(door), start);
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<DoorlightDoorMark>(door).openness, 1.4);
    expect(tester.widget<DoorlightDoorMark>(door).size, lessThan(196));
    expect(tester.getCenter(door).dy, lessThan(start.dy));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<DoorlightDoorMark>(door).size, closeTo(490 * .26, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'closed desktop door keeps its original central position and size',
    (tester) async {
      tester.view.physicalSize = const Size(675, 490);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final jami = JamiClient();
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: WindowsChrome(
            jami: jami,
            onboarding: true,
            child: OnboardingScreen(state: state),
          ),
        ),
      );
      final door = find.byType(DoorlightDoorMark);
      expect(tester.widget<DoorlightDoorMark>(door).size, 196);
      expect(tester.widget<DoorlightDoorMark>(door).openness, 0);
      expect(tester.getCenter(door).dx, closeTo(337.5, 1));
      expect(tester.getCenter(door).dy, closeTo(235, 8));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('onboarding-welcome-copy')),
            )
            .opacity,
        0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('welcome copy appears together after the door finishes opening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: OnboardingScreen(state: state),
      ),
    );
    final copy = find.byKey(const ValueKey('onboarding-welcome-copy'));
    final initialDoor = tester.getTopLeft(find.byType(DoorlightDoorMark));
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.widget<Opacity>(copy).opacity, 0);
    expect(initialDoor.dy, greaterThan(150));
    expect(
      tester.widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark)).openness,
      1.4,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Opacity>(copy).opacity, 1);
    expect(
      find.descendant(of: copy, matching: find.text('Doorlight')),
      findsOneWidget,
    );
    expect(
      tester.widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark)).size,
      lessThan(196),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Windows handoff keeps its child mounted and palette unchanged', (
    tester,
  ) async {
    var mounts = 0;
    final jami = JamiClient();
    Widget shell(bool onboarding) => MaterialApp(
      theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
      home: WindowsChrome(
        jami: jami,
        onboarding: onboarding,
        child: _MountProbe(() => mounts++),
      ),
    );
    await tester.pumpWidget(shell(true));
    final before = tester.element(find.byType(_MountProbe)).syblColors;
    await tester.pumpWidget(shell(false));
    expect(mounts, 1);
    expect(tester.element(find.byType(_MountProbe)).syblColors, before);
    expect(before, Warm.cozy);
  });

  testWidgets('desktop setup fades in without changing its final position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(675, 490);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: OnboardingScreen(state: state),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-door-mark')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-create-choice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final field = find.byKey(const ValueKey('onboarding-name-field'));
    final backFade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('onboarding-back')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    final fieldFade = tester.widget<FadeTransition>(
      find.ancestor(of: field, matching: find.byType(FadeTransition)).first,
    );
    expect(backFade.opacity.value, lessThan(1));
    expect(backFade.opacity, same(fieldFade.opacity));
    final arriving = tester.getTopLeft(field);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(field), arriving);
    expect(find.text('Create profile'), findsWidgets);
    expect(find.text('You can change it later.'), findsNothing);
    expect(find.text('Back'), findsOneWidget);
    expect(
      find.ancestor(of: field, matching: find.byType(SlideTransition)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
