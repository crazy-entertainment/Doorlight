import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_search.dart';
import 'package:sybl/state/search_message_selection.dart';
import 'app_state_test.dart' show FakeJami;

class SearchJami extends FakeJami {
  final pending = Completer<HistorySearchBatch>();
  final scopes = <ConversationScope>[];
  final retired = <String>[];
  final messagePending = Completer<SearchMessageSnapshot>();
  @override
  Future<SearchMessageSnapshot> loadSearchMessage(
    HistorySearchHit hit, {
    required String localAuthorId,
    Set<String>? allowedRemoteAuthorIds,
  }) => messagePending.future;
  @override
  Future<HistorySearchBatch> searchHistory(
    ConversationScope scope,
    HistorySearchQuery query,
    int limit,
  ) {
    scopes.add(scope);
    return pending.future;
  }

  @override
  Future<void> retireHistorySearch(String accountId) async {
    retired.add(accountId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'removing and restoring the same friend cannot revive a selected result',
    () async {
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
      });
      final native = SearchJami();
      final scope = ConversationScope(
        accountId: 'acc1',
        peerId: 'b' * 40,
        conversationId: 'c' * 40,
      );
      final friend = JamiFriend(
        peerJamiId: scope.peerId,
        confirmed: true,
        conversationId: scope.conversationId,
      );
      native.daemonFriends[scope.peerId] = friend;
      final state = AppState(native, await SharedPreferences.getInstance());
      await state.init();
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      addTearDown(state.dispose);
      final hit = HistorySearchHit.fromWire({
        ...scope.toMap(),
        'messageId': 'd' * 40,
        'authorId': scope.peerId,
        'channelId': 'main',
        'contentKind': 'text',
        'timestampSeconds': 1,
        'snippet': 'private',
      }, scope)!;
      final selection = state.searchMessageSelection;
      final pending = selection.select(hit);
      expect(selection.busy, isTrue);
      native.friendsRevision++;
      native.push('friendsChanged', {'accountId': scope.accountId});
      await pumpEventQueue();
      expect(selection.hasSession, isTrue);
      expect(native.retired, isEmpty);
      native.daemonFriends.clear();
      native.friendsRevision++;
      native.push('friendsChanged', {'accountId': scope.accountId});
      await pumpEventQueue();
      expect(selection.hasSession, isFalse);
      expect(native.retired, [scope.accountId]);
      native.daemonFriends[scope.peerId] = friend;
      native.friendsRevision++;
      native.push('friendsChanged', {'accountId': scope.accountId});
      await pumpEventQueue();
      expect(state.friends.containsKey(scope.peerId), isTrue);
      native.messagePending.complete(
        SearchMessageSnapshot.fromWire(
          {...scope.toMap(), 'messageId': hit.messageId, 'items': <Object?>[]},
          hit,
          localAuthorId: state.jamiId,
        )!,
      );
      expect(await pending, isFalse);
      expect(selection.hit, isNull);
      expect(native.displayedMessages, isEmpty);
    },
  );
  for (final scenario in <String, void Function(AppState)>{
    'lock': (state) => state.setProtectedSurfaceLocked(true),
    'background': (state) =>
        state.didChangeAppLifecycleState(AppLifecycleState.paused),
    'account replacement': (state) => state.accountId = 'replacement',
  }.entries) {
    test('AppState retires selected message on ${scenario.key}', () async {
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
      });
      final native = SearchJami();
      final scope = ConversationScope(
        accountId: 'acc1',
        peerId: 'b' * 40,
        conversationId: 'c' * 40,
      );
      native.daemonFriends[scope.peerId] = JamiFriend(
        peerJamiId: scope.peerId,
        confirmed: true,
        conversationId: scope.conversationId,
      );
      final state = AppState(native, await SharedPreferences.getInstance());
      await state.init();
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      addTearDown(state.dispose);
      final hit = HistorySearchHit.fromWire({
        ...scope.toMap(),
        'messageId': 'd' * 40,
        'authorId': scope.peerId,
        'channelId': 'main',
        'contentKind': 'text',
        'timestampSeconds': 1,
        'snippet': 'private',
      }, scope)!;
      final selection = state.searchMessageSelection;
      final pending = selection.select(hit);
      expect(selection.busy, isTrue);
      scenario.value(state);
      expect(native.retired, [scope.accountId]);
      expect(selection.hasSession, isFalse);
      native.messagePending.complete(
        SearchMessageSnapshot.fromWire(
          {...scope.toMap(), 'messageId': hit.messageId, 'items': <Object?>[]},
          hit,
          localAuthorId: state.jamiId,
        )!,
      );
      expect(await pending, isFalse);
      expect(selection.item, isNull);
      expect(native.displayedMessages, isEmpty);
    });
  }
  for (final scenario in <String, void Function(AppState)>{
    'lock': (state) => state.setProtectedSurfaceLocked(true),
    'clear query': (state) => state.historySearch.setQuery(''),
    'background': (state) =>
        state.didChangeAppLifecycleState(AppLifecycleState.paused),
    'account replacement': (state) => state.accountId = 'replacement',
  }.entries) {
    test(
      'AppState retires search on ${scenario.key} and rejects late results',
      () async {
        SharedPreferences.setMockInitialValues({
          'displayName': 'Me',
          'accountId': 'acc1',
        });
        final native = SearchJami();
        final peer = 'b' * 40;
        native.daemonFriends[peer] = JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: 'c' * 40,
        );
        final state = AppState(native, await SharedPreferences.getInstance());
        await state.init();
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        addTearDown(state.dispose);
        final search = state.historySearch;
        search.setQuery('private');
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(native.scopes, hasLength(1));
        final scope = native.scopes.single;
        final activity = state.friendActivity(peer).lastActivityAt;
        scenario.value(state);
        expect(native.retired, [scope.accountId]);
        expect(search.hasSession, isFalse);
        native.pending.complete(
          HistorySearchBatch.fromWire(
            {
              'truncated': false,
              'hits': [
                {
                  ...scope.toMap(),
                  'messageId': 'd' * 40,
                  'authorId': peer,
                  'channelId': 'main',
                  'contentKind': 'text',
                  'timestampSeconds': 1,
                  'snippet': 'private',
                },
              ],
            },
            scope,
            20,
          )!,
        );
        await pumpEventQueue();
        state.setProtectedSurfaceLocked(false);
        expect(search.results, isEmpty);
        expect(state.friendActivity(peer).lastActivityAt, activity);
        expect(native.displayedMessages, isEmpty);
      },
    );
  }
}
