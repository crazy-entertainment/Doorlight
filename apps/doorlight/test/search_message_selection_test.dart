import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_search.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/search_message_selection.dart';

void main() {
  final scope = ConversationScope(
    accountId: 'account',
    peerId: 'b' * 40,
    conversationId: 'c' * 40,
  );
  final hit = HistorySearchHit.fromWire({
    ...scope.toMap(),
    'messageId': 'd' * 40,
    'authorId': scope.peerId,
    'channelId': 'main',
    'timestampSeconds': 100,
    'snippet': 'Old search snippet',
    'contentKind': 'text',
  }, scope)!;
  final local = 'a' * 40;
  Map<String, Object?> message({String body = 'Current edited message'}) => {
    ...scope.toMap(),
    'daemonId': hit.messageId,
    'versionId': 'e' * 40,
    'authorId': scope.peerId,
    'timestampSeconds': 100,
    'mimeType': 'text/plain',
    'body': body,
  };
  Map<String, Object?> response(List<Object?> items) => {
    ...scope.toMap(),
    'messageId': hit.messageId,
    'items': items,
  };
  SearchMessageSnapshot? parse(Object? value) =>
      SearchMessageSnapshot.fromWire(value, hit, localAuthorId: local);

  test('fresh folded content replaces the snippet; deletion stays absent', () {
    final current = parse(response([message()]))!;
    expect((current.item as TimelineTextItem).text, 'Current edited message');
    expect(current.item!.versionId, 'e' * 40);
    expect(parse(response([message(body: '')]))!.item, isNull);
    expect(parse(response([]))!.item, isNull);
    expect(current.toString(), isNot(contains('Current edited message')));
  });

  test(
    'rejects another owner, target, author, topic, version and live edit',
    () {
      for (final change in <Map<String, Object?>>[
        {'accountId': 'other'},
        {'daemonId': 'f' * 40},
        {'authorId': 'f' * 40},
        {'topicId': 'f' * 32, 'topicTagged': true},
        {'timestampSeconds': 101},
        {'versionId': 'HEAD'},
        {'operation': 'edit'},
        {'body': 'x' * (TimelineWireContract.maxTextCodeUnits + 1)},
      ]) {
        expect(
          parse(
            response([
              {...message(), ...change},
            ]),
          ),
          isNull,
        );
      }
      expect(
        parse({
          ...response([message()]),
          'kind': 'group',
        }),
        isNull,
      );
      expect(
        parse({
          ...response([message()]),
          'messageId': 'f' * 40,
        }),
        isNull,
      );
      expect(parse(response([message(), message()])), isNull);
      expect(parse(null), isNull);
    },
  );

  test(
    'retirement hides content but holds the native lease until completion',
    () async {
      HistorySearchOwner? owner = (accountId: scope.accountId, lifetime: 1);
      var accessible = true;
      final pending = <Completer<SearchMessageSnapshot>>[];
      final retired = <HistorySearchOwner>[];
      final selection = SearchMessageSelection(
        owner: () => owner,
        accepts: (_) => accessible,
        load: (_) {
          final request = Completer<SearchMessageSnapshot>();
          pending.add(request);
          return request.future;
        },
        retireWorker: retired.add,
      );
      addTearDown(selection.dispose);
      final first = selection.select(hit);
      expect(selection.busy, isTrue);
      expect(await selection.select(hit), isFalse);
      selection.retire();
      selection.retire();
      expect(retired, hasLength(1));
      expect(selection.hit, isNull);
      expect(selection.canSelect, isFalse);
      pending.single.complete(parse(response([message()]))!);
      expect(await first, isFalse);
      expect(selection.item, isNull);
      expect(selection.canSelect, isTrue);

      final second = selection.select(hit);
      owner = (accountId: scope.accountId, lifetime: 2);
      pending.last.complete(parse(response([message()]))!);
      expect(await second, isFalse);
      expect(selection.item, isNull);

      final third = selection.select(hit);
      accessible = false;
      pending.last.complete(parse(response([message()]))!);
      expect(await third, isFalse);
      expect(selection.item, isNull);
    },
  );

  test(
    'absence and failure stay unavailable without reflecting native errors',
    () async {
      var unavailable = false;
      final selection = SearchMessageSelection(
        owner: () => (accountId: scope.accountId, lifetime: 1),
        accepts: (_) => true,
        load: (_) async {
          if (unavailable) throw StateError('Private native payload');
          return parse(response([]))!;
        },
      );
      addTearDown(selection.dispose);
      expect(await selection.select(hit), isFalse);
      expect(selection.problem, SearchMessageProblem.unavailable);
      unavailable = true;
      expect(await selection.select(hit), isFalse);
      expect(selection.problem, SearchMessageProblem.unavailable);
      expect(selection.item, isNull);
    },
  );

  group('group scope selects by the item effective room', () {
    final groupScope = ConversationScope(
      accountId: 'account',
      peerId: 'b' * 40,
      conversationId: 'c' * 40,
      kind: ConversationKind.group,
    );
    HistorySearchHit groupHit(String channel, {bool file = false}) =>
        HistorySearchHit.fromWire({
          ...groupScope.toMap(),
          'messageId': 'd' * 40,
          'authorId': groupScope.peerId,
          'channelId': channel,
          'timestampSeconds': 100,
          'snippet': 'Old search snippet',
          'contentKind': file ? 'file' : 'text',
        }, groupScope)!;
    Map<String, Object?> groupText(String body, {Object? room}) => {
      ...groupScope.toMap(),
      'daemonId': 'd' * 40,
      'versionId': 'e' * 40,
      'authorId': groupScope.peerId,
      'timestampSeconds': 100,
      'mimeType': 'text/plain',
      'body': body,
      'roomId': ?room,
    };
    Map<String, Object?> groupFile(String name) => {
      ...groupScope.toMap(),
      'daemonId': 'd' * 40,
      'versionId': 'e' * 40,
      'authorId': groupScope.peerId,
      'timestampSeconds': 100,
      'mimeType': 'application/data-transfer+json',
      'body': {'fileId': 'f1', 'displayName': name, 'totalBytes': 4},
    };
    SearchMessageSnapshot? parseGroup(
      Map<String, Object?> item,
      String channel, {
      bool file = false,
    }) => SearchMessageSnapshot.fromWire(
      {
        ...groupScope.toMap(),
        'messageId': 'd' * 40,
        'items': [item],
      },
      groupHit(channel, file: file),
      localAuthorId: local,
    );

    test('accepts room-less text, files, legacy prefix and explicit room', () {
      expect(parseGroup(groupText('hello'), 'general'), isNotNull);
      expect(
        parseGroup(groupFile('notes.txt'), 'general', file: true),
        isNotNull,
      );
      expect(parseGroup(groupText('[#dev] hello'), 'dev'), isNotNull);
      expect(parseGroup(groupText('hello', room: 'dev'), 'dev'), isNotNull);
    });

    test('rejects disagreement, file-name prefixes and bad room fields', () {
      for (final channel in ['dev', 'ops', 'general']) {
        expect(
          parseGroup(groupText('[#ops] hello', room: 'dev'), channel),
          isNull,
        );
      }
      expect(
        parseGroup(groupFile('[#dev] notes.txt'), 'dev', file: true),
        isNull,
      );
      expect(
        parseGroup(groupFile('[#dev] notes.txt'), 'general', file: true),
        isNotNull,
      );
      expect(parseGroup(groupText('hello'), 'dev'), isNull);
      for (final room in <Object>[7, true, 'Dev', '', 'a' * 33]) {
        expect(parseGroup(groupText('hello', room: room), 'general'), isNull);
        expect(parseGroup(groupText('hello', room: room), 'dev'), isNull);
      }
    });
  });
}
