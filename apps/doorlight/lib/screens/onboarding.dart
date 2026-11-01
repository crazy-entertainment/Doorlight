import '../ui/notice.dart';
import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../core/jami_identity.dart';
import '../theme.dart';
import '../ui/gravity.dart';
import '../ui/playful_door.dart';
import '../ui/onboarding_surface.dart';
import '../ui/spinning_word.dart';
import '../ui/device_pairing_dialog.dart';
import '../ui/sybl_ui.dart';

enum _SetupStep { choose, create, existing, restore }

class OnboardingScreen extends StatefulWidget {
  final AppState state;
  const OnboardingScreen({super.key, required this.state});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _name = TextEditingController();
  final _passphrase = TextEditingController();
  final _expectedFriendId = TextEditingController();
  _SetupStep _step = _SetupStep.choose;
  bool _busy = false;
  bool _confirmingRestore = false;
  bool _showPassphrase = false;
  String? _backupPath;
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final AnimationController _threshold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6400),
  );
  bool _introStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _threshold.stop();
      _intro.value = 1;
      _introStarted = true;
    } else if (!_introStarted &&
        Theme.of(context).platform != TargetPlatform.windows) {
      _threshold.stop();
      _intro.forward();
      _introStarted = true;
    } else if (!_introStarted && !_threshold.isAnimating) {
      _threshold.repeat();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || Theme.of(context).platform != TargetPlatform.windows) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _threshold.stop();
      _intro.value = 1;
      _introStarted = true;
    } else if (state == AppLifecycleState.resumed &&
        _introStarted &&
        _intro.value < 1) {
      _threshold.stop();
      _intro.forward();
      _introStarted = true;
    } else if (state != AppLifecycleState.resumed) {
      _intro.stop();
    }
  }

  void _openOnInteraction() {
    if (!mounted || _intro.isCompleted) return;
    _threshold.stop();
    _introStarted = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
    } else if (!_intro.isAnimating) {
      _intro.forward();
    }
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted ||
        Theme.of(context).platform != TargetPlatform.windows ||
        event.viewId != View.of(context).viewId) {
      return;
    }
    if (event.state == ViewFocusState.focused) {
      if (_introStarted && !_intro.isCompleted) _intro.forward();
    } else {
      _intro.stop();
    }
  }

  void _go(_SetupStep step) => setState(() {
    _step = step;
  });

  Future<void> _startNewLink() async {
    if (!mounted || _busy || _step != _SetupStep.existing) return;
    final state = widget.state;
    final action = state.captureConversationAction(
      isCurrent: () =>
          mounted &&
          identical(widget.state, state) &&
          _step == _SetupStep.existing,
    );
    setState(() => _busy = true);
    try {
      final cancelled = await state.devicePairing.cancel();
      if (!mounted || !state.ownsConversationAction(action)) return;
      if (!cancelled) {
        _showError("Couldn't cancel the previous linking attempt. Try again.");
        return;
      }
      await showDevicePairingPage(context, state: state, destination: true);
    } catch (_) {
      if (state.ownsConversationAction(action)) {
        _showError("Couldn't start a new link. Try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (!mounted || _busy || _step != _SetupStep.create) return;
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final state = widget.state;
    final action = state.captureConversationAction(
      isCurrent: () => mounted && identical(widget.state, state),
    );
    setState(() => _busy = true);
    try {
      if (state.devicePairingPending && !await state.devicePairing.cancel()) {
        if (state.ownsConversationAction(action)) {
          _showError(
            "Couldn't cancel the previous linking attempt. Try again.",
          );
        }
        if (mounted) setState(() => _busy = false);
        return;
      }
      if (!state.ownsConversationAction(action)) return;
      await state.onboard(name);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (state.ownsConversationAction(action)) {
        _showError("Couldn't create your profile. Try again.");
      }
    }
  }

  Future<void> _pickBackup() async {
    if (!mounted || _busy || _step != _SetupStep.restore) return;
    final state = widget.state;
    final action = state.captureConversationAction(
      isCurrent: () =>
          mounted &&
          identical(widget.state, state) &&
          _step == _SetupStep.restore,
    );
    setState(() => _busy = true);
    String? picked;
    try {
      picked = await state.pickIdentityBackup();
    } catch (_) {
      picked = null;
    }
    if (!mounted || !state.ownsConversationAction(action)) {
      if (picked != null) unawaited(state.discardIdentityBackup(picked));
      return;
    }
    final previous = _backupPath;
    setState(() {
      _busy = false;
      if (picked != null) _backupPath = picked;
    });
    if (picked != null && previous != null && previous != picked) {
      unawaited(state.discardIdentityBackup(previous));
    }
  }

  void _releaseBackup() {
    final path = _backupPath;
    _backupPath = null;
    if (path != null) unawaited(widget.state.discardIdentityBackup(path));
  }

  Future<void> _restore({bool unprotected = false}) async {
    if (!mounted || _busy || _step != _SetupStep.restore) return;
    final backup = _backupPath;
    if (backup == null) return;
    final state = widget.state;
    final action = state.captureConversationAction(
      isCurrent: () =>
          mounted &&
          identical(widget.state, state) &&
          _step == _SetupStep.restore,
    );
    final password = unprotected ? '' : _passphrase.text;
    final expectedJamiId = JamiIdentity.fingerprint(_expectedFriendId.text);
    if (expectedJamiId == null) return;
    if (password.isEmpty && !unprotected) return;
    setState(() {
      _busy = true;
      _confirmingRestore = unprotected;
    });
    try {
      if (unprotected) {
        var warningHandled = false;
        void finishWarning(BuildContext dialogContext, bool result) {
          if (warningHandled ||
              !dialogContext.mounted ||
              ModalRoute.of(dialogContext)?.isCurrent != true) {
            return;
          }
          warningHandled = true;
          Navigator.of(dialogContext).pop(result);
        }

        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Gravity(child: const Text('Use an unprotected backup?')),
            content: Gravity(
              child: const Text(
                'Only continue if you trust where it came from. An unprotected backup can be opened by anyone who has the file.',
              ),
            ),
            actions: [
              Gravity(
                child: TextButton(
                  onPressed: () => finishWarning(dialogContext, false),
                  child: const Text('Cancel'),
                ),
              ),
              Gravity(
                child: FilledButton(
                  onPressed: () => finishWarning(dialogContext, true),
                  child: const Text('Restore'),
                ),
              ),
            ],
          ),
        );
        if (!mounted ||
            proceed != true ||
            !state.ownsConversationAction(action) ||
            _backupPath != backup ||
            ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
      }
      if (!state.ownsConversationAction(action)) return;
      setState(() {
        _confirmingRestore = false;
        // The attempt spends the staged copy whatever its outcome.
        _backupPath = null;
      });
      final error = await state.restoreIdentity(
        password,
        backupPath: backup,
        expectedJamiId: expectedJamiId,
      );
      if (error != null && state.ownsConversationAction(action)) {
        _showError('$error Choose the backup again to retry.');
      }
    } catch (_) {
      if (state.ownsConversationAction(action)) {
        _showError("Couldn't restore your profile. Try again.");
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirmingRestore = false;
        });
      }
    }
  }

  void _showError(String message) =>
      showNotice(message, duration: const Duration(seconds: 3));

  void _back() {
    if (_busy) return;
    setState(() {
      if (_step == _SetupStep.restore) _releaseBackup();
      _step = _step == _SetupStep.restore
          ? _SetupStep.existing
          : _SetupStep.choose;
      _showPassphrase = false;
    });
  }

  @override
  void dispose() {
    _releaseBackup();
    WidgetsBinding.instance.removeObserver(this);
    _threshold.dispose();
    _intro.dispose();
    _name.dispose();
    _passphrase.dispose();
    _expectedFriendId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    // Window/taskbar focus never starts the introduction; activation does.
    builder: (context, _) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _openOnInteraction(),
      child: PopScope<void>(
        canPop: _step == _SetupStep.choose && !_busy,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: _buildSetup(context),
      ),
    ),
  );

  Widget _buildSetup(BuildContext context) {
    final stepKey = ValueKey(_step);
    // Read above the Scaffold, which strips the inset from its body.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final theme = Theme.of(context);
    final phone =
        theme.platform == TargetPlatform.android ||
        theme.platform == TargetPlatform.iOS;
    return FilledButtonTheme(
      data: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.copyWith(
          minimumSize: phone
              ? const WidgetStatePropertyAll(Size(48, 56))
              : null,
          textStyle: phone
              ? WidgetStatePropertyAll(
                  theme.textTheme.labelLarge!.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        ),
      ),
      child: OnboardingSurface(
        child: Builder(
          builder: (context) => Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, viewport) => AnimatedSwitcher(
                  duration: SyblMotion.duration(
                    context,
                    const Duration(milliseconds: 420),
                  ),
                  layoutBuilder: (current, previous) =>
                      Stack(children: [...previous, ?current]),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation.drive(
                      CurveTween(
                        curve: const Interval(
                          .45,
                          1,
                          curve: Curves.easeInOutCubic,
                        ),
                      ),
                    ),
                    child: child,
                  ),
                  child: Stack(
                    key: stepKey,
                    children: [
                      _setupBody(context, viewport.biggest, keyboard),
                      if (_step != _SetupStep.choose)
                        Positioned(
                          top: 24,
                          left: 24,
                          right: 24,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 390),
                              child: SetupBackButton(
                                buttonKey: const ValueKey('onboarding-back'),
                                onPressed: _busy ? null : _back,
                              ),
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

  /// On a phone-shaped screen every step fills one full-height frame, so
  /// moving between steps never jumps: the welcome step pins its door near
  /// the top and its two paths in thumb reach at the bottom, and the other
  /// steps sit at the golden-ratio line inside the same frame. Wider windows
  /// use a bounded desktop composition; short phone screens and pending
  /// invitations keep an inline, scrollable layout. An open keyboard does not
  /// make the screen short: switching layouts under it would rebuild the
  /// focused field and close the keyboard again.
  double? _frameHeight(Size viewport, double keyboard) =>
      (viewport.width >= 600 || viewport.height + keyboard >= 640) &&
          widget.state.inviteContinuation.pending == null
      ? viewport.height - 48
      : null;

  // A minimum, not a fixed, height: large text or a tall step still scrolls.
  // Inside the scroll view's unbounded height the Align sizes to its child,
  // grown to the frame, and places the step at the golden-ratio line.
  Widget _framed(double? height, Widget step) => height == null
      ? step
      : ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Align(
            alignment: const Alignment(0, -.236),
            child: SizedBox(width: double.infinity, child: step),
          ),
        );

  Widget _setupBody(BuildContext context, Size viewport, double keyboard) {
    final frameHeight = _frameHeight(viewport, keyboard);
    final desktopWelcome =
        _step == _SetupStep.choose &&
        viewport.width >= 600 &&
        !widget.state.devicePairingPending &&
        widget.state.inviteContinuation.pending == null;
    final wideWelcome =
        desktopWelcome &&
        (viewport.width >= 900 || viewport.height < 400) &&
        MediaQuery.textScalerOf(context).scale(16) <= 20;
    final desktopColumnWidth =
        390 * (MediaQuery.textScalerOf(context).scale(16) / 16).clamp(1.0, 1.6);
    return SizedBox.fromSize(
      size: viewport,
      // Golden-ratio placement: the spare height splits about 38/62 above
      // and below the content, which reads as centred where dead centre
      // looks like it sags.
      child: Align(
        alignment: const Alignment(0, -.236),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: wideWelcome
                  ? 760
                  : (desktopWelcome ? desktopColumnWidth : 390),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.state.inviteContinuation.pending
                    case final record?) ...[
                  SyblStatusPanel(
                    key: const ValueKey('onboarding-pending-invite'),
                    kind: SyblStatusKind.empty,
                    title: record.invite.displayName.isEmpty
                        ? 'A friend invited you'
                        : 'Invitation from ${record.invite.displayName}',
                    message:
                        'Finish setup to choose whether to add this person. No friend request is sent until you choose Add.',
                    compact: true,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Gravity(
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => widget.state.inviteContinuation.discard(
                                record,
                              ),
                        child: const Text('Not now'),
                      ),
                    ),
                  ),
                  if (widget.state.inviteContinuation.persistenceFailed)
                    Gravity(
                      child: const Text(
                        'This invitation could not be saved for a restart. You can open the original link again.',
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                switch (_step) {
                  _SetupStep.choose
                      when viewport.width < 600 &&
                          frameHeight != null &&
                          !widget.state.devicePairingPending =>
                    _choiceStep(height: frameHeight),
                  _SetupStep.choose => _framed(
                    frameHeight,
                    _choiceStep(
                      desktopViewport: desktopWelcome ? viewport : null,
                      wide: wideWelcome,
                    ),
                  ),
                  _SetupStep.create => _framed(frameHeight, _createStep()),
                  _SetupStep.existing => _framed(frameHeight, _existingStep()),
                  _SetupStep.restore => _framed(frameHeight, _restoreStep()),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The welcome step. With [height] (phone-shaped screens) it fills that
  /// height: the door's centre holds at about a quarter of the screen while
  /// it settles, and the two paths sit at the bottom. Desktop windows retain
  /// a larger door, with separate brand/action columns when space allows.
  Widget _choiceStep({
    double? height,
    Size? desktopViewport,
    bool wide = false,
  }) => AnimatedBuilder(
    key: const ValueKey('onboarding-choice-step'),
    animation: Listenable.merge([_intro, _threshold]),
    builder: (context, _) {
      final progress = _intro.value;
      final opening = Curves.easeOutCubic.transform(
        ((progress * 1100 - 55) / 640).clamp(0.0, 1.0),
      );
      final illumination = (opening * 1.4).clamp(0.0, 1.0);
      final settling = Curves.easeInOutCubic.transform(
        ((progress - .64) / .36).clamp(0.0, 1.0),
      );
      final reveal = Curves.easeOutCubic.transform(
        ((progress - .72) / .28).clamp(0.0, 1.0),
      );
      final compact = MediaQuery.sizeOf(context).height < 640;
      final finalSize = desktopViewport != null
          ? (desktopViewport.height * .26).clamp(96.0, 160.0)
          : (compact ? 80.0 : 144.0);
      final doorSize = 196 + (finalSize - 196) * settling;
      final playfulDoor = PlayfulDoor(
        key: const ValueKey('onboarding-door-play'),
        size: doorSize,
        openness: opening * 1.4,
        illumination: illumination,
        thresholdPhase: _threshold.value,
        interactive: _intro.isCompleted,
      );
      final door = Center(
        child: _intro.isCompleted
            ? playfulDoor
            : Semantics(
                label: 'Open Doorlight',
                button: true,
                excludeSemantics: true,
                onTap: _openOnInteraction,
                child: InkWell(
                  key: const ValueKey('onboarding-open-door'),
                  autofocus:
                      Theme.of(context).platform == TargetPlatform.windows,
                  onTap: _openOnInteraction,
                  child: playfulDoor,
                ),
              ),
      );
      final message = Opacity(
        key: const ValueKey('onboarding-welcome-copy'),
        opacity: reveal,
        child: _choiceMessage(
          reveal,
          compact,
          desktop: desktopViewport != null,
        ),
      );
      if (height == null) {
        final paths = _choicePaths(reveal);
        if (wide) {
          return Row(
            key: const ValueKey('onboarding-wide-welcome'),
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [door, message],
                ),
              ),
              SizedBox(width: desktopViewport!.width >= 900 ? 80 : 32),
              Expanded(child: paths),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            door,
            ClipRect(
              child: Align(heightFactor: reveal, child: message),
            ),
            ClipRect(
              child: Align(
                heightFactor: reveal,
                child: Padding(
                  padding: EdgeInsets.only(
                    // The desktop title bar consumes part of a short window.
                    // Tighten this gap before reducing the door or typography.
                    top: desktopViewport != null
                        ? (desktopViewport.height - 456).clamp(32.0, 44.0)
                        : 28,
                  ),
                  child: paths,
                ),
              ),
            ),
          ],
        );
      }
      // The frame starts 24px below the safe area's top edge.
      final above = ((height + 48) * .26 - 24 - doorSize / 2).clamp(
        0.0,
        double.infinity,
      );
      // At least the frame's height: spare room opens between the message
      // and the paths; large text instead grows the step and scrolls.
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: above),
                door,
                message,
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 4),
              child: _choicePaths(reveal),
            ),
          ],
        ),
      );
    },
  );

  // Reveal whole groups together so an isolated rotating word never arrives first.
  Widget _rise(double reveal, Widget child) => IgnorePointer(
    ignoring: reveal < 1,
    child: ExcludeSemantics(
      excluding: reveal < 1,
      child: ExcludeFocus(
        excluding: reveal < 1,
        child: Opacity(opacity: reveal, child: child),
      ),
    ),
  );

  Widget _choiceMessage(double reveal, bool compact, {bool desktop = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Gravity(
              child: Text(
                'Doorlight',
                maxLines: 1,
                style: context.syblColors.display.copyWith(
                  fontSize: desktop ? (compact ? 40 : 48) : (compact ? 34 : 44),
                  fontWeight: FontWeight.w400,
                  height: 1.15,
                  color: context.syblColors.amber,
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 12 : 16),
          _SpinningInvitation(spinning: reveal >= 1),
        ],
      );

  Widget _choicePaths(double reveal) => _rise(
    reveal,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetupPath(
          key: const ValueKey('onboarding-create-choice'),
          icon: Icons.person_add_alt_outlined,
          label: 'I’m new to Doorlight',
          primary: true,
          onPressed: () => _go(_SetupStep.create),
        ),
        const SizedBox(height: 12),
        _SetupPath(
          key: const ValueKey('onboarding-existing-choice'),
          icon: Icons.devices_outlined,
          label: 'I already have Doorlight',
          onPressed: () => _go(_SetupStep.existing),
        ),
      ],
    ),
  );

  Widget _existingStep() => _StepFrame(
    key: const ValueKey('onboarding-existing-step'),
    title: 'Welcome back',
    child: Column(
      children: [
        SetupChoice(
          key: const ValueKey('onboarding-link-choice'),
          icon: Icons.qr_code_scanner_rounded,
          title: 'Link this device',
          onPressed: _busy ? null : _startNewLink,
        ),
        if (!widget.state.devicePairingPending) ...[
          const SizedBox(height: 12),
          SetupChoice(
            key: const ValueKey('onboarding-restore-choice'),
            icon: Icons.folder_open_rounded,
            title: 'Restore a backup',
            onPressed: () => _go(_SetupStep.restore),
          ),
        ],
      ],
    ),
  );

  Widget _createStep() => _StepFrame(
    key: const ValueKey('onboarding-create-step'),
    title: 'Create profile',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Gravity(
          child: TextField(
            key: const ValueKey('onboarding-name-field'),
            controller: _name,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _create(),
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'Your name',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Gravity(
          child: FilledButton(
            key: const ValueKey('onboarding-create-submit'),
            onPressed: _busy ? null : _create,
            child: _busy ? _spinner() : const Text('Create profile'),
          ),
        ),
      ],
    ),
  );

  Widget _restoreStep() {
    final backup = _backupPath;
    final picked = backup != null;
    return _StepFrame(
      key: const ValueKey('onboarding-restore-step'),
      title: 'Restore a backup',
      // The password controls fade in where the file button stood.
      child: AnimatedSwitcher(
        duration: SyblMotion.duration(
          context,
          const Duration(milliseconds: 280),
        ),
        switchInCurve: Curves.easeOutCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        child: Column(
          key: ValueKey(picked),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!picked)
              Gravity(
                child: FilledButton.icon(
                  key: const ValueKey('onboarding-restore-pick'),
                  onPressed: _busy ? null : _pickBackup,
                  icon: _busy
                      ? _spinner()
                      : const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text(_busy ? 'Opening…' : 'Choose backup file'),
                ),
              )
            else ...[
              _BackupFileChip(
                name: _fileName(backup),
                onChange: _busy ? null : _pickBackup,
              ),
              const SizedBox(height: 14),
              Gravity(
                child: TextField(
                  key: const ValueKey('onboarding-restore-friend-id'),
                  controller: _expectedFriendId,
                  enabled: !_busy,
                  maxLength: 45,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Your Friend ID',
                    helperText:
                        'Use the ID you saved or shared before this backup.',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Gravity(
                child: TextField(
                  key: const ValueKey('onboarding-passphrase-field'),
                  controller: _passphrase,
                  enabled: !_busy,
                  autofocus: SyblLayout.autofocusTextInput(context),
                  obscureText: !_showPassphrase,
                  maxLength: 1024,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _restore(),
                  decoration: InputDecoration(
                    labelText: 'Backup password',
                    counterText: '',
                    suffixIcon: IconButton(
                      tooltip: _showPassphrase
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: _busy
                          ? null
                          : () => setState(
                              () => _showPassphrase = !_showPassphrase,
                            ),
                      icon: Icon(
                        _showPassphrase
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Gravity(
                child: FilledButton(
                  key: const ValueKey('onboarding-restore-submit'),
                  onPressed:
                      _busy ||
                          _passphrase.text.isEmpty ||
                          JamiIdentity.fingerprint(_expectedFriendId.text) ==
                              null
                      ? null
                      : _restore,
                  child: _busy && !_confirmingRestore
                      ? _spinner()
                      : const Text('Restore'),
                ),
              ),
              const SizedBox(height: 4),
              Gravity(
                child: TextButton(
                  key: const ValueKey('onboarding-restore-unprotected'),
                  onPressed:
                      _busy ||
                          JamiIdentity.fingerprint(_expectedFriendId.text) ==
                              null
                      ? null
                      : () => _restore(unprotected: true),
                  child: const Text('This backup has no password'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fileName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty || parts.last.isEmpty ? 'Backup file' : parts.last;
  }

  Widget _spinner() => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// One word in the reel and the bundled face it wears.
typedef _ReelWord = ({
  String word,
  String family,
  FontStyle fontStyle,
  FontWeight? weight,
});

/// "Let’s get you chatting with your friends": the verb keeps turning through
/// the cosy things friends do together, each word in a face of its own.
class _SpinningInvitation extends StatelessWidget {
  const _SpinningInvitation({required this.spinning});

  final bool spinning;

  // The first word is the resting one; the reel loops endlessly after it.
  static const reel = <_ReelWord>[
    (
      word: 'chatting',
      family: 'InstrumentSerif',
      fontStyle: FontStyle.italic,
      weight: null,
    ),
    (
      word: 'yapping',
      family: 'BricolageGrotesque',
      fontStyle: FontStyle.normal,
      weight: FontWeight.w800,
    ),
    (
      word: 'gaming',
      family: 'Silkscreen',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'gossiping',
      family: 'PlayfairDisplay',
      fontStyle: FontStyle.italic,
      weight: FontWeight.w500,
    ),
    (
      word: 'laughing',
      family: 'LilitaOne',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'chilling',
      family: 'Fredoka',
      fontStyle: FontStyle.normal,
      weight: FontWeight.w500,
    ),
    (
      word: 'voice-chatting',
      family: 'Quicksand',
      fontStyle: FontStyle.normal,
      weight: FontWeight.w600,
    ),
    (
      word: 'memeing',
      family: 'Anton',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'vibing',
      family: 'Pacifico',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'rambling',
      family: 'Caveat',
      fontStyle: FontStyle.normal,
      weight: FontWeight.w600,
    ),
    (
      word: 'texting',
      family: 'VT323',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'scheming',
      family: 'SpaceMono',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'hanging out',
      family: 'GochiHand',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'venting',
      family: 'Rubik',
      fontStyle: FontStyle.normal,
      weight: FontWeight.w600,
    ),
    (
      word: 'calling',
      family: 'Righteous',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
    (
      word: 'plotting',
      family: 'CourierPrime',
      fontStyle: FontStyle.normal,
      weight: null,
    ),
  ];

  /// Each word is sized to about the width "chatting" takes in the headline's
  /// own face, within these bounds, so the line hardly changes width.
  static const _smallest = .7;
  static const _largest = 1.25;

  // Fitted sizes per text scale and headline size; measuring seventeen faces
  // on every intro frame would be wasted work.
  static final _fitted = <(double, double), List<double>>{};

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final compact = MediaQuery.sizeOf(context).height < 640;
    final style = colors.display.copyWith(
      fontSize: compact ? 22 : 26,
      fontWeight: FontWeight.w400,
      height: 1.2,
    );
    return Semantics(
      label: 'Let’s get you chatting with your friends',
      excludeSemantics: true,
      child: Column(
        key: const ValueKey('onboarding-invitation'),
        children: [
          LayoutBuilder(
            builder: (context, constraints) =>
                _line(context, constraints.maxWidth, style),
          ),
          // Script faces have deep descenders; give them room above line two.
          SizedBox(height: style.fontSize! * .22),
          Gravity(
            child: Text(
              'with your friends',
              textAlign: TextAlign.center,
              style: style,
            ),
          ),
        ],
      ),
    );
  }

  static TextStyle _face(_ReelWord entry, TextStyle base, double fontSize) =>
      TextStyle(
        color: base.color,
        fontFamily: entry.family,
        fontFamilyFallback: Warm.serifFallback,
        fontStyle: entry.fontStyle,
        fontWeight: entry.weight,
        // The variable faces take their weight from the axis itself.
        fontVariations: [
          if (entry.weight case final weight?)
            FontVariation.weight(weight.value.toDouble()),
        ],
        fontSize: fontSize,
        height: base.height,
      );

  /// "Let’s get you" never moves while the word spins: the line is centred
  /// on the resting word, longer words grow to the right and shrink if they
  /// would pass the edge. At text sizes where even the resting word cannot
  /// fit beside it, the word takes its own line.
  Widget _line(BuildContext context, double maxWidth, TextStyle style) {
    const prefix = 'Let’s get you';
    final scaler = MediaQuery.textScalerOf(context);
    // Keep a clear word space even beside the heavier reel faces.
    final gap = scaler.scale(style.fontSize! * .4);
    final direction = Directionality.of(context);
    Size measure(String text, TextStyle style) {
      final painter = TextPainter(
        // Text merges its style with the inherited typography. Measuring the
        // same effective style keeps the prefix's actual edge out of the reel.
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    }

    final base = style.fontSize!;
    final lead = measure(prefix, style);
    final resting = measure(reel.first.word, style).width;
    final sizes = _fitted.putIfAbsent((scaler.scale(100), base), () {
      return [
        for (final entry in reel)
          base *
              (resting / measure(entry.word, _face(entry, style, base)).width)
                  .clamp(_smallest, _largest),
      ];
    });
    final words = [for (final entry in reel) entry.word];
    final styles = [
      for (final (i, entry) in reel.indexed) _face(entry, style, sizes[i]),
    ];
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    final wraps = lead.width + gap + resting > maxWidth;
    final start = (maxWidth - (lead.width + gap + resting)) / 2;
    final slot = maxWidth - start - lead.width - gap;
    final word = Gravity(
      child: SpinningWord(
        words: words,
        styles: styles,
        strutStyle: strut,
        running: spinning,
        interactive: true,
        alignment: wraps
            ? Alignment.center
            : AlignmentDirectional.centerStart.resolve(direction),
        maxWidth: wraps ? maxWidth : slot,
        style: style,
      ),
    );
    if (wraps) {
      return Column(
        children: [
          Gravity(
            child: Text(prefix, textAlign: TextAlign.center, style: style),
          ),
          word,
        ],
      );
    }
    return SizedBox(
      width: maxWidth,
      height: lead.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PositionedDirectional(
            start: start,
            top: 0,
            child: Gravity(child: Text(prefix, style: style)),
          ),
          PositionedDirectional(
            start: start + lead.width + gap,
            top: 0,
            bottom: 0,
            child: word,
          ),
        ],
      ),
    );
  }
}

class _BackupFileChip extends StatelessWidget {
  const _BackupFileChip({required this.name, required this.onChange});

  final String name;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('onboarding-restore-file'),
    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
    decoration: BoxDecoration(
      color: context.syblColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.syblColors.lineStrong),
    ),
    child: Row(
      children: [
        Gravity(
          child: Icon(
            Icons.insert_drive_file_outlined,
            color: context.syblColors.amber,
            size: 20,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Gravity(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        Gravity(
          child: TextButton(onPressed: onChange, child: const Text('Change')),
        ),
      ],
    ),
  );
}

class _StepFrame extends StatelessWidget {
  const _StepFrame({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Gravity(
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: context.syblColors.display.copyWith(fontSize: 22, height: 1.2),
        ),
      ),
      const SizedBox(height: 26),
      child,
    ],
  );
}

/// One of the two welcome paths: a single line with a fixed icon box, so both
/// labels start at the same x, and a chevron that says it leads somewhere.
/// The primary path is filled amber.
class _SetupPath extends StatelessWidget {
  const _SetupPath({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final phone =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final ink = primary
        ? colors.onAccent
        : (colors.neutralButtonForeground ?? colors.ink);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(colors.buttonRadius ?? 16),
      side: primary
          ? BorderSide.none
          : BorderSide(color: colors.neutralButtonBorder ?? colors.lineStrong),
    );
    return Gravity(
      child: Material(
        color: primary
            ? colors.accentFill
            : (colors.neutralButtonFill ?? Colors.transparent),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: shape,
          hoverColor: primary ? null : colors.neutralButtonHover,
          highlightColor: primary ? null : colors.neutralButtonPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: phone ? 64 : 58),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 16, 10),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 24,
                    child: Icon(
                      icon,
                      size: 22,
                      color: primary
                          ? colors.onAccent
                          : (colors.neutralButtonForeground ?? colors.amber),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: ink,
                        fontSize: phone ? 17 : 15,
                        fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: primary
                        ? colors.onAccent
                        : (colors.neutralButtonForeground ?? colors.muted),
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
