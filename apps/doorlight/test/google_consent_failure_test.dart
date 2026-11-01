import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _ConsentStore extends InMemorySharedPreferencesStore {
  _ConsentStore() : super.withData({});
  String? reject;
  bool throws = false;
  bool rejectRemoval = false;

  @override
  Future<bool> remove(String key) async =>
      rejectRemoval && key == reject ? false : super.remove(key);

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == reject) {
      if (throws) throw StateError('synthetic persistence failure');
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'total storage failure keeps wake off and warns before restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _ConsentStore();
      SharedPreferencesStorePlatform.instance = store;
      final jami = FakeJami();
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      expect(await state.setReliableBackgroundNotifications(true), isTrue);
      store
        ..reject = 'flutter.googleWakeConsent.v1'
        ..rejectRemoval = true;
      expect(await state.setReliableBackgroundNotifications(false), isFalse);
      expect(state.googleWakeAllowed, isFalse);
      expect(jami.backgroundWakeCalls.last.enabled, isFalse);
      expect(state.settingsError, contains('retry before restarting'));
      await state.prefs.reload();
      expect(
        state.prefs.getBool('googleWakeConsent.v1'),
        isTrue,
        reason: 'The test must model a genuinely unsaved withdrawal.',
      );
    },
  );
  for (final throws in [false, true]) {
    for (final enabled in [false, true]) {
      test(
        'wake fails closed after save failure: enable=$enabled throw=$throws',
        () async {
          SharedPreferences.setMockInitialValues({});
          final store = _ConsentStore();
          SharedPreferencesStorePlatform.instance = store;
          final jami = FakeJami();
          final state = AppState(jami, await SharedPreferences.getInstance());
          addTearDown(state.dispose);
          await state.init();
          if (!enabled) {
            expect(
              await state.setReliableBackgroundNotifications(true),
              isTrue,
            );
          }
          store
            ..reject = 'flutter.googleWakeConsent.v1'
            ..throws = throws;
          expect(
            await state.setReliableBackgroundNotifications(enabled),
            isFalse,
          );
          expect(state.googleWakeAllowed, isFalse);
          expect(state.reliableBackgroundNotifications, isFalse);
          expect(jami.backgroundWakeCalls.last.enabled, isFalse);
          expect(state.settingsError, contains('Could not save'));
          await state.prefs.reload();
          expect(state.prefs.getBool('googleWakeConsent.v1'), isNot(isTrue));
          final restarted = AppState(FakeJami(), state.prefs);
          addTearDown(restarted.dispose);
          await restarted.init();
          expect(restarted.googleWakeAllowed, isFalse);
          expect(restarted.reliableBackgroundNotifications, isFalse);
          store.reject = null;
          expect(await state.setReliableBackgroundNotifications(false), isTrue);
          expect(state.googleWakeAllowed, isFalse);
        },
      );
    }
    test(
      'Nearby withdrawal reaches native after save failure: throw=$throws',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _ConsentStore();
        SharedPreferencesStorePlatform.instance = store;
        final calls = <MethodCall>[];
        const channel = MethodChannel('syb.l/nearby_radio');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return true;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final state = AppState(
          FakeJami(),
          await SharedPreferences.getInstance(),
        );
        addTearDown(state.dispose);
        await state.init();
        expect(await state.setGoogleNearbyAllowed(true), isTrue);
        store
          ..reject = 'flutter.googleNearbyConsent.v1'
          ..throws = throws;
        expect(await state.setGoogleNearbyAllowed(false), isFalse);
        expect(state.googleNearbyAllowed, isFalse);
        expect(calls.last.arguments, {'enabled': false});
        expect(state.settingsError, contains('Could not apply'));
        await state.prefs.reload();
        final restarted = AppState(FakeJami(), state.prefs);
        addTearDown(restarted.dispose);
        await restarted.init();
        expect(restarted.googleNearbyAllowed, isFalse);
      },
    );
  }
}
