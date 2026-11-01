import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'gravity.dart';

/// The onboarding door is drawn on the current surface, so it never brings a
/// rectangular background along with the supplied promotional artwork.
class DoorlightDoorMark extends StatelessWidget {
  // Preserve the original resting pose, then rotate the leaf through 180°.
  static final _restAngle = math.acos((45 - 8 * 1.4) / 45);
  static final maxOpenness = 1.4 + math.pi - _restAngle;

  static Offset handlePosition(double openness) {
    final (right, depth) = _doorProjection(openness);
    final inset = openness <= 1.4
        ? 5.0
        : 5 * math.cos(_restAngle + openness - 1.4) / math.cos(_restAngle);
    return Offset(right - inset, 45 + depth);
  }

  const DoorlightDoorMark({
    super.key,
    required this.size,
    this.openness = 1.4,
    this.illumination,
    this.thresholdPhase = .5,
  });

  final double size;
  final double openness;
  final double? illumination;
  final double thresholdPhase;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -size * .4,
          top: -size * .02,
          width: size * 1.4,
          height: size * 1.14,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _DoorlightDoorPainter(
                scale: size / 100,
                color: context.syblColors.amber,
                background: context.syblColors.bg,
                openness: openness.clamp(0.0, maxOpenness),
                illumination: (illumination ?? openness).clamp(0.0, 1.0),
                thresholdPhase: thresholdPhase.clamp(0.0, 1.0),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

(double, double) _doorProjection(double openness) {
  if (openness <= 1.4) return (72 - 8 * openness, openness / 1.4);
  final angle = DoorlightDoorMark._restAngle + openness - 1.4;
  return (
    27 + 45 * math.cos(angle),
    math.sin(angle) /
        math.sin(DoorlightDoorMark._restAngle) *
        (math.cos(angle).abs() / math.cos(DoorlightDoorMark._restAngle)).clamp(
          0.0,
          1.0,
        ),
  );
}

class _DoorlightDoorPainter extends CustomPainter {
  const _DoorlightDoorPainter({
    required this.scale,
    required this.color,
    required this.background,
    required this.openness,
    required this.illumination,
    required this.thresholdPhase,
  });

  final Color color;
  final double scale;
  final Color background;
  final double openness;
  final double illumination;
  final double thresholdPhase;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    canvas.translate(40, 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;
    final (right, depth) = _doorProjection(openness);
    // At zero opening the leaf is a rectangle. Its upper and lower right
    // corners only move after opening begins; the final pose stays unchanged.
    final openingFraction = (openness / 1.4).clamp(0.0, 1.0);
    final top = 15.0 - 9.0 * depth;
    final bottom = 75.0 + 11.0 * depth;
    const wallBottom = 75.0;
    final wall = Paint()..color = color;

    // Let the floor light cover the wall's foot so scaling cannot expose a
    // darker seam where the two shapes meet.
    canvas.drawPath(
      Path()
        ..moveTo(27, 15)
        ..lineTo(72, 15)
        ..lineTo(72, wallBottom)
        ..lineTo(27, wallBottom)
        ..close(),
      wall,
    );

    // Continue the original curve to its intersection with the floor threshold.
    final transition =
        openingFraction * openingFraction * (3 - 2 * openingFraction);
    final extraOpening =
        ((openness - 1.4) / (DoorlightDoorMark.maxOpenness - 1.4)).clamp(
          0.0,
          1.0,
        );
    final completion = extraOpening * extraOpening * (3 - 2 * extraOpening);
    const columns = 32;
    const rows = 24;
    final leftColumns = completion > 0 ? 8 : 0;
    final stride = columns + leftColumns + 1;
    // The same cubic has y(t) = 89 + 58.8*t - 58.8*t*t.
    // Its negative root at y=75 completes the rounded left side.
    final leftLimit = (1 - math.sqrt(1 + 4 * (89 - wallBottom) / 58.8)) / 2;
    Offset curve(Offset a, Offset b, Offset c, Offset d, double t) {
      final inverse = 1 - t;
      return a * (inverse * inverse * inverse) +
          b * (3 * inverse * inverse * t) +
          c * (3 * inverse * t * t) +
          d * (t * t * t);
    }

    final positions = <Offset>[];
    final colors = <Color>[];
    final indices = <int>[];
    final sweepCenter = 1.15 - 1.85 * openness.clamp(0.0, 1.0);
    final shadowCenter = -.2 + 1.4 * thresholdPhase;
    for (var row = 0; row <= rows; row++) {
      final distance = row / rows;
      final closedFade = math.pow(1 - distance, 1.5).toDouble();
      final openFade = 1 - distance * distance;
      final fade = closedFade + (openFade - closedFade) * transition;
      for (var column = -leftColumns; column <= columns; column++) {
        final across = column < 0
            ? leftLimit * completion * -column / leftColumns
            : column / columns;
        final inner = Offset(27 + 45 * across, wallBottom);
        final spill = 1 / (1 + math.exp(-2 * (across - sweepCenter)));
        final outer = curve(
          const Offset(8, 89),
          const Offset(28, 108.6),
          const Offset(72, 108.6),
          const Offset(92, 89),
          across,
        );
        final position = Offset.lerp(inner, outer, .95 * distance)!;
        positions.add(position);
        final shadowWidth = .1 + .07 * distance;
        final shadowOffset = (across - shadowCenter) / shadowWidth;
        final shadow = math.exp(-.5 * shadowOffset * shadowOffset);
        final edgeFade = math.sin(math.pi * across);
        final closedDirection = edgeFade * (1 - .6 * shadow);
        final direction =
            closedDirection + (spill - closedDirection) * transition;
        final strength = .32 + .98 * illumination;
        colors.add(
          color.withValues(alpha: math.min(1.0, fade * strength * direction)),
        );
        if (row < rows && column < columns) {
          final index = row * stride + column + leftColumns;
          indices.addAll([
            index,
            index + stride,
            index + 1,
            index + 1,
            index + stride,
            index + stride + 1,
          ]);
        }
      }
    }
    canvas.drawVertices(
      ui.Vertices(
        ui.VertexMode.triangles,
        positions,
        colors: colors,
        indices: indices,
      ),
      BlendMode.dst,
      Paint(),
    );

    // The same fixed jamb and threshold remain visible in every pose.
    canvas.drawPath(
      Path()
        ..moveTo(27, 15)
        ..lineTo(72, 15)
        ..lineTo(72, wallBottom)
        ..lineTo(27, wallBottom),
      stroke,
    );
    final door = Path()
      ..moveTo(27, 15)
      ..lineTo(right, top)
      ..lineTo(right, bottom)
      ..lineTo(27, 75)
      ..close();
    canvas.drawPath(door, Paint()..color = background);
    canvas.drawPath(door, stroke);
    canvas.drawCircle(DoorlightDoorMark.handlePosition(openness), 1.8, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DoorlightDoorPainter oldDelegate) =>
      scale != oldDelegate.scale ||
      color != oldDelegate.color ||
      background != oldDelegate.background ||
      openness != oldDelegate.openness ||
      illumination != oldDelegate.illumination ||
      thresholdPhase != oldDelegate.thresholdPhase;
}

/// The generated open-door app mark, fitted without cropping.
class DoorlightMark extends StatelessWidget {
  const DoorlightMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Image.asset(
      'assets/brand/mark.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    ),
  );
}

class DoorlightHero extends StatelessWidget {
  const DoorlightHero({super.key, this.size = 112});

  final double size;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Image.asset(
      'assets/brand/about.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    ),
  );
}

Future<void> showDoorlightAbout(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Gravity(child: Text('About Doorlight')),
    contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
    actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: DoorlightHero(size: 80)),
            const SizedBox(height: 20),
            DefaultTextStyle(
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                color: context.syblColors.muted,
                fontSize: 14,
                height: 1.4,
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Gravity(
                    child: Text(
                      'Powered by Jami for identity, authenticated conversations, calls and media.',
                    ),
                  ),
                  SizedBox(height: 8),
                  Gravity(
                    child: Text(
                      'Sonar sound effects from Pixabay contributors.',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      Gravity(
        child: OutlinedButton(
          onPressed: () =>
              showLicensePage(context: context, applicationName: 'Doorlight'),
          child: const Text('Credits & licenses'),
        ),
      ),
      Gravity(
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ),
    ],
  ),
);
