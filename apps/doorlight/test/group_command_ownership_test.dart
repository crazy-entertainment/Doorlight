import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';

const _group = GroupState(
  conversationId: 'group-a',
  title: 'The Crew',
  memberCount: 2,
  canManageMembers: true,
  localRole: JamiGroupMemberRole.admin,
  memberIds: ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'],
  activeMemberIds: {'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
  invitedMemberIds: {},
);

final class _GroupClient extends JamiClient {
  final result = Completer<bool>();
  final created = Completer<String>();
  final owners = <String?>[];
  int refreshes = 0;

  Future<bool> _command(String? owner) {
    owners.add(owner);
    return result.future;
  }

  @override
  Future<String> createGroup(
    String title,
    Iterable<String> members, {
    String? expectedAccountId,
  }) {
    owners.add(expectedAccountId);
    return created.future;
  }

  @override
  Future<bool> addGroupMembers(
    String conversationId,
    Iterable<String> members, {
    String? expectedAccountId,
  }) => _command(expectedAccountId);
  @override
  Future<bool> removeGroupMember(
    String conversationId,
    String memberId, {
    String? expectedAccountId,
  }) => _command(expectedAccountId);
  @override
  Future<bool> renameGroup(
    String conversationId,
    String title, {
    String? expectedAccountId,
  }) => _command(expectedAccountId);
  @override
  Future<bool> updateGroupLayout(
    String conversationId,
    String description, {
    String? expectedAccountId,
  }) => _command(expectedAccountId);
  @override
  Future<bool> leaveGroup(String conversationId, {String? expectedAccountId}) =>
      _command(expectedAccountId);
  @override
  Future<JamiFriendList> listFriends() async {
    refreshes++;
    return const JamiFriendList(1, []);
  }

  @override
  Future<void> setPresenceSubscriptions(Iterable<String> peers) async {}
  @override
  Future<void> replayPendingNativeEvents() async {}

  void complete(bool accepted) {
    result.complete(accepted);
    created.complete(accepted ? 'created-group' : '');
  }
}

Future<AppState> _state(_GroupClient client) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(client, await SharedPreferences.getInstance())
    ..accountId = 'account-a'
    ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  state.seedEmptyRuntimeSnapshotForTesting(
    groups: const [_group],
    selectedFixtureGroupId: _group.conversationId,
    friends: const [
      FriendState(
        peerId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        confirmed: true,
        conversationId: 'friend-b',
        displayName: 'Bea',
      ),
    ],
  );
  return state;
}

Future<bool> _run(AppState state, String command) => switch (command) {
  'create' => state.createGroup('New group', _group.memberIds),
  'invite' => state.addGroupMembers(_group.conversationId, _group.memberIds),
  'remove' => state.removeGroupMember(
    _group.conversationId,
    _group.memberIds.first,
  ),
  'rename' => state.renameGroup(_group.conversationId, 'New name'),
  'layout' => state.updateGroupLayout(_group.conversationId, _group.layout),
  'leave' => state.leaveGroup(_group.conversationId),
  _ => throw ArgumentError.value(command),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final command in [
    'create',
    'invite',
    'remove',
    'rename',
    'layout',
    'leave',
  ]) {
    test(
      '$command sends the captured account to the native boundary',
      () async {
        final client = _GroupClient();
        final state = await _state(client);
        addTearDown(state.dispose);
        final pending = _run(state, command);
        client.complete(false);
        expect(await pending, isFalse);
        expect(client.owners, ['account-a']);
      },
    );

    for (final change in ['account', 'account-return', 'visit', 'disposed']) {
      test(
        '$command completion cannot update a replaced $change owner',
        () async {
          final client = _GroupClient();
          final state = await _state(client);
          if (change != 'disposed') addTearDown(state.dispose);
          final pending = _run(state, command);
          switch (change) {
            case 'account':
              state.accountId = 'account-b';
            case 'account-return':
              state.accountId = 'account-b';
              state.accountId = 'account-a';
            case 'visit':
              state.selectedGroupId = null;
              state.selectedGroupId = _group.conversationId;
            case 'disposed':
              state.dispose();
          }
          final selected = state.selectedGroupId;
          client.complete(true);
          expect(await pending, isFalse);
          expect(client.refreshes, 0);
          expect(state.selectedGroupId, selected);
        },
      );
    }
  }
}
