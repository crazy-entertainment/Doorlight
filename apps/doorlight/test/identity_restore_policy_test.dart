import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/core/jami.dart';

import 'app_state_test.dart' show FakeJami;

class _RestoreJami extends FakeJami {
  Completer<String?>? picker;
  Completer<void>? pickerStarted;
  Completer<void>? notification;
  Completer<void>? finalization;
  bool refuseFinalization = false;
  Map<String, dynamic>? pendingReply;

  bool discardAccepted = false;
  int discards = 0;
  String? discardedExpectedOwner;
  @override
  Future<bool> discardIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String? expectedAccountId,
  }) async {
    expect(accountId, 'incomplete-account');
    expect(restoreToken, 'restore-token');
    discards++;
    discardedExpectedOwner = expectedAccountId;
    if (discardAccepted) pendingReply = {'status': 'none'};
    return discardAccepted;
  }

  @override
  Future<String?> pickFile({
    String mimeType = '*/*',
    int maxBytes = JamiClient.maxPickedFileBytes,
  }) {
    if (pickerStarted?.isCompleted == false) pickerStarted!.complete();
    return picker?.future ??
        super.pickFile(mimeType: mimeType, maxBytes: maxBytes);
  }

  @override
  Future<void> setMessageNotificationPreview(
    bool showMessage, {
    required bool appLockEnabled,
  }) async {
    await notification?.future;
    await super.setMessageNotificationPreview(
      showMessage,
      appLockEnabled: appLockEnabled,
    );
  }

  @override
  Future<Map<String, dynamic>> getPendingIdentityRestore() async =>
      pendingReply ?? await super.getPendingIdentityRestore();

  @override
  Future<Map<String, dynamic>> finalizeIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String settingsDocument,
  }) async {
    await finalization?.future;
    if (refuseFinalization) return {'status': 'error'};
    return super.finalizeIdentityRestore(
      accountId: accountId,
      restoreToken: restoreToken,
      settingsDocument: settingsDocument,
    );
  }
}

class _AndroidRestoreJami extends _RestoreJami {
  @override
  bool get usesNativeAppSettingsStore => true;

  @override
  Future<Map<String, dynamic>> finalizeIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String settingsDocument,
  }) => JamiClient().finalizeIdentityRestore(
    accountId: accountId,
    restoreToken: restoreToken,
    settingsDocument: settingsDocument,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = AppSettingsCodec();
  final peer = 'b' * 40;
  final oldScope = ConversationScope(
    accountId: 'backup-owner',
    peerId: peer,
    conversationId: 'conversation',
  );
  final newScope = ConversationScope(
    accountId: 'restored-account',
    peerId: peer,
    conversationId: 'conversation',
  );

  Future<(AppState, _RestoreJami)> restoreFixture(
    AppSettings settings, {
    Map<String, Object> preferences = const {},
    _RestoreJami? client,
  }) async {
    SharedPreferences.setMockInitialValues(preferences);
    final jami = (client ?? _RestoreJami())..accountExists = false;
    final state = AppState(jami, await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await state.init();
    jami.messagePreviewCalls.clear();
    jami.restoreResult = {
      'status': 'ok',
      'accountId': 'restored-account',
      'jamiId': 'e' * 40,
      'displayName': 'Restored',
      'avatarBase64': '',
      'enabled': true,
      'announced': false,
      'registration': 'UNREGISTERED',
      'settingsDocument': jsonEncode({
        ...codec.encode(settings),
        'syblBackup': {'version': 1, 'sourceAccountId': 'backup-owner'},
      }),
      'backupSourceAccountId': 'backup-owner',
    };
    return (state, jami);
  }

  test(
    'restored hidden previews reach notification policy before Home',
    () async {
      final (state, jami) = await restoreFixture(
        AppSettings(showMessageInNotification: false),
      );
      final policyAtHome = <bool>[];
      state.addListener(() {
        if (state.screen == Screen.home) {
          policyAtHome.add(jami.messagePreviewCalls.lastOrNull ?? true);
        }
      });
      expect(await state.restoreIdentity('synthetic-password'), isNull);
      expect(jami.messagePreviewCalls, contains(false));
      expect(policyAtHome, isNotEmpty);
      expect(policyAtHome, everyElement(false));
    },
  );

  test('restore remaps only the established backup microphone owner', () async {
    final other = ConversationScope(
      accountId: 'other-owner',
      peerId: peer,
      conversationId: 'conversation',
    );
    final (state, _) = await restoreFixture(
      AppSettings(
        globalMicrophoneMode: MicrophoneMode.open,
        conversationMicrophoneModes: {
          oldScope: MicrophoneMode.pushToTalk,
          other: MicrophoneMode.pushToTalk,
        },
      ),
    );
    expect(await state.restoreIdentity('synthetic-password'), isNull);
    expect(
      state.appSettings.microphoneModeFor(newScope).mode,
      MicrophoneMode.pushToTalk,
    );
    expect(
      state.appSettings.conversationMicrophoneModes[other],
      MicrophoneMode.pushToTalk,
    );
    expect(
      state.appSettings.conversationMicrophoneModes.containsKey(oldScope),
      isFalse,
    );
  });

  for (final missingOwner in [true, false]) {
    test('ambiguous restore preserves all scopes and requires global choice: '
        'missing=$missingOwner', () async {
      final original = AppSettings(
        conversationMicrophoneModes: {
          oldScope: MicrophoneMode.pushToTalk,
          if (!missingOwner) newScope: MicrophoneMode.open,
        },
      );
      final (state, jami) = await restoreFixture(original);
      if (missingOwner) {
        jami.restoreResult!['settingsDocument'] = jsonEncode(
          codec.encode(original),
        );
        jami.restoreResult!.remove('backupSourceAccountId');
      }
      expect(await state.restoreIdentity('synthetic-password'), isNull);
      expect(
        state.appSettings.conversationMicrophoneModes,
        original.conversationMicrophoneModes,
      );
      expect(state.appSettings.microphoneReviewRequired, isTrue);
      expect(await state.setFolderHistoryLimit(123), isTrue);
      expect(state.appSettings.microphoneReviewRequired, isTrue);
      final saved = codec
          .decode(
            Map<String, Object?>.from(
              jsonDecode(state.prefs.getString('appSettings')!) as Map,
            ),
          )
          .settings;
      expect(saved.microphoneReviewRequired, isTrue);
      expect(
        await state.setGlobalMicrophoneMode(MicrophoneMode.pushToTalk),
        isTrue,
      );
      expect(state.appSettings.microphoneReviewRequired, isFalse);
      expect(
        state.appSettings.conversationMicrophoneModes,
        original.conversationMicrophoneModes,
      );
    });
  }

  test(
    'review state mutes actual direct placement and survives conversation edit',
    () async {
      final (state, jami) = await restoreFixture(
        AppSettings(microphoneReviewRequired: true),
      );
      jami.daemonFriends[peer] = JamiFriend(
        peerJamiId: peer,
        confirmed: true,
        conversationId: 'conversation',
      );
      expect(await state.restoreIdentity('synthetic-password'), isNull);
      await pumpEventQueue();
      await state.selectFriend(peer);
      jami.push('registrationState', {'state': 'REGISTERED'});
      expect(
        await state.setFriendMicrophoneMode(peer, MicrophoneMode.open),
        isTrue,
      );
      expect(state.appSettings.microphoneReviewRequired, isTrue);
      await state.startCallTo(peer);
      expect(jami.lastPlacedInitialAudioMuted, isTrue);
      expect(state.call?.micMuted, isTrue);
    },
  );

  test('restored settings retain the local app lock', () async {
    final (state, jami) = await restoreFixture(
      AppSettings(appLockEnabled: false),
      preferences: {'appLockEnabled.v1': true},
    );
    expect(await state.restoreIdentity('synthetic-password'), isNull);
    expect(state.appSettings.appLockEnabled, isTrue);
    expect(jami.messageAppLockCalls.last, isTrue);
    expect((jsonDecode(jami.finalizedRestoreDocument!) as Map)['appLock'], {
      'enabled': true,
    });
  });

  test(
    'corrupt local settings cannot become permissive restore defaults',
    () async {
      final (state, jami) = await restoreFixture(
        AppSettings(),
        preferences: {'appSettings': '{corrupt-local-policy'},
      );
      jami.restoreResult!['settingsDocument'] = '{corrupt-backup-policy';
      await expectLater(
        state.restoreIdentity('synthetic-password'),
        throwsStateError,
      );
      expect(jami.restoreFinalizations, 0);
      expect(state.screen, isNot(Screen.home));
      expect(state.prefs.getString('appSettings'), '{corrupt-local-policy');
    },
  );

  for (final kind in [null, 'future', 42]) {
    test(
      'invalid explicit backup scope kind $kind keeps valid local PTT',
      () async {
        final (state, jami) = await restoreFixture(
          AppSettings(),
          preferences: {
            'appSettings': jsonEncode(
              codec.encode(
                AppSettings(globalMicrophoneMode: MicrophoneMode.pushToTalk),
              ),
            ),
          },
        );
        final backup = codec.encode(AppSettings());
        (backup['microphone'] as Map)['conversationOverrides'] = [
          {...oldScope.toMap(), 'mode': 'open', 'kind': kind},
        ];
        jami.restoreResult!['settingsDocument'] = jsonEncode(backup);
        expect(await state.restoreIdentity('synthetic-password'), isNull);
        expect(
          state.appSettings.globalMicrophoneMode,
          MicrophoneMode.pushToTalk,
        );
        expect(state.appSettings.conversationMicrophoneModes, isEmpty);
        expect(state.settingsError, contains('Local settings were kept'));
      },
    );
  }

  test(
    'failed notification commit retains prepared identity for retry',
    () async {
      final (state, jami) = await restoreFixture(
        AppSettings(showMessageInNotification: false),
      );
      jami.failMessageNotificationPolicy = true;
      await expectLater(
        state.restoreIdentity('synthetic-password'),
        throwsStateError,
      );
      expect(jami.restoreFinalizations, 0);
      expect(jami.pendingIdentityRestore?['enabled'], isFalse);
      expect(state.screen, Screen.loading);
      jami.failMessageNotificationPolicy = false;
      await state.retryBoot();
      expect(state.screen, Screen.home);
      expect(jami.restoreFinalizations, 1);
      expect(jami.pickFileCalls, 1);
      expect(state.appSettings.showMessageInNotification, isFalse);
    },
  );

  test(
    'refused finalization stays out of Home and can resume without import',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      jami.refuseFinalization = true;
      await expectLater(
        state.restoreIdentity('synthetic-password'),
        throwsStateError,
      );
      expect(state.screen, Screen.loading);
      expect(jami.pendingIdentityRestore, isNotNull);
      await state.retryBoot();
      expect(state.pendingIdentityRecovery, isTrue);
      expect(state.bootError, 'An unfinished restore needs attention.');
      jami.refuseFinalization = false;
      await state.retryBoot();
      expect(state.screen, Screen.home);
      expect(jami.pickFileCalls, 1);
    },
  );

  test(
    'stale app-lock action cannot change policy while restore finalizes',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      jami.finalization = Completer<void>();
      final pending = state.restoreIdentity('synthetic-password');
      await pumpEventQueue();
      try {
        await expectLater(state.setAppLockEnabled(true), throwsStateError);
        expect(state.prefs.getBool('appLockEnabled.v1'), isFalse);
        expect(state.appSettings.appLockEnabled, isFalse);
      } finally {
        jami.finalization!.complete();
        await pending;
      }
    },
  );

  test('unknown pending journal blocks ordinary boot adoption', () async {
    final (state, jami) = await restoreFixture(AppSettings());
    final before = jami.calls
        .where((x) => x.startsWith('ensureAccount:'))
        .length;
    jami.pendingReply = {'status': 'recoveryRequired'};
    state.screen = Screen.loading;
    await state.retryBoot();
    expect(state.bootError, isNotNull);
    expect(
      jami.calls.where((x) => x.startsWith('ensureAccount:')).length,
      before,
    );
  });

  test(
    'engine unavailability does not claim a pending identity restore',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      jami.pendingReply = {'status': 'engineUnavailable'};
      await state.retryBoot();
      expect(state.pendingIdentityRecovery, isFalse);
      expect(state.canDiscardIdentityRestore, isFalse);
      expect(state.bootErrorDetails, contains('native_startup_failed'));
    },
  );

  test(
    'archive protection failure stays closed without claiming an unfinished restore',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      final before = jami.calls
          .where((x) => x.startsWith('ensureAccount:'))
          .length;
      jami.pendingReply = {'status': 'archiveProtectionUnavailable'};
      await state.retryBoot();
      expect(state.profileProtectionUnavailable, isTrue);
      expect(state.pendingIdentityRecovery, isFalse);
      expect(state.canDiscardIdentityRestore, isFalse);
      expect(state.bootError, "Couldn't open the saved profile.");
      expect(state.bootErrorDetails, contains('archive_protection_failed'));
      expect(
        state.bootErrorDetails,
        isNot(contains('unfinished identity restore')),
      );
      expect(
        jami.calls.where((x) => x.startsWith('ensureAccount:')).length,
        before,
      );
      jami.pendingReply = {'status': 'none'};
      await state.retryBoot();
      expect(state.profileProtectionUnavailable, isFalse);
      expect(state.bootError, isNull);
    },
  );

  test('unbound recovery cannot be discarded', () async {
    final (state, jami) = await restoreFixture(AppSettings());
    jami.pendingReply = {
      'status': 'recoveryRequired',
      'recoveryReason': 'journalUnreadable',
      'canDiscard': false,
    };
    await state.retryBoot();
    expect(state.pendingIdentityRecovery, isTrue);
    expect(state.identityRecoveryTitle, contains('record could not be read'));
    expect(await state.discardIdentityRestore(null), isFalse);
    expect(jami.discards, 0);
  });

  test('unknown startup reply makes no identity recovery claim', () async {
    final (state, jami) = await restoreFixture(AppSettings());
    jami.pendingReply = {
      'status': 'unexpected',
      'recoveryReason': 'private/path',
    };
    await state.retryBoot();
    expect(state.pendingIdentityRecovery, isFalse);
    expect(state.canDiscardIdentityRestore, isFalse);
    expect(state.bootError, "Couldn't start the engine.");
    expect(
      state.bootErrorDetails,
      contains('Startup could not complete this step.'),
    );
    expect(state.bootErrorDetails, isNot(contains('private/path')));
  });

  for (final status in ['engineUnavailable', 'recoveryRequired']) {
    test('$status with retired engine requires relaunch', () async {
      final (state, jami) = await restoreFixture(AppSettings());
      jami.pendingReply = {
        'status': status,
        'recoveryReason': 'restartRequired',
        'restartRequired': true,
        'canDiscard': true,
        'accountId': 'incomplete-account',
        'restoreToken': 'restore-token',
      };
      await state.retryBoot();
      expect(state.relaunchRequired, isTrue);
      expect(state.pendingIdentityRecovery, status == 'recoveryRequired');
      expect(state.canDiscardIdentityRestore, isFalse);
    });
  }

  test(
    'non-prepared import reconciles pending recovery before returning',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      jami.restoreResult = {'status': 'error'};
      jami.pendingReply = {'status': 'recoveryRequired', 'canDiscard': false};
      expect(await state.restoreIdentity('password'), isNotNull);
      expect(state.screen, Screen.loading);
      expect(state.pendingIdentityRecovery, isTrue);
    },
  );

  test(
    'discard requires exact confirmed owner and terminal acknowledgment',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      state.screen = Screen.loading;
      jami.pendingReply = {
        'status': 'recoveryRequired',
        'canDiscard': true,
        'accountId': 'incomplete-account',
        'restoreToken': 'restore-token',
      };
      await state.retryBoot();
      final owner = state.identityRestoreRecoveryOwner;
      expect(
        await state.discardIdentityRestore(('other-account', 'restore-token')),
        isFalse,
      );
      expect(jami.discards, 0);
      expect(await state.discardIdentityRestore(owner), isFalse);
      expect(state.pendingIdentityRecovery, isTrue);
      expect(state.screen, Screen.loading);
      jami.discardAccepted = true;
      expect(await state.discardIdentityRestore(owner), isTrue);
      expect(jami.discards, 2);
      expect(state.pendingIdentityRecovery, isFalse);
      expect(state.screen, Screen.onboarding);
    },
  );

  test(
    'discard uses native recovery owner instead of stale preference hint',
    () async {
      final (state, jami) = await restoreFixture(AppSettings());
      state.accountId = 'previous-profile';
      state.screen = Screen.loading;
      jami.pendingReply = {
        'status': 'recoveryRequired',
        'canDiscard': true,
        'accountId': 'incomplete-account',
        'restoreToken': 'restore-token',
        'recoveryOwnerAccountId': '',
      };
      await state.retryBoot();
      await state.discardIdentityRestore(state.identityRestoreRecoveryOwner);
      expect(jami.discardedExpectedOwner, '');
      expect(jami.discards, 1);
    },
  );

  test('picker account A-B-A cannot start a restore', () async {
    final (state, jami) = await restoreFixture(AppSettings());
    state.accountId = 'A';
    jami.picker = Completer<String?>();
    jami.pickerStarted = Completer<void>();
    final pending = state.restoreIdentity('synthetic-password');
    await jami.pickerStarted!.future;
    state.accountId = 'B';
    state.accountId = 'A';
    jami.picker!.complete('synthetic-picked-file');
    expect(await pending, isNull);
    expect(jami.lastRestoreArguments, isNull);
    expect(jami.discardedPickedFiles, ['synthetic-picked-file']);
  });

  for (final stage in ['notification', 'finalization']) {
    test('late $stage cannot adopt an account after A-B-A', () async {
      final (state, jami) = await restoreFixture(AppSettings());
      state.accountId = 'A';
      final gate = Completer<void>();
      if (stage == 'notification') {
        jami.notification = gate;
      } else {
        jami.finalization = gate;
      }
      final pending = state.restoreIdentity('synthetic-password');
      final assertion = expectLater(pending, throwsStateError);
      await pumpEventQueue();
      state.accountId = 'B';
      state.accountId = 'A';
      gate.complete();
      await assertion;
      expect(state.accountId, 'A');
      expect(state.screen, isNot(Screen.home));
      expect(state.prefs.getString('accountId'), isNull);
      expect(jami.lastProfileDisplayName, isNull);
    });
  }

  for (final outcome in ['ok', 'error', 'throw']) {
    test(
      'Android restore uses one owner-checked canonical channel: $outcome',
      () async {
        const channel = MethodChannel('syb.l/core');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final restored = AppSettings(
          showMessageInNotification: false,
          conversationMicrophoneModes: {oldScope: MicrophoneMode.pushToTalk},
        );
        final (state, jami) = await restoreFixture(
          restored,
          client: _AndroidRestoreJami(),
          preferences: {'appSettings': jsonEncode(codec.encode(AppSettings()))},
        );
        final commands = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          commands.add(call.method);
          expect(call.method, 'finalizeIdentityRestore');
          final arguments = call.arguments as Map;
          expect(arguments['accountId'], 'restored-account');
          expect(arguments['restoreToken'], 'synthetic-restore-token');
          final settings = codec
              .decode(
                Map<String, Object?>.from(
                  jsonDecode(arguments['settingsDocument'] as String) as Map,
                ),
              )
              .settings;
          expect(settings.showMessageInNotification, isFalse);
          expect(
            settings.microphoneModeFor(newScope).mode,
            MicrophoneMode.pushToTalk,
          );
          expect(state.screen, isNot(Screen.home));
          if (outcome == 'throw') {
            throw PlatformException(code: 'synthetic-failure');
          }
          if (outcome == 'error') return {'status': 'error'};
          // This fixture acknowledges the native transaction; native durability
          // and notification-answer ordering have separate JVM regressions.
          await state.prefs.setString(
            'appSettings',
            arguments['settingsDocument'] as String,
          );
          return {...jami.pendingRestoreFinalResult!, 'status': 'ok'};
        });
        if (outcome == 'ok') {
          expect(await state.restoreIdentity('synthetic-password'), isNull);
          expect(state.screen, Screen.home);
        } else {
          await expectLater(
            state.restoreIdentity('synthetic-password'),
            throwsA(anything),
          );
          expect(state.screen, isNot(Screen.home));
          expect(state.pendingIdentityRecovery, isTrue);
        }
        expect(
          commands,
          [
            'finalizeIdentityRestore',
            if (outcome != 'ok') 'finalizeIdentityRestore',
          ],
          reason:
              'Failed imports reconcile the exact pending transaction before showing recovery.',
        );
        expect(
          jami.messagePreviewCalls,
          isEmpty,
          reason: 'No unscoped mirror command can race native finalization.',
        );
      },
    );
  }
}
