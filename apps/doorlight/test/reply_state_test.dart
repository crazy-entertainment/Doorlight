import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_draft.dart';
import 'app_state_test.dart' show FakeJami;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'group replies respect authenticated rooms and reject stale room visits',
    () async {
      final peer = 'b' * 40;
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
      });
      final native = FakeJami();
      native.daemonGroups['reply-group'] = JamiGroup(
        conversationId: 'reply-group',
        title: 'Group',
        memberCount: 2,
        canManageMembers: true,
        members: [
          JamiGroupMember(peerJamiId: peer, role: JamiGroupMemberRole.member),
        ],
      );
      final state = AppState(native, await SharedPreferences.getInstance());
      await state.init();
      await state.selectGroup('reply-group');
      addTearDown(state.dispose);
      final scope = state.selectedConversationScope!;
      void message(String id, String text, {String? room, String reply = ''}) {
        native.push('chatMessage', {
          'accountId': scope.accountId,
          'peerJamiId': scope.peerId,
          'conversationId': scope.conversationId,
          'item': {
            ...scope.toMap(),
            'daemonId': id,
            'versionId': id,
            'authorId': peer,
            'mimeType': 'text/plain',
            'timestampSeconds': 1700000000,
            'body': text,
            'roomId': ?room,
            'replyTo': reply,
            'authenticatedGroupHistory': true,
          },
        });
      }

      message('games-target', '[#general] A game', room: 'games');
      message('general-reply', 'A cross-room reply', reply: 'games-target');
      final reply = state.conversationItems.firstWhere(
        (item) => item.daemonId == 'general-reply',
      );
      expect(state.replyTargetById('games-target'), isNull);
      expect(state.replyTargetFor(reply), isNull);
      await state.selectGroupTopic(scope.conversationId, 'games');
      final target = state.replyTargetById('games-target')!;
      final draft = state.composerDrafts.acquire(
        ComposerDraftKey(scope, 'games'),
      )!;
      draft.activate(Object());
      final owner = state.conversationActionOwner;
      expect(state.beginReply(target, owner: owner), isTrue);
      expect(
        await state.sendOwnedContent(
          '[#general] Wrong room',
          replyTo: target.daemonId,
        ),
        isNull,
      );
      final sent = await state.sendOwnedContent(
        '[#games] Right room',
        replyTo: target.daemonId,
      );
      expect(sent?.status, ComposerSendStatus.committed);
      await state.sendJournal.acknowledge(sent!.operationId);
      await state.selectGroupTopic(scope.conversationId, 'general');
      await state.selectGroupTopic(scope.conversationId, 'games');
      expect(state.beginReply(target, owner: owner), isFalse);
      message('unknown-room', '[#games] Hidden', room: 'unknown-room');
      expect(state.replyTargetById('unknown-room'), isNull);
    },
  );
  test(
    'reply selection resolves current scoped history and retires on lock or deletion',
    () async {
      final peer = 'b' * 40;
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
      });
      final native = FakeJami();
      native.daemonFriends[peer] = JamiFriend(
        peerJamiId: peer,
        confirmed: true,
        conversationId: 'conv-reply',
      );
      final state = AppState(native, await SharedPreferences.getInstance());
      await state.init();
      await state.selectFriend(peer);
      addTearDown(state.dispose);
      final scope = state.selectedConversationScope!;
      final draft = state.composerDrafts.acquire(
        ComposerDraftKey(scope, 'main'),
      )!;
      draft.activate(Object());
      void message(
        String id, {
        String reply = '',
        bool deleted = false,
        String? topic,
      }) {
        native.push('chatMessage', {
          'accountId': scope.accountId,
          'peerJamiId': peer,
          'conversationId': scope.conversationId,
          'item': {
            ...scope.toMap(),
            'daemonId': id,
            'versionId': deleted ? 'edit-$id' : id,
            'authorId': peer,
            'mimeType': 'text/plain',
            'timestampSeconds': 1700000000,
            'body': deleted ? '' : 'Text $id',
            'replyTo': reply,
            if (deleted) 'operation': 'edit',
            if (deleted) 'deleted': true,
            'topicId': ?topic,
            if (topic != null) 'topicTagged': true,
          },
        });
      }

      message('target');
      message('reply', reply: 'target');
      final target = state.replyTargetById('target')!;
      final reply = state.conversationItems.firstWhere(
        (item) => item.daemonId == 'reply',
      );
      expect(state.replyTargetFor(reply), target);
      final owner = state.conversationActionOwner;
      expect(state.beginReply(target, owner: owner), isTrue);
      expect(draft.replyTo, 'target');
      final sent = await state.sendOwnedContent('My reply', replyTo: 'target');
      expect(sent?.status, ComposerSendStatus.committed);
      expect(native.lastChatReplyTo, 'target');
      await state.sendJournal.acknowledge(sent!.operationId);
      message('hidden', topic: '1' * 32);
      expect(state.replyTargetById('hidden'), isNull);
      expect(
        await state.sendOwnedContent('Wrong topic', replyTo: 'hidden'),
        isNull,
      );
      state.setProtectedSurfaceLocked(true);
      expect(state.replyTargetFor(reply), isNull);
      expect(state.beginReply(target, owner: owner), isFalse);
      expect(
        await state.sendOwnedContent('Locked reply', replyTo: 'target'),
        isNull,
      );
      state.setProtectedSurfaceLocked(false);
      message('target', deleted: true);
      expect(state.replyTargetFor(reply), isNull);
      expect(
        await state.sendOwnedContent('Deleted reply', replyTo: 'target'),
        isNull,
      );
      expect(native.lastChatBody, 'My reply');
      expect(
        state.beginReply(target, owner: state.conversationActionOwner),
        isFalse,
      );
    },
  );
}
