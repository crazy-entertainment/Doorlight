import 'package:sybl/ui/notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/invite_link.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/pending_invite.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/account_share.dart';
import 'package:sybl/ui/add_friend_dialog.dart';
import 'package:sybl/ui/friend_qr_scanner.dart';

const _ownId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _friendId = 'abcdef0123456789abcdef0123456789abcdef01';

final class _AddFriendState extends AppState {
  _AddFriendState(super.jami, super.prefs);

  final submittedIds = <String>[];
  final submittedHints = <String?>[];
  bool result = true;
  Map<String, FriendState>? friendsOverride;

  @override
  Map<String, FriendState> get friends => friendsOverride ?? super.friends;

  @override
  Future<bool> addFriend(String hex, {String? nameHint}) async {
    submittedIds.add(hex);
    submittedHints.add(nameHint);
    return result;
  }
}

Future<_AddFriendState> _newState() async {
  SharedPreferences.setMockInitialValues({});
  return _AddFriendState(JamiClient(), await SharedPreferences.getInstance())
    ..jamiId = _ownId
    ..accountId = 'account'
    ..screen = Screen.home
    ..seedCaptureStateForTesting(
      resolved: true,
      applied: WindowCaptureProtectionStatus.exclude,
    );
}

Future<void> _pumpLauncher(
  WidgetTester tester,
  _AddFriendState state, {
  TextScaler textScaler = TextScaler.noScaling,
  TargetPlatform platform = TargetPlatform.windows,
  SyblInviteLink? initialInvite,
  PendingInvite? continuation,
  bool pasteOnOpen = false,
  bool chosen = false,
  bool nearby = false,
}) async {
  clearNotices();
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme().copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: withNoticeHost(child!, state),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showAddFriendDialog(
              context,
              state: state,
              initialInvite: initialInvite,
              continuation: continuation,
              pasteOnOpen: pasteOnOpen,
              manualEntry: pasteOnOpen,
              chosen: chosen,
              nearby: nearby,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('paste entry reads clipboard immediately but waits for Add', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': 'jami:$_friendId'}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpLauncher(tester, state, pasteOnOpen: true);
    expect(find.text('Paste a friend link'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('friend-id-field')))
          .controller!
          .text,
      'jami:$_friendId',
    );
    expect(state.submittedIds, isEmpty);
    await tester.tap(find.byKey(const ValueKey('confirm-add-friend-button')));
    await tester.pumpAndSettle();
    expect(state.submittedIds, [_friendId]);
  });

  testWidgets('Windows can copy the same invite link the QR carries', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state);
    await tester.tap(find.byKey(const ValueKey('show-my-friend-qr')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-friend-invite-link')));
    await tester.pump();
    expect(copied, [
      SyblInviteLink.create(
        jamiId: _ownId,
        displayName: state.displayName,
      )!.shareUri(),
    ]);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('first and later friends use the normal action heading', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state);
    expect(find.text('Good chats start\nwith your people.'), findsNothing);
    expect(find.text('Add a friend'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    state.friendsOverride = {
      _friendId: const FriendState(
        peerId: _friendId,
        confirmed: true,
        conversationId: 'conversation',
      ),
    };
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Add a friend'), findsOneWidget);
    expect(find.text('Good chats start\nwith your people.'), findsNothing);
  });

  testWidgets('named invitation remains usable at 200% text on a phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final state = await _newState();
    addTearDown(state.dispose);
    final invite = SyblInviteLink.create(
      jamiId: _friendId,
      displayName: 'A long invited name that still fits the public hint limit',
    )!;
    await _pumpLauncher(
      tester,
      state,
      initialInvite: invite,
      textScaler: const TextScaler.linear(2),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('confirm-add-friend-button')),
    );
    expect(find.text('Add ${invite.displayName}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['replace', 'return', 'lock']) {
    testWidgets('displayed invitation cannot submit after $change', (
      tester,
    ) async {
      final state = await _newState();
      addTearDown(state.dispose);
      state.inviteContinuation.stage('sybl://add/$_friendId?name=Mara');
      final record = state.inviteContinuation.pending!;
      await _pumpLauncher(
        tester,
        state,
        initialInvite: record.invite,
        continuation: record,
      );
      final submit = tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirm-add-friend-button')),
          )
          .onPressed!;
      if (change == 'lock') {
        state.setProtectedSurfaceLocked(true);
      } else {
        state.accountId = 'other';
        if (change == 'return') state.accountId = 'account';
      }
      submit();
      await tester.pump();
      expect(state.submittedIds, isEmpty);
      expect(state.inviteContinuation.pending, same(record));
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }

  testWidgets(
    'later link cannot retarget Add and issued uncertainty is not retried',
    (tester) async {
      final state = await _newState()
        ..result = false;
      addTearDown(state.dispose);
      state.inviteContinuation.stage('sybl://add/$_friendId?name=Mara');
      final record = state.inviteContinuation.pending!;
      await _pumpLauncher(
        tester,
        state,
        initialInvite: record.invite,
        continuation: record,
      );
      state.inviteContinuation.stage(
        'sybl://add/${'c' * 40}?name=Someone+else',
      );
      expect(find.text('Add Mara'), findsOneWidget);
      expect(state.submittedIds, isEmpty);
      final button = find.byKey(const ValueKey('confirm-add-friend-button'));
      final submit = tester.widget<FilledButton>(button).onPressed!;
      submit();
      submit();
      await tester.pumpAndSettle();
      expect(state.submittedIds, [_friendId]);
      expect(state.inviteContinuation.pending, isNull);
      expect(
        state.prefs.containsKey(PendingInviteStore.preferenceKey),
        isFalse,
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.textContaining('outcome is not confirmed'), findsOneWidget);
      submit();
      await tester.pump();
      expect(state.submittedIds, [_friendId]);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('typing an invitation shows its hint and sends only after Add', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state);
    await tester.tap(find.byKey(const ValueKey('enter-friend-id')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('friend-id-field')),
      'doorlight://add/$_friendId?name=Mara',
    );
    await tester.pump();
    expect(find.text('Add Mara'), findsOneWidget);
    expect(state.submittedIds, isEmpty);
    await tester.tap(find.text('Add Mara'));
    await tester.pumpAndSettle();
    expect(state.submittedIds, [_friendId]);
    expect(
      find.text('Friend request sent. Waiting for their acceptance.'),
      findsOneWidget,
    );
  });

  testWidgets('personalized invite prefills but never auto-adds trust', (
    tester,
  ) async {
    final state = await _newState();
    state.displayName = 'Me';
    addTearDown(state.dispose);
    final invite = SyblInviteLink.create(
      jamiId: _friendId,
      displayName: 'Mara',
    )!;
    await _pumpLauncher(tester, state, initialInvite: invite);

    expect(find.text('Mara invited you'), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-id-field')), findsNothing);
    expect(state.submittedIds, isEmpty);

    await tester.tap(find.byKey(const ValueKey('confirm-add-friend-button')));
    await tester.pumpAndSettle();
    expect(state.submittedIds, [_friendId]);
  });

  testWidgets('a person chosen in the pane needs only one Add press', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    final invite = SyblInviteLink.create(
      jamiId: _friendId,
      displayName: 'Mara',
    )!;
    await _pumpLauncher(tester, state, initialInvite: invite, chosen: true);

    expect(find.text('Mara'), findsOneWidget);
    expect(find.text('Mara invited you'), findsNothing);
    expect(find.textContaining('Add them as a friend?'), findsNothing);
    expect(find.text('The name comes from the invite link.'), findsOneWidget);
    expect(state.submittedIds, isEmpty);
    await tester.tap(find.text('Add Mara'));
    await tester.pumpAndSettle();
    expect(state.submittedIds, [_friendId]);
  });

  testWidgets('a nearby pick does not claim the name came from a link', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    final invite = SyblInviteLink.create(
      jamiId: _friendId,
      displayName: 'Mara',
    )!;
    await _pumpLauncher(
      tester,
      state,
      initialInvite: invite,
      chosen: true,
      nearby: true,
    );
    expect(find.textContaining('invite link'), findsNothing);
    expect(find.textContaining('Add them as a friend?'), findsNothing);
  });

  testWidgets('normalizes a canonical Jami URI before adding the contact', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state);
    await tester.tap(find.byKey(const ValueKey('enter-friend-id')));
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('friend-id-field')),
      'JAMI:${_friendId.toUpperCase()}',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-add-friend-button')));
    await tester.pumpAndSettle();

    expect(state.submittedIds, [_friendId]);
    expect(find.text('Add a friend'), findsNothing);
  });

  testWidgets('rejects malformed and self identities before calling AppState', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state);
    await tester.tap(find.byKey(const ValueKey('enter-friend-id')));
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('friend-id-field')),
      'not-a-jami-id',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-add-friend-button')));
    await tester.pump();
    expect(
      find.text('Scan or paste your friend’s invitation.'),
      findsOneWidget,
    );
    expect(state.submittedIds, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('friend-id-field')),
      _ownId,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-add-friend-button')));
    await tester.pump();
    expect(find.text('That is your own friend code.'), findsOneWidget);
    expect(state.submittedIds, isEmpty);
  });

  testWidgets('paste accepts the standard Jami URI', (tester) async {
    final state = await _newState();
    addTearDown(state.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': 'jami:$_friendId'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpLauncher(tester, state);

    await tester.tap(find.byKey(const ValueKey('paste-friend-invite')));
    await tester.pump();
    expect(find.byKey(const ValueKey('friend-id-field')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('friend-id-field')))
          .controller!
          .text,
      'jami:$_friendId',
    );
  });

  testWidgets('oversized clipboard input never fills the invitation field', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': 'x' * 1025}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpLauncher(tester, state);
    await tester.tap(find.byKey(const ValueKey('paste-friend-invite')));
    await tester.pump();
    expect(find.byKey(const ValueKey('friend-id-field')), findsNothing);
    expect(find.textContaining('invitation is too long'), findsOneWidget);
    expect(state.submittedIds, isEmpty);
  });

  testWidgets('add friend keeps sharing outside the flow', (tester) async {
    final state = await _newState();
    addTearDown(state.dispose);
    final semantics = tester.ensureSemantics();
    await _pumpLauncher(tester, state);

    expect(find.byKey(const ValueKey('paste-friend-invite')), findsOneWidget);
    expect(find.text('Share'), findsNothing);
    expect(find.text('Add by friend code'), findsOneWidget);
    expect(find.byKey(const ValueKey('show-my-friend-qr')), findsOneWidget);
    expect(tester, meetsGuideline(androidTapTargetGuideline));
    expect(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  for (final scenario in <({String name, Size size, TextScaler textScaler})>[
    (
      name: 'compact Windows window',
      size: const Size(800, 450),
      textScaler: TextScaler.noScaling,
    ),
    (
      name: 'phone at 200% text',
      size: const Size(390, 844),
      textScaler: const TextScaler.linear(2),
    ),
  ]) {
    testWidgets('add flow remains usable on ${scenario.name}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = scenario.size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final state = await _newState();
      addTearDown(state.dispose);

      await _pumpLauncher(tester, state, textScaler: scenario.textScaler);
      await tester.ensureVisible(find.byKey(const ValueKey('enter-friend-id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('enter-friend-id')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('friend-id-field')));
      await tester.pump();

      expect(find.byKey(const ValueKey('friend-id-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('QR accepts only supported friend invitations', () {
    expect(
      friendInviteFromQr('sybl://add/$_friendId?name=Mara')?.displayName,
      'Mara',
    );
    expect(friendInviteFromQr('jami:$_friendId')?.jamiId, _friendId);
    expect(friendInviteFromQr('https://example.com'), isNull);
  });

  testWidgets('phone Add opens without focusing the manual field', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state, platform: TargetPlatform.android);
    expect(find.byKey(const ValueKey('scan-friend-qr')), findsOneWidget);
    expect(find.byKey(const ValueKey('show-my-friend-qr')), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-id-field')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('enter-friend-id')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('friend-id-field')))
          .autofocus,
      false,
    );
  });

  testWidgets('Show my QR opens the separate invitation screen', (
    tester,
  ) async {
    final state = await _newState();
    addTearDown(state.dispose);
    await _pumpLauncher(tester, state, platform: TargetPlatform.android);
    await tester.tap(find.byKey(const ValueKey('show-my-friend-qr')));
    await tester.pumpAndSettle();
    expect(find.text('Invite a friend'), findsOneWidget);
    expect(find.byType(FriendInviteQr), findsOneWidget);
    expect(
      find.byKey(const ValueKey('share-friend-invitation')),
      findsOneWidget,
    );
  });
}
