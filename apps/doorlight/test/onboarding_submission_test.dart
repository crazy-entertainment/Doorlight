import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/doorlight_brand.dart';

final class _SetupState extends AppState {
  _SetupState(SharedPreferences prefs) : super(JamiClient(), prefs);

  final creation = Completer<void>();
  final restoration = Completer<String?>();
  final createRequests = <String>[];
  final restoreRequests = <String>[];
  final restoredBackups = <String?>[];
  final expectedIds = <String?>[];
  final discardedBackups = <String>[];
  var picks = 0;

  @override
  Future<void> onboard(String name) {
    createRequests.add(name);
    return creation.future;
  }

  @override
  Future<String?> pickIdentityBackup() async => '/staged/backup-${++picks}.gz';

  @override
  Future<void> discardIdentityBackup(String path) async {
    discardedBackups.add(path);
  }

  @override
  Future<String?> restoreIdentity(
    String passphrase, {
    String? backupPath,
    String? expectedJamiId,
  }) {
    restoreRequests.add(passphrase);
    restoredBackups.add(backupPath);
    expectedIds.add(expectedJamiId);
    return restoration.future;
  }
}

Future<_SetupState> _openSetup(WidgetTester tester, String choice) async {
  SharedPreferences.setMockInitialValues({});
  final state = _SetupState(await SharedPreferences.getInstance());
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      home: Scaffold(body: OnboardingScreen(state: state)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(choice)));
  await tester.pumpAndSettle();
  if (choice == 'onboarding-existing-choice') {
    await tester.tap(find.byKey(const ValueKey('onboarding-restore-choice')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('onboarding-passphrase-field')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-restore-pick')));
    await tester.pumpAndSettle();
    expect(find.text('backup-1.gz'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('onboarding-restore-friend-id')),
      'e' * 40,
    );
    await tester.pumpAndSettle();
  }
  return state;
}

void main() {
  testWidgets('mobile introduction opens the door before profile entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final state = _SetupState(await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.android),
        home: OnboardingScreen(state: state),
      ),
    );
    expect(
      tester.widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark)).openness,
      0,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark)).openness,
      1.4,
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-create-choice')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'Windows introduction waits for an app click and pauses when unfocused',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      SharedPreferences.setMockInitialValues({});
      final state = _SetupState(await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: OnboardingScreen(state: state),
        ),
      );
      double openness() => tester
          .widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark))
          .openness;
      double thresholdPhase() => tester
          .widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark))
          .thresholdPhase;

      final firstGlow = thresholdPhase();
      await tester.pump(const Duration(milliseconds: 800));
      expect(openness(), 0);
      expect(thresholdPhase(), isNot(firstGlow));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(openness(), 0);
      await tester.tap(find.byType(DoorlightDoorMark));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final partlyOpen = openness();
      expect(partlyOpen, greaterThan(0));
      expect(partlyOpen, lessThan(1.4));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 500));
      expect(openness(), partlyOpen);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(openness(), 1.4);
    },
  );

  testWidgets(
    'incoming invitation stays visible through setup without sending trust',
    (tester) async {
      final state = await _openSetup(tester, 'onboarding-create-choice');
      state.inviteContinuation.stage('doorlight://add/${'b' * 40}?name=Mara');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('onboarding-pending-invite')),
        findsOneWidget,
      );
      expect(find.text('Invitation from Mara'), findsOneWidget);
      expect(state.createRequests, isEmpty);
      expect(state.restoreRequests, isEmpty);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(state.pendingInvite, isNull);
    },
  );

  testWidgets('confirmed unprotected restore uses the chosen file once', (
    tester,
  ) async {
    final state = await _openSetup(tester, 'onboarding-existing-choice');
    state.restoration.complete(null);
    await tester.tap(
      find.byKey(const ValueKey('onboarding-restore-unprotected')),
    );
    await tester.pumpAndSettle();
    expect(state.restoreRequests, isEmpty);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Restore'),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.restoreRequests, ['']);
    expect(state.restoredBackups, ['/staged/backup-1.gz']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving restore releases an unused backup file', (tester) async {
    final state = await _openSetup(tester, 'onboarding-existing-choice');
    await tester.tap(find.widgetWithText(TextButton, 'Change'));
    await tester.pumpAndSettle();
    expect(find.text('backup-2.gz'), findsOneWidget);
    expect(state.discardedBackups, ['/staged/backup-1.gz']);
    await tester.tap(find.byKey(const ValueKey('onboarding-back')));
    await tester.pumpAndSettle();
    expect(state.discardedBackups, [
      '/staged/backup-1.gz',
      '/staged/backup-2.gz',
    ]);
    expect(state.restoreRequests, isEmpty);
  });

  testWidgets(
    'queued create submissions issue one setup request and allow retry after failure',
    (tester) async {
      final state = await _openSetup(tester, 'onboarding-create-choice');
      await tester.enterText(find.byType(TextField), 'Alice');
      final submit = tester
          .widget<TextField>(find.byType(TextField))
          .onSubmitted!;
      // Keyboard callbacks already queued before the disabled widget rebuilds.
      submit('Alice');
      submit('Alice');
      await tester.pump();
      state.creation.completeError(StateError('fixture creation rejected'));
      await tester.pumpAndSettle();

      expect(state.createRequests, ['Alice']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isNot(false),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queued protected restore submissions issue one restore request',
    (tester) async {
      final state = await _openSetup(tester, 'onboarding-existing-choice');
      final passwordField = find.byKey(
        const ValueKey('onboarding-passphrase-field'),
      );
      await tester.enterText(passwordField, 'backup password');
      final submit = tester.widget<TextField>(passwordField).onSubmitted!;
      submit('backup password');
      submit('backup password');
      await tester.pump();
      state.restoration.complete('fixture restore rejected');
      await tester.pumpAndSettle();

      expect(state.restoreRequests, ['backup password']);
      expect(state.expectedIds, ['e' * 40]);
      // The attempt spent the staged copy, so a retry starts by picking again.
      expect(
        find.byKey(const ValueKey('onboarding-restore-pick')),
        findsOneWidget,
      );
      expect(state.discardedBackups, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty password submits nothing; the unprotected path warns once',
    (tester) async {
      final state = await _openSetup(tester, 'onboarding-existing-choice');
      final passwordField = find.byKey(
        const ValueKey('onboarding-passphrase-field'),
      );
      final submit = tester.widget<TextField>(passwordField).onSubmitted!;
      submit('');
      submit('');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final unprotected = tester
          .widget<TextButton>(
            find.byKey(const ValueKey('onboarding-restore-unprotected')),
          )
          .onPressed!;
      // Both taps were queued before the busy button rebuilt.
      unprotected();
      unprotected();
      await tester.pumpAndSettle();

      expect(
        find.text('Use an unprotected backup?', skipOffstage: false),
        findsOneWidget,
      );
      expect(state.restoreRequests, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(passwordField).enabled, isNot(false));
      expect(tester.takeException(), isNull);
    },
  );

  for (final returnToNoAccount in [false, true]) {
    testWidgets(
      'restore warning cannot cross an identity change (return: $returnToNoAccount)',
      (tester) async {
        final state = await _openSetup(tester, 'onboarding-existing-choice');
        state.restoration.complete(null);
        await tester.tap(
          find.byKey(const ValueKey('onboarding-restore-unprotected')),
        );
        await tester.pumpAndSettle();
        state.accountId = 'replacement-account';
        if (returnToNoAccount) state.accountId = null;
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Restore'),
          ),
        );
        await tester.pumpAndSettle();

        expect(state.restoreRequests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
