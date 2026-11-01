import 'theme_reveal.dart';
import 'notice.dart';
import 'google_wake_choice.dart';
import 'window_presentation.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/jami.dart';
import '../state/app_lock.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'onboarding_surface.dart';
import '../widgets/passphrase_dialog.dart';
import 'account_share.dart';
import 'doorlight_brand.dart';
import 'gravity.dart';
import 'profile_picture_editor.dart';
import 'sybl_ui.dart';
import 'settings_profile.dart';
import 'desktop_settings_scrubber.dart';
import '../state/app_settings.dart'
    show AppSettings, WindowEdgeSpacing, WindowCloseAnimation;
import 'vibe_settings.dart';
import 'settings_previews.dart';
import 'message_time_settings.dart';
import 'message_receipt_settings.dart';
import 'sender_label_settings.dart';
import 'game_bar_setup.dart';
import 'window_dismiss.dart';

/// Applied-state copy. Only the ACTUAL native state may be described here;
/// [showThisSession] refines the intentional `none` state when the user chose
/// "Show" while the persisted preference stays enabled.
String windowCaptureProtectionDescription(
  WindowCaptureProtectionStatus status, {
  bool showThisSession = false,
}) => switch (status) {
  WindowCaptureProtectionStatus.exclude =>
    'Hidden from supported screenshot and screen-capture APIs. Shared apps and displays are unaffected.',
  WindowCaptureProtectionStatus.monitor =>
    'Protected with the Windows monitor-only fallback. Some capture paths are blocked, but full exclusion is not available.',
  WindowCaptureProtectionStatus.none =>
    showThisSession
        ? 'Visible in screen capture for this session. Protection returns at the next launch.'
        : 'This app window appears in screenshots and screen sharing.',
  WindowCaptureProtectionStatus.unavailable =>
    'This app window is not protected from screenshots or screen sharing on this device.',
};

String androidCaptureProtectionDescription(
  WindowCaptureProtectionStatus status,
) => switch (status) {
  WindowCaptureProtectionStatus.exclude ||
  WindowCaptureProtectionStatus.monitor =>
    'Open chats, calls and link codes are protected from supported screenshots and screen capture, and recent-app previews are hidden. Other apps and external cameras are unaffected.',
  WindowCaptureProtectionStatus.none =>
    'Doorlight surfaces can appear in screenshots, screen capture and recent-app previews.',
  WindowCaptureProtectionStatus.unavailable =>
    'Screen capture protection is unavailable on this device. Doorlight surfaces may appear in screenshots, screen capture and recent-app previews.',
};

class SettingsPane extends StatefulWidget {
  final AppState state;
  final AppLockController? appLockController;
  final VoidCallback onClose;
  final VoidCallback onOpenDiagnostics;
  final VoidCallback? onAddFriend;
  final bool focusMicrophoneOnOpen;

  const SettingsPane({
    super.key,
    required this.state,
    this.appLockController,
    required this.onClose,
    required this.onOpenDiagnostics,
    this.onAddFriend,
    this.focusMicrophoneOnOpen = false,
  });

  @override
  State<SettingsPane> createState() => _SettingsPaneState();
}

class _SettingsPaneState extends State<SettingsPane> {
  Future<void> _resetFriendPreferences() async {
    final state = widget.state;
    final owner = state.linkedDeviceOwner;
    final reset = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(child: const Text('Reset restored friend preferences?')),
        content: Gravity(
          child: const Text(
            'The backup does not establish which account owns these choices. Reset removes the restored friend overrides and keeps message alerts and Holograms off. You can choose new defaults and friend settings afterward.',
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ),
          Gravity(
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset preferences'),
            ),
          ),
        ],
      ),
    );
    if (!mounted ||
        reset != true ||
        owner != state.linkedDeviceOwner ||
        !state.canManageFriendPreferences) {
      return;
    }
    await state.resetUnreviewedFriendPreferences();
  }

  final _scrollController = ScrollController();
  final _railFocus = FocusNode();
  final _desktopScrubberKey = GlobalKey<DesktopSettingsScrubberState>();
  final _viewportKey = GlobalKey();
  final _profileKey = GlobalKey();
  final _appearanceKey = GlobalKey();
  final _notificationsKey = GlobalKey();
  final _connectionKey = GlobalKey();
  final _voiceKey = GlobalKey();
  final _filesKey = GlobalKey();
  final _safetyKey = GlobalKey();
  final _advancedKey = GlobalKey();
  int _activeSection = 0;
  double _sectionProgress = 0;
  int _sectionJump = 0;
  bool _scrollingToSection = false;
  bool _desktopRail = false;
  bool _showTransientRail = false;
  double _transientRailOpacity = 0;
  double _lastRailScrollOffset = 0;
  double _railScrollDistance = 0;
  DateTime? _lastRailScrollTime;
  bool _sectionRailPinned = false;
  bool _backupPromptOpen = false;
  bool _draggingSectionRail = false;
  bool _sectionRailFocused = false;
  Timer? _railHideTimer;
  Timer? _labelHideTimer;
  bool _showSectionLabel = false;

  List<GlobalKey> get _sectionKeys => [
    _profileKey,
    _appearanceKey,
    _notificationsKey,
    _voiceKey,
    _connectionKey,
    _filesKey,
    _safetyKey,
    _advancedKey,
  ];

  AppState get state => widget.state;
  AppLockController? get appLockController => widget.appLockController;
  VoidCallback get onClose => widget.onClose;
  VoidCallback get onOpenDiagnostics => widget.onOpenDiagnostics;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_trackSection);
    if (widget.focusMicrophoneOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSection(_voiceKey, 3);
      });
    }
  }

  @override
  void dispose() {
    _railHideTimer?.cancel();
    _labelHideTimer?.cancel();
    _scrollController.dispose();
    _railFocus.dispose();
    super.dispose();
  }

  void _trackSection() {
    if (!mounted || _desktopRail || !_scrollController.hasClients) return;
    if (!_showTransientRail) {
      _railScrollDistance = 0;
      _lastRailScrollTime = null;
    }
    final now = WidgetsBinding.instance.samplingClock.now();
    final offset = _scrollController.position.pixels;
    final distance = (offset - _lastRailScrollOffset).abs();
    final elapsed = _lastRailScrollTime == null
        ? 16.0
        : now.difference(_lastRailScrollTime!).inMicroseconds / 1000;
    _lastRailScrollOffset = offset;
    _lastRailScrollTime = now;
    _railScrollDistance += distance;
    final speed = distance * 1000 / (elapsed > 0 ? elapsed : 16);
    final activity = (speed / 900).clamp(0.0, 1.0);
    final travel = (_railScrollDistance / 240).clamp(0.0, 1.0);
    _revealTransientRail(
      opacity: .25 + .75 * (activity > travel ? activity : travel),
    );
    if (_scrollingToSection) return;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final sectionTop = viewport is RenderBox
        ? viewport.localToGlobal(Offset.zero).dy + 24
        : 150.0;
    var next = 0;
    for (var index = 0; index < _sectionKeys.length; index++) {
      final box = _sectionKeys[index].currentContext?.findRenderObject();
      if (box is RenderBox && box.localToGlobal(Offset.zero).dy < sectionTop) {
        next = index;
      }
    }
    // A short final section cannot reach the top; the end of the list is it.
    if (_scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 0 &&
        _scrollController.position.extentAfter < 1) {
      next = _sectionKeys.length - 1;
    }
    // Measure the whole section, including long and expanded settings groups.
    var progress = 0.0;
    final current = _sectionKeys[next].currentContext?.findRenderObject();
    final following = next + 1 < _sectionKeys.length
        ? _sectionKeys[next + 1].currentContext?.findRenderObject()
        : null;
    if (current is RenderBox) {
      final start = current.localToGlobal(Offset.zero).dy;
      final end = following is RenderBox
          ? following.localToGlobal(Offset.zero).dy
          : sectionTop +
                _scrollController.position.extentAfter +
                _scrollController.position.viewportDimension -
                24;
      if (end > start) {
        progress = ((sectionTop - start) / (end - start)).clamp(0.0, 1.0);
      }
    }
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 1) {
      progress = 1;
    }
    if (mounted && (next != _activeSection || progress != _sectionProgress)) {
      setState(() {
        _activeSection = next;
        _sectionProgress = progress;
      });
    }
  }

  bool _usesTransientRail(BuildContext context, BoxConstraints constraints) =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS ||
      constraints.maxWidth < 400 ||
      constraints.maxHeight < 448 ||
      MediaQuery.textScalerOf(context).scale(14) >= 21;

  void _revealTransientRail({double opacity = 1}) {
    if (!mounted) return;
    final nextOpacity = _showTransientRail && _transientRailOpacity > opacity
        ? _transientRailOpacity
        : opacity;
    if (!_showTransientRail ||
        !_showSectionLabel ||
        nextOpacity != _transientRailOpacity) {
      setState(() {
        _showTransientRail = true;
        _transientRailOpacity = nextOpacity;
        _showSectionLabel = true;
      });
    }
    _labelHideTimer?.cancel();
    _labelHideTimer = Timer(const Duration(milliseconds: 420), () {
      if (mounted) setState(() => _showSectionLabel = false);
    });
    _scheduleRailHide();
  }

  void _scheduleRailHide() {
    _railHideTimer?.cancel();
    if (_draggingSectionRail || _sectionRailPinned || _sectionRailFocused) {
      return;
    }
    _railHideTimer = Timer(const Duration(milliseconds: 420), () {
      if (mounted) {
        setState(() => _showTransientRail = false);
        _railScrollDistance = 0;
        _lastRailScrollTime = null;
      }
    });
  }

  void _setRailDragging(bool dragging) {
    if (dragging) {
      _railFocus.unfocus();
      _sectionRailFocused = false;
    }
    setState(() => _draggingSectionRail = dragging);
    _revealTransientRail();
  }

  void _setRailFocused(bool focused) {
    if (_desktopRail) return;
    _sectionRailFocused = focused;
    if (focused) {
      _revealTransientRail();
    } else {
      _scheduleRailHide();
    }
  }

  void _toggleSectionRail() {
    _railHideTimer?.cancel();
    setState(() {
      _sectionRailPinned = !_sectionRailPinned;
      _showTransientRail = _sectionRailPinned;
      _transientRailOpacity = 1;
    });
  }

  void _showSection(GlobalKey key, int index) {
    final target = key.currentContext;
    if (target == null) return;
    final jump = ++_sectionJump;
    setState(() {
      _sectionRailPinned = false;
      _showTransientRail = true;
      _transientRailOpacity = 1;
      _activeSection = index;
      _sectionProgress = 0;
      _scrollingToSection = true;
    });
    unawaited(
      Scrollable.ensureVisible(
        target,
        duration: SyblMotion.duration(
          context,
          const Duration(milliseconds: 320),
        ),
        curve: Curves.easeInOutCubic,
        alignment: 0.02,
      ).whenComplete(() {
        if (mounted && jump == _sectionJump) {
          _scrollingToSection = false;
          _trackSection();
          if (!_draggingSectionRail && !_sectionRailFocused) {
            _railHideTimer?.cancel();
            setState(() => _showTransientRail = false);
          }
        }
      }),
    );
  }

  Future<void> _copyId(BuildContext context) async {
    if (state.jamiId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: state.jamiId));
    if (!context.mounted) return;
    showNotice('Friend ID copied', duration: const Duration(seconds: 1));
  }

  Future<void> _backup(BuildContext context) async {
    if (!mounted ||
        _backupPromptOpen ||
        state.backingUp ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final ownerState = state;
    final action = ownerState.captureConversationAction(
      isCurrent: () => mounted && identical(state, ownerState),
    );
    setState(() => _backupPromptOpen = true);
    try {
      final passphrase = await showPassphraseDialog(
        context,
        title: 'Back up your identity',
        subtitle: 'Add a password to protect your identity!',
        actionLabel: 'Create backup',
        confirm: true,
        allowEmpty: true,
      );
      if (passphrase == null ||
          !context.mounted ||
          !ownerState.ownsConversationAction(action) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final saved = await ownerState.backupIdentity(passphrase);
      if (!context.mounted ||
          !ownerState.ownsConversationAction(action) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      showNotice(
        saved
            ? 'Identity backed up'
            : ownerState.backupFailureNotice ?? 'Backup not completed',
      );
    } finally {
      if (mounted) setState(() => _backupPromptOpen = false);
    }
  }

  Future<void> _editProfilePicture(BuildContext context) async {
    await showProfilePictureEditor(context, state: state);
  }

  Future<void> _editDisplayName(BuildContext context) async {
    var draft = state.displayName;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Gravity(child: const Text('Edit your name')),
        content: Gravity(
          child: TextFormField(
            key: const ValueKey('display-name-field'),
            initialValue: draft,
            autofocus: SyblLayout.autofocusTextInput(context),
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (value) => draft = value,
            onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(draft),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    final updated = await state.updateDisplayName(value);
    if (!updated && context.mounted) {
      showNotice('Choose a non-empty name up to 256 UTF-8 bytes');
    }
  }

  Future<void> _removeProfilePicture(BuildContext context) async {
    final removed = await state.updateProfileAvatar(null);
    if (!removed && context.mounted) {
      showNotice('Could not remove your profile picture');
    }
  }

  Future<void> _resetDoorlight() async {
    final ownerState = state;
    final action = ownerState.captureConversationAction(
      isCurrent: () =>
          mounted &&
          identical(state, ownerState) &&
          appLockController?.locked != true &&
          ModalRoute.of(context)?.isCurrent == true,
    );
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => const _ResetDoorlightWarning(),
    );
    if (!mounted || !ownerState.ownsConversationAction(action)) return;
    if (choice == 'backup') {
      await _backup(context);
      return;
    }
    if (choice != 'continue') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(child: const Text('Reset this device?')),
        content: Gravity(
          child: const Text(
            'Make sure your identity backup is saved somewhere safe. '
            'You cannot undo this reset.',
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('reset-doorlight-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: context.syblColors.dangerFill,
                foregroundColor: context.syblColors.foregroundFor(
                  context.syblColors.dangerFill,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset Doorlight'),
            ),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !ownerState.ownsConversationAction(action)) {
      return;
    }
    await ownerState.resetDoorlight();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildSettings);

  Widget _buildSettings(BuildContext context, BoxConstraints constraints) {
    final compact = WindowPresentationScope.isCompact(context);
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    final narrowDesktop =
        desktop &&
        !compact &&
        MediaQuery.sizeOf(context).width < SyblLayout.desktopBreakpoint;
    final transientRail = !desktop && _usesTransientRail(context, constraints);
    final rightPadding = transientRail ? 24.0 : 78.0;
    // Keep related controls together when settings fills a monitor.
    final contentInset = ((constraints.maxWidth - 24 - rightPadding - 640) / 2)
        .clamp(0.0, double.infinity);
    final shortRail = constraints.maxHeight < (desktop && !compact ? 400 : 448);
    final desktopRail = desktop && !shortRail;
    if (_desktopRail != desktopRail) {
      _desktopRail = desktopRail;
      _railHideTimer?.cancel();
      _labelHideTimer?.cancel();
      if (!desktopRail) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _trackSection());
      }
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        if (desktop && !shortRail) {
          _desktopScrubberKey.currentState?.refreshMetrics();
        }
        return false;
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: OnboardingSurface(
          active: false,
          child: Column(
            children: [
              if (compact)
                CompactHeader(
                  title: 'Settings',
                  onBack: onClose,
                  actions: desktop
                      ? const []
                      : [
                          CompactIconButton(
                            label: 'Settings sections',
                            icon: Icons.view_list_rounded,
                            onPressed: _toggleSectionRail,
                          ),
                        ],
                )
              else if (narrowDesktop)
                Row(
                  key: const ValueKey('narrow-settings-header'),
                  children: [
                    IconButton(
                      key: const ValueKey('narrow-settings-back'),
                      tooltip: 'Back',
                      onPressed: onClose,
                      icon: const Icon(Icons.arrow_back_rounded, size: 20),
                    ),
                    const SettingsHeading('Settings'),
                  ],
                )
              else if (!desktop)
                Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Gravity(
                        child: TextButton.icon(
                          key: const ValueKey('close-settings-button'),
                          onPressed: onClose,
                          icon: const Icon(Icons.arrow_back_rounded, size: 19),
                          label: const Text('Back'),
                        ),
                      ),
                      Expanded(
                        child: Gravity(
                          child: Text(
                            'Settings',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: context.syblColors.display.copyWith(
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ),
                      if (transientRail)
                        Gravity(
                          child: IconButton(
                            key: const ValueKey('settings-section-menu-button'),
                            tooltip: 'Show settings sections',
                            onPressed: _toggleSectionRail,
                            icon: const Icon(Icons.view_list_rounded),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: Stack(
                  key: _viewportKey,
                  children: [
                    SingleChildScrollView(
                      key: const ValueKey('settings-list'),
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        24 + contentInset,
                        // The desktop title bar already gives space above.
                        desktop && !compact ? 8 : 22,
                        rightPadding + contentInset,
                        30,
                      ),
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerSignal: desktop && !shortRail
                            ? (event) => _desktopScrubberKey.currentState
                                  ?.handlePointerSignal(event)
                            : null,
                        onPointerDown: desktop && !shortRail
                            ? (_) =>
                                  _desktopScrubberKey.currentState?.stopWheel()
                            : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (state.settingsError != null) ...[
                              Semantics(
                                liveRegion: true,
                                child: Gravity(
                                  child: Container(
                                    key: ValueKey(
                                      state.settingsWritable
                                          ? 'settings-save-error'
                                          : 'settings-read-only-error',
                                    ),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: context.syblColors.danger
                                          .withValues(alpha: .1),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: context.syblColors.danger
                                            .withValues(alpha: .4),
                                      ),
                                    ),
                                    child: Text(
                                      state.settingsWritable
                                          ? state.settingsError!
                                          : 'Settings are read-only because the saved '
                                                'settings could not be understood. The '
                                                'original saved document was left unchanged.',
                                      style: TextStyle(
                                        color: context.syblColors.danger,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 22),
                            ],
                            Gravity(
                              child: SyblSectionLabel(
                                'Profile',
                                key: _profileKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SettingsProfile(
                              state: state,
                              onEditName: () => _editDisplayName(context),
                              onEditPicture: () => _editProfilePicture(context),
                              onRemovePicture: () =>
                                  _removeProfilePicture(context),
                              onCopyId: () => _copyId(context),
                              onShareId: () => showAccountShareDialog(
                                context,
                                jamiId: state.jamiId,
                                displayName: state.displayName,
                              ),
                              onAddFriend: widget.onAddFriend,
                            ),
                            const Divider(height: 42),
                            Gravity(
                              child: SyblSectionLabel(
                                'Appearance',
                                key: _appearanceKey,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const SettingsHeading('Theme'),
                            const SizedBox(height: 8),
                            _AppearanceSelector(state: state),
                            const SizedBox(height: 8),
                            VibeSettings(
                              value: state.appSettings.ambientVibe,
                              opacity: state.appSettings.vibeOpacity,
                              intensity: state.appSettings.vibeIntensity,
                              animated: state.chatMotionEnabled,
                              enabled: state.settingsControlsEnabled,
                              onChanged: state.setAmbientVibe,
                              onOpacityChanged: state.setVibeOpacity,
                              onIntensityChanged: state.setVibeIntensity,
                            ),
                            _SettingsRow(
                              inlineControl: true,
                              title: 'Animations',
                              trailing: Gravity(
                                child: Switch(
                                  key: const ValueKey('chat-motion-switch'),
                                  value: state.chatMotionEnabled,
                                  onChanged: state.settingsControlsEnabled
                                      ? state.setChatMotionEnabled
                                      : null,
                                ),
                              ),
                            ),
                            if (Theme.of(context).platform ==
                                TargetPlatform.windows)
                              _SettingsRow(
                                title: 'Window animations',
                                inlineControl: true,
                                actionWidth: 100,
                                trailing: TextButton.icon(
                                  key: const ValueKey(
                                    'window-animations-settings',
                                  ),
                                  onPressed:
                                      state.settingsControlsEnabled &&
                                          state.chatMotionEnabled
                                      ? () => _showWindowAnimationsDialog(
                                          context,
                                          state,
                                        )
                                      : null,
                                  icon: const Icon(
                                    Icons.tune_rounded,
                                    size: 17,
                                  ),
                                  label: const Text('Edit'),
                                ),
                              ),
                            _SettingsRow(
                              inlineControl: true,
                              title: 'Typing indicators',
                              trailing: Gravity(
                                child: Switch(
                                  key: const ValueKey('chat-activity-switch'),
                                  value: state.chatActivityIndicatorsEnabled,
                                  onChanged: state.settingsControlsEnabled
                                      ? state.setChatActivityIndicatorsEnabled
                                      : null,
                                ),
                              ),
                            ),
                            MessageTimeSettings(
                              value: state.messageTimestampStyle,
                              enabled: state.settingsControlsEnabled,
                              onChanged: state.setMessageTimestampStyle,
                            ),
                            MessageReceiptSettings(
                              style: state.messageReceiptStyle,
                              visibility: state.messageReceiptVisibility,
                              enabled: state.settingsControlsEnabled,
                              onStyleChanged: state.setMessageReceiptStyle,
                              onVisibilityChanged:
                                  state.setMessageReceiptVisibility,
                            ),
                            SenderLabelSettings(
                              value: state.repeatMessageAuthorAfterPause,
                              enabled: state.settingsControlsEnabled,
                              onChanged: state.setRepeatMessageAuthorAfterPause,
                            ),
                            _TopicAppearanceSettings(state: state),
                            if (Theme.of(context).platform ==
                                TargetPlatform.windows) ...[
                              const SizedBox(height: 18),
                              GameBarSetup(state: state),
                              const SizedBox(height: 18),
                            ],
                            if (Theme.of(context).platform ==
                                TargetPlatform.windows) ...[
                              SettingsChoices<GroupHeaderPlacement>(
                                key: const ValueKey('group-header-placement'),
                                title: 'Group header',
                                values: GroupHeaderPlacement.values,
                                value: state.groupHeaderPlacement,
                                label: (placement) =>
                                    placement ==
                                        GroupHeaderPlacement.conversation
                                    ? 'Above conversation'
                                    : 'Full width',
                                preview: (option) => GroupHeaderPreview(option),
                                enabled: state.settingsControlsEnabled,
                                onChanged: state.setGroupHeaderPlacement,
                              ),
                              SettingsChoices<WindowEdgeSpacing>(
                                title: 'Edge spacing',
                                values: WindowEdgeSpacing.values,
                                value: state.appSettings.windowEdgeSpacing,
                                label: (spacing) =>
                                    spacing == WindowEdgeSpacing.close
                                    ? 'Close'
                                    : 'Floating',
                                preview: (spacing) =>
                                    WindowEdgeSpacingPreview(spacing),
                                enabled: state.settingsControlsEnabled,
                                onChanged: (spacing) async {
                                  final window =
                                      WindowPresentationScope.maybeOf(context);
                                  if (await state.setWindowEdgeSpacing(
                                    spacing,
                                  )) {
                                    await window?.setEdgeSpacing(spacing);
                                  }
                                },
                              ),
                              _SettingsRow(
                                inlineControl: true,
                                title: 'Keep position on default size',
                                trailing: Gravity(
                                  child: Switch(
                                    key: const ValueKey(
                                      'remember-default-window-position',
                                    ),
                                    value: state
                                        .appSettings
                                        .rememberDefaultWindowPosition,
                                    onChanged: state.settingsControlsEnabled
                                        ? state.setRememberDefaultWindowPosition
                                        : null,
                                  ),
                                ),
                              ),
                            ] else
                              SettingsChoices<MobileGroupNavigation>(
                                key: const ValueKey('mobile-group-navigation'),
                                title: 'Group navigation',
                                values: MobileGroupNavigation.values,
                                value: state.mobileGroupNavigation,
                                label: (navigation) =>
                                    navigation == MobileGroupNavigation.inline
                                    ? 'Conversation first'
                                    : 'Rooms first',
                                preview: (option) => MobileGroupPreview(option),
                                enabled: state.settingsControlsEnabled,
                                onChanged: state.setMobileGroupNavigation,
                              ),
                            const SizedBox(height: 42),
                            Gravity(
                              child: SyblSectionLabel(
                                'Notifications',
                                key: _notificationsKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (state
                                .appSettings
                                .friendPreferencesReviewRequired)
                              _SettingsRow(
                                title:
                                    'Restored friend preferences need review',
                                subtitle:
                                    'Message alerts and Holograms are paused until you reset the unverified choices.',
                                trailing: Gravity(
                                  child: TextButton(
                                    onPressed: state.settingsControlsEnabled
                                        ? _resetFriendPreferences
                                        : null,
                                    child: const Text(
                                      'Reset friend preferences',
                                    ),
                                  ),
                                ),
                              ),
                            _SettingsRow(
                              inlineControl: true,
                              title: 'Message alerts',
                              trailing: Gravity(
                                child: Switch(
                                  key: const ValueKey('message-alerts-switch'),
                                  value: state.appSettings.messageAlertsEnabled,
                                  onChanged:
                                      state.settingsControlsEnabled &&
                                          !state
                                              .appSettings
                                              .friendPreferencesReviewRequired
                                      ? state.setMessageAlertsEnabled
                                      : null,
                                ),
                              ),
                            ),
                            if (Theme.of(context).platform ==
                                TargetPlatform.android)
                              _SettingsRow(
                                inlineControl: true,
                                title: 'Show message in notification',
                                trailing: Gravity(
                                  child: Switch(
                                    key: const ValueKey(
                                      'show-message-notification-switch',
                                    ),
                                    value: state.showMessageInNotification,
                                    onChanged: state.settingsControlsEnabled
                                        ? state.setShowMessageInNotification
                                        : null,
                                  ),
                                ),
                              ),
                            _SettingsRow(
                              inlineControl: true,
                              title: 'Allow Holograms by default',
                              trailing: Gravity(
                                child: Switch(
                                  key: const ValueKey(
                                    'hologram-presentation-switch',
                                  ),
                                  value: state
                                      .appSettings
                                      .hologramPresentationEnabled,
                                  onChanged:
                                      state.settingsControlsEnabled &&
                                          !state
                                              .appSettings
                                              .friendPreferencesReviewRequired
                                      ? state.setHologramPresentationEnabled
                                      : null,
                                ),
                              ),
                            ),
                            SettingsChoices<UnreadBadgePlacement>(
                              previewHeight: 40,
                              key: const ValueKey('unread-badge-placement'),
                              title: 'Unread badges',
                              values: UnreadBadgePlacement.values,
                              value: state.unreadBadgePlacement,
                              label: (placement) =>
                                  placement == UnreadBadgePlacement.avatar
                                  ? 'On picture'
                                  : 'End of row',
                              preview: (placement) =>
                                  UnreadBadgePreview(placement),
                              enabled: state.settingsControlsEnabled,
                              onChanged: state.setUnreadBadgePlacement,
                            ),
                            const SizedBox(height: 42),
                            Gravity(
                              child: SyblSectionLabel('Calls', key: _voiceKey),
                            ),
                            const SizedBox(height: 8),
                            _MicrophoneSettings(state: state),
                            const SizedBox(height: 42),
                            Gravity(
                              child: SyblSectionLabel(
                                'Network',
                                key: _connectionKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _SettingsRow(
                              inlineControl: true,
                              title: 'Go offline',
                              trailing: Gravity(
                                child: Switch(
                                  value: state.appearOffline,
                                  onChanged: state.canChangeOnlineStatus
                                      ? state.setAppearOffline
                                      : null,
                                ),
                              ),
                            ),
                            _ConnectionSelector(state: state),
                            _SettingsRow(
                              inlineControl: true,
                              title:
                                  Theme.of(context).platform ==
                                      TargetPlatform.android
                                  ? 'Google background alerts'
                                  : 'Wake friends’ phones',
                              subtitle: !state.googleWakeAvailable
                                  ? 'Not available in this version.'
                                  : state.connectionProfile != 'jami'
                                  ? 'Available only with Online.'
                                  : Theme.of(context).platform ==
                                        TargetPlatform.android
                                  ? 'Let Google wake Doorlight for messages and calls.'
                                  : 'Use Google wake signals when you message or call.',
                              trailing: Gravity(
                                child: Switch(
                                  key: const ValueKey(
                                    'reliable-background-notifications-switch',
                                  ),
                                  value: state.reliableBackgroundNotifications,
                                  onChanged:
                                      state.settingsControlsEnabled &&
                                          (state.reliableBackgroundNotifications ||
                                              (state.googleWakeAvailable &&
                                                  state.connectionProfile ==
                                                      'jami'))
                                      ? (enabled) {
                                          if (enabled) {
                                            unawaited(
                                              showGoogleWakeChoice(
                                                context,
                                                state,
                                              ),
                                            );
                                          } else {
                                            unawaited(
                                              state
                                                  .setReliableBackgroundNotifications(
                                                    false,
                                                  ),
                                            );
                                          }
                                        }
                                      : null,
                                ),
                              ),
                            ),
                            if (state.googleWakeCleanupPending)
                              TextButton(
                                onPressed: state.settingsControlsEnabled
                                    ? () => state
                                          .setReliableBackgroundNotifications(
                                            false,
                                          )
                                    : null,
                                child: const Text('Retry Google wake cleanup'),
                              ),
                            const SizedBox(height: 42),
                            Gravity(
                              child: SyblSectionLabel(
                                'Files & Storage',
                                key: _filesKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _FileSettings(state: state),
                            _SettingsRow(
                              title: 'Back up your identity',
                              trailing: Gravity(
                                child: OutlinedButton(
                                  onPressed:
                                      state.backingUp || _backupPromptOpen
                                      ? null
                                      : () => _backup(context),
                                  child: Text(
                                    state.backingUp ? 'Backing up…' : 'Back up',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 42),
                            Gravity(
                              child: SyblSectionLabel(
                                'Privacy & Security',
                                key: _safetyKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (appLockController case final controller?)
                              _AppLockSettingsRow(
                                controller: controller,
                                persistenceWritable: state.appLockWritable,
                              ),
                            if (Theme.of(context).platform ==
                                TargetPlatform.windows)
                              _WindowsCaptureProtectionRow(state: state)
                            else
                              _AndroidCaptureProtectionRow(state: state),
                            _SettingsRow(
                              inlineControl: true,
                              title: 'Share activity',
                              subtitle:
                                  Theme.of(context).platform ==
                                      TargetPlatform.windows
                                  ? 'Show friends when Doorlight is open and the foreground app name. Window titles are never shared.'
                                  : 'Show friends when Doorlight is open. Other apps are never scanned.',
                              trailing: Gravity(
                                child: Switch(
                                  key: const ValueKey(
                                    'share-active-app-switch',
                                  ),
                                  value: state.shareActivityPresence,
                                  onChanged: state.settingsControlsEnabled
                                      ? (value) => state
                                            .setShareActivityPresence(value)
                                      : null,
                                ),
                              ),
                            ),
                            const SizedBox(height: 42),
                            Gravity(
                              child: SyblSectionLabel(
                                'Advanced',
                                key: _advancedKey,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _HistoryScanSettings(state: state),
                            if (state.strictBootstrap.isNotEmpty ||
                                state.connectionProfile == 'strict')
                              _ConnectionSelector(state: state, advanced: true),
                            const SizedBox(height: 8),
                            _SettingsRow(
                              title: 'Diagnostics',
                              actionWidth: 104,
                              trailing: Gravity(
                                child: OutlinedButton(
                                  onPressed: onOpenDiagnostics,
                                  child: const Text('Open'),
                                ),
                              ),
                            ),
                            _SettingsRow(
                              title: 'About Doorlight',
                              actionWidth: 104,
                              trailing: Gravity(
                                child: OutlinedButton(
                                  key: const ValueKey('settings-about'),
                                  onPressed: () => showDoorlightAbout(context),
                                  child: const Text('About'),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            _SettingsRow(
                              title: 'Reset Doorlight',
                              actionWidth: 104,
                              subtitle:
                                  state.resetDoorlightError ??
                                  'Remove this device’s identity and local data. Back up first to keep your identity.',
                              trailing: Gravity(
                                child: OutlinedButton(
                                  key: const ValueKey('reset-doorlight-button'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: context.syblColors.danger,
                                  ),
                                  onPressed:
                                      state.resettingDoorlight ||
                                          state.backingUp
                                      ? null
                                      : _resetDoorlight,
                                  child: Text(
                                    state.resettingDoorlight
                                        ? 'Resetting…'
                                        : 'Reset',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      key: const ValueKey('settings-section-rail'),
                      top: 0,
                      right: 8 + contentInset,
                      bottom: 0,
                      width: shortRail ? 104 : (transientRail ? 56 : 64),
                      child: ExcludeFocus(
                        excluding: transientRail && !_showTransientRail,
                        child: Focus(
                          focusNode: _railFocus,
                          onFocusChange: _setRailFocused,
                          child: IgnorePointer(
                            ignoring: transientRail && !_showTransientRail,
                            child: AnimatedOpacity(
                              duration: SyblMotion.duration(
                                context,
                                const Duration(milliseconds: 160),
                              ),
                              opacity: !transientRail
                                  ? 1
                                  : (_showTransientRail
                                        ? _transientRailOpacity
                                        : 0),
                              child: Center(
                                child: ColoredBox(
                                  key: const ValueKey(
                                    'settings-section-rail-strip',
                                  ),
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 4,
                                    ),
                                    child: desktop && !shortRail
                                        ? DesktopSettingsScrubber(
                                            key: _desktopScrubberKey,
                                            controller: _scrollController,
                                            sectionKeys: _sectionKeys,
                                            viewportKey: _viewportKey,
                                            animationsEnabled:
                                                state.chatMotionEnabled,
                                          )
                                        : _SettingsSectionRail(
                                            shortWindow: shortRail,
                                            activeIndex: _activeSection,
                                            showLabel: _showSectionLabel,
                                            progress: _sectionProgress,
                                            onDragging: _setRailDragging,
                                            onSelect: (index) => _showSection(
                                              _sectionKeys[index],
                                              index,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResetDoorlightWarning extends StatefulWidget {
  const _ResetDoorlightWarning();

  @override
  State<_ResetDoorlightWarning> createState() => _ResetDoorlightWarningState();
}

class _ResetDoorlightWarningState extends State<_ResetDoorlightWarning> {
  int _seconds = 3;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _seconds--);
      if (_seconds == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Gravity(child: const Text('Before you reset Doorlight')),
    content: Gravity(
      child: const Text(
        'Reset removes this device’s identity, chat history and settings. '
        'Your other devices are unchanged. Files saved or exported outside '
        'the account remain. '
        'Doorlight must be restarted afterward.\n\n'
        'To keep your Friend ID, save an identity backup first and keep its password. '
        'After restarting, choose “I already have Doorlight” and restore that backup. '
        'The identity backup does not include chat history or files. '
        'Without a backup or another linked device, you cannot recover this identity.',
      ),
    ),
    actions: [
      Gravity(
        child: TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ),
      Gravity(
        child: TextButton(
          key: const ValueKey('reset-doorlight-backup'),
          onPressed: () => Navigator.of(context).pop('backup'),
          child: const Text('Back up identity'),
        ),
      ),
      Gravity(
        child: FilledButton(
          key: const ValueKey('reset-doorlight-continue'),
          onPressed: _seconds == 0
              ? () => Navigator.of(context).pop('continue')
              : null,
          child: Text(_seconds == 0 ? 'Continue' : 'Continue ($_seconds)'),
        ),
      ),
    ],
  );
}

class _TopicAppearanceSettings extends StatelessWidget {
  const _TopicAppearanceSettings({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final settings = state.topicStripSurfaceSettings;
    final editable =
        state.settingsControlsEnabled &&
        settings.coverage != TopicStripSurfaceCoverage.off;
    void save(TopicStripSurfaceSettings next) =>
        state.setTopicStripSurfaceSettings(next);
    return Column(
      key: const ValueKey('topic-strip-surface-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoices<TopicStripSurfaceCoverage>(
          previewHeight: 80,
          title: 'Topic bar background',
          values: TopicStripSurfaceCoverage.values,
          value: settings.coverage,
          label: (coverage) => switch (coverage) {
            TopicStripSurfaceCoverage.topics => 'Behind topics',
            TopicStripSurfaceCoverage.fullWidth => 'Full width',
            TopicStripSurfaceCoverage.off => 'No background',
          },
          preview: (coverage) =>
              TopicBackgroundPreview(settings.copyWith(coverage: coverage)),
          enabled: state.settingsControlsEnabled,
          onChanged: (coverage) => save(settings.copyWith(coverage: coverage)),
        ),
        ExpansionTile(
          key: const ValueKey('appearance-advanced'),
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text('Fine-tune topic background'),
          children: [
            _TopicSurfaceSlider(
              label: 'Opacity',
              value: settings.strength,
              max: TopicStripSurfaceSettings.maxStrength,
              unit: '%',
              enabled: editable,
              onChanged: (v) => save(settings.copyWith(strength: v)),
            ),
            _TopicSurfaceSlider(
              label: 'Blur',
              value: settings.blur,
              max: TopicStripSurfaceSettings.maxBlur,
              unit: ' px',
              enabled: editable,
              onChanged: (v) => save(settings.copyWith(blur: v)),
            ),
            _TopicSurfaceSlider(
              label: 'Background depth',
              value: settings.solidReach,
              max: TopicStripSurfaceSettings.maxSolidReach,
              unit: ' px',
              enabled: editable,
              onChanged: (v) => save(settings.copyWith(solidReach: v)),
            ),
            _TopicSurfaceSlider(
              label: 'Bottom fade',
              value: settings.lowerFade,
              max: TopicStripSurfaceSettings.maxLowerFade,
              unit: ' px',
              enabled: editable,
              onChanged: (v) => save(settings.copyWith(lowerFade: v)),
            ),
            _TopicSurfaceSlider(
              label: 'Side fade',
              value: settings.rightFade,
              max: TopicStripSurfaceSettings.maxRightFade,
              unit: ' px',
              enabled: editable,
              onChanged: (v) => save(settings.copyWith(rightFade: v)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('reset-topic-surface'),
                onPressed: state.settingsControlsEnabled
                    ? state.resetTopicStripSurfaceSettings
                    : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Reset topic background'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TopicSurfaceSlider extends StatelessWidget {
  const _TopicSurfaceSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.unit,
    required this.onChanged,
    required this.enabled,
  });

  final String label;
  final int value;
  final int max;
  final String unit;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    value: '$value$unit',
    child: Row(
      children: [
        Expanded(
          flex: 4,
          child: Gravity(
            child: Text(
              label,
              maxLines: 2,
              style: TextStyle(color: context.syblColors.muted, fontSize: 12),
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: Gravity(
            child: Slider(
              key: ValueKey('topic-surface-${label.toLowerCase()}'),
              min: 0,
              max: max.toDouble(),
              divisions: max,
              value: value.toDouble(),
              semanticFormatterCallback: (next) => '${next.round()}$unit',
              onChanged: enabled ? (next) => onChanged(next.round()) : null,
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Gravity(
            child: Text(
              '$value$unit',
              textAlign: TextAlign.end,
              style: TextStyle(color: context.syblColors.faint, fontSize: 12),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AppearanceSelector extends StatelessWidget {
  const _AppearanceSelector({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    const labels = <AppearancePreset, String>{
      AppearancePreset.disaccord: 'Disaccord',
      AppearancePreset.cozy: 'Cozy',
      AppearancePreset.midnight: 'Midnight',
    };
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return SettingsPreviewRow(
      count: labels.length,
      minTileWidth: largeText ? 130 : 72,
      maxTileWidth: largeText ? 130 : 98,
      spacing: 12,
      children: (width) => [
        for (final entry in labels.entries)
          _ThemeSwatch(
            preset: entry.key,
            label: entry.value,
            colors: Warm.palette(entry.key),
            selected: state.appearancePreset == entry.key,
            enabled: state.settingsControlsEnabled,
            width: width,
            onPressed: (tileContext) {
              if (state.appearancePreset != entry.key) {
                ThemeReveal.change(
                  tileContext,
                  () => state.setAppearancePreset(entry.key),
                );
              }
            },
          ),
      ],
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.preset,
    required this.label,
    required this.colors,
    required this.selected,
    required this.enabled,
    required this.onPressed,
    required this.width,
  });

  final AppearancePreset preset;
  final String label;
  final SyblColors colors;
  final bool selected;
  final bool enabled;
  final ValueChanged<BuildContext> onPressed;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '$label appearance',
      child: Gravity(
        child: Material(
          color: colors.surfaceHi,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected ? colors.amber : colors.lineStrong,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('appearance-${preset.storageValue}'),
            onTap: enabled ? () => onPressed(context) : null,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RepaintBoundary(
                    key: ValueKey('appearance-preview-${preset.storageValue}'),
                    child: SizedBox(
                      width: double.infinity,
                      height: width * 5 / 7,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _AppearancePreview(colors),
                            ),
                          ),
                          if (selected)
                            Align(
                              alignment: Alignment.topRight,
                              child: Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  color: colors.amber,
                                  size: 16,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(7),
                    child: Text(
                      label,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: enabled ? colors.ink : colors.faint,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppearancePreview extends CustomPainter {
  const _AppearancePreview(this.colors);

  final SyblColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    // Use the default 700×500 layout: surfaces dominate, accents stay small.
    canvas.scale(size.width / 700, size.height / 500);
    final paint = Paint();
    void box(
      double x,
      double y,
      double w,
      double h,
      Color color, [
      double radius = 0,
    ]) {
      paint.color = color;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, h),
          Radius.circular(radius),
        ),
        paint,
      );
    }

    void dot(double x, double y, double radius, Color color) {
      paint.color = color;
      canvas.drawCircle(Offset(x, y), radius, paint);
    }

    box(0, 0, 700, 500, colors.surface);
    box(0, 0, 212, 500, colors.desk);
    box(212, 0, 488, 56, colors.bg);
    box(14, 24, 92, 7, colors.ink, 3);
    dot(184, 28, 17, colors.accentFill);
    box(8, 60, 196, 54, colors.surfaceTop, 10);
    for (var i = 0; i < 3; i++) {
      final y = 87.0 + i * 68;
      dot(29, y, 18, [colors.rose, colors.sky, colors.sage][i]);
      box(59, y - 8, 64, 6, colors.ink, 3);
      box(59, y + 6, 38, 4, colors.muted, 2);
    }
    dot(242, 27, 16, colors.rose);
    box(268, 18, 92, 7, colors.ink, 3);
    box(268, 34, 52, 4, colors.muted, 2);
    box(236, 130, 180, 58, colors.surfaceHi, 12);
    box(250, 146, 136, 5, colors.ink, 2);
    box(250, 162, 82, 5, colors.ink, 2);
    box(425, 212, 250, 64, colors.surfaceTop, 12);
    box(439, 230, 198, 5, colors.ink, 2);
    box(439, 247, 135, 5, colors.ink, 2);
    box(8, 436, 196, 54, colors.surfaceHi, 14);
    dot(29, 463, 18, colors.sage);
    box(59, 455, 80, 6, colors.ink, 3);
    box(59, 470, 40, 4, colors.muted, 2);
    box(230, 446, 450, 36, colors.surfaceHi, 18);
    box(246, 462, 86, 4, colors.faint, 2);
    dot(662, 464, 15, colors.accentFill);
  }

  @override
  bool shouldRepaint(_AppearancePreview oldDelegate) =>
      oldDelegate.colors != colors;
}

class _MicrophoneSettings extends StatelessWidget {
  const _MicrophoneSettings({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    const supportedModes = [MicrophoneMode.open, MicrophoneMode.pushToTalk];
    return Column(
      children: [
        if (state.appSettings.microphoneReviewRequired)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              liveRegion: true,
              child: Gravity(
                child: Text(
                  'Some microphone settings could not be matched after restore. '
                  'The microphone stays muted until you choose a default below. '
                  'Then check each friend’s call mode.',
                  key: const ValueKey('restore-microphone-review'),
                  style: TextStyle(color: context.syblColors.ink, height: 1.35),
                ),
              ),
            ),
          ),
        _SettingsRow(
          title: state.appSettings.microphoneReviewRequired
              ? 'Choose a default'
              : 'Default microphone',
          trailing: Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              for (final mode in supportedModes)
                _SegmentButton(
                  icon: mode == MicrophoneMode.pushToTalk
                      ? Icons.keyboard_rounded
                      : Icons.mic_none_rounded,
                  label: _microphoneModeLabel(mode),
                  selected:
                      !state.appSettings.microphoneReviewRequired &&
                      _visibleMicrophoneMode(
                            state.appSettings.globalMicrophoneMode,
                          ) ==
                          mode,
                  enabled: state.settingsControlsEnabled,
                  onPressed: () => state.setGlobalMicrophoneMode(mode),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FileSettings extends StatelessWidget {
  const _FileSettings({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    const mib = 1024 * 1024;
    const gib = 1024 * mib;
    const commonFileLimits = [256 * mib, gib, 2 * gib, 10 * gib, 0];
    final fileLimits =
        {...commonFileLimits, state.maxIncomingFileBytes}.toList()
          ..sort((left, right) {
            if (left == 0) return 1;
            if (right == 0) return -1;
            return left.compareTo(right);
          });
    return Column(
      children: [
        _SettingsRow(
          title: 'Incoming file limit',
          subtitle: state.maxIncomingFileBytes == 0
              ? 'No safety cap. A peer can fill the available disk space.'
              : 'Transfers over this declared or observed size stop automatically.',
          trailing: _SettingsDropdown<int>(
            value: state.maxIncomingFileBytes,
            enabled: state.settingsControlsEnabled,
            values: fileLimits,
            label: (value) =>
                value == 0 ? 'No cap' : _formatSettingBytes(value),
            onChanged: state.setMaxIncomingFileBytes,
          ),
        ),
      ],
    );
  }
}

class _HistoryScanSettings extends StatelessWidget {
  const _HistoryScanSettings({required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    const commonHistoryLimits = [50, 100, 200, 500, 1000];
    final historyLimits = {
      ...commonHistoryLimits,
      state.folderKeepLast,
    }.toList()..sort();
    return _SettingsRow(
      title: 'Shared files scanned',
      actionWidth: (144 * MediaQuery.textScalerOf(context).scale(14) / 14)
          .clamp(144, 260)
          .toDouble(),
      trailing: _SettingsDropdown<int>(
        value: state.folderKeepLast,
        enabled: state.settingsControlsEnabled,
        values: historyLimits,
        label: (value) => '$value items',
        onChanged: state.setFolderHistoryLimit,
      ),
    );
  }
}

Future<void> _showWindowAnimationsDialog(
  BuildContext context,
  AppState state,
) => showDialog<void>(
  context: context,
  builder: (_) => RepaintBoundary(
    key: const ValueKey('window-animations-dialog-boundary'),
    child: _WindowAnimationsDialog(state: state),
  ),
);

class _WindowAnimationsDialog extends StatefulWidget {
  const _WindowAnimationsDialog({required this.state});

  final AppState state;

  @override
  State<_WindowAnimationsDialog> createState() =>
      _WindowAnimationsDialogState();
}

class _WindowAnimationsDialogState extends State<_WindowAnimationsDialog> {
  AppSettings get settings => widget.state.appSettings;

  late WindowCloseAnimation _openAnimation = settings.windowOpenAnimation;
  late WindowCloseAnimation _minimizeAnimation =
      settings.windowMinimizeAnimation;
  late WindowCloseAnimation _closeAnimation = settings.windowCloseAnimation;
  late int _openDurationMs = settings.windowOpenDurationMs;
  late int _minimizeDurationMs = settings.windowMinimizeDurationMs;
  late int _closeDurationMs = settings.windowCloseDurationMs;
  String? _previewingAction;
  String? _previewUnavailableAction;

  bool get _enabled =>
      widget.state.settingsControlsEnabled && widget.state.chatMotionEnabled;

  Future<void> _preview(
    String action,
    WindowCloseAnimation animation,
    int durationMs,
  ) async {
    if (!_enabled ||
        animation == WindowCloseAnimation.none ||
        _previewingAction != null) {
      return;
    }
    setState(() {
      _previewingAction = action;
      _previewUnavailableAction = null;
    });
    final completed = await WindowDismiss.preview(
      action: action,
      animation: animation,
      durationMs: durationMs,
    );
    if (!mounted) return;
    setState(() {
      _previewingAction = null;
      _previewUnavailableAction = completed || !_enabled ? null : action;
    });
  }

  void _updateDuration(String action, VoidCallback update) {
    setState(() {
      update();
      if (_previewUnavailableAction == action) {
        _previewUnavailableAction = null;
      }
    });
  }

  Future<bool> _saveDuration(
    int value, {
    required int currentValue,
    required Future<bool> Function(int) save,
    required ValueChanged<int> update,
  }) async {
    if (await save(value)) return true;
    if (mounted) setState(() => update(currentValue));
    return false;
  }

  Future<bool> _saveAnimation(
    WindowCloseAnimation value, {
    required WindowCloseAnimation currentValue,
    required Future<bool> Function(WindowCloseAnimation) save,
    required ValueChanged<WindowCloseAnimation> update,
  }) async {
    if (_previewUnavailableAction != null) {
      setState(() => _previewUnavailableAction = null);
    }
    if (mounted) setState(() => update(value));
    final saved = await save(value);
    if (!saved && mounted) setState(() => update(currentValue));
    return saved;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => AlertDialog(
      title: const Text('Window animations'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _WindowAnimationGroup(
                key: const ValueKey('window-animation-open'),
                id: 'open',
                title: 'Open',
                animation: _openAnimation,
                durationMs: _openDurationMs,
                enabled: _enabled,
                previewingAction: _previewingAction,
                previewUnavailable: _previewUnavailableAction == 'open',
                onPreview: () =>
                    _preview('open', _openAnimation, _openDurationMs),
                onAnimationChanged: (value) => _saveAnimation(
                  value,
                  currentValue: settings.windowOpenAnimation,
                  save: widget.state.setWindowOpenAnimation,
                  update: (value) => _openAnimation = value,
                ),
                onDurationChanged: (value) =>
                    _updateDuration('open', () => _openDurationMs = value),
                onDurationChangeEnd: (value) => _saveDuration(
                  value,
                  currentValue: settings.windowOpenDurationMs,
                  save: widget.state.setWindowOpenDurationMs,
                  update: (value) => _openDurationMs = value,
                ),
              ),
              const Divider(height: 28),
              _WindowAnimationGroup(
                key: const ValueKey('window-animation-minimize'),
                id: 'minimize',
                title: 'Minimize',
                animation: _minimizeAnimation,
                durationMs: _minimizeDurationMs,
                enabled: _enabled,
                previewingAction: _previewingAction,
                previewUnavailable: _previewUnavailableAction == 'minimize',
                onPreview: () => _preview(
                  'minimize',
                  _minimizeAnimation,
                  _minimizeDurationMs,
                ),
                onAnimationChanged: (value) => _saveAnimation(
                  value,
                  currentValue: settings.windowMinimizeAnimation,
                  save: widget.state.setWindowMinimizeAnimation,
                  update: (value) => _minimizeAnimation = value,
                ),
                onDurationChanged: (value) => _updateDuration(
                  'minimize',
                  () => _minimizeDurationMs = value,
                ),
                onDurationChangeEnd: (value) => _saveDuration(
                  value,
                  currentValue: settings.windowMinimizeDurationMs,
                  save: widget.state.setWindowMinimizeDurationMs,
                  update: (value) => _minimizeDurationMs = value,
                ),
              ),
              const Divider(height: 28),
              _WindowAnimationGroup(
                key: const ValueKey('window-animation-close'),
                id: 'close',
                title: 'Close',
                animation: _closeAnimation,
                durationMs: _closeDurationMs,
                enabled: _enabled,
                previewingAction: _previewingAction,
                previewUnavailable: _previewUnavailableAction == 'close',
                onPreview: () =>
                    _preview('close', _closeAnimation, _closeDurationMs),
                onAnimationChanged: (value) => _saveAnimation(
                  value,
                  currentValue: settings.windowCloseAnimation,
                  save: widget.state.setWindowCloseAnimation,
                  update: (value) => _closeAnimation = value,
                ),
                onDurationChanged: (value) =>
                    _updateDuration('close', () => _closeDurationMs = value),
                onDurationChangeEnd: (value) => _saveDuration(
                  value,
                  currentValue: settings.windowCloseDurationMs,
                  save: widget.state.setWindowCloseDurationMs,
                  update: (value) => _closeDurationMs = value,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('window-animations-done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _WindowAnimationGroup extends StatelessWidget {
  const _WindowAnimationGroup({
    super.key,
    required this.id,
    required this.title,
    required this.animation,
    required this.durationMs,
    required this.enabled,
    required this.previewingAction,
    required this.previewUnavailable,
    required this.onPreview,
    required this.onAnimationChanged,
    required this.onDurationChanged,
    required this.onDurationChangeEnd,
  });

  final String id;
  final String title;
  final WindowCloseAnimation animation;
  final int durationMs;
  final bool enabled;
  final String? previewingAction;
  final bool previewUnavailable;
  final VoidCallback onPreview;
  final Future<bool> Function(WindowCloseAnimation) onAnimationChanged;
  final ValueChanged<int> onDurationChanged;
  final Future<bool> Function(int) onDurationChangeEnd;

  bool get durationEnabled => enabled && animation != WindowCloseAnimation.none;

  bool get previewEnabled => durationEnabled && previewingAction == null;

  Widget _title(BuildContext context) => Text(
    title,
    style: TextStyle(
      color: context.syblColors.ink,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _dropdown() => _SettingsDropdown<WindowCloseAnimation>(
    key: ValueKey('window-$id-animation'),
    value: animation.isFold ? WindowCloseAnimation.door : animation,
    enabled: enabled,
    values: const [
      WindowCloseAnimation.tray,
      WindowCloseAnimation.door,
      WindowCloseAnimation.warp,
      WindowCloseAnimation.fade,
      WindowCloseAnimation.none,
    ],
    label: _windowAnimationLabel,
    onChanged: onAnimationChanged,
  );

  Widget _previewButton() => IconButton(
    key: ValueKey('window-$id-preview'),
    tooltip: 'Preview $title animation',
    onPressed: previewEnabled ? onPreview : null,
    icon: previewingAction == id
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.play_arrow_rounded, size: 20),
  );

  // Keep the slider's value-indicator portal in this semantics subtree.
  // Flutter #190357 otherwise emits orphan nodes inside a pushed dialog.
  Widget _durationSlider(BuildContext context) => Overlay.wrap(
    alwaysSizeToContent: true,
    clipBehavior: Clip.none,
    child: Semantics(
      label: '$title animation duration',
      value: '$durationMs milliseconds',
      child: Slider(
        key: ValueKey('window-$id-duration'),
        min: AppSettings.minWindowAnimationDurationMs.toDouble(),
        max: AppSettings.maxWindowAnimationDurationMs.toDouble(),
        divisions: 35,
        value: durationMs.toDouble(),
        semanticFormatterCallback: (value) => '${value.round()} milliseconds',
        onChanged: durationEnabled
            ? (value) => onDurationChanged(value.round())
            : null,
        onChangeEnd: durationEnabled
            ? (value) => onDurationChangeEnd(value.round())
            : null,
      ),
    ),
  );

  Widget _durationValue(BuildContext context) => Text(
    '$durationMs ms',
    textAlign: TextAlign.end,
    style: TextStyle(color: context.syblColors.muted, fontSize: 12),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          constraints.maxWidth < 440 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      final controls = Row(
        children: [
          Expanded(child: _dropdown()),
          _previewButton(),
        ],
      );
      final heading = compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [_title(context), const SizedBox(height: 4), controls],
            )
          : Row(
              children: [
                Expanded(child: _title(context)),
                _dropdown(),
                _previewButton(),
              ],
            );
      final slider = Expanded(child: _durationSlider(context));
      final fast = Text(
        'Fast',
        style: TextStyle(color: context.syblColors.faint, fontSize: 12),
      );
      final slow = Text(
        'Slow',
        style: TextStyle(color: context.syblColors.faint, fontSize: 12),
      );
      final duration = compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [fast, slider, slow]),
                Align(
                  alignment: Alignment.centerRight,
                  child: _durationValue(context),
                ),
              ],
            )
          : Row(
              children: [
                fast,
                slider,
                slow,
                const SizedBox(width: 10),
                SizedBox(width: 82, child: _durationValue(context)),
              ],
            );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          if (animation.isFold)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Fold direction',
                    style: TextStyle(
                      color: context.syblColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
                _SettingsDropdown<WindowCloseAnimation>(
                  key: ValueKey('window-$id-fold-direction'),
                  value: animation,
                  enabled: enabled,
                  values: const [
                    WindowCloseAnimation.door,
                    WindowCloseAnimation.foldRight,
                    WindowCloseAnimation.foldUp,
                    WindowCloseAnimation.foldDown,
                  ],
                  label: (value) => switch (value) {
                    WindowCloseAnimation.foldRight => 'Right',
                    WindowCloseAnimation.foldUp => 'Up',
                    WindowCloseAnimation.foldDown => 'Down',
                    _ => 'Left',
                  },
                  onChanged: onAnimationChanged,
                ),
              ],
            ),
          const SizedBox(height: 4),
          duration,
          if (previewUnavailable)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Preview unavailable',
                key: ValueKey('window-$id-preview-unavailable'),
                style: TextStyle(color: context.syblColors.faint, fontSize: 12),
              ),
            ),
        ],
      );
    },
  );
}

String _windowAnimationLabel(WindowCloseAnimation animation) =>
    switch (animation) {
      WindowCloseAnimation.tray => 'Move',
      WindowCloseAnimation.door ||
      WindowCloseAnimation.foldRight ||
      WindowCloseAnimation.foldUp ||
      WindowCloseAnimation.foldDown => 'Fold',
      WindowCloseAnimation.warp => 'Warp',
      WindowCloseAnimation.fade => 'Fade',
      WindowCloseAnimation.none => 'None',
    };

class _SettingsDropdown<T> extends StatelessWidget {
  const _SettingsDropdown({
    super.key,
    required this.value,
    required this.enabled,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final T value;
  final bool enabled;
  final List<T> values;
  final String Function(T value) label;
  final Future<bool> Function(T value) onChanged;

  @override
  Widget build(BuildContext context) {
    return Gravity(
      child: DropdownButtonHideUnderline(
        child: SizedBox(
          width: (144 * MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
            144,
            MediaQuery.sizeOf(context).width.clamp(192, double.infinity) - 48,
          ),
          child: DropdownButton<T>(
            isExpanded: true,
            value: value,
            onChanged: enabled
                ? (next) {
                    if (next != null) onChanged(next);
                  }
                : null,
            borderRadius: BorderRadius.circular(10),
            dropdownColor: context.syblColors.surfaceTop,
            selectedItemBuilder: (context) => [
              for (final option in values)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    label(option),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            items: [
              for (final option in values)
                DropdownMenuItem(value: option, child: Text(label(option))),
            ],
          ),
        ),
      ),
    );
  }
}

String _microphoneModeLabel(MicrophoneMode mode) => switch (mode) {
  MicrophoneMode.open => 'Open mic',
  MicrophoneMode.pushToTalk => 'Push-to-talk',
  MicrophoneMode.voiceActivated => 'Voice-activated',
};

MicrophoneMode _visibleMicrophoneMode(MicrophoneMode mode) =>
    mode == MicrophoneMode.voiceActivated ? MicrophoneMode.open : mode;

String _formatSettingBytes(int bytes) {
  const mib = 1024 * 1024;
  const gib = 1024 * mib;
  if (bytes >= gib && bytes % gib == 0) return '${bytes ~/ gib} GB';
  return '${bytes ~/ mib} MB';
}

class _CaptureStatusIcon extends StatelessWidget {
  const _CaptureStatusIcon({required this.status});

  final WindowCaptureProtectionStatus status;

  @override
  Widget build(BuildContext context) {
    return Icon(
      status == WindowCaptureProtectionStatus.exclude
          ? Icons.visibility_off_outlined
          : Icons.visibility_outlined,
      color: switch (status) {
        WindowCaptureProtectionStatus.exclude => context.syblColors.online,
        WindowCaptureProtectionStatus.monitor => context.syblColors.amber,
        WindowCaptureProtectionStatus.none ||
        WindowCaptureProtectionStatus.unavailable => context.syblColors.danger,
      },
      size: 21,
    );
  }
}

class _AndroidCaptureProtectionRow extends StatelessWidget {
  const _AndroidCaptureProtectionRow({required this.state});

  final AppState state;

  Future<void> _toggle(BuildContext context, bool enable) async {
    if (enable) {
      await state.setAndroidCaptureProtectionEnabled(true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(child: const Text('Allow screenshots of Doorlight?')),
        content: Gravity(
          child: const Text(
            'Chats, calls, and profile details can appear in screenshots and '
            'the Android recent-apps preview until you turn Screen capture protection back on.',
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('android-capture-disable-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Allow screenshots'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.setAndroidCaptureProtectionEnabled(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = state.captureSettingsNote;
    return _SettingsRow(
      inlineControl: true,
      title: 'Screen capture protection',
      subtitle:
          note ??
          androidCaptureProtectionDescription(state.windowCaptureProtection),
      trailing: Gravity(
        child: Switch(
          key: const ValueKey('android-capture-protection-switch'),
          value: state.androidCaptureProtectionEnabled,
          onChanged: state.captureBusy
              ? null
              : (value) => _toggle(context, value),
        ),
      ),
    );
  }
}

/// Windows control: the switch is the DESIRED persisted preference; the
/// subtitle and icon describe only the ACTUAL applied state. Neither is ever
/// derived from the other.
class _WindowsCaptureProtectionRow extends StatelessWidget {
  const _WindowsCaptureProtectionRow({required this.state});

  final AppState state;

  Future<void> _toggle(BuildContext context, bool enable) async {
    if (enable) {
      await state.setWindowsCaptureProtectionEnabled(true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(child: const Text('Show Doorlight in screen capture?')),
        content: Gravity(
          child: const Text(
            'Conversations, calls, and the whole app window become visible '
            'to supported screenshot and screen-sharing tools — now and on '
            'future launches.',
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              key: const ValueKey('capture-disable-cancel'),
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('capture-disable-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Show Doorlight'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.setWindowsCaptureProtectionEnabled(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = state.windowCaptureProtection;
    final sessionShown =
        state.windowsCaptureProtectionEnabled &&
        state.captureConsent == WindowsCaptureConsent.showThisSession &&
        status == WindowCaptureProtectionStatus.none;
    final note = state.captureSettingsNote;
    final description = windowCaptureProtectionDescription(
      status,
      showThisSession: sessionShown,
    );
    return _SettingsRow(
      inlineControl: true,
      title: 'Screen capture protection',
      subtitle: note == null ? description : '$description $note',
      trailing: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          // A session-only Show leaves the durable preference enabled, so the
          // switch already reads on. Let the user restore protection directly.
          if (state.windowsCaptureProtectionEnabled && !status.isProtected)
            Gravity(
              child: TextButton(
                key: const ValueKey('capture-hide-now'),
                onPressed: state.captureBusy
                    ? null
                    : state.restoreWindowsCaptureProtection,
                child: const Text('Hide now'),
              ),
            ),
          Gravity(child: _CaptureStatusIcon(status: status)),
          Gravity(
            child: Switch(
              key: const ValueKey('capture-protection-switch'),
              value: state.windowsCaptureProtectionEnabled,
              onChanged: !state.settingsControlsEnabled || state.captureBusy
                  ? null
                  : (value) => _toggle(context, value),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppLockSettingsRow extends StatelessWidget {
  const _AppLockSettingsRow({
    required this.controller,
    required this.persistenceWritable,
  });

  final AppLockController controller;
  final bool persistenceWritable;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final available =
            controller.availability == AppLockAvailability.available;
        // A settings write elsewhere only disables the switch briefly; the
        // description stays put so saving another setting never flashes it.
        final subtitle = switch (controller.failure) {
          AppLockFailure.persistence =>
            'The setting could not be saved. Nothing changed.',
          AppLockFailure.credentialsUnavailable || AppLockFailure.unsupported =>
            'Set up a device PIN, password, or biometric unlock first.',
          AppLockFailure.temporarilyUnavailable =>
            'Device authentication is temporarily unavailable.',
          AppLockFailure.rejected || AppLockFailure.canceled =>
            'Authentication was not completed. Nothing changed.',
          AppLockFailure.deviceError =>
            'The device could not open its authentication prompt.',
          _ when controller.enabled =>
            'Require this device’s PIN, password, or biometrics after Doorlight is hidden.',
          _ =>
            'Protect conversations when Doorlight is hidden. Credentials stay with the operating system.',
        };
        return _SettingsRow(
          inlineControl: true,
          title: 'App lock',
          subtitle: subtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.enabled && !controller.authenticating)
                Gravity(
                  child: IconButton(
                    tooltip: 'Lock Doorlight now',
                    onPressed: controller.lock,
                    icon: const Icon(Icons.lock_outline_rounded, size: 19),
                  ),
                ),
              Gravity(
                child: Switch(
                  value: controller.enabled,
                  onChanged:
                      !persistenceWritable ||
                          !available ||
                          controller.authenticating
                      ? null
                      : (value) => controller.setEnabled(value),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectionSelector extends StatelessWidget {
  final AppState state;
  final bool advanced;

  const _ConnectionSelector({required this.state, this.advanced = false});

  @override
  Widget build(BuildContext context) {
    final options = <({String value, String label})>[
      if (!advanced) ...[
        (value: 'jami', label: 'Online'),
        (value: 'lan', label: 'Local network only'),
      ],
      if (advanced &&
          (state.strictBootstrap.isNotEmpty ||
              state.connectionProfile == 'strict'))
        (value: 'strict', label: 'Self-hosted'),
    ];
    final description = switch (state.connectionProfile) {
      'lan' =>
        'Announces your name and Friend ID on this network. Connects locally without online helper servers.',
      'strict' =>
        advanced
            ? 'Uses only your configured self-hosted services.'
            : 'A custom network profile is active. Manage it in Advanced.',
      _ => 'Connect over the internet. Local network discovery is off.',
    };
    return _SettingsRow(
      title: advanced ? 'Custom network profile' : 'Connection',
      subtitle: advanced
          ? 'Use your configured self-hosted services. Online and local-network choices are in Network.'
          : description,
      trailing: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: WrapAlignment.end,
        children: [
          for (final option in options)
            _SegmentButton(
              icon: switch (option.value) {
                'lan' => Icons.wifi_rounded,
                'strict' => Icons.dns_outlined,
                _ => Icons.public_rounded,
              },
              label: option.label,
              selected: option.value == state.connectionProfile,
              enabled: state.canChangeConnectionProfile,
              onPressed: () => state.setConnectionProfile(option.value),
            ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  const _SegmentButton({
    this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Gravity(
      child: Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        child: Material(
          color: selected
              ? context.syblColors.surfaceTop
              : context.syblColors.surfaceHi,
          shape: context.syblColors.buttonShape.copyWith(
            side: BorderSide(
              color: selected
                  ? context.syblColors.amber
                  : context.syblColors.line,
            ),
          ),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            customBorder: context.syblColors.buttonShape,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                widthFactor: 1,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(
                          icon,
                          size: 17,
                          color: enabled
                              ? context.syblColors.muted
                              : context.syblColors.faint,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: enabled
                                ? selected
                                      ? context.syblColors.ink
                                      : context.syblColors.muted
                                : context.syblColors.faint,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSectionRail extends StatelessWidget {
  const _SettingsSectionRail({
    required this.shortWindow,
    required this.activeIndex,
    required this.showLabel,
    required this.progress,
    required this.onSelect,
    required this.onDragging,
  });

  static const _sections = DesktopSettingsScrubberState.sections;

  final int activeIndex;
  final bool showLabel;
  final bool shortWindow;
  final double progress;
  final ValueChanged<int> onSelect;
  final ValueChanged<bool> onDragging;

  @override
  Widget build(BuildContext context) {
    void selectAt(Offset position) {
      final row = ((position.dy - 4) / 48).floor();
      final index = (shortWindow ? row * 2 + (position.dx / 48).floor() : row)
          .clamp(0, _sections.length - 1);
      if (index != activeIndex) onSelect(index);
    }

    return Material(
      color: context.syblColors.bg,
      borderRadius: BorderRadius.circular(28),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          onDragging(true);
          selectAt(event.localPosition);
        },
        onPointerUp: (_) => onDragging(false),
        onPointerCancel: (_) => onDragging(false),
        onPointerMove: (event) => selectAt(event.localPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Wrap(
                direction: shortWindow ? Axis.horizontal : Axis.vertical,
                children: [
                  for (var index = 0; index < _sections.length; index++)
                    _SettingsJumpButton(
                      key: ValueKey('settings-jump-${_sections[index].$1}'),
                      label: _sections[index].$2,
                      icon: _sections[index].$3,
                      onPressed: () => onSelect(index),
                      active: activeIndex == index,
                      showLabel: showLabel,
                      labelOffset: shortWindow && index.isOdd ? 104 : 56,
                    ),
                ],
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Semantics(
                    key: const ValueKey('settings-section-progress'),
                    label: '${_sections[activeIndex].$2}, remaining',
                    value: '${((1 - progress) * 100).round()}',
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(
                        end: (activeIndex + progress) / _sections.length,
                      ),
                      duration: SyblMotion.duration(
                        context,
                        const Duration(milliseconds: 90),
                      ),
                      curve: Curves.easeOut,
                      builder: (context, position, _) => Align(
                        alignment: Alignment(1, position * 2 - 1),
                        child: Container(
                          key: const ValueKey('settings-scroll-thumb'),
                          width: 3,
                          height: 18,
                          decoration: BoxDecoration(
                            color: context.syblColors.amber,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsJumpButton extends StatefulWidget {
  const _SettingsJumpButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.active,
    required this.showLabel,
    required this.labelOffset,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final bool showLabel;
  final double labelOffset;

  @override
  State<_SettingsJumpButton> createState() => _SettingsJumpButtonState();
}

class _SettingsJumpButtonState extends State<_SettingsJumpButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.active;
    final scale = selected ? 1.22 : 1.0;
    return Semantics(
      selected: selected,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: AnimatedContainer(
            key: ValueKey('settings-jump-active-${widget.label}'),
            duration: SyblMotion.duration(context),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: selected
                  ? context.syblColors.amber.withValues(alpha: .14)
                  : Colors.transparent,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (selected)
                  Positioned(
                    right: widget.labelOffset,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: widget.showLabel ? 1 : 0,
                        duration: SyblMotion.duration(
                          context,
                          const Duration(milliseconds: 160),
                        ),
                        child: Container(
                          key: const ValueKey('settings-scroll-section-label'),
                          constraints: const BoxConstraints(maxWidth: 180),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: context.syblColors.bg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            widget.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.syblColors.ink,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: widget.label,
                  onPressed: widget.onPressed,
                  onHover: (hovered) => setState(() => _hovered = hovered),
                  padding: EdgeInsets.zero,
                  icon: AnimatedScale(
                    duration: SyblMotion.duration(context),
                    curve: Curves.easeOutCubic,
                    scale: scale,
                    child: Icon(
                      widget.icon,
                      size: 19,
                      color: selected
                          ? context.syblColors.amber
                          : _hovered
                          ? context.syblColors.ink
                          : context.syblColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget trailing;
  final double? actionWidth;
  final bool inlineControl;

  const _SettingsRow({
    required this.title,
    this.subtitle,
    required this.trailing,
    this.actionWidth,
    this.inlineControl = false,
  });

  @override
  Widget build(BuildContext context) {
    final dense = inlineControl && subtitle == null;
    return Container(
      constraints: BoxConstraints(minHeight: dense ? 48 : 64),
      padding: EdgeInsets.symmetric(vertical: dense ? 0 : 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final statusDuration = SyblMotion.duration(
            context,
            const Duration(milliseconds: 220),
          );
          final status = Text(
            subtitle ?? '',
            key: ValueKey(subtitle),
            maxLines: title == 'Your Friend ID' ? 2 : null,
            overflow: title == 'Your Friend ID' ? TextOverflow.ellipsis : null,
            style: TextStyle(
              color: context.syblColors.faint,
              fontSize: 12.5,
              height: 1.35,
              fontFamily: title == 'Your Friend ID' ? 'monospace' : null,
            ),
          );
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Gravity(
                child: Text(
                  title,
                  style: TextStyle(color: context.syblColors.ink, fontSize: 14),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                // Status copy changes cross-fade and resize instead of jumping.
                Gravity(
                  child: statusDuration == Duration.zero
                      ? status
                      : AnimatedSize(
                          duration: statusDuration,
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topLeft,
                          child: AnimatedSwitcher(
                            duration: statusDuration,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.topLeft,
                              children: [...previous, ?current],
                            ),
                            child: status,
                          ),
                        ),
                ),
              ],
            ],
          );
          final stacked =
              !inlineControl &&
              (constraints.maxWidth < 400 ||
                  MediaQuery.textScalerOf(context).scale(14) >= 21);
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                copy,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: trailing),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: 16),
              if (actionWidth != null)
                SizedBox(width: actionWidth, child: trailing)
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * .48,
                  ),
                  child: trailing,
                ),
            ],
          );
        },
      ),
    );
  }
}
