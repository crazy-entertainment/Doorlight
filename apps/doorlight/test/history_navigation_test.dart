import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_search.dart';
import 'package:sybl/state/search_message_selection.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/theme.dart';
import 'app_state_test.dart' show FakeJami;

final _scope = ConversationScope(
  accountId: 'acc1',
  peerId: 'b' * 40,
  conversationId: 'c' * 40,
);
String _id(int index) => (index + 1).toRadixString(16).padLeft(40, '0');
const _target = 7;
Map<String, Object?> _message(int index) => {
  ..._scope.toMap(),
  'daemonId': _id(index),
  'versionId': index == _target ? 'e' * 40 : _id(index),
  'mimeType': 'text/plain',
  'authorId': _scope.peerId,
  'timestampSeconds': index + 1,
  'topicId': 'main',
  'body': index == _target
      ? 'Authoritative edited message'
      : 'Message $index ${'variable-height content ' * (index % 8)}',
};
HistorySearchHit _hit() => HistorySearchHit.fromWire({
  ..._scope.toMap(),
  'messageId': _id(_target),
  'authorId': _scope.peerId,
  'channelId': 'main',
  'contentKind': 'text',
  'timestampSeconds': _target + 1,
  'snippet': 'Obsolete untrusted search snippet',
}, _scope)!;

class _PagedJami extends FakeJami {
  int count = 600;
  int snapshotCalls = 0;
  final cursors = <String>[];
  final retiredSearches = <String>[];
  bool deleteOnRevalidation = false;
  Completer<void>? finalSnapshotGate;
  @override
  Future<SearchMessageSnapshot> loadSearchMessage(
    HistorySearchHit hit, {
    required String localAuthorId,
    Set<String>? allowedRemoteAuthorIds,
  }) async {
    snapshotCalls++;
    if (snapshotCalls == 2) await finalSnapshotGate?.future;
    return SearchMessageSnapshot.fromWire(
      {
        ...hit.scope.toMap(),
        'messageId': hit.messageId,
        'items': snapshotCalls >= 2 && deleteOnRevalidation
            ? <Object?>[]
            : [_message(_target)],
      },
      hit,
      localAuthorId: localAuthorId,
      allowedRemoteAuthorIds: allowedRemoteAuthorIds,
    )!;
  }

  @override
  Future<void> retireHistorySearch(String accountId) async {
    retiredSearches.add(accountId);
  }

  @override
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
  }) async {
    final id = nextChatLoadId++;
    cursors.add(fromMessage);
    final start = fromMessage.isEmpty
        ? count - 1
        : int.parse(fromMessage, radix: 16) - 1;
    final end = (start - pageSize + 1).clamp(0, start);
    push('chatSnapshot', {
      'accountId': _scope.accountId,
      'peerJamiId': peerJamiId,
      'conversationId': conversationId,
      'loadId': id,
      'requestedCursor': fromMessage,
      'nextCursor': end > 0 ? _id(end) : '',
      'hasMore': end > 0,
      'items': [for (var index = start; index >= end; index--) _message(index)],
    });
    return id;
  }
}

Future<AppState> _boot(_PagedJami native) async {
  SharedPreferences.setMockInitialValues({
    'displayName': 'Me',
    'accountId': 'acc1',
  });
  native.daemonFriends[_scope.peerId] = JamiFriend(
    peerJamiId: _scope.peerId,
    confirmed: true,
    conversationId: _scope.conversationId,
  );
  final state = AppState(native, await SharedPreferences.getInstance());
  await state.init();
  state.didChangeAppLifecycleState(AppLifecycleState.resumed);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'old edited result loads real contiguous pages without read or activity evidence',
    () async {
      final native = _PagedJami();
      final state = await _boot(native);
      addTearDown(state.dispose);
      final activity = state.friendActivity(_scope.peerId).lastActivityAt;
      final sounds = <Object>[];
      final subscription = state.soundEvents.listen(sounds.add);
      addTearDown(subscription.cancel);
      expect(
        await state.openHistorySearchConversation(
          _hit(),
          action: state.captureConversationAction(),
          onConversationOpened: () =>
              state.setConversationVisible(_scope.peerId),
        ),
        isTrue,
      );
      expect(native.cursors.length, greaterThan(12));
      expect(state.conversationItems, hasLength(native.count));
      expect(state.historyTimelineMessageId, _id(_target));
      expect(native.snapshotCalls, 2);
      expect(
        state.conversationItems.map((item) => item.daemonId).toSet(),
        hasLength(native.count),
      );
      expect(native.displayedMessages, isEmpty);
      expect(native.dismissedMessageNotifications, isEmpty);
      expect(state.friendActivity(_scope.peerId).lastActivityAt, activity);
      expect(sounds, isEmpty);
      state.returnToLatestHistory();
      await pumpEventQueue();
      expect(native.displayedMessages.single.messageId, _id(native.count - 1));
    },
  );

  test(
    'deletion at final folded revalidation never focuses stale content',
    () async {
      final native = _PagedJami()..deleteOnRevalidation = true;
      final state = await _boot(native);
      addTearDown(state.dispose);
      expect(
        await state.openHistorySearchConversation(
          _hit(),
          action: state.captureConversationAction(),
        ),
        isFalse,
      );
      expect(state.historyTimelineMessageId, isNull);
      expect(state.historyTimelineUnavailable, isTrue);
      expect(native.displayedMessages, isEmpty);
    },
  );

  for (final scenario in <String, void Function(AppState)>{
    'lock': (state) => state.setProtectedSurfaceLocked(true),
    'background': (state) =>
        state.didChangeAppLifecycleState(AppLifecycleState.paused),
    'account replacement': (state) => state.accountId = 'replacement',
    'cancel': (state) => state.returnToLatestHistory(),
  }.entries) {
    test(
      '${scenario.key} retires navigation before a late folded callback',
      () async {
        final native = _PagedJami()..finalSnapshotGate = Completer<void>();
        final state = await _boot(native);
        addTearDown(state.dispose);
        final opening = state.openHistorySearchConversation(
          _hit(),
          action: state.captureConversationAction(),
        );
        await pumpEventQueue(times: 200);
        expect(native.snapshotCalls, 2);
        scenario.value(state);
        native.finalSnapshotGate!.complete();
        expect(await opening, isFalse);
        expect(state.historyTimelineMessageId, isNull);
        expect(native.displayedMessages, isEmpty);
      },
    );
  }

  testWidgets(
    'variable-height ordinary timeline anchors and highlights exact old commit',
    (tester) async {
      late AppState state;
      final native = _PagedJami();
      await tester.runAsync(() async {
        state = await _boot(native);
        expect(
          await state.openHistorySearchConversation(
            _hit(),
            action: state.captureConversationAction(),
          ),
          isTrue,
        );
      });
      addTearDown(state.dispose);
      await tester.binding.setSurfaceSize(const Size(390, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) => ConversationTimelineView(
                state: state,
                live: const [],
                timeline: state.conversationItems,
                legacyFiles: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      final target = find.byKey(
        ValueKey<String>('history-message-highlight:${_id(_target)}'),
      );
      expect(target, findsOneWidget);
      final bounds = tester.getRect(target);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      expect(bounds.overlaps(viewport), isTrue);
      expect(bounds.center.dy, inInclusiveRange(viewport.top, viewport.bottom));
      expect(find.text('Obsolete untrusted search snippet'), findsNothing);
      expect(native.displayedMessages, isEmpty);
      await tester.tap(find.byKey(const ValueKey('history-return-latest')));
      await tester.pump();
      expect(find.byType(CustomScrollView), findsNothing);
      expect(find.byKey(const ValueKey('file-timeline')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
