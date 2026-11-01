import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Sonar combat drawing: target brackets, the incoming warning, a rocket with
/// flame and smoke on its arc, and the blast where it lands. Pure functions
/// of time, so reduced motion can draw an end state or nothing.
abstract final class SonarCombatPainter {
  /// Red `[` `]` framing a target; they breathe while [time] runs.
  static void brackets(
    Canvas canvas,
    Offset centre,
    double radius,
    Color color,
    double time, {
    int pairs = 1,
  }) {
    for (var pair = 0; pair < pairs; pair++) {
      _bracket(canvas, centre, radius + pair * 7, color, time);
    }
  }

  static void _bracket(
    Canvas canvas,
    Offset centre,
    double radius,
    Color color,
    double time,
  ) {
    final r = radius + 3 * math.sin(time * 14);
    final arm = r * .45;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square
      ..color = color.withValues(alpha: .75 + .25 * math.sin(time * 14));
    for (final side in const [-1.0, 1.0]) {
      final x = centre.dx + side * r;
      canvas.drawPath(
        Path()
          ..moveTo(x - side * arm, centre.dy - r)
          ..lineTo(x, centre.dy - r)
          ..lineTo(x, centre.dy + r)
          ..lineTo(x - side * arm, centre.dy + r),
        paint,
      );
    }
  }

  /// A red ring pulsing around your sonar while something is inbound.
  static void warning(
    Canvas canvas,
    Offset centre,
    double radius,
    Color color,
    double time,
  ) {
    final pulse = .5 + .5 * math.sin(time * 9);
    canvas
      ..drawCircle(
        centre,
        radius + 5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: .45 + .4 * pulse),
      )
      ..drawCircle(
        centre,
        radius + 10,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = color.withValues(alpha: .18 * pulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
  }

  /// Where a missile is at [q] on its bowed path; the bow always lifts.
  static Offset arc(Offset from, Offset to, double bow, double q) {
    final span = to - from;
    final normal = Offset(-span.dy, span.dx) / math.max(span.distance, 1);
    final lift = normal.dy > 0 ? -normal : normal;
    final control = from + span / 2 + lift * span.distance * bow;
    final u = 1 - q;
    return from * (u * u) + control * (2 * u * q) + to * (q * q);
  }

  /// A small rocket at [progress] of its flight, trailing smoke and flame.
  /// [hostile] tints the nose of one fired at you.
  static void rocket(
    Canvas canvas, {
    required Offset from,
    required Offset to,
    required double bow,
    required double progress,
    required double time,
    required Color body,
    required Color flame,
    required Color smoke,
    Color? hostile,
  }) {
    // It eases off the pad and speeds up towards the target.
    final q = Curves.easeInSine.transform(progress.clamp(0.0, 1.0));
    final at = arc(from, to, bow, q);
    final ahead = arc(from, to, bow, math.min(1, q + .01));
    final heading = ahead == at
        ? (to - from).direction
        : (ahead - at).direction;
    // Smoke puffs left behind, growing and thinning with age.
    for (var i = 14; i >= 1; i--) {
      final back = q - i * .02;
      if (back <= 0) continue;
      final drift = math.sin(i * 1.7 + time * 3) * i * .35;
      final point =
          arc(from, to, bow, back) +
          Offset(
                math.cos(heading + math.pi / 2),
                math.sin(heading + math.pi / 2),
              ) *
              drift;
      canvas.drawCircle(
        point,
        1.6 + i * .45,
        Paint()..color = smoke.withValues(alpha: .32 * (1 - i / 15)),
      );
    }
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..rotate(heading);
    final flicker = 7 + 3 * math.sin(time * 61) + 2 * math.sin(time * 37);
    canvas
      ..drawCircle(
        Offset(-9 - flicker * .4, 0),
        5,
        Paint()
          ..color = flame.withValues(alpha: .55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      )
      ..drawPath(
        Path()
          ..moveTo(-6, -2.6)
          ..lineTo(-6 - flicker, 0)
          ..lineTo(-6, 2.6)
          ..close(),
        Paint()..color = flame,
      )
      ..drawPath(
        Path()
          ..moveTo(-6, -1.3)
          ..lineTo(-6 - flicker * .5, 0)
          ..lineTo(-6, 1.3)
          ..close(),
        Paint()..color = Colors.white.withValues(alpha: .85),
      )
      // Fins, body and nose.
      ..drawPath(
        Path()
          ..moveTo(-6, -2.5)
          ..lineTo(-8, -5.5)
          ..lineTo(-3, -2.5)
          ..moveTo(-6, 2.5)
          ..lineTo(-8, 5.5)
          ..lineTo(-3, 2.5),
        Paint()..color = hostile ?? flame,
      )
      ..drawRRect(
        RRect.fromLTRBR(-6, -2.6, 5, 2.6, const Radius.circular(1.5)),
        Paint()..color = body,
      )
      ..drawPath(
        Path()
          ..moveTo(5, -2.6)
          ..lineTo(10, 0)
          ..lineTo(5, 2.6)
          ..close(),
        Paint()..color = hostile ?? flame,
      )
      ..restore();
  }

  /// The blast where a missile lands, [q] from 0 to 1 over its life.
  static void explosion(
    Canvas canvas,
    Offset at,
    double q,
    Color fire,
    Color heat, {
    int seed = 0,
  }) {
    if (q < 0 || q >= 1) return;
    final grow = Curves.easeOutCubic.transform(q);
    canvas.drawCircle(
      at,
      10 + 34 * grow,
      Paint()
        ..color = Color.lerp(fire, heat, q)!.withValues(alpha: .7 * (1 - q))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    if (q < .2) {
      canvas.drawCircle(
        at,
        14 * (1 - q / .2) + 4,
        Paint()..color = Colors.white.withValues(alpha: .9 * (1 - q / .2)),
      );
    }
    canvas.drawCircle(
      at,
      8 + 46 * grow,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - q) + .5
        ..color = fire.withValues(alpha: .8 * (1 - q)),
    );
    final random = math.Random(seed);
    final debris = Paint()..color = fire.withValues(alpha: 1 - q);
    for (var i = 0; i < 12; i++) {
      final angle = random.nextDouble() * math.pi * 2;
      final speed = 30 + random.nextDouble() * 40;
      canvas.drawCircle(
        at +
            Offset(math.cos(angle), math.sin(angle)) * speed * grow +
            Offset(0, 30 * q * q),
        2.2 * (1 - q) + .6,
        debris,
      );
    }
  }
}
