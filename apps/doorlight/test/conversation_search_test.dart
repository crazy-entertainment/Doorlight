import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_search.dart';

final scope = ConversationScope(
  accountId: 'account',
  peerId: 'b' * 40,
  conversationId: 'c' * 40,
);
Map<String, Object?> hitWire(int id, {ConversationScope? owner}) => {
  ...(owner ?? scope).toMap(),
  'messageId': id.toRadixString(16).padLeft(40, '0'),
  'authorId': 'b' * 40,
  'channelId': 'main',
  'contentKind': 'text',
  'timestampSeconds': 1700000000 + id,
  'snippet': 'A private matching message',
};
HistorySearchBatch batch(
  int count, {
  ConversationScope? owner,
  bool truncated = false,
}) => HistorySearchBatch.fromWire(
  {
    'truncated': truncated,
    'hits': List.generate(count, (i) => hitWire(i + 1, owner: owner)),
  },
  owner ?? scope,
  HistorySearchWire.maximumResults,
)!;

void main() {
  test(
    'channel validation keeps group and direct topic boundaries separate',
    () {
      final group = ConversationScope(
        accountId: scope.accountId,
        peerId: 'group:room',
        conversationId: scope.conversationId,
      );
      for (final channel in ['general', 'a', '0-room', 'a' * 32]) {
        expect(HistorySearchWire.channel(group, channel), isTrue);
      }
      for (final channel in [
        null,
        1,
        '',
        '-room',
        'Room',
        'a' * 33,
        'room\n',
      ]) {
        expect(HistorySearchWire.channel(group, channel), isFalse);
      }
      for (final channel in ['main', 'a' * 32, '0123456789abcdef' * 2]) {
        expect(HistorySearchWire.channel(scope, channel), isTrue);
      }
      for (final channel in [
        null,
        1,
        '',
        'general',
        'a' * 31,
        'a' * 33,
        'g' * 32,
        '${'a' * 32}\n',
      ]) {
        expect(HistorySearchWire.channel(scope, channel), isFalse);
      }
    },
  );

  test('ordinary query syntax stays literal and bounded', () {
    const input = r'a.b+[c](d)? {e} ^f$ | g\h';
    final query = HistorySearchQuery.parse(input)!;
    expect(RegExp(query.pattern).hasMatch(input), isTrue);
    expect(RegExp(query.pattern).hasMatch('axbccc'), isFalse);
    expect(HistorySearchQuery.parse('  café 👍  ')!.literal, 'café 👍');
    for (final invalid in ['', '   ', 'x' * 257, 'a\nb', '\u0000', '\uD800']) {
      expect(HistorySearchQuery.parse(invalid), isNull);
    }
    expect(query.toString(), isNot(contains(input)));
  });

  test('hit parsing binds every owner field and rejects malformed content', () {
    final wire = hitWire(1);
    expect(HistorySearchHit.fromWire(wire, scope), isNotNull);
    for (final invalid in [
      {...wire, 'accountId': 'other'},
      {...wire, 'conversationId': 'e' * 40},
      {...wire, 'messageId': 'HEAD'},
      {...wire, 'authorId': 'claimed name'},
      {...wire, 'snippet': 'x' * 513},
      {...wire, 'snippet': '\uD800'},
      {...wire, 'timestampSeconds': -1},
      {...wire, 'timestampSeconds': 1.5},
      {...wire, 'channelId': 'unknown'},
      {...wire, 'contentKind': 'reaction'},
    ]) {
      expect(HistorySearchHit.fromWire(invalid, scope), isNull);
    }
    expect(
      HistorySearchBatch.fromWire(
        {
          'truncated': false,
          'hits': [wire, wire],
        },
        scope,
        2,
      ),
      isNull,
    );
    expect(
      HistorySearchBatch.fromWire(
        {
          'truncated': false,
          'hits': [wire],
        },
        scope,
        0,
      ),
      isNull,
    );
    expect(
      HistorySearchHit.fromWire(wire, scope).toString(),
      isNot(contains('private matching')),
    );
  });

  testWidgets('debounce and replacement keep one native request active', (
    tester,
  ) async {
    final first = Completer<HistorySearchBatch>();
    final issued = <String>[];
    final currentOwner = (accountId: 'account', lifetime: Object());
    final search = ConversationSearch(
      owner: () => currentOwner,
      scopes: () => [scope],
      accepts: (_) => true,
      search: (_, query, _) {
        issued.add(query.literal);
        return issued.length == 1 ? first.future : Future.value(batch(1));
      },
    );
    addTearDown(search.dispose);
    search.setQuery('a');
    await tester.pump(const Duration(milliseconds: 150));
    search.setQuery('ab');
    await tester.pump(const Duration(milliseconds: 300));
    expect(issued, ['ab']);
    search.setQuery('abc');
    await tester.pump(const Duration(milliseconds: 300));
    search.setQuery('abcd');
    await tester.pump(const Duration(milliseconds: 300));
    expect(issued, ['ab']);
    first.complete(batch(2));
    await tester.pump();
    expect(issued, ['ab', 'abcd']);
    expect(search.results, hasLength(1));
    expect(search.busy, isFalse);
  });

  testWidgets(
    'retirement drops private results and waits for the actual worker',
    (tester) async {
      HistorySearchOwner? currentOwner = (
        accountId: 'account',
        lifetime: Object(),
      );
      final first = Completer<HistorySearchBatch>();
      var issued = 0;
      final search = ConversationSearch(
        owner: () => currentOwner,
        scopes: () => [scope],
        accepts: (_) => true,
        search: (_, _, _) =>
            ++issued == 1 ? first.future : Future.value(batch(1)),
      );
      addTearDown(search.dispose);
      search.setQuery('private');
      await tester.pump(const Duration(milliseconds: 300));
      currentOwner = null;
      search.retire();
      expect(search.results, isEmpty);
      expect(search.busy, isFalse);
      currentOwner = (accountId: 'account', lifetime: Object());
      search.setQuery('new visit');
      await tester.pump(const Duration(milliseconds: 300));
      expect(issued, 1);
      first.complete(batch(10));
      await tester.pump();
      expect(issued, 2);
      expect(search.results, hasLength(1));
      currentOwner = null;
      expect(
        search.results,
        isEmpty,
        reason: 'the getter also fails closed before a retirement notification',
      );
    },
  );

  testWidgets('global results have one aggregate bound and local pages', (
    tester,
  ) async {
    final prepared = batch(HistorySearchWire.maximumResults, truncated: true);
    final other = ConversationScope(
      accountId: 'account',
      peerId: 'e' * 40,
      conversationId: 'f' * 40,
    );
    final foreign = ConversationScope(
      accountId: 'foreign',
      peerId: 'e' * 40,
      conversationId: 'f' * 40,
    );
    final currentOwner = (accountId: 'account', lifetime: Object());
    final issued = <ConversationScope>[];
    final limits = <int>[];
    final search = ConversationSearch(
      owner: () => currentOwner,
      scopes: () => [foreign, scope, other],
      accepts: (_) => true,
      search: (owner, _, limit) async {
        issued.add(owner);
        limits.add(limit);
        return prepared;
      },
    );
    addTearDown(search.dispose);
    search.setQuery('message');
    await tester.pump(const Duration(milliseconds: 300));
    expect(issued, [scope]);
    expect(limits, [HistorySearchWire.maximumResults]);
    expect(search.problem, isNull);
    expect(search.busy, isFalse);
    expect(search.resultCount, 200);
    expect(search.results, hasLength(20));
    expect(search.limited, isTrue);
    search.showMore();
    expect(search.results, hasLength(40));
    expect(issued, [scope]);
  });

  testWidgets('pages count accessible results after channel access changes', (
    tester,
  ) async {
    var hiddenThrough = 0;
    final currentOwner = (accountId: 'account', lifetime: Object());
    final search = ConversationSearch(
      owner: () => currentOwner,
      scopes: () => [scope],
      accepts: (hit) => int.parse(hit.messageId, radix: 16) > hiddenThrough,
      search: (_, _, _) async => batch(60),
    );
    addTearDown(search.dispose);
    search.setQuery('message');
    await tester.pump(const Duration(milliseconds: 300));
    // Results are newest first. Losing the oldest 45 leaves 15 accessible
    // results, so there must be no empty extra page.
    hiddenThrough = 45;
    expect(search.resultCount, 15);
    expect(search.results, hasLength(15));
    expect(search.hasMore, isFalse);
    search.showMore();
    expect(search.results, hasLength(15));
  });

  testWidgets(
    'inaccessible first-page hits do not hide later accessible hits',
    (tester) async {
      var visibleThrough = 60;
      final currentOwner = (accountId: 'account', lifetime: Object());
      final search = ConversationSearch(
        owner: () => currentOwner,
        scopes: () => [scope],
        accepts: (hit) => int.parse(hit.messageId, radix: 16) <= visibleThrough,
        search: (_, _, _) async => batch(60),
      );
      addTearDown(search.dispose);
      search.setQuery('message');
      await tester.pump(const Duration(milliseconds: 300));
      visibleThrough = 30;
      expect(search.results, hasLength(20));
      expect(int.parse(search.results.first.messageId, radix: 16), 30);
      expect(search.hasMore, isTrue);
      search.showMore();
      expect(search.results, hasLength(30));
      expect(search.hasMore, isFalse);
    },
  );

  testWidgets(
    'removed membership and unknown channels are filtered again at display time',
    (tester) async {
      var admitted = true;
      final currentOwner = (accountId: 'account', lifetime: Object());
      final search = ConversationSearch(
        owner: () => currentOwner,
        scopes: () => [scope],
        accepts: (_) => admitted,
        search: (_, _, _) async => batch(1),
      );
      addTearDown(search.dispose);
      search.setQuery('message');
      await tester.pump(const Duration(milliseconds: 300));
      expect(search.results, hasLength(1));
      admitted = false;
      expect(search.results, isEmpty);
      expect(search.resultCount, 0);
    },
  );
}
