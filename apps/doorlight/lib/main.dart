import 'ui/theme_reveal.dart';
import 'ui/ambient_vibe.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/jami.dart';
import 'core/sound_effects.dart';
import 'doorlight_binding.dart';
import 'state/app_lock.dart';
import 'state/app_state.dart';
import 'state/appearance_bridge.dart';
import 'state/overlay_bridge.dart';
import 'state/nearby_transports.dart';
import 'state/pending_invite.dart';
import 'theme.dart';
import 'screens/onboarding.dart';
import 'screens/home.dart';
import 'ui/app_lock_gate.dart';
import 'ui/add_friend_dialog.dart';
import 'ui/capture_consent_gate.dart';
import 'ui/onboarding_surface.dart';
import 'ui/playful_door.dart';
import 'ui/notice.dart';
import 'ui/notification_bell.dart';
import 'ui/update_button.dart';
import 'state/windows_update.dart';
import 'ui/sonar_warp.dart';
import 'ui/sybl_ui.dart';
import 'ui/windows_chrome.dart';
import 'ui/settings_startup.dart';
import 'ui/widget_chat_consent.dart';

Future<void> main({Future<void> Function()? beforeAppStart}) async {
  DoorlightBinding();
  // The native UAT host installs its isolated storage before preferences load.
  if (beforeAppStart != null) await beforeAppStart();
  LicenseRegistry.addLicense(() async* {
    for (final font in {
      'Fraunces': 'OFL-Fraunces.txt',
      'Hanken Grotesk': 'OFL-HankenGrotesk.txt',
      'Anton': 'OFL-Anton.txt',
      'Bricolage Grotesque': 'OFL-BricolageGrotesque.txt',
      'Caveat': 'OFL-Caveat.txt',
      'Courier Prime': 'OFL-CourierPrime.txt',
      'Fredoka': 'OFL-Fredoka.txt',
      'Gochi Hand': 'OFL-GochiHand.txt',
      'Instrument Serif': 'OFL-InstrumentSerif.txt',
      'Lilita One': 'OFL-LilitaOne.txt',
      'Pacifico': 'OFL-Pacifico.txt',
      'Playfair Display': 'OFL-PlayfairDisplay.txt',
      'Quicksand': 'OFL-Quicksand.txt',
      'Righteous': 'OFL-Righteous.txt',
      'Rubik': 'OFL-Rubik.txt',
      'Silkscreen': 'OFL-Silkscreen.txt',
      'Space Mono': 'OFL-SpaceMono.txt',
      'VT323': 'OFL-VT323.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        font.key,
      ], await rootBundle.loadString('assets/fonts/${font.value}'));
    }
    yield LicenseEntryWithLineBreaks(const [
      'Doorlight artwork — provenance',
    ], await rootBundle.loadString('assets/brand/NOTICE.txt'));
    for (final notice in ['NOTICE.txt', 'Kenney-License.txt', 'CC0-1.0.txt']) {
      yield LicenseEntryWithLineBreaks(const [
        'Doorlight GIFs — Kenney Emotes and original animation',
      ], await rootBundle.loadString('assets/gifs/doorlight/$notice'));
    }
    yield LicenseEntryWithLineBreaks(const [
      'Doorlight Nearby sonar sounds — Pixabay',
    ], await rootBundle.loadString('assets/sounds/NOTICE-sonar.txt'));
  });
  // Start from the phone-safe portrait policy. The live call surface owns the
  // temporary landscape allowance while either side is sharing a screen, then
  // restores portrait when that surface leaves the tree.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(
    SettingsStartup(
      load: SharedPreferences.getInstance,
      readyBuilder: (prefs) {
        final jami = JamiClient();
        final state = AppState(jami, prefs);
        state.attachNearby(
          nearbyTransport(
            jami,
            onPermissionRequired: () => state.nearby?.endVisible(),
            googleAllowed: () => state.googleNearbyAllowed,
          ),
        );
        return SyblApp(state: state);
      },
    ),
  );
}

class SyblApp extends StatefulWidget {
  final AppState state;
  const SyblApp({super.key, required this.state});
  @override
  State<SyblApp> createState() => _SyblAppState();
}

class _SyblAppState extends State<SyblApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _navigator = GlobalKey<NavigatorState>();
  AppLockController? _appLock;
  late AppearancePreset _appearancePreset;
  bool _inviteDialogScheduled = false;
  PendingInvite? _presentedInvite;
  int _presentedInviteRevision = -1;
  bool _captureGateWasVisible = false;
  int _captureSurfaceGeneration = 0;
  final _soundPlayer = SyblSoundPlayer();
  StreamSubscription<SyblSoundEvent>? _soundSubscription;
  StreamSubscription<String>? _nearbySonarSubscription;
  final _sonar = GlobalKey<SonarWarpState>();
  AppearanceBridge? _appearanceBridge;
  OverlayBridge? _overlayBridge;
  WindowsUpdate? _update;

  bool _updateKey(KeyEvent event) {
    _update?.activity();
    return false;
  }

  @override
  void initState() {
    super.initState();
    _appearancePreset = widget.state.appearancePreset;
    unawaited(_syncWindowAppearance());
    widget.state.init();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _update = WindowsUpdate(
        canRestart: () => widget.state.canRestartForUpdate,
        reserveRestart: widget.state.reserveUpdateRestart,
        restartStillSafe: () => widget.state.updateRestartStillSafe,
        releaseRestart: widget.state.cancelUpdateRestart,
        prepareNative: () => widget.state.jami.prepareUpdateShutdown(
          widget.state.accountId ?? '',
        ),
        cancelNative: widget.state.jami.cancelUpdateShutdown,
        commitNative: widget.state.jami.commitUpdateShutdown,
        identity: () => widget.state.jamiId,
        motion: () => widget.state.chatMotionEnabled,
      )..start();
      HardwareKeyboard.instance.addHandler(_updateKey);
      _appearanceBridge = AppearanceBridge(
        widget.state,
        canEdit: () => _appLock?.locked == false,
      )..start();
      _overlayBridge = OverlayBridge(
        widget.state,
        onUserActivity: () => _update?.activity(),
        canEdit: () => _appLock?.locked == false,
      )..start();
    }
    widget.state.addListener(_onState);
    _soundSubscription = widget.state.soundEvents.listen(_soundPlayer.handle);
    _nearbySonarSubscription = widget.state.nearby?.sonarReceived.listen((_) {
      // Sonar on screen shows the ping on its own stage.
      if (widget.state.nearby?.watching != true) {
        _sonar.currentState?.received();
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_updateKey);
    _update?.dispose();
    _appearanceBridge?.dispose();
    _overlayBridge?.dispose();
    unawaited(_soundSubscription?.cancel());
    unawaited(_nearbySonarSubscription?.cancel());
    unawaited(_soundPlayer.dispose());
    widget.state.removeListener(_onState);
    _appLock?.removeListener(_onAppLockChanged);
    _appLock?.dispose();
    super.dispose();
  }

  Future<void> _syncWindowAppearance() async {
    try {
      await widget.state.jami.setWindowAppearance(
        disaccord: _appearancePreset == AppearancePreset.disaccord,
      );
    } on MissingPluginException {
      // Test hosts and older native runners may not expose cosmetic chrome.
    } on PlatformException {
      // A missing window must not prevent the app from loading its settings.
    }
  }

  /// Surface a failed-call note (set in AppState) as a brief snackbar, then clear it.
  void _onState() {
    final startup = widget.state;
    unawaited(
      _update?.reportStartup(
        ready:
            startup.screen != Screen.loading &&
            startup.bootError == null &&
            !startup.pendingIdentityRecovery &&
            !startup.resetDoorlightPending &&
            !startup.resetDoorlightRestartRequired,
        identity: startup.jamiId,
      ),
    );
    var rebuild = false;
    final captureGateVisible = widget.state.captureGateVisible;
    if (captureGateVisible != _captureGateWasVisible) {
      _captureGateWasVisible = captureGateVisible;
      _captureSurfaceGeneration++;
      if (!captureGateVisible) _presentedInvite = null;
      if (captureGateVisible) {
        clearNotices();
      }
    }
    AppLockController? controllerToStart;
    final appearance = widget.state.appearancePreset;
    if (_appearancePreset != appearance) {
      _appearancePreset = appearance;
      unawaited(_syncWindowAppearance());
      rebuild = true;
    }
    // The capture-protection failure gate is the outermost surface, so nothing
    // may authenticate or paint over it while native state is unresolved.
    if (_appLock == null &&
        !widget.state.captureGateVisible &&
        (widget.state.screen != Screen.loading ||
            widget.state.bootError != null)) {
      controllerToStart = AppLockController(
        authenticator: LocalAuthDeviceAuthenticator(),
        initialEnabled: widget.state.appLockEnabled,
        persistEnabled: widget.state.setAppLockEnabled,
      );
      _appLock = controllerToStart;
      controllerToStart.addListener(_onAppLockChanged);
      widget.state.setProtectedSurfaceLocked(controllerToStart.locked);
      _appearanceBridge?.refresh();
      _overlayBridge?.refresh();
      rebuild = true;
    }
    if (rebuild && mounted) setState(() {});
    if (controllerToStart != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controllerToStart?.start();
      });
    }
    _scheduleInviteDialog();
    final note = widget.state.callEndedNote;
    if (note == null) return;
    widget.state.callEndedNote = null;
    // ScaffoldMessenger sits above `home`, so a snackbar would float over the
    // gate. Drop it rather than narrate call state on the neutral surface.
    if (widget.state.captureGateVisible) return;
    final surfaceGeneration = _captureSurfaceGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.state.captureGateVisible ||
          surfaceGeneration != _captureSurfaceGeneration) {
        return;
      }
      clearNotices();
      showNotice(note, duration: const Duration(seconds: 3));
    });
  }

  void _scheduleInviteDialog() {
    final state = widget.state;
    final appLock = _appLock;
    final continuation = state.inviteContinuation;
    if (_inviteDialogScheduled ||
        (continuation.replacement == null &&
            identical(continuation.pending, _presentedInvite) &&
            continuation.presentationRevision == _presentedInviteRevision) ||
        (state.inviteContinuation.pending == null &&
            state.inviteContinuation.replacement == null) ||
        !state.canPresentInvite ||
        appLock == null ||
        appLock.locked) {
      return;
    }
    _inviteDialogScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = _navigator.currentContext;
      final controller = _appLock;
      if (!mounted ||
          context == null ||
          !state.canPresentInvite ||
          controller == null ||
          controller.locked) {
        _inviteDialogScheduled = false;
        return;
      }
      try {
        final continuation = state.inviteContinuation;
        final replacement = continuation.replacement;
        if (replacement != null) {
          final previous = continuation.pending;
          final owner = state.linkedDeviceOwner;
          final name = replacement.invite.displayName;
          final route = DialogRoute<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Open a different invitation?'),
              content: Text(
                name.isEmpty
                    ? 'A different invitation was opened. Replace the current invitation?'
                    : 'An invitation from $name was opened. Replace the current invitation?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep current'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Replace invitation'),
                ),
              ],
            ),
          );
          unawaited(Navigator.of(context, rootNavigator: true).push(route));
          final replace = await route.completed;
          if (!mounted ||
              !state.canPresentInvite ||
              owner != state.linkedDeviceOwner) {
            return;
          }
          if (replace == true) {
            continuation.acceptReplacement(replacement, previous);
          } else {
            continuation.rejectReplacement(replacement);
          }
        } else {
          final record = continuation.pending;
          if (record == null) return;
          _presentedInvite = record;
          _presentedInviteRevision = continuation.presentationRevision;
          await showAddFriendDialog(
            context,
            state: state,
            initialInvite: record.invite,
            continuation: record,
          );
        }
      } finally {
        _inviteDialogScheduled = false;
        if (mounted) _scheduleInviteDialog();
      }
    });
  }

  void _onAppLockChanged() {
    final controller = _appLock;
    if (controller != null) {
      widget.state.setProtectedSurfaceLocked(controller.locked);
      _appearanceBridge?.refresh();
      _overlayBridge?.refresh();
      if (!controller.locked) _presentedInvite = null;
      _scheduleInviteDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return MaterialApp(
      title: 'Doorlight',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messenger,
      navigatorKey: _navigator,
      theme: Warm.theme(_appearancePreset),
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          if (WidgetsBinding.instance
              case final DoorlightMotionPolicy binding) {
            binding.animationsEnabled = state.chatMotionEnabled;
          }
          // OUTERMOST: while Windows capture protection or a detected-capture
          // decision is unresolved, the whole window is a data-free navigator.
          // No splash, onboarding, call, settings, app-lock child, or existing
          // route may render behind an unconfirmed native state.
          Widget withNotices(Widget page) => withNoticeHost(
            AmbientVibeSurface(
              vibe: state.appSettings.ambientVibe,
              opacity: state.appSettings.vibeOpacity / 100,
              intensity: state.appSettings.vibeIntensity / 100,
              animationsEnabled: state.chatMotionEnabled,
              child: page,
            ),
            state,
          );
          final protectedSurface = state.captureGateVisible
              ? Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => WindowsChromeContent(
                      child: CaptureConsentGate(state: state),
                    ),
                  ),
                )
              : switch (_appLock) {
                  null => withNotices(
                    SonarWarp(
                      key: _sonar,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                  final appLock => AppLockGate(
                    controller: appLock,
                    child: withNotices(
                      SonarWarp(
                        key: _sonar,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                };
          return Listener(
            onPointerDown: (_) => _update?.activity(),
            onPointerSignal: (_) => _update?.activity(),
            onPointerMove: (_) => _update?.activity(),
            child: ThemeReveal(
              key: ValueKey(state.accountId),
              enabled:
                  state.chatMotionEnabled &&
                  state.screen == Screen.home &&
                  !state.captureGateVisible &&
                  _appLock?.locked != true,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: !state.chatMotionEnabled),
                child: Theme.of(context).platform == TargetPlatform.windows
                    ? WindowsChrome(
                        jami: state.jami,
                        dismissAnimationsEnabled:
                            state.chatMotionEnabled &&
                            !state.captureGateVisible &&
                            _appLock?.locked != true,
                        openAnimation: state.appSettings.windowOpenAnimation,
                        minimizeAnimation:
                            state.appSettings.windowMinimizeAnimation,
                        closeAnimation: state.appSettings.windowCloseAnimation,
                        openDurationMs: state.appSettings.windowOpenDurationMs,
                        minimizeDurationMs:
                            state.appSettings.windowMinimizeDurationMs,
                        closeDurationMs:
                            state.appSettings.windowCloseDurationMs,
                        rememberDefaultWindowPosition:
                            state.appSettings.rememberDefaultWindowPosition,
                        windowEdgeSpacing: state.appSettings.windowEdgeSpacing,
                        renderControls: false,
                        onboarding:
                            state.screen != Screen.home &&
                            !state.captureGateVisible &&
                            _appLock?.locked != true,
                        compactContentAvailable:
                            state.screen == Screen.home &&
                            !state.captureGateVisible &&
                            _appLock?.locked != true,
                        child: AbsorbPointer(
                          absorbing: state.updateRestartPending,
                          child: ExcludeFocus(
                            excluding: state.updateRestartPending,
                            child: protectedSurface,
                          ),
                        ),
                      )
                    : protectedSurface,
              ),
            ),
          );
        },
      ),
      home: ListenableBuilder(
        listenable: state,
        // Keep screen geometry fixed throughout the onboarding/home handoff.
        builder: (context, _) => WindowsChromeContent(
          onboarding: state.screen != Screen.home,
          compactContentAvailable: state.screen == Screen.home,
          leading: state.screen == Screen.home
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_update case final update?)
                      UpdateButton(
                        update: update,
                        canRestart: state.canRestartForUpdate,
                      ),
                    NotificationBell(state: state),
                  ],
                )
              : null,
          child: AnimatedSwitcher(
            duration: SyblMotion.duration(
              context,
              const Duration(milliseconds: 420),
            ),
            switchInCurve: Curves.linear,
            switchOutCurve: Curves.linear,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation.drive(
                CurveTween(
                  curve: const Interval(.45, 1, curve: Curves.easeInOutCubic),
                ),
              ),
              child: child,
            ),
            child: KeyedSubtree(
              key: ValueKey(state.screen),
              child: switch (state.screen) {
                Screen.loading => _Splash(
                  error: state.bootError,
                  details:
                      state.resetDoorlightPending ||
                          state.resetDoorlightRestartRequired
                      ? null
                      : state.bootErrorDetails,
                  guidance:
                      state.resetDoorlightPending ||
                          state.resetDoorlightRestartRequired
                      ? null
                      : state.profileProtectionUnavailable
                      ? 'Your profile files have been kept. Doorlight could not verify their protection.'
                      : state.pendingIdentityRecovery
                      ? state.relaunchRequired
                            ? 'Restart Doorlight to continue checking the unfinished restore.'
                            : state.identityRecoveryGuidance
                      : state.relaunchRequired
                      ? 'Doorlight needs a fresh start. Close the app completely, then open it again.'
                      : 'Try again to resume startup. If this keeps happening, quit Doorlight completely and open it again.',
                  onRetry: state.discardingIdentityRestore
                      ? null
                      : state.relaunchRequired
                      ? () => unawaited(state.relaunchRetired())
                      : state.resetDoorlightPending
                      ? () => unawaited(state.resetDoorlight())
                      : state.retryBoot,
                  retryLabel: state.relaunchRequired
                      ? AppState.relaunchLabel
                      : state.resetDoorlightPending
                      ? 'Finish reset'
                      : state.pendingIdentityRecovery
                      ? state.identityRecoveryRetryLabel
                      : 'Try again',
                  onDiscard:
                      state.canDiscardIdentityRestore &&
                          !state.discardingIdentityRestore
                      ? () async {
                          final owner = state.identityRestoreRecoveryOwner;
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Remove unfinished restore?'),
                              content: const Text(
                                'This removes only the incomplete identity import on this device. Your backup file stays unchanged. Settings already applied will be kept. You can choose your backup again afterward.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Keep restore'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Remove import'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await state.discardIdentityRestore(owner);
                          }
                        }
                      : null,
                ),
                Screen.onboarding => OnboardingScreen(state: state),
                Screen.home => WidgetChatConsentHost(
                  state: state,
                  child: HomeScreen(state: state, appLockController: _appLock),
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  /// Set when boot failed — the splash swaps the spinner for the message + a retry (never strands silently).
  final String? error;
  final String? guidance;
  final String? details;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;
  final String retryLabel;
  const _Splash({
    this.error,
    this.guidance,
    this.details,
    this.onRetry,
    this.onDiscard,
    this.retryLabel = 'Try again',
  });
  @override
  Widget build(BuildContext context) {
    final err = error;
    return OnboardingSurface(
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, viewport) {
                final desktop = viewport.maxWidth >= 600;
                final compact = MediaQuery.sizeOf(context).height < 640;
                return Align(
                  alignment: const Alignment(0, -.236),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 390),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (viewport.maxHeight >= 320) ...[
                            Center(
                              child: PlayfulDoor(
                                size: desktop
                                    ? (viewport.maxHeight * .26).clamp(
                                        96.0,
                                        160.0,
                                      )
                                    : (compact ? 80 : 144),
                                openness: 1.4,
                                illumination: 1,
                                thresholdPhase: 0,
                              ),
                            ),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'Doorlight',
                                style: context.syblColors.display.copyWith(
                                  fontSize: desktop
                                      ? (compact ? 40 : 48)
                                      : (compact ? 34 : 44),
                                  fontWeight: FontWeight.w400,
                                  height: 1.15,
                                  color: context.syblColors.amber,
                                ),
                              ),
                            ),
                            SizedBox(height: compact ? 12 : 16),
                          ],
                          Flexible(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    err ?? 'warming up…',
                                    textAlign: TextAlign.center,
                                    style: context.syblColors.display.copyWith(
                                      fontSize: compact ? 22 : 26,
                                      height: 1.4,
                                    ),
                                  ),
                                  if (err != null && guidance != null) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      guidance!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: context.syblColors.muted,
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 24),
                                  if (err == null)
                                    Center(
                                      child: SizedBox.square(
                                        dimension: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: context.syblColors.muted,
                                        ),
                                      ),
                                    )
                                  else if (onRetry != null)
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(48, 58),
                                        shape:
                                            context.syblColors.buttonRadius !=
                                                null
                                            ? context.syblColors.buttonShape
                                            : RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                              ),
                                      ),
                                      onPressed: onRetry,
                                      child: Text(retryLabel),
                                    ),
                                  if (err != null && onDiscard != null)
                                    TextButton(
                                      onPressed: onDiscard,
                                      child: const Text(
                                        'Remove unfinished import',
                                      ),
                                    ),
                                  if (err != null && details != null) ...[
                                    const SizedBox(height: 12),
                                    ExpansionTile(
                                      key: ValueKey(details),
                                      title: const Text('Technical details'),
                                      tilePadding: EdgeInsets.zero,
                                      childrenPadding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      children: [
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: SelectableText(
                                            details!,
                                            style: TextStyle(
                                              color: context.syblColors.muted,
                                              height: 1.45,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
