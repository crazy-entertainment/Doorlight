import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'gravity.dart';

/// A short history of the existing local microphone meter, never a generated
/// speaking animation. Muting immediately clears any previously audible trace.
class MicrophoneWaveform extends StatefulWidget {
  const MicrophoneWaveform({
    super.key,
    required this.level,
    required this.muted,
  });

  final ValueListenable<double> level;
  final bool muted;

  @override
  State<MicrophoneWaveform> createState() => _MicrophoneWaveformState();
}

class _MicrophoneWaveformState extends State<MicrophoneWaveform> {
  final _samples = List<double>.filled(24, 0, growable: true);
  Timer? _timer;
  bool _reducedMotion = false;

  double get _level => widget.muted || !widget.level.value.isFinite
      ? 0
      : widget.level.value.clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_changed);
  }

  void _changed() {
    if (_reducedMotion) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _timer?.cancel();
    _timer = _reducedMotion
        ? null
        : Timer.periodic(const Duration(milliseconds: 50), (_) {
            final level = _level;
            if (level == 0 && _samples.every((sample) => sample == 0)) return;
            setState(() {
              _samples.removeAt(0);
              _samples.add(level);
            });
          });
  }

  @override
  void didUpdateWidget(covariant MicrophoneWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level.removeListener(_changed);
      widget.level.addListener(_changed);
      _samples.fillRange(0, _samples.length, 0);
    }
    if (widget.muted) _samples.fillRange(0, _samples.length, 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.level.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Gravity(
    child: Semantics(
      label: widget.muted ? 'Microphone muted' : 'Microphone level',
      value: '${(_level * 100).round()}%',
      child: CustomPaint(
        size: const Size(116, 14),
        painter: MicrophoneWaveformPainter(
          samples: widget.muted
              ? List<double>.filled(24, 0)
              : _reducedMotion
              ? [_level]
              : List<double>.of(_samples),
          color: context.syblColors.online,
          baseline: context.syblColors.lineStrong,
        ),
      ),
    ),
  );
}

class MicrophoneWaveformPainter extends CustomPainter {
  const MicrophoneWaveformPainter({
    required this.samples,
    required this.color,
    required this.baseline,
  });

  final List<double> samples;
  final Color color;
  final Color baseline;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint..color = baseline,
    );
    paint.color = color;
    for (var i = 0; i < samples.length; i++) {
      if (samples[i] <= 0) continue;
      final x = (i + .5) * size.width / samples.length;
      final halfHeight = samples[i] * (size.height - 2) / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - halfHeight),
        Offset(x, size.height / 2 + halfHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(MicrophoneWaveformPainter oldDelegate) =>
      !listEquals(samples, oldDelegate.samples) ||
      color != oldDelegate.color ||
      baseline != oldDelegate.baseline;
}
