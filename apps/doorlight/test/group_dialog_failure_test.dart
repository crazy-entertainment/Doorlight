import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/group_dialogs.dart';

const _group = GroupState(
  conversationId: 'fixture-group',
  title: 'The Crew',
  memberCount: 1,
  canManageMembers: true,
  localRole: JamiGroupMemberRole.admin,
  memberIds: [],
  activeMemberIds: {},
  invitedMemberIds: {},
);

final class _GroupJami extends JamiClient {
  Completer<bool> leaveResult = Completer<bool>();
  final leaveRequests = <String>[];
  final inviteRequests = <(String, List<String>)>[];

  @override
  Future<bool> leaveGroup(String conversationId, {String? expectedAccountId}) {
    leaveRequests.add(conversationId);
    return leaveResult.future;
  }

  @override
  Future<JamiFriendList> listFriends() async => const JamiFriendList(1, []);

  @override
  Future<void> setPresenceSubscriptions(Iterable<String> peerJamiIds) async {}

  @override
  Future<void> replayPendingNativeEvents() async {}

  @override
  Future<bool> addGroupMembers(
    String conversationId,
    Iterable<String> peerJamiIds, {
    String? expectedAccountId,
  }) async {
    inviteRequests.add((conversationId, peerJamiIds.toList()));
    return false;
  }
}

Future<AppState> _newState(_GroupJami jami, {int friendCount = 0}) async {
  SharedPreferences.setMockInitialValues({'selectedGroupId': 'fixture-group'});
  final state = AppState(jami, await SharedPreferences.getInstance())
    ..accountId = 'fixture-account'
    ..jamiId = 'a' * 40;
  state.seedEmptyRuntimeSnapshotForTesting(
    friends: [
      for (var index = 0; index < friendCount; index++)
        FriendState(
          peerId: index.toRadixString(16).padLeft(40, '0'),
          confirmed: true,
          conversationId: 'friend-conversation-$index',
          displayName: 'Friend ${index.toString().padLeft(2, '0')}',
        ),
    ],
    groups: const [_group],
    selectedFixtureGroupId: _group.conversationId,
  );
  return state;
}

Future<void> _openDialog(
  WidgetTester tester,
  AppState state, {
  bool invite = false,
  TextScaler textScaler = TextScaler.noScaling,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: Warm.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () => invite
                ? showInviteGroupMembersDialog(
                    context,
                    state: state,
                    group: _group,
                  )
                : showGroupSettingsDialog(context, state: state, group: _group),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _addDraftCollection(WidgetTester tester) async {
  final addCollection = find.byKey(const ValueKey('add-group-collection'));
  await tester.ensureVisible(addCollection);
  await tester.tap(addCollection);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), 'Weekend plans');
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

Future<void> _confirmLeave(WidgetTester tester) async {
  final leaveGroup = find.widgetWithText(TextButton, 'Leave group');
  await tester.ensureVisible(leaveGroup);
  await tester.tap(leaveGroup);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'group settings keeps collection actions reachable at 200% text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = await _newState(_GroupJami());
      addTearDown(state.dispose);
      await _openDialog(tester, state, textScaler: const TextScaler.linear(2));
      expect(tester.takeException(), isNull);

      await _addDraftCollection(tester);
      expect(tester.takeException(), isNull);
      final addRoom = find.byKey(
        const ValueKey('add-conversation-Weekend plans'),
      );
      await tester.ensureVisible(addRoom);
      await tester.tap(addRoom);
      await tester.pumpAndSettle();
      expect(find.text('Text topic'), findsOneWidget);
      expect(find.text('Voice room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final throws in [false, true]) {
    testWidgets(
      'leave ${throws ? 'exception' : 'rejection'} keeps the group and draft and permits retry',
      (tester) async {
        final jami = _GroupJami();
        final state = await _newState(jami);
        addTearDown(state.dispose);
        await _openDialog(tester, state);
        await _addDraftCollection(tester);
        await _confirmLeave(tester);

        expect(jami.leaveRequests, [_group.conversationId]);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Leave group'),
              )
              .onPressed,
          isNull,
        );
        if (throws) {
          jami.leaveResult.completeError(StateError('fixture leave failed'));
        } else {
          jami.leaveResult.complete(false);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull);
        expect(state.groups[_group.conversationId], same(_group));
        expect(state.selectedGroupId, _group.conversationId);
        expect(state.prefs.getString('selectedGroupId'), _group.conversationId);
        expect(find.text('Weekend plans'), findsOneWidget);
        expect(find.textContaining('Try again'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Leave group'),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byTooltip('Close'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('save-group-layout')),
              )
              .onPressed,
          isNotNull,
        );

        jami.leaveResult = Completer<bool>();
        await _confirmLeave(tester);
        expect(jami.leaveRequests, [
          _group.conversationId,
          _group.conversationId,
        ]);
        jami.leaveResult.complete(true);
        await tester.pumpAndSettle();

        expect(find.text('Leave group'), findsNothing);
        expect(state.groups, isEmpty);
        expect(state.selectedGroupId, isNull);
        expect(state.prefs.getString('selectedGroupId'), isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel leave keeps the draft and does not call the daemon', (
    tester,
  ) async {
    final jami = _GroupJami();
    final state = await _newState(jami);
    addTearDown(state.dispose);
    await _openDialog(tester, state);
    await _addDraftCollection(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Leave group'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(jami.leaveRequests, isEmpty);
    expect(find.text('Weekend plans'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Leave group'), findsNothing);
    expect(state.groups[_group.conversationId], same(_group));
  });

  for (final outcome in ['false', 'throw', 'true']) {
    testWidgets(
      'leave $outcome after route removal does not update disposed UI',
      (tester) async {
        final jami = _GroupJami();
        final state = await _newState(jami);
        final navigatorKey = GlobalKey<NavigatorState>();
        addTearDown(state.dispose);
        await _openDialog(tester, state, navigatorKey: navigatorKey);
        await _confirmLeave(tester);
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Leave group'), findsNothing);

        if (outcome == 'throw') {
          jami.leaveResult.completeError(StateError('fixture leave failed'));
        } else {
          jami.leaveResult.complete(outcome == 'true');
        }
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Open'), findsOneWidget);
        expect(state.groups.isEmpty, outcome == 'true');
      },
    );
  }

  for (final viewport in [
    (const Size(1280, 800), 1.0),
    (const Size(700, 500), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(390, 844), 2.0),
  ]) {
    testWidgets(
      'Add people reaches the last friend at ${viewport.$1} and text ${viewport.$2}',
      (tester) async {
        tester.view.physicalSize = viewport.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final jami = _GroupJami();
        final state = await _newState(jami, friendCount: 30);
        addTearDown(state.dispose);
        await _openDialog(
          tester,
          state,
          invite: true,
          textScaler: TextScaler.linear(viewport.$2),
        );

        expect(tester.takeException(), isNull);
        final peerId = '1d'.padLeft(40, '0');
        final invite = find.byKey(ValueKey('invite-group-member-$peerId'));
        await tester.scrollUntilVisible(
          invite,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(invite);
        await tester.pumpAndSettle();

        expect(jami.inviteRequests, hasLength(1));
        expect(jami.inviteRequests.single.$1, _group.conversationId);
        expect(jami.inviteRequests.single.$2, [peerId]);
        expect(find.text('Friend 29 could not be invited.'), findsOneWidget);
        expect(tester.widget<FilledButton>(invite).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(TextButton, 'Done'));
        await tester.pumpAndSettle();
        expect(find.text('Add people'), findsNothing);
        state.dispose();
        await tester.pump();
      },
    );
  }
}
