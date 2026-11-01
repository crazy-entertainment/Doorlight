import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'app_state_test.dart' show FakeJami;

class _Store extends InMemorySharedPreferencesStore {
  _Store()
    : super.withData({
        'flutter.displayName': 'Me',
        'flutter.connectionProfile': 'jami',
        'flutter.appearOffline': false,
        'flutter.appSettings': jsonEncode(
          const AppSettingsCodec().encode(
            AppSettings(globalMicrophoneMode: MicrophoneMode.pushToTalk),
          ),
        ),
      });
  String? blockedKey;
  int blockedWrite = 1;
  int writes = 0;
  Completer<void> entered = Completer<void>();
  Completer<void> release = Completer<void>();
  bool rejectDocument = false;
  bool throwDocument = false;
  bool failRead = false;
  String? rejectedKey;
  int rejectedAttempt = 1;
  bool rejectThrows = false;
  final attempts = <String, int>{};
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final attempt = attempts.update(
      key,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    if (key == rejectedKey && attempt == rejectedAttempt) {
      if (rejectThrows) throw StateError('private rejected write');
      return false;
    }
    if (key == blockedKey && ++writes == blockedWrite) {
      entered.complete();
      await release.future;
    }
    if (key == 'flutter.appSettings') {
      if (throwDocument) throw StateError('private storage payload');
      if (rejectDocument) return false;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('private read payload');
    return super.getAll();
  }

  Future<void> canonicalSave(String document) async {
    await super.setValue('String', 'flutter.appSettings', document);
  }

  Future<Map<String, Object?>> durableDocument() async =>
      Map<String, Object?>.from(
        jsonDecode((await super.getAll())['flutter.appSettings']! as String)
            as Map,
      );
}

class _CanonicalJami extends FakeJami {
  _CanonicalJami(this.store);
  final _Store store;
  Completer<void>? saveEntered;
  Completer<void>? saveRelease;
  @override
  bool get usesNativeAppSettingsStore => true;
  @override
  Future<void> saveAppSettingsDocument(String document) async {
    saveEntered?.complete();
    await saveRelease?.future;
    await store.canonicalSave(document);
  }
}

class _DelayedProfileJami extends FakeJami {
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  final profileOwners = <String?>[];
  @override
  Future<bool> updateProfile({
    required String displayName,
    required String avatarBase64,
    required String fileType,
    required int flag,
    String? expectedAccountId,
  }) async {
    profileOwners.add(expectedAccountId);
    if (hold && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.updateProfile(
      displayName: displayName,
      avatarBase64: avatarBase64,
      fileType: fileType,
      flag: flag,
      expectedAccountId: expectedAccountId,
    );
  }
}

class _CleanupProfileJami extends FakeJami {
  final cleanupEntered = Completer<void>();
  final cleanupRelease = Completer<void>();
  final editRelease = Completer<void>();
  int profileCalls = 0;
  @override
  Future<void> discardPickedFile(String path) async {
    cleanupEntered.complete();
    await cleanupRelease.future;
    await super.discardPickedFile(path);
  }

  @override
  Future<bool> updateProfile({
    required String displayName,
    required String avatarBase64,
    required String fileType,
    required int flag,
    String? expectedAccountId,
  }) async {
    profileCalls++;
    if (displayName == 'During cleanup' || flag == 2) await editRelease.future;
    return super.updateProfile(
      displayName: displayName,
      avatarBase64: avatarBase64,
      fileType: fileType,
      flag: flag,
      expectedAccountId: expectedAccountId,
    );
  }
}

Future<(AppState, FakeJami, _Store)> _boot({
  bool canonical = false,
  FakeJami? client,
}) async {
  SharedPreferences.resetStatic();
  final prior = SharedPreferencesStorePlatform.instance;
  final store = _Store();
  SharedPreferencesStorePlatform.instance = store;
  addTearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = prior;
  });
  final jami = client ?? (canonical ? _CanonicalJami(store) : FakeJami());
  final state = AppState(jami, await SharedPreferences.getInstance());
  await state.init();
  await pumpEventQueue();
  state.seedCaptureStateForTesting(
    resolved: true,
    applied: WindowCaptureProtectionStatus.exclude,
  );
  addTearDown(state.dispose);
  return (state, jami, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final avatar in [false, true]) {
    test(
      'restore retains its guard through cleanup and automatic recovery: avatar=$avatar',
      () async {
        final jami = _CleanupProfileJami();
        final (state, _, _) = await _boot(client: jami);
        jami.restoreResult = {'status': 'error'};
        final before = jami.profileCalls;
        final ensures = jami.calls
            .where((call) => call.startsWith('ensureAccount:'))
            .length;
        final restore = state.restoreIdentity(
          'secret',
          backupPath: 'synthetic-backup',
        );
        await jami.cleanupEntered.future;
        final edit = avatar
            ? state.updateProfileAvatar(null)
            : state.updateDisplayName('During cleanup');
        await pumpEventQueue();
        try {
          expect(jami.profileCalls, before);
        } finally {
          jami.cleanupRelease.complete();
          await restore;
          jami.editRelease.complete();
          expect(await edit, false);
        }
        expect(
          jami.calls.where((call) => call.startsWith('ensureAccount:')).length,
          ensures + 1,
        );
        expect(state.bootError, isNull);
      },
    );
  }
  for (final avatar in [false, true]) {
    test(
      'profile completion after disposal is inert: avatar=$avatar',
      () async {
        final jami = _DelayedProfileJami();
        final (state, _, _) = await _boot(client: jami);
        jami.hold = true;
        final edit = avatar
            ? state.updateProfileAvatar(null)
            : state.updateDisplayName('Old edit');
        await jami.entered.future;
        state.dispose();
        jami.release.complete();
        expect(await edit, false);
        final calls = jami.profileOwners.length;
        expect(
          await (avatar
              ? state.updateProfileAvatar(null)
              : state.updateDisplayName('After disposal')),
          false,
        );
        expect(jami.profileOwners.length, calls);
      },
    );
    test(
      'profile mutation reserves identity transition admission: avatar=$avatar',
      () async {
        final jami = _DelayedProfileJami();
        final (state, _, _) = await _boot(client: jami);
        jami.hold = true;
        final edit = avatar
            ? state.updateProfileAvatar(null)
            : state.updateDisplayName('New name');
        await jami.entered.future;
        final ensures = jami.calls
            .where((call) => call.startsWith('ensureAccount:'))
            .length;
        try {
          expect(
            await state.restoreIdentity(
              'secret',
              backupPath: 'synthetic-backup',
            ),
            isNotNull,
          );
          expect(jami.lastRestoreArguments, isNull);
          expect(await state.beginDevicePairing(destination: false), false);
          expect(state.devicePairingStartError, contains('Finish the current'));
          await expectLater(state.onboard('Replacement'), throwsStateError);
          await state.retryBoot();
          expect(
            jami.calls
                .where((call) => call.startsWith('ensureAccount:'))
                .length,
            ensures,
          );
        } finally {
          jami.release.complete();
          expect(await edit, true);
        }
        expect(jami.profileOwners.last, 'acc1');
      },
    );
    test('profile edit is refused during adoption: avatar=$avatar', () async {
      final (state, jami, _) = await _boot();
      jami.pendingEnsure = Completer<Map<String, dynamic>>();
      final retry = state.retryBoot();
      await pumpEventQueue();
      try {
        expect(
          await (avatar
              ? state.updateProfileAvatar(null)
              : state.updateDisplayName('New name')),
          false,
        );
      } finally {
        jami.pendingEnsure!.complete({'status': 'noAccount'});
        await retry;
      }
    });
    for (final aba in [false, true]) {
      test(
        'stale profile completion preserves replacement projection/cache: avatar=$avatar aba=$aba',
        () async {
          final jami = _DelayedProfileJami();
          final (state, _, _) = await _boot(client: jami);
          jami.hold = true;
          final edit = avatar
              ? state.updateProfileAvatar(null)
              : state.updateDisplayName('Old edit');
          await jami.entered.future;
          state.accountId = 'replacement';
          if (aba) state.accountId = 'acc1';
          final replacementAvatar = base64Encode(
            image.encodePng(image.Image(width: 2, height: 2)),
          );
          state.displayName = 'Replacement';
          state.profileAvatarBase64 = replacementAvatar;
          await state.prefs.setString('displayName', 'Replacement');
          await state.prefs.setString('profileAvatarBase64', replacementAvatar);
          jami.release.complete();
          expect(await edit, false);
          expect(state.displayName, 'Replacement');
          expect(state.profileAvatarBase64, replacementAvatar);
          expect(state.prefs.getString('displayName'), 'Replacement');
          expect(
            state.prefs.getString('profileAvatarBase64'),
            replacementAvatar,
          );
        },
      );
    }
  }
  test('name and avatar edits share one mutation slot', () async {
    final jami = _DelayedProfileJami();
    final (state, _, _) = await _boot(client: jami);
    jami.hold = true;
    final edit = state.updateProfileAvatar(null);
    await jami.entered.future;
    final count = jami.profileOwners.length;
    try {
      expect(await state.updateDisplayName('Concurrent name'), false);
      expect(jami.profileOwners.length, count);
    } finally {
      jami.release.complete();
      expect(await edit, true);
    }
    jami.hold = false;
    expect(await state.updateDisplayName('Sequential name'), true);
    expect(state.displayName, 'Sequential name');
  });
  test(
    'startup migration excludes public app-lock changes until preparation completes',
    () async {
      SharedPreferences.resetStatic();
      final prior = SharedPreferencesStorePlatform.instance;
      final store = _Store();
      await store.canonicalSave(
        jsonEncode({
          ...const AppSettingsCodec().encode(
            AppSettings(folderHistoryLimit: 25),
          ),
          'schemaVersion': 13,
        }),
      );
      store.blockedKey = 'flutter.appSettings';
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = prior;
      });
      final state = AppState(FakeJami(), await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      final init = state.init();
      await store.entered.future;
      try {
        await expectLater(state.setAppLockEnabled(true), throwsStateError);
      } finally {
        store.release.complete();
        await init;
      }
      expect(state.appSettings.folderHistoryLimit, 25);
      await state.setAppLockEnabled(true);
      expect(state.appLockEnabled, true);
      expect(
        (await store.durableDocument())['files'],
        containsPair('folderHistoryLimit', 25),
      );
    },
  );
  for (final offline in [false, true]) {
    test(
      'a pending network writer excludes prepared restore recovery: offline=$offline',
      () async {
        final (state, jami, store) = await _boot();
        await jami.restoreIdentity(
          'synthetic-journal',
          'secret',
          appearOffline: true,
        );
        store.blockedKey = offline
            ? 'flutter.appearOffline'
            : 'flutter.connectionProfile';
        final write = offline
            ? state.setAppearOffline(true)
            : state.setConnectionProfile('lan');
        await store.entered.future;
        try {
          await state.retryBoot();
          expect(jami.restoreFinalizations, 0);
          expect(state.accountId, 'acc1');
        } finally {
          store.release.complete();
          await write;
        }
        await state.retryBoot();
        expect(jami.restoreFinalizations, 1);
        expect(state.accountId, 'restored-account');
      },
    );
  }
  test(
    'a native canonical write excludes prepared restore recovery until completion',
    () async {
      final (state, fake, _) = await _boot(canonical: true);
      final jami = fake as _CanonicalJami;
      await jami.restoreIdentity(
        'synthetic-journal',
        'secret',
        appearOffline: true,
      );
      jami.saveEntered = Completer<void>();
      jami.saveRelease = Completer<void>();
      final write = state.setGlobalMicrophoneMode(MicrophoneMode.open);
      await jami.saveEntered!.future;
      try {
        await state.retryBoot();
        expect(jami.restoreFinalizations, 0);
        expect(state.accountId, 'acc1');
        expect(jami.pendingIdentityRestore?['status'], 'prepared');
      } finally {
        jami.saveRelease!.complete();
        expect(await write, true);
        jami.saveEntered = null;
        jami.saveRelease = null;
      }
      await state.retryBoot();
      expect(jami.restoreFinalizations, 1);
      expect(state.accountId, 'restored-account');
    },
  );
  for (final locking in [false, true]) {
    test('adoption excludes a later settings writer: lock=$locking', () async {
      final (state, jami, store) = await _boot();
      jami.pendingEnsure = Completer<Map<String, dynamic>>();
      final retry = state.retryBoot();
      await pumpEventQueue();
      expect(state.settingsBusy, true);
      final attempts = Map<String, int>.of(store.attempts);
      try {
        if (locking) {
          await expectLater(state.setAppLockEnabled(true), throwsStateError);
          expect(state.appLockEnabled, false);
        } else {
          expect(
            await state.setGlobalMicrophoneMode(MicrophoneMode.open),
            false,
          );
          expect(
            state.appSettings.globalMicrophoneMode,
            MicrophoneMode.pushToTalk,
          );
        }
        expect(store.attempts, attempts);
      } finally {
        jami.pendingEnsure!.complete({'status': 'noAccount'});
        await retry;
      }
    });
  }
  for (final locking in [false, true]) {
    test(
      'a pending settings writer excludes boot adoption: lock=$locking',
      () async {
        final (state, jami, store) = await _boot();
        store.blockedKey = 'flutter.appSettings';
        final write = locking
            ? state.setAppLockEnabled(true)
            : state.setGlobalMicrophoneMode(MicrophoneMode.open);
        await store.entered.future;
        final ensures = jami.calls
            .where((call) => call.startsWith('ensureAccount:'))
            .length;
        try {
          await state.retryBoot();
          expect(state.bootError, isNotNull);
          expect(
            jami.calls
                .where((call) => call.startsWith('ensureAccount:'))
                .length,
            ensures,
          );
        } finally {
          store.release.complete();
          await write;
        }
        await state.retryBoot();
        expect(state.bootError, isNull);
        expect(
          jami.calls.where((call) => call.startsWith('ensureAccount:')).length,
          ensures + 1,
        );
      },
    );
  }
  for (final nativeFailure in [false, true]) {
    test(
      'prepared restore recovery waits for network reconciliation: native=$nativeFailure',
      () async {
        final (state, jami, store) = await _boot();
        if (nativeFailure) {
          jami.failConnectionProfile = true;
        } else {
          store.rejectedKey = 'flutter.connectionProfile';
          store.rejectedAttempt = (store.attempts[store.rejectedKey] ?? 0) + 1;
          store.failRead = true;
        }
        await state.setConnectionProfile('lan');
        jami.failConnectionProfile = false;
        await jami.restoreIdentity(
          'synthetic-journal',
          'secret',
          appearOffline: true,
        );
        await state.retryBoot();
        expect(jami.restoreFinalizations, 0);
        expect(state.accountId, 'acc1');
        expect(jami.pendingIdentityRestore?['status'], 'prepared');
        store.failRead = false;
        await state.setConnectionProfile('strict');
        await state.retryBoot();
        expect(jami.restoreFinalizations, 1);
        expect(state.accountId, 'restored-account');
        expect(state.appearOffline, true);
      },
    );
  }
  for (final nativeFailure in [false, true]) {
    for (final onboarding in [false, true]) {
      test(
        'adoption refuses completed unresolved network policy: native=$nativeFailure onboard=$onboarding',
        () async {
          final (state, jami, store) = await _boot();
          if (nativeFailure) {
            jami.failConnectionProfile = true;
          } else {
            store.rejectedKey = 'flutter.connectionProfile';
            store.rejectedAttempt =
                (store.attempts[store.rejectedKey] ?? 0) + 1;
            store.failRead = true;
          }
          await state.setConnectionProfile('lan');
          jami.failConnectionProfile = false;
          final ensures = jami.calls
              .where((call) => call.startsWith('ensureAccount:'))
              .length;
          if (onboarding) {
            await expectLater(state.onboard('Replacement'), throwsStateError);
          } else {
            await state.retryBoot();
            expect(state.bootError, isNotNull);
          }
          expect(
            jami.calls
                .where((call) => call.startsWith('ensureAccount:'))
                .length,
            ensures,
          );
        },
      );
    }
  }
  for (final offline in [false, true]) {
    for (final rollback in [false, true]) {
      for (final throws in [false, true]) {
        for (final linking in [false, true]) {
          test(
            'completed network failure blocks identity transition: offline=$offline rollback=$rollback throw=$throws link=$linking',
            () async {
              final (state, jami, store) = await _boot();
              final key = offline
                  ? 'flutter.appearOffline'
                  : 'flutter.connectionProfile';
              store.rejectedKey = key;
              store.rejectedAttempt =
                  (store.attempts[key] ?? 0) + (rollback ? 2 : 1);
              store.rejectThrows = throws;
              // Initial-save failures leave an unreadable optimistic cache.
              // Native failures need reconciliation even when reread succeeds.
              store.failRead = !rollback;
              jami.failAppearOffline = offline && rollback;
              jami.failConnectionProfile = !offline && rollback;
              if (offline) {
                await state.setAppearOffline(true);
              } else {
                await state.setConnectionProfile('lan');
              }
              jami.failAppearOffline = false;
              jami.failConnectionProfile = false;
              if (linking) {
                expect(
                  await state.beginDevicePairing(destination: false),
                  false,
                );
                expect(state.devicePairingStartError, contains('Restart'));
              } else {
                expect(
                  await state.restoreIdentity(
                    'secret',
                    backupPath: 'synthetic-backup',
                  ),
                  contains('Restart'),
                );
                expect(jami.lastRestoreArguments, isNull);
              }
            },
          );
        }
      }
    }
  }

  for (final offline in [false, true]) {
    test(
      'explicit same-value network retry reconciles a failed native change: offline=$offline',
      () async {
        final (state, jami, _) = await _boot();
        jami.failAppearOffline = offline;
        jami.failConnectionProfile = !offline;
        if (offline) {
          await state.setAppearOffline(true);
        } else {
          await state.setConnectionProfile('lan');
        }
        jami.failAppearOffline = false;
        jami.failConnectionProfile = false;
        expect(
          await state.restoreIdentity('secret', backupPath: 'blocked-backup'),
          contains('Restart'),
        );
        expect(jami.lastRestoreArguments, isNull);
        if (offline) {
          await state.setAppearOffline(false);
        } else {
          await state.setConnectionProfile('jami');
        }
        expect(
          await state.restoreIdentity('secret', backupPath: 'recovered-backup'),
          isNull,
        );
        expect(jami.lastRestoreArguments?['appearOffline'], true);
      },
    );
  }

  test(
    'initial-save cache recovery allows restore only after authoritative reread',
    () async {
      final (state, jami, store) = await _boot();
      store.rejectedKey = 'flutter.connectionProfile';
      store.rejectedAttempt = (store.attempts[store.rejectedKey] ?? 0) + 1;
      store.failRead = true;
      await state.setConnectionProfile('lan');
      expect(
        await state.restoreIdentity('secret', backupPath: 'blocked-backup'),
        contains('Restart'),
      );
      expect(jami.lastRestoreArguments, isNull);
      store.failRead = false;
      expect(
        await state.restoreIdentity('secret', backupPath: 'recovered-backup'),
        isNull,
      );
      expect(jami.lastRestoreArguments?['connectionProfile'], 'jami');
      expect(jami.lastRestoreArguments?['appearOffline'], true);
    },
  );
  for (final offline in [false, true]) {
    for (final rollback in [false, true]) {
      for (final linking in [false, true]) {
        test(
          'identity transition refuses in-flight network write: offline=$offline rollback=$rollback link=$linking',
          () async {
            final (state, jami, store) = await _boot();
            store.blockedKey = offline
                ? 'flutter.appearOffline'
                : 'flutter.connectionProfile';
            store.blockedWrite = rollback ? 2 : 1;
            jami.failAppearOffline = offline && rollback;
            jami.failConnectionProfile = !offline && rollback;
            final change = offline
                ? state.setAppearOffline(true)
                : state.setConnectionProfile('lan');
            await store.entered.future;
            try {
              if (linking) {
                expect(
                  await state.beginDevicePairing(destination: false),
                  false,
                );
                expect(
                  state.devicePairingStartError,
                  contains('Finish the current'),
                );
              } else {
                expect(
                  await state.restoreIdentity(
                    'secret',
                    backupPath: 'synthetic-backup',
                  ),
                  contains('Wait for the current'),
                );
                expect(jami.lastRestoreArguments, isNull);
              }
              expect(state.accountId, 'acc1');
            } finally {
              store.release.complete();
              await change;
            }
          },
        );
      }
    }
  }

  test('network toggle cannot enter boot account adoption', () async {
    SharedPreferences.setMockInitialValues({'displayName': 'Me'});
    final jami = FakeJami()..pendingEnsure = Completer<Map<String, dynamic>>();
    final state = AppState(jami, await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    final init = state.init();
    await pumpEventQueue();
    final calls = List<String>.of(jami.calls);
    await state.setAppearOffline(true);
    await state.setConnectionProfile('lan');
    expect(state.appearOffline, false);
    expect(state.connectionProfile, 'jami');
    expect(jami.calls, calls);
    jami.pendingEnsure!.complete({'status': 'noAccount'});
    await init;
  });

  for (final throws in [false, true]) {
    test(
      'failed document save cannot seed a new state from optimistic cache: throw=$throws',
      () async {
        final (state, _, store) = await _boot();
        store.rejectDocument = true;
        store.throwDocument = throws;
        expect(await state.setGlobalMicrophoneMode(MicrophoneMode.open), false);
        expect(
          state.appSettings.globalMicrophoneMode,
          MicrophoneMode.pushToTalk,
        );
        expect(
          (jsonDecode(state.prefs.getString('appSettings')!)
              as Map)['microphone']['globalDefault'],
          'pushToTalk',
        );
        final fresh = AppState(FakeJami(), state.prefs);
        addTearDown(fresh.dispose);
        await fresh.init();
        expect(
          fresh.appSettings.globalMicrophoneMode,
          MicrophoneMode.pushToTalk,
        );
        expect(fresh.settingsWritable, true);
      },
    );
  }
  test(
    'new state refuses an unreadable authoritative document after failed cache recovery',
    () async {
      final (state, _, store) = await _boot();
      store.rejectDocument = true;
      store.failRead = true;
      expect(await state.setGlobalMicrophoneMode(MicrophoneMode.open), false);
      final fresh = AppState(FakeJami(), state.prefs);
      addTearDown(fresh.dispose);
      await fresh.init();
      expect(fresh.settingsWritable, false);
      store.failRead = false;
      final recovered = AppState(FakeJami(), state.prefs);
      addTearDown(recovered.dispose);
      await recovered.init();
      expect(
        recovered.appSettings.globalMicrophoneMode,
        MicrophoneMode.pushToTalk,
      );
    },
  );
  test(
    'native canonical success remains success when cache refresh fails',
    () async {
      final (state, _, store) = await _boot(canonical: true);
      store.failRead = true;
      expect(await state.setGlobalMicrophoneMode(MicrophoneMode.open), true);
      expect(state.appSettings.globalMicrophoneMode, MicrophoneMode.open);
      expect(
        (await store.durableDocument())['microphone'],
        containsPair('globalDefault', 'open'),
      );
      expect(state.settingsError, contains('Settings were saved'));
    },
  );
}
