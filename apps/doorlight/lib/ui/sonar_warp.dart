import 'dart:async';
import 'dart:math' as math;
import '../state/sonar_combat.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'sybl_ui.dart';

/// Screen-wide sonar effects for Nearby.
///
/// [SonarWarpState.reveal] sends one wavefront out from a point: the current
/// screen is captured once and bent by `shaders/sonar_warp.frag` as the wave
/// crosses it. [SonarWarpState.received] is the quieter counterpart: a few
/// rings leave the notification bell, so the ping reads as coming from it.
/// Effects never intercept input and follow the app's motion setting.
class SonarWarp extends StatefulWidget {
  const SonarWarp({super.key, required this.child});

  final Widget child;

  static SonarWarpState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<SonarWarpState>();

  /// How long a wave plays; a full reveal shows a frozen snapshot this long.
  static const waveDuration = Duration(milliseconds: 1250);

  /// Fades in what a reveal turns on only once the frozen snapshot lifts, so
  /// it appears instead of popping in finished.
  static Widget revealSwitcher(
    BuildContext context, {
    required bool revealed,
    required Widget child,
  }) {
    const fade = Duration(milliseconds: 450);
    final total = waveDuration + fade;
    return AnimatedSwitcher(
      duration: SyblMotion.duration(context, revealed ? total : fade),
      reverseDuration: SyblMotion.duration(context, fade),
      switchInCurve: revealed
          ? Interval(
              waveDuration.inMilliseconds / total.inMilliseconds,
              1,
              curve: Curves.easeOut,
            )
          : Curves.easeOut,
      child: child,
    );
  }

  @override
  State<SonarWarp> createState() => SonarWarpState();
}

enum _SonarKind { reveal, received, death }

class SonarWarpState extends State<SonarWarp>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _program;

  final _boundary = GlobalKey();
  late final AnimationController _wave;
  _SonarKind? _kind;
  // A tap's wave nudges the live screen instead of bending a snapshot.
  bool _shake = false;
  Offset _origin = Offset.zero;
  ui.Image? _snapshot;
  ui.FragmentShader? _shader;
  static const _desktop = MethodChannel('syb.l/sonar');
  bool _desktopActive = false;

  Future<void> _desktopCall(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      await _desktop.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // The in-window effect remains available if the overlay cannot be shown.
    } on MissingPluginException {
      // Other platforms and widget fixtures have no Windows overlay.
    }
  }

  // Where a received sonar starts: the newest attached SonarTarget, which is
  // the notification bell of whichever layout is on screen.
  final List<BuildContext> _targets = [];

  static Future<ui.FragmentProgram?> _loadProgram() =>
      _program ??= ui.FragmentProgram.fromAsset(
        'shaders/sonar_warp.frag',
      ).then<ui.FragmentProgram?>((p) => p).catchError((Object _) => null);

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      });
  }

  bool get _reducedMotion => MediaQuery.disableAnimationsOf(context);

  Offset _local(Offset global) {
    final box = context.findRenderObject();
    return box is RenderBox ? box.globalToLocal(global) : global;
  }

  /// One outward wavefront from [globalOrigin], bending the whole screen.
  /// With [full] false it is rings only over the live app: no frozen
  /// snapshot and nothing outside the window.
  Future<void> reveal(Offset globalOrigin, {bool full = true}) async {
    if (!mounted || _reducedMotion || _kind == _SonarKind.death) return;
    final origin = _local(globalOrigin);
    ui.Image? snapshot;
    ui.FragmentShader? shader;
    final program = full ? await _loadProgram() : null;
    if (!mounted) return;
    final boundary = _boundary.currentContext?.findRenderObject();
    if (program != null && boundary is RenderRepaintBoundary) {
      try {
        snapshot = await boundary.toImage(
          pixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        shader = program.fragmentShader();
      } catch (_) {
        snapshot?.dispose();
        snapshot = null;
      }
    }
    if (!mounted || _kind == _SonarKind.death) {
      snapshot?.dispose();
      shader?.dispose();
      return;
    }
    _finish();
    setState(() {
      _kind = _SonarKind.reveal;
      _shake = !full;
      _origin = origin;
      _snapshot = snapshot;
      _shader = shader;
    });
    _wave
      ..duration = SonarWarp.waveDuration
      ..forward(from: 0);
    if (full && Theme.of(context).platform == TargetPlatform.windows) {
      _desktopActive = true;
      unawaited(
        _desktopCall('reveal', {
          'x': globalOrigin.dx,
          'y': globalOrigin.dy,
          'color': context.syblColors.amber.toARGB32() & 0xffffff,
        }),
      );
    }
  }

  /// Rings leaving the newest [SonarTarget], or the screen centre without one.
  void received() {
    if (!mounted ||
        _reducedMotion ||
        _kind == _SonarKind.reveal ||
        _kind == _SonarKind.death) {
      return;
    }
    final size = (context.findRenderObject() as RenderBox?)?.size;
    Offset origin = size == null ? Offset.zero : size.center(Offset.zero);
    for (final target in _targets.reversed) {
      final box = target.mounted ? target.findRenderObject() : null;
      if (box is RenderBox && box.attached && box.hasSize) {
        origin = _local(box.localToGlobal(box.size.center(Offset.zero)));
        break;
      }
    }
    _finish();
    setState(() {
      _kind = _SonarKind.received;
      _origin = origin;
    });
    _wave
      ..duration = const Duration(milliseconds: 950)
      ..forward(from: 0);
  }

  void death() {
    if (!mounted || _reducedMotion) return;
    _finish();
    setState(() => _kind = _SonarKind.death);
    _wave
      ..duration = SonarCombat.deathDuration
      ..forward(from: 0);
  }

  void _finish() {
    if (_desktopActive) {
      _desktopActive = false;
      unawaited(_desktopCall('cancel'));
    }
    _wave.stop();
    _snapshot?.dispose();
    _shader?.dispose();
    _snapshot = null;
    _shader = null;
    if (_kind != null && mounted) setState(() => _kind = null);
  }

  @override
  void dispose() {
    if (_desktopActive) unawaited(_desktopCall('cancel'));
    _wave.dispose();
    _snapshot?.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        AnimatedBuilder(
          animation: _wave,
          child: RepaintBoundary(key: _boundary, child: widget.child),
          // Always the same wrapper, so the app below never remounts.
          builder: (context, child) {
            var offset = Offset.zero;
            if (kind == _SonarKind.death) {
              final seconds =
                  _wave.value * SonarCombat.deathDuration.inMilliseconds / 1000;
              final force = seconds < 1
                  ? .7
                  : seconds < 1.5
                  ? 8 * (1.5 - seconds) * 2
                  : 0.0;
              offset = Offset(
                math.sin(seconds * 87) * force,
                math.cos(seconds * 63) * force,
              );
            }
            if (_shake && kind == _SonarKind.reveal) {
              // A short damped tremor as the ring leaves, a few pixels at most.
              final t = (_wave.value / .45).clamp(0.0, 1.0);
              final fade = (1 - t) * (1 - t);
              offset = Offset(
                math.sin(t * math.pi * 9) * 3 * fade,
                math.cos(t * math.pi * 7) * 2 * fade,
              );
            }
            return Transform.translate(offset: offset, child: child);
          },
        ),
        if (kind != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                key: ValueKey('sonar-${kind.name}'),
                painter: _SonarPainter(
                  kind: kind,
                  progress: _wave,
                  origin: _origin,
                  snapshot: _snapshot,
                  shader: _shader,
                  tint: context.syblColors.amber,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SonarPainter extends CustomPainter {
  _SonarPainter({
    required this.kind,
    required this.progress,
    required this.origin,
    required this.snapshot,
    required this.shader,
    required this.tint,
  }) : super(repaint: progress);

  final _SonarKind kind;
  final Animation<double> progress;
  final Offset origin;
  final ui.Image? snapshot;
  final ui.FragmentShader? shader;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (kind == _SonarKind.death) {
      final seconds = t * SonarCombat.deathDuration.inMilliseconds / 1000;
      final fade = ((1 - t) / .3).clamp(0.0, 1.0);
      final flood = ((seconds - 1.5) / 1.5).clamp(0.0, 1.0);
      final surface = size.height * (1 - flood) - (flood == 1 ? 8 : 0);
      if (seconds < 1.5) {
        final flash = seconds < 1
            ? .12 * (1 + math.sin(seconds * 15))
            : .55 * (1.5 - seconds) * 2;
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = const Color(0xffb82920).withValues(alpha: flash),
        );
      }
      final water = Path()..moveTo(0, surface);
      if (seconds >= 1 && seconds < 3) {
        final breach = ((seconds - 1) * 2).clamp(0.0, 1.0);
        for (var i = 0; i < 5; i++) {
          final left = i.isEven;
          final y = size.height * (.2 + i * .13);
          final jet = Path()
            ..moveTo(left ? 0 : size.width, y)
            ..quadraticBezierTo(
              left
                  ? size.width * .28 * breach
                  : size.width * (1 - .28 * breach),
              y - 30,
              left
                  ? size.width * .35 * breach
                  : size.width * (1 - .35 * breach),
              size.height,
            );
          canvas.drawPath(
            jet,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 8 + i * 3
              ..color = const Color(
                0xff79b2bd,
              ).withValues(alpha: .3 * breach * fade),
          );
        }
      }
      for (var x = 0.0; x <= size.width + 12; x += 12) {
        water.lineTo(x, surface + math.sin(x / 38 + seconds * 5) * 7 * fade);
      }
      water
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        water,
        Paint()..color = const Color(0xff063c50).withValues(alpha: .76 * fade),
      );
      if (flood > 0 && seconds < 7) {
        for (var i = 0; i < 24; i++) {
          final x = (i * 137.0 + math.sin(seconds + i) * 14) % size.width;
          final y =
              size.height - ((seconds * (45 + i * 3) + i * 83) % size.height);
          if (y < surface) continue;
          canvas.drawCircle(
            Offset(x, y),
            2.0 + i % 4,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = Colors.white.withValues(alpha: .2 * fade),
          );
        }
      }
      return;
    }
    final reach = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    if (kind == _SonarKind.reveal) {
      final image = snapshot;
      final program = shader;
      if (image != null && program != null) {
        program
          ..setFloat(0, size.width)
          ..setFloat(1, size.height)
          ..setFloat(2, origin.dx)
          ..setFloat(3, origin.dy)
          ..setFloat(4, Curves.easeOutCubic.transform(t))
          ..setFloat(5, 16)
          ..setFloat(6, tint.r)
          ..setFloat(7, tint.g)
          ..setFloat(8, tint.b)
          ..setImageSampler(0, image);
        canvas.drawRect(Offset.zero & size, Paint()..shader = program);
      }
      // Trailing echoes behind the main wavefront.
      for (var echo = 0; echo < 3; echo++) {
        final local = ((t - echo * .12) / (1 - echo * .12)).clamp(0.0, 1.0);
        if (local <= 0) continue;
        final radius = Curves.easeOutCubic.transform(local) * reach;
        final alpha = (1 - local) * (echo == 0 ? .55 : .3);
        canvas.drawCircle(
          origin,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = echo == 0 ? 3 : 1.5
            ..color = tint.withValues(alpha: alpha),
        );
      }
      return;
    }
    // Received: a few rings leave the bell and fade within part of the screen.
    for (var ring = 0; ring < 3; ring++) {
      final local = ((t - ring * .15) / (1 - ring * .15)).clamp(0.0, 1.0);
      if (local <= 0 || local >= 1) continue;
      final radius = 6 + Curves.easeOutCubic.transform(local) * reach * .35;
      final alpha = (1 - local) * .5;
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tint.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_SonarPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.origin != origin ||
      oldDelegate.snapshot != snapshot ||
      oldDelegate.shader != shader ||
      oldDelegate.tint != tint;
}

/// Marks the widget a received sonar should leave from.
class SonarTarget extends StatefulWidget {
  const SonarTarget({super.key, required this.child});

  final Widget child;

  @override
  State<SonarTarget> createState() => _SonarTargetState();
}

class _SonarTargetState extends State<SonarTarget> {
  SonarWarpState? _warp;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final warp = SonarWarp.maybeOf(context);
    if (identical(warp, _warp)) return;
    _warp?._targets.remove(context);
    _warp = warp?.._targets.add(context);
  }

  @override
  void dispose() {
    _warp?._targets.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
