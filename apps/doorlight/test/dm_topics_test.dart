import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/dm_topics.dart';

void main() {
  const alice = 'alice';
  const bob = 'bob';
  const topicA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const topicB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  DmTopicEventEnvelope event(
    String commitId,
    String authorId,
    DmTopicEvent value, {
    int position = 1000,
  }) => DmTopicEventEnvelope(
    commitId: commitId,
    authorId: authorId,
    position: position,
    event: value,
  );

  DmTopicItemEnvelope item(
    String commitId,
    String authorId, {
    String? topicId,
    required int position,
    bool daemonRead = false,
  }) => DmTopicItemEnvelope(
    commitId: commitId,
    authorId: authorId,
    topicId: topicId,
    position: position,
    daemonRead: daemonRead,
  );

  DmTopicState reduce(Iterable<DmTopicRecord> records) {
    final snapshot = records.toList();
    var state = DmTopicState.initial(const {alice, bob});
    for (final record in snapshot) {
      state = DmTopicReducer.reduce(state, record);
    }
    final batch = DmTopicReducer.reduceAll(
      DmTopicState.initial(const {alice, bob}),
      snapshot,
    );
    expect(batch.customTopics, state.customTopics);
    expect(batch.acceptedEventCount, state.acceptedEventCount);
    for (final member in [alice, bob]) {
      expect(
        batch.visibleTopics(localMemberId: member),
        state.visibleTopics(localMemberId: member),
      );
      expect(
        batch.unreadByTopic(localMemberId: member),
        state.unreadByTopic(localMemberId: member),
      );
      for (final record in snapshot.whereType<DmTopicItemEnvelope>()) {
        expect(
          batch.effectiveRead(record.commitId, readerId: member),
          state.effectiveRead(record.commitId, readerId: member),
        );
      }
    }
    return batch;
  }

  group('DM topic wire', () {
    test('plain and invalid topic IDs map to main', () {
      expect(DmTopicWire.normalizeItemTopic(null), DmTopicWire.mainId);
      expect(DmTopicWire.normalizeItemTopic(''), DmTopicWire.mainId);
      expect(DmTopicWire.normalizeItemTopic('BAD'), DmTopicWire.mainId);
      expect(DmTopicWire.normalizeItemTopic('main'), DmTopicWire.mainId);
      expect(
        DmTopicWire.normalizeItemTopic('0123456789abcdef0123456789abcdef'),
        '0123456789abcdef0123456789abcdef',
      );
    });

    test('topic event codec rejects oversized and unknown input', () {
      expect(DmTopicEventCodec.decode('{"v":2}'), isNull);
      expect(DmTopicEventCodec.decode('x' * 4097), isNull);
      expect(DmTopicEventCodec.decode('[]'), isNull);
      expect(DmTopicEventCodec.decode('{'), isNull);
      expect(
        DmTopicEventCodec.decode(
          '{"v":1,"op":"read","topic":"main","revision":2147483648,"message":"m"}',
        ),
        isNull,
      );
      expect(
        DmTopicEventCodec.decode(
          '{"v":1,"op":"read","topic":"main","revision":1,"message":"bad\\nmessage"}',
        ),
        isNull,
      );
    });

    test('topic event codec uses bounded operation fields', () {
      const topicId = '0123456789abcdef0123456789abcdef';
      const event = DmTopicEvent.create(
        topicId: topicId,
        revision: 1,
        name: 'vacation',
        order: 2,
      );

      final encoded = DmTopicEventCodec.encode(event);

      expect(utf8.encode(encoded).length, lessThanOrEqualTo(4096));
      expect(jsonDecode(encoded), {
        'v': 1,
        'op': 'create',
        'topic': topicId,
        'revision': 1,
        'name': 'vacation',
        'order': 2,
      });
      expect(DmTopicEventCodec.decode(encoded), event);
    });

    test('new topic IDs are valid and not reused', () {
      final first = newDmTopicId();
      final second = newDmTopicId();

      expect(first, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(second, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(second, isNot(first));
    });

    test('main accepts read events but no shared mutation', () {
      const read = DmTopicEvent.read(
        topicId: DmTopicWire.mainId,
        revision: 1,
        messageId: 'message-1',
      );
      expect(DmTopicEventCodec.decode(DmTopicEventCodec.encode(read)), read);
      expect(
        () => DmTopicEventCodec.encode(
          const DmTopicEvent.rename(
            topicId: DmTopicWire.mainId,
            revision: 1,
            name: 'other',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('DM left event', () {
    const body = '{"v":1,"op":"left","topic":"main","revision":1}';

    test('encodes exactly the four-key wire body', () {
      expect(DmTopicEventCodec.encode(const DmTopicEvent.left()), body);
      expect(DmTopicEventCodec.decode(body), const DmTopicEvent.left());
    });

    test('rejects any other shape', () {
      for (final value in [
        '{"v":1,"op":"left","topic":"main","revision":1,"name":"x"}',
        '{"v":1,"op":"left","topic":"main","revision":1,"extra":true}',
        '{"v":1,"op":"left","topic":"main","revision":2}',
        '{"v":1,"op":"left","topic":"0123456789abcdef0123456789abcdef","revision":1}',
        '{"v":1,"op":"left","topic":"main"}',
        '{"v":2,"op":"left","topic":"main","revision":1}',
      ]) {
        expect(DmTopicEventCodec.decode(value), isNull, reason: value);
      }
    });

    test("only the member's newest record decides hasLeft", () {
      final left = event(
        'left',
        bob,
        const DmTopicEvent.left(),
        position: 2,
      );
      expect(reduce([left]).hasLeft(bob), isTrue);
      expect(reduce([left]).hasLeft(alice), isFalse);
      expect(
        reduce([left, item('later', bob, position: 3)]).hasLeft(bob),
        isFalse,
      );
      expect(
        reduce([item('earlier', bob, position: 1), left]).hasLeft(bob),
        isTrue,
      );
      // Another member's later message does not undo bob's left.
      expect(
        reduce([left, item('alice-later', alice, position: 3)]).hasLeft(bob),
        isTrue,
      );
      // A non-member cannot leave on anyone's behalf.
      expect(
        reduce([
          event('carol-left', 'carol', const DmTopicEvent.left()),
        ]).hasLeft('carol'),
        isFalse,
      );
    });

    test('a left event changes no topic state', () {
      final state = reduce([
        event('left', bob, const DmTopicEvent.left(), position: 2),
      ]);
      expect(state.customTopics, isEmpty);
      expect(state.unreadByTopic(localMemberId: alice), {
        DmTopicWire.mainId: 0,
      });
    });
  });

  group('DM topic reducer', () {
    test('main is implicit and cannot be changed', () {
      final state = reduce([
        event(
          'rename-main',
          alice,
          const DmTopicEvent.rename(
            topicId: DmTopicWire.mainId,
            revision: 2,
            name: 'renamed',
          ),
        ),
        event(
          'archive-main',
          alice,
          const DmTopicEvent.archive(
            topicId: DmTopicWire.mainId,
            revision: 2,
            archived: true,
          ),
        ),
      ]);

      expect(state.topic(DmTopicWire.mainId)?.name, 'main');
      expect(state.topic(DmTopicWire.mainId)?.archivedBy, isEmpty);
      expect(state.visibleTopics(localMemberId: alice), hasLength(1));
    });

    test('either member can create and rename a custom topic', () {
      final state = reduce([
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
        ),
        event(
          'rename-a',
          bob,
          const DmTopicEvent.rename(
            topicId: topicA,
            revision: 2,
            name: 'summer trip',
          ),
        ),
      ]);

      expect(state.topic(topicA)?.name, 'summer trip');
      expect(state.topic(topicA)?.createdBy, alice);
    });

    test('rename and personal archive commute', () {
      final records = [
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
        ),
        event(
          'rename-a',
          bob,
          const DmTopicEvent.rename(
            topicId: topicA,
            revision: 2,
            name: 'plans',
          ),
        ),
        event(
          'archive-a',
          alice,
          const DmTopicEvent.archive(
            topicId: topicA,
            revision: 1,
            archived: true,
          ),
        ),
      ];

      final forward = reduce(records);
      final reverse = reduce(records.reversed);

      expect(forward.topic(topicA), reverse.topic(topicA));
      expect(forward.topic(topicA)?.name, 'plans');
      expect(forward.topic(topicA)?.archivedBy, {alice});
    });

    test(
      'the open locally archived topic stays in the row until selection leaves',
      () {
        final state = reduce([
          event(
            'create-a',
            alice,
            const DmTopicEvent.create(
              topicId: topicA,
              revision: 1,
              name: 'vacation',
              order: 1,
            ),
          ),
          event(
            'archive-a',
            alice,
            const DmTopicEvent.archive(
              topicId: topicA,
              revision: 1,
              archived: true,
            ),
          ),
        ]);

        expect(
          state.visibleTopics(localMemberId: alice).map((topic) => topic.id),
          [DmTopicWire.mainId],
        );
        expect(
          state
              .visibleTopics(localMemberId: alice, retainedTopicId: topicA)
              .map((topic) => topic.id),
          [DmTopicWire.mainId, topicA],
        );
      },
    );

    test('a non-member cannot change archive state', () {
      final state = reduce([
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
        ),
        event(
          'archive-a',
          'mallory',
          const DmTopicEvent.archive(
            topicId: topicA,
            revision: 99,
            archived: true,
          ),
        ),
      ]);

      expect(state.topic(topicA)?.archivedBy, isEmpty);
    });

    test('same revision uses commit ID and not timestamp or arrival', () {
      final common = event(
        'create-a',
        alice,
        const DmTopicEvent.create(
          topicId: topicA,
          revision: 1,
          name: 'vacation',
          order: 1,
        ),
      );
      final lower = event(
        'rename-1',
        alice,
        const DmTopicEvent.rename(topicId: topicA, revision: 2, name: 'lower'),
      );
      final higher = event(
        'rename-2',
        bob,
        const DmTopicEvent.rename(topicId: topicA, revision: 2, name: 'higher'),
      );

      expect(reduce([common, lower, higher]).topic(topicA)?.name, 'higher');
      expect(reduce([higher, lower, common]).topic(topicA)?.name, 'higher');
    });

    test('duplicate active names get stable numeric suffixes', () {
      final records = [
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 2,
          ),
        ),
        event(
          'create-b',
          bob,
          const DmTopicEvent.create(
            topicId: topicB,
            revision: 1,
            name: 'vacation',
            order: 3,
          ),
        ),
      ];

      final topics = reduce(
        records.reversed,
      ).visibleTopics(localMemberId: alice);

      expect(topics.map((topic) => topic.name), [
        'main',
        'vacation',
        'vacation 2',
      ]);
      expect(topics.map((topic) => topic.id), [
        DmTopicWire.mainId,
        topicA,
        topicB,
      ]);
    });

    test('archive ordering does not change duplicate-name suffixes', () {
      final state = reduce([
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 2,
          ),
        ),
        event(
          'create-b',
          bob,
          const DmTopicEvent.create(
            topicId: topicB,
            revision: 1,
            name: 'vacation',
            order: 3,
          ),
        ),
        event(
          'archive-a',
          bob,
          const DmTopicEvent.archive(
            topicId: topicA,
            revision: 1,
            archived: true,
          ),
        ),
      ]);

      final topics = state.visibleTopics(localMemberId: alice);

      expect(topics.map((topic) => topic.id), [
        DmTopicWire.mainId,
        topicB,
        topicA,
      ]);
      expect(topics.map((topic) => topic.name), [
        'main',
        'vacation 2',
        'vacation',
      ]);
    });

    test('an unknown tagged item is quarantined until its create arrives', () {
      final message = item('message-a', bob, topicId: topicA, position: 1);
      final before = reduce([message]);
      final after = reduce([
        message,
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
        ),
      ]);

      expect(before.topicForItem(message), isNull);
      expect(
        before.unreadByTopic(localMemberId: alice).values,
        everyElement(0),
      );
      expect(after.topicForItem(message)?.id, topicA);
      expect(after.unreadByTopic(localMemberId: alice)[topicA], 1);
    });

    test('duplicate events are idempotent', () {
      final create = event(
        'create-a',
        alice,
        const DmTopicEvent.create(
          topicId: topicA,
          revision: 1,
          name: 'vacation',
          order: 1,
        ),
      );

      final state = reduce([create, create]);

      expect(state.customTopics, hasLength(1));
      expect(state.acceptedEventCount, 1);
    });

    test('topic reads require a matching item from the other member', () {
      final records = [
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
        ),
        item('a-1', alice, topicId: topicA, position: 2, daemonRead: true),
        item('a-2', alice, topicId: topicA, position: 3, daemonRead: true),
        event(
          'read-a-1',
          bob,
          const DmTopicEvent.read(
            topicId: topicA,
            revision: 1,
            messageId: 'a-1',
          ),
        ),
        event(
          'bad-self-read',
          alice,
          const DmTopicEvent.read(
            topicId: topicA,
            revision: 99,
            messageId: 'a-2',
          ),
        ),
      ];
      final state = reduce(records);

      expect(state.effectiveRead('a-1', readerId: bob), isTrue);
      expect(state.effectiveRead('a-2', readerId: bob), isFalse);
      expect(state.effectiveRead('a-2', readerId: alice), isFalse);
    });

    test('a read event resolves after its target arrives', () {
      final create = event(
        'create-a',
        alice,
        const DmTopicEvent.create(
          topicId: topicA,
          revision: 1,
          name: 'vacation',
          order: 1,
        ),
      );
      final message = item('a-1', alice, topicId: topicA, position: 2);
      final read = event(
        'read-a-1',
        bob,
        const DmTopicEvent.read(topicId: topicA, revision: 1, messageId: 'a-1'),
      );

      expect(
        reduce([read, create, message]).effectiveRead('a-1', readerId: bob),
        isTrue,
      );
    });

    test('an explicit main read covers an untagged legacy item', () {
      final state = reduce([
        item('legacy-main', alice, position: 1),
        event(
          'read-legacy-main',
          bob,
          const DmTopicEvent.read(
            topicId: DmTopicWire.mainId,
            revision: 1,
            messageId: 'legacy-main',
          ),
          position: 2,
        ),
      ]);

      expect(state.effectiveRead('legacy-main', readerId: bob), isTrue);
      expect(state.unreadByTopic(localMemberId: bob)[DmTopicWire.mainId], 0);
    });

    test('a read event cannot target a later commit', () {
      final state = reduce([
        event(
          'create-a',
          alice,
          const DmTopicEvent.create(
            topicId: topicA,
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
          position: 1,
        ),
        event(
          'read-future',
          bob,
          const DmTopicEvent.read(
            topicId: topicA,
            revision: 1,
            messageId: 'future-message',
          ),
          position: 2,
        ),
        item('future-message', alice, topicId: topicA, position: 3),
      ]);

      expect(state.effectiveRead('future-message', readerId: bob), isFalse);
    });

    test(
      'unread counts are per topic and legacy daemon reads remain valid',
      () {
        final state = reduce([
          event(
            'create-a',
            alice,
            const DmTopicEvent.create(
              topicId: topicA,
              revision: 1,
              name: 'vacation',
              order: 1,
            ),
          ),
          item('legacy', bob, position: 1, daemonRead: true),
          item('main-new', bob, topicId: DmTopicWire.mainId, position: 2),
          item('topic-new', bob, topicId: topicA, position: 3),
          event(
            'read-main',
            alice,
            const DmTopicEvent.read(
              topicId: DmTopicWire.mainId,
              revision: 1,
              messageId: 'main-new',
            ),
          ),
        ]);

        expect(state.unreadByTopic(localMemberId: alice), {
          DmTopicWire.mainId: 0,
          topicA: 1,
        });
      },
    );
  });
}
