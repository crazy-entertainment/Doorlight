import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/sound_effects.dart';
import 'package:sybl/state/app_state.dart';
import 'app_state_test.dart' show FakeJami;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native reaction events update metadata without message effects',
    () async {
      final peer = 'b' * 40, message = 'a' * 40, reaction = '1' * 40;
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
      });
      final native = FakeJami();
      native.daemonFriends[peer] = JamiFriend(
        peerJamiId: peer,
        confirmed: true,
        conversationId: 'conversation',
      );
      final state = AppState(native, await SharedPreferences.getInstance());
      await state.init();
      await state.selectFriend(peer);
      addTearDown(state.dispose);
      final scope = state.selectedConversationScope!;
      native.push('chatMessage', {
        'accountId': scope.accountId,
        'peerJamiId': peer,
        'conversationId': scope.conversationId,
        'item': {
          ...scope.toMap(),
          'daemonId': message,
          'versionId': message,
          'authorId': peer,
          'mimeType': 'text/plain',
          'body': 'Hello',
          'timestampSeconds': 1700000000,
        },
      });
      await pumpEventQueue();
      final unread = state.friendActivity(peer).unreadTotal;
      final activity = state.friendActivity(peer).lastActivityAt;
      final sounds = <SyblSoundEvent>[];
      final subscription = state.soundEvents.listen(sounds.add);
      addTearDown(subscription.cancel);
      void change({bool remove = false, String? account}) {
        native.push('chatReaction', {
          'accountId': account ?? scope.accountId,
          'peerJamiId': peer,
          'conversationId': scope.conversationId,
          'item': {
            ...scope.toMap(),
            'messageId': message,
            if (remove)
              'removedId': reaction
            else
              'reaction': {
                'commitId': reaction,
                'authorId': peer,
                'emoji': '👍',
              },
          },
        });
      }

      change();
      change();
      expect(state.conversationItems.single.reactions.count('👍'), 1);
      change(remove: true, account: 'other-account');
      expect(state.conversationItems.single.reactions.count('👍'), 1);
      change(remove: true);
      expect(state.conversationItems.single.reactions.count('👍'), 0);
      await pumpEventQueue();
      expect(state.conversationItems, hasLength(1));
      expect(state.friendActivity(peer).unreadTotal, unread);
      expect(state.friendActivity(peer).lastActivityAt, activity);
      expect(sounds, isEmpty);
      expect(native.displayedMessages, isEmpty);
    },
  );
}
