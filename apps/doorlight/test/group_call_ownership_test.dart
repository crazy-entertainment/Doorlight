import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/group_calls.dart';
import 'package:sybl/state/group_topics.dart';
import 'app_state_test.dart' as fixture;

class _Native extends fixture.FakeJami {
  Completer<List<GroupActiveCall>>? discovery;
  bool detach = true;
  bool throwLeave = false;
  @override
  Future<List<GroupActiveCall>> listGroupCalls(String conversationId) async {
    calls.add('discovery');
    return discovery?.future ?? [];
  }

  @override
  Future<bool> leaveGroupCall(
    String conferenceId, {
    String reservationId = '',
  }) async {
    calls.add('leave:$conferenceId');
    if (throwLeave) throw StateError('leave');
    return detach;
  }
}

Future<(AppState, _Native, GroupState, GroupRoom)> boot() async {
  SharedPreferences.setMockInitialValues({});
  final native = _Native()..accountRegistration = 'REGISTERED';
  final state = AppState(native, await SharedPreferences.getInstance());
  await state.init();
  addTearDown(state.dispose);
  final layout = GroupLayout.defaults.addRoom('Voice', GroupRoomKind.voice);
  final room = layout.rooms.firstWhere((r) => r.kind == GroupRoomKind.voice);
  final group = GroupState(
    conversationId: 'e' * 40,
    title: 'Group',
    description: GroupLayoutCodec.encode(layout),
    memberCount: 2,
    canManageMembers: true,
    memberIds: const [fixture.peer],
    activeMemberIds: const {fixture.peer},
    invitedMemberIds: const {},
  );
  state.seedEmptyRuntimeSnapshotForTesting(
    friends: const [
      FriendState(
        peerId: fixture.peer,
        confirmed: true,
        conversationId: fixture.peerConversation,
      ),
    ],
    selectedPeerId: fixture.peer,
    groups: [group],
  );
  return (state, native, group, room);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native reservation precedes discovery and blocks a competing call',
    () async {
      final (state, native, group, room) = await boot();
      native.discovery = Completer();
      final joining = state.joinGroupVoice(group, room);
      await Future<void>.delayed(Duration.zero);
      expect(state.groupCall?.phase, GroupCallPhase.joining);
      expect(
        native.calls.indexWhere((c) => c.startsWith('reserveGroupCall:')),
        lessThan(native.calls.indexOf('discovery')),
      );
      await state.startCallTo(fixture.peer);
      await state.joinGroupVoice(group, room);
      expect(native.calls.where((c) => c.startsWith('place:')), isEmpty);
      expect(native.calls.where((c) => c == 'discovery'), hasLength(1));
      await state.leaveGroupVoice();
      native.discovery!.complete([]);
      await joining;
      expect(state.groupCall, isNull);
      expect(
        native.calls.where((c) => c.startsWith('joinGroupCall:')),
        isEmpty,
      );
    },
  );
  for (final throwing in [false, true]) {
    test(
      'failed Leave retains exact media ownership (throw=$throwing)',
      () async {
        final (state, native, group, room) = await boot();
        await state.joinGroupVoice(group, room);
        final session = state.groupCall!;
        native.detach = false;
        native.throwLeave = throwing;
        await state.leaveGroupVoice();
        expect(identical(state.groupCall, session), isTrue);
        expect(session.phase, GroupCallPhase.leaving);
        await state.startCallTo(fixture.peer);
        expect(native.calls.where((c) => c.startsWith('place:')), isEmpty);
        native.push('groupConferenceRemoved', {
        'reservationId': state.groupCall!.reservationId,
          'conferenceId': session.conferenceId,
        });
        await Future<void>.delayed(Duration.zero);
        expect(state.groupCall, isNull);
      },
    );
  }
  test(
    'placement and unrelated callbacks cannot connect or reset retries',
    () async {
      final (state, native, group, room) = await boot();
      await state.joinGroupVoice(group, room);
      final session = state.groupCall!;
      session.recoveryAttempts = 2;
      expect(session.connected, isFalse);
      native.push('groupConferenceCreated', {
        'reservationId': state.groupCall!.reservationId,
        'conversationId': group.conversationId,
        'conferenceId': 'syblv1-voice-999',
      });
      native.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': session.conferenceId,
        'callId': 'unrelated',
        'state': 'CURRENT',
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.connected, isFalse);
      expect(session.recoveryAttempts, 2);
      native.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': session.conferenceId,
        'callId': session.callId,
        'state': 'CURRENT',
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.connected, isTrue);
      expect(session.recoveryAttempts, 0);
    },
  );
}
