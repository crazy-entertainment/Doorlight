import '../ui/microphone_press_target.dart';
import '../ui/microphone_waveform.dart';
import '../ui/gravity.dart';
import '../ui/hologram_anchor.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../state/annotation.dart';
import '../state/outgoing_video.dart';
import '../state/orientation_policy.dart';
import '../state/remote_control.dart';
import '../state/video_viewport.dart';
import '../theme.dart';
import '../ui/remote_control_surface.dart';
import '../ui/screen_share_action.dart';
import '../ui/audio_output_action.dart';
import '../ui/sybl_ui.dart';
import '../ui/window_presentation.dart';

class InCallScreen extends StatelessWidget {
  final AppState state;
  final VoidCallback? onMinimize;
  const InCallScreen({super.key, required this.state, this.onMinimize});

  Future<void> _toggleShare(BuildContext context, CallSession c) async {
    await toggleScreenShareWithPicker(context, state, c);
  }

  // The status word, no dots — the animated dots are appended by [_callStatus] while connecting.
  String _statusBase(CallSession c) {
    if (c.connected) return 'Connected';
    return c.dir == CallDir.outgoing ? 'Calling' : 'Connecting';
  }

  /// Status line: the base word, plus cute loading dots that fill in (only the dots move) while connecting.
  Widget _callStatus(
    BuildContext context,
    CallSession c, {
    required double fontSize,
  }) {
    final style = TextStyle(
      color: context.syblColors.muted,
      fontSize: fontSize,
    );
    final base = _statusBase(c);
    if (c.connected) return Gravity(child: Text(base, style: style));
    return Gravity(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(base, style: style),
          _AnimatedDots(style: style),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = state.call;
    if (c == null) return const SizedBox.shrink();
    if (WindowPresentationScope.isCompact(context) && !c.hasVideo) {
      return Column(
        children: [
          CompactHeader(
            title: state.peerDisplayName(c.peerId),
            onBack: onMinimize,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 4),
              child: Column(
                children: [
                  _callStatus(context, c, fontSize: 11),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 12,
                    children: [
                      _MicControl(
                        state: state,
                        call: c,
                        size: 34,
                        iconSize: 18,
                        labelSize: 0,
                      ),
                      if (state.outputPickerAvailable)
                        _AudioRouteControl(
                          state: state,
                          call: c,
                          size: 34,
                          iconSize: 18,
                          labelSize: 0,
                        ),
                      _CircleToggle(
                        active: false,
                        icon: Icons.videocam_outlined,
                        label: 'Camera',
                        onTap: () async {
                          if (!identical(state.call, c)) return;
                          await WindowPresentationScope.maybeOf(
                            context,
                          )?.setCompact(false);
                          if (!context.mounted || !identical(state.call, c)) {
                            return;
                          }
                          await state.toggleCamera();
                        },
                        size: 34,
                        iconSize: 18,
                        labelSize: 0,
                      ),
                      _HangUpButton(
                        onTap: state.hangUp,
                        size: 34,
                        iconSize: 18,
                        label: 'Leave',
                        labelSize: 0,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  MicrophoneWaveform(
                    level: state.voiceMeter,
                    muted: c.micMuted,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final content = !c.hasVideo
        ? _audioLayout(context, c)
        : ListenableBuilder(
            listenable: state.annotation,
            builder: (_, _) => _videoLayout(context, c),
          );
    return _CallOrientationScope(
      policy: c.peerVideoKind == OutgoingVideoKind.screen || c.sharingScreen
          ? SyblOrientationPolicy.screenContent
          : SyblOrientationPolicy.portrait,
      child: Stack(
        children: [
          Positioned.fill(child: content),
          if (onMinimize != null)
            Positioned(
              left: 8,
              top: 8,
              child: SafeArea(
                child: Gravity(
                  child: HologramAnchor(
                    state: state,
                    child: IconButton(
                      key: const ValueKey('minimize-call-button'),
                      tooltip: 'Back to your friends',
                      onPressed: onMinimize,
                      style: IconButton.styleFrom(
                        backgroundColor: context.syblColors.accentFill,
                        foregroundColor: context.syblColors.foregroundFor(
                          context.syblColors.accentFill,
                          preferred: Colors.black,
                        ),
                      ),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- audio (M1) layout: avatar/name just above centre, controls grouped at the bottom ----

  Widget _audioLayout(BuildContext context, CallSession c) {
    final connected = c.connected;
    return Scaffold(
      backgroundColor: context.syblColors.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const padding = EdgeInsets.fromLTRB(20, 28, 20, 32);
            return SingleChildScrollView(
              padding: padding,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - padding.vertical,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      // Identity stays calm and centered, but participates in
                      // layout so large accessibility text can scroll instead of
                      // colliding with the controls.
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Stack(
                                alignment: Alignment.center,
                                children: [
                                  if (!connected)
                                    SizedBox(
                                      width: 128,
                                      height: 128,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation(
                                          context.syblColors.amber.withValues(
                                            alpha: 0.45,
                                          ),
                                        ),
                                      ),
                                    ),
                                  SyblAvatar(
                                    label: state.peerDisplayName(c.peerId),
                                    imageBase64:
                                        state.friends[c.peerId]?.avatarBase64,
                                    size: 112,
                                    color: context.syblColors.surfaceHi,
                                    statusColor: connected
                                        ? context.syblColors.online
                                        : null,
                                    statusLabel: connected ? 'connected' : null,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: Gravity(
                                  child: Text(
                                    state.peerDisplayName(c.peerId),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: context.syblColors.display.copyWith(
                                      fontSize: 20,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              _callStatus(context, c, fontSize: 14),
                              if (!connected)
                                const _ConnectingHint(fontSize: 12),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (connected)
                            _primaryCallControls(context, c, video: false),
                          if (!connected)
                            _HangUpButton(
                              key: const ValueKey('call-hang-up-control'),
                              onTap: state.hangUp,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- video layout: selected Mine/Theirs target fills, other live direction in PiP ----

  Widget _videoLayout(BuildContext context, CallSession c) {
    final mineAvailable = c.outgoingVideo.active;
    final theirsAvailable = c.peerVideo || c.remoteActive;
    final requestedMine =
        state.annotation.target == AnnotationTarget.mine && mineAvailable;
    final mainOwner =
        state.callInteractionMode == CallInteractionMode.control &&
            theirsAvailable
        ? AnnotationTarget.theirs
        : (requestedMine || !theirsAvailable
              ? AnnotationTarget.mine
              : AnnotationTarget.theirs);
    final pipOwner = mineAvailable && theirsAvailable
        ? (mainOwner == AnnotationTarget.mine
              ? AnnotationTarget.theirs
              : AnnotationTarget.mine)
        : null;
    final desktopController =
        state.remoteControl.isControlling &&
        Theme.of(context).platform != TargetPlatform.android &&
        Theme.of(context).platform != TargetPlatform.iOS;
    final mainSize = _sourceSize(c, mainOwner);
    final mainVideo = _videoTile(c, mainOwner, mainSize);
    return Scaffold(
      backgroundColor: context.syblColors.bg,
      body: Stack(
        children: [
          // The selected drawing/presentation target fills the screen.
          Positioned.fill(
            right: state.remoteControl.isControlling
                ? RemoteControlHud.controllerGutterWidth
                : 0,
            child:
                state.callInteractionMode == CallInteractionMode.control &&
                    mainOwner == AnnotationTarget.theirs
                ? RemoteControlSurface(
                    controller: state.remoteControl,
                    sourceSize: mainSize,
                    child: mainVideo,
                  )
                : mainVideo,
          ),

          // Annotation overlay (M8) — draws over the video; both sides' "point here" marks render here. It only
          // CAPTURES pointers while draw mode is on (IgnorePointer otherwise, so the call controls stay tappable);
          // it always PAINTS, so a mark the peer drew shows even when you're not drawing yourself.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: state.callInteractionMode != CallInteractionMode.draw,
              child: _AnnotationOverlay(
                ann: state.annotation,
                sourceSize: mainSize,
              ),
            ),
          ),

          // The other live direction stays visible and is tappable to promote it to the drawing/main target.
          if (pipOwner != null)
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: Semantics(
                  button: true,
                  label: pipOwner == AnnotationTarget.mine
                      ? 'Show my video'
                      : "Show friend's video",
                  child: GestureDetector(
                    onTap: () => state.selectAnnotationTarget(pipOwner),
                    child: Container(
                      width: 104,
                      height: 156,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: context.syblColors.amber.withValues(
                            alpha: 0.6,
                          ),
                          width: 1.5,
                        ),
                        color: context.syblColors.surface,
                      ),
                      child: _videoTile(
                        c,
                        pipOwner,
                        _sourceSize(c, pipOwner),
                        compact: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Status (peer id + state) top-left.
          Positioned(
            top: 12,
            left: onMinimize == null ? 16 : 68,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Gravity(
                    child: Text(
                      state.peerDisplayName(c.peerId),
                      style: context.syblColors.display.copyWith(fontSize: 16),
                    ),
                  ),
                  _callStatus(context, c, fontSize: 12),
                  if (!c.connected) const _ConnectingHint(fontSize: 11),
                ],
              ),
            ),
          ),

          // Annotation tools (M8) — a calm left rail: a draw toggle, and while drawing, the colour swatches + a
          // "clear mine". Only on a live call (the side channel needs CURRENT). Above the overlay so it stays tappable.
          if (c.connected && state.annotation.available)
            Positioned(
              left: 10,
              top: 84,
              child: SafeArea(child: _AnnotateRail(state: state)),
            ),

          if (c.connected)
            Positioned(
              top: 12,
              right: pipOwner == null ? 12 : 128,
              child: SafeArea(
                child: Wrap(
                  spacing: 6,
                  children: [
                    if (c.cameraOn)
                      Gravity(
                        child: ActionChip(
                          avatar: const Icon(Icons.cameraswitch_outlined),
                          label: const Text('Flip'),
                          onPressed: c.cameraChanging
                              ? null
                              : state.switchCamera,
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // Stable primary controls; mic mode expands from the mic chevron.
          if (desktopController)
            Positioned(
              top: 56,
              right: 0,
              bottom: 0,
              width: RemoteControlHud.controllerGutterWidth,
              child: SafeArea(
                child: Center(
                  child: Padding(
                    key: const ValueKey('call-control-row'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _primaryCallControls(
                      context,
                      c,
                      video: true,
                      axis: Axis.vertical,
                    ),
                  ),
                ),
              ),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  key: const ValueKey('call-control-row'),
                  padding: const EdgeInsets.only(
                    bottom: 28,
                    top: 16,
                    left: 20,
                    right: 20,
                  ),
                  child: _primaryCallControls(context, c, video: true),
                ),
              ),
            ),
          Positioned.fill(child: RemoteControlHud(state: state)),
        ],
      ),
    );
  }

  Widget _primaryCallControls(
    BuildContext context,
    CallSession c, {
    required bool video,
    Axis axis = Axis.horizontal,
  }) {
    final compact = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final twoRows = compact && axis == Axis.horizontal;
    final size = twoRows
        ? 48.0
        : compact
        ? 54.0
        : 64.0;
    final primarySize = twoRows ? 88.0 : size;
    final iconSize = compact ? 24.0 : 28.0;
    final primaryIconSize = twoRows ? 36.0 : iconSize;
    // Mobile call controls use familiar icons with tooltips/semantics. Keeping
    // the label slot empty prevents text scaling and unequal word widths from
    // shifting otherwise identical circles off their shared baseline.
    final labelSize = compact ? 0.0 : 12.0;
    Widget slot(Widget child) => axis == Axis.horizontal
        ? Expanded(child: Center(child: child))
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: child,
          );
    final controls = <Widget>[
      _MicControl(
        key: const ValueKey('call-mic-control'),
        state: state,
        call: c,
        size: primarySize,
        iconSize: primaryIconSize,
        labelSize: labelSize,
      ),
      _CircleToggle(
        key: const ValueKey('call-camera-control'),
        active: video && c.cameraOn,
        icon: video
            ? (c.cameraOn ? Icons.videocam : Icons.videocam_off)
            : Icons.videocam_outlined,
        label: c.cameraChanging
            ? 'Wait'
            : video
            ? (c.cameraOn ? 'On' : 'Off')
            : 'Camera',
        onTap: state.toggleCamera,
        size: size,
        iconSize: iconSize,
        labelSize: labelSize,
      ),
      if (state.speakerControlAvailable || state.outputPickerAvailable)
        _AudioRouteControl(
          state: state,
          call: c,
          size: size,
          iconSize: iconSize,
          labelSize: labelSize,
        ),
      _CircleToggle(
        key: const ValueKey('call-share-control'),
        active: video && c.sharingScreen,
        icon: video && c.sharingScreen
            ? Icons.stop_screen_share
            : Icons.screen_share,
        label: c.sourceChanging
            ? 'Wait'
            : video && c.sharingScreen
            ? 'Stop'
            : 'Share',
        onTap: c.sourceChanging ? null : () => _toggleShare(context, c),
        size: size,
        iconSize: iconSize,
        labelSize: labelSize,
      ),
      _HangUpButton(
        key: const ValueKey('call-hang-up-control'),
        onTap: state.hangUp,
        size: primarySize,
        iconSize: primaryIconSize,
        label: 'Leave',
        labelSize: labelSize,
      ),
    ];
    if (twoRows) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 24,
            children: controls.sublist(1, controls.length - 1),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 40,
            children: [controls.first, controls.last],
          ),
        ],
      );
    }
    return Flex(
      direction: axis,
      mainAxisSize: axis == Axis.horizontal
          ? MainAxisSize.max
          : MainAxisSize.min,
      children: controls.map(slot).toList(),
    );
  }

  Size _sourceSize(CallSession c, AnnotationTarget owner) {
    if (owner == AnnotationTarget.mine) {
      return c.outgoingVideo.geometry ??
          (c.selfWidth > 0 && c.selfHeight > 0
              ? Size(c.selfWidth.toDouble(), c.selfHeight.toDouble())
              : const Size(1, 1));
    }
    return c.remoteWidth > 0 && c.remoteHeight > 0
        ? Size(c.remoteWidth.toDouble(), c.remoteHeight.toDouble())
        : const Size(1, 1);
  }

  Widget _videoTile(
    CallSession c,
    AnnotationTarget owner,
    Size sourceSize, {
    bool compact = false,
  }) {
    if (owner == AnnotationTarget.mine) {
      if (c.selfActive && c.selfTextureId != null) {
        Widget texture = _ContainedTexture(
          textureId: c.selfTextureId!,
          sourceSize: sourceSize,
        );
        if (c.outgoingVideo.isCamera && c.selfFront) {
          texture = Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0),
            child: texture,
          );
        }
        return texture;
      }
      if (c.sharingScreen) {
        return _VideoPlaceholder(
          label: compact ? 'My screen' : 'Starting your screen…',
          icon: Icons.screen_share,
          compact: compact,
        );
      }
      return _VideoPlaceholder(
        label: c.cameraOn
            ? (compact ? 'My camera' : 'starting your camera…')
            : 'camera off',
        icon: c.cameraOn ? Icons.hourglass_empty : Icons.videocam_off,
        compact: compact,
      );
    }

    if (c.remoteActive && c.remoteTextureId != null) {
      return _ContainedTexture(
        textureId: c.remoteTextureId!,
        sourceSize: sourceSize,
      );
    }
    final peerScreen = c.peerVideoKind == OutgoingVideoKind.screen;
    return _VideoPlaceholder(
      label: c.peerVideo
          ? (compact
                ? (peerScreen ? 'Their screen' : 'Their camera')
                : (peerScreen
                      ? 'connecting their screen…'
                      : 'connecting their camera…'))
          : 'camera off',
      icon: c.peerVideo
          ? (peerScreen ? Icons.screen_share : Icons.hourglass_empty)
          : Icons.videocam_off,
      compact: compact,
    );
  }
}

class _CallOrientationScope extends StatefulWidget {
  const _CallOrientationScope({required this.policy, required this.child});

  final SyblOrientationPolicy policy;
  final Widget child;

  @override
  State<_CallOrientationScope> createState() => _CallOrientationScopeState();
}

class _CallOrientationScopeState extends State<_CallOrientationScope> {
  late final PreferredOrientationCoordinator _coordinator;

  bool get _touchPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _coordinator = PreferredOrientationCoordinator();
    _apply(widget.policy);
  }

  @override
  void didUpdateWidget(covariant _CallOrientationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.policy != widget.policy) _apply(widget.policy);
  }

  void _apply(SyblOrientationPolicy policy) {
    if (_touchPlatform) unawaited(_coordinator.setPolicy(policy));
  }

  @override
  void dispose() {
    _apply(SyblOrientationPolicy.portrait);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A small loading animation: a fixed-width slot that fills 1→2→3 dots, so the word it follows never shifts.
class _AnimatedDots extends StatefulWidget {
  final TextStyle style;
  const _AnimatedDots({required this.style});
  @override
  State<_AnimatedDots> createState() => _AnimatedDotsState();
}

class _AnimatedDotsState extends State<_AnimatedDots> {
  static const _max = 3;
  int _n = 1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 450), (_) {
      if (!mounted) return;
      setState(() => _n = _n % _max + 1); // 1 → 2 → 3 → 1
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The invisible ' ...' reserves the full width; only the visible dots change → the word stays put.
    return Stack(
      children: [
        Opacity(opacity: 0, child: Text(' ${'.' * _max}', style: widget.style)),
        Text(' ${'.' * _n}', style: widget.style),
      ],
    );
  }
}

/// A calm, escalating reassurance shown only while a call is still connecting — addresses the cold-start lag
/// (the first call to a hard-to-reach peer can take ~15-25s) without the reverted auto-redial. Silent for the
/// first 8s (a normal ring needs no excuse), then gently explains the wait.
class _ConnectingHint extends StatefulWidget {
  final double fontSize;
  const _ConnectingHint({required this.fontSize});
  @override
  State<_ConnectingHint> createState() => _ConnectingHintState();
}

class _ConnectingHintState extends State<_ConnectingHint> {
  int _secs = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secs++);
      if (_secs >= 18) {
        _t?.cancel(); // copy stops changing past 18s — no point rebuilding every second after
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? hint;
    if (_secs >= 18) {
      hint = 'the first call can take a moment…';
    } else if (_secs >= 8) {
      hint = 'still reaching them…';
    }
    if (hint == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Gravity(
        child: Text(
          hint,
          style: TextStyle(
            color: context.syblColors.muted,
            fontSize: widget.fontSize,
          ),
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool compact;
  const _VideoPlaceholder({
    required this.label,
    required this.icon,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.syblColors.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Gravity(
              child: Icon(
                icon,
                color: context.syblColors.muted,
                size: compact ? 28 : 48,
              ),
            ),
            SizedBox(height: compact ? 6 : 12),
            Gravity(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.syblColors.muted,
                  fontSize: compact ? 10 : 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HangUpButton extends StatelessWidget {
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final String? label;
  final double labelSize;
  const _HangUpButton({
    super.key,
    required this.onTap,
    this.size = 72,
    this.iconSize = 32,
    this.label,
    this.labelSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    final button = Gravity(
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          tooltip: 'End call',
          onPressed: onTap,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            backgroundColor: context.syblColors.dangerFill,
            foregroundColor: context.syblColors.foregroundFor(
              context.syblColors.dangerFill,
            ),
            shape: const CircleBorder(),
          ),
          icon: Icon(Icons.call_end, size: iconSize),
        ),
      ),
    );
    if (label == null) return button;
    // A labelled hang-up sits on the same baseline as the other circles.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 8),
        _ControlLabel(label: label!, maxWidth: size, fontSize: labelSize),
      ],
    );
  }
}

/// Speaker/earpiece toggle on the phone; audio output device picker on the PC.
/// Bluetooth routing is a future refinement.
class _AudioRouteControl extends StatelessWidget {
  const _AudioRouteControl({
    required this.state,
    required this.call,
    required this.size,
    required this.iconSize,
    required this.labelSize,
  });

  final AppState state;
  final CallSession call;
  final double size;
  final double iconSize;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    if (state.speakerControlAvailable) {
      return _CircleToggle(
        key: const ValueKey('call-speaker-control'),
        active: call.speakerOn,
        icon: audioOutputIcon(state, speakerOn: call.speakerOn),
        label: call.speakerOn ? 'Speaker' : 'Earpiece',
        onTap: state.toggleSpeaker,
        activeColor: context.syblColors.surfaceHi,
        size: size,
        iconSize: iconSize,
        labelSize: labelSize,
      );
    }
    return _CircleToggle(
      key: const ValueKey('call-output-control'),
      active: false,
      icon: Icons.volume_up_rounded,
      label: 'Output',
      onTap: () => unawaited(showAudioOutputPicker(context, state)),
      size: size,
      iconSize: iconSize,
      labelSize: labelSize,
    );
  }
}

class _MicControl extends StatelessWidget {
  final AppState state;
  final CallSession call;
  final double size;
  final double iconSize;
  final double labelSize;
  const _MicControl({
    super.key,
    required this.state,
    required this.call,
    required this.size,
    required this.iconSize,
    required this.labelSize,
  });

  @override
  Widget build(BuildContext context) {
    final pushToTalk = call.micMode == MicrophoneMode.pushToTalk;
    final talking = !call.micMuted;
    final micLabel = pushToTalk
        ? (talking ? 'Talking' : 'Hold')
        : (call.micMuted ? 'Muted' : 'Mic on');
    final background = pushToTalk
        ? (talking
              ? context.syblColors.onlineFill
              : context.syblColors.surfaceHi)
        : (call.micMuted
              ? context.syblColors.surface
              : context.syblColors.surfaceHi);
    final foreground = pushToTalk
        ? (talking
              ? context.syblColors.foregroundFor(background)
              : context.syblColors.muted)
        : (call.micMuted ? context.syblColors.muted : context.syblColors.ink);
    final circleControl = MicrophonePressTarget(
      key: ValueKey(call.callId),
      pushToTalk: pushToTalk,
      enabled: call.connected,
      onHold: (down) {
        if (state.call?.callId == call.callId) state.pttHold(down);
      },
      onToggle: state.toggleMute,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: background),
        child: Icon(
          !pushToTalk && call.micMuted ? Icons.mic_off : Icons.mic,
          color: foreground,
          size: iconSize,
        ),
      ),
    );
    final circle = Gravity(
      child: Semantics(
        button: true,
        label: micLabel,
        child: Tooltip(message: micLabel, child: circleControl),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            circle,
            // The little chevron tells people the mic button expands into
            // mic-mode choices instead of hiding them in a separate pill.
            Positioned(
              right: -4,
              bottom: -4,
              child: Gravity(
                key: const ValueKey('mic-mode-chevron'),
                child: PopupMenuButton<MicrophoneMode>(
                  // Retire an open menu when its displayed session is replaced.
                  key: ObjectKey(call),
                  tooltip: 'Microphone mode',
                  initialValue: pushToTalk
                      ? MicrophoneMode.pushToTalk
                      : MicrophoneMode.open,
                  onSelected: (mode) {
                    if (!identical(state.call, call)) return;
                    state.setMicMode(mode);
                  },
                  color: context.syblColors.surfaceTop,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: MicrophoneMode.open,
                      child: Text('Open mic'),
                    ),
                    PopupMenuItem(
                      value: MicrophoneMode.pushToTalk,
                      child: Text('Push to talk'),
                    ),
                  ],
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.syblColors.surfaceTop,
                      border: Border.all(color: context.syblColors.lineStrong),
                    ),
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: context.syblColors.ink,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ControlLabel(label: micLabel, maxWidth: size, fontSize: labelSize),
      ],
    );
  }
}

/// The annotation draw surface (M8): captures pointer strokes (when draw mode is on) and paints both sides' marks
/// over the video, in normalized coords so a "point here" lands at the same spot on each device's surface.
class _ContainedTexture extends StatelessWidget {
  final int textureId;
  final Size sourceSize;
  const _ContainedTexture({required this.textureId, required this.sourceSize});

  @override
  Widget build(BuildContext context) {
    if (sourceSize.width <= 0 || sourceSize.height <= 0) {
      return Texture(textureId: textureId);
    }
    return Center(
      child: AspectRatio(
        aspectRatio: sourceSize.aspectRatio,
        child: Texture(textureId: textureId),
      ),
    );
  }
}

class _AnnotationOverlay extends StatelessWidget {
  final AnnotationController ann;
  final Size sourceSize;
  const _AnnotationOverlay({required this.ann, required this.sourceSize});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final source = sourceSize.width > 0 && sourceSize.height > 0
            ? sourceSize
            : size;
        final viewport = VideoViewport(viewport: size, source: source);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            final normalized = viewport.normalize(e.localPosition);
            if (normalized != null) ann.begin(normalized);
          },
          onPointerMove: (e) {
            final normalized = viewport.normalize(e.localPosition);
            if (normalized != null) ann.extend(normalized);
          },
          onPointerUp: (_) => ann.end(),
          onPointerCancel: (_) => ann.end(),
          child: CustomPaint(
            size: Size.infinite,
            painter: _StrokePainter(ann, source),
          ),
        );
      },
    );
  }
}

/// Paints every stroke (peer first, then ours, so my fresh marks sit on top) — normalized points scaled to the
/// canvas. A single-point stroke renders as a dot ("tap here"). Repaints on the controller tick, NOT a tree rebuild.
class _StrokePainter extends CustomPainter {
  final AnnotationController ann;
  final Size sourceSize;
  _StrokePainter(this.ann, this.sourceSize)
    : super(repaint: Listenable.merge([ann, ann.repaint]));

  @override
  void paint(Canvas canvas, Size size) {
    final viewport = VideoViewport(viewport: size, source: sourceSize);
    for (final s in [...ann.peerStrokes, ...ann.mineStrokes]) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = Color(s.color)
        ..strokeWidth = s.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      Offset at(Offset n) => viewport.denormalize(n);
      if (s.points.length == 1) {
        canvas.drawCircle(
          at(s.points.first),
          s.width,
          paint..style = PaintingStyle.fill,
        );
        continue;
      }
      final path = Path()..moveTo(at(s.points.first).dx, at(s.points.first).dy);
      for (final p in s.points.skip(1)) {
        final o = at(p);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.sourceSize != sourceSize || old.ann != ann;
}

/// Pen-first annotation controls. Opening the pen reveals colours to its right.
/// The visible main/thumbnail video selects the surface, so this rail does not
/// duplicate source selection.
class _AnnotateRail extends StatelessWidget {
  final AppState state;
  const _AnnotateRail({required this.state});

  @override
  Widget build(BuildContext context) {
    final ann = state.annotation;
    return ListenableBuilder(
      listenable: ann,
      builder: (context, _) {
        final control = state.remoteControl;
        final peerScreenActive = state.peerSharedScreenReady;
        final requesting = control.phase == RemoteControlPhase.requesting;
        final targetPlatform = state.remoteControlTargetPlatform;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _railButton(
                  key: const ValueKey('annotation-draw-toggle'),
                  context: context,
                  icon: Icons.edit_outlined,
                  active: ann.enabled,
                  tooltip: ann.ready ? 'Draw' : 'Syncing video target',
                  onTap: () => state.setAnnotationEnabled(!ann.enabled),
                ),
                if (ann.enabled) ...[
                  const SizedBox(width: 6),
                  for (final color in AnnotationController.palette)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: _Swatch(
                        color: Color(color),
                        selected: ann.color == color,
                        onTap: () => ann.setColor(color),
                      ),
                    ),
                  _railButton(
                    context: context,
                    icon: Icons.cleaning_services_outlined,
                    active: false,
                    tooltip: 'Clear my marks',
                    onTap: ann.clearMine,
                  ),
                ],
              ],
            ),
            if (!control.isControlling && (peerScreenActive || requesting)) ...[
              const SizedBox(height: 6),
              // Labeled on purpose: a bare rail icon was undiscoverable — the
              // founder could not find how to actually take control.
              _railPill(
                key: Key(
                  requesting
                      ? 'remote-control-requesting'
                      : control.canRequest
                      ? 'remote-control-request'
                      : 'remote-control-preparing',
                ),
                context: context,
                icon: switch (targetPlatform) {
                  'android' => Icons.touch_app_outlined,
                  'windows' => Icons.near_me_outlined,
                  _ => Icons.ads_click_outlined,
                },
                label: requesting ? 'Asking…' : 'Ask to help',
                active: requesting,
                tooltip: requesting
                    ? 'Cancel control request'
                    : control.canRequest
                    ? switch (targetPlatform) {
                        'android' =>
                          'Request temporary control of their phone: taps, scrolling, typing, Back, Home and Recents.',
                        'windows' =>
                          'Request temporary control of their mouse and keyboard.',
                        _ =>
                          'Request temporary control of their shared device.',
                      }
                    : 'Syncing shared screen',
                onTap: requesting
                    ? () => unawaited(state.stopRemoteControl())
                    : control.canRequest
                    ? () => unawaited(state.requestRemoteControl())
                    : null,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _railPill({
    Key? key,
    required BuildContext context,
    required IconData icon,
    required String label,
    required bool active,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Gravity(
      child: Tooltip(
        key: key,
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.55 : 1,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                color: active
                    ? context.syblColors.accentFill
                    : context.syblColors.surface.withValues(alpha: 0.85),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    color: active
                        ? context.syblColors.onAccent
                        : context.syblColors.ink,
                    size: 20,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      color: active
                          ? context.syblColors.onAccent
                          : context.syblColors.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
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

  Widget _railButton({
    Key? key,
    required BuildContext context,
    required IconData icon,
    required bool active,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Gravity(
      child: Tooltip(
        key: key,
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.55 : 1,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? context.syblColors.accentFill
                    : context.syblColors.surface.withValues(alpha: 0.85),
              ),
              child: Icon(
                icon,
                color: active
                    ? context.syblColors.onAccent
                    : context.syblColors.ink,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Gravity(
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Drawing color',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(
                    color: selected
                        ? context.syblColors.ink
                        : Colors.transparent,
                    width: 2.5,
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

class _CircleToggle extends StatelessWidget {
  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? activeColor;
  final double size;
  final double iconSize;
  final double labelSize;
  const _CircleToggle({
    super.key,
    required this.active,
    required this.icon,
    required this.label,
    required this.onTap,
    this.activeColor,
    required this.size,
    required this.iconSize,
    required this.labelSize,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = active
        ? (activeColor ?? context.syblColors.accentFill)
        : (context.syblColors.neutralButtonFill ?? context.syblColors.surface);
    Color background(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return Color.alphaBlend(
          context.syblColors.bg.withValues(alpha: .35),
          baseColor,
        );
      }
      if (!active && context.syblColors.neutralButtonFill != null) {
        if (states.contains(WidgetState.pressed)) {
          return context.syblColors.neutralButtonPressed ?? baseColor;
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return context.syblColors.neutralButtonHover ?? baseColor;
        }
      }
      if (states.contains(WidgetState.pressed)) {
        return Color.alphaBlend(
          context.syblColors.ink.withValues(alpha: .18),
          baseColor,
        );
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return Color.alphaBlend(
          context.syblColors.amber.withValues(alpha: .12),
          baseColor,
        );
      }
      return baseColor;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Gravity(
          child: SizedBox.square(
            dimension: size,
            child: IconButton(
              tooltip: label,
              onPressed: onTap,
              padding: EdgeInsets.zero,
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith(background),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  final color = active
                      ? (activeColor == null
                            ? context.syblColors.onAccent
                            : context.syblColors.foregroundFor(baseColor))
                      : (context.syblColors.neutralButtonForeground ??
                            context.syblColors.muted);
                  return states.contains(WidgetState.disabled)
                      ? color.withValues(alpha: .45)
                      : color;
                }),
                shape: const WidgetStatePropertyAll(CircleBorder()),
              ),
              icon: Icon(icon, size: iconSize),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _ControlLabel(label: label, maxWidth: size, fontSize: labelSize),
      ],
    );
  }
}

class _ControlLabel extends StatelessWidget {
  const _ControlLabel({
    required this.label,
    required this.maxWidth,
    required this.fontSize,
  });

  final String label;
  final double maxWidth;
  final double fontSize;

  @override
  Widget build(BuildContext context) => fontSize <= 0
      ? const SizedBox.shrink()
      : SizedBox(
          width: maxWidth,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Gravity(
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: context.syblColors.muted,
                  fontSize: fontSize,
                ),
              ),
            ),
          ),
        );
}
