import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/group_dialogs.dart';

const _peer = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _group = GroupState(
  conversationId: 'crew',
  title: 'The Crew',
  memberCount: 2,
  canManageMembers: true,
  localRole: JamiGroupMemberRole.admin,
  memberIds: [_peer],
  activeMemberIds: {},
  invitedMemberIds: {_peer},
  memberRoles: {_peer: JamiGroupMemberRole.invited},
);

final class _Client extends JamiClient {
  final commands = <String>[];
  Completer<bool>? pending;
  bool throws = false;

  Future<bool> command(String name) async {
    commands.add(name);
    if (throws) throw StateError('fixture command failed');
    return pending == null ? false : pending!.future;
  }

  @override
  Future<String> createGroup(
    String title,
    Iterable<String> members, {
    String? expectedAccountId,
  }) async {
    await command('create');
    return '';
  }

  @override
  Future<bool> renameGroup(
    String conversationId,
    String title, {
    String? expectedAccountId,
  }) => command('rename');
  @override
  Future<bool> addGroupMembers(
    String conversationId,
    Iterable<String> members, {
    String? expectedAccountId,
  }) => command('invite');
  @override
  Future<bool> removeGroupMember(
    String conversationId,
    String memberId, {
    String? expectedAccountId,
  }) => command('remove');
  @override
  Future<bool> leaveGroup(String conversationId, {String? expectedAccountId}) =>
      command('leave');
  @override
  Future<bool> updateGroupLayout(
    String conversationId,
    String description, {
    String? expectedAccountId,
  }) => command('layout');
}

class _StateOwner extends StatefulWidget {
  const _StateOwner({required this.state, required this.child});
  final AppState state;
  final Widget child;
  @override
  State<_StateOwner> createState() => _StateOwnerState();
}

class _StateOwnerState extends State<_StateOwner> {
  @override
  Widget build(BuildContext context) => widget.child;
  @override
  void dispose() {
    widget.state.dispose();
    super.dispose();
  }
}

Future<AppState> _open(
  WidgetTester tester,
  _Client client,
  String screen, {
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(client, await SharedPreferences.getInstance())
    ..accountId = 'account-a'
    ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  addTearDown(state.dispose);
  state.seedEmptyRuntimeSnapshotForTesting(
    groups: const [_group],
    selectedFixtureGroupId: _group.conversationId,
    friends: const [
      FriendState(
        peerId: 'cccccccccccccccccccccccccccccccccccccccc',
        confirmed: true,
        conversationId: 'claire-conversation',
        displayName: 'Claire',
      ),
    ],
  );
  await tester.pumpWidget(
    _StateOwner(
      state: state,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: Warm.theme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => switch (screen) {
                'create' => showCreateGroupDialog(context, state: state),
                'rename' => showRenameGroupDialog(
                  context,
                  state: state,
                  group: _group,
                ),
                'invite' => showInviteGroupMembersDialog(
                  context,
                  state: state,
                  group: _group,
                ),
                _ => showGroupSettingsDialog(
                  context,
                  state: state,
                  group: _group,
                ),
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  for (final change in ['account', 'account-return', 'visit']) {
    testWidgets('leave confirmation cannot cross a $change change', (
      tester,
    ) async {
      final client = _Client();
      final state = await _open(tester, client, 'settings');
      await tester.ensureVisible(
        find.widgetWithText(TextButton, 'Leave group'),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Leave group'));
      await tester.pumpAndSettle();
      if (change == 'visit') {
        state.selectedGroupId = null;
        state.selectedGroupId = _group.conversationId;
      } else {
        state.accountId = 'account-b';
        if (change == 'account-return') state.accountId = 'account-a';
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
      await tester.pumpAndSettle();
      expect(client.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final screen in ['create', 'rename', 'invite']) {
    for (final stale in [false, true]) {
      testWidgets(
        '$screen rejects ${stale ? 'stale identity' : 'queued duplicate'} submissions',
        (tester) async {
          final client = _Client()..pending = Completer<bool>();
          final state = await _open(tester, client, screen);
          if (screen == 'create') {
            await tester.enterText(
              find.byKey(const ValueKey('group-title-field')),
              'New group',
            );
            await tester.tap(find.byType(CheckboxListTile));
            await tester.pump();
          } else if (screen == 'rename') {
            await tester.enterText(
              find.byKey(const ValueKey('rename-group-field')),
              'New name',
            );
          }
          final submit = tester
              .widget<FilledButton>(find.byType(FilledButton).last)
              .onPressed!;
          if (stale) {
            state.accountId = 'account-b';
            state.accountId = 'account-a';
          }
          submit();
          if (!stale) submit();
          await tester.pump();
          client.pending!.complete(false);
          await tester.pumpAndSettle();
          expect(client.commands, stale ? isEmpty : [screen]);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$screen command exception releases the busy UI for retry', (
      tester,
    ) async {
      final client = _Client()..throws = true;
      await _open(tester, client, screen);
      if (screen == 'create') {
        await tester.enterText(
          find.byKey(const ValueKey('group-title-field')),
          'New group',
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
      } else if (screen == 'rename') {
        await tester.enterText(
          find.byKey(const ValueKey('rename-group-field')),
          'New name',
        );
      }
      final submit = find.byType(FilledButton).last;
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(client.commands, [screen]);
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rename keyboard and button submissions share the busy guard', (
    tester,
  ) async {
    final client = _Client()..pending = Completer<bool>();
    await _open(tester, client, 'rename');
    await tester.enterText(
      find.byKey(const ValueKey('rename-group-field')),
      'New name',
    );
    final submit = tester
        .widget<FilledButton>(find.byType(FilledButton).last)
        .onPressed!;
    await tester.testTextInput.receiveAction(TextInputAction.done);
    submit();
    await tester.pump();
    expect(client.commands, ['rename']);
    client.pending!.complete(false);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'member removal requires confirmation and cancellation is nonmutating',
    (tester) async {
      final client = _Client();
      await _open(tester, client, 'settings');
      await tester.ensureVisible(find.byTooltip('Remove member'));
      await tester.tap(find.byTooltip('Remove member'));
      await tester.pumpAndSettle();
      expect(client.commands, isEmpty);
      expect(find.text('Remove this member?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(client.commands, isEmpty);
      await tester.tap(find.byTooltip('Remove member'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(client.commands, ['remove']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('queued name submissions cannot dismiss group settings', (
    tester,
  ) async {
    await _open(tester, _Client(), 'settings');
    await tester.ensureVisible(
      find.byKey(const ValueKey('add-group-collection')),
    );
    await tester.tap(find.byKey(const ValueKey('add-group-collection')));
    await tester.pumpAndSettle();
    final save = tester.widget<TextField>(find.byType(TextField)).onSubmitted!;
    save('Weekend');
    save('Weekend');
    await tester.pumpAndSettle();
    expect(find.text('Weekend'), findsOneWidget);
    expect(find.text('Leave group'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested name completion cannot update a disposed group dialog', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await _open(tester, _Client(), 'settings', navigatorKey: key);
    final parentRoute = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('add-group-collection'))),
    )!;
    await tester.ensureVisible(
      find.byKey(const ValueKey('add-group-collection')),
    );
    await tester.tap(find.byKey(const ValueKey('add-group-collection')));
    await tester.pumpAndSettle();
    key.currentState!.removeRoute(parentRoute);
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), 'Weekend');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending member role and removal remain reachable at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _open(tester, _Client(), 'settings');
    expect(find.text('Invitation pending'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Remove member'));
    expect(tester.takeException(), isNull);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'create group remains usable above the keyboard at text $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final client = _Client();
        await _open(tester, client, 'create');
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('group-title-field')),
          'Family',
        );
        await tester.ensureVisible(find.byType(CheckboxListTile));
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('confirm-create-group')),
        );
        await tester.tap(find.byKey(const ValueKey('confirm-create-group')));
        await tester.pumpAndSettle();
        expect(client.commands, ['create']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
