import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/screens/home.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_search.dart';
import 'package:sybl/state/search_message_selection.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/history_search_dialog.dart';
import 'package:sybl/ui/group_stage.dart';
import 'app_state_test.dart' show FakeJami;

final _scope = ConversationScope(
  accountId: 'acc1',
  peerId: 'b' * 40,
  conversationId: 'c' * 40,
);
final _groupScope = ConversationScope(
  accountId: 'acc1',
  peerId: 'group:${'f' * 40}',
  conversationId: 'f' * 40,
);
HistorySearchHit _hit(ConversationScope scope, {int number = 13}) =>
    HistorySearchHit.fromWire({
      ...scope.toMap(),
      'messageId': number.toRadixString(16).padLeft(40, '0'),
      'authorId': 'b' * 40,
      'channelId': scope.isGroup ? 'games' : 'main',
      'timestampSeconds': 100,
      'snippet': 'Old snippet $number',
      'contentKind': 'text',
    }, scope)!;

class _SearchNative extends FakeJami {
  final searched = <ConversationScope>[];
  final loaded = <HistorySearchHit>[];
  final retired = <String>[];
  String body = 'Current edited message';
  bool deleted = false;
  bool failSearch = false;
  int count = 1;
  Completer<SearchMessageSnapshot>? pendingMessage;
  Completer<HistorySearchBatch>? pendingSearch;
  @override
  Future<HistorySearchBatch> searchHistory(
    ConversationScope scope,
    HistorySearchQuery query,
    int limit,
  ) async {
    searched.add(scope);
    if (failSearch) throw StateError('PRIVATE transport detail');
    if (pendingSearch != null) return pendingSearch!.future;
    return HistorySearchBatch.fromWire(
      {
        'truncated': count > limit,
        'hits': [
          for (var i = 0; i < count && i < limit; i++)
            {
              ...scope.toMap(),
              'messageId': (i + 13).toRadixString(16).padLeft(40, '0'),
              'authorId': 'b' * 40,
              'channelId': scope.isGroup ? 'games' : 'main',
              'timestampSeconds': 100,
              'snippet': 'Old snippet ${i + 13}',
              'contentKind': 'text',
            },
        ],
      },
      scope,
      limit,
    )!;
  }

  SearchMessageSnapshot snapshot(HistorySearchHit hit) =>
      SearchMessageSnapshot.fromWire(
        {
          ...hit.scope.toMap(),
          'messageId': hit.messageId,
          'items': deleted
              ? <Object?>[]
              : [
                  {
                    ...hit.scope.toMap(),
                    'daemonId': hit.messageId,
                    'versionId': 'e' * 40,
                    'authorId': hit.authorId,
                    'timestampSeconds': 100,
                    'mimeType': 'text/plain',
                    'body': body,
                    if (hit.scope.isGroup) 'roomId': 'games',
                  },
                ],
        },
        hit,
        localAuthorId: 'a' * 40,
        allowedRemoteAuthorIds: {'b' * 40},
      )!;
  @override
  Future<SearchMessageSnapshot> loadSearchMessage(
    HistorySearchHit hit, {
    required String localAuthorId,
    Set<String>? allowedRemoteAuthorIds,
  }) async {
    loaded.add(hit);
    return pendingMessage?.future ?? snapshot(hit);
  }

  @override
  Future<void> retireHistorySearch(String accountId) async {
    retired.add(accountId);
  }
}

Future<AppState> _state(_SearchNative native, {bool group = false}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(native, await SharedPreferences.getInstance())
    ..jamiId = 'a' * 40
    ..screen = Screen.home;
  state.seedEmptyRuntimeSnapshotForTesting(
    selectedPeerId: _scope.peerId,
    friends: [
      FriendState(
        peerId: _scope.peerId,
        confirmed: true,
        conversationId: _scope.conversationId,
        displayName: 'Friend',
      ),
    ],
    groups: [
      if (group)
        GroupState(
          conversationId: _groupScope.conversationId,
          title: 'Group',
          memberCount: 2,
          canManageMembers: false,
          memberIds: ['a' * 40, 'b' * 40],
          activeMemberIds: {'a' * 40, 'b' * 40},
          invitedMemberIds: {},
        ),
    ],
  );
  // Match the existing Home widget fixtures: this is a seeded view, not a
  // running native event subscription or background topic scan.
  state.accountId = _scope.accountId;
  return state;
}

Future<void> _open(
  WidgetTester tester,
  AppState state, {
  bool home = false,
  Size? size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size ?? const Size(800, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      home: home
          ? ListenableBuilder(
              listenable: state,
              builder: (_, _) => HomeScreen(state: state),
            )
          : Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () =>
                      showHistorySearchDialog(context, state: state),
                  child: const Text('Search'),
                ),
              ),
            ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    home
        ? find.byKey(const ValueKey('open-history-search'))
        : find.text('Search'),
  );
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('history-search-query')),
    'message',
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void main() {
  testWidgets(
    'selection reloads folded text and deletion never restores its snippet',
    (tester) async {
      final native = _SearchNative();
      final state = await _state(native);
      addTearDown(state.dispose);
      await _open(tester, state);
      await _query(tester);
      expect(find.text('Old snippet 13'), findsOneWidget);
      expect(native.loaded, isEmpty);
      await tester.tap(find.text('Old snippet 13'));
      await tester.pumpAndSettle();
      expect(native.loaded, hasLength(1));
      expect(find.text('Current edited message'), findsOneWidget);
      expect(find.text('Old snippet 13'), findsNothing);
      expect(find.text('Edited'), findsOneWidget);
      native.deleted = true;
      await tester.tap(find.byKey(const ValueKey('history-message-reload')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('history-message-unavailable')),
        findsOneWidget,
      );
      expect(find.text('Current edited message'), findsNothing);
      expect(find.text('Old snippet 13'), findsNothing);
      expect(
        find.byKey(const ValueKey('history-message-open-conversation')),
        findsNothing,
      );
      expect(native.displayedMessages, isEmpty);
    },
  );
  testWidgets(
    'closing retires a pending folded load and rejects its late result',
    (tester) async {
      final native = _SearchNative()
        ..pendingMessage = Completer<SearchMessageSnapshot>();
      final state = await _state(native);
      addTearDown(state.dispose);
      await _open(tester, state);
      await _query(tester);
      await tester.tap(find.text('Old snippet 13'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('history-message-progress')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('history-search-close')));
      await tester.pumpAndSettle();
      expect(native.retired, [_scope.accountId]);
      expect(state.searchMessageSelection.canSelect, isFalse);
      native.pendingMessage!.complete(native.snapshot(_hit(_scope)));
      await tester.pumpAndSettle();
      expect(state.searchMessageSelection.canSelect, isTrue);
      expect(state.searchMessageSelection.item, isNull);
      expect(native.displayedMessages, isEmpty);
    },
  );
  testWidgets('unavailable search is not presented as zero matches', (
    tester,
  ) async {
    final native = _SearchNative()..failSearch = true;
    final state = await _state(native);
    addTearDown(state.dispose);
    await _open(tester, state);
    await _query(tester);
    expect(find.byKey(const ValueKey('history-search-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('history-search-empty')), findsNothing);
    expect(find.textContaining('PRIVATE'), findsNothing);
  });
  testWidgets(
    'privacy retirement clears query and ignores an unfinished search',
    (tester) async {
      final native = _SearchNative()
        ..pendingSearch = Completer<HistorySearchBatch>();
      final state = await _state(native);
      addTearDown(state.dispose);
      await _open(tester, state);
      await _query(tester);
      expect(
        find.byKey(const ValueKey('history-search-progress')),
        findsOneWidget,
      );
      state.setProtectedSurfaceLocked(true);
      await tester.pumpAndSettle();
      expect(native.retired, [_scope.accountId]);
      expect(find.byKey(const ValueKey('history-search-query')), findsNothing);
      expect(find.textContaining('privacy state changed'), findsOneWidget);
      native.pendingSearch!.complete(HistorySearchBatch.empty);
      await tester.pumpAndSettle();
      state.setProtectedSurfaceLocked(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history-search-query')), findsNothing);
      expect(state.historySearch.results, isEmpty);
    },
  );
  testWidgets(
    'pagination reveals bounded results without another native scan',
    (tester) async {
      final native = _SearchNative()..count = 30;
      final state = await _state(native);
      addTearDown(state.dispose);
      await _open(tester, state);
      await _query(tester);
      expect(find.text('Old snippet 42'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('history-search-more')),
      );
      await tester.tap(find.byKey(const ValueKey('history-search-more')));
      await tester.pumpAndSettle();
      expect(find.text('Old snippet 42'), findsOneWidget);
      expect(native.searched, [_scope]);
    },
  );
  testWidgets('conversation filter searches only the selected owner', (
    tester,
  ) async {
    final native = _SearchNative();
    final state = await _state(native, group: true);
    addTearDown(state.dispose);
    await _open(tester, state);
    await _query(tester);
    expect(native.searched, [_scope, _groupScope]);
    await tester.tap(find.byKey(const ValueKey('history-search-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group').last);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(native.searched, [_scope, _groupScope, _groupScope]);
    expect(find.text('Old snippet 13'), findsOneWidget);
  });
  testWidgets(
    'compact keyboard layout remains scrollable at doubled text size',
    (tester) async {
      final native = _SearchNative();
      final state = await _state(native);
      addTearDown(state.dispose);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, state, size: const Size(390, 440));
      await _query(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('history-search-close')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'Home opens a selected direct result without reading snippets as messages',
    (tester) async {
      final native = _SearchNative();
      final state = await _state(native);
      addTearDown(state.dispose);
      await _open(tester, state, home: true, size: const Size(390, 844));
      await _query(tester);
      expect(state.visibleConversationPeerId, isNull);
      await tester.tap(find.text('Old snippet 13'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('history-message-open-conversation')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HistorySearchDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('compact-conversation-pane')),
        findsOneWidget,
      );
      expect(state.selectedConversationScope, _scope);
      expect(state.historySearch.results, isEmpty);
      expect(state.searchMessageSelection.item, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('group search opens its exact text room in rooms-first layout', (
    tester,
  ) async {
    final native = _SearchNative();
    final state = await _state(native, group: true);
    state.appSettings = AppSettings(
      mobileGroupNavigation: MobileGroupNavigation.roomsFirst,
    );
    addTearDown(state.dispose);
    await _open(tester, state, home: true, size: const Size(390, 844));
    await _query(tester);
    await tester.tap(find.text('Old snippet 13').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('history-message-open-conversation')),
    );
    await tester.tap(
      find.byKey(const ValueKey('history-message-open-conversation')),
    );
    await tester.pumpAndSettle();
    expect(state.selectedConversationScope, _groupScope);
    expect(
      find.byKey(const ValueKey('mobile-group-room-browser')),
      findsNothing,
    );
    expect(state.visibleGroupTopicId, 'games');
    expect(tester.takeException(), isNull);
  });
  testWidgets('an invalid query is retired on lock before any worker starts', (
    tester,
  ) async {
    final native = _SearchNative();
    final state = await _state(native);
    addTearDown(state.dispose);
    await _open(tester, state);
    await tester.enterText(
      find.byKey(const ValueKey('history-search-query')),
      'private\u0000query',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('history-search-error')), findsOneWidget);
    expect(native.searched, isEmpty);
    state.setProtectedSurfaceLocked(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-search-query')), findsNothing);
    expect(find.textContaining('privacy state changed'), findsOneWidget);
  });
  testWidgets('an account round trip cannot revive a previous search route', (
    tester,
  ) async {
    final native = _SearchNative()
      ..pendingSearch = Completer<HistorySearchBatch>();
    final state = await _state(native);
    addTearDown(state.dispose);
    await _open(tester, state);
    await _query(tester);
    state.accountId = 'other';
    state.accountId = _scope.accountId;
    await tester.pumpAndSettle();
    native.pendingSearch!.complete(HistorySearchBatch.empty);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-search-query')), findsNothing);
    expect(find.textContaining('privacy state changed'), findsOneWidget);
    expect(state.historySearch.results, isEmpty);
  });
  testWidgets(
    'reusing GroupStage for another group preserves the requested room',
    (tester) async {
      final native = _SearchNative();
      final state = await _state(native, group: true);
      addTearDown(state.dispose);
      state.appSettings = AppSettings(
        mobileGroupNavigation: MobileGroupNavigation.roomsFirst,
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      String? visible;
      Widget stage(GroupState group, {String? topic, Object? token}) =>
          MaterialApp(
            theme: Warm.theme(),
            home: Scaffold(
              body: GroupStage(
                onOpenCall: () {},
                onOpenSettings: () {},
                state: state,
                group: group,
                requestedTopicId: topic,
                navigationToken: token,
                onConversationVisibilityChanged: (topic) => visible = topic,
              ),
            ),
          );
      final original = state.groups[_groupScope.conversationId]!;
      await tester.pumpWidget(stage(original));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-group-room-browser')),
        findsOneWidget,
      );
      final replacement = GroupState(
        conversationId: 'a' * 40,
        title: 'Other group',
        memberCount: 2,
        canManageMembers: false,
        memberIds: ['a' * 40, 'b' * 40],
        activeMemberIds: {'a' * 40, 'b' * 40},
        invitedMemberIds: {},
      );
      await tester.pumpWidget(
        stage(replacement, topic: 'games', token: Object()),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-group-room-browser')),
        findsNothing,
      );
      expect(visible, 'games');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Ctrl F opens one search route, not nested search dialogs', (
    tester,
  ) async {
    final native = _SearchNative();
    final state = await _state(native);
    addTearDown(state.dispose);
    await _open(tester, state, home: true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
    expect(find.byType(HistorySearchDialog), findsOneWidget);
  });
}
