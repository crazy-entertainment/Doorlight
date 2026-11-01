import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

const _conference = 'syblv1-voice-42';

final class _ControlledGroupJami extends FakeJami {
  Completer<bool>? pendingUnmute;
  Completer<void>? pendingMute;
  bool rejectMute = false;
  bool throwMute = false;
  bool refuseLeave = false;
  bool rejectDeafen = false;
  bool throwDeafen = false;
  Completer<bool>? pendingDeafen;
  final deafenCommands = <(String, bool)>[];
  final acknowledgedDeafen = <String, bool>{_conference: false};
  final microphoneCommands = <(String, bool)>[];
  final acknowledgedMute = <String, bool>{_conference: true};

  @override
  Future<bool> setGroupMicMuted(String conferenceId, bool muted) async {
    microphoneCommands.add((conferenceId, muted));
    if (muted && throwMute) throw StateError('synthetic native mute failure');
    if (muted && rejectMute) return false;
    if (muted) await pendingMute?.future;
    final accepted = !muted && pendingUnmute != null
        ? await pendingUnmute!.future
        : true;
    if (accepted) acknowledgedMute[conferenceId] = muted;
    return accepted;
  }

  @override
  Future<bool> leaveGroupCall(String conferenceId, {String reservationId = ''}) async {
    if (refuseLeave) {
      calls.add('leaveGroupCall:$conferenceId');
      return false;
    }
    return super.leaveGroupCall(conferenceId);
  }

  @override
  Future<bool> setGroupDeafened(String conferenceId, bool deafened) async {
    deafenCommands.add((conferenceId, deafened));
    if (throwDeafen) throw StateError('synthetic playback failure');
    if (rejectDeafen) return false;
    final accepted = deafened && pendingDeafen != null
        ? await pendingDeafen!.future
        : true;
    if (accepted) acknowledgedDeafen[conferenceId] = deafened;
    return accepted;
  }
}

Future<(AppState, _ControlledGroupJami, GroupCallSession)> _newSession() async {
  SharedPreferences.setMockInitialValues({});
  final jami = _ControlledGroupJami();
  final state = AppState(jami, await SharedPreferences.getInstance())
    ..jamiId = 'a' * 40;
  final session = GroupCallSession(
    conversationId: 'b' * 40,
    roomId: 'voice',
    conferenceId: _conference,
    sessionId: 'session42',
    phase: GroupCallPhase.connected,
    micMuted: true,
    micMode: MicrophoneMode.pushToTalk,
  );
  state.groupCall = session;
  addTearDown(state.dispose);
  return (state, jami, session);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final replaceAccount in [false, true]) {
    test(
      'old deafen cannot submit playback after ${replaceAccount ? 'account A-B-A' : 'conference replacement'}',
      () async {
        final (state, jami, session) = await _newSession();
        state.accountId = 'account-a';
        await state.groupPushToTalk(true);
        jami.pendingMute = Completer<void>();
        final deafen = state.setGroupDeafened(true);
        await pumpEventQueue();
        expect(jami.microphoneCommands.last, (_conference, true));
        if (replaceAccount) {
          state.accountId = 'account-b';
          state.accountId = 'account-a';
        } else {
          session.conferenceId = 'syblv1-voice-43';
          session.acknowledgedMicrophoneMuted = true;
          session.micMuted = true;
        }
        jami.pendingMute!.complete();
        await deafen;
        expect(jami.deafenCommands, isEmpty);
      },
    );
  }

  test('group PTT release wins over a pending native unmute', () async {
    final (state, jami, session) = await _newSession();
    final unmute = Completer<bool>();
    jami.pendingUnmute = unmute;

    final press = state.groupPushToTalk(true);
    await pumpEventQueue();
    expect(jami.microphoneCommands, [(_conference, false)]);
    final release = state.groupPushToTalk(false);
    expect(session.pushToTalkPressed, isFalse);
    unmute.complete(true);
    await Future.wait([press, release]);

    expect(session.pushToTalkPressed, isFalse);
    expect(session.micMuted, isTrue);
    expect(jami.acknowledgedMute[_conference], isTrue);
    expect(jami.microphoneCommands, [
      (_conference, false),
      (_conference, true),
    ]);
  });

  test('manual mute while PTT is released survives the next press', () async {
    final (state, jami, session) = await _newSession();

    await state.setGroupMicMuted(true);
    await state.groupPushToTalk(true);

    expect(session.manuallyMuted, isTrue);
    expect(session.micMuted, isTrue);
    expect(jami.acknowledgedMute[_conference], isTrue);
    expect(jami.microphoneCommands, isNot(contains((_conference, false))));
  });

  test(
    'deafen prevents a subsequent group PTT press from transmitting',
    () async {
      final (state, jami, session) = await _newSession();

      await state.setGroupDeafened(true);
      expect(session.deafened, isTrue);
      await state.groupPushToTalk(true);

      expect(session.deafened, isTrue);
      expect(session.micMuted, isTrue);
      expect(jami.acknowledgedMute[_conference], isTrue);
      expect(jami.microphoneCommands, isNot(contains((_conference, false))));
    },
  );

  test('group manual mute wins while native unmute is pending', () async {
    final (state, jami, session) = await _newSession();
    jami.pendingUnmute = Completer<bool>();
    final press = state.groupPushToTalk(true);
    await pumpEventQueue();
    final mute = state.setGroupMicMuted(true);
    jami.pendingUnmute!.complete(true);
    await Future.wait([press, mute]);
    expect(session.manuallyMuted, isTrue);
    expect(jami.acknowledgedMute[_conference], isTrue);
    await state.groupPushToTalk(false);
    await state.groupPushToTalk(true);
    expect(jami.acknowledgedMute[_conference], isTrue);
  });

  test(
    'an account A-B-A change cannot revive an old group completion',
    () async {
      final (state, jami, session) = await _newSession();
      state.accountId = 'account-a';
      jami.pendingUnmute = Completer<bool>();
      final press = state.groupPushToTalk(true);
      await pumpEventQueue();
      state.accountId = 'account-b';
      state.accountId = 'account-a';
      jami.pendingUnmute!.complete(true);
      await press;
      expect(session.acknowledgedMicrophoneMuted, isTrue);
      expect(session.micMuted, isTrue);
    },
  );

  for (final lock in [false, true]) {
    test(
      'group ${lock ? 'lock' : 'focus loss'} releases delayed PTT and resume does not reopen it',
      () async {
        final (state, jami, session) = await _newSession();
        jami.pendingUnmute = Completer<bool>();
        final press = state.groupPushToTalk(true);
        await pumpEventQueue();
        if (lock) {
          state.setProtectedSurfaceLocked(true);
        } else {
          state.didChangeAppLifecycleState(AppLifecycleState.inactive);
        }
        expect(session.pushToTalkPressed, isFalse);
        jami.pendingUnmute!.complete(true);
        await press;
        await pumpEventQueue();
        expect(jami.acknowledgedMute[_conference], isTrue);
        await state.groupPushToTalk(true);
        expect(session.pushToTalkPressed, isFalse);
        if (lock) {
          state.setProtectedSurfaceLocked(false);
        } else {
          state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        }
        expect(session.pushToTalkPressed, isFalse);
        expect(jami.acknowledgedMute[_conference], isTrue);
      },
    );
  }

  test(
    'latest group undeafen wins over delayed deafen acknowledgement',
    () async {
      final (state, jami, session) = await _newSession();
      jami.pendingDeafen = Completer<bool>();
      final deafen = state.setGroupDeafened(true);
      await pumpEventQueue();
      expect(jami.deafenCommands, [(_conference, true)]);
      final undeafen = state.setGroupDeafened(false);
      jami.pendingDeafen!.complete(true);
      await Future.wait([deafen, undeafen]);
      expect(session.deafened, isFalse);
      expect(session.acknowledgedDeafened, isFalse);
      expect(jami.acknowledgedDeafen[_conference], isFalse);
      expect(jami.deafenCommands, [(_conference, true), (_conference, false)]);
      expect(session.pushToTalkPressed, isFalse);
      expect(jami.acknowledgedMute[_conference], isTrue);
    },
  );

  for (final throws in [false, true]) {
    test(
      'failed group deafen keeps microphone protection and allows retry: throw=$throws',
      () async {
        final (state, jami, session) = await _newSession();
        jami
          ..rejectDeafen = !throws
          ..throwDeafen = throws;
        await state.setGroupDeafened(true);
        expect(session.deafened, isTrue);
        expect(session.acknowledgedDeafened, isNull);
        expect(session.error, isNotNull);
        await state.groupPushToTalk(true);
        expect(jami.acknowledgedMute[_conference], isTrue);
        jami
          ..rejectDeafen = false
          ..throwDeafen = false;
        await state.setGroupDeafened(true);
        expect(session.acknowledgedDeafened, isTrue);
        expect(session.error, isNull);
        expect(jami.acknowledgedMute[_conference], isTrue);
      },
    );
  }

  test(
    'failed group protective mute and leave retain an unavailable media owner',
    () async {
      final (state, jami, session) = await _newSession();
      await state.groupPushToTalk(true);
      jami
        ..rejectMute = true
        ..refuseLeave = true;
      await state.groupPushToTalk(false);
      expect(state.groupCall, same(session));
      expect(session.phase, GroupCallPhase.leaving);
      expect(session.acknowledgedMicrophoneMuted, isNull);
      expect(session.error, contains('unknown'));
      final count = jami.microphoneCommands.length;
      await state.groupPushToTalk(true);
      expect(jami.microphoneCommands.length, count);
    },
  );

  for (final sameSession in [false, true]) {
    test('old unmute acknowledgement cannot own a replacement '
        '${sameSession ? 'conference' : 'session'}', () async {
      final (state, jami, previous) = await _newSession();
      final unmute = Completer<bool>();
      jami.pendingUnmute = unmute;
      final press = state.groupPushToTalk(true);
      await pumpEventQueue();
      expect(jami.microphoneCommands, [(_conference, false)]);

      const replacementConference = 'syblv1-voice-43';
      final replacement = sameSession
          ? previous
          : GroupCallSession(
              conversationId: 'c' * 40,
              roomId: 'voice',
              conferenceId: replacementConference,
              sessionId: 'session43',
              phase: GroupCallPhase.connected,
              micMuted: true,
              micMode: MicrophoneMode.pushToTalk,
            );
      // Recovery can replace the conference on the same session object.
      // These assignments establish the replacement, not its mute algorithm.
      replacement
        ..conferenceId = replacementConference
        ..pushToTalkPressed = false
        ..micMuted = true;
      state.groupCall = replacement;
      jami.acknowledgedMute[replacementConference] = true;
      unmute.complete(true);
      await press;

      expect(state.groupCall, same(replacement));
      expect(replacement.pushToTalkPressed, isFalse);
      expect(replacement.micMuted, isTrue);
      expect(jami.acknowledgedMute[replacementConference], isTrue);
      expect(
        jami.microphoneCommands.where(
          (command) => command.$1 == replacementConference && !command.$2,
        ),
        isEmpty,
      );
      expect(jami.groupPresencePayloads, isEmpty);
    });
  }

  for (final throws in [false, true]) {
    test('a ${throws ? 'throwing' : 'refused'} group PTT release mute '
        'requires conference teardown', () async {
      final (state, jami, session) = await _newSession();
      await state.groupPushToTalk(true);
      expect(jami.acknowledgedMute[_conference], isFalse);
      jami
        ..rejectMute = !throws
        ..throwMute = throws;

      Object? escapedError;
      try {
        await state.groupPushToTalk(false);
      } catch (error) {
        escapedError = error;
      }
      await pumpEventQueue();

      expect(session.pushToTalkPressed, isFalse);
      expect(jami.microphoneCommands.last, (_conference, true));
      expect(jami.acknowledgedMute[_conference], isFalse);
      expect(
        jami.calls,
        contains('leaveGroupCall:$_conference'),
        reason: 'A failed mute cannot leave a released PTT session active.',
      );
      expect(state.groupCall?.connected ?? false, isFalse);
      expect(escapedError, isNull);
    });
  }
}
