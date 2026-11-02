import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/home.dart';
import 'package:sybl/screens/debug.dart';
import 'package:sybl/screens/in_call.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/ui/capture_consent_gate.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/account_share.dart';
import 'package:sybl/ui/add_friend_dialog.dart';
import 'package:sybl/ui/group_dialogs.dart';
import 'package:sybl/ui/linked_devices_dialog.dart';
import 'package:sybl/ui/device_pairing_dialog.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'package:sybl/ui/settings_pane.dart';
import 'package:sybl/ui/doorlight_brand.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/widgets/passphrase_dialog.dart';

const _mara = '1111111111111111111111111111111111111111';
const _phoneA = '2222222222222222222222222222222222222222';
const _phoneB = '3333333333333333333333333333333333333333';
const _goldenSurface = ValueKey('visual-regression-surface');

// Opt-in private captures: the normal suite still compares Cozy goldens.
// Use --plain-name to select the group/audio-call fixtures when comparing themes.
const _captureTheme = String.fromEnvironment(
  'VISUAL_THEME',
  defaultValue: 'cozy',
);
const _captureDirectory = String.fromEnvironment('VISUAL_OUTPUT_DIR');
final _visualPreset = switch (_captureTheme) {
  'cozy' => AppearancePreset.cozy,
  'disaccord' => AppearancePreset.disaccord,
  'midnight' => AppearancePreset.midnight,
  _ => throw ArgumentError.value(_captureTheme, 'VISUAL_THEME'),
};

Uri _goldenPath(String name) {
  if (_captureDirectory.isEmpty) {
    if (_visualPreset != AppearancePreset.cozy) {
      throw StateError('VISUAL_OUTPUT_DIR is required for alternate themes');
    }
    return Uri.parse('goldens/$name.png');
  }
  return Uri.directory(_captureDirectory).resolve('$name.png');
}

class _VisualJamiClient extends JamiClient {
  // This fixture has no Android channel or native canonical settings store.
  @override
  bool get usesNativeAppSettingsStore => false;

  @override
  Future<String?> pickFile({
    String mimeType = '*/*',
    int maxBytes = JamiClient.maxPickedFileBytes,
  }) async => '/staged/doorlight-backup.gz';

  @override
  Future<void> discardPickedFile(String path) async {}

  bool? lastMicMuted;
  String? lastScreenSource;
  int hangUps = 0;

  @override
  Future<List<JamiKnownDevice>> listKnownDevices() async => const [
    JamiKnownDevice(id: 'desktop-device', name: 'Desktop', current: true),
    JamiKnownDevice(id: 'phone-device', name: 'Phone B', current: false),
  ];

  @override
  Future<void> setMicMuted(String callId, bool muted) async {
    lastMicMuted = muted;
  }

  @override
  Future<List<ScreenSource>> listScreenSources(String callId) async {
    return const [
      ScreenSource(
        id: 'monitor:primary',
        label: 'Primary display',
        primary: true,
        bounds: Rect.fromLTWH(0, 0, 1920, 1080),
      ),
    ];
  }

  @override
  Future<bool> setOutgoingVideoSource(
    String callId,
    OutgoingVideoKind kind, {
    String? sourceId,
  }) async {
    lastScreenSource = sourceId;
    return true;
  }

  @override
  Future<int> createVideoTexture(String role) async => -1;

  @override
  Future<void> hangUp(String callId) async {
    hangUps += 1;
  }

  @override
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
  }) async => 0;

  @override
  Future<WindowCaptureProtectionStatus> applyWindowsCaptureProtection({
    required bool protect,
  }) async => protect
      ? WindowCaptureProtectionStatus.exclude
      : WindowCaptureProtectionStatus.none;
}

class _ProfileVisualJami extends _VisualJamiClient {
  @override
  Stream<JamiEvent> events() => const Stream<JamiEvent>.empty();
  @override
  Future<String> myJamiId() async => '';
}

class _VisualAppState extends AppState {
  _VisualAppState(super.jami, super.prefs, {required this.showSpeakerControl});

  final bool showSpeakerControl;

  @override
  AppearancePreset get appearancePreset => _visualPreset;

  @override
  List<ConversationTimelineItem> get conversationItems {
    if (_captureDirectory.isEmpty || selectedGroupId != 'conversation-crew') {
      return super.conversationItems;
    }
    final scope = selectedConversationScope;
    if (scope == null) return super.conversationItems;
    final messages = [
      (author: _mara, text: 'Anyone up for a call after lunch?'),
      (author: jamiId, text: 'Yes! I can join at two.'),
      (author: _phoneA, text: 'Works for me. I will bring the photos.'),
      (author: jamiId, text: 'Perfect, see you both then.'),
    ];
    return [
      for (var i = 0; i < messages.length; i++)
        TimelineTextItem(
          scope: scope,
          daemonId: 'synthetic-group-message-$i',
          versionId: 'synthetic-group-message-$i-v1',
          authorId: messages[i].author,
          direction: messages[i].author == jamiId
              ? TimelineDirection.outgoing
              : TimelineDirection.incoming,
          createdAt: DateTime(2026, 3, 28, 13, 10 + i),
          roomId: 'general',
          text: messages[i].text,
        ),
    ];
  }

  @override
  bool get speakerControlAvailable => showSpeakerControl;

  @override
  Future<void> selectGroup(
    String conversationId, {
    ConversationAction? action,
    bool fromHistorySearch = false,
  }) async {
    if (!groups.containsKey(conversationId)) return;
    selectedGroupId = conversationId;
    peerId = null;
    notifyListeners();
  }
}

Future<AppState> _fixtureState({
  JamiClient? jami,
  bool showSpeakerControl = false,
  bool selectGroup = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state =
      _VisualAppState(
          jami ?? _VisualJamiClient(),
          await SharedPreferences.getInstance(),
          showSpeakerControl: showSpeakerControl,
        )
        ..accountId = 'account'
        ..displayName = 'You'
        ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        ..registration = 'REGISTERED';
  state.seedEmptyRuntimeSnapshotForTesting(
    selectedPeerId: selectGroup ? null : _mara,
    selectedFixtureGroupId: selectGroup ? 'conversation-crew' : null,
    friends: const [
      FriendState(
        peerId: _mara,
        confirmed: true,
        conversationId: 'conversation-mara',
        displayName: 'Mara',
        presence: PeerPresence.inApp,
      ),
      FriendState(
        peerId: _phoneA,
        confirmed: true,
        conversationId: 'conversation-phone-a',
        displayName: 'Phone A',
        presence: PeerPresence.reachable,
        presencePlatform: 'android',
      ),
      FriendState(
        peerId: _phoneB,
        confirmed: true,
        conversationId: 'conversation-phone-b',
        displayName: 'Phone B',
        presence: PeerPresence.unreachable,
        presencePlatform: 'android',
      ),
    ],
    groups: const [
      GroupState(
        conversationId: 'conversation-crew',
        title: 'The Crew',
        memberCount: 3,
        canManageMembers: true,
        localRole: JamiGroupMemberRole.admin,
        memberIds: [_mara, _phoneA],
        activeMemberIds: {_mara, _phoneA},
        invitedMemberIds: {},
        memberRoles: {
          _mara: JamiGroupMemberRole.admin,
          _phoneA: JamiGroupMemberRole.member,
        },
      ),
    ],
    folderEntries: [
      FolderFile(
        peerId: _mara,
        conversationId: 'conversation-mara',
        fileId: 'file-one',
        interactionId: 'interaction-one',
        name: 'holiday-photo.jpg',
        size: 4281958,
        outgoing: false,
        downloaded: true,
        timestamp: DateTime(2026, 3, 28, 1).millisecondsSinceEpoch ~/ 1000,
      ),
      FolderFile(
        peerId: _mara,
        conversationId: 'conversation-mara',
        fileId: 'file-two',
        interactionId: 'interaction-two',
        name: 'travel-notes.pdf',
        size: 973112,
        outgoing: true,
        downloaded: true,
        timestamp: DateTime(2026, 3, 28, 1, 1).millisecondsSinceEpoch ~/ 1000,
      ),
    ],
  );
  return state;
}

// Test-owned state must stop its recovery timers when Flutter unmounts the
// fixture, before flutter_test verifies that no timers remain.
class _FixtureOwner extends StatefulWidget {
  const _FixtureOwner({required this.appState, required this.child});
  final AppState appState;
  final Widget child;

  @override
  State<_FixtureOwner> createState() => _FixtureOwnerState();
}

class _FixtureOwnerState extends State<_FixtureOwner> {
  @override
  void dispose() {
    widget.appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> _pumpSurface(
  WidgetTester tester, {
  required AppState state,
  required Size size,
  required TargetPlatform platform,
  TextScaler textScaler = TextScaler.noScaling,
  Widget Function(AppState state)? child,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    _FixtureOwner(
      appState: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: Warm.theme(_visualPreset).copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: textScaler,
            disableAnimations: true,
            accessibleNavigation: true,
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: _goldenSurface,
          child: child?.call(state) ?? HomeScreen(state: state),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    final context = tester.element(find.byKey(_goldenSurface));
    await precacheImage(const AssetImage('assets/brand/mark.png'), context);
    await precacheImage(const AssetImage('assets/brand/about.png'), context);
  });
  await tester.pump();
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  expect(
    tester.takeException(),
    isNull,
    reason: 'No layout or rendering errors',
  );
  await expectLater(
    find.byKey(_goldenSurface),
    matchesGoldenFile(_goldenPath(name)),
  );
}

Future<void> _expectDialogGolden(WidgetTester tester, String name) async {
  await expectLater(
    find.byType(AlertDialog).last,
    matchesGoldenFile(_goldenPath(name)),
  );
}

Widget _launcher(Future<void> Function(BuildContext context) open) => Scaffold(
  body: Builder(
    builder: (context) => Center(
      child: FilledButton(
        key: const ValueKey('test-open-surface'),
        onPressed: () => open(context),
        child: const Text('Open'),
      ),
    ),
  ),
);

void main() {
  for (final fixture in [
    (
      name: 'desktop_profile',
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      scale: 1.0,
    ),
    (
      name: 'phone_profile',
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      scale: 1.0,
    ),
    (
      name: 'phone_profile_text200',
      size: const Size(320, 720),
      platform: TargetPlatform.android,
      scale: 2.0,
    ),
  ]) {
    testWidgets('${fixture.name} closed and expanded palette', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state =
          (await tester.runAsync(() async {
              final value = AppState(
                _ProfileVisualJami(),
                await SharedPreferences.getInstance(),
              );
              await value.init();
              return value;
            }))!
            ..accountId = 'profile-owner'
            ..jamiId = 'f' * 40
            ..displayName = 'Desktop';
      state.seedEmptyRuntimeSnapshotForTesting(
        selectedPeerId: _mara,
        friends: const [
          FriendState(
            peerId: _mara,
            confirmed: true,
            conversationId: 'mara',
            displayName: 'Mara',
            identityColor: IdentityColor.red,
          ),
          FriendState(
            peerId: _phoneA,
            confirmed: true,
            conversationId: 'phone-a',
            displayName: 'Alex',
            identityColor: IdentityColor.sky,
          ),
          FriendState(
            peerId: _phoneB,
            confirmed: true,
            conversationId: 'phone-b',
            displayName: 'Lee',
            identityColor: IdentityColor.sky,
          ),
        ],
      );
      state.appSettings = state.appSettings.withIdentityColor(
        IdentityColor.green,
      );
      await _pumpSurface(
        tester,
        state: state,
        size: fixture.size,
        platform: fixture.platform,
        textScaler: TextScaler.linear(fixture.scale),
        child: (state) => Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
            onAddFriend: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _expectGolden(tester, '${fixture.name}_closed');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('identity-color-more')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('identity-color-palette')),
        findsOneWidget,
      );
      await expectLater(
        find.byType(Overlay).first,
        matchesGoldenFile(_goldenPath('${fixture.name}_expanded')),
      );
      expect(tester.takeException(), isNull);
    });
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    // flutter_test maps generic families to the block-shaped Ahem font.
    // Alias the bundled sans face for deterministic, readable identifier
    // previews; production still resolves its platform monospace normally.
    await (FontLoader('monospace')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
    // Reduced motion keeps the onboarding reel on its resting word.
    await (FontLoader('InstrumentSerif')
          ..addFont(rootBundle.load('assets/fonts/InstrumentSerif-Italic.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('button typography keeps the bundled sans family', () {
    final style = Warm.theme(_visualPreset).filledButtonTheme.style!;
    expect(style.textStyle?.resolve({})?.fontFamily, Warm.sansFamily);
  });

  testWidgets('the unopened door has a rectangular outline', (tester) async {
    const mark = ValueKey('closed-door-mark');
    Widget closedDoor(double phase) => MaterialApp(
      theme: Warm.theme(_visualPreset),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: mark,
            child: ColoredBox(
              color: Warm.palette(_visualPreset).bg,
              child: DoorlightDoorMark(
                size: 176,
                openness: 0,
                illumination: 0,
                thresholdPhase: phase,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(closedDoor(0));
    await expectLater(
      find.byKey(mark),
      matchesGoldenFile(_goldenPath('closed_door_176')),
    );
    await tester.pumpWidget(closedDoor(.5));
    await expectLater(
      find.byKey(mark),
      matchesGoldenFile(_goldenPath('closed_door_shadow_176')),
    );
  });

  testWidgets('floor light remains visible as the door starts opening', (
    tester,
  ) async {
    const mark = ValueKey('continuous-door-light');
    Future<int> floorBrightness(double openness) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(_visualPreset),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: mark,
                child: ColoredBox(
                  color: Warm.palette(_visualPreset).bg,
                  child: DoorlightDoorMark(
                    size: 176,
                    openness: openness,
                    illumination: (openness * 1.4).clamp(0.0, 1.0),
                    thresholdPhase: 0,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final surface = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(mark),
      );
      final pixels = await tester.runAsync(() async {
        final image = await surface.toImage();
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      return pixels!.getUint8((150 * 176 + 88) * 4);
    }

    final brightness = <int>[];
    for (final openness in [0.0, .05, .1, .2, .3]) {
      brightness.add(await floorBrightness(openness));
    }
    expect(brightness.first, greaterThan(40));
    for (var index = 1; index < brightness.length; index++) {
      expect(
        brightness[index],
        greaterThanOrEqualTo(brightness[index - 1] - 2),
      );
    }
  });

  for (final mobile in [false, true]) {
    testWidgets('About shows supplied artwork at ${mobile ? 200 : 100}% text', (
      tester,
    ) async {
      final state = await _fixtureState();
      addTearDown(state.dispose);
      await _pumpSurface(
        tester,
        state: state,
        size: mobile ? const Size(390, 844) : const Size(700, 500),
        platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
        textScaler: TextScaler.linear(mobile ? 2 : 1),
        child: (_) => _launcher(showDoorlightAbout),
      );
      await tester.tap(find.byKey(const ValueKey('test-open-surface')));
      await tester.pumpAndSettle();
      expect(find.text('About Doorlight'), findsOneWidget);
      expect(find.byType(DoorlightHero), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Credits & licenses'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Close'), findsOneWidget);
      expect(
        find.text('Sonar sound effects from Pixabay contributors.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _expectDialogGolden(
        tester,
        mobile ? 'mobile_about_390x844_text200' : 'desktop_about_700x500',
      );
      await tester.tap(find.text('Credits & licenses'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(LicensePage))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.text('About Doorlight'), findsNothing);
    });
  }

  for (final mobile in [false, true]) {
    testWidgets(
      'diagnostics status spans the view with readable optional details (${mobile ? 'phone200' : 'desktop'})',
      (tester) async {
        final state = await _fixtureState();
        final size = mobile ? const Size(320, 720) : const Size(700, 500);
        await _pumpSurface(
          tester,
          state: state,
          size: size,
          platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
          textScaler: TextScaler.linear(mobile ? 2 : 1),
          child: (state) => DebugScreen(state: state),
        );
        await tester.pumpAndSettle();
        final badge = tester.getRect(
          find.byKey(const ValueKey('diagnostics-status')),
        );
        expect(badge.right, closeTo(size.width - 12, .1));
        expect(badge.left, closeTo(12, .1));
        expect(badge.width, closeTo(size.width - 24, .1));
        expect(find.text('Recent activity — newest first'), findsNothing);
        expect(find.text('Network online'), findsOneWidget);
        final logPanel = tester.widget<Container>(
          find.byKey(const ValueKey('diagnostics-log')),
        );
        expect(
          (logPanel.decoration! as BoxDecoration).color,
          isNot(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor),
        );
        expect(find.text(state.jamiId), findsNothing);
        expect(tester.takeException(), isNull);
        await _expectGolden(
          tester,
          mobile
              ? 'mobile_diagnostics_320x720_text200'
              : 'desktop_diagnostics_700x500',
        );
        await tester.tap(find.byKey(const ValueKey('diagnostics-status')));
        await tester.pumpAndSettle();
        expect(find.text('Status details'), findsOneWidget);
        expect(find.text('Messaging network'), findsOneWidget);
        expect(
          find.text(
            'Network registration for this device. It does not confirm friend availability or message delivery.',
          ),
          findsOneWidget,
        );
        expect(find.text('Doorlight open'), findsOneWidget);
        expect(find.text('Registration code'), findsOneWidget);
        expect(find.text(state.jamiId), findsOneWidget);
        expect(find.text('Close').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _expectDialogGolden(
          tester,
          mobile
              ? 'mobile_diagnostics_details_320x720_text200'
              : 'desktop_diagnostics_details_700x500',
        );
        await tester.tap(find.text('Close'));
        state.registration = 'TRYING';
        state.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Connecting to network'), findsOneWidget);
        state.appearOffline = true;
        state.notifyListeners();
        await tester.pump();
        expect(find.text('Network offline'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('desktop conversation matches the canonical warm shell', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
    );

    await _expectGolden(tester, 'desktop_conversation_700x500');
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('onboarding separates setup choices from forms on $platform', (
      tester,
    ) async {
      final state = await _fixtureState();
      addTearDown(state.dispose);
      final mobile = platform == TargetPlatform.android;
      await _pumpSurface(
        tester,
        state: state,
        size: mobile ? const Size(390, 844) : const Size(700, 500),
        platform: platform,
        child: (state) => OnboardingScreen(state: state),
      );
      expect(find.text('Let’s get you'), findsOneWidget);
      expect(find.text('with your friends'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-create-choice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding-existing-choice')),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      for (final key in [
        'onboarding-create-choice',
        'onboarding-existing-choice',
      ]) {
        final choice = find.byKey(ValueKey(key));
        expect(choice.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(choice).bottom,
          lessThanOrEqualTo(mobile ? 844 : 500),
        );
      }
      await _expectGolden(
        tester,
        mobile ? 'mobile_onboarding_390x844' : 'desktop_onboarding_700x500',
      );

      await tester.tap(find.byKey(const ValueKey('onboarding-create-choice')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('onboarding-create-step')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding-name-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding-create-submit')),
        findsOneWidget,
      );
      await _expectGolden(
        tester,
        mobile
            ? 'mobile_create_identity_390x844'
            : 'desktop_create_identity_700x500',
      );

      await tester.tap(find.byKey(const ValueKey('onboarding-back')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('onboarding-existing-choice')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore a backup'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-link-choice')),
        findsOneWidget,
      );
      await _expectGolden(
        tester,
        mobile
            ? 'mobile_link_existing_identity_390x844'
            : 'desktop_link_existing_identity_700x500',
      );
      await tester.tap(find.byKey(const ValueKey('onboarding-restore-choice')));
      await tester.pumpAndSettle();
      // The backup file comes first; its password is asked afterwards.
      expect(
        find.byKey(const ValueKey('onboarding-passphrase-field')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('onboarding-restore-pick')));
      await tester.pumpAndSettle();
      expect(find.text('doorlight-backup.gz'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-passphrase-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding-restore-submit')),
        findsOneWidget,
      );
    });
  }

  testWidgets('mobile onboarding remains usable at 200% text', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      textScaler: const TextScaler.linear(2),
      child: (state) => OnboardingScreen(state: state),
    );

    expect(tester.takeException(), isNull);
    final existingChoice = find.byKey(
      const ValueKey('onboarding-existing-choice'),
    );
    await tester.ensureVisible(existingChoice);
    await tester.tap(existingChoice);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('onboarding-restore-choice')),
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-restore-choice')));
    await tester.pumpAndSettle();

    expect(find.text('Restore a backup'), findsOneWidget);
    final pick = find.byKey(const ValueKey('onboarding-restore-pick'));
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('onboarding-passphrase-field')),
      findsOneWidget,
    );
    final restoreButton = find.byKey(
      const ValueKey('onboarding-restore-submit'),
    );
    await tester.ensureVisible(restoreButton);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(const ValueKey('onboarding-back')));
    await tester.tap(find.byKey(const ValueKey('onboarding-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-back')));
    await tester.pumpAndSettle();
    final createChoice = find.byKey(const ValueKey('onboarding-create-choice'));
    await tester.ensureVisible(createChoice);
    await tester.tap(createChoice);
    await tester.pumpAndSettle();
    final createButton = find.byKey(const ValueKey('onboarding-create-submit'));
    await tester.ensureVisible(createButton);
    expect(
      find.byKey(const ValueKey('onboarding-create-step')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unprotected restore warns before opening a backup', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      child: (state) => OnboardingScreen(state: state),
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-existing-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-restore-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-restore-pick')));
    await tester.pumpAndSettle();
    final unprotected = find.byKey(
      const ValueKey('onboarding-restore-unprotected'),
    );
    expect(tester.widget<TextButton>(unprotected).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('onboarding-restore-friend-id')),
      'e' * 40,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(unprotected);
    await tester.tap(unprotected);
    await tester.pumpAndSettle();

    expect(find.text('Use an unprotected backup?'), findsOneWidget);
    expect(
      find.textContaining('Only continue if you trust where it came from'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Restore'),
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    await _expectDialogGolden(
      tester,
      'desktop_unprotected_restore_warning_700x500',
    );
  });

  testWidgets('identity share dialog is render correctly', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 700),
      platform: TargetPlatform.windows,
      child: (_) => _launcher(
        (context) => showAccountShareDialog(
          context,
          jamiId: 'a' * 40,
          displayName: 'You',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_share_identity_700x700');
  });

  testWidgets('pending invitation is visible during onboarding at 200% text', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    state.inviteContinuation.stage('sybl://add/$_mara?name=Mara');
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      textScaler: const TextScaler.linear(2),
      child: (state) => OnboardingScreen(state: state),
    );
    await _expectGolden(tester, 'mobile_pending_invite_390x844_text200');
    await tester.ensureVisible(
      find.byKey(const ValueKey('onboarding-create-choice')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invitation confirmation displays one explicit named Add action',
    (tester) async {
      final state = await _fixtureState();
      addTearDown(state.dispose);
      state.inviteContinuation.stage('sybl://add/$_mara?name=Mara');
      final record = state.inviteContinuation.pending!;
      await _pumpSurface(
        tester,
        state: state,
        size: const Size(700, 500),
        platform: TargetPlatform.windows,
        child: (state) => _launcher((context) async {
          await showAddFriendDialog(
            context,
            state: state,
            initialInvite: record.invite,
            continuation: record,
          );
        }),
      );
      await tester.tap(find.byKey(const ValueKey('test-open-surface')));
      await tester.pumpAndSettle();
      expect(find.text('Add Mara'), findsOneWidget);
      await _expectDialogGolden(tester, 'desktop_confirm_invite_700x500');
    },
  );

  testWidgets('add friend dialog is render correctly', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      child: (state) => _launcher((context) async {
        await showAddFriendDialog(context, state: state);
      }),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_add_friend_700x500');
  });

  testWidgets('mobile Add leads with scanning and keeps the keyboard closed', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      child: (state) => _launcher((context) async {
        await showAddFriendDialog(context, state: state);
      }),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scan-friend-qr')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await _expectDialogGolden(tester, 'mobile_add_friend_390x844');
  });

  testWidgets('mobile invitation presents the QR on its own screen', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      child: (_) => _launcher(
        (context) => showAccountShareDialog(
          context,
          jamiId: 'a' * 40,
          displayName: 'You',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('share-friend-invitation')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(Scaffold).last,
      matchesGoldenFile(_goldenPath('mobile_invite_friend_390x844')),
    );
  });

  testWidgets('invite a friend stays separate from Add friend', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 700),
      platform: TargetPlatform.windows,
      child: (_) => _launcher(
        (context) => showAccountShareDialog(
          context,
          jamiId: 'a' * 40,
          displayName: 'You',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_share_invite_700x700');
  });

  testWidgets('configured invitation keeps the QR as primary action', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 700),
      platform: TargetPlatform.windows,
      child: (_) => _launcher(
        (context) => showAccountShareDialog(
          context,
          jamiId: _mara,
          displayName: 'Mara',
          httpsOrigin: 'https://invites.example.test',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    expect(find.text('Show this to your friend'), findsOneWidget);
    await _expectDialogGolden(tester, 'desktop_share_https_invite_700x700');
    expect(tester.takeException(), isNull);
  });

  testWidgets('create group dialog is render correctly', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(800, 650),
      platform: TargetPlatform.windows,
      child: (state) => _launcher((context) async {
        await showCreateGroupDialog(context, state: state);
      }),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_create_group_800x650');
  });

  testWidgets('rename group dialog is render correctly', (tester) async {
    final state = await _fixtureState(selectGroup: true);
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      child: (state) => _launcher(
        (context) => showRenameGroupDialog(
          context,
          state: state,
          group: state.groups['conversation-crew']!,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_rename_group_700x500');
  });

  testWidgets('invite group members dialog is render correctly', (
    tester,
  ) async {
    final state = await _fixtureState(selectGroup: true);
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 600),
      platform: TargetPlatform.windows,
      child: (state) => _launcher(
        (context) => showInviteGroupMembersDialog(
          context,
          state: state,
          group: state.groups['conversation-crew']!,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_invite_group_members_700x600');
  });

  for (final mobile in [false, true]) {
    testWidgets(
      'edit name keeps only the necessary controls (${mobile ? 'phone200' : 'desktop'})',
      (tester) async {
        final state = await _fixtureState();
        state.seedCaptureStateForTesting(
          settingsDocumentWritable: true,
          resolved: true,
        );
        await _pumpSurface(
          tester,
          state: state,
          size: mobile ? const Size(390, 844) : const Size(700, 500),
          platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
          textScaler: TextScaler.linear(mobile ? 2 : 1),
        );
        await tester.tap(find.byKey(const ValueKey('open-settings-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('edit-display-name')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('display-name-field')),
          findsOneWidget,
        );
        expect(
          find.text('Friends see this name. Your Friend ID does not change.'),
          findsNothing,
        );
        expect(find.text('Save').hitTestable(), findsOneWidget);
        expect(find.text('Cancel').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _expectDialogGolden(
          tester,
          mobile
              ? 'mobile_edit_name_390x844_text200'
              : 'desktop_edit_name_700x500',
        );
      },
    );
  }

  testWidgets('profile menu exposes status and keeps settings direct', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    state.seedCaptureStateForTesting(
      settingsDocumentWritable: true,
      resolved: true,
    );
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(800, 700),
      platform: TargetPlatform.windows,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings-button')));
    await tester.pumpAndSettle();
    expect(find.text('PROFILE'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('account-menu-button')));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Go offline'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.widgetWithText(PopupMenuItem<String>, 'Go offline'),
          )
          .enabled,
      isTrue,
    );
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile(_goldenPath('desktop_profile_menu_800x700')),
    );
    state.accountId = 'replacement-account';
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Go offline'));
    await tester.pumpAndSettle();
    expect(
      state.appearOffline,
      isFalse,
      reason: 'a stale menu must not change another identity',
    );
  });

  for (final phone in [false, true]) {
    testWidgets('link source dialog fits ${phone ? "phone200" : "desktop"}', (
      tester,
    ) async {
      final state = await _fixtureState();
      addTearDown(state.dispose);
      await _pumpSurface(
        tester,
        state: state,
        size: phone ? const Size(390, 844) : const Size(700, 500),
        platform: phone ? TargetPlatform.android : TargetPlatform.windows,
        textScaler: TextScaler.linear(phone ? 2 : 1),
        child: (state) => _launcher(
          (context) => showDevicePairingDialog(
            context,
            state: state,
            destination: false,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('test-open-surface')));
      await tester.pumpAndSettle();
      expect(find.text('Link another device'), findsOneWidget);
      await _expectDialogGolden(
        tester,
        phone
            ? 'mobile_link_source_390x844_text200'
            : 'desktop_link_source_700x500',
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final phone in [false, true]) {
    testWidgets(
      'backup password dialog fits ${phone ? "phone200" : "desktop"}',
      (tester) async {
        final state = await _fixtureState();
        addTearDown(state.dispose);
        await _pumpSurface(
          tester,
          state: state,
          size: phone ? const Size(390, 844) : const Size(700, 500),
          platform: phone ? TargetPlatform.android : TargetPlatform.windows,
          textScaler: TextScaler.linear(phone ? 2 : 1),
          child: (_) => _launcher((context) async {
            await showPassphraseDialog(
              context,
              title: 'Back up your identity',
              subtitle: 'Add a password to protect your identity!',
              actionLabel: 'Create backup',
              confirm: true,
              allowEmpty: true,
            );
          }),
        );
        await tester.tap(find.byKey(const ValueKey('test-open-surface')));
        await tester.pumpAndSettle();
        await _expectDialogGolden(
          tester,
          phone
              ? 'mobile_backup_identity_390x844_text200'
              : 'desktop_backup_identity_700x500',
        );
        await tester.tap(
          find.byKey(const ValueKey('backup-password-protection')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        await _expectDialogGolden(
          tester,
          phone
              ? 'mobile_unprotected_backup_warning_390x844_text200'
              : 'desktop_unprotected_backup_warning_700x500',
        );
      },
    );
  }

  testWidgets('linked devices dialog is render correctly', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(800, 700),
      platform: TargetPlatform.windows,
      child: (state) => _launcher(
        (context) => showLinkedDevicesDialog(context, state: state),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text('Phone B'), findsOneWidget);
    await _expectDialogGolden(tester, 'desktop_linked_devices_800x700');
  });

  testWidgets('device revocation confirmation is render correctly', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    await _pumpSurface(
      tester,
      state: state,
      size: const Size(800, 700),
      platform: TargetPlatform.windows,
      child: (state) => _launcher(
        (context) => showLinkedDevicesDialog(context, state: state),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-open-surface')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('revoke-device-phone-device')));
    await tester.pumpAndSettle();
    await _expectDialogGolden(tester, 'desktop_revoke_device_800x700');
  });

  testWidgets('desktop window chrome matches the canonical warm shell', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      child: (state) => WindowsChrome(
        jami: state.jami,
        child: HomeScreen(state: state),
      ),
    );

    await _expectGolden(tester, 'windows_chrome_700x500');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop group matches collections, rooms, and stacked avatars', (
    tester,
  ) async {
    final state = await _fixtureState(selectGroup: true);
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(1280, 800),
      platform: TargetPlatform.windows,
    );

    expect(find.text('The Crew'), findsWidgets);
    expect(find.textContaining('3 members'), findsWidgets);
    expect(find.byKey(const ValueKey('group-topic-general')), findsOneWidget);
    await _expectGolden(tester, 'desktop_group_1280x800');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop group settings keep the title and editor unclipped', (
    tester,
  ) async {
    final state = await _fixtureState(selectGroup: true);
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(900, 700),
      platform: TargetPlatform.windows,
    );
    await tester.tap(find.byKey(const ValueKey('group-settings-button')));
    await tester.pumpAndSettle();

    expect(find.text('The Crew'), findsWidgets);
    expect(find.textContaining('You are an admin'), findsOneWidget);
    final rename = find.byKey(const ValueKey('edit-group-identity-button'));
    expect(rename, findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Edit'), findsNothing);
    expect(
      find.byKey(const ValueKey('group-member-card'), skipOffstage: false),
      findsNWidgets(3),
    );
    expect(
      find.byKey(const ValueKey('add-group-member-button')),
      findsOneWidget,
    );
    final addPeople = find.widgetWithText(OutlinedButton, 'Add people');
    final addCollection = find.widgetWithText(OutlinedButton, 'New collection');
    expect(addPeople, findsOneWidget);
    expect(addCollection, findsOneWidget);
    final memberCards = find.byKey(
      const ValueKey('group-member-card'),
      skipOffstage: false,
    );
    expect(
      tester.getTopLeft(addPeople).dy,
      greaterThan(tester.getBottomLeft(memberCards.last).dy),
    );
    expect(
      tester.getTopLeft(addCollection).dy,
      greaterThan(tester.getBottomLeft(find.text('No conversations')).dy),
    );
    expect(find.text('Add conversation'), findsWidgets);
    expect(find.text('COLLECTIONS & CONVERSATIONS'), findsOneWidget);
    await expectLater(
      find.byType(Dialog),
      matchesGoldenFile(_goldenPath('desktop_group_settings_900x700')),
    );
    expect(tester.takeException(), isNull);
  });

  // The conversation golden above contains only file cards, so it passed
  // unchanged when the text-message layout was rewritten on 2026-07-28 - it
  // never rendered a text message at all. This covers both directions
  // directly: every message has its own shrink-wrapped bubble, with avatar and
  // name shown once for an incoming block.
  testWidgets('text messages use shrink-wrapped bubbles in both directions', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    final scope = ConversationScope(
      accountId: 'account',
      peerId: _mara,
      conversationId: 'conversation-mara',
    );
    // LOCAL, deliberately: _formatTime renders createdAt.toLocal(), so a UTC
    // fixture bakes the author's timezone into the golden bytes and fails on
    // any runner in another zone. A local DateTime renders identically
    // everywhere.
    final at = DateTime(2026, 3, 28, 9, 0);
    ConversationTimelineItem text(
      String id,
      String body,
      TimelineDirection direction,
    ) => TimelineTextItem(
      scope: scope,
      daemonId: id,
      versionId: '$id-v1',
      authorId: direction == TimelineDirection.outgoing ? state.jamiId : _mara,
      direction: direction,
      createdAt: at,
      text: body,
    );

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      // Material ancestor: without one, Flutter paints its missing-Material
      // debug underlines over every glyph and the golden is unreadable.
      child: (state) => Material(
        color: Warm.theme(_visualPreset).colorScheme.surface,
        child: ConversationTimelineView(
          state: state,
          live: const [],
          legacyFiles: const [],
          timeline: [
            text('m1', 'did the build finish?', TimelineDirection.incoming),
            text('m2', 'yep', TimelineDirection.outgoing),
            text(
              'm3',
              'good. the long one wraps so we can see the maximum width behave '
                  'itself instead of running edge to edge across the stage.',
              TimelineDirection.incoming,
            ),
            text('m4', 'on it', TimelineDirection.outgoing),
          ],
        ),
      ),
    );

    await _expectGolden(tester, 'timeline_text_messages_700x500');
    expect(tester.takeException(), isNull);
  });

  // The block rule: consecutive same-author messages inside the five-minute
  // window share ONE avatar/name header; a gap (or the other author) starts a
  // fresh block. Individual bubbles stay visually conjoined inside the block.
  testWidgets('consecutive same-author messages group under one header', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    final scope = ConversationScope(
      accountId: 'account',
      peerId: _mara,
      conversationId: 'conversation-mara',
    );
    // Local, for the same timezone-portability reason as the golden above.
    final start = DateTime(2026, 3, 28, 9, 0);
    ConversationTimelineItem text(
      String id,
      String body,
      TimelineDirection direction,
      Duration afterStart,
    ) => TimelineTextItem(
      scope: scope,
      daemonId: id,
      versionId: '$id-v1',
      authorId: direction == TimelineDirection.outgoing ? state.jamiId : _mara,
      direction: direction,
      createdAt: start.add(afterStart),
      text: body,
    );

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
      child: (state) => Material(
        color: Warm.theme(_visualPreset).colorScheme.surface,
        child: ConversationTimelineView(
          state: state,
          live: const [],
          legacyFiles: const [],
          timeline: [
            text(
              'g1',
              'first message of the block',
              TimelineDirection.incoming,
              Duration.zero,
            ),
            text(
              'g2',
              'second one, same block — no second header',
              TimelineDirection.incoming,
              const Duration(minutes: 1),
            ),
            text(
              'g3',
              'third, still under the one avatar',
              TimelineDirection.incoming,
              const Duration(minutes: 2),
            ),
            text(
              'g4',
              'a twenty-minute gap starts a fresh block with its own header',
              TimelineDirection.incoming,
              const Duration(minutes: 22),
            ),
            text(
              'g5',
              'two outgoing in a row',
              TimelineDirection.outgoing,
              const Duration(minutes: 23),
            ),
            text(
              'g6',
              'stack tighter when grouped',
              TimelineDirection.outgoing,
              const Duration(minutes: 23, seconds: 30),
            ),
          ],
        ),
      ),
    );

    await _expectGolden(tester, 'timeline_grouped_messages_700x500');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop settings scales across a larger window', (tester) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(1280, 800),
      platform: TargetPlatform.windows,
    );
    await tester.tap(find.byKey(const ValueKey('open-settings-button')));
    await tester.pumpAndSettle();

    final strip = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('settings-section-rail-strip')),
    );
    expect(strip.color, Colors.transparent);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-section-rail-strip')))
          .width,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-section-rail-strip')))
          .height,
      lessThanOrEqualTo(800),
    );

    await _expectGolden(tester, 'desktop_settings_1280x800');
    await tester.tap(find.byKey(const ValueKey('settings-jump-appearance')));
    await tester.pumpAndSettle();
    final profile = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('settings-jump-active-Profile')),
    );
    final appearance = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('settings-jump-active-Appearance')),
    );
    expect(profile.constraints!.maxWidth, 40);
    expect(appearance.constraints!.maxWidth, 48);
    expect(find.byKey(const ValueKey('settings-section-rail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop audio call stays in the conversation stage', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'audio-call',
      dir: CallDir.outgoing,
      peerId: _mara,
      state: 'CURRENT',
      microphonePolicyApplied: true,
      everConnected: true,
    );

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
    );

    expect(find.byKey(const ValueKey('audio-call-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-active-call-button')), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    await _expectGolden(tester, 'desktop_audio_call_700x500');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop header controls use the active call and monitor', (
    tester,
  ) async {
    final jami = _VisualJamiClient();
    final state = await _fixtureState(jami: jami);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'audio-call',
      dir: CallDir.outgoing,
      peerId: _mara,
      state: 'CURRENT',
      microphonePolicyApplied: true,
      everConnected: true,
    );

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
    );
    for (final key in const [
      ValueKey('audio-call-mic'),
      ValueKey('audio-call-video'),
      ValueKey('audio-call-share'),
      ValueKey('audio-call-leave'),
    ]) {
      final control = find.byKey(key);
      expect(control, findsOneWidget);
      expect(tester.getSize(control).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
    }

    await tester.tap(find.byKey(const ValueKey('audio-call-mic')));
    await tester.pumpAndSettle();
    expect(jami.lastMicMuted, isTrue);

    await tester.tap(find.byKey(const ValueKey('audio-call-share')));
    await tester.pumpAndSettle();
    expect(jami.lastScreenSource, 'monitor:primary');
    expect(state.call?.sharingScreen, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop header preserves push-to-talk hold semantics', (
    tester,
  ) async {
    final jami = _VisualJamiClient();
    final state = await _fixtureState(jami: jami);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'ptt-call',
      dir: CallDir.outgoing,
      peerId: _mara,
      state: 'CURRENT',
      micMuted: true,
      micMode: MicrophoneMode.pushToTalk,
      microphonePolicyApplied: true,
      everConnected: true,
    );

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(700, 500),
      platform: TargetPlatform.windows,
    );
    final control = find.byKey(const ValueKey('audio-call-mic'));
    final gesture = await tester.startGesture(tester.getCenter(control));
    await tester.pumpAndSettle();
    expect(jami.lastMicMuted, isFalse);
    expect(state.call?.pushToTalkPressed, isTrue);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(jami.lastMicMuted, isTrue);
    expect(state.call?.pushToTalkPressed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile People follows the Windows visual language', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
    );

    await _expectGolden(tester, 'mobile_people_390x844');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile group shows member count and inline rooms', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byKey(const ValueKey('group-conversation-crew')));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 members'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-topic-general')), findsOneWidget);
    await _expectGolden(tester, 'mobile_group_390x844');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile conversation remains a focused single pane', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
    );
    await tester.tap(find.byKey(const ValueKey('friend-$_mara')));
    await tester.pumpAndSettle();

    await _expectGolden(tester, 'mobile_conversation_390x844');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile settings remain readable at 200 percent text', (
    tester,
  ) async {
    final state = await _fixtureState();
    addTearDown(state.dispose);

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      textScaler: const TextScaler.linear(2),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-section-menu-button')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('settings-section-rail')),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
    expect(find.byKey(const ValueKey('edit-display-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-profile')), findsOneWidget);

    await _expectGolden(tester, 'mobile_settings_390x844_text200');

    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -120),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-section-rail')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('settings-section-rail')),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );

    expect(tester.takeException(), isNull);
  });

  // Private comparison captures do not add a required checked-in golden.
  if (_captureDirectory.isNotEmpty) {
    testWidgets('theme comparison mobile connected call', (tester) async {
      final state = await _fixtureState(showSpeakerControl: true);
      state.call = CallSession(
        callId: 'synthetic-mobile-call',
        dir: CallDir.outgoing,
        peerId: _mara,
        state: 'CURRENT',
        microphonePolicyApplied: true,
        everConnected: true,
      );
      await _pumpSurface(
        tester,
        state: state,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
        child: (state) => InCallScreen(state: state),
      );
      expect(find.byKey(const ValueKey('call-mic-control')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('call-hang-up-control')),
        findsOneWidget,
      );
      await _expectGolden(tester, 'mobile_audio_call_390x844');
    });
  }

  testWidgets('mobile audio call remains readable at 200 percent text', (
    tester,
  ) async {
    final state = await _fixtureState(showSpeakerControl: true);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'mobile-audio',
      dir: CallDir.outgoing,
      peerId: _mara,
      state: 'CURRENT',
      microphonePolicyApplied: true,
      everConnected: true,
    );

    await _pumpSurface(
      tester,
      state: state,
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      textScaler: const TextScaler.linear(2),
      child: (state) => InCallScreen(state: state),
    );

    for (final label in const [
      'Mic on',
      'Camera',
      'Earpiece',
      'Share',
      'Leave',
    ]) {
      expect(find.text(label), findsNothing);
    }
    final controls = [
      find.byKey(const ValueKey('call-mic-control')),
      find.byKey(const ValueKey('call-camera-control')),
      find.byKey(const ValueKey('call-speaker-control')),
      find.byKey(const ValueKey('call-share-control')),
      find.byKey(const ValueKey('call-hang-up-control')),
    ];
    final centers = controls.map(tester.getCenter).toList();
    expect(centers.last.dy, closeTo(centers.first.dy, .01));
    for (final center in centers.sublist(1, 4)) {
      expect(center.dy, closeTo(centers[1].dy, .01));
      expect(center.dy, lessThan(centers.first.dy));
    }

    await _expectGolden(tester, 'mobile_audio_call_390x844_text200');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detected capture gate matches the canonical Windows surface',
    (tester) async {
      final state = await _fixtureState();
      addTearDown(state.dispose);
      state.seedCaptureStateForTesting(
        activityActive: true,
        applied: WindowCaptureProtectionStatus.none,
      );

      await _pumpSurface(
        tester,
        state: state,
        size: const Size(700, 500),
        platform: TargetPlatform.windows,
        child: (state) => CaptureConsentGate(state: state),
      );

      await _expectGolden(tester, 'capture_consent_gate_700x500');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'detected capture gate remains readable at 200 percent text',
    (tester) async {
      final state = await _fixtureState();
      addTearDown(state.dispose);
      state.seedCaptureStateForTesting(
        activityActive: true,
        applied: WindowCaptureProtectionStatus.none,
      );

      await _pumpSurface(
        tester,
        state: state,
        size: const Size(700, 500),
        platform: TargetPlatform.windows,
        textScaler: const TextScaler.linear(2),
        child: (state) => CaptureConsentGate(state: state),
      );

      await _expectGolden(tester, 'capture_consent_gate_700x500_text200');
      for (final key in const [
        ValueKey('capture-consent-show'),
        ValueKey('capture-consent-show-always'),
        ValueKey('capture-consent-hide'),
      ]) {
        final action = find.byKey(key);
        await tester.ensureVisible(action);
        await tester.pump();
        expect(action.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
