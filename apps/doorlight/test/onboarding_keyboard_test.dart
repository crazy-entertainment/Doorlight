import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';

void main() {
  testWidgets('the phone keyboard does not drop focus from the name field', (
    tester,
  ) async {
    // Phone B-shaped: 360 x 690 logical once system bars are excluded.
    tester.view.physicalSize = const Size(1080, 2070);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: OnboardingScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-create-choice')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('onboarding-name-field'));
    await tester.tap(field);
    await tester.pump();

    // The keyboard opens and takes about 300 logical pixels.
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pumpAndSettle();

    final editable = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
  });
}
