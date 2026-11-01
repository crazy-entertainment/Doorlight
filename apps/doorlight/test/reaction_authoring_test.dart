import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_draft.dart';
import 'app_state_test.dart' show FakeJami;

final peer = 'b' * 40,
    message = 'a' * 40,
    conversation = 'c' * 40,
    me = 'd' * 40;

class ReactionNative extends FakeJami {
  final issued = <Map<String, String>>[];
  String admission = 'pending';
  Completer<void>? paused;
  Completer<bool>? journalWrite;
  @override
  bool get usesNativeSendJournal => true;
  @override
  Future<String?> loadSendJournal() async => null;
  @override
  Future<bool> saveSendJournal(String source) async =>
      journalWrite == null ? true : await journalWrite!.future;

  @override
  Future<String> sendOwnedReaction({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
    required String messageId,
    required String operationId,
    required String emoji,
    String removedId = '',
    String topicId = '',
    String roomId = '',
  }) async {
    issued.add({
      'message': messageId,
      'removed': removedId,
      'emoji': emoji,
      'topic': topicId,
      'room': roomId,
      'operation': operationId,
    });
    if (paused != null) await paused!.future;
    if (admission == 'pending') {
      final item = chatHistory[conversationId]!.single;
      final projection = item['reactions'] as Map<String, Object?>;
      final entries = projection['entries'] as List<Map<String, Object?>>;
      final commit = issued.length.toRadixString(16).padLeft(40, '0');
      if (removedId.isEmpty) {
        entries.add({'commitId': commit, 'authorId': me, 'emoji': emoji});
      } else {
        entries.removeWhere((entry) => entry['commitId'] == removedId);
      }
      push('sendOperationCompleted', {
        'accountId': accountId,
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'operationId': operationId,
        'status': 'committed',
        'commitId': commit,
      });
    }
    return admission;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReactionNative native;
  late AppState state;
  Future<void> boot({List<Map<String, Object?>> reactions = const []}) async {
    SharedPreferences.setMockInitialValues({
      'displayName': 'Me',
      'accountId': 'acc1',
    });
    native = ReactionNative()..accountJamiId = me;
    native.daemonFriends[peer] = JamiFriend(
      peerJamiId: peer,
      confirmed: true,
      conversationId: conversation,
    );
    native.chatHistory[conversation] = [
      {
        'accountId': 'acc1',
        'peerId': peer,
        'conversationId': conversation,
        'daemonId': message,
        'versionId': message,
        'authorId': peer,
        'mimeType': 'text/plain',
        'body': 'Hello',
        'timestampSeconds': 1700000000,
        'reactions': <String, Object?>{
          'messageId': message,
          'complete': true,
          'entries': [...reactions],
        },
      },
    ];
    state = AppState(native, await SharedPreferences.getInstance());
    await state.init();
    await state.selectFriend(peer);
    addTearDown(state.dispose);
    await pumpEventQueue();
  }

  test(
    'confirmed reaction updates from history without clearing the draft',
    () async {
      await boot();
      final target = state.conversationItems.single;
      final owner = state.conversationActionOwner;
      final draft = state.composerDrafts.acquire(
        ComposerDraftKey(target.scope, 'main'),
      )!..activate(owner);
      draft.updateText(owner, const TextEditingValue(text: 'Still writing'));
      expect(
        await state.toggleReaction(
          target,
          '👍',
          owner: state.conversationActionOwner,
        ),
        isTrue,
      );
      expect(native.issued.single['message'], message);
      expect(native.issued.single['removed'], '');
      expect(native.issued.single['topic'], 'main');
      expect(state.conversationItems.single.reactions.count('👍'), 1);
      expect(draft.text.text, 'Still writing');
      expect(state.sendJournal.unresolved, isEmpty);
    },
  );

  test(
    'removal targets every own duplicate and leaves another author intact',
    () async {
      await boot(
        reactions: [
          {'commitId': '1' * 40, 'authorId': me, 'emoji': '👍'},
          {'commitId': '2' * 40, 'authorId': me, 'emoji': '👍'},
          {'commitId': '3' * 40, 'authorId': peer, 'emoji': '👍'},
        ],
      );
      expect(
        await state.toggleReaction(
          state.conversationItems.single,
          '👍',
          owner: state.conversationActionOwner,
        ),
        isTrue,
      );
      expect(native.issued.map((entry) => entry['removed']), [
        '1' * 40,
        '2' * 40,
      ]);
      expect(native.issued.every((entry) => entry['emoji']!.isEmpty), isTrue);
      expect(
        state.conversationItems.single.reactions.entries.single.authorId,
        peer,
      );
    },
  );

  test(
    'unknown publication never becomes an optimistic reaction or automatic retry',
    () async {
      await boot();
      native.admission = 'unknown';
      final target = state.conversationItems.single;
      final owner = state.conversationActionOwner;
      expect(await state.toggleReaction(target, '❤️', owner: owner), isFalse);
      expect(state.conversationItems.single.reactions.entries, isEmpty);
      expect(state.reactionBusy(target), isTrue);
      expect(await state.toggleReaction(target, '❤️', owner: owner), isFalse);
      expect(native.issued, hasLength(1));
      expect(
        state.sendJournal.unresolved.single.status,
        ComposerSendStatus.unknown,
      );
    },
  );

  test(
    'locking while journal persistence waits prevents native issue',
    () async {
      await boot();
      final saved = Completer<bool>();
      native.journalWrite = saved;
      final target = state.conversationItems.single;
      final sending = state.toggleReaction(
        target,
        '😂',
        owner: state.conversationActionOwner,
      );
      await pumpEventQueue();
      state.setProtectedSurfaceLocked(true);
      saved.complete(true);
      expect(await sending, isFalse);
      expect(native.issued, isEmpty);
      expect(state.sendJournal.unresolved, isEmpty);
    },
  );
}
