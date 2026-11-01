import 'dart:ui';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sybl/ui/account_share.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as image;
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/home.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/friend_rail.dart';
import 'package:sybl/ui/group_stage.dart';
import 'package:sybl/ui/sybl_ui.dart';
import 'package:sybl/ui/windows_chrome.dart';

const _firstPeer = '1111111111111111111111111111111111111111';
const _secondPeer = '2222222222222222222222222222222222222222';
const _nonFriendMember = '3333333333333333333333333333333333333333';

Finder _friendAvatar(String peerId, {required bool mini}) => find.descendant(
  of: find.byKey(ValueKey('${mini ? 'friend-mini' : 'friend'}-$peerId')),
  matching: find.byType(SyblAvatar),
);

Finder _groupAvatar({required bool mini}) => find.descendant(
  of: find.byKey(
    ValueKey('${mini ? 'group-mini-' : 'group-'}conversation-crew'),
  ),
  matching: find.byType(GroupAvatar),
);

Finder _selfAvatar({required bool mini}) {
  final shared = find.byKey(const ValueKey('desktop-shared-profile-avatar'));
  if (shared.evaluate().isNotEmpty) return shared;
  return find.descendant(
    of: find.byKey(ValueKey(mini ? 'group-mini-settings' : 'account-card')),
    matching: find.byType(SyblAvatar),
  );
}

final Finder _selfCallRing = find.byKey(const ValueKey('group-mini-self-ring'));

Finder _peerCallRing(String peerId) =>
    find.byKey(ValueKey('friend-mini-call-ring-$peerId'));

Finder _rowCallRing(String peerId) =>
    find.byKey(ValueKey('friend-call-ring-$peerId'));

/// The decoration actually being painted, which is what a caller sees. The
/// `AnimatedContainer` widget only carries the target it is heading towards.
BoxDecoration _paintedRing(WidgetTester tester, Finder frame) =>
    tester
            .renderObject<RenderDecoratedBox>(
              find
                  .descendant(of: frame, matching: find.byType(DecoratedBox))
                  .first,
            )
            .decoration
        as BoxDecoration;

/// Alpha span of the outline: a travelling segment is mostly transparent with
/// one lit stop, a complete outline is lit everywhere.
({double min, double max}) _ringAlpha(BoxDecoration ring) {
  final colors = (ring.gradient! as SweepGradient).colors;
  return (
    min: colors.fold(1.0, (low, c) => c.a < low ? c.a : low),
    max: colors.fold(0.0, (high, c) => c.a > high ? c.a : high),
  );
}

double _ringAngle(WidgetTester tester, Finder frame) =>
    ((_paintedRing(tester, frame).gradient! as SweepGradient).transform!
            as GradientRotation)
        .radians;

/// Implicit decoration swaps are 180 ms; frames longer than that land on the
/// previous target, so two are enough to settle without stalling on the
/// repeating pre-connect spin (which `pumpAndSettle` would never end).
Future<void> _settleRing(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

class _LayoutJamiClient extends JamiClient {
  @override
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
    // Never loads: -1 is a rejected load. (0 now means "still cloning" and
    // would start the automatic retry.)
  }) async => -1;
}

final class _ActivityAppState extends AppState {
  _ActivityAppState(super.jami, super.prefs, this.fixtureActivity);

  final FriendActivity fixtureActivity;

  @override
  FriendActivity friendActivity(String peerId) => fixtureActivity;
}

final class _RouteRetirementState extends AppState {
  _RouteRetirementState(super.jami, super.prefs);

  int stopRemoteControlCalls = 0;

  @override
  Future<void> stopRemoteControl() async {
    stopRemoteControlCalls++;
  }
}

Future<AppState> _stateWithFriends({
  bool inviteSecond = false,
  bool includeNonFriendMember = false,
  FriendActivity? friendActivity,
  JamiClient? jami,
  bool trackRouteRetirement = false,
  bool twoGroups = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final state =
      (friendActivity == null
            ? trackRouteRetirement
                  ? _RouteRetirementState(jami ?? _LayoutJamiClient(), prefs)
                  : AppState(jami ?? _LayoutJamiClient(), prefs)
            : _ActivityAppState(
                jami ?? _LayoutJamiClient(),
                prefs,
                friendActivity,
              ))
        ..displayName = 'You'
        ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        ..registration = 'REGISTERED';
  state.seedEmptyRuntimeSnapshotForTesting(
    selectedPeerId: _firstPeer,
    friends: const [
      FriendState(
        peerId: _firstPeer,
        confirmed: true,
        conversationId: 'conversation-one',
        displayName: 'Phone B',
        presence: PeerPresence.inApp,
        presencePlatform: 'android',
      ),
      FriendState(
        peerId: _secondPeer,
        confirmed: true,
        conversationId: 'conversation-two',
        displayName: 'Phone A',
        presence: PeerPresence.reachable,
        presencePlatform: 'windows',
        presenceActivity: 'Team Fortress 2',
      ),
    ],
    groups: [
      if (twoGroups)
        GroupState(
          conversationId: 'conversation-weekend',
          title: 'Weekend plans',
          memberCount: 2,
          canManageMembers: false,
          memberIds: const [_firstPeer],
          activeMemberIds: const {_firstPeer},
          invitedMemberIds: const {},
        ),
      GroupState(
        conversationId: 'conversation-crew',
        title: 'The Crew',
        memberCount: includeNonFriendMember ? 4 : 3,
        canManageMembers: true,
        localRole: JamiGroupMemberRole.admin,
        memberRoles: {
          _firstPeer: JamiGroupMemberRole.member,
          _secondPeer: JamiGroupMemberRole.member,
          if (includeNonFriendMember)
            _nonFriendMember: JamiGroupMemberRole.member,
        },
        memberDisplayNames: includeNonFriendMember
            ? const {_nonFriendMember: 'Nora'}
            : const {},
        memberIds: [
          _firstPeer,
          _secondPeer,
          if (includeNonFriendMember) _nonFriendMember,
        ],
        activeMemberIds: inviteSecond
            ? const {_firstPeer}
            : {
                _firstPeer,
                _secondPeer,
                if (includeNonFriendMember) _nonFriendMember,
              },
        invitedMemberIds: inviteSecond ? const {_secondPeer} : const {},
      ),
    ],
    folderEntries: [
      FolderFile(
        peerId: _firstPeer,
        conversationId: 'conversation-one',
        fileId: 'file-one',
        interactionId: 'interaction-one',
        name: 'holiday-photo.jpg',
        size: 2048,
        outgoing: true,
        downloaded: true,
        timestamp: 1,
      ),
    ],
  );
  state.accountId = 'fixture-account';
  return state;
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required AppState state,
  required Size size,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
  bool listenToState = false,
  TargetPlatform? platform,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: platform == null
          ? Warm.theme()
          : Warm.theme().copyWith(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: listenToState
            ? ListenableBuilder(
                listenable: state,
                builder: (context, _) => HomeScreen(state: state),
              )
            : HomeScreen(state: state),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('desktop empty state centers in full pane with a matte rail', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(
      _LayoutJamiClient(),
      await SharedPreferences.getInstance(),
    )..screen = Screen.home;
    addTearDown(state.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 500);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        builder: (_, child) => WindowsChrome(
          jami: _LayoutJamiClient(),
          renderControls: false,
          child: child!,
        ),
        home: WindowsChromeContent(
          compactContentAvailable: true,
          child: HomeScreen(state: state),
        ),
      ),
    );
    await tester.pump();
    final panel = find.byKey(const ValueKey('no-selected-friend'));
    final content = find.descendant(
      of: panel,
      matching: find.byType(SingleChildScrollView),
    );
    final divider = tester.getRect(
      find.byKey(const ValueKey('desktop-rail-divider')),
    );
    expect(
      tester.getCenter(content).dx,
      closeTo((divider.right + 700) / 2, .01),
    );
    expect(tester.getCenter(content).dy, closeTo(250, .01));
    final rail = find.byType(FriendRail);
    final background = tester.widget<DecoratedBox>(
      find.descendant(of: rail, matching: find.byType(DecoratedBox)).first,
    );
    expect((background.decoration as BoxDecoration).gradient, isNull);
    expect(
      (background.decoration as BoxDecoration).color,
      tester.element(rail).syblColors.desk,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'empty people rail has one action opening first-friend onboarding',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state =
          AppState(_LayoutJamiClient(), await SharedPreferences.getInstance())
            ..displayName = 'You'
            ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            ..accountId = 'fixture-account'
            ..screen = Screen.home
            ..seedCaptureStateForTesting(
              resolved: true,
              applied: WindowCaptureProtectionStatus.exclude,
            );
      addTearDown(state.dispose);
      await _pumpHome(
        tester,
        state: state,
        size: const Size(675, 490),
        platform: TargetPlatform.windows,
      );
      expect(find.byKey(const ValueKey('people-actions-button')), findsNothing);
      expect(find.text('Invite a friend'), findsNothing);
      expect(find.text('Add a friend'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-first-friend')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('connection-name')), findsOneWidget);
      expect(find.text('Your Doorlight'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('connection-name'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('connection-short-id')))
              .dy,
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('connection-name'))).dx,
        tester.getTopLeft(find.byKey(const ValueKey('connection-short-id'))).dx,
      );
      expect(find.byTooltip('Close'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('connection-name')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop settings close from empty sidebar space', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    await _pumpHome(
      tester,
      state: state,
      size: const Size(675, 490),
      platform: TargetPlatform.windows,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('close-settings-button')), findsNothing);
    final sidebar = tester.getRect(
      find.byKey(const ValueKey('desktop-sidebar-dismiss-settings')),
    );
    await tester.tapAt(Offset(sidebar.left + 18, sidebar.bottom - 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-settings')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '700x500 keeps the people rail and selected conversation visible',
    (tester) async {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);

      await _pumpHome(
        tester,
        state: state,
        size: const Size(700, 500),
        platform: TargetPlatform.windows,
      );

      expect(find.byKey(const ValueKey('friend-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('friend-$_firstPeer')), findsOneWidget);
      expect(find.byKey(const ValueKey('friend-$_secondPeer')), findsOneWidget);
      expect(find.text('Phone B'), findsWidgets);
      expect(find.text('Phone A'), findsOneWidget);
      expect(find.text('holiday-photo.jpg'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-call-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-call-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('send-file-button')), findsOneWidget);
      expect(tester.getSize(find.text('Your people')).height, lessThan(26));

      final colors = tester
          .element(find.byKey(const ValueKey('friend-$_firstPeer')))
          .syblColors;
      Color? rowFill(String peerId) =>
          (tester
                      .widget<DecoratedBox>(
                        find.descendant(
                          of: find.byKey(
                            ValueKey('friend-row-background-$peerId'),
                          ),
                          matching: find.byType(DecoratedBox),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      expect(rowFill(_firstPeer), colors.surfaceTop);
      final friendFill = tester.getRect(
        find.byKey(const ValueKey('friend-row-background-$_firstPeer')),
      );
      final friendFrame = tester.getRect(
        find.byKey(const ValueKey('friend-call-ring-$_firstPeer')),
      );
      final groupFill = tester.getRect(
        find.byKey(const ValueKey('group-row-background-conversation-crew')),
      );
      expect(
        friendFill,
        friendFrame,
        reason: 'selection belongs to the row, outside the call ring inset',
      );
      expect(friendFill.height, 58);
      expect(groupFill.height, friendFill.height);
      expect(groupFill.left, friendFill.left);
      expect(groupFill.right, friendFill.right);
      expect(
        rowFill(_secondPeer),
        Colors.transparent,
        reason: 'Unselected rows reveal the shared light field.',
      );

      final peopleActionIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('people-actions-button')),
          matching: find.byType(Icon),
        ),
      );
      expect(peopleActionIcon.color, Colors.black);
      expect(find.byKey(const ValueKey('add-friend-button')), findsNothing);
      expect(find.byKey(const ValueKey('create-group-button')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('people-actions-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('people-action-add-friend')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('people-action-create-group')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('people-action-invite-friend')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final accountCard = tester.getRect(
        find.byKey(const ValueKey('account-card')),
      );
      expect(accountCard.left, 10);
      expect(accountCard.right, SyblLayout.railWidth - 10);
      expect(accountCard.bottom, lessThan(500));

      final composer = tester.getRect(
        find.byKey(const ValueKey('conversation-composer')),
      );
      final attachment = tester.getRect(
        find.byKey(const ValueKey('send-file-button')),
      );
      final send = tester.getRect(
        find.byKey(const ValueKey('send-chat-button')),
      );
      expect(attachment.left - composer.left, lessThanOrEqualTo(8));
      expect(composer.right - send.right, lessThanOrEqualTo(8));

      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Ready',
      );
      await tester.pump();
      final sendIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('send-chat-button')),
          matching: find.byIcon(Icons.arrow_upward_rounded),
        ),
      );
      expect(sendIcon.color, Colors.black);
      expect(tester.takeException(), isNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('desktop-settings')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Online'),
        120,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('settings-list')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ),
      );
      expect(find.text('Online'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a reachable friend offers Notify or Ring before a call', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    await state.selectFriend(_secondPeer);

    await _pumpHome(tester, state: state, size: const Size(700, 500));
    await tester.tap(find.byKey(const ValueKey('voice-call-button')));
    await tester.pumpAndSettle();

    expect(find.text('Call Phone A?'), findsOneWidget);
    expect(
      find.text('They may not have Doorlight open right now.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reachable-call-notify')), findsOneWidget);
    expect(find.byKey(const ValueKey('reachable-call-ring')), findsOneWidget);
  });

  testWidgets('desktop call peer exposes direct controls without moving chat', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'desktop-call',
      dir: CallDir.outgoing,
      peerId: _secondPeer,
      state: 'CURRENT',
    );

    await _pumpHome(tester, state: state, size: const Size(800, 450));

    expect(find.byKey(const ValueKey('friend-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-$_firstPeer')), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-$_secondPeer')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-call-stage')), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('return-to-call-button')), findsNothing);
    expect(find.byKey(const ValueKey('audio-call-strip')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('friend-$_secondPeer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-call-stage')), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-call-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-call-mic')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-call-video')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-call-share')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-call-leave')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'phone incoming banner stays below chat header at text $scale',
      (tester) async {
        final state = await _stateWithFriends();
        addTearDown(state.dispose);
        await _pumpHome(
          tester,
          state: state,
          size: const Size(390, 844),
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
          listenToState: true,
        );
        await tester.tap(find.byKey(const ValueKey('friend-$_firstPeer')));
        await tester.pumpAndSettle();
        state.call = CallSession(
          callId: 'phone-incoming',
          dir: CallDir.incoming,
          peerId: _secondPeer,
          state: 'RINGING',
        );
        state.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final banner = find.byKey(
          const ValueKey('incoming-call-banner-phone-incoming'),
        );
        expect(banner, findsOneWidget);
        expect(
          tester.getRect(banner).top,
          greaterThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey('conversation-header')))
                .bottom,
          ),
        );
        expect(
          find.byKey(const ValueKey('conversation-back-button')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .byKey(const ValueKey('answer-incoming-call-banner'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .byKey(const ValueKey('decline-incoming-call-banner'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('desktop incoming call slides over the current stage', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'desktop-incoming',
      dir: CallDir.incoming,
      peerId: _secondPeer,
      state: 'RINGING',
    );

    await _pumpHome(tester, state: state, size: const Size(800, 450));

    expect(find.byKey(const ValueKey('friend-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-call-stage')), findsNothing);
    expect(
      find.byKey(const ValueKey('incoming-call-banner-desktop-incoming')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('open-incoming-call')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('desktop-call-stage')), findsOneWidget);
    expect(find.text('incoming call'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop video call fits inside the stage without hiding People',
    (tester) async {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'desktop-video',
        dir: CallDir.outgoing,
        peerId: _secondPeer,
        state: 'CURRENT',
        outgoingVideo: const OutgoingVideoSource(
          kind: OutgoingVideoKind.camera,
          revision: 1,
          width: 720,
          height: 1280,
        ),
        peerVideo: true,
      );

      await _pumpHome(tester, state: state, size: const Size(800, 450));

      expect(find.byKey(const ValueKey('friend-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-call-stage')), findsNothing);
      expect(find.byKey(const ValueKey('return-to-call-button')), findsNothing);
      expect(find.byKey(const ValueKey('audio-call-strip')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('friend-$_secondPeer')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('desktop-call-stage')), findsNothing);
      expect(find.byKey(const ValueKey('audio-call-strip')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop portrait preview is contained and opens the call', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'desktop-preview',
      dir: CallDir.outgoing,
      peerId: _secondPeer,
      state: 'CURRENT',
      remoteTextureId: 7,
      remoteActive: true,
      peerVideo: true,
      remoteWidth: 1080,
      remoteHeight: 2400,
    );

    await _pumpHome(tester, state: state, size: const Size(800, 450));

    final preview = find.byKey(const ValueKey('desktop-call-preview'));
    expect(preview, findsOneWidget);
    expect(find.byKey(const ValueKey('audio-call-open-viewer')), findsNothing);
    final ratio = tester.widget<AspectRatio>(
      find.descendant(of: preview, matching: find.byType(AspectRatio)),
    );
    expect(ratio.aspectRatio, closeTo(1080 / 2400, .001));
    final previewRect = tester.getRect(preview);
    expect(previewRect.height, greaterThan(previewRect.width));
    expect(
      previewRect.top,
      greaterThanOrEqualTo(
        tester
            .getRect(find.byKey(const ValueKey('conversation-header')))
            .bottom,
      ),
      reason: 'the minimized preview must leave every header action exposed',
    );

    await tester.tap(preview);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('desktop-call-stage')), findsOneWidget);
  });

  testWidgets('leaving the call surface retires remote control', (
    tester,
  ) async {
    final state =
        await _stateWithFriends(trackRouteRetirement: true)
            as _RouteRetirementState;
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'controlled-call',
      dir: CallDir.outgoing,
      peerId: _secondPeer,
      state: 'CURRENT',
      peerVideo: true,
      peerVideoKind: OutgoingVideoKind.screen,
      remoteTextureId: 7,
      remoteActive: true,
      remoteWidth: 1920,
      remoteHeight: 1080,
    );
    await _pumpHome(tester, state: state, size: const Size(800, 450));
    await tester.tap(find.byKey(const ValueKey('desktop-call-preview')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('friend-$_firstPeer')));
    await tester.pump();
    expect(state.stopRemoteControlCalls, 1);

    await tester.tap(find.byKey(const ValueKey('desktop-call-preview')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('minimize-call-button')));
    await tester.pump();

    expect(state.stopRemoteControlCalls, 2);
  });

  testWidgets('phone width uses people then conversation as separate panes', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(
      tester,
      state: state,
      size: const Size(390, 844),
      disableAnimations: true,
    );

    expect(find.byKey(const ValueKey('compact-people-pane')), findsOneWidget);
    final account = find.byKey(const ValueKey('account-card'));
    final avatar = tester.widget<SyblAvatar>(
      find.descendant(of: account, matching: find.byType(SyblAvatar)),
    );
    expect(avatar.size, 56);
    final name = find.descendant(
      of: account,
      matching: find.text(state.displayName),
    );
    expect(tester.widget<Text>(name).style!.fontSize, 18);
    final status = find.descendant(of: account, matching: find.text('online'));
    expect(tester.widget<Text>(status).style!.fontSize, 14);

    expect(find.byKey(const ValueKey('friend-$_firstPeer')), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-$_secondPeer')), findsOneWidget);
    expect(find.text('Phone B'), findsOneWidget);
    expect(find.text('Phone A'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-call-button')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('friend-$_firstPeer')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('compact-conversation-pane')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-button')),
      findsOneWidget,
    );
    expect(find.text('holiday-photo.jpg'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-call-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('conversation-back-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('compact-people-pane')), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-$_secondPeer')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('open-settings-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('compact-settings-pane')), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Share activity'),
      100,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    expect(find.text('Share activity'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('close-settings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-people-pane')), findsOneWidget);
  });

  testWidgets('system back steps through the phone panes before leaving', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(
      tester,
      state: state,
      size: const Size(390, 844),
      disableAnimations: true,
    );
    // Same path the Android back gesture takes: Navigator.maybePop consults the
    // route's PopScope, and returns false once only the OS can handle it.
    Future<bool> back() async {
      final popped = await Navigator.maybePop(
        tester.element(find.byType(HomeScreen)),
      );
      await tester.pumpAndSettle();
      return popped;
    }

    await tester.tap(find.byKey(const ValueKey('friend-$_firstPeer')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('compact-conversation-pane')),
      findsOneWidget,
    );

    expect(await back(), isTrue, reason: 'back must not leave the app here');
    expect(find.byKey(const ValueKey('compact-people-pane')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-settings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-settings-pane')), findsOneWidget);

    expect(await back(), isTrue);
    expect(find.byKey(const ValueKey('compact-people-pane')), findsOneWidget);

    expect(
      await back(),
      isFalse,
      reason: 'the people pane is home — back leaves the app',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone resume reports only the pane that is on screen', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final state = await _stateWithFriends();

    await _pumpHome(
      tester,
      state: state,
      size: const Size(390, 844),
      disableAnimations: true,
      listenToState: true,
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byKey(const ValueKey('friend-$_firstPeer')));
    await tester.pumpAndSettle();
    expect(state.visibleConversationPeerId, _firstPeer);

    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(state.visibleConversationPeerId, isNull);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(state.visibleConversationPeerId, _firstPeer);

    await Navigator.maybePop(tester.element(find.byType(HomeScreen)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-people-pane')), findsOneWidget);
    expect(state.visibleConversationPeerId, isNull);

    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(state.visibleConversationPeerId, isNull);
    expect(tester.takeException(), isNull);
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('rooms-first mobile groups open the room list before a topic', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.appSettings = AppSettings(
      mobileGroupNavigation: MobileGroupNavigation.roomsFirst,
    );

    await _pumpHome(
      tester,
      state: state,
      size: const Size(390, 844),
      disableAnimations: true,
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile-group-room-browser')),
      findsOneWidget,
    );
    expect(find.text('TOPICS'), findsOneWidget);
    expect(find.text('VOICE CHATS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-composer-conversation-crew')),
      findsNothing,
    );
    expect(
      state.visibleConversationPeerId,
      isNull,
      reason: 'the room list is not a visible topic',
    );

    await tester.tap(find.byKey(const ValueKey('group-topic-games')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile-group-room-browser')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('mobile-group-topic-header')),
      findsOneWidget,
    );
    expect(find.text('games'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-composer-conversation-crew')),
      findsOneWidget,
    );
    expect(state.visibleConversationPeerId, 'group:conversation-crew');
    expect(state.visibleGroupTopicId, 'games');

    await tester.tap(find.byKey(const ValueKey('mobile-group-topic-back')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile-group-room-browser')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-composer-conversation-crew')),
      findsNothing,
    );
    expect(state.visibleConversationPeerId, isNull);
    expect(state.visibleGroupTopicId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline mobile group topics overlay the shared surface', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(
      tester,
      state: state,
      size: const Size(390, 844),
      disableAnimations: true,
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    final timeline = tester.getRect(
      find.byKey(const ValueKey('group-messages-general')),
    );
    final surface = tester.getRect(
      find.byKey(const ValueKey('topic-strip-surface')),
    );
    expect(surface.top, timeline.top);
    expect(find.byKey(const ValueKey('group-topic-general')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-topic-games')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '390x844 mobile people and conversation remain usable at 200% text',
    (tester) async {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);

      await _pumpHome(
        tester,
        state: state,
        size: const Size(390, 844),
        textScaler: const TextScaler.linear(2),
        disableAnimations: true,
      );

      expect(tester.takeException(), isNull);
      for (final key in [
        const ValueKey('friend-$_firstPeer'),
        const ValueKey('friend-$_secondPeer'),
      ]) {
        expect(
          tester.getSize(find.byKey(key)).height,
          greaterThanOrEqualTo(48),
        );
      }

      await tester.tap(find.byKey(const ValueKey('friend-$_firstPeer')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('compact-conversation-pane')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(find.text('holiday-photo.jpg'), findsOneWidget);
      for (final key in [
        const ValueKey('conversation-back-button'),
        const ValueKey('voice-call-button'),
        const ValueKey('video-call-button'),
        const ValueKey('send-file-button'),
        const ValueKey('voice-record-button'),
      ]) {
        final target = find.byKey(key);
        expect(target, findsOneWidget);
        final size = tester.getSize(target);
        expect(
          size.width,
          greaterThanOrEqualTo(48),
          reason: '$key width was ${size.width}',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(48),
          reason: '$key height was ${size.height}',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('friend and call controls expose meaningful semantics', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    final semantics = tester.ensureSemantics();

    await _pumpHome(
      tester,
      state: state,
      size: const Size(700, 500),
      textScaler: const TextScaler.linear(1.5),
    );

    expect(find.bySemanticsLabel(RegExp('Phone B.*online')), findsWidgets);
    expect(
      find.bySemanticsLabel(RegExp('Phone A.*Using Team Fortress 2')),
      findsWidgets,
    );
    final phoneIcons = tester.widgetList<Icon>(
      find.byIcon(Icons.phone_iphone_rounded),
    );
    expect(phoneIcons, isNotEmpty);
    expect(
      phoneIcons.every(
        (icon) =>
            icon.color ==
            tester
                .element(find.byIcon(Icons.phone_iphone_rounded).first)
                .syblColors
                .online,
      ),
      isTrue,
    );
    expect(find.bySemanticsLabel(RegExp('111111|222222')), findsNothing);
    expect(find.bySemanticsLabel('Start voice call'), findsWidgets);
    expect(find.bySemanticsLabel('Start video call'), findsWidgets);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('unknown presence displays offline without changing its state', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    const unknown = FriendState(
      peerId: _firstPeer,
      confirmed: true,
      conversationId: 'conversation-one',
      displayName: 'Phone B',
    );
    expect(friendPresenceLabel(state, unknown), 'offline');
    expect(unknown.presence, PeerPresence.unknown);
  });

  testWidgets('offline presence uses a neutral hollow badge', (tester) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    const offline = FriendState(
      peerId: _firstPeer,
      confirmed: true,
      conversationId: 'conversation-one',
      displayName: 'Phone B',
      presence: PeerPresence.unreachable,
      presencePlatform: 'android',
    );

    await _pumpHome(tester, state: state, size: const Size(900, 600));
    final context = tester.element(find.byType(HomeScreen));

    expect(friendPresenceIcon(offline), Icons.circle_outlined);
    expect(
      friendPresenceColor(context, state, offline),
      context.syblColors.faint,
    );
  });

  testWidgets('phone presence keeps a larger outlined phone proportion', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(700, 500));

    final phone = find.byKey(const ValueKey('phone-presence-badge')).first;
    final round = find.byKey(const ValueKey('round-presence-badge')).first;
    expect(tester.getSize(phone), const Size(13, 16));
    expect(tester.getSize(round), const Size(11, 11));
    final decoration = tester.widget<DecoratedBox>(phone).decoration;
    expect(decoration, isA<BoxDecoration>());
    expect((decoration as BoxDecoration).shape, BoxShape.rectangle);
    expect(decoration.borderRadius, BorderRadius.circular(4.5));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.phone_iphone_rounded).first).size,
      11,
    );
  });

  testWidgets('trailing unread badge is more prominent than the avatar badge', (
    tester,
  ) async {
    final state = await _stateWithFriends(
      friendActivity: const FriendActivity(unreadMessages: 7, unreadFiles: 1),
    );
    addTearDown(state.dispose);
    state.appSettings = AppSettings(
      unreadBadgePlacement: UnreadBadgePlacement.trailing,
    );

    await _pumpHome(tester, state: state, size: const Size(700, 500));

    final trailing = find.descendant(
      of: find.byKey(const ValueKey('friend-$_secondPeer')),
      matching: find.byKey(const ValueKey('trailing-unread-badge')),
    );
    expect(trailing, findsOneWidget);
    final trailingSize = tester.getSize(trailing);
    expect(trailingSize.width, greaterThanOrEqualTo(24));
    expect(trailingSize.height, greaterThanOrEqualTo(22));

    state.appSettings = AppSettings(
      unreadBadgePlacement: UnreadBadgePlacement.avatar,
    );
    await _pumpHome(tester, state: state, size: const Size(700, 500));

    final avatar = find.descendant(
      of: find.byKey(const ValueKey('friend-$_secondPeer')),
      matching: find.byKey(const ValueKey('avatar-unread-badge')),
    );
    expect(avatar, findsOneWidget);
    final avatarSize = tester.getSize(avatar);
    expect(trailingSize.width, greaterThan(avatarSize.width));
    expect(trailingSize.height, greaterThan(avatarSize.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets('people menu exposes the existing invite flow', (tester) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(700, 500));
    await tester.tap(find.byKey(const ValueKey('people-actions-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('people-action-invite-friend')));
    await tester.pumpAndSettle();

    expect(find.text('Invite a friend'), findsOneWidget);
    expect(find.byType(FriendInviteQr), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected group has no paint seam at the mini column edge', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 500);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
        ),
        home: RepaintBoundary(
          key: boundary,
          child: HomeScreen(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pump();

    Future<void> expectContinuousFill() async {
      final rail = tester.getRect(
        find.byKey(const ValueKey('desktop-group-mini-rail')),
      );
      // Sample above the avatar and label, inside the selected row's fill.
      final y =
          (tester
                      .getRect(
                        find.byKey(const ValueKey('group-conversation-crew')),
                      )
                      .top +
                  4)
              .floor();
      final pixels = await tester.runAsync(() async {
        final shot = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
            .toImage();
        final data = await shot.toByteData(format: ImageByteFormat.rawRgba);
        shot.dispose();
        return data!;
      });
      for (var channel = 0; channel < 4; channel++) {
        int at(int x) =>
            pixels!.getUint8((y * 700 + rail.left.floor() + x) * 4 + channel);
        expect(
          at(54),
          at(62),
          reason: 'selected fill must not split at the 58px icon column',
        );
      }
    }

    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
      await expectContinuousFill();
    }
    await tester.tap(find.byKey(ValueKey('friend-mini-$_firstPeer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await expectContinuousFill();
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'desktop group transition keeps avatars round and expands once at scale $scale',
      (tester) async {
        final state = await _stateWithFriends(twoGroups: true);
        addTearDown(state.dispose);

        await _pumpHome(
          tester,
          state: state,
          size: Size(700, scale == 1 ? 500 : 800),
          textScaler: TextScaler.linear(scale),
        );
        final peopleAvatarRects = {
          for (final peerId in [_firstPeer, _secondPeer])
            peerId: tester.getRect(_friendAvatar(peerId, mini: false)),
        };
        final peopleGroupAvatarRect = tester.getRect(_groupAvatar(mini: false));
        Finder weekendAvatar({required bool mini}) => find.descendant(
          of: find.byKey(
            ValueKey(
              mini
                  ? 'group-mini-conversation-weekend'
                  : 'group-conversation-weekend',
            ),
          ),
          matching: find.byType(GroupAvatar),
        );
        final peopleWeekendAvatarRect = tester.getRect(
          weekendAvatar(mini: false),
        );
        final overflow = find.byKey(
          const ValueKey('group-avatar-overflow-conversation-crew'),
        );
        final groupAvatar = find.ancestor(
          of: overflow,
          matching: find.byType(GroupAvatar),
        );
        expect(overflow, findsOneWidget);
        final avatarRect = tester.getRect(groupAvatar);
        final overflowRect = tester.getRect(overflow);
        expect(overflowRect.right, greaterThanOrEqualTo(avatarRect.right - 3));
        expect(
          overflowRect.bottom,
          greaterThanOrEqualTo(avatarRect.bottom - 3),
        );

        await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
        await tester.pump();
        final startWidth = tester.getSize(find.byType(GroupStage)).width;
        await tester.pump(const Duration(milliseconds: 110));

        expect(
          find.byKey(const ValueKey('desktop-people-rail-layer')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('desktop-mini-rail-layer')),
          findsOneWidget,
        );
        final peopleAlpha = tester
            .widget<Opacity>(
              find.byKey(const ValueKey('desktop-people-rail-layer')),
            )
            .opacity;
        final miniAlpha = tester
            .widget<Opacity>(
              find.byKey(const ValueKey('desktop-mini-rail-layer')),
            )
            .opacity;
        expect(
          miniAlpha + peopleAlpha * (1 - miniAlpha),
          1,
          reason:
              'the avatar column must remain covered throughout the handoff',
        );
        expect(
          find.byKey(const ValueKey('group-topic-general')),
          findsOneWidget,
        );
        for (final avatar in tester.widgetList<SyblAvatar>(
          find.byType(SyblAvatar),
        )) {
          final size = tester.getSize(find.byWidget(avatar));
          expect(size.width, closeTo(size.height, .01));
        }
        expect(
          tester.getRect(_groupAvatar(mini: true)),
          peopleGroupAvatarRect,
          reason: 'the group avatar must not jump while the rail collapses',
        );
        // The single account portrait moves continuously from the card's inset to
        // the mini rail's center; it must not swap to a second portrait midway.
        final profile = tester.widget<RailProfileAvatar>(
          find.byKey(const ValueKey('desktop-shared-profile')),
        );
        expect(
          tester.getRect(_selfAvatar(mini: true)),
          Rect.lerp(
            tester.getRect(find.byKey(profile.start)),
            tester.getRect(find.byKey(profile.end, skipOffstage: false)),
            profile.progress,
          ),
        );
        final miniRailRect = tester.getRect(
          find.byKey(const ValueKey('desktop-group-mini-rail')),
        );
        for (final avatar in [
          _friendAvatar(_firstPeer, mini: true),
          _groupAvatar(mini: true),
        ]) {
          expect(
            tester.getRect(avatar).center.dx,
            miniRailRect.left + 29,
            reason: 'mini avatars stay in the fixed 58px icon column',
          );
        }
        final middleWidth = tester.getSize(find.byType(GroupStage)).width;
        expect(middleWidth, greaterThan(startWidth));

        await tester.pumpAndSettle();
        expect(
          state.visibleConversationPeerId,
          'group:conversation-crew',
          reason: 'the visible topic must report its group owner route',
        );
        expect(state.visibleGroupTopicId, 'general');
        final endWidth = tester.getSize(find.byType(GroupStage)).width;
        expect(endWidth, greaterThan(middleWidth));
        for (final peerId in [_firstPeer, _secondPeer]) {
          expect(
            tester.getRect(_friendAvatar(peerId, mini: true)),
            peopleAvatarRects[peerId],
            reason: '$peerId must not jump when the people rail collapses',
          );
        }
        expect(tester.getRect(_groupAvatar(mini: true)), peopleGroupAvatarRect);
        expect(
          tester.getRect(weekendAvatar(mini: true)),
          peopleWeekendAvatarRect,
          reason: 'later group rows retain their scaled position too',
        );
        expect(
          tester.getRect(_selfAvatar(mini: true)).center.dy,
          tester
              .getRect(find.byKey(const ValueKey('group-mini-settings')))
              .center
              .dy,
        );

        await tester.tap(find.byKey(ValueKey('friend-mini-$_firstPeer')));
        for (final elapsed in const [
          Duration.zero,
          Duration(milliseconds: 70),
        ]) {
          await tester.pump(elapsed);
          final peopleLayer = find.byKey(
            const ValueKey('desktop-people-rail-layer'),
          );
          final miniLayer = find.byKey(
            const ValueKey('desktop-mini-rail-layer'),
          );
          expect(peopleLayer, findsOneWidget);
          expect(miniLayer, findsOneWidget);
          expect(
            tester.getRect(_friendAvatar(_firstPeer, mini: false)),
            tester.getRect(_friendAvatar(_firstPeer, mini: true)),
          );
          expect(
            tester.widget<Opacity>(miniLayer).opacity +
                tester.widget<Opacity>(peopleLayer).opacity *
                    (1 - tester.widget<Opacity>(miniLayer).opacity),
            1,
            reason: 'the avatar column must stay visible when expanding',
          );
        }
        await tester.pumpAndSettle();
        expect(
          tester.getRect(_friendAvatar(_firstPeer, mini: false)),
          peopleAvatarRects[_firstPeer],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('rail icons remain visible through interrupted group transitions', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    await _pumpHome(tester, state: state, size: const Size(700, 500));
    final peopleRail = find.byKey(const ValueKey('desktop-people-rail'));
    final peopleElement = tester.element(peopleRail);
    final avatarState = tester.state(_friendAvatar(_firstPeer, mini: false));
    double miniOpacity() => tester
        .widget<Opacity>(find.byKey(const ValueKey('desktop-mini-rail-layer')))
        .opacity;
    void assertContinuity() {
      final people = tester
          .widget<Opacity>(
            find.byKey(const ValueKey('desktop-people-rail-layer')),
          )
          .opacity;
      final mini = miniOpacity();
      expect(mini + people * (1 - mini), closeTo(1, .0001));
      expect(tester.element(peopleRail), same(peopleElement));
      expect(
        tester.state(_friendAvatar(_firstPeer, mini: false)),
        same(avatarState),
      );
      expect(tester.takeException(), isNull);
    }

    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pump();
    var previous = 0.0;
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      assertContinuity();
      expect(miniOpacity(), greaterThanOrEqualTo(previous));
      previous = miniOpacity();
    }
    // Reverse before collapse finishes; neither layer may disappear or remount.
    await tester.tap(find.byKey(ValueKey('friend-mini-$_firstPeer')));
    await tester.pump();
    expect(miniOpacity(), closeTo(previous, .0001));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      assertContinuity();
      expect(miniOpacity(), lessThanOrEqualTo(previous));
      previous = miniOpacity();
    }
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pump();
    for (var frame = 0; frame < 18; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      assertContinuity();
    }
    expect(miniOpacity(), 1);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'one decoded profile picture survives reversal at scale $scale',
      (tester) async {
        final state = await _stateWithFriends();
        addTearDown(state.dispose);
        state.profileAvatarBase64 = base64Encode(
          image.encodePng(
            image.fill(
              image.Image(width: 32, height: 32),
              color: image.ColorRgb8(40, 150, 230),
            ),
          ),
        );
        await _pumpHome(
          tester,
          state: state,
          size: const Size(700, 500),
          textScaler: TextScaler.linear(scale),
        );
        await tester.pumpAndSettle();
        bool miniTicks() => TickerMode.valuesOf(
          tester.element(
            find.byKey(
              const ValueKey('desktop-group-mini-rail'),
              skipOffstage: false,
            ),
          ),
        ).enabled;
        expect(miniTicks(), isFalse);
        final portrait = find.descendant(
          of: find.byKey(const ValueKey('desktop-sidebar-dismiss-settings')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is SyblAvatar &&
                widget.imageBase64 == state.profileAvatarBase64,
          ),
        );
        final portraitState = tester.state(portrait);
        final photo = find.descendant(
          of: portrait,
          matching: find.byType(Image),
        );
        final provider = tester.widget<Image>(photo).image;
        final start = tester.getRect(portrait);
        void checkFrame() {
          expect(portrait, findsOneWidget);
          expect(tester.state(portrait), same(portraitState));
          expect(tester.widget<Image>(photo).image, provider);
          final profile = tester.widget<RailProfileAvatar>(
            find.byType(RailProfileAvatar),
          );
          final expected = Rect.lerp(
            tester.getRect(find.byKey(profile.start)),
            tester.getRect(find.byKey(profile.end, skipOffstage: false)),
            profile.progress,
          )!;
          final actual = tester.getRect(portrait);
          expect(actual.left, closeTo(expected.left, .000001));
          expect(actual.top, closeTo(expected.top, .000001));
          expect(actual.width, closeTo(expected.width, .000001));
          expect(actual.height, closeTo(expected.height, .000001));
          expect(
            actual.center.dy,
            closeTo(start.center.dy, .000001),
            reason: 'collapsing the rail must not lower the profile portrait',
          );
          for (final opacity in tester.widgetList<Opacity>(
            find.ancestor(of: portrait, matching: find.byType(Opacity)),
          )) {
            expect(opacity.opacity, 1);
          }
          expect(tester.takeException(), isNull);
        }

        await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          checkFrame();
        }
        await tester.tap(find.byKey(ValueKey('friend-mini-$_firstPeer')));
        await tester.pump();
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          checkFrame();
        }
        expect(tester.getRect(portrait), start);
        await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
        await tester.pumpAndSettle();
        checkFrame();
        expect(miniTicks(), isTrue);
        expect(
          tester.getRect(portrait).center,
          tester
              .getRect(find.byKey(const ValueKey('group-mini-settings')))
              .center,
        );
      },
    );
  }

  testWidgets('a portrait entering from a call dock does not pop in opaque', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.profileAvatarBase64 = base64Encode(
      image.encodePng(
        image.fill(
          image.Image(width: 32, height: 32),
          color: image.ColorRgb8(40, 150, 230),
        ),
      ),
    );
    final absentCard = GlobalKey();
    final mini = GlobalKey();
    final boundary = GlobalKey();
    Future<int> blueAt(double progress) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Center(
            child: SizedBox.square(
              dimension: 100,
              child: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 10,
                        top: 10,
                        child: SizedBox.square(key: mini, dimension: 38),
                      ),
                      Positioned.fill(
                        child: RailProfileAvatar(
                          state: state,
                          start: absentCard,
                          end: mini,
                          progress: progress,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bytes = await tester.runAsync(() async {
        final shot = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
            .toImage();
        final rgba = await shot.toByteData(format: ImageByteFormat.rawRgba);
        shot.dispose();
        return rgba!;
      });
      return bytes!.getUint8((29 * 100 + 29) * 4 + 2);
    }

    expect(await blueAt(0), 0);
    expect(await blueAt(.25), inInclusiveRange(55, 60));
    expect(await blueAt(1), 230);
  });

  testWidgets('desktop account card keeps its last good geometry', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(700, 500));
    final accountCard = find.byKey(const ValueKey('account-card'));
    final avatar = _selfAvatar(mini: false);

    expect(tester.getSize(accountCard).height, 59);
    expect(
      tester.getRect(avatar).left,
      greaterThan(tester.getRect(accountCard).left),
    );
  });

  testWidgets('desktop account card keeps its rounded clip', (tester) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(700, 500));
    final cardMaterial = find
        .descendant(
          of: find.byKey(const ValueKey('account-card')),
          matching: find.byType(Material),
        )
        .first;

    expect(tester.widget<Material>(cardMaterial).clipBehavior, Clip.antiAlias);
  });

  testWidgets('desktop fixes the group call dock below the room list', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    state.displayName = 'Peer';
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    state.groupCall = GroupCallSession(
      conversationId: 'conversation-crew',
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      sessionId: 'session42',
      phase: GroupCallPhase.connected,
    );
    addTearDown(state.dispose);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await _pumpHome(tester, state: state, size: const Size(900, 600));
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-topic-voice')), findsOneWidget);
    final sidebar = find.byKey(const ValueKey('group-topic-sidebar'));
    final dock = find.byKey(const ValueKey('group-call-dock'));
    expect(dock, findsOneWidget);
    expect(find.byKey(const ValueKey('group-voice-controls')), findsNothing);
    expect(tester.getBottomLeft(dock).dy, tester.getBottomLeft(sidebar).dy);
    expect(find.text('Voice connected'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-card')), findsNothing);
    expect(find.byKey(const ValueKey('group-mini-settings')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-call-dock-account')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dock, matching: find.byType(SyblAvatar)),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('group-mic-split-control')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-call-dock-transition')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('voice-participant-transition-${state.jamiId}')),
      findsOneWidget,
    );
    expect(find.text('Os…'), findsNothing);
    expect(
      find.descendant(of: dock, matching: find.byTooltip('Start camera')),
      findsNothing,
    );
    expect(
      find.descendant(of: dock, matching: find.byTooltip('Share screen')),
      findsNothing,
    );
    expect(
      find.descendant(of: dock, matching: find.byTooltip('Output')),
      findsNothing,
    );
    final leave = tester.widget<IconButton>(
      find.byKey(const ValueKey('group-voice-leave')),
    );
    expect(leave.style?.side?.resolve(<WidgetState>{}), isNotNull);
    expect(leave.style?.backgroundColor?.resolve(<WidgetState>{}), isNotNull);
    expect(
      find.byKey(const ValueKey('group-mic-mode-chevron')),
      findsOneWidget,
    );
    expect(find.text('Group voice is not available yet.'), findsNothing);
    state.groupCall!.sourceChanging = true;
    await tester.tap(find.byTooltip('Open call'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('group-call-screen')), findsOneWidget);
    final cameraControl = find.byKey(
      const ValueKey('group-call-camera-control'),
    );
    expect(
      find.descendant(
        of: cameraControl,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('Starting camera…'), findsOneWidget);
    final outputControl = find.byKey(
      const ValueKey('group-call-output-control'),
    );
    expect(outputControl, findsOneWidget);
    expect(
      find.descendant(
        of: outputControl,
        matching: find.byIcon(Icons.volume_up_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: outputControl,
        matching: find.byIcon(Icons.hearing_rounded),
      ),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('rooms-first mobile fixes the group call dock below rooms', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    state.appSettings = AppSettings(
      mobileGroupNavigation: MobileGroupNavigation.roomsFirst,
    );
    state.groupCall = GroupCallSession(
      conversationId: 'conversation-crew',
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      sessionId: 'session42',
      phase: GroupCallPhase.connected,
    );
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    final browser = find.byKey(const ValueKey('mobile-group-room-browser'));
    final dock = find.byKey(const ValueKey('group-call-dock'));
    expect(dock, findsOneWidget);
    expect(
      find.byKey(const ValueKey('global-group-voice-panel')),
      findsNothing,
    );
    expect(tester.getBottomLeft(dock).dy, tester.getBottomLeft(browser).dy);
    expect(find.byTooltip('Mute'), findsOne);
    expect(find.byTooltip('Deafen'), findsOne);
    expect(find.byTooltip('Start camera'), findsOne);
    expect(find.byTooltip('Share screen'), findsOne);
    expect(find.byTooltip('Earpiece'), findsOne);
    expect(find.byTooltip('Open call'), findsOne);
    expect(find.byTooltip('Leave voice'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'group call replaces the desktop profile card while browsing DMs',
    (tester) async {
      final state = await _stateWithFriends();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      state.groupCall = GroupCallSession(
        conversationId: 'conversation-crew',
        roomId: 'voice',
        conferenceId: 'syblv1-voice-42',
        sessionId: 'session42',
        phase: GroupCallPhase.connected,
      );
      addTearDown(state.dispose);

      await _pumpHome(tester, state: state, size: const Size(900, 600));
      debugDefaultTargetPlatformOverride = null;

      expect(find.byKey(const ValueKey('group-call-dock')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-card')), findsNothing);
      expect(find.text('Voice connected'), findsOneWidget);
      expect(find.text('The Crew / voice'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('global-group-voice-panel')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('group-call-dock-account')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group video preview opens the group call screen', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    state.groupCall = GroupCallSession(
      conversationId: 'conversation-crew',
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      sessionId: 'session42',
      phase: GroupCallPhase.connected,
      videoActive: true,
      videoWidth: 1280,
      videoHeight: 720,
      videoTextureId: 99,
      focusedStreamKey: '$_firstPeer\u0000${'d' * 64}\u0000peer-video_0',
      conference: GroupConferenceSnapshot.fromWire([
        {
          'uri': _firstPeer,
          'device': 'd' * 64,
          'sinkId': 'peer-video_0',
          'w': '1280',
          'h': '720',
          'videoMuted': 'false',
        },
      ]),
    );
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(900, 600));
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-call-preview')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-call-preview')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-call-screen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-call-grid-control')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey(
          'group-call-stream-$_firstPeer\u0000${'d' * 64}\u0000peer-video_0',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-call-camera-control')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-call-share-control')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-call-leave-control')),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile group video preview starts below inline topics', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    state.groupCall = GroupCallSession(
      conversationId: 'conversation-crew',
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      sessionId: 'session42',
      phase: GroupCallPhase.connected,
      videoActive: true,
      videoWidth: 1280,
      videoHeight: 720,
    );
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('group-call-preview'))).dy,
      greaterThanOrEqualTo(
        tester
            .getBottomLeft(find.byKey(const ValueKey('group-topic-general')))
            .dy,
      ),
    );
  });

  testWidgets('group mini rail marks both sides of the current call', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);

    await _pumpHome(tester, state: state, size: const Size(700, 500));
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    final peerAvatar = _friendAvatar(_firstPeer, mini: true);
    final otherAvatar = _friendAvatar(_secondPeer, mini: true);
    final selfAvatar = _selfAvatar(mini: true);
    final peerRect = tester.getRect(peerAvatar);
    final otherRect = tester.getRect(otherAvatar);
    final selfRect = tester.getRect(selfAvatar);
    final selfFrameRect = tester.getRect(_selfCallRing);

    // Nothing is outlined before a call exists.
    for (final frame in [_selfCallRing, _peerCallRing(_firstPeer)]) {
      expect(_paintedRing(tester, frame).gradient, isNull);
    }

    Future<void> pumpCall(String callState) async {
      state.call = CallSession(
        callId: 'mini-call',
        dir: CallDir.outgoing,
        peerId: _firstPeer,
        state: callState,
        microphonePolicyApplied: true,
      );
      await _pumpHome(tester, state: state, size: const Size(700, 500));
      await _settleRing(tester);
    }

    await pumpCall('CONNECTING');
    for (final frame in [_selfCallRing, _peerCallRing(_firstPeer)]) {
      final ring = _paintedRing(tester, frame);
      expect(ring.gradient, isA<SweepGradient>(), reason: '$frame');
      expect(ring.color, isNull, reason: 'a flat fill would hide the gradient');
      expect(_ringAlpha(ring).min, lessThan(.35), reason: 'a segment, $frame');
      expect(_ringAlpha(ring).max, greaterThan(.65), reason: 'is lit, $frame');
    }
    expect(_paintedRing(tester, _peerCallRing(_secondPeer)).gradient, isNull);

    await pumpCall('CURRENT');
    for (final frame in [_selfCallRing, _peerCallRing(_firstPeer)]) {
      final ring = _paintedRing(tester, frame);
      expect(ring.gradient, isA<SweepGradient>(), reason: '$frame');
      expect(
        _ringAlpha(ring).min,
        greaterThan(.95),
        reason: 'a complete outline, $frame',
      );
    }
    expect(_paintedRing(tester, _peerCallRing(_secondPeer)).gradient, isNull);

    // Nothing moved, and the self outline stays inside the collapsed rail.
    expect(tester.getRect(peerAvatar), peerRect);
    expect(tester.getRect(otherAvatar), otherRect);
    expect(tester.getRect(selfAvatar), selfRect);
    expect(tester.getRect(_selfCallRing), selfFrameRect);
    final rail = tester.getRect(find.byType(GroupMiniRail));
    expect(
      rail.contains(selfFrameRect.topLeft) &&
          rail.contains(selfFrameRect.bottomRight - const Offset(.01, .01)),
      isTrue,
      reason:
          'the 58 px rail hard-clips anything it does not contain: '
          '$selfFrameRect vs $rail',
    );

    // Ending the call clears both outlines with nothing frozen behind.
    state.call = null;
    await _pumpHome(tester, state: state, size: const Size(700, 500));
    await _settleRing(tester);
    for (final frame in [_selfCallRing, _peerCallRing(_firstPeer)]) {
      expect(_paintedRing(tester, frame).gradient, isNull, reason: '$frame');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the call peer is outlined in the people rail, nobody else is', (
    tester,
  ) async {
    for (final size in const [Size(1280, 800), Size(390, 844)]) {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);
      await _pumpHome(tester, state: state, size: size);

      final peerRow = _rowCallRing(_firstPeer);
      final otherRow = _rowCallRing(_secondPeer);
      final peerRect = tester.getRect(peerRow);
      final avatarRect = tester.getRect(_friendAvatar(_firstPeer, mini: false));
      expect(_paintedRing(tester, peerRow).gradient, isNull, reason: '$size');

      Future<void> pumpCall(String callState) async {
        state.call = CallSession(
          callId: 'row-call',
          dir: CallDir.outgoing,
          peerId: _firstPeer,
          state: callState,
        );
        await _pumpHome(tester, state: state, size: size);
        await _settleRing(tester);
      }

      await pumpCall('RINGING');
      final connecting = _paintedRing(tester, peerRow);
      expect(connecting.gradient, isA<SweepGradient>(), reason: '$size');
      expect(_ringAlpha(connecting).min, lessThan(.35), reason: '$size');
      expect(_ringAlpha(connecting).max, greaterThan(.65), reason: '$size');
      expect(_paintedRing(tester, otherRow).gradient, isNull, reason: '$size');

      await pumpCall('CURRENT');
      expect(
        _ringAlpha(_paintedRing(tester, peerRow)).min,
        greaterThan(.95),
        reason: '$size',
      );
      expect(_paintedRing(tester, otherRow).gradient, isNull, reason: '$size');

      // The outline comes out of the row's own padding, never out of layout.
      expect(tester.getRect(peerRow), peerRect, reason: '$size');
      expect(
        tester.getRect(_friendAvatar(_firstPeer, mini: false)),
        avatarRect,
        reason: '$size',
      );

      state.call = null;
      await _pumpHome(tester, state: state, size: size);
      await _settleRing(tester);
      expect(_paintedRing(tester, peerRow).gradient, isNull, reason: '$size');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('connecting to connected fills the ring in without a gap', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'fill-in',
      dir: CallDir.outgoing,
      peerId: _firstPeer,
      state: 'CONNECTING',
    );
    await _pumpHome(tester, state: state, size: const Size(1280, 800));
    await _settleRing(tester);

    final row = _rowCallRing(_firstPeer);
    expect(_ringAlpha(_paintedRing(tester, row)).min, lessThan(.35));

    state.call = CallSession(
      callId: 'fill-in',
      dir: CallDir.outgoing,
      peerId: _firstPeer,
      state: 'CURRENT',
    );
    await _pumpHome(tester, state: state, size: const Size(1280, 800));
    // Halfway through the 180 ms swap: the rendered decoration, not the
    // AnimatedContainer's target, is what a fade-out-then-pop would show.
    await tester.pump(const Duration(milliseconds: 90));
    final mid = _paintedRing(tester, row);
    expect(mid.gradient, isA<SweepGradient>());
    expect(mid.color, isNull);
    final midAlpha = _ringAlpha(mid);
    expect(
      midAlpha.min,
      greaterThan(0),
      reason: 'the ring is filling in, not fading out',
    );
    expect(midAlpha.min, lessThan(.95), reason: 'and has not popped yet');
    expect(midAlpha.max, greaterThan(.95), reason: 'the segment stays lit');

    await _settleRing(tester);
    expect(_ringAlpha(_paintedRing(tester, row)).min, greaterThan(.95));
    expect(tester.takeException(), isNull);
  });

  testWidgets('calling outline advances at constant speed on phone and PC', (
    tester,
  ) async {
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'constant-$size',
        dir: CallDir.outgoing,
        peerId: _firstPeer,
        state: 'CONNECTING',
      );
      await _pumpHome(tester, state: state, size: size);
      final ring = _rowCallRing(_firstPeer);
      final angles = <double>[_ringAngle(tester, ring)];
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        angles.add(_ringAngle(tester, ring));
      }
      final deltas = [
        for (var index = 1; index < angles.length; index++)
          angles[index] - angles[index - 1],
      ];
      expect(deltas[1], closeTo(deltas[0], .001), reason: '$size');
      expect(deltas[2], closeTo(deltas[0], .001), reason: '$size');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('reduced motion keeps the segment visible but still', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'still',
      dir: CallDir.outgoing,
      peerId: _firstPeer,
      state: 'CONNECTING',
    );
    await _pumpHome(
      tester,
      state: state,
      size: const Size(1280, 800),
      disableAnimations: true,
    );

    final row = _rowCallRing(_firstPeer);
    final first = _paintedRing(tester, row).gradient! as SweepGradient;
    await tester.pump(const Duration(milliseconds: 900));
    final later = _paintedRing(tester, row).gradient! as SweepGradient;
    expect(_ringAlpha(_paintedRing(tester, row)).max, greaterThan(.95));
    expect(
      later.transform,
      first.transform,
      reason: 'the segment must not move',
    );
    // A repeating controller would never let the tree go idle.
    await tester.pumpAndSettle();

    state.call = CallSession(
      callId: 'still',
      dir: CallDir.outgoing,
      peerId: _firstPeer,
      state: 'CURRENT',
    );
    await _pumpHome(
      tester,
      state: state,
      size: const Size(1280, 800),
      disableAnimations: true,
    );
    expect(_ringAlpha(_paintedRing(tester, row)).min, greaterThan(.95));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop groups keep friends in the mini rail and reuse DM controls',
    (tester) async {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);

      await _pumpHome(
        tester,
        state: state,
        size: const Size(800, 600),
        platform: TargetPlatform.windows,
      );
      await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('desktop-group-mini-rail')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('friend-mini-$_firstPeer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('friend-mini-$_secondPeer')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('group-topic-general')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-call-button')), findsNothing);
      expect(find.text('TOPICS'), findsOneWidget);
      expect(find.text('# general'), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('group-header'))).left,
        greaterThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('group-topic-sidebar')))
              .right,
        ),
      );
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(find.byKey(const ValueKey('send-file-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('send-chat-button')), findsOneWidget);
      expect(find.text('+1'), findsWidgets);
      expect(tester.takeException(), isNull);

      final palette = SyblColors.of(
        tester.element(find.byKey(const ValueKey('desktop-group-mini-rail'))),
      );
      final miniRail = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byKey(const ValueKey('desktop-group-mini-rail')),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      final topicRail = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('group-topic-sidebar')),
      );
      final chat = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('group-conversation-surface')),
      );
      expect(miniRail.color, palette.desk);
      expect(topicRail.color, palette.surface);
      expect(chat.color, Colors.transparent);
      final surface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('onboarding-warm-surface')),
      );
      expect((surface.decoration as BoxDecoration).color, palette.bg);
      expect(
        tester
            .widget<CustomPaint>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('onboarding-warm-surface')),
                    matching: find.byType(CustomPaint),
                  )
                  .first,
            )
            .painter,
        isNotNull,
        reason: 'The conversation reveals the shared lit background.',
      );
      expect({miniRail.color, topicRail.color, chat.color}, hasLength(3));
      final selected = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('group-mini-selection-conversation-crew')),
      );
      expect((selected.decoration as BoxDecoration).color, topicRail.color);
      final selectedRect = tester.getRect(
        find.byKey(const ValueKey('group-mini-selection-conversation-crew')),
      );
      expect(selectedRect.height, 58);
      final topicRect = tester.getRect(
        find.byKey(const ValueKey('group-topic-sidebar')),
      );
      expect(selectedRect.width, 58);
      expect(selectedRect.right + 1, topicRect.left);
      expect(
        tester
            .widget<VerticalDivider>(
              find.byKey(const ValueKey('desktop-rail-divider')),
            )
            .color,
        topicRail.color,
      );
      expect(
        (selected.decoration as BoxDecoration).borderRadius,
        const BorderRadius.horizontal(left: Radius.circular(9)),
      );

      await tester.tap(find.byKey(const ValueKey('friend-mini-$_firstPeer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-people-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('friend-$_secondPeer')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group header placement keeps both desktop styles', (
    tester,
  ) async {
    final state = await _stateWithFriends();
    addTearDown(state.dispose);
    state.appSettings = AppSettings(
      groupHeaderPlacement: GroupHeaderPlacement.fullWidth,
    );

    await _pumpHome(
      tester,
      state: state,
      size: const Size(800, 600),
      platform: TargetPlatform.windows,
    );
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    final header = tester.getRect(find.byKey(const ValueKey('group-header')));
    final topics = tester.getRect(
      find.byKey(const ValueKey('group-topic-sidebar')),
    );
    expect(header.left, lessThanOrEqualTo(topics.left));
    expect(header.right, greaterThanOrEqualTo(topics.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'group settings expose admin roles and reusable add-person flow',
    (tester) async {
      final state = await _stateWithFriends();
      addTearDown(state.dispose);

      await _pumpHome(
        tester,
        state: state,
        size: const Size(900, 700),
        platform: TargetPlatform.windows,
      );
      await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rename-group-title')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rename-group-field')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('group-settings-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('You are an admin'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('add-group-member-button')),
        findsOneWidget,
      );
      expect(find.text('COLLECTIONS & CONVERSATIONS'), findsOneWidget);
      expect(find.text('Outside collections'), findsOneWidget);
      expect(find.text('Topics'), findsOneWidget);
      expect(find.text('Voice chats'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byKey(const ValueKey('rename-group-field')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('joined group preview lives on the opened header avatar', (
    tester,
  ) async {
    final state = await _stateWithFriends(includeNonFriendMember: true);
    addTearDown(state.dispose);

    await _pumpHome(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
    );

    final overflow = tester.widget<Text>(find.text('+2'));
    expect(overflow.style?.fontSize, greaterThanOrEqualTo(10));
    expect(overflow.style?.color, Colors.black);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('group-conversation-crew'))),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('group-members-conversation-crew')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    final avatar = find.byKey(const ValueKey('group-header-avatar'));
    final collapsedWidth = tester.getSize(avatar).width;
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('group-header-avatar-hover'))),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(avatar).width, greaterThan(collapsedWidth));
    expect(
      find.byKey(const ValueKey('group-header-members-conversation-crew')),
      findsOneWidget,
    );
    expect(find.text('Nora'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(tester.getSize(avatar).width, collapsedWidth);
    expect(
      find.byKey(const ValueKey('group-header-members-conversation-crew')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
