import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/screens/home.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/account_share.dart';
import 'package:sybl/ui/settings_pane.dart';
import 'package:sybl/ui/google_wake_choice.dart';
import 'package:sybl/ui/settings_profile.dart';
import 'package:sybl/ui/settings_previews.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sybl/ui/sybl_ui.dart';
import 'package:sybl/ui/windows_chrome.dart';

const _jamiId = 'abcdef0123456789abcdef0123456789abcdef01';

final class _SettingsJami extends JamiClient {
  @override
  bool get usesNativeAppSettingsStore => false;

  final appliedAndroidProtection = <bool>[];
  final messagePreviews = <bool>[];
  final presenceColors = <String>[];
  final backgroundWakeCalls = <bool>[];

  @override
  Stream<JamiEvent> events() => const Stream<JamiEvent>.empty();

  @override
  Future<WindowCaptureProtectionStatus> windowCaptureProtectionStatus() async =>
      WindowCaptureProtectionStatus.exclude;

  @override
  Future<WindowCaptureProtectionStatus> applyAndroidCaptureProtection({
    required bool protect,
  }) async {
    appliedAndroidProtection.add(protect);
    return protect
        ? WindowCaptureProtectionStatus.exclude
        : WindowCaptureProtectionStatus.none;
  }

  @override
  Future<String> myJamiId() async => '';

  @override
  Future<void> setMessageNotificationPreview(
    bool showMessage, {
    required bool appLockEnabled,
  }) async {
    messagePreviews.add(showMessage);
  }

  @override
  Future<void> setPresenceMetadata({
    required bool shareActivity,
    required String color,
  }) async {
    presenceColors.add(color);
  }

  @override
  Future<bool> backgroundWakeAvailability() async => true;

  @override
  Future<void> setConnectionProfile(
    String profile, {
    String? expectedAccountId,
    String dhtBootstrap = '',
    String turnServer = '',
    String turnRealm = '',
    String turnUser = '',
    String turnPassword = '',
  }) async {}

  @override
  Future<bool> setReliableBackgroundNotifications({
    required bool enabled,
    required String connectionProfile,
    String? expectedAccountId,
  }) async {
    backgroundWakeCalls.add(enabled);
    return true;
  }
}

Future<AppState> _initializedState(
  WidgetTester tester,
  _SettingsJami jami,
) async => (await tester.runAsync(() async {
  // Future owners and initialization must use the same real async zone.
  final state = AppState(jami, await SharedPreferences.getInstance());
  await state.init();
  return state;
}))!;

class _DelayedSettingsStore extends InMemorySharedPreferencesStore {
  _DelayedSettingsStore() : super.withData({});
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (hold && key == 'flutter.appSettings') {
      entered.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  testWidgets('desktop exposes its outbound Google wake choice', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reliable-background-notifications-switch')),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    expect(find.text('Wake friends’ phones'), findsOneWidget);
    expect(state.googleWakeAllowed, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'Google choice fits large text and dismissal stays off: $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = platform == TargetPlatform.android
              ? const Size(390, 844)
              : const Size(700, 500);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        SharedPreferences.setMockInitialValues({});
        final state = await _initializedState(tester, _SettingsJami());
        addTearDown(state.dispose);
        state.seedCaptureStateForTesting(resolved: true);
        final consentBoundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: consentBoundary,
            child: MaterialApp(
              theme: Warm.theme().copyWith(platform: platform),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showGoogleWakeChoice(context, state),
                    child: const Text('Choose'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Use Google').hitTestable(), findsOneWidget);
        expect(find.text('Keep Google off').hitTestable(), findsOneWidget);
        final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
        if (output != null) {
          await tester.runAsync(() async {
            final boundary =
                consentBoundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/google-choice-${platform.name}-text200.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        Navigator.of(tester.element(find.text('Use Google'))).pop();
        await tester.pumpAndSettle();
        expect(state.googleWakeChoiceMade, isFalse);
        expect(state.googleWakeAllowed, isFalse);
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
        state.setProtectedSurfaceLocked(true);
        state.setProtectedSurfaceLocked(false);
        await tester.tap(find.text('Use Google'));
        await tester.pumpAndSettle();
        expect(
          state.googleWakeChoiceMade,
          isFalse,
          reason: 'A dialog opened before locking cannot grant consent.',
        );
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keep Google off'));
        await tester.pumpAndSettle();
        expect(state.googleWakeChoiceMade, isTrue);
        expect(state.googleWakeAllowed, isFalse);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'desktop scrolling keeps profile widgets and fallback tracks after resize',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await _initializedState(tester, _SettingsJami());
      addTearDown(state.dispose);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: SettingsPane(
              state: state,
              onClose: () {},
              onOpenDiagnostics: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final profile = tester.widget<SettingsProfile>(
        find.byType(SettingsProfile),
      );
      final scroll = tester
          .widget<SingleChildScrollView>(
            find
                .descendant(
                  of: find.byType(SettingsPane),
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          )
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SettingsProfile>(find.byType(SettingsProfile)),
        same(profile),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('settings-section-progress')),
            )
            .label,
        'Advanced, remaining',
      );
      tester.view.physicalSize = const Size(1280, 350);
      await tester.pumpAndSettle();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('settings-jump-advanced')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'network controls disable during a settings save and recover afterward',
    (tester) async {
      SharedPreferences.resetStatic();
      final previous = SharedPreferencesStorePlatform.instance;
      final store = _DelayedSettingsStore();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = previous;
      });
      final state = await _initializedState(tester, _SettingsJami());
      addTearDown(state.dispose);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: state,
              builder: (_, _) => SettingsPane(
                state: state,
                onClose: () {},
                onOpenDiagnostics: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final offline = find.byWidgetPredicate(
        (widget) =>
            widget is Switch && widget.onChanged == state.setAppearOffline,
      );
      expect(offline, findsOneWidget);
      store.hold = true;
      final save = state.setChatMotionEnabled(false);
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);
      expect(state.canChangeOnlineStatus, isFalse);
      expect(state.canChangeConnectionProfile, isFalse);
      expect(offline, findsNothing);
      final localButton = find.ancestor(
        of: find.text('Local network only'),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(localButton.first).onTap, isNull);
      store.release.complete();
      await tester.pumpAndSettle();
      expect(await save, isTrue);
      expect(state.canChangeOnlineStatus, isTrue);
      expect(state.canChangeConnectionProfile, isTrue);
      expect(offline, findsOneWidget);
    },
  );

  for (final size in [
    const Size(280, 490),
    const Size(320, 490),
    const Size(400, 490),
    const Size(620, 490),
    const Size(675, 490),
    const Size(686, 490),
    const Size(400, 493),
    const Size(676, 493),
    const Size(1100, 800),
    const Size(1920, 1032),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('normal desktop settings at $size text $scale', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final state = await _initializedState(tester, _SettingsJami());
        addTearDown(state.dispose);
        state.screen = Screen.home;
        state.accountId = 'fixture-account';
        state.jamiId = _jamiId;
        state.displayName = 'PC';
        state.appSettings = state.appSettings
            .withIdentityColor(IdentityColor.slate)
            .withMessageTimestampStyle(MessageTimestampStyle.apple);
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: RepaintBoundary(
                key: boundary,
                child: WindowsChrome(
                  jami: state.jami,
                  child: HomeScreen(state: state),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'initial HomeScreen layout',
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('windows-title-bar')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('close-settings-button')),
          findsNothing,
          reason: 'A narrow Windows window must not acquire a phone header',
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('settings-list'))).dy,
          greaterThanOrEqualTo(
            tester
                .getBottomLeft(find.byKey(const ValueKey('windows-title-bar')))
                .dy,
          ),
          reason: 'Settings content stays below the native caption controls',
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('windows-title-bar')))
              .height,
          34,
        );
        expect(find.byType(Scrollbar), findsNothing);
        final profileAvatar = find.descendant(
          of: find.byType(SettingsPane),
          matching: find.byType(SyblAvatar),
        );
        expect(profileAvatar, findsOneWidget);
        expect(
          tester.widget<SyblAvatar>(profileAvatar).color,
          tester.element(profileAvatar).syblColors.sage,
        );
        Future<void> capture(String stage) async {
          final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
          if (output == null) return;
          await tester.runAsync(() async {
            final surface =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await surface.toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/settings-normal-${size.width.round()}x${size.height.round()}-text${(scale * 100).round()}-$stage.png',
              ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
            } finally {
              image.dispose();
            }
          });
        }

        for (final preset in ['calm', 'cozy', 'midnight']) {
          final palette = Warm.palette(
            AppearancePreset.values.firstWhere(
              (value) => value.storageValue == preset,
            ),
          );
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(ValueKey('appearance-preview-$preset')),
            );
            final image = await boundary.toImage();
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final counts = <int, int>{};
              for (var offset = 0; offset < bytes.lengthInBytes; offset += 4) {
                final rgb =
                    (bytes.getUint8(offset) << 16) |
                    (bytes.getUint8(offset + 1) << 8) |
                    bytes.getUint8(offset + 2);
                counts.update(rgb, (count) => count + 1, ifAbsent: () => 1);
              }
              double share(Color color) =>
                  (counts[color.toARGB32() & 0xffffff] ?? 0) /
                  (image.width * image.height);
              expect(share(palette.desk), greaterThan(.15));
              expect(share(palette.surface), greaterThan(.4));
              expect(share(palette.amber), lessThan(.08));
              expect(share(palette.ink), lessThan(.08));
            } finally {
              image.dispose();
            }
          });
          expect(
            tester
                .getSize(find.byKey(ValueKey('appearance-preview-$preset')))
                .width,
            size.width < 400 ? greaterThanOrEqualTo(72) : greaterThan(80),
          );
        }
        await capture('profile-outside');
        final suggested = IdentityColor.recommended(
          const [],
          current: IdentityColor.automaticFor(state.jamiId),
        ).first;
        await tester.runAsync(() => state.setIdentityColor(suggested));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));
        await capture('profile-transition');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('identity-color-divider')),
          findsNothing,
        );
        await capture('profile');
        expect(
          find.byKey(const ValueKey('settings-jump-profile')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-section-menu-button')),
          findsNothing,
        );
        expect(find.text('Back'), findsNothing);
        for (final section in [
          'profile',
          'appearance',
          'notifications',
          'voice',
          'connection',
          'files',
          'safety',
          'advanced',
        ]) {
          final jump = find.byKey(ValueKey('settings-jump-$section'));
          expect(jump.hitTestable(), findsOneWidget);
          expect(tester.getSize(jump), const Size(48, 48));
          await tester.tap(jump);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (section == 'appearance') {
            for (final preset in ['cozy', 'midnight']) {
              expect(
                tester
                    .getTopLeft(find.byKey(ValueKey('appearance-$preset')))
                    .dy,
                tester
                    .getTopLeft(find.byKey(const ValueKey('appearance-calm')))
                    .dy,
              );
            }
            final samples = find.byType(VibePreview);
            for (var index = 1; index < 4; index++) {
              expect(
                tester.getTopLeft(samples.at(index)).dy,
                tester.getTopLeft(samples.first).dy,
              );
            }
            final controls = tester.getRect(
              find.byKey(const ValueKey('vibe-adjustments')),
            );
            final choices = tester.getRect(
              find.byKey(const ValueKey('choice-Vibe-halloween')),
            );
            if (controls.left >= choices.right) {
              expect(controls.center.dy, closeTo(choices.center.dy, 1));
              expect(controls.left - choices.right, closeTo(8, 1));
            } else {
              expect(controls.bottom, lessThan(choices.top));
            }
            expect(find.byType(Slider), findsNothing);
            await capture('appearance');
            await tester.tap(find.byKey(const ValueKey('vibe-opacity-button')));
            await tester.pumpAndSettle();
            await capture('appearance-opacity');
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            final control = find.byKey(const ValueKey('chat-motion-switch'));
            await tester.ensureVisible(control);
            await tester.pumpAndSettle();
            final label = tester.getRect(find.text('Animations'));
            final toggle = tester.getRect(control);
            expect(toggle.right - label.left, lessThanOrEqualTo(640));
            expect(toggle.left, greaterThan(label.right));
            expect(toggle.center.dy, closeTo(label.center.dy, 1));
            final typing = find.byKey(const ValueKey('chat-activity-switch'));
            expect(tester.getRect(typing).right, closeTo(toggle.right, 1));
            if (scale == 1) {
              // The Window animations label wraps at the narrowest desktop size.
              final expectedTypingOffset = size.width == 280 ? 108 : 96;
              expect(
                tester.getRect(typing).center.dy - toggle.center.dy,
                closeTo(expectedTypingOffset, 1),
              );
            }
            await tester.ensureVisible(
              find.byKey(const ValueKey('message-time-placement')),
            );
            await tester.pumpAndSettle();
            expect(
              find
                  .byKey(const ValueKey('message-time-explanation'))
                  .hitTestable(),
              findsOneWidget,
            );
            await capture('message-times');
          }
        }
        await tester.ensureVisible(
          find.byKey(const ValueKey('reset-doorlight-button')),
        );
        await tester.pumpAndSettle();
        await capture('advanced-reset');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('review reset is explicit and keeps alerts and Holograms off', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'displayName': 'Me',
      'accountId': 'acc1',
    });
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    state.accountId = 'acc1';
    state.screen = Screen.home;
    state.appSettings = AppSettings(
      friendPreferencesReviewRequired: true,
      globalMicrophoneMode: MicrophoneMode.pushToTalk,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (_, _) => SettingsPane(
              state: state,
              onClose: () {},
              onOpenDiagnostics: () {},
            ),
          ),
        ),
      ),
    );
    final reset = find.text('Reset friend preferences');
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(state.appSettings.friendPreferencesReviewRequired, isTrue);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(state.appSettings.friendPreferencesReviewRequired, isTrue);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset preferences'));
    await tester.pumpAndSettle();
    expect(state.appSettings.friendPreferencesReviewRequired, isFalse);
    expect(state.appSettings.messageAlertsEnabled, isFalse);
    expect(state.appSettings.hologramPresentationEnabled, isFalse);
    expect(state.appSettings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
    expect(tester.takeException(), isNull);
  });
  setUpAll(() async {
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader('monospace')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'settings categories keep everyday controls separate from advanced controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await _initializedState(tester, _SettingsJami());
      addTearDown(state.dispose);
      state.strictBootstrap = 'bootstrap.example.invalid';
      final phone = defaultTargetPlatform == TargetPlatform.android;
      final size = phone ? const Size(390, 844) : const Size(1280, 800);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: defaultTargetPlatform),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(phone ? 2 : 1),
            ),
            child: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: SettingsPane(
                  state: state,
                  onClose: () {},
                  onOpenDiagnostics: () {},
                ),
              ),
            ),
          ),
        ),
      );
      final headings = [
        'PROFILE',
        'APPEARANCE',
        'NOTIFICATIONS',
        'CALLS',
        'NETWORK',
        'FILES & STORAGE',
        'PRIVACY & SECURITY',
        'ADVANCED',
      ];
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      for (var i = 1; i < headings.length; i++) {
        expect(top(headings[i]), greaterThan(top(headings[i - 1])));
      }
      void inside(String control, String section, String next) {
        expect(top(control), greaterThan(top(section)));
        expect(top(control), lessThan(top(next)));
      }

      inside('Devices', 'PROFILE', 'APPEARANCE');
      inside('Go offline', 'NETWORK', 'FILES & STORAGE');
      inside('Back up your identity', 'FILES & STORAGE', 'PRIVACY & SECURITY');
      inside('Share activity', 'PRIVACY & SECURITY', 'ADVANCED');
      expect(top('Shared files scanned'), greaterThan(top('ADVANCED')));
      expect(top('Self-hosted'), greaterThan(top('ADVANCED')));
      expect(
        find.text('Connect over the internet. Local network discovery is off.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-about')).hitTestable(),
        findsNothing,
      );
      expect(find.byType(Scrollbar), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-section-rail')),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      Future<void> capture(String section) async {
        final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
        if (output == null) return;
        await tester.runAsync(() async {
          final surface =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await surface.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$output/settings-$section-${size.width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
          } finally {
            image.dispose();
          }
        });
      }

      for (final preset in ['calm', 'cozy', 'midnight']) {
        expect(
          tester
              .getSize(find.byKey(ValueKey('appearance-preview-$preset')))
              .width,
          greaterThan(80),
        );
      }
      await capture('profile');
      for (final section in ['appearance', 'connection', 'advanced']) {
        if (phone) {
          await tester.tap(
            find.byKey(const ValueKey('settings-section-menu-button')),
          );
          await tester.pump();
        }
        await tester.tap(find.byKey(ValueKey('settings-jump-$section')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 1400));
        expect(tester.takeException(), isNull);
        if (section == 'advanced') {
          expect(
            tester
                .renderObject<RenderParagraph>(find.text('200 items'))
                .didExceedMaxLines,
            isFalse,
          );
          if (!phone) {
            expect(
              find.byKey(const ValueKey('settings-section-progress')),
              findsOneWidget,
            );
            final about = tester.getRect(
              find.byKey(const ValueKey('settings-about')),
            );
            final reset = tester.getRect(
              find.byKey(const ValueKey('reset-doorlight-button')),
            );
            expect(about.left, closeTo(reset.left, .01));
            expect(about.width, closeTo(reset.width, .01));
            final marker = tester.widget<AnimatedContainer>(
              find.byKey(const ValueKey('settings-jump-active-Advanced')),
            );
            expect(
              (marker.decoration! as BoxDecoration).color,
              isNot(Colors.transparent),
            );
          }
          await tester.ensureVisible(
            find.byKey(const ValueKey('settings-about')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('settings-about')).hitTestable(),
            findsOneWidget,
          );
        }
        await capture(section);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  test('Android capture descriptions follow actual native protection', () {
    expect(
      androidCaptureProtectionDescription(
        WindowCaptureProtectionStatus.exclude,
      ),
      contains('recent-app previews'),
    );
    expect(
      androidCaptureProtectionDescription(WindowCaptureProtectionStatus.none),
      contains('can appear'),
    );
    expect(
      androidCaptureProtectionDescription(
        WindowCaptureProtectionStatus.unavailable,
      ),
      contains('unavailable'),
    );
  });
  testWidgets(
    'color shortcuts select immediately and More shows at most two friends',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final jami = _SettingsJami();
      final state = await _initializedState(tester, jami);
      addTearDown(state.dispose);
      state.appSettings = state.appSettings.withIdentityColor(
        IdentityColor.slate,
      );
      state.seedEmptyRuntimeSnapshotForTesting(
        selectedPeerId: 'friend-a',
        friends: const [
          FriendState(
            peerId: 'friend-a',
            confirmed: true,
            conversationId: 'conversation-a',
            displayName: 'Ada',
            identityColor: IdentityColor.sage,
          ),
          FriendState(
            peerId: 'friend-b',
            confirmed: true,
            conversationId: 'conversation-b',
            displayName: 'Bea',
            identityColor: IdentityColor.sage,
          ),
          FriendState(
            peerId: 'friend-c',
            confirmed: true,
            conversationId: 'conversation-c',
            displayName: 'Cy',
            identityColor: IdentityColor.sage,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: SettingsPane(
              state: state,
              onClose: () {},
              onOpenDiagnostics: () {},
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('identity-color-row')), findsOneWidget);
      expect(find.text('Your color'), findsNothing);
      final current = find.byKey(
        ValueKey('identity-color-shortcut-${state.identityColor.storageValue}'),
      );
      final divider = find.byKey(const ValueKey('identity-color-divider'));
      expect(
        tester.getRect(current).right,
        lessThan(tester.getRect(divider).left),
      );
      expect(
        find.byKey(const ValueKey('identity-color-palette')),
        findsNothing,
      );
      final shortcut = IdentityColor.recommended(
        state.friendsByIdentityColor.keys,
        current: IdentityColor.automaticFor(state.jamiId),
      ).firstWhere((color) => color != state.identityColor);
      final shortcutFinder = find.byKey(
        ValueKey('identity-color-shortcut-${shortcut.storageValue}'),
      );
      expect(
        tester.getRect(shortcutFinder).left,
        greaterThan(tester.getRect(divider).right),
      );
      expect(
        tester.getSemantics(shortcutFinder).flagsCollection.isButton,
        isTrue,
      );
      await tester.tap(shortcutFinder);
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(divider, findsOneWidget, reason: 'The old row fades out smoothly');
      await tester.pumpAndSettle();
      expect(state.identityColor, shortcut);
      expect(state.appSettings.identityColorManual, isTrue);
      expect(jami.presenceColors.last, shortcut.storageValue);
      expect(divider, findsNothing);
      await tester.tap(find.byKey(const ValueKey('identity-color-more')));
      await tester.pumpAndSettle();
      expect(find.text('Automatic'), findsNothing);
      expect(
        find.byKey(const ValueKey('identity-color-palette')),
        findsOneWidget,
      );
      final skySemantics = tester.getSemantics(
        find.byKey(const ValueKey('identity-color-sky')),
      );
      expect(skySemantics.flagsCollection.isButton, isTrue);
      expect(skySemantics.label, contains('Sky'));
      expect(
        skySemantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('identity-color-used-sage')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('identity-color-used-sage')),
          matching: find.byType(SyblAvatar),
        ),
        findsNWidgets(2),
      );
      expect(find.text('+1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('identity-color-sky')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      expect(state.identityColor, IdentityColor.sky);
      expect(state.appSettings.identityColorManual, isTrue);
      expect(jami.presenceColors.last, 'sky');
    },
  );

  testWidgets(
    'current swatch opens the picker in a narrow large-text profile',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await _initializedState(tester, _SettingsJami());
      addTearDown(state.dispose);
      state.appSettings = state.appSettings.withIdentityColor(
        IdentityColor.slate,
      );
      Widget profile(double width) => MaterialApp(
        theme: Warm.theme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: SizedBox(
              width: width,
              child: SettingsProfile(
                state: state,
                onEditName: () {},
                onEditPicture: () {},
                onRemovePicture: () {},
                onCopyId: () {},
                onShareId: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(profile(320));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('identity-color-divider')),
        findsOneWidget,
      );
      final rowSwitcher = find
          .descendant(
            of: find.byKey(const ValueKey('identity-color-row')),
            matching: find.byType(AnimatedSwitcher),
          )
          .first;
      expect(
        tester.widget<AnimatedSwitcher>(rowSwitcher).duration,
        const Duration(milliseconds: 220),
        reason:
            'The app motion preference takes precedence over the OS setting',
      );
      await tester.pumpWidget(profile(180));
      await tester.pump(const Duration(milliseconds: 110));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('identity-color-more')), findsNothing);
      await tester.tap(
        find.byKey(
          ValueKey(
            'identity-color-shortcut-${state.identityColor.storageValue}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('identity-color-palette')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.runAsync(() => state.setChatMotionEnabled(false));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedSwitcher>(rowSwitcher).duration,
        Duration.zero,
      );
    },
  );

  test('capture-protection copy distinguishes exclusion from fallbacks', () {
    expect(
      windowCaptureProtectionDescription(WindowCaptureProtectionStatus.exclude),
      contains('Hidden from supported'),
    );
    expect(
      windowCaptureProtectionDescription(WindowCaptureProtectionStatus.monitor),
      allOf(contains('monitor-only fallback'), contains('not available')),
    );
    expect(
      windowCaptureProtectionDescription(
        WindowCaptureProtectionStatus.unavailable,
      ),
      contains('not protected'),
    );
    expect(
      windowCaptureProtectionDescription(WindowCaptureProtectionStatus.none),
      contains('appears in screenshots'),
    );
  });

  testWidgets('unreadable saved settings surface read-only controls', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance())
      ..settingsError = 'Could not load app settings.';
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('settings-read-only-error')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('appearance-calm')),
      150,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('appearance-calm')))
          .onTap,
      isNull,
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  });

  testWidgets('settings has no topic tutorial', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () => closed = true,
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('show-topic-introduction')), findsNothing);
    expect(state.dmTopicIntroduction, DmTopicIntroduction.none);
    expect(closed, isFalse);
    expect(state.prefs.getBool('dmTopicIntroductionUnderstoodV1'), isNull);
  });

  testWidgets('Topic background choices preview and fine-tune reset', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );

    final advanced = find.byKey(const ValueKey('appearance-advanced'));
    await tester.scrollUntilVisible(
      advanced,
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    await tester.tap(find.text('Fine-tune topic background'));
    await tester.pumpAndSettle();

    expect(find.byType(TopicBackgroundPreview), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('choice-Topic bar background-fullWidth')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('choice-Topic bar background-fullWidth')),
    );
    await tester.pumpAndSettle();
    expect(
      state.topicStripSurfaceSettings.coverage,
      TopicStripSurfaceCoverage.fullWidth,
    );
    expect(
      ((jsonDecode(state.prefs.getString('appSettings')!) as Map)['appearance']
          as Map)['topicStripSurface'],
      isA<Map>(),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('reset-topic-surface')),
    );
    await tester.tap(find.byKey(const ValueKey('reset-topic-surface')));
    await tester.pumpAndSettle();
    expect(state.topicStripSurfaceSettings, const TopicStripSurfaceSettings());
    expect(
      find.byKey(const ValueKey('topic-strip-surface-settings')),
      findsOneWidget,
      reason: 'Reset does not collapse the controls',
    );
  });

  testWidgets('phone scroll reveals section progress and permits scrubbing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    double opacityOf(Finder finder) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(of: finder, matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;
    final rail = find.byKey(const ValueKey('settings-section-rail-strip'));
    expect(opacityOf(rail), 0);

    final list = find.descendant(
      of: find.byKey(const ValueKey('settings-list')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    final position = tester.state<ScrollableState>(list).position;
    position.jumpTo(2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      opacityOf(rail),
      inExclusiveRange(0, .5),
      reason: 'A small scroll only reveals a faint rail',
    );
    final faintRailGrab = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('settings-jump-profile'))),
    );
    await tester.pump();
    expect(
      opacityOf(rail),
      1,
      reason: 'Grabbing a faint rail reveals it fully',
    );
    await faintRailGrab.up();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(opacityOf(rail), 0);
    for (var step = 0; step < 30; step++) {
      position.jumpTo(position.pixels + 8);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      opacityOf(rail),
      1,
      reason: 'Sustained slow scrolling also makes navigation prominent',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(opacityOf(rail), 0);

    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(opacityOf(rail), 1);
    expect(
      find.byKey(const ValueKey('settings-scroll-section-label')),
      findsOneWidget,
    );

    // Long sections report their measured fraction, rather than a fixed
    // transition distance near the next heading.
    final viewportTop = tester
        .getTopLeft(find.byKey(const ValueKey('settings-list')))
        .dy;
    final appearance = tester.getTopLeft(find.text('APPEARANCE')).dy;
    final notifications = tester.getTopLeft(find.text('NOTIFICATIONS')).dy;
    position.jumpTo(
      position.pixels +
          appearance -
          viewportTop -
          24 +
          (notifications - appearance) * .5,
    );
    await tester.pump();
    final progress = tester.widget<Semantics>(
      find.byKey(const ValueKey('settings-section-progress')),
    );
    expect(progress.properties.value, '50');
    final thumb = find.byKey(const ValueKey('settings-scroll-thumb'));
    final movingTop = tester.getTopLeft(thumb).dy;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(thumb).dy, greaterThan(movingTop));
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final railFocus = Focus.of(
      tester.element(
        find.descendant(
          of: find.byKey(const ValueKey('settings-jump-appearance')),
          matching: find.byType(Icon),
        ),
      ),
    );
    railFocus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(opacityOf(rail), 1, reason: 'Keep focused navigation visible');
    railFocus.unfocus();
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('settings-jump-appearance'))),
    );
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('settings-jump-advanced'))),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(opacityOf(rail), 1, reason: 'Do not hide during a held scrub');
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(opacityOf(rail), 0);

    await tester.tap(
      find.byKey(const ValueKey('settings-section-menu-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-jump-appearance')));
    await tester.pumpAndSettle();
    expect(opacityOf(rail), 0);
    position.jumpTo(position.pixels + 2);
    await tester.pump();
    expect(
      opacityOf(rail),
      inExclusiveRange(0, .5),
      reason: 'A section jump does not brighten the next small scroll',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('writable settings failures remain visibly announced', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    state.settingsError = 'Could not save app settings.';
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('settings-save-error')), findsOneWidget);
    expect(find.text('Could not save app settings.'), findsOneWidget);
    final node = tester.getSemantics(
      find.byKey(const ValueKey('settings-save-error')),
    );
    expect(node.flagsCollection.isLiveRegion, isTrue);
    semantics.dispose();
  });

  testWidgets('window animation previews are temporary and serialized', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    state.appSettings = AppSettings(
      windowOpenAnimation: WindowCloseAnimation.fade,
      windowMinimizeAnimation: WindowCloseAnimation.door,
      windowCloseAnimation: WindowCloseAnimation.warp,
      windowOpenDurationMs: 640,
      windowMinimizeDurationMs: 180,
      windowCloseDurationMs: 420,
    );
    const channel = MethodChannel('syb.l/window-dismiss');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Completer<bool>? pendingPreview;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'preview') return null;
      calls.add(call);
      return pendingPreview!.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );

    final openDialog = find.byKey(const ValueKey('window-animations-settings'));
    await tester.ensureVisible(openDialog);
    await tester.tap(openDialog);
    await tester.pumpAndSettle();
    final stableSettings = state.appSettings;

    Future<void> preview(
      String action,
      String animation,
      int durationMs,
    ) async {
      final previewButton = find.byKey(ValueKey('window-$action-preview'));
      expect(tester.widget<IconButton>(previewButton).onPressed, isNotNull);
      pendingPreview = Completer<bool>();
      await tester.tap(previewButton);
      await tester.pump();
      expect(calls.last.method, 'preview');
      expect(calls.last.arguments, {
        'action': action,
        'animation': animation,
        'durationMs': durationMs,
      });
      for (final id in ['open', 'minimize', 'close']) {
        expect(
          tester
              .widget<IconButton>(find.byKey(ValueKey('window-$id-preview')))
              .onPressed,
          isNull,
          reason: 'All previews stay disabled until the active preview ends',
        );
      }
      expect(state.appSettings, stableSettings);
      pendingPreview!.complete(true);
      await tester.pumpAndSettle();
      expect(state.appSettings, stableSettings);
    }

    for (final title in ['Open', 'Minimize', 'Close']) {
      expect(find.byTooltip('Preview $title animation'), findsOneWidget);
    }
    await preview('open', 'fade', 640);
    await preview('minimize', 'door', 180);
    await preview('close', 'warp', 420);

    pendingPreview = Completer<bool>();
    await tester.tap(find.byKey(const ValueKey('window-open-preview')));
    await tester.pump();
    pendingPreview!.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);

    pendingPreview = Completer<bool>();
    await tester.tap(find.byKey(const ValueKey('window-open-preview')));
    await tester.pump();
    expect(find.text('Preview unavailable'), findsNothing);
    pendingPreview!.complete(true);
    await tester.pumpAndSettle();

    final minimizeAnimation = find.byKey(
      const ValueKey('window-minimize-animation'),
    );
    await tester.tap(minimizeAnimation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();
    final minimizePreview = find.byKey(
      const ValueKey('window-minimize-preview'),
    );
    expect(tester.widget<IconButton>(minimizePreview).onPressed, isNull);

    await state.setChatMotionEnabled(false);
    await tester.pumpAndSettle();
    for (final id in ['open', 'minimize', 'close']) {
      expect(
        tester
            .widget<IconButton>(find.byKey(ValueKey('window-$id-preview')))
            .onPressed,
        isNull,
      );
    }

    await state.setChatMotionEnabled(true);
    await tester.pumpAndSettle();
    pendingPreview = Completer<bool>();
    await tester.tap(find.byKey(const ValueKey('window-close-preview')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('window-animations-done')));
    await tester.pumpAndSettle();
    pendingPreview!.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('window animation dialog fits narrow large-text windows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(280, 490);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    final openDialog = find.byKey(const ValueKey('window-animations-settings'));
    await tester.ensureVisible(openDialog);
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(openDialog).onPressed, isNotNull);
    await tester.tap(openDialog);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);

    for (final id in ['open', 'minimize', 'close']) {
      final group = find.byKey(ValueKey('window-animation-$id'));
      final preview = find.byKey(ValueKey('window-$id-preview'));
      final slider = find.byKey(ValueKey('window-$id-duration'));
      await tester.ensureVisible(preview);
      await tester.pumpAndSettle();
      expect(preview.hitTestable(), findsOneWidget);
      expect(tester.widget<IconButton>(preview).onPressed, isNotNull);
      final groupRect = tester.getRect(group);
      expect(tester.getRect(preview).right, lessThanOrEqualTo(groupRect.right));

      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final durationValue = find.descendant(
        of: find.byKey(ValueKey('window-animation-$id')),
        matching: find.text('240 ms'),
      );
      expect(durationValue, findsOneWidget);
      expect(
        tester.getRect(durationValue).right,
        lessThanOrEqualTo(tester.getRect(group).right),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('window animation editor semantics survive repeated routes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await _initializedState(tester, _SettingsJami());
    addTearDown(state.dispose);
    final semantics = tester.ensureSemantics();
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    final edit = find.byKey(const ValueKey('window-animations-settings'));
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();

    List<SemanticsNode> traverseTree() {
      final sliderNodes = <SemanticsNode>[];
      final visited = <int>{};
      void walkSemantics(SemanticsNode node) {
        expect(
          visited.add(node.id),
          isTrue,
          reason: 'Semantic node IDs are unique',
        );
        if (node.getSemanticsData().flagsCollection.isSlider) {
          sliderNodes.add(node);
        }
        node.childrenCountInTraversalOrder;
        node.visitChildren((child) {
          walkSemantics(child);
          return true;
        });
      }

      final renderView = tester.binding.renderViews.single;
      final root = renderView.owner!.semanticsOwner!.rootSemanticsNode!;
      walkSemantics(root);
      return sliderNodes;
    }

    for (var cycle = 0; cycle < 4; cycle++) {
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final sliderNodes = traverseTree();
      expect(sliderNodes, hasLength(3));
      for (final slider in sliderNodes) {
        final data = slider.getSemanticsData();
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
      }

      for (final action in ['open', 'minimize', 'close']) {
        final title = switch (action) {
          'open' => 'Open',
          'minimize' => 'Minimize',
          _ => 'Close',
        };
        final preview = tester.getSemantics(
          find.byKey(ValueKey('window-$action-preview')),
        );
        expect(preview.getSemanticsData().tooltip, 'Preview $title animation');
        expect(preview.flagsCollection.isButton, isTrue);
        expect(preview.flagsCollection.isEnabled, Tristate.isTrue);
        expect(
          preview.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );

        final slider = tester.getSemantics(
          find.byKey(ValueKey('window-$action-duration')),
        );
        expect(slider.label, '$title animation duration');
        expect(slider.value, '240 milliseconds');
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('window-animations-done')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      traverseTree();
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  testWidgets(
    'section rail scrolls smoothly and visual choices select immediately',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await _initializedState(tester, _SettingsJami());
      addTearDown(state.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: defaultTargetPlatform),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) => SettingsPane(
                state: state,
                onClose: () {},
                onOpenDiagnostics: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byType(Divider), findsOneWidget);
      double labelOpacity() => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.byKey(
                    const ValueKey('settings-scroll-section-label'),
                  ),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;
      expect(labelOpacity(), 0);
      final safety = find.text('PRIVACY & SECURITY', skipOffstage: false);
      final safetyBefore = tester.getTopLeft(safety).dy;
      expect(safetyBefore, greaterThan(600));

      Future<void> openMobileSections() async {
        if (defaultTargetPlatform == TargetPlatform.android) {
          await tester.tap(
            find.byKey(const ValueKey('settings-section-menu-button')),
          );
          await tester.pumpAndSettle();
        }
      }

      await openMobileSections();
      await tester.tap(
        find.byKey(const ValueKey('settings-jump-safety')),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        labelOpacity(),
        defaultTargetPlatform == TargetPlatform.windows ? 0 : 1,
      );
      final safetyDuring = tester.getTopLeft(safety).dy;
      expect(safetyDuring, lessThan(safetyBefore));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(labelOpacity(), 0);
      expect(
        tester.getTopLeft(safety).dy,
        inInclusiveRange(
          defaultTargetPlatform == TargetPlatform.windows ? 0 : 48,
          500,
        ),
      );

      await openMobileSections();
      await tester.tap(
        find.byKey(const ValueKey('settings-jump-appearance')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      final appearanceMarker = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('settings-jump-active-Appearance')),
      );
      final appearanceDecoration =
          appearanceMarker.decoration! as BoxDecoration;
      expect(appearanceDecoration.borderRadius, BorderRadius.circular(24));
      expect(appearanceDecoration.color, isNot(Colors.transparent));
      final windowAnimations = find.byKey(
        const ValueKey('window-animations-settings'),
      );
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await tester.ensureVisible(windowAnimations);
        expect(
          tester.widget<TextButton>(windowAnimations).onPressed,
          isNotNull,
        );
        await tester.tap(windowAnimations);
        await tester.pumpAndSettle();
        final screenshotPath =
            Platform.environment['SYBL_WINDOW_ANIMATIONS_SCREENSHOT'];
        if (screenshotPath != null) {
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          Future<void> captureDialog(
            String path, {
            double textScale = 1,
            bool revealClose = false,
          }) async {
            tester.view.physicalSize = const Size(700, 500);
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            await tester.pumpAndSettle();
            if (revealClose) {
              await tester.ensureVisible(
                find.byKey(const ValueKey('window-close-animation')),
              );
              await tester.pumpAndSettle();
            }
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('window-animations-dialog-boundary')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(path).writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }

          await captureDialog(screenshotPath);
          final largeScreenshotPath =
              Platform.environment['SYBL_WINDOW_ANIMATIONS_LARGE_SCREENSHOT'];
          if (largeScreenshotPath != null) {
            await captureDialog(
              largeScreenshotPath,
              textScale: 1.6,
              revealClose: true,
            );
          }
          tester.view.physicalSize = const Size(800, 600);
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await tester.pumpAndSettle();
        }
        Finder styleDropdown(String id) => find.descendant(
          of: find.byKey(ValueKey('window-$id-animation')),
          matching: find.byType(DropdownButton<WindowCloseAnimation>),
        );
        final closeAnimation = styleDropdown('close');
        final openAnimation = styleDropdown('open');
        final minimizeAnimation = styleDropdown('minimize');
        expect(
          tester
              .widget<DropdownButton<WindowCloseAnimation>>(closeAnimation)
              .value,
          WindowCloseAnimation.tray,
        );
        expect(
          tester
              .widget<DropdownButton<WindowCloseAnimation>>(openAnimation)
              .value,
          WindowCloseAnimation.tray,
        );
        expect(
          tester
              .widget<DropdownButton<WindowCloseAnimation>>(minimizeAnimation)
              .value,
          WindowCloseAnimation.tray,
        );
        expect(
          tester
              .widget<Slider>(
                find.byKey(const ValueKey('window-open-duration')),
              )
              .value,
          240,
        );

        await tester.tap(openAnimation);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fade').last);
        await tester.pumpAndSettle();
        expect(
          state.appSettings.windowOpenAnimation,
          WindowCloseAnimation.fade,
        );

        await tester.tap(minimizeAnimation);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fold').last);
        await tester.pumpAndSettle();
        expect(
          state.appSettings.windowMinimizeAnimation,
          WindowCloseAnimation.door,
        );

        final direction = find.byKey(
          const ValueKey('window-minimize-fold-direction'),
        );
        for (final entry in {
          'Right': WindowCloseAnimation.foldRight,
          'Up': WindowCloseAnimation.foldUp,
          'Down': WindowCloseAnimation.foldDown,
          'Left': WindowCloseAnimation.door,
        }.entries) {
          await tester.ensureVisible(direction);
          await tester.tap(direction);
          await tester.pumpAndSettle();
          await tester.tap(find.text(entry.key).last);
          await tester.pumpAndSettle();
          expect(state.appSettings.windowMinimizeAnimation, entry.value);
        }

        final openDuration = find.byKey(const ValueKey('window-open-duration'));
        await tester.ensureVisible(openDuration);
        final openSlider = tester.getRect(openDuration);
        await tester.tapAt(Offset(openSlider.right - 2, openSlider.center.dy));
        await tester.pumpAndSettle();
        expect(state.appSettings.windowOpenDurationMs, 800);

        final minimizeDuration = find.byKey(
          const ValueKey('window-minimize-duration'),
        );
        await tester.ensureVisible(minimizeDuration);
        final minimizeSlider = tester.getRect(minimizeDuration);
        await tester.tapAt(
          Offset(minimizeSlider.left + 2, minimizeSlider.center.dy),
        );
        await tester.pumpAndSettle();
        expect(state.appSettings.windowMinimizeDurationMs, 100);
        await tester.tap(minimizeAnimation);
        await tester.pumpAndSettle();
        await tester.tap(find.text('None').last);
        await tester.pumpAndSettle();
        expect(
          state.appSettings.windowMinimizeAnimation,
          WindowCloseAnimation.none,
        );
        expect(tester.widget<Slider>(minimizeDuration).onChanged, isNull);

        await tester.tap(closeAnimation);
        await tester.pumpAndSettle();
        for (final label in ['Move', 'Fold', 'Warp', 'Fade', 'None']) {
          expect(find.text(label), findsWidgets);
        }
        await tester.tap(find.text('Warp').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('window-animations-done')));
        await tester.pumpAndSettle();
        expect(
          state.appSettings.windowCloseAnimation,
          WindowCloseAnimation.warp,
        );
        expect(
          state.appSettings.windowMinimizeAnimation,
          WindowCloseAnimation.none,
        );
      } else {
        expect(windowAnimations, findsNothing);
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('chat-motion-switch')),
      );
      await tester.tap(find.byKey(const ValueKey('chat-motion-switch')));
      expect(state.chatMotionEnabled, isFalse);
      await tester.pump();
      if (defaultTargetPlatform == TargetPlatform.windows) {
        expect(tester.widget<TextButton>(windowAnimations).onPressed, isNull);
        expect(
          state.appSettings.windowCloseAnimation,
          WindowCloseAnimation.warp,
        );
      }
      await tester.tap(find.byKey(const ValueKey('chat-activity-switch')));
      expect(state.chatActivityIndicatorsEnabled, isFalse);
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final fullWidth = find.byKey(
          const ValueKey('choice-Group header-fullWidth'),
        );
        await tester.ensureVisible(fullWidth);
        await tester.tap(fullWidth);

        expect(state.groupHeaderPlacement, GroupHeaderPlacement.fullWidth);
        await tester.pump();
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('choice-Group header-fullWidth')),
              )
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
      }

      await openMobileSections();
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final gesture = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey('settings-jump-appearance')),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 280));
        final next = tester.getCenter(
          find.byKey(const ValueKey('settings-jump-notifications')),
        );
        await gesture.moveTo(Offset(next.dx, next.dy + 3));
        await tester.pump();
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('settings-section-progress')),
              )
              .label,
          'Notifications, remaining',
        );
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-jump-safety')));
      } else {
        final gesture = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey('settings-jump-appearance')),
          ),
        );
        await gesture.moveTo(
          tester.getCenter(
            find.byKey(const ValueKey('settings-jump-connection')),
          ),
        );
        await tester.pump();
        final connectionMarker = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('settings-jump-active-Network')),
        );
        expect(
          (connectionMarker.decoration! as BoxDecoration).color,
          isNot(Colors.transparent),
          reason: 'dragging across the rail changes section immediately',
        );
        await gesture.moveTo(
          tester.getCenter(find.byKey(const ValueKey('settings-jump-safety'))),
        );
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(safety).dy,
        inInclusiveRange(
          defaultTargetPlatform == TargetPlatform.windows ? 0 : 48,
          500,
        ),
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('account row opens the Doorlight invitation share surface', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance())
      ..jamiId = _jamiId;
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('show-jami-qr')));
    await tester.pumpAndSettle();

    final qr = tester.widget<FriendInviteQr>(find.byType(FriendInviteQr));
    expect(qr.invite.jamiId, _jamiId);
    expect(find.text('Invite a friend'), findsOneWidget);
  });

  testWidgets('Android enhanced privacy requires confirmation before opt-out', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final jami = _SettingsJami();
    final state = await _initializedState(tester, jami);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('show-message-notification-switch')),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('show-message-notification-switch')),
    );
    await tester.pump();
    expect(state.showMessageInNotification, isFalse);
    expect(jami.messagePreviews.last, isFalse);
    await tester.scrollUntilVisible(
      find.text('Screen capture protection'),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('android-capture-protection-switch')),
    );
    await tester.pumpAndSettle();

    expect(state.androidCaptureProtectionEnabled, isTrue);
    await tester.tap(
      find.byKey(const ValueKey('android-capture-protection-switch')),
    );
    await tester.pumpAndSettle();
    expect(jami.appliedAndroidProtection, isEmpty);
    expect(
      find.byKey(const ValueKey('android-capture-disable-confirm')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('android-capture-disable-confirm')),
    );
    await tester.pumpAndSettle();

    expect(jami.appliedAndroidProtection, [false]);
    expect(state.androidCaptureProtectionEnabled, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android connection settings expose the optional FCM wake', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final jami = _SettingsJami();
    final state = await _initializedState(tester, jami);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    final switchFinder = find.byKey(
      const ValueKey('reliable-background-notifications-switch'),
    );
    await tester.scrollUntilVisible(
      switchFinder,
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );

    expect(find.text('Google background alerts'), findsOneWidget);
    expect(
      find.text('Let Google wake Doorlight for messages and calls.'),
      findsOneWidget,
    );
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('Get alerts while Doorlight sleeps?'), findsOneWidget);
    expect(state.reliableBackgroundNotifications, isFalse);
    await tester.tap(find.text('Use Google'));
    await tester.pumpAndSettle();
    expect(state.reliableBackgroundNotifications, isTrue);
    expect(jami.backgroundWakeCalls.last, isTrue);

    await tester.runAsync(() => state.setConnectionProfile('lan'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Switch>(switchFinder).onChanged,
      isNotNull,
      reason: 'Withdrawal must remain available outside Online mode.',
    );
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(state.reliableBackgroundNotifications, isFalse);
    expect(jami.backgroundWakeCalls.last, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
