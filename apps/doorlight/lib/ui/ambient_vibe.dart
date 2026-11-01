import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme.dart';

String vibeLabel(AmbientVibe vibe) => switch (vibe) {
  AmbientVibe.none => 'None',
  AmbientVibe.rain => 'Rain',
  AmbientVibe.snow => 'Snow',
  AmbientVibe.halloween => 'Halloween',
};

/// Decorative only: never intercepts input or participates in accessibility.
class AmbientVibeSurface extends StatefulWidget {
  const AmbientVibeSurface({
    super.key,
    required this.vibe,
    required this.animationsEnabled,
    this.preview = false,
    this.opacity = 1,
    this.intensity = 1,
    required this.child,
  }) : assert(opacity >= 0 && opacity <= 1),
       assert(intensity >= 0 && intensity <= 1);
  final AmbientVibe vibe;
  final bool animationsEnabled;
  final bool preview;
  final double opacity;
  final double intensity;
  final Widget child;

  @override
  State<AmbientVibeSurface> createState() => _AmbientVibeSurfaceState();
}

class _AmbientVibeSurfaceState extends State<AmbientVibeSurface>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
    animationBehavior: AnimationBehavior.preserve,
  );
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _syncMotion();
  }

  void _syncMotion() {
    if (_foreground &&
        widget.animationsEnabled &&
        widget.opacity > 0 &&
        widget.intensity > 0 &&
        widget.vibe != AmbientVibe.none) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
    }
  }

  @override
  void didUpdateWidget(covariant AmbientVibeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncMotion();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      widget.child,
      if (widget.vibe != AmbientVibe.none && widget.opacity > 0)
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: ClipRect(
                  child: CustomPaint(
                    key: ValueKey('ambient-vibe-${widget.vibe.name}'),
                    painter: VibePainter(
                      widget.vibe,
                      context.syblColors,
                      motion: _motion,
                      preview: widget.preview,
                      opacity: widget.opacity,
                      intensity: widget.intensity,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }
}

class VibePainter extends CustomPainter {
  VibePainter(
    this.vibe,
    this.colors, {
    this.motion,
    this.preview = false,
    this.opacity = 1,
    this.intensity = 1,
  }) : super(repaint: motion);
  final AmbientVibe vibe;
  final SyblColors colors;
  final Animation<double>? motion;
  final bool preview;
  final double opacity;
  final double intensity;

  // The streak and its trajectory share the same wind vector.
  static const rainDirection = Offset(-.22, 1);

  static double _seed(int i, double salt) =>
      (math.sin(i * 12.9898 + salt) * 43758.5453) % 1;

  @visibleForTesting
  static Offset rainPosition(Size size, int i, double phase) {
    const padding = 24.0;
    final travel =
        ((_seed(i, 6) + phase * 6) % 1) * (size.height + padding * 2);
    return Offset(
      (_seed(i, 4) * size.width + rainDirection.dx * travel) % size.width,
      travel - padding,
    );
  }

  // Keep the centre quiet: atmosphere belongs around the content, not over it.
  double _edgeOpacity(Offset point, Size size) {
    if (preview) return 1;
    final x = (point.dx / size.width).clamp(0.0, 1.0);
    final y = (point.dy / size.height).clamp(0.0, 1.0);
    final edge = math.max((x - .5).abs() * 2, (y - .5).abs() * 2);
    return .18 + .82 * math.pow(edge, 3);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (vibe == AmbientVibe.none || opacity == 0 || size.isEmpty) return;
    final phase = motion?.value ?? .35;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (vibe == AmbientVibe.halloween) {
      _paintHalloween(canvas, size, phase);
    } else {
      _paintWeather(canvas, size, phase);
    }
    canvas.restore();
  }

  void _paintWeather(Canvas canvas, Size size, double phase) {
    final rain = vibe == AmbientVibe.rain;
    final baseCount = preview
        ? (rain ? 12 : 10)
        : (size.width * size.height / 14000).round().clamp(14, 48);
    final count = (baseCount * intensity).round();
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final seed = _seed(i, 4);
      final point = rain
          ? rainPosition(size, i, phase)
          : Offset(
              (seed * size.width +
                      math.sin(phase * math.pi * 2 + i) * (preview ? 3 : 12)) %
                  size.width,
              ((_seed(i, 6) + phase) % 1) * (size.height + 12) - 6,
            );
      final depth = .55 + .45 * seed;
      final opacity =
          this.opacity *
          (preview ? .32 : .13) *
          depth *
          _edgeOpacity(point, size);
      paint.color = (rain ? colors.sky : colors.ink).withValues(alpha: opacity);
      if (rain) {
        final length = (preview ? 8.0 : 13.0) * depth;
        paint.strokeWidth = preview ? .8 : .9;
        canvas.drawLine(point, point + rainDirection * length, paint);
      } else {
        canvas.drawCircle(point, (preview ? 1.1 : 1.7) * depth, paint);
      }
    }
  }

  void _paintHalloween(Canvas canvas, Size size, double phase) {
    // A quiet moonlit scene: low drifting mist and two gliding silhouettes.
    // This deliberately has no precipitation or falling seasonal symbols.
    final moon = Offset(size.width * .81, size.height * .22);
    final radius = preview ? 8.0 : 20.0;
    final paint = Paint()
      ..color = colors.ink.withValues(alpha: opacity * (preview ? .38 : .14));
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addOval(Rect.fromCircle(center: moon, radius: radius)),
        Path()..addOval(
          Rect.fromCircle(
            center: moon.translate(radius * .5, -radius * .25),
            radius: radius * .92,
          ),
        ),
      ),
      paint,
    );
    paint.color = Colors.white;
    for (var i = 0; i < (3 * intensity).ceil(); i++) {
      final drift = math.sin(phase * math.pi * 2 + i * 2);
      final centre = Offset(
        size.width * (.2 + i * .32) + drift * size.width * .08,
        size.height * (.96 - i * .025),
      );
      final mist = Rect.fromCenter(
        center: centre,
        width: size.width * .95,
        height: size.height * .35,
      );
      paint.shader = RadialGradient(
        colors: [
          colors.sky.withValues(alpha: opacity * (preview ? .09 : .04)),
          colors.sky.withValues(alpha: 0),
        ],
      ).createShader(mist);
      canvas.drawOval(mist, paint);
    }
    paint.shader = null;
    for (var i = 0; i < (2 * intensity).ceil(); i++) {
      final travel = (phase + i * .47) % 1;
      final x = travel * (size.width + 32) - 16;
      final y =
          size.height * (.16 + i * .13) +
          math.sin(travel * math.pi * 2 + i) * (preview ? 4 : 10);
      final position = Offset(x, y);
      final wing = math.sin(phase * math.pi * 24 + i * 2);
      final scale = preview ? .48 : .7;
      final opacity =
          this.opacity * (preview ? .28 : .14) * _edgeOpacity(position, size);
      paint.color = colors.ink.withValues(alpha: opacity);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(.12 * math.cos(travel * math.pi * 2 + i));
      canvas.scale(scale);
      canvas.drawPath(
        Path()
          ..moveTo(-10, -2 - wing * 4)
          ..quadraticBezierTo(-5, -5 - wing * 2, -1, 0)
          ..lineTo(-1, -2)
          ..lineTo(0, -1)
          ..lineTo(1, -2)
          ..lineTo(1, 0)
          ..quadraticBezierTo(5, -5 - wing * 2, 10, -2 - wing * 4)
          ..quadraticBezierTo(7, 3, 4, 1)
          ..quadraticBezierTo(2, 4, 0, 3)
          ..quadraticBezierTo(-2, 4, -4, 1)
          ..quadraticBezierTo(-7, 3, -10, -2 - wing * 4)
          ..close(),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant VibePainter oldDelegate) =>
      vibe != oldDelegate.vibe ||
      colors != oldDelegate.colors ||
      preview != oldDelegate.preview ||
      opacity != oldDelegate.opacity ||
      intensity != oldDelegate.intensity ||
      motion != oldDelegate.motion;
}
