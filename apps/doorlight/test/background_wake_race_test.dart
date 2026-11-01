import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _WakeJami extends FakeJami {
  Completer<bool>? next;
  Completer<void>? started;

  @override
  Future<bool> setReliableBackgroundNotifications({
    required bool enabled,
    required String connectionProfile,
    String? expectedAccountId,
  }) {
    final pending = next;
    next = null;
    if (pending == null) {
      return super.setReliableBackgroundNotifications(
        enabled: enabled,
        connectionProfile: connectionProfile,
      );
    }
    started?.complete();
    return pending.future;
  }
}

Future<(AppState, _WakeJami)> _boot() async {
  SharedPreferences.setMockInitialValues({'displayName': 'Me'});
  final jami = _WakeJami();
  final state = AppState(jami, await SharedPreferences.getInstance());
  await state.init();
  addTearDown(state.dispose);
  expect(state.effectiveReliableBackgroundNotifications, isFalse);
  expect(await state.setReliableBackgroundNotifications(true), isTrue);
  expect(state.effectiveReliableBackgroundNotifications, isTrue);
  return (state, jami);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a profile change supersedes an older activation error', () async {
    final (state, jami) = await _boot();
    final pending = Completer<bool>();
    jami.next = pending;
    jami.started = Completer<void>();
    final old = state.setReliableBackgroundNotifications(true);
    await jami.started!.future;
    await state.setConnectionProfile('lan');
    pending.complete(false);
    expect(await old, isFalse);
    expect(state.connectionProfile, 'lan');
    expect(state.settingsError, isNull);
    expect(state.effectiveReliableBackgroundNotifications, isFalse);
  });

  test(
    'an old profile failure cannot roll back a replacement profile',
    () async {
      final (state, jami) = await _boot();
      final pending = Completer<void>();
      jami.pendingConnectionProfile = pending;
      final old = state.setConnectionProfile('lan');
      await pumpEventQueue();
      state.accountId = 'replacement';
      state.connectionProfile = 'strict';
      final before = jami.backgroundWakeCalls.length;
      pending.completeError(StateError('synthetic old profile failure'));
      await old;
      expect(state.connectionProfile, 'strict');
      expect(jami.backgroundWakeCalls, hasLength(before));
    },
  );

  for (final replacement in ['account-b', 'acc1']) {
    test(
      'profile continuation cannot target a replacement account: $replacement',
      () async {
        final (state, jami) = await _boot();
        final pending = Completer<bool>();
        jami.next = pending;
        jami.started = Completer<void>();
        final old = state.setConnectionProfile('lan');
        await jami.started!.future;
        final before = List<String>.of(jami.calls);
        state.accountId = 'account-b';
        state.accountId = replacement;
        pending.complete(false);
        await old;
        expect(
          jami.calls,
          before,
          reason: 'No old profile command may reach the replacement.',
        );
      },
    );
  }

  for (final failWithError in [false, true]) {
    test(
      'older wake completion cannot clear newer readiness: error=$failWithError',
      () async {
        final (state, jami) = await _boot();
        final pending = Completer<bool>();
        jami.next = pending;
        jami.started = Completer<void>();
        final old = state.setReliableBackgroundNotifications(true);
        await jami.started!.future;
        expect(await state.setReliableBackgroundNotifications(false), isTrue);
        expect(await state.setReliableBackgroundNotifications(true), isTrue);
        if (failWithError) {
          pending.completeError(StateError('synthetic old wake failure'));
        } else {
          pending.complete(false);
        }
        expect(await old, isFalse);
        expect(state.effectiveReliableBackgroundNotifications, isTrue);
        expect(state.settingsError, isNull);
      },
    );
  }

  test('wake completion cannot cross account A-B-A', () async {
    final (state, jami) = await _boot();
    final pending = Completer<bool>();
    jami.next = pending;
    jami.started = Completer<void>();
    final old = state.setReliableBackgroundNotifications(true);
    await jami.started!.future;
    state.accountId = 'replacement';
    state.accountId = 'acc1';
    pending.complete(true);
    expect(await old, isFalse);
    expect(state.effectiveReliableBackgroundNotifications, isFalse);
  });
}
