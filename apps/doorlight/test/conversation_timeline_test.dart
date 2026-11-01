import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/dm_topics.dart';

void main() {
  test(
    'compatible text merges keep the later receipt and union of readers',
    () {
      final scope = ConversationScope(
        accountId: 'account',
        peerId: 'peer',
        conversationId: 'conversation',
      );
      TimelineTextItem item(TimelineDeliveryState delivery, String reader) =>
          TimelineTextItem(
            scope: scope,
            daemonId: 'message',
            versionId: 'version',
            authorId: 'author',
            direction: TimelineDirection.outgoing,
            createdAt: DateTime.utc(2026),
            text: 'Hello',
            deliveryState: delivery,
            readByMemberIds: {reader},
          );
      const expected = [
        [
          TimelineDeliveryState.sent,
          TimelineDeliveryState.delivered,
          TimelineDeliveryState.read,
        ],
        [
          TimelineDeliveryState.delivered,
          TimelineDeliveryState.delivered,
          TimelineDeliveryState.read,
        ],
        [
          TimelineDeliveryState.read,
          TimelineDeliveryState.read,
          TimelineDeliveryState.read,
        ],
      ];
      for (final left in TimelineDeliveryState.values) {
        for (final right in TimelineDeliveryState.values) {
          final original = item(left, 'first');
          final incoming = item(right, 'second');
          final merged = original.mergeCompatible(incoming)!;
          expect(merged.deliveryState, expected[left.index][right.index]);
          expect(merged.readByMemberIds, {'first', 'second'});
          expect(original.readByMemberIds, {'first'});
          expect(incoming.readByMemberIds, {'second'});
        }
      }
    },
  );

  test(
    'live reaction removal wins over delayed refresh and older-page snapshots',
    () async {
      final peer = 'b' * 40,
          local = 'c' * 40,
          target = 'a' * 40,
          older = 'd' * 40;
      final reactionScope = ConversationScope(
        accountId: 'account',
        peerId: peer,
        conversationId: 'conversation',
      );
      final repository = _FakeTimelineRepository();
      final controller = ConversationTimelineController(
        scope: reactionScope,
        localAuthorId: local,
        repository: repository,
        pageSize: 1,
      );
      addTearDown(controller.dispose);
      Map<String, Object?> change(
        String message, {
        String? remove,
        String? add,
      }) => {
        ...reactionScope.toMap(),
        'messageId': message,
        'removedId': ?remove,
        if (add != null)
          'reaction': {'commitId': add, 'authorId': peer, 'emoji': '👍'},
      };
      Map<String, Object?> snapshot(String message, String reaction) => {
        ..._text(reactionScope, daemonId: message, body: 'Message'),
        'reactions': {
          'messageId': message,
          'complete': true,
          'entries': [
            {'commitId': reaction, 'authorId': peer, 'emoji': '👍'},
          ],
        },
      };
      final load = controller.refresh();
      expect(
        controller.mergeReaction(change(target, remove: '1' * 40)),
        TimelineMergeOutcome.unchanged,
      );
      expect(controller.items, isEmpty);
      repository.loads.single.complete(
        items: [snapshot(target, '1' * 40)],
        hasMore: true,
        nextCursor: 'older',
      );
      await load;
      expect(controller.items.single.reactions.count('👍'), 0);
      expect(
        controller.mergeReaction(change(target, add: '2' * 40)),
        TimelineMergeOutcome.updated,
      );
      expect(
        controller.mergeReaction(change(target, add: '2' * 40)),
        TimelineMergeOutcome.unchanged,
      );
      expect(controller.items.single.reactions.count('👍'), 1);
      final more = controller.loadMore();
      controller.mergeReaction(change(older, remove: '3' * 40));
      repository.loads.last.complete(items: [snapshot(older, '3' * 40)]);
      await more;
      expect(controller.items.first.reactions.count('👍'), 0);
      expect(controller.items.last.reactions.count('👍'), 1);
      expect(
        controller.mergeReaction({
          ...change(target, remove: '2' * 40),
          'accountId': 'other',
        }),
        TimelineMergeOutcome.rejected,
      );
      expect(controller.items.last.reactions.count('👍'), 1);
    },
  );

  test(
    'reaction reconciliation overflow retires the stale load without inserting it',
    () async {
      final peer = 'b' * 40, target = 'a' * 40;
      final reactionScope = ConversationScope(
        accountId: 'account',
        peerId: peer,
        conversationId: 'conversation',
      );
      final repository = _FakeTimelineRepository();
      final controller = ConversationTimelineController(
        scope: reactionScope,
        localAuthorId: 'c' * 40,
        repository: repository,
      );
      addTearDown(controller.dispose);
      final load = controller.refresh();
      for (
        var i = 0;
        i <= ConversationTimelineController.maximumPendingReactionChanges;
        i++
      ) {
        controller.mergeReaction({
          ...reactionScope.toMap(),
          'messageId': target,
          'removedId': '1' * 40,
        });
      }
      expect(controller.isLoading, isFalse);
      expect(controller.lastError, isA<TimelineProtocolException>());
      repository.loads.single.complete(
        items: [_text(reactionScope, daemonId: target, body: 'Stale')],
      );
      await load;
      expect(controller.items, isEmpty);
    },
  );
  const localAuthorId = 'local-jami-id';
  final scope = ConversationScope(
    accountId: 'local-daemon-account-uuid',
    peerId: 'peer-jami-id',
    conversationId: 'conversation-a',
  );
  final otherScope = ConversationScope(
    accountId: 'local-daemon-account-uuid',
    peerId: 'other-peer-jami-id',
    conversationId: 'conversation-b',
  );
  final groupScope = ConversationScope(
    accountId: scope.accountId,
    peerId: 'group:conversation-group',
    conversationId: 'conversation-group',
    kind: ConversationKind.group,
  );

  group('TimelineItemParser', () {
    test('reaction snapshots retain own commit IDs and survive receipts', () {
      final peer = 'b' * 40;
      final local = 'c' * 40;
      final reactionScope = ConversationScope(
        accountId: 'account',
        peerId: peer,
        conversationId: 'conversation',
      );
      final message = 'a' * 40;
      final wire = _text(reactionScope, daemonId: message, body: 'Hello')
        ..['reactions'] = {
          'messageId': message,
          'complete': true,
          'entries': [
            {'commitId': '1' * 40, 'authorId': local, 'emoji': '👍'},
          ],
        };
      const parser = TimelineItemParser();
      final item = parser
          .parse(
            expectedScope: reactionScope,
            localAuthorId: local,
            value: wire,
          )
          .item!;
      expect(item.reactions.removalCommitIds(local, '👍'), ['1' * 40]);
      expect(
        item.withDeliveryState(TimelineDeliveryState.read).reactions,
        item.reactions,
      );
      expect(
        parser
            .parse(
              expectedScope: reactionScope,
              localAuthorId: peer,
              value: wire,
            )
            .item,
        isNull,
      );
      expect(
        parser
            .parse(
              expectedScope: reactionScope,
              localAuthorId: local,
              value: {
                ...wire,
                'reactions': {
                  'messageId': 'other',
                  'complete': true,
                  'entries': [],
                },
              },
            )
            .item,
        isNull,
      );
    });
    test(
      'authenticated reply references survive receipts and reject conflicting duplicates',
      () {
        const parser = TimelineItemParser();
        final wire = _text(scope, daemonId: 'reply', body: 'My reply')
          ..['replyTo'] = 'target';
        final item = parser
            .parse(
              expectedScope: scope,
              localAuthorId: localAuthorId,
              value: wire,
            )
            .item!;
        expect(item.replyTo, 'target');
        expect(
          item.withDeliveryState(TimelineDeliveryState.read).replyTo,
          'target',
        );
        final other = parser
            .parse(
              expectedScope: scope,
              localAuthorId: localAuthorId,
              value: {...wire, 'replyTo': 'different'},
            )
            .item!;
        expect(item.mergeCompatible(other), isNull);
        for (final malformed in [
          false,
          ['target'],
          'x' * 1025,
        ]) {
          expect(
            parser
                .parse(
                  expectedScope: scope,
                  localAuthorId: localAuthorId,
                  value: {...wire, 'replyTo': malformed},
                )
                .item,
            isNull,
          );
        }
      },
    );
    const parser = TimelineItemParser();

    test(
      'keeps legacy content in main and preserves valid topic ownership',
      () {
        final legacy = parser
            .parse(
              expectedScope: scope,
              localAuthorId: localAuthorId,
              value: _text(scope, daemonId: 'legacy', body: 'old'),
            )
            .item!;
        final tagged = parser
            .parse(
              expectedScope: scope,
              localAuthorId: localAuthorId,
              value: _text(
                scope,
                daemonId: 'tagged',
                body: 'plans',
                topicId: '0123456789abcdef0123456789abcdef',
                topicTagged: true,
                linearizedParent: 'legacy',
              ),
            )
            .item!;

        expect(legacy.topicId, DmTopicWire.mainId);
        expect(legacy.topicTagged, isFalse);
        expect(tagged.topicId, '0123456789abcdef0123456789abcdef');
        expect(tagged.topicTagged, isTrue);
        expect(tagged.linearizedParent, 'legacy');
        expect(
          parser
              .parse(
                expectedScope: scope,
                localAuthorId: localAuthorId,
                value: _text(
                  scope,
                  daemonId: 'bad-topic',
                  body: 'bad',
                  topicId: 'BAD',
                  topicTagged: true,
                ),
              )
              .failure,
          TimelineParseFailure.malformedTopic,
        );
      },
    );

    test('keeps signed DM topic events out of the visible item list', () {
      final controller = _controller(scope, _FakeTimelineRepository());
      addTearDown(controller.dispose);
      final event = <String, Object?>{
        ...scope.toMap(),
        'daemonId': 'event-a',
        'versionId': 'event-a',
        'mimeType': DmTopicWire.mimeType,
        'authorId': scope.peerId,
        'timestampSeconds': 1,
        'linearizedParent': 'message-a',
        'topicId': DmTopicWire.mainId,
        'topicTagged': false,
        'eventBody': DmTopicEventCodec.encode(
          const DmTopicEvent.create(
            topicId: '0123456789abcdef0123456789abcdef',
            revision: 1,
            name: 'vacation',
            order: 1,
          ),
        ),
      };

      expect(controller.mergeLive(event), TimelineMergeOutcome.inserted);
      expect(controller.items, isEmpty);
      expect(controller.allItems.single, isA<TimelineDmTopicEventItem>());
      expect(
        (controller.allItems.single as TimelineDmTopicEventItem).eventBody,
        event['eventBody'],
      );
    });

    test('keeps daemon account ownership separate from message author', () {
      final outgoing = parser.parse(
        expectedScope: scope,
        localAuthorId: localAuthorId,
        value: _text(
          scope,
          daemonId: 'outgoing',
          authorId: localAuthorId,
          body: 'hello',
        ),
      );
      final incoming = parser.parse(
        expectedScope: scope,
        localAuthorId: localAuthorId,
        value: _text(
          scope,
          daemonId: 'incoming',
          authorId: scope.peerId,
          body: 'hi',
        ),
      );

      expect(outgoing.item?.direction, TimelineDirection.outgoing);
      expect(incoming.item?.direction, TimelineDirection.incoming);
      expect(scope.accountId, isNot(localAuthorId));
      expect(
        parser
            .parse(
              expectedScope: scope,
              localAuthorId: localAuthorId,
              value: _text(
                scope,
                daemonId: 'wrong-author',
                authorId: scope.accountId,
                body: 'not an author URI',
              ),
            )
            .failure,
        TimelineParseFailure.unexpectedAuthor,
      );
    });

    test('group scope accepts only its explicit active member set', () {
      final accepted = parser.parse(
        expectedScope: groupScope,
        localAuthorId: localAuthorId,
        allowedRemoteAuthorIds: const {'member-a', 'member-b'},
        value: _text(
          groupScope,
          daemonId: 'member-message',
          authorId: 'member-b',
          body: 'hello group',
        ),
      );
      final rejected = parser.parse(
        expectedScope: groupScope,
        localAuthorId: localAuthorId,
        allowedRemoteAuthorIds: const {'member-a', 'member-b'},
        value: _text(
          groupScope,
          daemonId: 'invited-message',
          authorId: 'invited-member',
          body: 'not active',
        ),
      );

      expect(accepted.item?.direction, TimelineDirection.incoming);
      expect(rejected.failure, TimelineParseFailure.unexpectedAuthor);
    });

    test('accepts only authenticated group reader ids', () {
      final allowed = const {'member-a', 'member-b'};
      final parsed = parser.parse(
        expectedScope: groupScope,
        localAuthorId: localAuthorId,
        allowedRemoteAuthorIds: allowed,
        value: _text(
          groupScope,
          daemonId: 'group-receipt',
          authorId: localAuthorId,
          body: 'hello group',
          deliveryState: 3,
          readByMemberIds: const ['member-a', 'member-a', 'member-b'],
        ),
      );

      expect(parsed.item?.readByMemberIds, allowed);
      for (final value in [
        _text(
          scope,
          daemonId: 'direct-readers',
          authorId: localAuthorId,
          body: 'direct',
          readByMemberIds: const <String>[],
        ),
        _text(
          groupScope,
          daemonId: 'incoming-readers',
          authorId: 'member-a',
          body: 'incoming',
          readByMemberIds: const ['member-a'],
        ),
        _text(
          groupScope,
          daemonId: 'unknown-reader',
          authorId: localAuthorId,
          body: 'outgoing',
          readByMemberIds: const ['invited-member'],
        ),
        _text(
          groupScope,
          daemonId: 'too-many-readers',
          authorId: localAuthorId,
          body: 'outgoing',
          readByMemberIds: List.filled(
            TimelineWireContract.maxGroupReceiptMembers + 1,
            'member-a',
          ),
        ),
      ]) {
        expect(
          parser
              .parse(
                expectedScope: value['peerId'] == scope.peerId
                    ? scope
                    : groupScope,
                localAuthorId: localAuthorId,
                allowedRemoteAuthorIds: allowed,
                value: value,
              )
              .failure,
          TimelineParseFailure.malformedEnvelope,
        );
      }
    });

    test('parses versioned Unix-second text snapshots and edits', () {
      final snapshot = parser.parse(
        expectedScope: scope,
        localAuthorId: localAuthorId,
        value: _text(
          scope,
          daemonId: 'message',
          versionId: 'edition-1',
          body: 'first',
          timestampSeconds: '123',
        ),
      );
      final edit = parser.parse(
        expectedScope: scope,
        localAuthorId: localAuthorId,
        value: _text(
          scope,
          daemonId: 'message',
          versionId: 'edition-2',
          body: 'second',
          operation: 'edit',
        ),
      );

      expect(snapshot.mutation?.kind, TimelineMutationKind.snapshot);
      expect(snapshot.item, isA<TimelineTextItem>());
      expect(snapshot.item?.versionId, 'edition-1');
      expect(
        snapshot.item?.createdAt,
        DateTime.fromMillisecondsSinceEpoch(123000, isUtc: true),
      );
      expect(edit.mutation?.kind, TimelineMutationKind.edit);
      expect((edit.item! as TimelineTextItem).text, 'second');
    });

    test('turns an empty edited or folded text body into a tombstone', () {
      for (final operation in [null, 'edit']) {
        final parsed = parser.parse(
          expectedScope: scope,
          localAuthorId: localAuthorId,
          value: _text(
            scope,
            daemonId: 'deleted',
            versionId: 'latest-edition',
            body: '',
            operation: operation,
          ),
        );

        expect(parsed.isAccepted, isTrue);
        expect(parsed.mutation?.kind, TimelineMutationKind.delete);
        expect(parsed.item, isNull);
      }
    });

    test('accepts an explicit adapter-level file tombstone', () {
      final value = _file(
        scope,
        daemonId: 'deleted-file-message',
        versionId: 'latest-edition',
        body: const {},
      )..['deleted'] = true;

      final parsed = parser.parse(
        expectedScope: scope,
        localAuthorId: localAuthorId,
        value: value,
      );

      expect(parsed.isAccepted, isTrue);
      expect(parsed.mutation?.kind, TimelineMutationKind.delete);
      expect(parsed.item, isNull);
    });

    test('parses bounded file metadata and native scalar variants', () {
      final parsed = parser.parse(
        expectedScope: scope,
        localAuthorId: localAuthorId,
        value: _file(
          scope,
          daemonId: 'file-message',
          body: {
            'fileId': 'file-id',
            'displayName': 'notes.txt',
            'totalBytes': '42',
            'sha3': 'abc',
            'downloaded': 'true',
          },
        ),
      );

      final item = parsed.item! as TimelineFileItem;
      expect(item.fileId, 'file-id');
      expect(item.totalBytes, 42);
      expect(item.sha3, 'abc');
      expect(item.downloaded, isTrue);
      expect(item.direction, TimelineDirection.incoming);
    });

    test('rejects malformed envelopes and unsupported content', () {
      final valid = _text(scope, daemonId: 'message', body: 'hello');
      final cases = <(Map<String, Object?>, TimelineParseFailure)>[
        ({...valid, 'accountId': ''}, TimelineParseFailure.malformedScope),
        ({...valid, ...otherScope.toMap()}, TimelineParseFailure.scopeMismatch),
        ({...valid, 'versionId': ''}, TimelineParseFailure.malformedEnvelope),
        (
          {...valid, 'timestampSeconds': -1},
          TimelineParseFailure.malformedEnvelope,
        ),
        (
          {...valid, 'timestampSeconds': 8640000000001},
          TimelineParseFailure.malformedEnvelope,
        ),
        (
          {...valid, 'operation': 'unknown'},
          TimelineParseFailure.malformedEnvelope,
        ),
        (
          {...valid, 'deleted': 'maybe'},
          TimelineParseFailure.malformedEnvelope,
        ),
        (
          {...valid, 'authorId': 'third-party'},
          TimelineParseFailure.unexpectedAuthor,
        ),
        (
          {...valid, 'mimeType': 'application/octet-stream'},
          TimelineParseFailure.unsupportedMimeType,
        ),
        ({...valid, 'body': 7}, TimelineParseFailure.malformedText),
        (
          {
            ...valid,
            'body': List.filled(
              TimelineWireContract.maxTextCodeUnits + 1,
              'x',
            ).join(),
          },
          TimelineParseFailure.malformedText,
        ),
      ];

      for (final (value, expected) in cases) {
        expect(
          parser
              .parse(
                expectedScope: scope,
                localAuthorId: localAuthorId,
                value: value,
              )
              .failure,
          expected,
        );
      }
    });

    test('rejects malformed files and file edit claims', () {
      final valid = _file(
        scope,
        daemonId: 'file',
        body: {'fileId': 'file-id', 'displayName': 'file.txt'},
      );
      for (final value in [
        {...valid, 'body': 'not-a-map'},
        {
          ...valid,
          'body': {'fileId': '', 'displayName': 'file.txt'},
        },
        {
          ...valid,
          'body': {
            'fileId': 'file-id',
            'displayName': 'file.txt',
            'totalBytes': -1,
          },
        },
        {
          ...valid,
          'body': {
            'fileId': 'file-id',
            'displayName': 'file.txt',
            'downloaded': 'yes',
          },
        },
        {...valid, 'operation': 'edit'},
      ]) {
        expect(
          parser
              .parse(
                expectedScope: scope,
                localAuthorId: localAuthorId,
                value: value,
              )
              .failure,
          TimelineParseFailure.malformedFile,
        );
      }
    });
  });

  group('ConversationTimelineController', () {
    test('delivery receipts advance monotonically for outgoing messages', () {
      final controller = _controller(scope, _FakeTimelineRepository());
      addTearDown(controller.dispose);
      controller.mergeLive(
        _text(
          scope,
          daemonId: 'receipt-message',
          authorId: localAuthorId,
          body: 'hello',
        ),
      );

      expect(controller.items.single.deliveryState, TimelineDeliveryState.sent);
      expect(controller.updateDelivery('receipt-message', 2), isTrue);
      expect(
        controller.items.single.deliveryState,
        TimelineDeliveryState.delivered,
      );
      expect(controller.updateDelivery('receipt-message', 1), isFalse);
      expect(controller.updateDelivery('receipt-message', 3), isTrue);
      expect(controller.items.single.deliveryState, TimelineDeliveryState.read);
    });

    test('group receipt updates count each active reader once', () {
      final controller = _controller(
        groupScope,
        _FakeTimelineRepository(),
        allowedRemoteAuthorIds: const {'member-a', 'member-b'},
      );
      addTearDown(controller.dispose);
      controller.mergeLive(
        _text(
          groupScope,
          daemonId: 'group-receipt',
          authorId: localAuthorId,
          body: 'hello',
        ),
      );

      expect(
        controller.updateDelivery('group-receipt', 3, memberId: 'member-a'),
        isTrue,
      );
      expect(
        controller.updateDelivery('group-receipt', 3, memberId: 'member-a'),
        isFalse,
      );
      expect(
        controller.updateDelivery(
          'group-receipt',
          3,
          memberId: 'invited-member',
        ),
        isFalse,
      );
      expect(
        controller.updateDelivery('group-receipt', 3, memberId: 'member-b'),
        isTrue,
      );
      expect(controller.items.single.readByMemberIds, {'member-a', 'member-b'});
    });

    group('delivery receipts during a staged refresh', () {
      Map<String, Object?> sent(ConversationScope scope, String id) =>
          _text(scope, daemonId: id, authorId: localAuthorId, body: 'hello');

      test('survive commit of an older sent snapshot', () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);
        addTearDown(controller.dispose);
        controller.mergeLive(sent(scope, 'm'));

        final load = controller.refresh();
        expect(controller.updateDelivery('m', 2), isTrue);
        expect(controller.updateDelivery('m', 3), isTrue);
        repository.loads.single.complete(items: [sent(scope, 'm')]);
        await load;

        expect(
          controller.items.single.deliveryState,
          TimelineDeliveryState.read,
        );
      });

      test('are idempotent and never lower the state', () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);
        addTearDown(controller.dispose);
        controller.mergeLive(sent(scope, 'm'));

        final load = controller.refresh();
        expect(controller.updateDelivery('m', 3), isTrue);
        expect(controller.updateDelivery('m', 3), isFalse);
        expect(controller.updateDelivery('m', 2), isFalse);
        repository.loads.single.complete(items: [sent(scope, 'm')]);
        await load;

        expect(
          controller.items.single.deliveryState,
          TimelineDeliveryState.read,
        );
      });

      test('keep group readers and reject unauthorized readers', () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(
          groupScope,
          repository,
          allowedRemoteAuthorIds: const {'member-a', 'member-b'},
        );
        addTearDown(controller.dispose);
        controller.mergeLive(sent(groupScope, 'g'));

        final load = controller.refresh();
        controller.updateDelivery('g', 3, memberId: 'member-a');
        controller.updateDelivery('g', 3, memberId: 'member-a');
        controller.updateDelivery('g', 3, memberId: 'invited-member');
        controller.updateDelivery('g', 3, memberId: localAuthorId);
        repository.loads.single.complete(items: [sent(groupScope, 'g')]);
        await load;

        expect(controller.items.single.readByMemberIds, {'member-a'});
        expect(
          controller.items.single.deliveryState,
          TimelineDeliveryState.read,
        );
      });

      test(
        'apply to a message present only in the refreshed snapshot',
        () async {
          final repository = _FakeTimelineRepository();
          final controller = _controller(scope, repository);
          addTearDown(controller.dispose);

          final load = controller.refresh();
          controller.updateDelivery('late', 2);
          expect(controller.items, isEmpty);
          repository.loads.single.complete(items: [sent(scope, 'late')]);
          await load;

          expect(
            controller.items.single.deliveryState,
            TimelineDeliveryState.delivered,
          );
        },
      );

      test('never insert or resurrect a message', () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);
        addTearDown(controller.dispose);
        controller.mergeLive(sent(scope, 'gone'));

        final load = controller.refresh();
        controller.updateDelivery('gone', 3);
        controller.updateDelivery('never-seen', 3);
        repository.loads.single.complete(
          items: [
            _text(
              scope,
              daemonId: 'gone',
              versionId: 'latest-edition',
              authorId: localAuthorId,
              body: '',
            ),
          ],
        );
        await load;

        expect(controller.items, isEmpty);
      });

      test('are dropped after cancelPendingLoad', () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);
        addTearDown(controller.dispose);
        controller.mergeLive(sent(scope, 'm'));

        controller.refresh();
        controller.updateDelivery('m', 3);
        controller.cancelPendingLoad();
        final load = controller.refresh();
        repository.loads.last.complete(items: [sent(scope, 'm')]);
        await load;

        expect(
          controller.items.single.deliveryState,
          TimelineDeliveryState.sent,
        );
      });

      test(
        'are dropped when a second refresh replaces the generation',
        () async {
          final repository = _FakeTimelineRepository();
          final controller = _controller(scope, repository);
          addTearDown(controller.dispose);
          controller.mergeLive(sent(scope, 'm'));

          final stale = controller.refresh();
          controller.updateDelivery('m', 3);
          final current = controller.refresh();
          repository.loads.first.complete(items: [sent(scope, 'm')]);
          repository.loads.last.complete(items: [sent(scope, 'm')]);
          await stale;
          await current;

          expect(
            controller.items.single.deliveryState,
            TimelineDeliveryState.sent,
          );
        },
      );

      test('are bounded and cancel the stale snapshot on overflow', () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);
        addTearDown(controller.dispose);

        final load = controller.refresh();
        for (
          var i = 0;
          i <= ConversationTimelineController.maximumPendingDeliveryEvidence;
          i++
        ) {
          controller.updateDelivery('m$i', 2);
        }
        expect(controller.lastError, isA<TimelineProtocolException>());
        expect(controller.isLoading, isFalse);
        repository.loads.single.complete(items: [sent(scope, 'm0')]);
        await load;
        expect(controller.items, isEmpty);
      });
    });

    test(
      'loads, sorts, paginates, and keeps daemon correlation visible',
      () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository, pageSize: 2);

        final firstLoad = controller.refresh();
        expect(repository.loads, hasLength(1));
        expect(repository.loads.single.request.scope, scope);
        expect(repository.loads.single.request.beforeCursor, isNull);
        expect(repository.loads.single.request.limit, 2);
        await _flush();
        expect(controller.activeDaemonLoadId, 'load-1');

        repository.loads.single.complete(
          items: [
            _text(
              scope,
              daemonId: 'newer',
              body: 'newer',
              timestampSeconds: 20,
            ),
            _text(
              scope,
              daemonId: 'middle',
              body: 'middle',
              timestampSeconds: 10,
            ),
          ],
          hasMore: true,
          nextCursor: 'before-middle',
        );
        await firstLoad;

        expect(controller.items.map((item) => item.daemonId), [
          'middle',
          'newer',
        ]);
        expect(controller.hasMore, isTrue);

        final secondLoad = controller.loadMore();
        expect(repository.loads, hasLength(2));
        expect(repository.loads.last.request.beforeCursor, 'before-middle');
        repository.loads.last.complete(
          items: [
            _text(
              scope,
              daemonId: 'oldest',
              body: 'oldest',
              timestampSeconds: 1,
            ),
          ],
        );
        await secondLoad;

        expect(controller.items.map((item) => item.daemonId), [
          'oldest',
          'middle',
          'newer',
        ]);
        expect(controller.hasMore, isFalse);
        expect(controller.lastError, isNull);
      },
    );

    test(
      'preserves daemon order when several messages share one second',
      () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);

        final load = controller.refresh();
        repository.loads.single.complete(
          // libjami pages are newest-first. The ids are intentionally ordered in
          // the opposite lexical direction: hashes are not chronology.
          items: [
            _text(
              scope,
              daemonId: 'aaa-newest',
              body: 'newest',
              timestampSeconds: 20,
            ),
            _text(
              scope,
              daemonId: 'zzz-older',
              body: 'older',
              timestampSeconds: 20,
            ),
          ],
        );
        await load;
        controller.mergeLive(
          _text(
            scope,
            daemonId: '000-live-latest',
            body: 'live latest',
            timestampSeconds: 20,
          ),
        );

        expect(controller.items.map((item) => item.daemonId), [
          'zzz-older',
          'aaa-newest',
          '000-live-latest',
        ]);
      },
    );

    test('daemon commit order wins over sender clock skew', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);

      final load = controller.refresh();
      repository.loads.single.complete(
        // Newest-first daemon order for messages written 1 through 6. The
        // local author's clock is one minute behind the peer's clock.
        items: [
          _text(scope, daemonId: '6', body: '6', timestampSeconds: 202),
          _text(
            scope,
            daemonId: '5',
            authorId: 'local-jami-id',
            body: '5',
            timestampSeconds: 102,
          ),
          _text(scope, daemonId: '4', body: '4', timestampSeconds: 201),
          _text(scope, daemonId: '3', body: '3', timestampSeconds: 200),
          _text(
            scope,
            daemonId: '2',
            authorId: 'local-jami-id',
            body: '2',
            timestampSeconds: 101,
          ),
          _text(
            scope,
            daemonId: '1',
            authorId: 'local-jami-id',
            body: '1',
            timestampSeconds: 100,
          ),
        ],
      );
      await load;

      expect(controller.items.map((item) => (item as TimelineTextItem).text), [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
      ]);
    });

    test('merges live and history duplicates idempotently', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);
      final live = _text(
        scope,
        daemonId: 'same',
        versionId: 'same-version',
        body: 'one copy',
      );

      expect(controller.mergeLive(live), TimelineMergeOutcome.inserted);
      expect(controller.mergeLive(live), TimelineMergeOutcome.unchanged);

      final load = controller.refresh();
      controller.mergeLive(live);
      repository.loads.single.complete(items: [live, live]);
      await load;

      expect(controller.items, hasLength(1));
      expect(controller.rejectedItemCount, 0);
    });

    test('enriches equal-version file state without duplicating it', () {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);
      final base = _file(
        scope,
        daemonId: 'file-message',
        versionId: 'version',
        body: {'fileId': 'file', 'displayName': 'photo.jpg'},
      );
      final enriched = _file(
        scope,
        daemonId: 'file-message',
        versionId: 'version',
        body: {
          'fileId': 'file',
          'displayName': 'photo.jpg',
          'totalBytes': 123,
          'sha3': 'hash',
          'downloaded': true,
        },
      );

      expect(controller.mergeLive(base), TimelineMergeOutcome.inserted);
      expect(controller.mergeLive(enriched), TimelineMergeOutcome.updated);

      final item = controller.items.single as TimelineFileItem;
      expect(item.totalBytes, 123);
      expect(item.sha3, 'hash');
      expect(item.downloaded, isTrue);
    });

    test('removes a file through an explicit versioned adapter tombstone', () {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);
      controller.mergeLive(
        _file(
          scope,
          daemonId: 'file-message',
          versionId: 'version-1',
          body: {'fileId': 'file', 'displayName': 'photo.jpg'},
        ),
      );
      final tombstone =
          _file(
              scope,
              daemonId: 'file-message',
              versionId: 'version-2',
              body: const {},
            )
            ..['operation'] = 'edit'
            ..['deleted'] = true;

      expect(controller.mergeLive(tombstone), TimelineMergeOutcome.updated);
      expect(controller.items, isEmpty);
    });

    test(
      'applies explicit live edits and deletes without stale resurrection',
      () {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository);
        final original = _text(
          scope,
          daemonId: 'message',
          versionId: 'version-1',
          body: 'original',
        );
        final edited = _text(
          scope,
          daemonId: 'message',
          versionId: 'version-2',
          body: 'edited',
          operation: 'edit',
        );
        final deleted = _text(
          scope,
          daemonId: 'message',
          versionId: 'version-3',
          body: '',
          operation: 'edit',
        );

        expect(controller.mergeLive(original), TimelineMergeOutcome.inserted);
        expect(controller.mergeLive(edited), TimelineMergeOutcome.updated);
        expect((controller.items.single as TimelineTextItem).text, 'edited');
        expect(controller.mergeLive(deleted), TimelineMergeOutcome.updated);
        expect(controller.items, isEmpty);

        expect(controller.mergeLive(original), TimelineMergeOutcome.rejected);
        expect(controller.items, isEmpty);
      },
    );

    test('honors an already-folded history deletion', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);

      final load = controller.refresh();
      repository.loads.single.complete(
        items: [
          _text(
            scope,
            daemonId: 'deleted',
            versionId: 'latest-edition',
            body: '',
          ),
        ],
      );
      await load;

      expect(controller.items, isEmpty);
      expect(controller.rejectedItemCount, 0);
    });

    test(
      'fills the initial visible page through mixed raw daemon records',
      () async {
        final repository = _FakeTimelineRepository();
        final controller = _controller(scope, repository, pageSize: 2);

        final load = controller.refresh();
        repository.loads.single.complete(
          items: [
            _text(scope, daemonId: 'newest-message', body: 'newest'),
            {
              ..._text(scope, daemonId: 'call-record', body: 'ignored'),
              'mimeType': 'application/x-jami-call-history',
            },
          ],
          hasMore: true,
          nextCursor: 'before-call-records',
        );
        await _flush();

        expect(repository.loads, hasLength(2));
        expect(
          repository.loads.last.request.beforeCursor,
          'before-call-records',
        );
        repository.loads.last.complete(
          items: [_text(scope, daemonId: 'older-message', body: 'still here')],
        );
        await load;

        expect(controller.items.map((item) => item.daemonId), [
          'older-message',
          'newest-message',
        ]);
        expect(controller.rejectedItemCount, 1);
        expect(controller.lastError, isNull);
      },
    );

    test('keeps the last good timeline until a refresh succeeds', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);

      final first = controller.refresh();
      repository.loads.single.complete(
        items: [_text(scope, daemonId: 'last-good', body: 'last good')],
      );
      await first;

      final replacement = controller.refresh();
      expect(controller.isLoading, isTrue);
      expect(controller.items.single.daemonId, 'last-good');

      repository.loads.last.complete(
        items: [_text(scope, daemonId: 'replacement', body: 'replacement')],
      );
      await replacement;

      expect(controller.isLoading, isFalse);
      expect(controller.items.single.daemonId, 'replacement');

      final failed = controller.refresh();
      repository.loads.last.page.completeError(StateError('load failed'));
      await failed;

      expect(controller.lastError, isA<StateError>());
      expect(controller.items.single.daemonId, 'replacement');
    });

    test('rejects unknown version conflicts instead of timestamp guessing', () {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);
      controller.mergeLive(
        _text(
          scope,
          daemonId: 'message',
          versionId: 'version-a',
          body: 'a',
          timestampSeconds: 1000,
        ),
      );

      final result = controller.mergeLive(
        _text(
          scope,
          daemonId: 'message',
          versionId: 'version-b',
          body: 'b',
          timestampSeconds: 1000,
        ),
      );

      expect(result, TimelineMergeOutcome.rejected);
      expect((controller.items.single as TimelineTextItem).text, 'a');
    });

    test('ignores stale generations after a newer refresh', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);

      final stale = controller.refresh();
      final current = controller.refresh();
      expect(repository.loads, hasLength(2));

      repository.loads.first.complete(
        items: [_text(scope, daemonId: 'stale', body: 'stale')],
      );
      await stale;
      expect(controller.items, isEmpty);

      repository.loads.last.complete(
        items: [_text(scope, daemonId: 'current', body: 'current')],
      );
      await current;
      expect(controller.items.single.daemonId, 'current');
      expect(repository.canceledLoadIds, contains('load-1'));
    });

    test(
      'cancels a handle returned after its controller generation retired',
      () async {
        final firstStart = Completer<void>();
        final repository = _FakeTimelineRepository(
          beforeHandle: (request) =>
              request.requestId == 1 ? firstStart.future : Future.value(),
        );
        final controller = _controller(scope, repository);

        final stale = controller.refresh();
        final current = controller.refresh();
        await _flush();
        repository.loads.last.complete(
          items: [_text(scope, daemonId: 'current', body: 'current')],
        );
        await current;

        firstStart.complete();
        await stale;
        expect(repository.canceledLoadIds, contains('load-1'));
        expect(controller.items.single.daemonId, 'current');
      },
    );

    test(
      'refresh and dispose retire active loads without awaiting cancel failure',
      () async {
        final repository = _FakeTimelineRepository(
          cancelError: StateError('daemon cancel failed'),
        );
        final controller = _controller(scope, repository);

        final first = controller.refresh();
        await _flush();
        final replacement = controller.refresh();
        await _flush();
        expect(repository.loads, hasLength(2));
        expect(repository.canceledLoadIds, contains('load-1'));

        controller.dispose();
        await _flush();
        expect(repository.canceledLoadIds, contains('load-2'));

        repository.loads[0].complete();
        repository.loads[1].complete();
        await Future.wait([first, replacement]);
      },
    );

    test(
      'rejects a page with wrong daemon, request, scope, or cursor',
      () async {
        Future<void> expectProtocolError(
          TimelineHistoryPage Function(_PendingTimelineLoad load) page,
        ) async {
          final repository = _FakeTimelineRepository();
          final controller = _controller(scope, repository);
          final future = controller.refresh();
          final pending = repository.loads.single;
          pending.page.complete(page(pending));
          await future;
          expect(controller.lastError, isA<TimelineProtocolException>());
          expect(controller.items, isEmpty);
        }

        await expectProtocolError(
          (load) => load.pageValue(daemonLoadId: 'wrong'),
        );
        await expectProtocolError(
          (load) => load.pageValue(requestId: load.request.requestId + 1),
        );
        await expectProtocolError((load) => load.pageValue(scope: otherScope));
        await expectProtocolError(
          (load) => load.pageValue(requestedCursor: 'wrong'),
        );
      },
    );

    test(
      'requires advancing pagination cursors and unique daemon load ids',
      () async {
        final repeatedRepository = _FakeTimelineRepository(
          loadIdFor: (_) => 'same-load',
        );
        final repeated = _controller(scope, repeatedRepository);
        final first = repeated.refresh();
        repeatedRepository.loads.single.complete(
          hasMore: true,
          nextCursor: 'cursor',
        );
        await first;
        expect(repeated.lastError, isA<TimelineProtocolException>());
        expect(repeatedRepository.loads, hasLength(2));

        final stuckRepository = _FakeTimelineRepository();
        final stuck = _controller(scope, stuckRepository);
        final stuckFirst = stuck.refresh();
        stuckRepository.loads.single.complete(
          hasMore: true,
          nextCursor: 'cursor',
        );
        await _flush();
        stuckRepository.loads.last.complete(
          hasMore: true,
          nextCursor: 'cursor',
        );
        await stuckFirst;
        expect(stuck.lastError, isA<TimelineProtocolException>());
      },
    );

    test('isolates live and history items by full friend scope', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);

      expect(
        controller.mergeLive(
          _text(
            otherScope,
            daemonId: 'other-live',
            authorId: otherScope.peerId,
            body: 'wrong friend',
          ),
        ),
        TimelineMergeOutcome.rejected,
      );

      final load = controller.refresh();
      repository.loads.single.complete(
        items: [
          _text(
            otherScope,
            daemonId: 'other-history',
            authorId: otherScope.peerId,
            body: 'wrong friend',
          ),
          _text(scope, daemonId: 'right-history', body: 'right friend'),
        ],
      );
      await load;

      expect(controller.items.single.daemonId, 'right-history');
      expect(controller.rejectedItemCount, 1);
    });

    test('does not start overlapping pagination requests', () async {
      final repository = _FakeTimelineRepository();
      final controller = _controller(scope, repository);

      final load = controller.refresh();
      await controller.loadMore();
      expect(repository.loads, hasLength(1));
      repository.loads.single.complete();
      await load;
    });

    test(
      'surfaces repository errors only for the current generation',
      () async {
        final controller = _controller(scope, _ThrowingTimelineRepository());

        await controller.refresh();

        expect(controller.isLoading, isFalse);
        expect(controller.lastError, isA<StateError>());
      },
    );

    test('validates controller bounds and deeply freezes page payloads', () {
      final repository = _FakeTimelineRepository();
      expect(
        () => ConversationTimelineController(
          scope: scope,
          localAuthorId: '',
          repository: repository,
        ),
        throwsArgumentError,
      );
      expect(
        () => ConversationTimelineController(
          scope: scope,
          localAuthorId: localAuthorId,
          repository: repository,
          pageSize: 0,
        ),
        throwsArgumentError,
      );

      final body = <String, Object?>{
        'fileId': 'file',
        'displayName': 'before.txt',
      };
      final page = TimelineHistoryPage(
        scope: scope,
        generation: 1,
        requestId: 1,
        daemonLoadId: 'load',
        requestedCursor: null,
        nextCursor: null,
        hasMore: false,
        items: [_file(scope, daemonId: 'file-message', body: body)],
      );
      body['displayName'] = 'after.txt';

      expect((page.items.single['body'] as Map)['displayName'], 'before.txt');
      expect(
        () => (page.items.single['body'] as Map)['displayName'] = 'mutate',
        throwsUnsupportedError,
      );
    });
  });
}

ConversationTimelineController _controller(
  ConversationScope scope,
  ConversationTimelineRepository repository, {
  int pageSize = 50,
  Set<String>? allowedRemoteAuthorIds,
}) => ConversationTimelineController(
  scope: scope,
  localAuthorId: 'local-jami-id',
  repository: repository,
  pageSize: pageSize,
  allowedRemoteAuthorIds: allowedRemoteAuthorIds,
);

Map<String, Object?> _text(
  ConversationScope scope, {
  required String daemonId,
  String? versionId,
  String? authorId,
  required String body,
  Object timestampSeconds = 1,
  String? operation,
  Object? deliveryState,
  Object? readByMemberIds,
  String? topicId,
  bool? topicTagged,
  String? linearizedParent,
}) {
  final value = <String, Object?>{
    ...scope.toMap(),
    'daemonId': daemonId,
    'versionId': versionId ?? daemonId,
    'mimeType': TimelineWireContract.textMimeType,
    'authorId': authorId ?? scope.peerId,
    'timestampSeconds': timestampSeconds,
    'body': body,
  };
  if (operation != null) value['operation'] = operation;
  if (deliveryState != null) value['deliveryState'] = deliveryState;
  if (readByMemberIds != null) value['readByMemberIds'] = readByMemberIds;
  if (topicId != null) value['topicId'] = topicId;
  if (topicTagged != null) value['topicTagged'] = topicTagged;
  if (linearizedParent != null) {
    value['linearizedParent'] = linearizedParent;
  }
  return value;
}

Map<String, Object?> _file(
  ConversationScope scope, {
  required String daemonId,
  String? versionId,
  String? authorId,
  required Map<String, Object?> body,
  Object timestampSeconds = 1,
}) => {
  ...scope.toMap(),
  'daemonId': daemonId,
  'versionId': versionId ?? daemonId,
  'mimeType': TimelineWireContract.fileMimeType,
  'authorId': authorId ?? scope.peerId,
  'timestampSeconds': timestampSeconds,
  'body': body,
};

Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _FakeTimelineRepository implements ConversationTimelineRepository {
  _FakeTimelineRepository({
    this.loadIdFor,
    this.beforeHandle,
    this.cancelError,
  });

  final String Function(TimelineLoadRequest request)? loadIdFor;
  final Future<void> Function(TimelineLoadRequest request)? beforeHandle;
  final Object? cancelError;
  final List<_PendingTimelineLoad> loads = [];
  final List<String> canceledLoadIds = [];

  @override
  Future<TimelineLoadHandle> startLoad(TimelineLoadRequest request) async {
    final load = _PendingTimelineLoad(
      request,
      loadIdFor?.call(request) ?? 'load-${request.requestId}',
    );
    loads.add(load);
    await beforeHandle?.call(request);
    return TimelineLoadHandle(
      daemonLoadId: load.daemonLoadId,
      completion: load.page.future,
    );
  }

  @override
  Future<void> cancelLoad(String daemonLoadId) async {
    canceledLoadIds.add(daemonLoadId);
    final error = cancelError;
    if (error != null) throw error;
  }
}

final class _PendingTimelineLoad {
  _PendingTimelineLoad(this.request, this.daemonLoadId);

  final TimelineLoadRequest request;
  final String daemonLoadId;
  final Completer<TimelineHistoryPage> page = Completer();

  TimelineHistoryPage pageValue({
    ConversationScope? scope,
    int? generation,
    int? requestId,
    String? daemonLoadId,
    String? requestedCursor,
    String? nextCursor,
    bool hasMore = false,
    List<Map<String, Object?>> items = const [],
  }) => TimelineHistoryPage(
    scope: scope ?? request.scope,
    generation: generation ?? request.generation,
    requestId: requestId ?? request.requestId,
    daemonLoadId: daemonLoadId ?? this.daemonLoadId,
    requestedCursor: requestedCursor ?? request.beforeCursor,
    nextCursor: nextCursor,
    hasMore: hasMore,
    items: items,
  );

  void complete({
    String? nextCursor,
    bool hasMore = false,
    List<Map<String, Object?>> items = const [],
  }) {
    page.complete(
      pageValue(nextCursor: nextCursor, hasMore: hasMore, items: items),
    );
  }
}

final class _ThrowingTimelineRepository
    implements ConversationTimelineRepository {
  @override
  Future<void> cancelLoad(String daemonLoadId) async {}

  @override
  Future<TimelineLoadHandle> startLoad(TimelineLoadRequest request) {
    throw StateError('load failed');
  }
}
