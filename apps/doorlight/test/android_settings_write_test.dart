import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _AndroidJami extends FakeJami {
  int accountCreations = 0;
  @override
  bool get usesNativeAppSettingsStore => true;

  @override
  Future<Map<String, dynamic>> ensureAccount(
    String name, {
    String preferredAccountId = '',
    String preferredPeerId = '',
    bool createIfMissing = false,
  }) {
    if (createIfMissing) accountCreations++;
    return super.ensureAccount(
      name,
      preferredAccountId: preferredAccountId,
      preferredPeerId: preferredPeerId,
      createIfMissing: createIfMissing,
    );
  }
}

class _Preferences extends Fake implements SharedPreferences {
  _Preferences(this.stored);
  final SharedPreferences stored;
  int documentPluginWrites = 0;
  int reloads = 0;
  bool rejectReload = false;

  @override
  Object? get(String key) => stored.get(key);
  @override
  bool containsKey(String key) => stored.containsKey(key);
  @override
  String? getString(String key) => stored.getString(key);
  @override
  bool? getBool(String key) => stored.getBool(key);
  @override
  Future<bool> setString(String key, String value) {
    if (key == 'appSettings') documentPluginWrites++;
    return stored.setString(key, value);
  }

  @override
  Future<bool> setBool(String key, bool value) => stored.setBool(key, value);
  @override
  Future<bool> remove(String key) => stored.remove(key);
  @override
  Future<void> reload() async {
    reloads++;
    if (rejectReload) throw StateError('fixture cache refresh failure');
    await stored.reload();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final failure in [false, true]) {
    test(
      'onboarding does not create an account after rejected policy save: throw=$failure',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = _Preferences(await SharedPreferences.getInstance());
        final jami = _AndroidJami()..accountExists = false;
        final state = AppState(jami, preferences);
        addTearDown(state.dispose);
        await state.init();
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveAppSettingsDocument');
          if (failure) throw PlatformException(code: 'fixture-save-failed');
          return false;
        });
        await expectLater(state.onboard('Synthetic'), throwsStateError);
        expect(jami.accountCreations, 0);
        expect(state.settingsError, isNotNull);
      },
    );
  }

  for (final result in [
    'success',
    'false',
    'throw',
    'null',
    'reload failure',
  ]) {
    test(
      'canonical Android save $result preserves the authoritative policy',
      () async {
        final original = jsonEncode(
          const AppSettingsCodec().encode(
            AppSettings().withGlobalMicrophoneMode(MicrophoneMode.pushToTalk),
          ),
        );
        SharedPreferences.setMockInitialValues({'appSettings': original});
        final preferences = _Preferences(await SharedPreferences.getInstance());
        final state = AppState(
          _AndroidJami()..accountExists = false,
          preferences,
        );
        addTearDown(state.dispose);
        await state.init();
        final startupReloads = preferences.reloads;
        expect(startupReloads, 1);
        final completed = Completer<Object?>();
        final documents = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveAppSettingsDocument');
          final document = (call.arguments as Map)['document'] as String;
          documents.add(document);
          final value = await completed.future;
          if (value == true) {
            // Synthetic native persistence; the production adapter must not use
            // the separate plugin writer after this acknowledgment.
            await preferences.stored.setString('appSettings', document);
          }
          return value;
        });
        preferences.rejectReload = result == 'reload failure';
        final save = state.setGlobalMicrophoneMode(MicrophoneMode.open);
        await pumpEventQueue();
        expect(documents, hasLength(1));
        expect(preferences.reloads, startupReloads);
        expect(preferences.documentPluginWrites, 0);
        if (result == 'throw') {
          completed.completeError(
            PlatformException(code: 'synthetic-write-failed'),
          );
        } else {
          completed.complete(switch (result) {
            'success' || 'reload failure' => true,
            'false' => false,
            _ => null,
          });
        }
        final saved = result == 'success' || result == 'reload failure';
        expect(await save, saved);
        expect(preferences.reloads, startupReloads + (saved ? 1 : 0));
        expect(preferences.documentPluginWrites, 0);
        expect(
          state.appSettings.globalMicrophoneMode,
          saved ? MicrophoneMode.open : MicrophoneMode.pushToTalk,
        );
        expect(
          preferences.stored.getString('appSettings'),
          saved ? documents.single : original,
        );
        if (result == 'reload failure') {
          expect(state.settingsError, contains('cache'));
        }
      },
    );
  }

  test(
    'explicitly saving unchanged Open establishes a missing canonical document',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = _Preferences(await SharedPreferences.getInstance());
      final state = AppState(
        _AndroidJami()..accountExists = false,
        preferences,
      );
      addTearDown(state.dispose);
      await state.init();
      expect(preferences.stored.containsKey('appSettings'), isFalse);
      var writes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveAppSettingsDocument');
        writes++;
        await preferences.stored.setString(
          'appSettings',
          (call.arguments as Map)['document'] as String,
        );
        return true;
      });
      expect(await state.setGlobalMicrophoneMode(MicrophoneMode.open), isTrue);
      expect(writes, 1);
      expect(preferences.stored.containsKey('appSettings'), isTrue);
    },
  );
}
