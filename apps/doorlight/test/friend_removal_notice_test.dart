import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/chat_archive.dart';
import 'package:sybl/state/dm_topics.dart';

import 'app_state_test.dart'
    show FakeJami, peer, peerConversation, stranger, strangerConversation;

const _markerKey = 'doorlight.pendingFriendRemovals.v1';
const _leftBody = '{"v":1,"op":"left","topic":"main","revision":1}';

class _HeldRemovalPreferences extends Fake implements SharedPreferences {
  _HeldRemovalPreferences(this.stored);
  final SharedPreferences stored;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool armed = false;
  @override
  Object? get(String key) => stored.get(key);
  @override
  bool containsKey(String key) => stored.containsKey(key);
  @override
  String? getString(String key) => stored.getString(key);
  @override
  bool? getBool(String key) => stored.getBool(key);
  @override
  Future<bool> setString(String key, String value) async {
    if (armed && key == _markerKey) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return stored.setString(key, value);
  }

  @override
  Future<bool> setBool(String key, bool value) => stored.setBool(key, value);
  @override
  Future<bool> remove(String key) => stored.remove(key);
  @override
  Future<void> reload() => stored.reload();
}

/// Records whether the archive file existed when trust was dropped.
class _ArchiveJami extends FakeJami {
  bool? archiveExistedAtRemoval;
  File? watched;
  bool resetSucceeds = true;
  Completer<void>? holdTopicMutation;

  @override
  Future<String> sendDmTopicEvent(
    String peerJamiId,
    String conversationId,
    String body,
  ) async {
    final hold = holdTopicMutation;
    if (hold != null &&
        DmTopicEventCodec.decode(body)?.operation != DmTopicOperation.left) {
      await hold.future;
    }
    return super.sendDmTopicEvent(peerJamiId, conversationId, body);
  }

  @override
  Future<void> removeContact(String uri, {bool block = false}) async {
    archiveExistedAtRemoval ??= watched?.existsSync();
    await super.removeContact(uri, block: block);
  }

  @override
  Future<bool> resetDoorlight(String expectedAccountId) async {
    calls.add('resetDoorlight:$expectedAccountId');
    return resetSucceeds;
  }
}

Map<String, Object?> _leftRecord(String commitId, String authorId) => {
  'commitId': commitId,
  'authorId': authorId,
  'mimeType': DmTopicWire.mimeType,
  'topicId': DmTopicWire.mainId,
  'linearizedParent': '',
  'eventBody': _leftBody,
};

Map<String, Object?> _itemRecord(String commitId, String authorId) => {
  'commitId': commitId,
  'authorId': authorId,
  'mimeType': 'text/plain',
  'topicId': DmTopicWire.mainId,
  'topicTagged': false,
  'daemonRead': false,
  'linearizedParent': '',
};

Map<String, Object?> _chatWire({
  required String daemonId,
  required String authorId,
  String mimeType = 'text/plain',
  String? body,
  String? eventBody,
}) => {
  'accountId': 'acc1',
  'peerId': peer,
  'conversationId': peerConversation,
  'daemonId': daemonId,
  'versionId': daemonId,
  'mimeType': mimeType,
  'authorId': authorId,
  'timestampSeconds': 1700000000,
  'body': ?body,
  'eventBody': ?eventBody,
  'topicId': DmTopicWire.mainId,
  'topicTagged': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ArchiveJami jami;
  late AppState state;

  Future<void> boot({
    Map<String, Object> prefs = const {},
    void Function(_ArchiveJami jami)? configure,
    Duration? noticeWindow,
    SharedPreferences Function(SharedPreferences)? wrapPreferences,
  }) async {
    SharedPreferences.setMockInitialValues({
      'displayName': 'Me',
      'selectedFriendId': peer,
      ...prefs,
    });
    jami = _ArchiveJami()..accountExists = true;
    jami.daemonFriends[peer] = const JamiFriend(
      peerJamiId: peer,
      confirmed: true,
      conversationId: peerConversation,
    );
    jami.daemonFriends[stranger] = const JamiFriend(
      peerJamiId: stranger,
      confirmed: true,
      conversationId: strangerConversation,
    );
    configure?.call(jami);
    final preferences = await SharedPreferences.getInstance();
    state = AppState(jami, wrapPreferences?.call(preferences) ?? preferences);
    if (noticeWindow != null) state.friendRemovalNoticeWindow = noticeWindow;
    addTearDown(state.dispose);
    await state.init();
    await state.selectFriend(peer);
    await pumpEventQueue();
  }

  List<Map<String, Object?>> markers() {
    final raw = state.prefs.getString(_markerKey);
    return raw == null
        ? const []
        : (jsonDecode(raw) as List).cast<Map<String, Object?>>();
  }

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('receiver', () {
    test('only the peer\'s own latest left in its 1:1 scope counts', () async {
      await boot(
        configure: (fake) {
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
          // A peer's left cannot leak into another conversation.
          fake.dmTopicHistory[strangerConversation] = [
            _leftRecord('foreign-left', peer),
          ];
        },
      );
      expect(state.peerLeft(peer), isTrue);
      expect(state.peerLeft(stranger), isFalse);
      expect(state.friendActivity(peer).unreadTotal, 0);
    });

    test('a self-authored left never means removed you', () async {
      await boot(
        configure: (fake) {
          fake.dmTopicHistory[peerConversation] = [
            _leftRecord('mine', fake.accountJamiId),
          ];
        },
      );
      expect(state.jamiId, jami.accountJamiId);
      expect(state.peerLeft(peer), isFalse);
    });

    test('a later record by the peer supersedes the left', () async {
      await boot(
        configure: (fake) {
          // Pages are newest first.
          fake.dmTopicHistory[peerConversation] = [
            _itemRecord('back', peer),
            _leftRecord('left', peer),
          ];
        },
      );
      expect(state.peerLeft(peer), isFalse);
    });

    test('a live left closes calls, sends and reactions', () async {
      await boot();
      jami.push('registrationState', {'state': 'REGISTERED'});
      expect(state.peerLeft(peer), isFalse);
      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': peer,
        'conversationId': peerConversation,
        'item': _chatWire(
          daemonId: 'live-left',
          authorId: peer,
          mimeType: DmTopicWire.mimeType,
          eventBody: _leftBody,
        ),
      });
      await pumpEventQueue();
      expect(state.peerLeft(peer), isTrue);
      expect(state.friendActivity(peer).unreadTotal, 0);

      await state.startCallTo(peer);
      expect(jami.lastPlacedPeer, isNull);
      expect(state.call, isNull);
      expect(await state.notifyCallRequest(peer), isFalse);
      expect(await state.sendText('still there?'), isFalse);
      expect(jami.calls.where((c) => c.startsWith('sendChatMessage')), isEmpty);

      // The other friend is untouched.
      await state.startCallTo(stranger);
      expect(jami.lastPlacedPeer, stranger);
    });

    test('the timeline shows only the peer-authored left in main', () async {
      await boot(
        configure: (fake) {
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
          fake.chatHistory[peerConversation] = [
            _chatWire(daemonId: 'hello', authorId: peer, body: 'hello'),
            _chatWire(
              daemonId: 'left',
              authorId: peer,
              mimeType: DmTopicWire.mimeType,
              eventBody: _leftBody,
            ),
            _chatWire(
              daemonId: 'my-left',
              authorId: fake.accountJamiId,
              mimeType: DmTopicWire.mimeType,
              eventBody: _leftBody,
            ),
          ];
        },
      );
      final ids = state.selectedDmTopicItems.map((item) => item.daemonId);
      expect(ids, unorderedEquals(['hello', 'left']));
    });

    test('Delete removes trust without a notice', () async {
      await boot(
        configure: (fake) {
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
        },
      );
      final result = await state.deleteLeftChat(peer);
      expect(result.status, FriendRemovalStatus.removed);
      expect(jami.calls, contains('removeContact:$peer:false'));
      expect(jami.sentDmTopicEvents, isEmpty);
    });

    test('Delete refuses an active chat', () async {
      await boot();
      final result = await state.deleteLeftChat(peer);
      expect(result.status, FriendRemovalStatus.notRemoved);
      expect(jami.calls, isNot(contains('removeContact:$peer:false')));
    });
  });

  group('remover', () {
    for (final queued in [false, true]) {
      test(
        'pending save cannot retire a replacement account ${queued ? 'queued' : 'visible'} ring',
        () async {
          late _HeldRemovalPreferences held;
          await boot(
            wrapPreferences: (prefs) => held = _HeldRemovalPreferences(prefs),
          );
          held.armed = true;
          final removing = state.removeFriend(peer);
          await held.entered.future;
          state.accountId = 'acc2';
          jami.push('registrationState', {'state': 'REGISTERED'});
          if (queued) {
            jami.push('incomingCall', {
              'accountId': 'acc2',
              'callId': 'other-visible',
              'fromJamiId': stranger,
            });
            await pumpEventQueue();
          }
          jami.push('incomingCall', {
            'accountId': 'acc2',
            'callId': 'replacement-ring',
            'fromJamiId': peer,
          });
          await pumpEventQueue();
          expect(
            state.call?.callId,
            queued ? 'other-visible' : 'replacement-ring',
          );
          held.release.complete();
          expect((await removing).status, FriendRemovalStatus.stale);
          expect(jami.calls, isNot(contains('refuse:replacement-ring')));
          expect(jami.calls, isNot(contains('removeContact:$peer:false')));
          expect(jami.sentDmTopicEvents, isEmpty);
          expect(
            markers().single['accountId'],
            'acc1',
            reason: 'the persisted promise may resume in its own account',
          );
          if (queued) {
            await state.decline(state.call!);
            await pumpEventQueue();
          }
          expect(state.call?.callId, 'replacement-ring');
        },
      );
    }

    test(
      'pending save is stale after an account switches away and back',
      () async {
        late _HeldRemovalPreferences held;
        await boot(
          wrapPreferences: (prefs) => held = _HeldRemovalPreferences(prefs),
        );
        held.armed = true;
        final removing = state.removeFriend(peer);
        await held.entered.future;
        state.accountId = 'acc2';
        state.accountId = 'acc1';
        final replacement = CallSession(
          callId: 'new-runtime-ring',
          dir: CallDir.incoming,
          peerId: peer,
        );
        state.call = replacement;
        held.release.complete();
        expect((await removing).status, FriendRemovalStatus.stale);
        expect(state.call, same(replacement));
        expect(jami.calls, isNot(contains('refuse:new-runtime-ring')));
        expect(jami.calls, isNot(contains('removeContact:$peer:false')));
        expect(jami.sentDmTopicEvents, isEmpty);
        expect(markers().single['accountId'], 'acc1');
      },
    );

    test('the notice is committed before trust is removed', () async {
      await boot();
      final result = await state.removeFriend(peer);

      expect(result.status, FriendRemovalStatus.removed);
      expect(jami.sentDmTopicEvents.single.body, _leftBody);
      expect(jami.sentDmTopicEvents.single.conversationId, peerConversation);
      final notice = jami.calls.indexOf('sendDmTopicEvent:$peer');
      final removal = jami.calls.indexOf('removeContact:$peer:false');
      expect(notice, greaterThanOrEqualTo(0));
      expect(removal, greaterThan(notice));
      expect(markers(), isEmpty);
      expect(state.friends, isNot(contains(peer)));
    });

    test(
      'only delivery from that peer for that commit removes early',
      () async {
        await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
        var done = false;
        final removing = state
            .removeFriend(peer)
            .whenComplete(() => done = true);
        await pumpEventQueue();

        expect(state.isRemovalPending(peer), isTrue);
        expect(
          state.visibleFriends.map((f) => f.peerId),
          isNot(contains(peer)),
        );
        expect(state.selectedFriend, isNull);
        expect(state.friends, contains(peer), reason: 'daemon truth unchanged');
        expect(markers().single['noticeCommitId'], jami.nextDmTopicCommitId);

        void status(String messageId, String from, int wireState) =>
            jami.push('messageStatus', {
              'accountId': 'acc1',
              'conversationId': peerConversation,
              'peerJamiId': from,
              'messageId': messageId,
              'state': wireState,
            });

        status(jami.nextDmTopicCommitId, peer, 1);
        status(jami.nextDmTopicCommitId, stranger, 2);
        status('another-commit', peer, 3);
        await pumpEventQueue();
        expect(done, isFalse);
        expect(jami.calls, isNot(contains('removeContact:$peer:false')));

        status(jami.nextDmTopicCommitId, peer, 2);
        final result = await removing;
        expect(result.status, FriendRemovalStatus.removed);
        expect(markers(), isEmpty);
      },
    );

    test('an undelivered notice is capped at 30 seconds', () async {
      await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
      fakeAsync((async) {
        unawaited(state.removeFriend(peer));
        async.flushMicrotasks();
        expect(state.isRemovalPending(peer), isTrue);
        async.elapse(const Duration(seconds: 29));
        expect(jami.calls, isNot(contains('removeContact:$peer:false')));
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(jami.calls, contains('removeContact:$peer:false'));
      });
    });

    test('a refused notice (older daemon) removes at once', () async {
      await boot(configure: (fake) => fake.throwDmTopicEvent = true);
      final result = await state.removeFriend(peer);
      expect(result.status, FriendRemovalStatus.removed);
      expect(jami.calls, contains('removeContact:$peer:false'));
    });

    test('blocking sends no notice', () async {
      await boot();
      final result = await state.removeFriend(peer, block: true);
      expect(result.status, FriendRemovalStatus.removed);
      expect(jami.sentDmTopicEvents, isEmpty);
      expect(jami.calls, contains('removeContact:$peer:true'));
    });

    test('a refused removal clears its marker and shows the friend', () async {
      await boot(configure: (fake) => fake.ignoreRemoveContact = true);
      final result = await state.removeFriend(peer);
      expect(result.status, FriendRemovalStatus.notRemoved);
      expect(result.warning, 'The friend was not removed. Please try again.');
      // Shown again for a retry; never silently removed on the next start.
      expect(markers(), isEmpty);
      expect(state.isRemovalPending(peer), isFalse);
      expect(state.visibleFriends.map((f) => f.peerId), contains(peer));
    });

    test(
      'presence probing is closed while removing, reopened on refusal',
      () async {
        await boot(
          configure: (fake) => fake
            ..autoDeliverLeftNotice = false
            ..ignoreRemoveContact = true,
        );
        state.friendRemovalNoticeWindow = const Duration(milliseconds: 200);
        final removing = state.removeFriend(peer);
        await pumpEventQueue();
        expect(state.isRemovalPending(peer), isTrue);
        jami.probedPeers.clear();
        expect(await state.setShareActivityPresence(true), isTrue);
        expect(jami.probedPeers, contains(stranger));
        expect(jami.probedPeers, isNot(contains(peer)));

        expect((await removing).status, FriendRemovalStatus.notRemoved);
        expect(await state.setShareActivityPresence(false), isTrue);
        jami.probedPeers.clear();
        expect(await state.setShareActivityPresence(true), isTrue);
        expect(jami.probedPeers, contains(peer));
      },
    );

    test('an incoming call from a peer being removed is refused', () async {
      await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
      jami.push('registrationState', {'state': 'REGISTERED'});
      unawaited(state.removeFriend(peer));
      await pumpEventQueue();
      jami.push('incomingCall', {
        'accountId': 'acc1',
        'callId': 'removing-call',
        'fromJamiId': peer,
      });
      await pumpEventQueue();
      expect(state.call, isNull);
      expect(jami.calls, contains('refuse:removing-call'));

      jami.push('incomingCall', {
        'accountId': 'acc1',
        'callId': 'other-call',
        'fromJamiId': stranger,
      });
      await pumpEventQueue();
      expect(state.call?.callId, 'other-call');
    });

    test('Remove declines a ring that was already showing', () async {
      await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
      jami.push('registrationState', {'state': 'REGISTERED'});
      jami.push('incomingCall', {
        'accountId': 'acc1',
        'callId': 'early-ring',
        'fromJamiId': peer,
      });
      await pumpEventQueue();
      expect(state.call?.callId, 'early-ring');
      // Hold the decline so the ring is still showing when Answer is pressed.
      final refusing = Completer<void>();
      jami.pendingRefuse = refusing;
      unawaited(state.removeFriend(peer));
      await pumpEventQueue();
      expect(jami.calls, contains('refuse:early-ring'));
      expect(state.call?.callId, 'early-ring');
      await state.answer(state.call!);
      expect(jami.calls, isNot(contains('answer:early-ring')));
      refusing.complete();
      await pumpEventQueue();
    });

    test('a peer who left gets no read receipt in an ordinary chat', () async {
      await boot(
        configure: (fake) {
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
          fake.chatHistory[peerConversation] = [
            {
              'accountId': 'acc1',
              'peerId': peer,
              'conversationId': peerConversation,
              'daemonId': 'bye',
              'versionId': 'bye',
              'mimeType': 'text/plain',
              'authorId': peer,
              'timestampSeconds': 1700000000,
              'body': 'bye',
              'topicId': DmTopicWire.mainId,
              'topicTagged': false,
            },
          ];
        },
      );
      expect(state.peerLeft(peer), isTrue);
      state.setConversationVisible(peer, dmTopicId: DmTopicWire.mainId);
      await pumpEventQueue();
      expect(jami.displayedMessages, isEmpty);
    });

    test('Remove refuses a ring from them queued behind another', () async {
      await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
      jami.push('registrationState', {'state': 'REGISTERED'});
      jami.push('incomingCall', {
        'accountId': 'acc1',
        'callId': 'stranger-ring',
        'fromJamiId': stranger,
      });
      await pumpEventQueue();
      jami.push('incomingCall', {
        'accountId': 'acc1',
        'callId': 'queued-ring',
        'fromJamiId': peer,
      });
      await pumpEventQueue();
      expect(state.call?.callId, 'stranger-ring');
      unawaited(state.removeFriend(peer));
      await pumpEventQueue();
      expect(jami.calls, contains('refuse:queued-ring'));
      await state.decline(state.call!);
      await pumpEventQueue();
      expect(state.call, isNull);
    });

    test('an incoming call from a peer who left is refused', () async {
      await boot(
        configure: (fake) {
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
        },
      );
      jami.push('registrationState', {'state': 'REGISTERED'});
      expect(state.peerLeft(peer), isTrue);
      jami.push('incomingCall', {
        'accountId': 'acc1',
        'callId': 'left-call',
        'fromJamiId': peer,
      });
      await pumpEventQueue();
      expect(state.call, isNull);
      expect(jami.calls, contains('refuse:left-call'));
    });

    test('the notice waits for an in-flight topic change', () async {
      await boot(configure: (fake) => fake.holdTopicMutation = Completer());
      final creating = state.createDmTopic('trip');
      await pumpEventQueue();
      final removing = state.removeFriend(peer);
      await pumpEventQueue();
      expect(jami.calls, isNot(contains('removeContact:$peer:false')));

      jami.holdTopicMutation!.complete();
      await creating;
      final result = await removing;
      expect(result.status, FriendRemovalStatus.removed);
      expect(jami.sentDmTopicEvents.map((e) => e.body), contains(_leftBody));
      final notice = jami.calls.lastIndexOf('sendDmTopicEvent:$peer');
      expect(
        jami.calls.indexOf('removeContact:$peer:false'),
        greaterThan(notice),
      );
    });

    test('a removal run belongs to one account', () async {
      await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
      state.friendRemovalNoticeWindow = const Duration(seconds: 1);
      var firstDone = false;
      final first = state
          .removeFriend(peer)
          .whenComplete(() => firstDone = true);
      await pumpEventQueue();

      state.accountId = 'acc2';
      state.friendRemovalNoticeWindow = const Duration(milliseconds: 50);
      final second = await state.removeFriend(peer);
      expect(firstDone, isFalse, reason: "B never borrows A's run");
      expect(second.peerId, peer);
      expect(state.isRemovalPending(peer), isFalse);

      state.accountId = 'acc1';
      expect(state.isRemovalPending(peer), isTrue);
      await first;
    });

    test('a pending removal blocks calls and re-adding', () async {
      await boot(configure: (fake) => fake.autoDeliverLeftNotice = false);
      jami.push('registrationState', {'state': 'REGISTERED'});
      unawaited(state.removeFriend(peer));
      await pumpEventQueue();
      await state.startCallTo(peer);
      expect(jami.lastPlacedPeer, isNull);
      expect(await state.addFriend(peer), isFalse);
    });

    test('a marker resumes after restart and finishes removal', () async {
      await boot(
        prefs: {
          _markerKey: jsonEncode([
            {
              'accountId': 'acc1',
              'peerId': peer,
              'conversationId': peerConversation,
              'deadlineMs': 0,
              'noticeCommitId': 'old-notice',
            },
          ]),
        },
      );
      await pumpEventQueue();
      expect(jami.sentDmTopicEvents, isEmpty, reason: 'never re-sent');
      expect(jami.calls, contains('removeContact:$peer:false'));
      expect(state.friends, isNot(contains(peer)));
      expect(markers(), isEmpty);
    });

    test('a marker for another conversation is dropped, not run', () async {
      await boot(
        prefs: {
          _markerKey: jsonEncode([
            {
              'accountId': 'acc1',
              'peerId': peer,
              'conversationId': 'conversation-before-re-add',
              'deadlineMs': 0,
            },
          ]),
        },
      );
      await pumpEventQueue();
      expect(jami.calls, isNot(contains('removeContact:$peer:false')));
      expect(state.friends, contains(peer));
      expect(state.isRemovalPending(peer), isFalse);
      expect(markers(), isEmpty);
    });

    test('a resumed deadline never exceeds the notice window', () async {
      await boot(
        noticeWindow: const Duration(milliseconds: 100),
        prefs: {
          _markerKey: jsonEncode([
            {
              'accountId': 'acc1',
              'peerId': peer,
              'conversationId': peerConversation,
              // A clock moved back would otherwise hide the friend for days.
              'deadlineMs': DateTime.now()
                  .add(const Duration(days: 3))
                  .millisecondsSinceEpoch,
            },
          ]),
        },
      );
      expect(state.isRemovalPending(peer), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await pumpEventQueue();
      expect(jami.calls, contains('removeContact:$peer:false'));
      expect(markers(), isEmpty);
    });

    test('a marker within its window hides the friend after restart', () async {
      await boot(
        prefs: {
          _markerKey: jsonEncode([
            {
              'accountId': 'acc1',
              'peerId': peer,
              'conversationId': peerConversation,
              'deadlineMs': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch,
            },
          ]),
        },
      );
      expect(state.isRemovalPending(peer), isTrue);
      expect(state.visibleFriends.map((f) => f.peerId), [stranger]);
      expect(jami.calls, isNot(contains('removeContact:$peer:false')));
    });
  });

  group('archive', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sybl-archive-test-');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('a complete snapshot is written before trust is removed', () async {
      await boot(
        configure: (fake) {
          fake.archivedChatsRoot = root.path;
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
          fake.chatHistory[peerConversation] = [
            _chatWire(daemonId: 'hello', authorId: peer, body: 'hello'),
          ];
        },
      );
      jami.watched = File(
        '${root.path}${Platform.pathSeparator}acc1'
        '${Platform.pathSeparator}${ChatArchiveStore.idFor(peer)}.json',
      );
      final result = await state.archiveLeftChat(peer);

      expect(result.status, FriendRemovalStatus.removed);
      expect(jami.archiveExistedAtRemoval, isTrue);
      expect(state.archivedChats.single.chat?.items.single.text, 'hello');
      expect(jami.sentDmTopicEvents, isEmpty);
    });

    test('an incomplete snapshot never removes trust', () async {
      await boot(
        configure: (fake) {
          fake.archivedChatsRoot = root.path;
          fake.dmTopicHistory[peerConversation] = [_leftRecord('left', peer)];
        },
      );
      jami.eventDuringLoadChat = JamiEvent('chatSnapshot', {
        'hasMore': true,
        'nextCursor': '',
      });
      final result = await state.archiveLeftChat(peer);

      expect(result.status, FriendRemovalStatus.notRemoved);
      expect(jami.calls, isNot(contains('removeContact:$peer:false')));
      expect(state.friends, contains(peer));
      expect(state.archivedChats, isEmpty);
    });

    test('reset deletes the account archive directory', () async {
      await boot(configure: (fake) => fake.archivedChatsRoot = root.path);
      final account = Directory('${root.path}${Platform.pathSeparator}acc1');
      expect(
        await state.chatArchive.write(
          'acc1',
          peer,
          ArchivedChat(
            peerLabel: 'P',
            archivedAt: DateTime.utc(2026),
            topics: const {},
            items: const [],
          ),
        ),
        ChatArchiveWriteResult.saved,
      );
      expect(await account.exists(), isTrue);

      expect(await state.resetDoorlight(), isTrue);
      expect(await account.exists(), isFalse);
    });
  });

  group('nearby requests', () {
    test('accepting one request consumes only that request', () async {
      await boot();
      const first = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      const second = 'ffffffffffffffffffffffffffffffffffffffff';
      for (final (id, conv) in [(first, 'conv-first'), (second, 'conv-two')]) {
        jami.push('connectRequest', {
          'accountId': 'acc1',
          'conversationId': conv,
          'fromJamiId': id,
          'isGroup': false,
        });
      }
      await pumpEventQueue();
      expect(state.incomingRequestFrom(second)?.convId, 'conv-two');

      await state.allowConnectFrom('conv-two');

      expect(jami.calls, contains('acceptConnect:conv-two'));
      expect(jami.calls, isNot(contains('acceptConnect:conv-first')));
      expect(state.incomingRequestFrom(second), isNull);
      expect(state.pendingConnect?.convId, 'conv-first');
    });
  });
}
