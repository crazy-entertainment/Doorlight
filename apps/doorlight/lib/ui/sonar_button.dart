import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'gravity.dart';
import 'sonar_warp.dart';
import 'sybl_ui.dart';

/// Your own avatar as the Nearby sonar.
///
/// Hidden, it asks to be held: a ring fills while the finger stays down and
/// the reveal fires only once it closes, so a brush in a pocket or a class
/// never reveals anyone. Visible, the ring becomes the remaining time; the
/// Nearby stage draws the waves each announcement sends.
///
/// A hit turns the timer and ring red while the shown time drains through
/// what it cost; a sonar destroyed by a hit cracks and refuses holds until it
/// re-arms.
class SonarButton extends StatefulWidget {
  const SonarButton({
    super.key,
    required this.label,
    required this.imageBase64,
    required this.visibleUntil,
    required this.window,
    required this.onReveal,
    required this.onStop,
    this.onPulse,
    this.onHolding,
    this.enabled = true,
    this.size = 112,
    this.hitAt,
    this.hitLost = Duration.zero,
    this.rearmAt,
  });

  final String label;
  final String imageBase64;

  /// End of the current visibility window, or null while hidden.
  final DateTime? visibleUntil;
  final Duration window;

  /// Called with the avatar's global centre once the hold completes.
  final ValueChanged<Offset> onReveal;
  final VoidCallback onStop;
  final ValueChanged<bool>? onHolding;

  /// Called with the avatar's global centre when it is tapped while visible.
  final ValueChanged<Offset>? onPulse;
  final bool enabled;
  final double size;

  /// The latest hit on you and the time it took.
  final DateTime? hitAt;
  final Duration hitLost;

  /// While set and ahead, the sonar is destroyed and holding does nothing.
  final DateTime? rearmAt;

  static const holdDuration = Duration(milliseconds: 750);

  /// Red eases back to amber over this after a hit; the shown time catches
  /// up with the real one in its first [hitDrain] share.
  static const hitRecovery = Duration(seconds: 3);
  static const hitDrain = .4;

  @override
  State<SonarButton> createState() => _SonarButtonState();
}

class _SonarButtonState extends State<SonarButton>
    with TickerProviderStateMixin {
  // `preserve`: reduced motion must not shorten the hold, or a brush would
  // reveal someone.
  late final AnimationController _hold =
      AnimationController(
          vsync: this,
          duration: SonarButton.holdDuration,
          animationBehavior: AnimationBehavior.preserve,
        )
        ..addStatusListener(_holdStatus)
        ..addListener(_holdBuzz);
  // A small press-and-bounce on the picture for each tap while visible.
  late final AnimationController _tap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final AnimationController _hit = AnimationController(
    vsync: this,
    duration: SonarButton.hitRecovery,
    value: 1,
  );
  static final _tapScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: .9,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 25,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: .9,
        end: 1.06,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.06,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 40,
    ),
  ]);
  final _avatar = GlobalKey();
  // Only a press that began while visible pulses, so lifting the finger that
  // just finished the reveal hold does not.
  bool _pressedVisible = false;
  Timer? _tick;
  int _buzzes = 0;
  bool _holding = false;
  void _setHolding(bool value) {
    if (_holding == value) return;
    _holding = value;
    widget.onHolding?.call(value);
  }

  // The phone shakes harder and faster as the reveal hold fills: taps come
  // closer together and step up from clicks to impacts.
  static const _buzzAt = [.12, .3, .45, .57, .67, .75, .82, .87, .91, .94, .97];

  void _holdBuzz() {
    final value = _hold.value;
    if (_hold.status == AnimationStatus.reverse || value == 0) {
      _buzzes = 0;
      return;
    }
    while (_buzzes < _buzzAt.length && value >= _buzzAt[_buzzes]) {
      final step = _buzzes++;
      if (step < 3) {
        HapticFeedback.selectionClick();
      } else if (step < 7) {
        HapticFeedback.lightImpact();
      } else {
        HapticFeedback.mediumImpact();
      }
    }
  }

  bool get _visible =>
      widget.visibleUntil != null &&
      widget.visibleUntil!.isAfter(DateTime.now());

  bool get _rearming =>
      widget.rearmAt != null && widget.rearmAt!.isAfter(DateTime.now());

  @override
  void initState() {
    super.initState();
    _syncVisible();
  }

  @override
  void didUpdateWidget(SonarButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || _visible || _rearming) {
      _setHolding(false);
      _hold.value = 0;
    }
    if (oldWidget.visibleUntil != widget.visibleUntil ||
        oldWidget.rearmAt != widget.rearmAt) {
      _syncVisible();
    }
    if (widget.hitAt != null && oldWidget.hitAt != widget.hitAt) {
      // Reduced motion shows the settled colour and time at once.
      if (MediaQuery.disableAnimationsOf(context)) {
        _hit.value = 1;
      } else {
        _hit.forward(from: 0);
      }
    }
  }

  void _syncVisible() {
    _tick?.cancel();
    _tick = null;
    if (_visible || _rearming) {
      _hold.value = 0;
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _holdStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        !widget.enabled ||
        _visible ||
        _rearming) {
      return;
    }
    _setHolding(false);
    HapticFeedback.heavyImpact();
    // The full ring stays until the countdown takes over; the completed hold
    // paints a calm avatar, and the reveal waits for that frame so the wave's
    // screen capture shows neither the glitch nor an empty ring.
    _hold.value = 1;
    final binding = WidgetsBinding.instance;
    binding
      ..addPostFrameCallback((_) {
        if (!mounted || !widget.enabled || _visible || _rearming) return;
        widget.onReveal(_centre());
        // A refused reveal never becomes visible: let the ring go.
        binding
          ..addPostFrameCallback((_) {
            if (mounted && !_visible) _hold.value = 0;
          })
          ..scheduleFrame();
      })
      ..scheduleFrame();
  }

  // The wave starts at the avatar, not the hint text under it.
  Offset _centre() {
    final box = _avatar.currentContext?.findRenderObject();
    return box is RenderBox
        ? box.localToGlobal(box.size.center(Offset.zero))
        : Offset.zero;
  }

  void _pulseNow() {
    if (!widget.enabled || !_visible) return;
    HapticFeedback.mediumImpact();
    if (!MediaQuery.disableAnimationsOf(context)) _tap.forward(from: 0);
    widget.onPulse?.call(_centre());
  }

  void _down() {
    _pressedVisible = _visible;
    if (!widget.enabled || _visible || _rearming) return;
    HapticFeedback.selectionClick();
    _setHolding(true);
    _hold.forward();
  }

  void _up() {
    _setHolding(false);
    if (_pressedVisible) {
      _pressedVisible = false;
      _pulseNow();
      return;
    }
    if (_hold.isCompleted || _visible) return;
    _hold.reverse();
  }

  @override
  void dispose() {
    _setHolding(false);
    _tick?.cancel();
    _hold.dispose();
    _tap.dispose();
    _hit.dispose();
    super.dispose();
  }

  final _noise = math.Random();

  /// The avatar breaks up more and more as the hold closes, so the reveal
  /// lands like a release: colour-split ghosts tear apart, the picture
  /// jitters and flickers, and horizontal slices slip sideways.
  Widget _glitch(BuildContext context, Widget avatar) {
    final hold = _hold.value;
    if (hold == 0 ||
        _hold.isCompleted ||
        _visible ||
        MediaQuery.disableAnimationsOf(context)) {
      return avatar;
    }
    final g = Curves.easeInQuad.transform(hold);
    double jitter(double scale) => (_noise.nextDouble() * 2 - 1) * scale * g;
    bool chance(double odds) => _noise.nextDouble() < odds * g;
    final slip = chance(.5) ? jitter(18) : 0.0;
    final split = 3 + g * 11;
    Widget ghost(Color color, double dx) => Transform.translate(
      offset: Offset(dx + jitter(4), jitter(4)),
      child: Opacity(
        opacity: (.35 + g * .55).clamp(0.0, 1.0),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          child: avatar,
        ),
      ),
    );
    final size = widget.size;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ghost(const Color(0xFFFF3B5C), -split),
        ghost(const Color(0xFF3BD6FF), split),
        Opacity(
          opacity: chance(.2) ? .55 : 1,
          child: Transform.translate(
            offset: Offset(jitter(6) + slip, jitter(3)),
            child: avatar,
          ),
        ),
        // Torn scanline bands, more of them and wider as the hold closes.
        for (var band = 0; band < (g * 4).ceil(); band++)
          if (chance(.8))
            Positioned.fill(
              child: ClipRect(
                clipper: _Band(
                  top: _noise.nextDouble() * size,
                  height: 3 + _noise.nextDouble() * 12 * g,
                ),
                child: Transform.translate(
                  offset: Offset(jitter(26), 0),
                  child: avatar,
                ),
              ),
            ),
      ],
    );
  }

  String _remainingLabel(Duration remaining) {
    final seconds = remaining.inSeconds.clamp(0, 5999);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// What the hit still adds to the shown time: it drains fast, then slows
  /// into the real countdown.
  Duration _drain() {
    final drain = Curves.easeOutCubic.transform(
      (_hit.value / SonarButton.hitDrain).clamp(0.0, 1.0),
    );
    return widget.hitLost * (1 - drain);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _hit,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final colors = context.syblColors;
    final visible = _visible;
    final rearming = !visible && _rearming;
    final remaining = visible
        ? widget.visibleUntil!.difference(DateTime.now()) + _drain()
        : Duration.zero;
    final tint = Color.lerp(
      colors.danger,
      colors.amber,
      Curves.easeIn.transform(_hit.value),
    )!;
    final rearmIn = rearming
        ? widget.rearmAt!.difference(DateTime.now()).inSeconds + 1
        : 0;
    final share = visible
        ? (remaining.inMilliseconds / widget.window.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final size = widget.size;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: visible
              ? 'Your light is on for ${_remainingLabel(remaining)}'
              : rearming
              ? 'Your sonar is re-arming'
              : 'Hold to reveal yourself nearby',
          hint: visible ? 'Tap to send a pulse' : null,
          onLongPress: widget.enabled && !visible && !rearming
              ? () => _holdStatus(AnimationStatus.completed)
              : null,
          onTap: widget.enabled && visible && widget.onPulse != null
              ? _pulseNow
              : null,
          child: Listener(
            key: const ValueKey('nearby-sonar-button'),
            onPointerDown: (_) => _down(),
            onPointerUp: (_) => _up(),
            onPointerCancel: (_) {
              _pressedVisible = false;
              _up();
            },
            child: SizedBox.square(
              key: _avatar,
              dimension: size + 48,
              child: AnimatedBuilder(
                animation: Listenable.merge([_hold, _tap]),
                builder: (context, _) => CustomPaint(
                  painter: _SonarRingPainter(
                    hold: _hold.value,
                    remaining: share,
                    color: tint,
                    track: colors.line,
                    avatar: size,
                  ),
                  child: Center(
                    child: AnimatedScale(
                      duration: _tap.isAnimating
                          ? Duration.zero
                          : SyblMotion.duration(context),
                      scale:
                          (1 - _hold.value * .06) *
                          _tapScale.transform(_tap.value),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          _glitch(
                            context,
                            SyblAvatar(
                              label: widget.label,
                              imageBase64: widget.imageBase64,
                              size: size,
                            ),
                          ),
                          // The crack heals by fading once the sonar re-arms.
                          IgnorePointer(
                            child: AnimatedOpacity(
                              key: const ValueKey('nearby-sonar-crack'),
                              opacity:
                                  rearming &&
                                      (widget.hitAt == null ||
                                          _hit.value >= 1 / 3)
                                  ? 1
                                  : 0,
                              duration: SyblMotion.duration(context),
                              child: CustomPaint(
                                size: Size.square(size),
                                painter: _CrackPainter(
                                  color: colors.ink,
                                  glow: colors.danger,
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
        ),
        const SizedBox(height: 8),
        // One fixed height for both states, so revealing never moves the
        // avatar.
        SizedBox(
          height: 52,
          child: Center(
            child: SonarWarp.revealSwitcher(
              context,
              revealed: visible,
              child: visible
                  ? Row(
                      key: const ValueKey('nearby-visible'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Gravity(
                          child: _Countdown(
                            key: const ValueKey('nearby-countdown'),
                            seconds: remaining.inSeconds.clamp(0, 5999),
                            color: tint,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Gravity(
                          child: IconButton(
                            key: const ValueKey('nearby-stop'),
                            tooltip: 'Turn off',
                            onPressed: widget.onStop,
                            style: IconButton.styleFrom(
                              foregroundColor: colors.muted,
                              fixedSize: const Size(32, 32),
                              minimumSize: const Size(32, 32),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(
                              Icons.power_settings_new_rounded,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    )
                  : rearming
                  ? Gravity(
                      key: const ValueKey('nearby-rearm-row'),
                      child: Text(
                        'Sonar down · re-arming in ${rearmIn}s',
                        key: const ValueKey('nearby-rearm'),
                        style: TextStyle(color: colors.danger),
                      ),
                    )
                  : Gravity(
                      child: Text(
                        'Hold to reveal yourself',
                        key: const ValueKey('nearby-hold-hint'),
                        style: TextStyle(color: colors.muted),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shattered glass over a destroyed sonar: cracks run out from an impact
/// point just off centre.
class _CrackPainter extends CustomPainter {
  _CrackPainter({required this.color, required this.glow});

  final Color color;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final centre = size.center(Offset.zero);
    final impact = centre + Offset(radius * .18, -radius * .12);
    canvas
      ..save()
      ..clipPath(
        Path()..addOval(Rect.fromCircle(center: centre, radius: radius)),
      )
      ..drawCircle(
        centre,
        radius,
        Paint()..color = color.withValues(alpha: .45),
      );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = glow.withValues(alpha: .9);
    for (var i = 0; i < 7; i++) {
      final angle = i * math.pi * 2 / 7 + (i.isEven ? .2 : -.15);
      final path = Path()..moveTo(impact.dx, impact.dy);
      var point = impact;
      for (var step = 1; step <= 3; step++) {
        final bend = angle + (step.isEven ? .25 : -.2);
        point += Offset(math.cos(bend), math.sin(bend)) * radius * .42;
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, line);
    }
    canvas
      ..drawCircle(impact, radius * .2, line)
      ..restore();
  }

  @override
  bool shouldRepaint(_CrackPainter old) =>
      old.color != color || old.glow != glow;
}

class _SonarRingPainter extends CustomPainter {
  _SonarRingPainter({
    required this.hold,
    required this.remaining,
    required this.color,
    required this.track,
    required this.avatar,
  });

  final double hold;
  final double remaining;
  final Color color;
  final Color track;
  final double avatar;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = avatar / 2 + 9;
    final rect = Rect.fromCircle(center: centre, radius: radius);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = track,
    );
    final sweep = remaining > 0 ? remaining : hold;
    if (sweep > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_SonarRingPainter old) =>
      old.hold != hold || old.remaining != remaining || old.color != color;
}

class _Band extends CustomClipper<Rect> {
  _Band({required this.top, required this.height});

  final double top;
  final double height;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(-size.width, top, size.width * 3, height);

  @override
  bool shouldReclip(_Band old) => old.top != top || old.height != height;
}

/// A classic countdown: glowing fixed-width digits and a colon that blinks
/// with each second.
class _Countdown extends StatelessWidget {
  const _Countdown({super.key, required this.seconds, required this.color});

  final int seconds;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return Semantics(
      label: '$minutes:$rest left',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: minutes),
            TextSpan(
              text: ':',
              style: TextStyle(
                color: seconds.isEven ? color : color.withValues(alpha: .25),
              ),
            ),
            TextSpan(text: rest),
          ],
        ),
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: 3,
          height: 1.1,
          fontFeatures: const [FontFeature.tabularFigures()],
          shadows: [
            Shadow(color: color.withValues(alpha: .45), blurRadius: 10),
          ],
        ),
      ),
    );
  }
}
