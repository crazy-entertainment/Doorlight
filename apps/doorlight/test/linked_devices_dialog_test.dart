import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/linked_devices_dialog.dart';

final class _DeviceJami extends JamiClient {
  final currentId = 'a' * 40;
  final otherId = 'b' * 64;
  final revoked = <String>[];
  final revokeAccounts = <String>[];
  int loads = 0;
  JamiDeviceRevocationStatus status = JamiDeviceRevocationStatus.revoked;
  Completer<JamiDeviceRevocationStatus>? pendingRevocation;
  Completer<List<JamiKnownDevice>>? pendingLoad;

  @override
  Future<List<JamiKnownDevice>> listKnownDevices() async {
    loads++;
    final pending = pendingLoad;
    if (pending != null) return pending.future;
    return [
      JamiKnownDevice(id: currentId, name: 'This PC', current: true),
      JamiKnownDevice(id: otherId, name: 'Phone B', current: false),
    ];
  }

  @override
  Future<JamiDeviceRevocationStatus> revokeKnownDevice(
    String deviceId, {
    required String accountId,
  }) async {
    revoked.add(deviceId);
    revokeAccounts.add(accountId);
    final pending = pendingRevocation;
    if (pending != null) return pending.future;
    return status;
  }
}

Future<void> _openDevices(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => showLinkedDevicesDialog(context, state: state),
            child: const Text('Open devices'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open devices'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('link action stays beside the heading and before the list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final jami = _DeviceJami();
    final state = AppState(jami, await SharedPreferences.getInstance())
      ..accountId = 'account-a';
    addTearDown(state.dispose);
    await _openDevices(tester, state);
    final title = find.text('Linked devices');
    final link = find.byKey(const ValueKey('link-another-device'));
    expect(tester.getCenter(title).dy, closeTo(tester.getCenter(link).dy, 1));
    expect(
      tester.getBottomLeft(link).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(ValueKey('linked-device-${jami.currentId}')))
            .dy,
      ),
    );
    expect(
      find.text(
        'Identity and chats sync. Files, settings and permissions stay on each device.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unconfirmed late revocation restores actions without success', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final jami = _DeviceJami()
      ..pendingRevocation = Completer<JamiDeviceRevocationStatus>();
    final state = AppState(jami, await SharedPreferences.getInstance())
      ..accountId = 'account-a';
    addTearDown(state.dispose);
    await _openDevices(tester, state);
    await tester.tap(find.byKey(ValueKey('revoke-device-${jami.otherId}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-device-revocation')));
    await tester.pump();
    jami.pendingRevocation!.complete(JamiDeviceRevocationStatus.timeout);
    await tester.pumpAndSettle();
    expect(jami.loads, 1);
    expect(find.byKey(const ValueKey('linked-devices-notice')), findsNothing);
    expect(find.textContaining('Revocation is not confirmed.'), findsOneWidget);
    final action = tester.widget<TextButton>(
      find.byKey(ValueKey('revoke-device-${jami.otherId}')),
    );
    expect(action.onPressed, isNotNull);
  });

  testWidgets('unresolved earlier revocation explains the pending retry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final jami = _DeviceJami()..status = JamiDeviceRevocationStatus.pending;
    final state = AppState(jami, await SharedPreferences.getInstance())
      ..accountId = 'account-a';
    addTearDown(state.dispose);
    await _openDevices(tester, state);
    await tester.tap(find.byKey(ValueKey('revoke-device-${jami.otherId}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-device-revocation')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('An earlier revocation is still unresolved.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('linked-devices-notice')), findsNothing);
    expect(jami.loads, 1);
  });

  testWidgets('late device list cannot populate a replacement account dialog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final jami = _DeviceJami();
    final state = AppState(jami, await SharedPreferences.getInstance())
      ..accountId = 'account-a';
    addTearDown(state.dispose);
    await _openDevices(tester, state);
    jami.pendingLoad = Completer<List<JamiKnownDevice>>();
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    state.accountId = 'account-b';
    state.accountId = 'account-a';
    jami.pendingLoad!.complete([
      JamiKnownDevice(
        id: jami.otherId,
        name: 'Old account row',
        current: false,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Old account row'), findsNothing);
    expect(find.textContaining('The identity changed.'), findsOneWidget);
  });

  testWidgets('revocation confirmation cannot cross account A B A', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final jami = _DeviceJami();
    final state = AppState(jami, await SharedPreferences.getInstance())
      ..accountId = 'account-a'
      ..jamiId = 'f' * 40;
    addTearDown(state.dispose);
    await _openDevices(tester, state);
    await tester.tap(find.byKey(ValueKey('revoke-device-${jami.otherId}')));
    await tester.pumpAndSettle();
    state.accountId = 'account-b';
    state.accountId = 'account-a';
    await tester.tap(find.byKey(const ValueKey('confirm-device-revocation')));
    await tester.pumpAndSettle();
    expect(
      jami.revoked,
      isEmpty,
      reason: 'confirmation belongs to the original account lifetime',
    );
  });

  testWidgets(
    'old revocation completion cannot refresh replacement account rows',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final jami = _DeviceJami()
        ..pendingRevocation = Completer<JamiDeviceRevocationStatus>();
      final state = AppState(jami, await SharedPreferences.getInstance())
        ..accountId = 'account-a'
        ..jamiId = 'f' * 40;
      addTearDown(state.dispose);
      await _openDevices(tester, state);
      await tester.tap(find.byKey(ValueKey('revoke-device-${jami.otherId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-device-revocation')));
      await tester.pump();
      expect(jami.revoked, [jami.otherId]);
      state.accountId = 'account-b';
      state.accountId = 'account-a';
      jami.pendingRevocation!.complete(JamiDeviceRevocationStatus.revoked);
      await tester.pumpAndSettle();
      expect(
        jami.loads,
        1,
        reason: 'old completion cannot reload devices for a replacement owner',
      );
      expect(find.byKey(const ValueKey('linked-devices-notice')), findsNothing);
    },
  );

  testWidgets(
    'linked devices explains sync and confirms exact noncurrent revocation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final jami = _DeviceJami();
      final state = AppState(jami, await SharedPreferences.getInstance())
        ..accountId = 'account-a'
        ..jamiId = 'f' * 40;
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      showLinkedDevicesDialog(context, state: state),
                  child: const Text('Open devices'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open devices'));
      await tester.pumpAndSettle();

      expect(find.text('Linked devices'), findsOneWidget);
      expect(find.textContaining('Identity and chats sync'), findsOneWidget);
      expect(
        find.textContaining('Files, settings and permissions'),
        findsOneWidget,
      );
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Phone B'), findsOneWidget);
      expect(find.text('Revoke'), findsOneWidget);
      expect(
        find.byKey(ValueKey('revoke-device-${jami.currentId}')),
        findsNothing,
      );

      await tester.tap(find.byKey(ValueKey('revoke-device-${jami.otherId}')));
      await tester.pumpAndSettle();

      expect(find.text('Revoke Phone B?'), findsOneWidget);
      expect(find.text(jami.otherId), findsOneWidget);
      expect(jami.revoked, isEmpty);

      await tester.tap(find.byKey(const ValueKey('confirm-device-revocation')));
      await tester.pumpAndSettle();

      expect(jami.revoked, [jami.otherId]);
      expect(jami.revokeAccounts, ['account-a']);
      expect(
        jami.loads,
        2,
        reason: 'confirmed revocation refreshes daemon truth',
      );
      expect(
        find.byKey(const ValueKey('linked-devices-notice')),
        findsOneWidget,
      );
    },
  );
}
