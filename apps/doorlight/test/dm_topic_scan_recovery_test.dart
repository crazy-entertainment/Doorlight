import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/dm_topics.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/chat_stage.dart';

import 'app_state_test.dart' show FakeJami;

const _peer = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _otherPeer = 'dddddddddddddddddddddddddddddddddddddddd';
const _conversation = 'topic-conversation';

class _HistoryFailureState extends AppState {
  _HistoryFailureState(super.jami, super.prefs);

  @override
  ConversationScope get selectedConversationScope => ConversationScope(
    accountId: 'acc1',
    peerId: _peer,
    conversationId: _conversation,
  );

  @override
  DmTopicHistoryStatus get selectedDmTopicHistoryStatus =>
      DmTopicHistoryStatus.tooLarge;
}

class _ScanJami extends FakeJami {
  final requests = <Completer<int>>[];
  final requestedPeers = <String>[];
  final cancelledTopics = <int>[];

  @override
  Future<bool> cancelDmTopicStateLoad(int loadId) async {
    cancelledTopics.add(loadId);
    return true;
  }

  @override
  Future<int> loadDmTopicState(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 200,
  }) {
    final pending = Completer<int>();
    requestedPeers.add(peerJamiId);
    requests.add(pending);
    return pending.future;
  }

  void page(
    int loadId, {
    bool malformed = false,
    List<Object?> items = const [],
    String requested = '',
    String next = '',
    bool hasMore = false,
  }) => push('dmTopicStatePage', {
    'accountId': 'acc1',
    'peerJamiId': _peer,
    'conversationId': _conversation,
    'loadId': loadId,
    'requestedCursor': requested,
    'nextCursor': next,
    'hasMore': hasMore,
    'items': malformed ? 'bad' : items,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'oversized topic notice fits a narrow chat without promising recovery',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final state = _HistoryFailureState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: ChatStage(
              state: state,
              friend: const FriendState(
                peerId: _peer,
                confirmed: true,
                conversationId: _conversation,
                displayName: 'Friend',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('too large to load safely'), findsOneWidget);
      final retry = tester.widget<TextButton>(
        find.byKey(const ValueKey('retry-dm-topic-history')),
      );
      expect(retry.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
  test('topic history scans serialize across confirmed friends', () async {
    SharedPreferences.setMockInitialValues({'displayName': 'Me'});
    final preferences = await SharedPreferences.getInstance();
    fakeAsync((clock) {
      final jami = _ScanJami();
      jami.daemonFriends[_peer] = const JamiFriend(
        peerJamiId: _peer,
        confirmed: true,
        conversationId: _conversation,
      );
      jami.daemonFriends[_otherPeer] = const JamiFriend(
        peerJamiId: _otherPeer,
        confirmed: true,
        conversationId: 'other-topic-conversation',
      );
      final state = AppState(jami, preferences);
      unawaited(state.init());
      clock.flushMicrotasks();
      expect(jami.requests, hasLength(1));
      jami.requests.single.complete(81);
      clock.flushMicrotasks();
      jami.page(81);
      clock.flushMicrotasks();
      expect(jami.requestedPeers, [_peer, _otherPeer]);
      state.dispose();
      clock.flushMicrotasks();
    });
  });

  test(
    'over-budget history never publishes a partial topic projection',
    () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      final preferences = await SharedPreferences.getInstance();
      fakeAsync((clock) {
        final jami = _ScanJami();
        jami.daemonFriends[_peer] = const JamiFriend(
          peerJamiId: _peer,
          confirmed: true,
          conversationId: _conversation,
        );
        final state = AppState(jami, preferences);
        unawaited(state.init());
        clock.flushMicrotasks();
        var cursor = '';
        for (var page = 0; page < 101; page++) {
          final loadId = 1000 + page;
          jami.requests.last.complete(loadId);
          clock.flushMicrotasks();
          final next = 'cursor-$page';
          jami.page(
            loadId,
            requested: cursor,
            next: next,
            hasMore: true,
            items: [
              for (var item = 0; item < 200; item++)
                {
                  'commitId': 'item-$page-$item',
                  'authorId': _peer,
                  'mimeType': 'text/plain',
                  'topicTagged': false,
                },
            ],
          );
          clock.flushMicrotasks();
          cursor = next;
        }
        unawaited(state.selectFriend(_peer));
        clock.flushMicrotasks();
        expect(state.selectedDmTopicState, isNull);
        expect(
          state.selectedDmTopicHistoryStatus,
          DmTopicHistoryStatus.tooLarge,
        );
        final scope = state.selectedConversationScope!;
        final owner = state.conversationActionOwner;
        expect(state.canRetryDmTopicHistory, isFalse);
        expect(state.retryDmTopicHistory(scope: scope, owner: owner), isFalse);
        expect(jami.requests, hasLength(101));
        jami.push('conversationSyncFinished', {'accountId': 'acc1'});
        clock.flushMicrotasks();
        expect(
          jami.requests,
          hasLength(101),
          reason: 'Budget retry cools down.',
        );
        // A late completion cannot turn a truncated scan into authority.
        jami.page(1100);
        clock.flushMicrotasks();
        expect(
          state.selectedDmTopicHistoryStatus,
          DmTopicHistoryStatus.tooLarge,
        );
        expect(state.selectedDmTopicState, isNull);
        clock.elapse(const Duration(minutes: 5));
        expect(state.canRetryDmTopicHistory, isTrue);
        expect(state.retryDmTopicHistory(scope: scope, owner: owner), isTrue);
        clock.flushMicrotasks();
        expect(jami.requests, hasLength(102));
        expect(
          state.selectedDmTopicHistoryStatus,
          DmTopicHistoryStatus.loading,
        );
        expect(state.retryDmTopicHistory(scope: scope, owner: owner), isFalse);
        state.dispose();
        clock.flushMicrotasks();
      });
    },
  );
  test(
    'explicit retry is scoped and clears temporary failure only on completion',
    () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      final preferences = await SharedPreferences.getInstance();
      fakeAsync((clock) {
        final jami = _ScanJami();
        jami.daemonFriends[_peer] = const JamiFriend(
          peerJamiId: _peer,
          confirmed: true,
          conversationId: _conversation,
        );
        final state = AppState(jami, preferences);
        unawaited(state.init());
        clock.flushMicrotasks();
        unawaited(state.selectFriend(_peer));
        clock.flushMicrotasks();
        final scope = state.selectedConversationScope!;
        final owner = state.conversationActionOwner;
        for (var attempt = 0; attempt < 3; attempt++) {
          jami.requests.last.complete(0);
          clock.flushMicrotasks();
          if (attempt < 2) {
            clock.elapse(Duration(seconds: 1 << attempt));
            clock.flushMicrotasks();
          }
        }
        expect(state.selectedDmTopicHistoryStatus, DmTopicHistoryStatus.failed);
        expect(state.canRetryDmTopicHistory, isFalse);
        clock.elapse(const Duration(seconds: 30));
        expect(
          state.retryDmTopicHistory(scope: scope, owner: Object()),
          isFalse,
        );
        expect(state.retryDmTopicHistory(scope: scope, owner: owner), isTrue);
        clock.flushMicrotasks();
        jami.requests.last.complete(808);
        clock.flushMicrotasks();
        expect(
          state.selectedDmTopicHistoryStatus,
          DmTopicHistoryStatus.loading,
        );
        jami.page(808);
        clock.flushMicrotasks();
        expect(state.selectedDmTopicHistoryStatus, DmTopicHistoryStatus.ready);
        expect(state.selectedDmTopicState, isNotNull);
        expect(state.canRetryDmTopicHistory, isFalse);
        state.accountId = 'replacement-account';
        expect(state.retryDmTopicHistory(scope: scope, owner: owner), isFalse);
        jami.page(808);
        clock.flushMicrotasks();
        expect(state.selectedDmTopicState, isNull);
        state.dispose();
        clock.flushMicrotasks();
      });
    },
  );
  test('live staging overflow schedules one scoped recovery scan', () async {
    SharedPreferences.setMockInitialValues({'displayName': 'Me'});
    final preferences = await SharedPreferences.getInstance();
    fakeAsync((clock) {
      const topic = 'cccccccccccccccccccccccccccccccc';
      final create = {
        'commitId': 'create',
        'authorId': _peer,
        'mimeType': DmTopicWire.mimeType,
        'eventBody': DmTopicEventCodec.encode(
          const DmTopicEvent.create(
            topicId: topic,
            revision: 1,
            name: 'Recovered',
            order: 0,
          ),
        ),
      };
      final jami = _ScanJami();
      jami.daemonFriends[_peer] = const JamiFriend(
        peerJamiId: _peer,
        confirmed: true,
        conversationId: _conversation,
      );
      final state = AppState(jami, preferences);
      unawaited(state.init());
      clock.flushMicrotasks();
      jami.requests.single.complete(81);
      clock.flushMicrotasks();
      jami.page(81, items: [create]);
      clock.flushMicrotasks();
      unawaited(state.selectFriend(_peer));
      clock.flushMicrotasks();
      expect(state.selectedDmTopicState?.topic(topic), isNotNull);
      unawaited(state.selectDmTopic(topic));
      clock.flushMicrotasks();
      expect(state.selectedDmTopicId, topic);

      for (var index = 0; index < 65; index++) {
        final id = 'live-$index';
        jami.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': _peer,
          'conversationId': _conversation,
          'item': {
            'accountId': 'acc1',
            'peerId': _peer,
            'conversationId': _conversation,
            'daemonId': id,
            'versionId': id,
            'mimeType': 'text/plain',
            'authorId': _peer,
            'timestampSeconds': 1700000000,
            'body': 'new',
            'topicId': DmTopicWire.mainId,
            'topicTagged': false,
          },
        });
      }
      expect(state.selectedDmTopicState, isNull);
      bool? sent;
      unawaited(
        state.sendText('keep this in the topic').then((value) {
          sent = value;
        }),
      );
      clock.flushMicrotasks();
      expect(sent, isFalse);
      expect(
        jami.calls.where((call) => call.startsWith('sendChatMessage:')),
        isEmpty,
      );
      expect(state.chatError, contains('Topic history'));
      var fileCompleted = false;
      unawaited(state.sendFile().then((_) => fileCompleted = true));
      clock.flushMicrotasks();
      expect(fileCompleted, isTrue);
      expect(jami.requests, hasLength(1));
      clock.elapse(const Duration(seconds: 29));
      expect(jami.requests, hasLength(1));
      clock.elapse(const Duration(seconds: 1));
      expect(jami.requests, hasLength(2));
      jami.requests.last.complete(82);
      clock.flushMicrotasks();
      jami.page(
        82,
        items: [
          for (var index = 64; index >= 0; index--)
            {
              'commitId': 'live-$index',
              'authorId': _peer,
              'mimeType': 'text/plain',
              'topicTagged': false,
            },
          create,
        ],
      );
      clock.flushMicrotasks();
      expect(state.selectedDmTopicState?.topic(topic)?.name, 'Recovered');
      state.dispose();
      clock.elapse(const Duration(minutes: 1));
      expect(jami.requests, hasLength(2));
    });
  });
  test(
    'overflow cannot reopen a peer closed by the last exact history',
    () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      final preferences = await SharedPreferences.getInstance();
      fakeAsync((clock) {
        final jami = _ScanJami();
        jami.daemonFriends[_peer] = const JamiFriend(
          peerJamiId: _peer,
          confirmed: true,
          conversationId: _conversation,
        );
        final state = AppState(jami, preferences);
        unawaited(state.init());
        clock.flushMicrotasks();
        jami.requests.single.complete(81);
        clock.flushMicrotasks();
        final left = {
          'commitId': 'left',
          'authorId': _peer,
          'mimeType': DmTopicWire.mimeType,
          'eventBody': DmTopicEventCodec.encode(const DmTopicEvent.left()),
        };
        jami.page(81, items: [left]);
        clock.flushMicrotasks();
        unawaited(state.selectFriend(_peer));
        clock.flushMicrotasks();
        expect(state.peerLeft(_peer), isTrue);
        for (var index = 0; index < 65; index++) {
          jami.push('chatMessage', {
            'accountId': 'acc1',
            'peerJamiId': _peer,
            'conversationId': _conversation,
            'item': {
              'accountId': 'acc1',
              'peerId': _peer,
              'conversationId': _conversation,
              'daemonId': 'local-$index',
              'versionId': 'local-$index',
              'mimeType': 'text/plain',
              'authorId': jami.accountJamiId,
              'timestampSeconds': 1700000000,
              'body': 'local linked-device history',
              'topicId': DmTopicWire.mainId,
              'topicTagged': false,
            },
          });
        }
        expect(state.selectedDmTopicState, isNull);
        // Presentation no longer asserts a current left; authority stays closed.
        expect(state.peerLeft(_peer), isFalse);
        bool? sent;
        unawaited(state.sendText('blocked').then((result) => sent = result));
        unawaited(state.startCallTo(_peer));
        clock.flushMicrotasks();
        expect(sent, isFalse);
        expect(jami.lastPlacedPeer, isNull);
        expect(
          jami.calls.where((c) => c.startsWith('sendChatMessage')),
          isEmpty,
        );
        clock.elapse(const Duration(seconds: 30));
        clock.flushMicrotasks();
        jami.requests.last.complete(82);
        clock.flushMicrotasks();
        jami.page(
          82,
          items: [
            {
              'commitId': 'peer-returned',
              'authorId': _peer,
              'mimeType': 'text/plain',
              'topicTagged': false,
            },
            left,
          ],
        );
        clock.flushMicrotasks();
        expect(state.selectedDmTopicHistoryStatus, DmTopicHistoryStatus.ready);
        expect(state.peerLeft(_peer), isFalse);
        sent = null;
        unawaited(state.sendText('reopened').then((result) => sent = result));
        clock.flushMicrotasks();
        expect(sent, isTrue);
        state.dispose();
        clock.flushMicrotasks();
      });
    },
  );
  test(
    'failed partial rescan preserves the complete topic and read frontier',
    () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      final preferences = await SharedPreferences.getInstance();
      fakeAsync((clock) {
        const topic = 'cccccccccccccccccccccccccccccccc';
        final jami = _ScanJami();
        jami.daemonFriends[_peer] = const JamiFriend(
          peerJamiId: _peer,
          confirmed: true,
          conversationId: _conversation,
        );
        final state = AppState(jami, preferences);
        unawaited(state.init());
        clock.flushMicrotasks();
        jami.requests.first.complete(80);
        clock.flushMicrotasks();
        jami.page(
          80,
          items: [
            {
              'commitId': 'read',
              'authorId': jami.accountJamiId,
              'mimeType': DmTopicWire.mimeType,
              'eventBody': DmTopicEventCodec.encode(
                const DmTopicEvent.read(
                  topicId: topic,
                  revision: 1,
                  messageId: 'message',
                ),
              ),
            },
            {
              'commitId': 'message',
              'authorId': _peer,
              'mimeType': 'text/plain',
              'topicId': topic,
              'topicTagged': true,
            },
            {
              'commitId': 'create',
              'authorId': _peer,
              'mimeType': DmTopicWire.mimeType,
              'eventBody': DmTopicEventCodec.encode(
                const DmTopicEvent.create(
                  topicId: topic,
                  revision: 1,
                  name: 'Saved topic',
                  order: 0,
                ),
              ),
            },
          ],
        );
        clock.flushMicrotasks();
        unawaited(state.selectFriend(_peer));
        clock.flushMicrotasks();
        final complete = state.selectedDmTopicState!;
        expect(complete.topic(topic)?.name, 'Saved topic');
        expect(
          complete.effectiveRead('message', readerId: jami.accountJamiId),
          isTrue,
        );
        jami.push('conversationSyncFinished', {'accountId': 'acc1'});
        clock.flushMicrotasks();
        jami.requests.last.complete(81);
        clock.flushMicrotasks();
        jami.page(81, items: [], hasMore: true, next: 'older');
        clock.flushMicrotasks();
        jami.requests.last.complete(82);
        clock.flushMicrotasks();
        jami.page(82, malformed: true, requested: 'older');
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 3));
        expect(state.selectedDmTopicState, same(complete));
        expect(
          state.selectedDmTopicState!.effectiveRead(
            'message',
            readerId: jami.accountJamiId,
          ),
          isTrue,
        );
        state.dispose();
        clock.flushMicrotasks();
      });
    },
  );
  for (final retire in ['account ABA', 'dispose', 'deadline']) {
    test('late topic request is cancelled after $retire', () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      final preferences = await SharedPreferences.getInstance();
      fakeAsync((clock) {
        final jami = _ScanJami();
        jami.daemonFriends[_peer] = const JamiFriend(
          peerJamiId: _peer,
          confirmed: true,
          conversationId: _conversation,
        );
        final state = AppState(jami, preferences);
        unawaited(state.init());
        clock.flushMicrotasks();
        expect(jami.requests, hasLength(1));
        switch (retire) {
          case 'account ABA':
            state.accountId = 'replacement';
            state.accountId = 'acc1';
          case 'dispose':
            state.dispose();
          case 'deadline':
            clock.elapse(const Duration(seconds: 30));
        }
        jami.requests.first.complete(81);
        clock.flushMicrotasks();
        expect(jami.cancelledTopics, [81]);
        jami.page(81);
        clock.flushMicrotasks();
        if (retire != 'dispose') state.dispose();
        clock.elapse(const Duration(minutes: 2));
        expect(jami.requests, hasLength(1));
      });
    });
  }

  test(
    'three failed attempts stop until a new sync and keep late loads retired',
    () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      final preferences = await SharedPreferences.getInstance();
      fakeAsync((clock) {
        final jami = _ScanJami();
        jami.daemonFriends[_peer] = const JamiFriend(
          peerJamiId: _peer,
          confirmed: true,
          conversationId: _conversation,
        );
        final state = AppState(jami, preferences);
        unawaited(state.init());
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 5));
        expect(jami.requests, hasLength(3));
        for (var index = 0; index < 3; index++) {
          jami.requests[index].complete(81 + index);
        }
        clock.flushMicrotasks();
        expect(jami.cancelledTopics, [81, 82, 83]);
        jami.push('conversationSyncFinished', {'accountId': 'acc1'});
        clock.flushMicrotasks();
        expect(jami.requests, hasLength(4));
        jami.requests.last.complete(84);
        clock.flushMicrotasks();
        jami.page(84);
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 2));
        expect(jami.requests, hasLength(4));
        state.dispose();
        clock.flushMicrotasks();
      });
    },
  );
  for (final failure in ['throw', 'zero', 'no reply', 'no page', 'bad page']) {
    test(
      'topic scan recovers after $failure without another native sync',
      () async {
        SharedPreferences.setMockInitialValues({'displayName': 'Me'});
        final preferences = await SharedPreferences.getInstance();
        fakeAsync((clock) {
          final jami = _ScanJami();
          jami.daemonFriends[_peer] = const JamiFriend(
            peerJamiId: _peer,
            confirmed: true,
            conversationId: _conversation,
          );
          final state = AppState(jami, preferences);
          unawaited(state.init());
          clock.flushMicrotasks();
          expect(jami.requests, hasLength(1));
          switch (failure) {
            case 'throw':
              jami.requests.first.completeError(StateError('synthetic'));
            case 'zero':
              jami.requests.first.complete(0);
            case 'no page':
              jami.requests.first.complete(81);
            case 'bad page':
              jami.requests.first.complete(81);
              clock.flushMicrotasks();
              jami.page(81, malformed: true);
          }
          clock.flushMicrotasks();
          clock.elapse(Duration(seconds: failure.startsWith('no ') ? 31 : 1));
          expect(jami.requests, hasLength(2));
          jami.requests.last.complete(82);
          clock.flushMicrotasks();
          jami.page(82);
          clock.flushMicrotasks();
          clock.elapse(const Duration(minutes: 2));
          expect(
            jami.requests,
            hasLength(2),
            reason: 'A complete scan must stop recovery.',
          );
          state.dispose();
          clock.flushMicrotasks();
        });
      },
    );
  }
}
