import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/widgets/passphrase_dialog.dart';

Future<void> _openBackupDialog(
  WidgetTester tester,
  ValueChanged<String?> onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async => onResult(
              await showPassphraseDialog(
                context,
                title: 'Back up your identity',
                subtitle: 'Add a password to protect your identity!',
                actionLabel: 'Create backup',
                confirm: true,
                allowEmpty: true,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('password eyes appear only for their nonempty field', (
    tester,
  ) async {
    await _openBackupDialog(tester, (_) {});
    final fields = find.byType(TextField);
    expect(find.byTooltip('Show passwords'), findsNothing);
    await tester.enterText(fields.first, 'private');
    await tester.pump();
    expect(find.byTooltip('Show passwords'), findsOneWidget);
    expect(
      tester.widget<TextField>(fields.last).decoration!.suffixIcon,
      isNull,
    );
    await tester.enterText(fields.first, '');
    await tester.pump();
    expect(find.byTooltip('Show passwords'), findsNothing);
    final controller = tester.widget<TextField>(fields.last).controller!;
    controller.text = 'autofilled';
    await tester.pump();
    expect(find.byTooltip('Show passwords'), findsOneWidget);
  });

  testWidgets('eye buttons reveal and hide passwords inside their fields', (
    tester,
  ) async {
    await _openBackupDialog(tester, (_) {});
    final fields = find.byType(TextField);
    await tester.enterText(fields.first, 'private backup password');
    await tester.enterText(fields.last, 'private backup password');
    await tester.pump();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('show'), findsNothing);
    expect(find.byTooltip('Show passwords'), findsNWidgets(2));
    expect(
      tester.widgetList<TextField>(fields).every((field) => field.obscureText),
      isTrue,
    );
    for (final field in tester.widgetList<TextField>(fields)) {
      expect(field.decoration!.suffixIcon, isA<IconButton>());
    }
    await tester.tap(find.byTooltip('Show passwords').first);
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<TextField>(fields).every((field) => !field.obscureText),
      isTrue,
    );
    expect(find.byTooltip('Hide passwords'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Hide passwords').last);
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<TextField>(fields).every((field) => field.obscureText),
      isTrue,
    );
    expect(
      tester.widget<TextField>(fields.first).controller!.text,
      'private backup password',
    );
  });

  testWidgets(
    'backup protection defaults on and empty password cannot opt out',
    (tester) async {
      await _openBackupDialog(tester, (_) {});
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('backup-password-protection')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a password'), findsOneWidget);
      expect(find.text('Create an unprotected backup?'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('backup-password-protection')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('unprotected warning confirmation is one-shot', (tester) async {
    String? result;
    await _openBackupDialog(tester, (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('backup-password-protection')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    final confirm = tester
        .widget<FilledButton>(
          find.byKey(const ValueKey('confirm-unprotected-backup')),
        )
        .onPressed!;
    confirm();
    confirm();
    await tester.pumpAndSettle();

    expect(result, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty first password cannot bypass a nonempty confirmation', (
    tester,
  ) async {
    await _openBackupDialog(tester, (_) {});
    await tester.enterText(find.byType(TextField).last, 'protected password');
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pump();

    expect(find.text("The two passwords don't match"), findsOneWidget);
    expect(find.text('Create an unprotected backup?'), findsNothing);
  });

  testWidgets(
    'queued empty password submissions cannot stack backup warnings',
    (tester) async {
      await _openBackupDialog(tester, (_) {});
      await tester.tap(
        find.byKey(const ValueKey('backup-password-protection')),
      );
      await tester.pumpAndSettle();
      final submit = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create backup'),
          )
          .onPressed!;
      submit();
      submit();
      await tester.pump();

      expect(
        find.text('Create an unprotected backup?', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('changed password invalidates an outstanding unprotected warning', (
    tester,
  ) async {
    String? result = 'not completed';
    await _openBackupDialog(tester, (value) => result = value);
    final password = tester
        .widget<TextField>(find.byType(TextField).first)
        .controller!;
    await tester.tap(find.byKey(const ValueKey('backup-password-protection')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pump();
    // An autofill/controller update must not leave an old empty snapshot authoritative.
    password.text = 'new protected password';
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(const ValueKey('confirm-unprotected-backup')));
    await tester.pumpAndSettle();

    expect(result, 'not completed');
    expect(find.text('Back up your identity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty backup password requires a five-second warning', (
    tester,
  ) async {
    String? result = 'not completed';
    await _openBackupDialog(tester, (value) => result = value);

    await tester.tap(find.byKey(const ValueKey('backup-password-protection')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pump();

    expect(find.text('Create an unprotected backup?'), findsOneWidget);
    expect(
      find.textContaining('Anyone who gets the file can use your identity'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('cancel-unprotected-backup')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirm-unprotected-backup')),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(seconds: 4));
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirm-unprotected-backup')),
          )
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirm-unprotected-backup')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('confirm-unprotected-backup')));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });

  testWidgets('unprotected-backup warning can be cancelled immediately', (
    tester,
  ) async {
    String? result = 'not completed';
    await _openBackupDialog(tester, (value) => result = value);

    await tester.tap(find.byKey(const ValueKey('backup-password-protection')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cancel-unprotected-backup')));
    await tester.pumpAndSettle();

    expect(find.text('Back up your identity'), findsOneWidget);
    expect(result, 'not completed');
  });
}
