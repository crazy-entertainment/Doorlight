import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/home.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/group_topics.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/window_presentation.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'package:sybl/ui/windows_pane_layout.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/group_room_activity.dart';
import 'package:sybl/ui/microphone_press_target.dart';
import 'package:sybl/screens/in_call.dart';
import 'package:sybl/screens/group_call.dart';

const peer = '1111111111111111111111111111111111111111';

class FixtureJami extends JamiClient {
  final commands = <String>[];
  @override
  bool get usesNativeAppSettingsStore => false;
  @override
  Future<void> windowCommand(String command) async {
    commands.add(command);
  }

  @override
  Future<int> loadChat(
    String peer,
    String conversation, {
    String fromMessage = '',
    int pageSize = 50,
  }) async => 0;
}

class FixtureState extends AppState {
  FixtureState(super.jami, super.prefs);
  List<GroupRoomParticipant>? roomParticipants;
  @override
  List<GroupRoomParticipant> groupVoiceParticipants(
    String group,
    String room,
  ) => roomParticipants ?? super.groupVoiceParticipants(group, room);
  void changeRoomParticipants(List<GroupRoomParticipant> participants) {
    roomParticipants = participants;
    notifyListeners();
  }

  @override
  bool get outputPickerAvailable => true;
}

void testWindows(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
  });
  late FixtureJami jami;
  late AppState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    jami = FixtureJami();
    state = FixtureState(jami, await SharedPreferences.getInstance())
      ..displayName = 'Local test account'
      ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      ..registration = 'REGISTERED';
    state.seedEmptyRuntimeSnapshotForTesting(
      selectedPeerId: peer,
      friends: const [
        FriendState(
          peerId: peer,
          confirmed: true,
          conversationId: 'test-chat',
          displayName: 'A very long contact display name',
          presence: PeerPresence.inApp,
        ),
      ],
      groups: [
        GroupState(
          conversationId: 'test-group',
          title: 'A very long group title',
          memberCount: 2,
          canManageMembers: false,
          memberIds: const [peer],
          activeMemberIds: const {peer},
          invitedMemberIds: const {},
        ),
      ],
    );
    state.accountId = 'test-account';
    state.screen = Screen.home;
    state.seedCaptureStateForTesting(
      resolved: true,
      applied: WindowCaptureProtectionStatus.exclude,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('syb.l/core'),
          (_) async => null,
        );
  });
  tearDown(() {
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('syb.l/core'), null);
  });

  Future<void> pump(
    WidgetTester tester, {
    double scale = 1,
    bool compact = true,
    bool animations = false,
    AppearancePreset preset = AppearancePreset.cozy,
    Size size = const Size(320, 360),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: Warm.theme(preset).copyWith(platform: TargetPlatform.windows),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: !animations,
          ),
          child: WindowsChrome(
            jami: jami,
            renderControls: false,
            child: child!,
          ),
        ),
        home: WindowsChromeContent(
          compactContentAvailable: true,
          child: ListenableBuilder(
            listenable: state,
            builder: (_, _) => HomeScreen(state: state),
          ),
        ),
      ),
    );
    if (compact) await tester.tap(find.byTooltip('Compact'));
    await tester.pumpAndSettle();
  }

  for (final people in [true, false]) {
    testWindows(
      'window resize keeps live ${people ? 'people' : 'chat'} across the breakpoint',
      (tester) async {
        if (people) {
          state.dispose();
          state = FixtureState(jami, await SharedPreferences.getInstance())
            ..displayName = 'Local test account'
            ..accountId = 'test-account'
            ..jamiId = 'a' * 40
            ..screen = Screen.home;
          state.seedCaptureStateForTesting(
            resolved: true,
            applied: WindowCaptureProtectionStatus.exclude,
          );
        }
        tester.view
          ..physicalSize = const Size(700, 500)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late WindowPresentation window;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
            builder: (context, child) =>
                WindowsChrome(jami: jami, renderControls: false, child: child!),
            home: Builder(
              builder: (context) {
                window = WindowPresentationScope.maybeOf(context)!;
                return RepaintBoundary(
                  key: boundary,
                  child: WindowsChromeContent(
                    compactContentAvailable: true,
                    child: ListenableBuilder(
                      listenable: state,
                      builder: (_, _) => HomeScreen(state: state),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rail = find.byKey(const ValueKey('desktop-people-rail'));
        final initialRail = tester.element(rail);
        final chatState = people
            ? null
            : tester.element(find.byType(ChatStage));
        TextEditingController? composer;
        if (!people) {
          final field = find.byKey(const ValueKey('chat-composer'));
          await tester.enterText(field, 'A draft across window sizes');
          composer = tester.widget<TextField>(field).controller!;
          composer.selection = const TextSelection.collapsed(offset: 4);
        }
        Future<void> capture(String frame) async {
          final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
          if (output == null) return;
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/window-${people ? 'people' : 'chat'}-$frame.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }

        await capture('wide');
        await window.setCompact(true, animate: true);
        await tester.pump();
        for (final width in [640.0, 600.0, 500.0, 400.0, 320.0]) {
          tester.view.physicalSize = Size(
            width,
            360 + (width - 320) * 140 / 380,
          );
          await tester.pump(const Duration(milliseconds: 44));
          expect(
            tester.element(
              find.byKey(
                const ValueKey('desktop-people-rail'),
                skipOffstage: false,
              ),
            ),
            same(initialRail),
          );
          if (!people) {
            expect(tester.element(find.byType(ChatStage)), same(chatState));
          }
          if (width == 500) await capture('middle');
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        await capture('compact');
        if (!people) {
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
                .controller,
            same(composer),
          );
          expect(composer!.selection, const TextSelection.collapsed(offset: 4));
        }
        await window.setCompact(false, animate: true);
        await tester.pump();
        for (final width in [400.0, 500.0, 600.0, 640.0, 700.0]) {
          tester.view.physicalSize = Size(
            width,
            360 + (width - 320) * 140 / 380,
          );
          await tester.pump(const Duration(milliseconds: 44));
          expect(
            tester
                .widget<WindowsPaneLayout>(find.byType(WindowsPaneLayout))
                .compact,
            isFalse,
            reason:
                'An expanding window must not revert to compact below the width breakpoint.',
          );
          if (!people) {
            expect(tester.element(find.byType(ChatStage)), same(chatState));
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        expect(tester.element(rail), same(initialRail));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWindows(
      'manual people resize keeps desktop density and clears window controls at text $scale',
      (tester) async {
        state.peerId = null;
        await pump(
          tester,
          scale: scale,
          compact: false,
          animations: true,
          preset: AppearancePreset.disaccord,
          size: const Size(700, 500),
        );
        final rail = find.byKey(const ValueKey('desktop-people-rail'));
        final railElement = tester.element(rail);
        final account = find.byKey(const ValueKey('account-card'));
        final accountElement = tester.element(account);
        final accountHeight = tester.getSize(account).height;
        final title = find.text('Your people');
        final wideTitleTop = tester.getTopLeft(title).dy;
        var previousWidth = 700.0;
        for (final width in [
          680.0,
          650.0,
          635.0,
          621.0,
          620.0,
          619.0,
          550.0,
          400.0,
          280.0,
          550.0,
          620.0,
          700.0,
        ]) {
          final previousTitleTop = tester.getTopLeft(title).dy;
          final crossesBreakpoint = (width < 620) != (previousWidth < 620);
          tester.view.physicalSize = Size(width, 500);
          await tester.pump();
          if (crossesBreakpoint) {
            expect(
              tester.getTopLeft(title).dy,
              closeTo(previousTitleTop, 1),
              reason:
                  'Title-bar clearance must animate without a first-frame jump.',
            );
            for (var frame = 0; frame < 10; frame++) {
              await tester.pump(const Duration(milliseconds: 22));
              final bar = find.byKey(const ValueKey('windows-title-bar'));
              final add = tester.getRect(
                find.byKey(const ValueKey('people-actions-button')),
              );
              for (final controls in [
                find.byKey(const ValueKey('windows-close-button')),
                find.descendant(
                  of: bar,
                  matching: find.byType(WindowModeButtons),
                ),
                find.descendant(
                  of: bar,
                  matching: find.byKey(const ValueKey('notification-bell')),
                ),
              ]) {
                if (controls.evaluate().isNotEmpty) {
                  expect(add.overlaps(tester.getRect(controls)), isFalse);
                }
              }
            }
          }
          await tester.pumpAndSettle();
          previousWidth = width;
          expect(tester.element(rail), same(railElement));
          expect(tester.element(account), same(accountElement));
          expect(tester.getSize(account).height, accountHeight);
          expect(tester.widget<Text>(title).style!.fontSize, 16);
          expect(find.text('2 conversations'), findsNothing);
          if (width >= 620) {
            expect(
              tester.getTopLeft(title).dy,
              closeTo(wideTitleTop, 1),
              reason:
                  'A split view must not reserve title space above the people panel.',
            );
          }
          for (final key in ['open-history-search', 'people-actions-button']) {
            final action = find.byKey(ValueKey(key));
            expect(action.hitTestable(), findsOneWidget);
            if (width < 620) {
              expect(
                tester.getRect(action).top,
                greaterThanOrEqualTo(WindowsChrome.height),
              );
            }
          }
          expect(
            find.byKey(const ValueKey('windows-close-button')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('open-settings-button')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (width == 280 || width == 550 || width == 635) {
            await expectLater(
              find.byType(WindowsChromeContent),
              matchesGoldenFile(
                'goldens/windows_people_normal_${width.toInt()}_text$scale.png',
              ),
            );
          }
        }
        tester.view.physicalSize = const Size(550, 500);
        await tester.pumpAndSettle();
        final beforeCompact = tester.getTopLeft(title).dy;
        final window = WindowPresentationScope.maybeOf(
          tester.element(find.byType(HomeScreen)),
        )!;
        await window.setCompact(true, animate: true);
        await tester.pump();
        expect(
          tester.getTopLeft(title).dy,
          closeTo(beforeCompact, 1),
          reason: 'Native compact mode must animate the existing title inset.',
        );
        await tester.pump(const Duration(milliseconds: 55));
        expect(tester.getTopLeft(title).dy, lessThan(beforeCompact));
        tester.view.physicalSize = const Size(320, 360);
        await tester.pumpAndSettle();
        expect(tester.element(rail), same(railElement));
        expect(tester.element(account), same(accountElement));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWindows(
      'manual narrow resize retains settings and draft at text $scale',
      (tester) async {
        await pump(
          tester,
          scale: scale,
          compact: false,
          size: const Size(700, 500),
        );
        await tester.enterText(
          find.byKey(const ValueKey('chat-composer')),
          'Draft through manual resizing',
        );
        final chat = tester.element(find.byType(ChatStage));
        tester.view.physicalSize = const Size(500, 500);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<WindowsPaneLayout>(find.byType(WindowsPaneLayout))
              .compact,
          isTrue,
        );
        expect(
          WindowPresentationScope.maybeOf(
            tester.element(find.byType(HomeScreen)),
          )!.compact,
          isFalse,
        );
        expect(tester.element(find.byType(ChatStage)), same(chat));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        final settings = find.byKey(const ValueKey('desktop-settings'));
        final settingsElement = tester.element(settings);
        for (final width in [280.0, 620.0, 700.0, 320.0]) {
          tester.view.physicalSize = Size(width, 500);
          await tester.pumpAndSettle();
          expect(tester.element(settings), same(settingsElement));
          expect(
            find.byKey(const ValueKey('windows-title-bar')),
            findsOneWidget,
          );
          if (width < 620) {
            expect(
              find.byKey(const ValueKey('narrow-settings-back')).hitTestable(),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('open-settings-button')).hitTestable(),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byKey(const ValueKey('narrow-settings-back')));
        await tester.pumpAndSettle();
        // Settings navigation recreates the chat; its saved draft must survive.
        expect(find.text('Draft through manual resizing'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('conversation-back-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('open-settings-button')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWindows(
    'pin and compact transitions are independent and draft survives',
    (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('windows-title-bar')), findsNothing);
      await tester.tap(find.byTooltip('Pin'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Unsent draft',
      );
      await tester.tap(find.byTooltip('Default size'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Compact'));
      await tester.pumpAndSettle();
      expect(find.text('Unsent draft'), findsOneWidget);
      expect(find.byTooltip('Unpin'), findsOneWidget);
      expect(jami.commands.where((c) => c == 'pin').length, 1);
      expect(jami.commands, isNot(contains('unpin')));
      await tester.tap(find.byTooltip('Close'));
      expect(jami.commands.last, 'close');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWindows(
      'compact Add friend keeps an exit while scrolling at ${scale}x',
      (tester) async {
        await pump(tester, scale: scale);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('people-actions-button')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('people-action-add-friend')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Add a friend'), findsOneWidget);
        final header = find.byType(CompactHeader);
        expect(header, findsOneWidget);
        final position = tester.getTopLeft(header);
        for (final label in ['Back', 'Pin', 'Default size', 'Close']) {
          expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        }
        await expectLater(
          find.byType(WindowsChrome),
          matchesGoldenFile('goldens/windows_compact_add_friend_${scale}x.png'),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('connection-scan-qr')),
        );
        await tester.tap(find.byKey(const ValueKey('connection-scan-qr')));
        await tester.pumpAndSettle();
        expect(find.text('Scan a QR code'), findsOneWidget);
        expect(find.byType(CompactHeader), findsOneWidget);
        for (final label in ['Back', 'Pin', 'Default size', 'Close']) {
          expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.text('Add a friend'), findsOneWidget);
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -500),
        );
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(header), position);
        expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-people-rail')),
          findsOneWidget,
        );
        expect(find.text('Add a friend'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWindows('settings expands the people rail after opening a group', (
    tester,
  ) async {
    await pump(tester);
    tester.view.physicalSize = const Size(700, 500);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Default size'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-test-group')));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(
      const ValueKey('desktop-sidebar-dismiss-settings'),
    );
    expect(tester.getSize(sidebar).width, 58);
    await tester.tap(find.byKey(const ValueKey('group-mini-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-settings')), findsOneWidget);
    expect(tester.getSize(sidebar).width, 212);
    expect(
      find.byKey(const ValueKey('open-settings-button')).hitTestable(),
      findsOneWidget,
    );
    expect(state.selectedGroup?.conversationId, 'test-group');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-settings')), findsNothing);
    expect(tester.getSize(sidebar).width, 58);
    expect(state.selectedGroup?.conversationId, 'test-group');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWindows('large text and settings remain within compact viewport', (
    tester,
  ) async {
    await pump(tester, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(CompactHeader), findsOneWidget);
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    for (final width in [280.0, 320.0]) {
      tester.view.physicalSize = Size(width, 360);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text('Settings'));
      final controls = tester.getRect(find.byType(WindowModeButtons));
      expect(title.right, lessThanOrEqualTo(controls.left));
      expect(controls.right, lessThanOrEqualTo(width));
    }
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWindows('settings section navigation stays visible until selected', (
    tester,
  ) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Settings sections'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const ValueKey('settings-jump-appearance')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-jump-appearance')));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWindows('both group overflow entries expose the same real rooms', (
    tester,
  ) async {
    state.selectedGroupId = 'test-group';
    state.peerId = null;
    await pump(tester);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    for (final entry in ['header', 'topics']) {
      await tester.tap(find.byKey(ValueKey('compact-group-menu-$entry')));
      await tester.pumpAndSettle();
      expect(find.text('Topics'), findsOneWidget);
      expect(find.text('Voice chats'), findsOneWidget);
      expect(find.text('Group settings'), findsOneWidget);
      expect(state.groupCall, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    final voice = state.groups['test-group']!.layout.rooms.firstWhere(
      (room) => room.kind == GroupRoomKind.voice,
    );
    await tester.tap(find.byKey(const ValueKey('compact-group-menu-header')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(voice.name));
    await tester.pumpAndSettle();
    expect(find.text('Join voice chat'), findsOneWidget);
    expect(state.groupCall, isNull, reason: 'Browsing must not join the room');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWindows('an open room menu updates when its last participant leaves', (
    tester,
  ) async {
    state.selectedGroupId = 'test-group';
    state.peerId = null;
    final fixture = state as FixtureState;
    fixture.changeRoomParticipants(const [
      GroupRoomParticipant(
        accountId: peer,
        muted: false,
        deafened: false,
        video: false,
        screenShare: false,
        speaking: false,
      ),
    ]);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('compact-group-menu-header')));
    await tester.pumpAndSettle();
    final avatars = find.descendant(
      of: find.byType(RoomParticipantAvatars),
      matching: find.byType(Tooltip),
    );
    expect(avatars, findsOneWidget);
    fixture.changeRoomParticipants(const []);
    await tester.pump();
    expect(find.text('Voice chats'), findsOneWidget);
    expect(avatars, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWindows('incoming overlay leaves the composer in place', (tester) async {
    state.call = CallSession(
      callId: 'test-incoming',
      dir: CallDir.incoming,
      peerId: peer,
      state: 'RINGING',
    );
    await pump(tester);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('answer-incoming-call-banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('decline-incoming-call-banner')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/windows_compact_incoming.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWindows('compact people retains the shared account pill and actions', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('account-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('people-actions-button')), findsOneWidget);
    expect(find.text('Your people'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/windows_compact_people.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final group in [false, true]) {
    testWindows(
      '${group ? 'group' : 'direct'} audio fits the approved HUD size',
      (tester) async {
        final controller = WindowPresentation(jami);
        await controller.setCompact(true);
        addTearDown(controller.dispose);
        if (group) {
          state.groupCall = GroupCallSession(
            conversationId: 'test-group',
            roomId: 'voice',
            conferenceId: 'test-conference',
            sessionId: 'test-session',
            phase: GroupCallPhase.connected,
          );
        } else {
          state.call = CallSession(
            callId: 'test-call',
            dir: CallDir.outgoing,
            peerId: peer,
            state: 'CURRENT',
            microphonePolicyApplied: true,
            everConnected: true,
          );
        }
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(300, group ? 156 : 132);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
            home: WindowPresentationScope(
              controller: controller,
              child: RepaintBoundary(
                key: const ValueKey('hud'),
                child: Material(
                  child: group
                      ? GroupCallScreen(state: state, onMinimize: () {})
                      : InCallScreen(state: state, onMinimize: () {}),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byTooltip('Deafen'), group ? findsOneWidget : findsNothing);
        expect(find.byTooltip('Default size'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const ValueKey('hud')),
          matchesGoldenFile(
            'goldens/windows_compact_${group ? 'group' : 'direct'}_audio.png',
          ),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final group in [false, true]) {
    testWindows(
      'compact ${group ? 'group' : 'direct'} video returns to default size',
      (tester) async {
        if (group) {
          state.selectedGroupId = 'test-group';
          state.peerId = null;
          state.groupCall = GroupCallSession(
            conversationId: 'test-group',
            roomId: 'voice',
            conferenceId: 'test-conference',
            sessionId: 'test-session',
            phase: GroupCallPhase.connected,
            video: true,
          );
        } else {
          state.call = CallSession(
            callId: 'test-video',
            dir: CallDir.outgoing,
            peerId: peer,
            state: 'CURRENT',
            everConnected: true,
            peerVideo: true,
          );
        }
        await pump(tester);
        await tester.tap(find.byTooltip('Return to call'));
        await tester.pumpAndSettle();
        expect(jami.commands.last, 'resetWindow');
        tester.view.physicalSize = const Size(700, 500);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('windows-title-bar')), findsOneWidget);
        expect(find.byTooltip('Compact').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('windows-close-button')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(
          find.byTooltip(group ? 'Back to the group' : 'Back to your friends'),
        );
        await tester.pumpAndSettle();
        expect(
          group
              ? find.byKey(const ValueKey('group-conversation-surface'))
              : find.byKey(const ValueKey('chat-composer')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWindows('removing a held microphone releases its owner', (tester) async {
    final holds = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MicrophonePressTarget(
            pushToTalk: true,
            onHold: holds.add,
            onToggle: () {},
            child: const SizedBox(width: 40, height: 40),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MicrophonePressTarget)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(holds, [true]);
    await tester.pumpWidget(const SizedBox());
    expect(holds, [true, false]);
    await gesture.up();
  });
}
