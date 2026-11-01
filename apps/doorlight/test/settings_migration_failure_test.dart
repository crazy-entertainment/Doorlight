import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

Map<String, Object?> _legacySettings() => {
  'schemaVersion': 13,
  'microphone': {
    'globalDefault': 'pushToTalk',
    'conversationOverrides': <Object?>[],
  },
  'appLock': {'enabled': true},
  'files': {'folderHistoryLimit': 25, 'maxIncomingFileBytes': 4096},
  'appearance': {
    'preset': 'calm',
    'groupHeaderPlacement': 'conversation',
    'mobileGroupNavigation': 'inline',
    'chatMotionEnabled': false,
    'chatActivityIndicatorsEnabled': false,
    'messageTimestampStyle': 'inward',
    'messageReceiptStyle': 'whatsapp',
    'messageReceiptVisibility': 'always',
    'repeatMessageAuthorAfterPause': true,
    'topicStripSurface': {
      'coverage': 'topics',
      'strength': 50,
      'blur': 10,
      'solidReach': 20,
      'lowerFade': 30,
      'rightFade': 30,
    },
  },
  'windowsCaptureProtection': {'enabled': true},
  'presence': {'shareActiveApp': false},
  'profile': {'identityColor': 'amber'},
  'notifications': {'unreadBadgePlacement': 'avatar', 'showMessage': false},
};

final class _DocumentStore implements AppSettingsDocumentStore {
  _DocumentStore(this.document);

  Map<String, Object?> document;
  bool rejectWrites = false;
  int writeAttempts = 0;

  @override
  Future<Map<String, Object?>?> readDocument() async => document;

  @override
  Future<void> writeDocument(Map<String, Object?> next) async {
    writeAttempts++;
    if (rejectWrites) throw StateError('fixture migration write failed');
    document = next;
  }
}

final class _MigrationPreferences extends Fake implements SharedPreferences {
  _MigrationPreferences(this.stored, this.failure);

  @override
  Future<void> reload() => stored.reload();

  final SharedPreferences stored;
  String? failure;

  @override
  Object? get(String key) => stored.get(key);

  @override
  bool containsKey(String key) => stored.containsKey(key);

  @override
  String? getString(String key) => stored.getString(key);

  @override
  bool? getBool(String key) => stored.getBool(key);

  @override
  Future<bool> setString(String key, String value) async {
    if (key == 'appSettings') {
      if (failure == 'false') return false;
      if (failure == 'throw') {
        throw StateError('fixture preferences write failed');
      }
    }
    return stored.setString(key, value);
  }

  @override
  Future<bool> setBool(String key, bool value) => stored.setBool(key, value);

  @override
  Future<bool> remove(String key) => stored.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migration write failure retains decoded privacy and file limits',
    () async {
      final document = _legacySettings();
      final store = _DocumentStore(document)..rejectWrites = true;
      final repository = VersionedAppSettingsRepository(store);
      final warnings = <Object>[];

      final settings = await repository.load(
        onMigrationWriteFailure: warnings.add,
      );

      expect(settings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
      expect(settings.appLockEnabled, isTrue);
      expect(settings.showMessageInNotification, isFalse);
      expect(settings.maxIncomingFileBytes, 4096);
      expect(settings.folderHistoryLimit, 25);
      expect(store.document, same(document));
      expect(store.writeAttempts, 1);
      expect(warnings, hasLength(1));
      expect(warnings.single, isStateError);
    },
  );

  test(
    'migration can retry after a failed write and persists current schema',
    () async {
      final store = _DocumentStore(_legacySettings())..rejectWrites = true;
      final repository = VersionedAppSettingsRepository(store);
      await repository.load();
      store.rejectWrites = false;
      final warnings = <Object>[];

      final settings = await repository.load(
        onMigrationWriteFailure: warnings.add,
      );

      expect(settings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
      expect(settings.showMessageInNotification, isFalse);
      expect(store.document['schemaVersion'], AppSettings.currentSchemaVersion);
      expect(store.writeAttempts, 2);
      await repository.load(onMigrationWriteFailure: warnings.add);
      expect(store.writeAttempts, 2);
      expect(warnings, isEmpty);
    },
  );

  test('current settings do not write or report a migration failure', () async {
    final store = _DocumentStore({
      ..._legacySettings(),
      'schemaVersion': AppSettings.currentSchemaVersion,
      'appearance': {
        ..._legacySettings()['appearance'] as Map,
        'vibe': 'none',
        'vibeOpacity': 100,
        'vibeIntensity': 100,
        'rememberDefaultWindowPosition': false,
        'windowEdgeSpacing': 'close',
        'windowOpenAnimation': 'tray',
        'windowMinimizeAnimation': 'tray',
        'windowCloseAnimation': 'tray',
        'windowOpenDurationMs': 240,
        'windowMinimizeDurationMs': 240,
        'windowCloseDurationMs': 240,
      },
      'profile': {'identityColor': 'amber', 'identityColorManual': true},
      'friendPreferences': {'reviewRequired': false, 'overrides': <Object?>[]},
      'microphone': {
        'globalDefault': 'pushToTalk',
        'conversationOverrides': <Object?>[],
        'reviewRequired': false,
      },
      'notifications': {
        'unreadBadgePlacement': 'avatar',
        'showMessage': false,
        'reliableBackground': false,
        'googleWakeConsent': false,
        'hologramPresentationEnabled': true,
        'messageAlertsEnabled': true,
      },
    })..rejectWrites = true;
    final warnings = <Object>[];

    final settings = await VersionedAppSettingsRepository(
      store,
    ).load(onMigrationWriteFailure: warnings.add);

    expect(settings.showMessageInNotification, isFalse);
    expect(settings.reliableBackgroundNotifications, isFalse);
    expect(store.writeAttempts, 0);
    expect(warnings, isEmpty);
  });

  for (final document in [
    <String, Object?>{'schemaVersion': 99},
    <String, Object?>{'schemaVersion': 1, 'microphoneMode': 'invalid'},
  ]) {
    test(
      'unreadable settings are not replaced by a migration result: $document',
      () async {
        final store = _DocumentStore(document);
        final warnings = <Object>[];

        await expectLater(
          VersionedAppSettingsRepository(
            store,
          ).load(onMigrationWriteFailure: warnings.add),
          throwsA(anything),
        );

        expect(store.document, same(document));
        expect(store.writeAttempts, 0);
        expect(warnings, isEmpty);
      },
    );
  }

  for (final failure in ['false', 'throw']) {
    test(
      'boot preserves legacy policy when the settings write returns $failure',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final encoded = jsonEncode(_legacySettings());
        SharedPreferences.setMockInitialValues({'appSettings': encoded});
        final stored = await SharedPreferences.getInstance();
        final preferences = _MigrationPreferences(stored, failure);
        final jami = FakeJami()..accountExists = false;
        final state = AppState(jami, preferences);
        addTearDown(state.dispose);

        await state.init();

        expect(
          state.appSettings.globalMicrophoneMode,
          MicrophoneMode.pushToTalk,
        );
        expect(state.appSettings.showMessageInNotification, isFalse);
        expect(state.appSettings.appLockEnabled, isTrue);
        expect(state.maxIncomingFileBytes, 4096);
        expect(state.folderKeepLast, 25);
        expect(jami.messagePreviewCalls, [false]);
        expect(stored.getString('appSettings'), encoded);
        expect(state.settingsError, isNotNull);

        preferences.failure = null;
        expect(
          await state.setGlobalMicrophoneMode(MicrophoneMode.open),
          isTrue,
        );
        expect(state.settingsError, isNull);
        expect(
          (jsonDecode(stored.getString('appSettings')!)
              as Map)['schemaVersion'],
          AppSettings.currentSchemaVersion,
        );
      },
    );
  }
}
