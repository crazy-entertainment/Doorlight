import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_search.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final scope = ConversationScope(
    accountId: 'account',
    peerId: 'b' * 40,
    conversationId: 'c' * 40,
  );
  final query = HistorySearchQuery.parse('literal [query]')!;
  final client = JamiClient();
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'selected message carries exact target and rejects unowned replies',
    () async {
      final hit = HistorySearchHit.fromWire({
        ...scope.toMap(),
        'messageId': 'd' * 40,
        'authorId': scope.peerId,
        'channelId': 'main',
        'timestampSeconds': 1,
        'snippet': 'private',
        'contentKind': 'text',
      }, scope)!;
      final terminal = Completer<Object?>();
      MethodCall? issued;
      messenger.setMockMethodCallHandler(channel, (call) {
        issued = call;
        return terminal.future;
      });
      var completed = false;
      final pending = client
          .loadSearchMessage(hit, localAuthorId: 'a' * 40)
          .then((snapshot) {
            completed = true;
            return snapshot;
          });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(issued!.method, 'loadSearchMessage');
      expect(issued!.arguments, {
        'accountId': scope.accountId,
        'peerJamiId': scope.peerId,
        'conversationId': scope.conversationId,
        'messageId': hit.messageId,
      });
      terminal.complete({
        ...scope.toMap(),
        'messageId': hit.messageId,
        'items': <Object?>[],
      });
      expect((await pending).item, isNull);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          ...scope.toMap(),
          'accountId': 'other',
          'messageId': hit.messageId,
          'items': <Object?>[],
        },
      );
      await expectLater(
        client.loadSearchMessage(hit, localAuthorId: 'a' * 40),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Message unavailable',
          ),
        ),
      );
    },
  );

  test(
    'sends exact owner and literal input and waits for native completion',
    () async {
      final terminal = Completer<Object?>();
      MethodCall? issued;
      messenger.setMockMethodCallHandler(channel, (call) {
        issued = call;
        return terminal.future;
      });
      var completed = false;
      final pending = client.searchHistory(scope, query, 20).then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(issued!.arguments, {
        'accountId': scope.accountId,
        'peerJamiId': scope.peerId,
        'conversationId': scope.conversationId,
        'query': query.literal,
        'limit': 20,
      });
      terminal.complete({'hits': <Object?>[], 'truncated': false});
      expect((await pending).hits, isEmpty);
    },
  );

  test(
    'rejects foreign results and null failures without reflecting content',
    () async {
      for (final response in [
        null,
        {
          'truncated': false,
          'hits': [
            {
              ...scope.toMap(),
              'accountId': 'foreign',
              'messageId': 'd' * 40,
              'authorId': scope.peerId,
              'channelId': 'main',
              'timestampSeconds': 1,
              'snippet': 'private content',
              'contentKind': 'text',
            },
          ],
        },
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => response);
        await expectLater(
          client.searchHistory(scope, query, 20),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Search unavailable',
            ),
          ),
        );
      }
    },
  );

  test(
    'invalid limit never invokes native and retirement carries exact account',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await expectLater(
        client.searchHistory(scope, query, 201),
        throwsFormatException,
      );
      expect(calls, isEmpty);
      await client.retireHistorySearch(scope.accountId);
      expect(calls.single.method, 'retireHistorySearch');
      expect(calls.single.arguments, {'accountId': scope.accountId});
    },
  );
}
