import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps the old appearance outside a growing circle while the live app changes.
class ThemeReveal extends StatefulWidget {
  const ThemeReveal({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  static void change(BuildContext context, VoidCallback change) {
    final host = context.findAncestorStateOfType<_ThemeRevealState>();
    final box = context.findRenderObject();
    if (host == null || box is! RenderBox) {
      change();
      return;
    }
    host.reveal(box.localToGlobal(box.size.center(Offset.zero)), change);
  }

  @override
  State<ThemeReveal> createState() => _ThemeRevealState();
}

class _ThemeRevealState extends State<ThemeReveal>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  late final AnimationController _animation;

  @override
  void initState() {
    super.initState();
    _animation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 550),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _finish();
        });
  }

  ui.Image? _before;
  Offset _origin = Offset.zero;
  int _request = 0;

  void _finish() {
    _animation.stop();
    final before = _before;
    _before = null;
    if (mounted) setState(() {});
    before?.dispose();
  }

  Future<void> reveal(Offset globalOrigin, VoidCallback change) async {
    final request = ++_request;
    _finish();
    if (!widget.enabled) {
      change();
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || request != _request) return;
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      change();
      return;
    }
    ui.Image image;
    try {
      image = await boundary.toImage(
        pixelRatio: View.of(context).devicePixelRatio,
      );
    } catch (_) {
      if (mounted && request == _request) change();
      return;
    }
    if (!mounted || !widget.enabled || request != _request) {
      image.dispose();
      return;
    }
    _origin = boundary.globalToLocal(globalOrigin);
    setState(() => _before = image);
    change();
    _animation.forward(from: 0);
  }

  @override
  void didUpdateWidget(ThemeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _request++;
      _finish();
    }
  }

  @override
  void dispose() {
    _request++;
    _animation.dispose();
    _before?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      RepaintBoundary(key: _boundary, child: widget.child),
      if (_before case final before?)
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, _) => ClipPath(
                key: const ValueKey('theme-circle-reveal'),
                clipper: ThemeRevealClipper(
                  origin: _origin,
                  progress: Curves.easeOutCubic.transform(_animation.value),
                ),
                child: RawImage(image: before, fit: BoxFit.fill),
              ),
            ),
          ),
        ),
    ],
  );
}

class ThemeRevealClipper extends CustomClipper<Path> {
  const ThemeRevealClipper({required this.origin, required this.progress});
  final Offset origin;
  final double progress;

  @override
  Path getClip(Size size) {
    final dx = math.max(origin.dx.abs(), (size.width - origin.dx).abs());
    final dy = math.max(origin.dy.abs(), (size.height - origin.dy).abs());
    final radius = math.sqrt(dx * dx + dy * dy) * progress;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: origin, radius: radius));
  }

  @override
  bool shouldReclip(ThemeRevealClipper oldClipper) =>
      origin != oldClipper.origin || progress != oldClipper.progress;
}
