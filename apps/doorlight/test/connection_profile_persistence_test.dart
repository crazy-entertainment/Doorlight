import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _Store extends InMemorySharedPreferencesStore {
  _Store()
    : super.withData({
        'flutter.displayName': 'Me',
        'flutter.connectionProfile': 'jami',
      });
  bool rejectProfile = false;
  bool throwWrite = false;
  bool failRead = false;
  int profileWrites = 0;
  int? rejectAt;
  int? throwAt;
  Future<void> Function(int)? beforeWrite;
  Completer<void>? writeStarted;
  Completer<void>? writeRelease;
  Completer<void>? readStarted;
  Completer<void>? readRelease;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.connectionProfile') {
      profileWrites++;
      await beforeWrite?.call(profileWrites);
      writeStarted?.complete();
      await writeRelease?.future;
      if (throwWrite || profileWrites == throwAt) {
        throw StateError('private write details');
      }
      if (rejectProfile || profileWrites == rejectAt) return false;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    readStarted?.complete();
    await readRelease?.future;
    if (failRead) throw StateError('private read details');
    return super.getAll();
  }
}

Future<(AppState, FakeJami, _Store)> _boot() async {
  SharedPreferences.resetStatic();
  final prior = SharedPreferencesStorePlatform.instance;
  final store = _Store();
  SharedPreferencesStorePlatform.instance = store;
  addTearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = prior;
  });
  final jami = FakeJami();
  final state = AppState(jami, await SharedPreferences.getInstance());
  await state.init();
  await pumpEventQueue();
  addTearDown(state.dispose);
  return (state, jami, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final throws in [false, true]) {
    test(
      'failed profile rollback rereads durable state: throw=$throws',
      () async {
        final (state, jami, store) = await _boot();
        jami.failConnectionProfile = true;
        if (throws) {
          store.throwAt = 2;
        } else {
          store.rejectAt = 2;
        }
        await state.setConnectionProfile('lan');
        expect(state.connectionProfile, 'jami');
        expect(state.prefs.getString('connectionProfile'), 'lan');
        expect(state.settingsError, contains('Could not change or restore'));
        expect(state.settingsError, isNot(contains('private')));
        expect(store.profileWrites, 2);
        jami.failConnectionProfile = false;
        await state.setConnectionProfile('strict');
        expect(state.connectionProfile, 'strict');
        expect(state.settingsError, isNull);
      },
    );
  }

  test('failed rollback reread blocks subsequent profile writes', () async {
    final (state, jami, store) = await _boot();
    jami.failConnectionProfile = true;
    store.rejectAt = 2;
    store.failRead = true;
    await state.setConnectionProfile('lan');
    expect(state.settingsError, contains('Could not change or restore'));
    final calls = List<String>.of(jami.calls);
    final wake = jami.backgroundWakeCalls.length;
    jami.failConnectionProfile = false;
    await state.setConnectionProfile('strict');
    expect(store.profileWrites, 2);
    expect(jami.calls, calls);
    expect(jami.backgroundWakeCalls.length, wake);
    store.failRead = false;
    await state.setConnectionProfile('strict');
    expect(state.connectionProfile, 'strict');
    expect(state.settingsError, isNull);
  });

  for (final aba in [false, true]) {
    test(
      'profile rollback completion preserves replacement runtime: aba=$aba',
      () async {
        final (state, jami, store) = await _boot();
        jami.failConnectionProfile = true;
        final entered = Completer<void>();
        final release = Completer<void>();
        store.beforeWrite = (number) async {
          if (number == 2) {
            entered.complete();
            await release.future;
          }
        };
        final run = state.setConnectionProfile('lan');
        await entered.future;
        final original = state.accountId;
        state.accountId = 'replacement';
        if (aba) state.accountId = original;
        state.connectionProfile = 'strict';
        state.settingsError = 'Replacement warning';
        final wake = jami.backgroundWakeCalls.length;
        release.complete();
        await run;
        expect(state.connectionProfile, 'strict');
        expect(state.settingsError, 'Replacement warning');
        expect(jami.backgroundWakeCalls.length, wake);
      },
    );
  }
  for (final throws in [false, true]) {
    test(
      'rejected profile persistence never changes network: throw=$throws',
      () async {
        final (state, jami, store) = await _boot();
        store.rejectProfile = true;
        store.throwWrite = throws;
        final calls = List<String>.of(jami.calls);
        final wakeCount = jami.backgroundWakeCalls.length;
        await state.setConnectionProfile('lan');
        expect(state.connectionProfile, 'jami');
        expect(state.prefs.getString('connectionProfile'), 'jami');
        expect(jami.calls, calls);
        expect(jami.backgroundWakeCalls.length, wakeCount);
        expect(state.settingsError, contains('Could not save'));
        expect(state.settingsError, isNot(contains('private')));
        expect(store.profileWrites, 1);
      },
    );
  }

  test('failed cache reread blocks writes until a successful reread', () async {
    final (state, jami, store) = await _boot();
    store.rejectProfile = true;
    store.failRead = true;
    final calls = List<String>.of(jami.calls);
    final wakeCount = jami.backgroundWakeCalls.length;
    await state.setConnectionProfile('lan');
    expect(state.connectionProfile, 'jami');
    expect(state.prefs.getString('connectionProfile'), 'lan');
    expect(state.settingsError, contains('Restart Doorlight'));
    store.rejectProfile = false;
    await state.setConnectionProfile('strict');
    expect(store.profileWrites, 1);
    expect(jami.calls, calls);
    expect(jami.backgroundWakeCalls.length, wakeCount);
    store.failRead = false;
    await state.setConnectionProfile('strict');
    expect(store.profileWrites, 2);
    expect(state.connectionProfile, 'strict');
    expect(state.prefs.getString('connectionProfile'), 'strict');
    expect(state.settingsError, isNull);
    expect(
      jami.calls.where((call) => call.startsWith('connectionProfile:strict:')),
      hasLength(1),
    );
    state.settingsError = 'Other settings warning';
    await state.setConnectionProfile('lan');
    expect(state.settingsError, 'Other settings warning');
  });

  for (final duringRead in [false, true]) {
    for (final backToOriginal in [false, true]) {
      test(
        'failed save cannot affect replacement owner: read=$duringRead aba=$backToOriginal',
        () async {
          final (state, jami, store) = await _boot();
          store.rejectProfile = true;
          final entered = Completer<void>();
          final release = Completer<void>();
          if (duringRead) {
            store.readStarted = entered;
            store.readRelease = release;
          } else {
            store.writeStarted = entered;
            store.writeRelease = release;
          }
          final pending = state.setConnectionProfile('lan');
          await entered.future;
          final original = state.accountId;
          state.accountId = 'replacement';
          if (backToOriginal) state.accountId = original;
          state.connectionProfile = 'strict';
          state.settingsError = 'Replacement warning';
          final calls = List<String>.of(jami.calls);
          final wakeCount = jami.backgroundWakeCalls.length;
          release.complete();
          await pending;
          expect(state.connectionProfile, 'strict');
          expect(state.settingsError, 'Replacement warning');
          expect(jami.calls, calls);
          expect(jami.backgroundWakeCalls.length, wakeCount);
          expect(store.profileWrites, 1);
        },
      );
    }
  }
}
