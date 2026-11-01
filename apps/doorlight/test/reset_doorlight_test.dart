import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _RetiredJami extends FakeJami {
  _RetiredJami(this.reason);
  final String reason;
  int relaunches = 0;

  @override
  Future<Map<String, dynamic>> ensureAccount(
    String displayName, {
    String preferredAccountId = '',
    String preferredPeerId = '',
    bool createIfMissing = false,
  }) async =>
      throw PlatformException(code: 'relaunch_required', details: reason);

  @override
  Future<void> relaunchRetired() async => relaunches++;
}

class _ResetJami extends FakeJami {
  bool removeSucceeds = true;
  final removedAccounts = <String>[];

  @override
  Future<bool> resetDoorlight(String expectedAccountId) async {
    removedAccounts.add(expectedAccountId);
    if (removeSucceeds) accountExists = false;
    return removeSucceeds;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> fixture(
    _ResetJami jami, [
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    final state = AppState(jami, await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await state.init();
    return state;
  }

  Future<AppState> fixture2(FakeJami jami) async {
    SharedPreferences.setMockInitialValues({'displayName': 'PC'});
    final state = AppState(jami, await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await state.init();
    return state;
  }

  test('confirmed reset clears preferences and requires restart', () async {
    final jami = _ResetJami();
    final state = await fixture(jami, {
      'displayName': 'PC',
      'customLocalValue': 'old',
    });
    expect(await state.resetDoorlight(), isTrue);
    expect(jami.removedAccounts, ['acc1']);
    expect(state.prefs.getKeys(), isEmpty);
    expect(state.accountId, isNull);
    expect(state.resetDoorlightRestartRequired, isTrue);
    expect(state.screen, Screen.loading);
    await state.retryBoot();
    expect(state.screen, Screen.loading);
    expect(await state.resetDoorlight(), isFalse);
  });

  test(
    'unconfirmed removal keeps exact consent and permits explicit retry',
    () async {
      final jami = _ResetJami()..removeSucceeds = false;
      final state = await fixture(jami);
      expect(await state.resetDoorlight(), isFalse);
      expect(state.prefs.getString(AppState.resetDoorlightMarker), 'acc1');
      expect(state.resetDoorlightPending, isTrue);
      expect(state.screen, Screen.loading);
      expect(state.resetDoorlightError, isNotNull);
      jami.removeSucceeds = true;
      expect(await state.resetDoorlight(), isTrue);
      expect(jami.removedAccounts, ['acc1', 'acc1']);
    },
  );

  test(
    'interrupted reset blocks boot adoption until explicit completion',
    () async {
      final jami = _ResetJami();
      final state = await fixture(jami, {
        AppState.resetDoorlightMarker: 'acc1',
        'accountId': 'acc1',
        'displayName': 'PC',
      });
      expect(jami.lastEnsureCreateIfMissing, isNull);
      expect(jami.removedAccounts, isEmpty);
      expect(state.screen, Screen.loading);
      expect(await state.resetDoorlight(), isTrue);
      expect(jami.removedAccounts, ['acc1']);
    },
  );

  test(
    'changed identity and malformed consent cannot remove accounts',
    () async {
      final jami = _ResetJami();
      final state = await fixture(jami);
      await state.prefs.setString(
        AppState.resetDoorlightMarker,
        'other-account',
      );
      expect(await state.resetDoorlight(), isFalse);
      await state.prefs.setBool(AppState.resetDoorlightMarker, true);
      expect(await state.resetDoorlight(), isFalse);
      expect(jami.removedAccounts, isEmpty);
    },
  );

  // Android keeps the process (daemon worker, services) after the Activity
  // closes, so a reopened UI meets the retired engine with no Dart memory of
  // the reset. It must offer the relaunch, never a retry that cannot succeed.
  for (final reason in ['reset', 'engine']) {
    test('retired process ($reason) offers relaunch, not retry', () async {
      final jami = _RetiredJami(reason);
      final state = await fixture2(jami);
      expect(state.screen, Screen.loading);
      expect(state.relaunchRequired, isTrue);
      expect(state.resetDoorlightRestartRequired, reason == 'reset');
      expect(state.bootError, isNot("Couldn't start the engine."));
      await state.relaunchRetired();
      expect(jami.relaunches, 1);
    });
  }
}