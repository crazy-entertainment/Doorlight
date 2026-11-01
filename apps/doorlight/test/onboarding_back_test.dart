import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';

class _CreatingState extends AppState {
  _CreatingState(super.jami, super.prefs);

  final creation = Completer<void>();

  @override
  Future<void> onboard(String name) => creation.future;
}

void main() {
  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester, {
    AppState? suppliedState,
    double textScale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final state =
        suppliedState ??
        AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: OnboardingScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'phone setup actions stay legible and reachable at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await open(tester, textScale: scale);
        final welcome = find.byKey(const ValueKey('onboarding-create-choice'));
        expect(tester.getSize(welcome).height, greaterThanOrEqualTo(64));
        final label = tester.widget<Text>(find.text('I’m new to Doorlight'));
        expect(label.style!.fontSize, 17);
        await tester.ensureVisible(welcome);
        await tester.tap(welcome);
        await tester.pumpAndSettle();
        final submit = find.byKey(const ValueKey('onboarding-create-submit'));
        await tester.ensureVisible(submit);
        expect(tester.getSize(submit).height, greaterThanOrEqualTo(56));
        final submitContext = tester.element(submit);
        expect(
          FilledButtonTheme.of(
            submitContext,
          ).style!.textStyle!.resolve({})!.fontSize,
          17,
        );
        expect(tester.takeException(), isNull);
        await back(tester);
        final existing = find.byKey(
          const ValueKey('onboarding-existing-choice'),
        );
        await tester.ensureVisible(existing);
        await tester.tap(existing);
        await tester.pumpAndSettle();
        final restore = find.byKey(const ValueKey('onboarding-restore-choice'));
        await tester.ensureVisible(restore);
        expect(
          tester.widget<Text>(find.text('Restore a backup')).style!.fontSize,
          17,
        );
        await tester.tap(restore);
        await tester.pumpAndSettle();
        final pick = find.byKey(const ValueKey('onboarding-restore-pick'));
        await tester.ensureVisible(pick);
        expect(tester.getSize(pick).height, greaterThanOrEqualTo(56));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('system Back cannot leave an active profile creation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _CreatingState(
      JamiClient(),
      await SharedPreferences.getInstance(),
    );
    await open(tester, suppliedState: state);
    await tester.tap(find.byKey(const ValueKey('onboarding-create-choice')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('onboarding-name-field')),
      'Test',
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-create-submit')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('onboarding-create-step')),
      findsOneWidget,
    );
    state.creation.completeError(StateError('Creation failed'));
    await tester.pumpAndSettle();
    await back(tester);
    expect(
      find.byKey(const ValueKey('onboarding-choice-step')),
      findsOneWidget,
    );
  });

  for (final choice in ['create', 'existing']) {
    testWidgets('system Back returns from $choice to welcome', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(ValueKey('onboarding-$choice-choice')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('onboarding-$choice-step')), findsOneWidget);
      await back(tester);
      expect(
        find.byKey(const ValueKey('onboarding-choice-step')),
        findsOneWidget,
      );
      expect(
        tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
        isTrue,
      );
    });
  }

  testWidgets('system Back follows restore to existing to welcome', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding-existing-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-restore-choice')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('onboarding-restore-step')),
      findsOneWidget,
    );
    await back(tester);
    expect(
      find.byKey(const ValueKey('onboarding-existing-step')),
      findsOneWidget,
    );
    await back(tester);
    expect(
      find.byKey(const ValueKey('onboarding-choice-step')),
      findsOneWidget,
    );
  });

  testWidgets('Back dismisses a dialog before changing the onboarding step', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding-existing-choice')));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(OnboardingScreen));
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('Dialog')),
    );
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('Dialog'), findsNothing);
    expect(
      find.byKey(const ValueKey('onboarding-existing-step')),
      findsOneWidget,
    );
  });
}
