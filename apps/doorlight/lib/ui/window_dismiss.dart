import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../state/app_settings.dart';

/// A memory-only frame for the protected native exit surface. The live window
/// keeps its layout and placement; native code owns the short exit and timeout.
class WindowDismiss extends StatefulWidget {
  static const MethodChannel _channel = MethodChannel('syb.l/window-dismiss');

  const WindowDismiss({
    super.key,
    required this.enabled,
    this.openAnimation = WindowCloseAnimation.tray,
    this.minimizeAnimation = WindowCloseAnimation.tray,
    this.closeAnimation = WindowCloseAnimation.tray,
    this.openDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    this.minimizeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    this.closeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    required this.child,
  });

  final bool enabled;
  final WindowCloseAnimation openAnimation;
  final WindowCloseAnimation minimizeAnimation;
  final WindowCloseAnimation closeAnimation;
  final int openDurationMs;
  final int minimizeDurationMs;
  final int closeDurationMs;
  final Widget child;

  static Future<bool> preview({
    required String action,
    required WindowCloseAnimation animation,
    required int durationMs,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('preview', {
            'action': action,
            'animation': animation.name,
            'durationMs': durationMs,
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  State<WindowDismiss> createState() => _WindowDismissState();
}

class _WindowDismissState extends State<WindowDismiss>
    with SingleTickerProviderStateMixin {
  static const _channel = WindowDismiss._channel;
  static _WindowDismissState? _owner;
  final _surface = GlobalKey();
  bool _busy = false;
  int _generation = 0;
  bool _diagnostics = false;
  late final AnimationController _attention = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void initState() {
    super.initState();
    final replacing = _owner != null;
    _owner = this;
    _channel.setMethodCallHandler(_onNativeCall);
    if (replacing) unawaited(_configure(false));
    unawaited(_configure(widget.enabled));
  }

  Future<void> _configure(bool enabled) async {
    try {
      _diagnostics =
          await _channel.invokeMethod<bool>('configure', {
            'enabled': enabled,
            'openAnimation': widget.openAnimation.name,
            'minimizeAnimation': widget.minimizeAnimation.name,
            'closeAnimation': widget.closeAnimation.name,
            'openDurationMs': widget.openDurationMs,
            'minimizeDurationMs': widget.minimizeDurationMs,
            'closeDurationMs': widget.closeDurationMs,
          }) ==
          true;
    } on MissingPluginException {
      // Widget-only hosts have no native window.
    } on PlatformException {
      // Native dismissal remains immediate if the effect is unavailable.
    }
  }

  Future<void> _trace(int token, int stage) async {
    if (!_diagnostics) return;
    await _channel.invokeMethod<void>('trace', {
      'token': token,
      'stage': stage,
    });
  }

  @override
  void didUpdateWidget(covariant WindowDismiss oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.openAnimation != widget.openAnimation ||
        oldWidget.minimizeAnimation != widget.minimizeAnimation ||
        oldWidget.closeAnimation != widget.closeAnimation ||
        oldWidget.openDurationMs != widget.openDurationMs ||
        oldWidget.minimizeDurationMs != widget.minimizeDurationMs ||
        oldWidget.closeDurationMs != widget.closeDurationMs) {
      if (!widget.enabled) {
        _stopAttention();
        ++_generation;
        _busy = false;
      }
      unawaited(_configure(widget.enabled));
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'reset') {
      _stopAttention();
      ++_generation;
      if (mounted && _busy) setState(() => _busy = false);
      return;
    }
    if (call.method == 'attention') {
      if (!widget.enabled || _busy) {
        _stopAttention();
      } else if (!_attention.isAnimating) {
        _attention.forward(from: 0);
      }
      return;
    }
    if (call.method != 'capture' || !widget.enabled || _busy) return;
    final token = call.arguments;
    if (token is! int) return;
    _stopAttention();
    final generation = ++_generation;
    setState(() => _busy = true);
    ui.Image? image;
    ByteData? pixels;
    try {
      await _trace(token, 10);
      await WidgetsBinding.instance.endOfFrame;
      await _trace(token, 11);
      if (!mounted || !widget.enabled || generation != _generation) return;
      final boundary = _surface.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return;
      final ratio = View.of(context).devicePixelRatio;
      if (boundary.size.width * boundary.size.height * ratio * ratio >
          16 * 1024 * 1024) {
        return;
      }
      image = await boundary.toImage(pixelRatio: ratio);
      await _trace(token, 12);
      pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      await _trace(token, 13);
      if (!mounted ||
          !widget.enabled ||
          generation != _generation ||
          pixels == null) {
        return;
      }
      await _channel.invokeMethod<void>('present', {
        'token': token,
        'width': image.width,
        'height': image.height,
        'rgba': pixels.buffer.asUint8List(
          pixels.offsetInBytes,
          pixels.lengthInBytes,
        ),
      });
    } on MissingPluginException {
      // The native watchdog always completes the original window action.
    } on PlatformException {
      // Keep the same fallback when the compositor rejects the surface.
    } catch (_) {
      await _trace(token, 19);
      // A resize or retiring render surface can invalidate this one frame.
    } finally {
      pixels?.buffer
          .asUint8List(pixels.offsetInBytes, pixels.lengthInBytes)
          .fillRange(0, pixels.lengthInBytes, 0);
      image?.dispose();
    }
  }

  void _stopAttention() {
    _attention.stop();
    _attention.value = 0;
  }

  @override
  void dispose() {
    ++_generation;
    _stopAttention();
    _attention.dispose();
    // Account changes can mount the successor before retiring this state.
    if (identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
      unawaited(_configure(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: _busy,
    child: Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _surface, child: widget.child),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _AttentionPainter(
                animation: _attention,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AttentionPainter extends CustomPainter {
  _AttentionPainter({required this.animation, required this.color})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value;
    if (progress <= 0 || progress >= 1) return;
    canvas.drawCircle(
      size.center(Offset.zero),
      size.longestSide * .72 * progress,
      Paint()
        ..color = color.withValues(alpha: math.sin(progress * math.pi) * .16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * (1 - progress) + 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _AttentionPainter oldDelegate) =>
      oldDelegate.animation != animation || oldDelegate.color != color;
}
