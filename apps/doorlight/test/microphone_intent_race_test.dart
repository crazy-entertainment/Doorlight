import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _ControlledJami extends FakeJami {
  bool nativeSettings = false;
  Completer<void>? pendingUnmute;
  bool rejectMute = false;
  final muteCommands = <(String, bool)>[];
  final acknowledged = <String, bool>{'direct': true};

  @override
  bool get usesNativeAppSettingsStore => nativeSettings;

  @override
  Future<void> setMicMuted(String id, bool muted) async {
    muteCommands.add((id, muted));
    if (muted && rejectMute) throw StateError('synthetic mute refusal');
    if (!muted) await pendingUnmute?.future;
    acknowledged[id] = muted;
  }
}

class _DelayedReloadPreferences extends Fake implements SharedPreferences {
  _DelayedReloadPreferences(this.stored);
  final SharedPreferences stored;
  final reloadStarted = Completer<void>();
  final finishReload = Completer<void>();
  bool delayReload = false;

  @override
  Object? get(String key) => stored.get(key);
  @override
  bool containsKey(String key) => stored.containsKey(key);
  @override
  String? getString(String key) => stored.getString(key);
  @override
  bool? getBool(String key) => stored.getBool(key);
  @override
  Future<bool> setBool(String key, bool value) => stored.setBool(key, value);
  @override
  Future<bool> setString(String key, String value) =>
      stored.setString(key, value);
  @override
  Future<bool> remove(String key) => stored.remove(key);
  @override
  Future<void> reload() async {
    if (delayReload) {
      reloadStarted.complete();
      await finishReload.future;
    }
    await stored.reload();
  }
}

CallSession _session({
  String id = 'direct',
  MicrophoneMode mode = MicrophoneMode.pushToTalk,
}) => CallSession(
  callId: id,
  dir: CallDir.incoming,
  peerId: 'b' * 40,
  state: 'CURRENT',
  micMode: mode,
  micMuted: true,
  microphonePolicyApplied: true,
);

Future<(AppState, _ControlledJami, CallSession)> _direct() async {
  SharedPreferences.setMockInitialValues({});
  final jami = _ControlledJami();
  final state = AppState(jami, await SharedPreferences.getInstance());
  final call = _session();
  state.call = call;
  addTearDown(state.dispose);
  return (state, jami, call);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final manual in [false, true]) {
    test(
      'latest ${manual ? 'manual mute' : 'PTT release'} wins after delayed direct unmute',
      () async {
        final (state, jami, session) = await _direct();
        jami.pendingUnmute = Completer<void>();
        final press = state.pttHold(true);
        await pumpEventQueue();
        expect(jami.muteCommands, [('direct', false)]);
        final close = manual ? state.toggleMute() : state.pttHold(false);
        jami.pendingUnmute!.complete();
        await Future.wait([press, close]);
        expect(jami.acknowledged['direct'], isTrue);
        expect(session.micMuted, isTrue);
        if (manual) {
          expect(session.manuallyMuted, isTrue);
        } else {
          expect(session.pushToTalkPressed, isFalse);
        }
        expect(jami.muteCommands, [('direct', false), ('direct', true)]);
      },
    );
  }

  test('failed old direct unmute cannot restore a released hold', () async {
    final (state, jami, session) = await _direct();
    jami.pendingUnmute = Completer<void>();
    final press = state.pttHold(true);
    await pumpEventQueue();
    final release = state.pttHold(false);
    jami.pendingUnmute!.completeError(StateError('synthetic late failure'));
    await Future.wait([press, release]);
    expect(session.pushToTalkPressed, isFalse);
    expect(jami.acknowledged['direct'], isTrue);
    expect(session.micMuted, isTrue);
  });

  test(
    'failed direct release retains intent and requests exact teardown',
    () async {
      final (state, jami, session) = await _direct();
      await state.pttHold(true);
      jami.rejectMute = true;
      await state.pttHold(false);
      expect(session.pushToTalkPressed, isFalse);
      expect(jami.calls, contains('hangUp:direct'));
      expect(state.microphoneError, isNotNull);
      expect(session.acknowledgedMicrophoneMuted, isNull);
      final commands = jami.muteCommands.length;
      await state.pttHold(true);
      expect(jami.muteCommands.length, commands);
    },
  );

  for (final lock in [false, true]) {
    test(
      '${lock ? 'app lock' : 'focus loss'} clears pending PTT and does not restore it',
      () async {
        final (state, jami, session) = await _direct();
        jami.pendingUnmute = Completer<void>();
        final press = state.pttHold(true);
        await pumpEventQueue();
        if (lock) {
          state.setProtectedSurfaceLocked(true);
        } else {
          state.didChangeAppLifecycleState(AppLifecycleState.inactive);
        }
        expect(session.pushToTalkPressed, isFalse);
        jami.pendingUnmute!.complete();
        await press;
        await pumpEventQueue();
        expect(jami.acknowledged['direct'], isTrue);
        if (lock) {
          state.setProtectedSurfaceLocked(false);
        } else {
          state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        }
        expect(session.pushToTalkPressed, isFalse);
        expect(jami.acknowledged['direct'], isTrue);
      },
    );
  }

  test('old direct completion cannot change a replacement session', () async {
    final (state, jami, previous) = await _direct();
    jami.pendingUnmute = Completer<void>();
    final press = state.pttHold(true);
    await pumpEventQueue();
    final replacement = _session(id: 'replacement');
    state.call = replacement;
    jami.pendingUnmute!.complete();
    await press;
    expect(state.call, same(replacement));
    expect(replacement.micMuted, isTrue);
    expect(replacement.pushToTalkPressed, isFalse);
    expect(
      jami.muteCommands.where((entry) => entry.$1 == 'replacement'),
      isEmpty,
    );
    expect(previous, isNot(same(replacement)));
  });

  test(
    'an account A-B-A change cannot revive an old direct completion',
    () async {
      final (state, jami, session) = await _direct();
      state.accountId = 'account-a';
      jami.pendingUnmute = Completer<void>();
      final press = state.pttHold(true);
      await pumpEventQueue();
      state.accountId = 'account-b';
      state.accountId = 'account-a';
      jami.pendingUnmute!.complete();
      await press;
      expect(session.acknowledgedMicrophoneMuted, isTrue);
      expect(session.micMuted, isTrue);
    },
  );

  for (final fail in [false, true]) {
    test(
      'pending Android Open save and failure do not reopen a microphone: throw=$fail',
      () async {
        SharedPreferences.setMockInitialValues({
          'appSettings': jsonEncode(
            const AppSettingsCodec().encode(AppSettings()),
          ),
        });
        final jami = _ControlledJami()
          ..nativeSettings = true
          ..accountExists = false;
        final state = AppState(jami, await SharedPreferences.getInstance());
        addTearDown(state.dispose);
        await state.init();
        final session = _session(mode: MicrophoneMode.open)
          ..micMuted = false
          ..acknowledgedMicrophoneMuted = false;
        state.call = session;
        jami.acknowledged['direct'] = false;
        final result = Completer<bool>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveAppSettingsDocument');
          return result.future;
        });
        final save = state.setGlobalMicrophoneMode(MicrophoneMode.open);
        await pumpEventQueue();
        expect(jami.acknowledged['direct'], isTrue);
        if (fail) {
          result.completeError(StateError('synthetic save failure'));
        } else {
          result.complete(false);
        }
        expect(await save, isFalse);
        await state.toggleMute();
        await state.toggleMute();
        expect(jami.acknowledged['direct'], isTrue);
        expect(jami.muteCommands, isNot(contains(('direct', false))));
      },
    );
  }

  for (final document in [null, '{', '{"schemaVersion":99}']) {
    test('unknown Android canonical policy stays muted: $document', () async {
      SharedPreferences.setMockInitialValues({'appSettings': ?document});
      final jami = _ControlledJami()
        ..nativeSettings = true
        ..accountExists = false;
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      state.call = _session(mode: MicrophoneMode.open);
      state.call!.state = 'RINGING';
      await state.answer(state.call!);
      state.call!.state = 'CURRENT';
      expect(jami.calls, contains('answer:direct'));
      expect(jami.lastAnsweredInitialAudioMuted, isTrue);
      await state.toggleMute();
      await state.toggleMute();
      expect(jami.muteCommands, isNot(contains(('direct', false))));
    });
  }

  test('explicit durable Open recovers an unknown Android policy', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final jami = _ControlledJami()
      ..nativeSettings = true
      ..accountExists = false;
    final state = AppState(jami, preferences);
    addTearDown(state.dispose);
    await state.init();
    state.call = _session(mode: MicrophoneMode.open);
    final saved = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'saveAppSettingsDocument');
      final ok = await saved.future;
      if (ok) {
        await preferences.setString(
          'appSettings',
          (call.arguments as Map)['document'] as String,
        );
      }
      return ok;
    });
    final request = state.setGlobalMicrophoneMode(MicrophoneMode.open);
    await pumpEventQueue();
    expect(jami.muteCommands, isNot(contains(('direct', false))));
    saved.complete(true);
    expect(await request, isTrue);
    await pumpEventQueue();
    expect(jami.acknowledged['direct'], isFalse);
  });

  for (final group in [false, true]) {
    for (final waitForCache in [false, true]) {
      test(
        'older ${group ? 'group' : 'direct'} Open save preserves newer manual mute during ${waitForCache ? 'cache reload' : 'persistence'}',
        () async {
          SharedPreferences.setMockInitialValues({
            'appSettings': jsonEncode(
              const AppSettingsCodec().encode(
                AppSettings().withGlobalMicrophoneMode(
                  MicrophoneMode.pushToTalk,
                ),
              ),
            ),
          });
          final preferences = _DelayedReloadPreferences(
            await SharedPreferences.getInstance(),
          );
          final jami = _ControlledJami()
            ..nativeSettings = true
            ..accountExists = false;
          final state = AppState(jami, preferences);
          addTearDown(state.dispose);
          await state.init();
          expect(preferences.reloadStarted.isCompleted, false);
          preferences.delayReload = true;
          state.accountId = 'account-a';
          if (group) {
            state.seedEmptyRuntimeSnapshotForTesting(
              friends: const [],
              selectedFixtureGroupId: 'b' * 40,
              groups: [
                GroupState(
                  conversationId: 'b' * 40,
                  title: 'Group',
                  memberCount: 1,
                  canManageMembers: true,
                  memberIds: const [],
                  activeMemberIds: const {},
                  invitedMemberIds: const {},
                ),
              ],
            );
            state.groupCall = GroupCallSession(
              conversationId: 'b' * 40,
              roomId: 'voice',
              conferenceId: 'syblv1-voice-42',
              sessionId: 'session42',
              phase: GroupCallPhase.connected,
              micMuted: true,
              micMode: MicrophoneMode.pushToTalk,
            );
          } else {
            state.call = _session();
          }
          final persistence = Completer<void>();
          messenger.setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'saveAppSettingsDocument');
            await persistence.future;
            await preferences.stored.setString(
              'appSettings',
              (call.arguments as Map)['document'] as String,
            );
            return true;
          });
          final save = group
              ? state.setGroupMicrophoneMode('b' * 40, MicrophoneMode.open)
              : state.setGlobalMicrophoneMode(MicrophoneMode.open);
          if (waitForCache) {
            persistence.complete();
            await preferences.reloadStarted.future;
            await pumpEventQueue();
          } else {
            await pumpEventQueue();
          }
          if (group) {
            await state.setGroupMicMuted(true);
          } else {
            await state.toggleMute();
          }
          expect(
            state.groupCall?.manuallyMuted ?? state.call!.manuallyMuted,
            isTrue,
          );
          if (!waitForCache) {
            persistence.complete();
            await preferences.reloadStarted.future;
          }
          preferences.finishReload.complete();
          expect(await save, isTrue);
          await pumpEventQueue();
          expect(
            state.groupCall?.manuallyMuted ?? state.call!.manuallyMuted,
            isTrue,
          );
          expect(state.groupCall?.micMuted ?? state.call!.micMuted, isTrue);
        },
      );
    }
  }

  for (final group in [false, true]) {
    test(
      'durable ${group ? 'group' : 'direct'} mode change resets only the existing manual mute and permits PTT',
      () async {
        SharedPreferences.setMockInitialValues({
          'appSettings': jsonEncode(
            const AppSettingsCodec().encode(AppSettings()),
          ),
        });
        final preferences = await SharedPreferences.getInstance();
        final jami = _ControlledJami()
          ..nativeSettings = true
          ..accountExists = false;
        final state = AppState(jami, preferences);
        addTearDown(state.dispose);
        await state.init();
        state.accountId = 'account-a';
        if (group) {
          state.seedEmptyRuntimeSnapshotForTesting(
            friends: const [],
            selectedFixtureGroupId: 'b' * 40,
            groups: [
              GroupState(
                conversationId: 'b' * 40,
                title: 'Group',
                memberCount: 1,
                canManageMembers: true,
                memberIds: const [],
                activeMemberIds: const {},
                invitedMemberIds: const {},
              ),
            ],
          );
          state.groupCall = GroupCallSession(
            conversationId: 'b' * 40,
            roomId: 'voice',
            conferenceId: 'syblv1-voice-42',
            sessionId: 'session42',
            phase: GroupCallPhase.connected,
            micMuted: true,
          );
          await state.setGroupMicMuted(true);
        } else {
          state.call = _session(mode: MicrophoneMode.open);
          await state.toggleMute();
        }
        final persistence = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveAppSettingsDocument');
          await persistence.future;
          await preferences.setString(
            'appSettings',
            (call.arguments as Map)['document'] as String,
          );
          return true;
        });
        final save = group
            ? state.setGroupMicrophoneMode('b' * 40, MicrophoneMode.pushToTalk)
            : state.setGlobalMicrophoneMode(MicrophoneMode.pushToTalk);
        await pumpEventQueue();
        expect(
          state.groupCall?.manuallyMuted ?? state.call!.manuallyMuted,
          isTrue,
        );
        expect(state.groupCall?.micMuted ?? state.call!.micMuted, isTrue);
        persistence.complete();
        expect(await save, isTrue);
        expect(
          state.groupCall?.manuallyMuted ?? state.call!.manuallyMuted,
          isFalse,
        );
        if (group) {
          await state.groupPushToTalk(true);
        } else {
          await state.pttHold(true);
        }
        expect(state.groupCall?.micMuted ?? state.call!.micMuted, isFalse);
        if (group) {
          await state.groupPushToTalk(false);
        } else {
          await state.pttHold(false);
        }
        expect(state.groupCall?.micMuted ?? state.call!.micMuted, isTrue);
      },
    );
  }

  test(
    'valid Android v1 policy ignores modern microphone extras during migration',
    () async {
      SharedPreferences.setMockInitialValues({
        'appSettings': jsonEncode({
          'schemaVersion': 1,
          'microphoneMode': 'open',
          'microphone': {
            'conversationOverrides': [
              {'kind': null},
            ],
          },
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveAppSettingsDocument');
        await preferences.setString(
          'appSettings',
          (call.arguments as Map)['document'] as String,
        );
        return true;
      });
      final jami = _ControlledJami()
        ..nativeSettings = true
        ..accountExists = false;
      final state = AppState(jami, preferences);
      addTearDown(state.dispose);
      await state.init();
      expect(state.settingsError, isNull);
      expect(state.appSettings.globalMicrophoneMode, MicrophoneMode.open);
      state.call = _session(mode: MicrophoneMode.open)..micMuted = false;
      state.call!.state = 'RINGING';
      await state.answer(state.call!);
      state.call!.state = 'CURRENT';
      expect(jami.lastAnsweredInitialAudioMuted, isFalse);
    },
  );

  final validOpen = jsonEncode(const AppSettingsCodec().encode(AppSettings()));
  final parityDocuments = <String, (String, bool)>{
    'duplicate mode': (
      validOpen.replaceFirst(
        '"globalDefault":"open"',
        '"globalDefault":"pushToTalk","globalDefault":"open"',
      ),
      false,
    ),
    'depth 20': (
      validOpen.replaceFirst('{', '{"extra":${'[' * 18}0${']' * 18},'),
      true,
    ),
    'depth 21': (
      validOpen.replaceFirst('{', '{"extra":${'[' * 19}0${']' * 19},'),
      false,
    ),
    for (final kind in ['null', '"unknown"', '"direct"', '"group"'])
      'scope kind $kind': (
        validOpen.replaceFirst(
          '"conversationOverrides":[]',
          '"conversationOverrides":[{"accountId":"account-a","peerId":"peer","conversationId":"conversation","kind":$kind,"mode":"open"}]',
        ),
        kind == '"direct"' || kind == '"group"',
      ),
  };
  for (final entry in parityDocuments.entries) {
    test('Android microphone policy input parity: ${entry.key}', () async {
      SharedPreferences.setMockInitialValues({'appSettings': entry.value.$1});
      final jami = _ControlledJami()
        ..nativeSettings = true
        ..accountExists = false;
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      state.call = _session(mode: MicrophoneMode.open)..micMuted = false;
      state.call!.state = 'RINGING';
      await state.answer(state.call!);
      state.call!.state = 'CURRENT';
      expect(jami.lastAnsweredInitialAudioMuted, !entry.value.$2);
      await state.toggleMute();
      await state.toggleMute();
      expect(jami.muteCommands.contains(('direct', false)), entry.value.$2);
    });
  }

  for (final group in [false, true]) {
    test(
      'durable PTT does not apply old ${group ? 'group' : 'direct'} Open mode while cache reload waits',
      () async {
        SharedPreferences.setMockInitialValues({
          'appSettings': jsonEncode(
            const AppSettingsCodec().encode(AppSettings()),
          ),
        });
        final preferences = _DelayedReloadPreferences(
          await SharedPreferences.getInstance(),
        );
        final jami = _ControlledJami()
          ..nativeSettings = true
          ..accountExists = false;
        final state = AppState(jami, preferences);
        addTearDown(state.dispose);
        await state.init();
        expect(preferences.reloadStarted.isCompleted, false);
        preferences.delayReload = true;
        if (group) {
          state.groupCall = GroupCallSession(
            conversationId: 'b' * 40,
            roomId: 'voice',
            conferenceId: 'syblv1-voice-42',
            sessionId: 'session42',
            phase: GroupCallPhase.connected,
            micMuted: true,
          );
        } else {
          state.call = _session(mode: MicrophoneMode.open);
        }
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveAppSettingsDocument');
          await preferences.stored.setString(
            'appSettings',
            (call.arguments as Map)['document'] as String,
          );
          return true;
        });
        final saved = state.setGlobalMicrophoneMode(MicrophoneMode.pushToTalk);
        await preferences.reloadStarted.future;
        await pumpEventQueue();
        expect(jami.muteCommands, isNot(contains(('direct', false))));
        expect(
          jami.calls,
          isNot(contains('setGroupMicMuted:syblv1-voice-42:false')),
        );
        preferences.finishReload.complete();
        expect(await saved, isTrue);
        expect(
          state.groupCall?.micMode ?? state.call!.micMode,
          MicrophoneMode.pushToTalk,
        );
        expect(state.groupCall?.micMuted ?? state.call!.micMuted, isTrue);
      },
    );
  }

  test(
    'decoded Android PTT survives migration failure without permitting a hold until save',
    () async {
      SharedPreferences.setMockInitialValues({
        'appSettings': jsonEncode({
          'schemaVersion': 1,
          'microphoneMode': 'ptt',
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      final jami = _ControlledJami()
        ..nativeSettings = true
        ..accountExists = false;
      final state = AppState(jami, preferences);
      addTearDown(state.dispose);
      await state.init();
      expect(state.appSettings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
      expect(state.settingsError, isNotNull);
      state.call = _session();
      await state.pttHold(true);
      expect(jami.muteCommands, isNot(contains(('direct', false))));
    },
  );
}
