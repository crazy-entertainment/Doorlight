import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/settings_pane.dart';

final class _BackupState extends AppState {
  _BackupState(SharedPreferences prefs) : super(JamiClient(), prefs);

  final exports = <(String?, String)>[];

  @override
  Future<bool> backupIdentity(String passphrase) async {
    exports.add((accountId, passphrase));
    return true;
  }
}

Future<_BackupState> _openSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final state = _BackupState(await SharedPreferences.getInstance())
    ..accountId = 'original-account'
    ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      home: Scaffold(
        body: SettingsPane(
          state: state,
          onClose: () {},
          onOpenDiagnostics: () {},
        ),
      ),
    ),
  );
  await tester.scrollUntilVisible(
    find.widgetWithText(OutlinedButton, 'Back up'),
    180,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('settings-list')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    ),
  );
  return state;
}

void main() {
  for (final protected in [true, false]) {
    for (final replacement in ['unchanged', 'different', 'returned']) {
      testWidgets(
        'backup prompt stays bound to its identity: protected=$protected, owner=$replacement',
        (tester) async {
          final state = await _openSettings(tester);
          await tester.tap(find.widgetWithText(OutlinedButton, 'Back up'));
          await tester.pumpAndSettle();
          if (protected) {
            await tester.enterText(
              find.byType(TextField).first,
              'private password',
            );
            await tester.enterText(
              find.byType(TextField).last,
              'private password',
            );
          }
          if (!protected) {
            await tester.tap(
              find.byKey(const ValueKey('backup-password-protection')),
            );
            await tester.pumpAndSettle();
          }
          if (replacement != 'unchanged') {
            state.accountId = 'replacement-account';
            if (replacement == 'returned') state.accountId = 'original-account';
          }
          await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
          await tester.pumpAndSettle();
          if (!protected) {
            expect(state.exports, isEmpty);
            await tester.pump(const Duration(seconds: 5));
            await tester.tap(
              find.byKey(const ValueKey('confirm-unprotected-backup')),
            );
            await tester.pumpAndSettle();
          }
          expect(
            state.exports,
            replacement == 'unchanged'
                ? [('original-account', protected ? 'private password' : '')]
                : isEmpty,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('queued backup actions cannot stack password prompts', (
    tester,
  ) async {
    await _openSettings(tester);
    final open = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Back up'))
        .onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
