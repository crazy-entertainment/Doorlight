import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

import 'doorlight_brand.dart';
import 'onboarding_surface.dart';
import 'playful_tap.dart';

class PlayfulDoor extends StatefulWidget {
  const PlayfulDoor({
    super.key,
    required this.size,
    required this.openness,
    required this.illumination,
    required this.thresholdPhase,
    this.interactive = true,
  });

  final double size;
  final double openness;
  final double illumination;
  final double thresholdPhase;
  final bool interactive;

  @override
  State<PlayfulDoor> createState() => _PlayfulDoorState();
}

class _PlayfulDoorState extends State<PlayfulDoor>
    with TickerProviderStateMixin {
  final _doorAnchor = GlobalKey();
  Timer? _knockCooldown;
  int _knocks = 0;
  double _fromOpenness = 1.4;
  double? _manualOpenness;
  Offset? _holdOrigin;
  Duration? _lastDragTime;
  static const _slamSpeed = 2200.0; // Logical pixels per second, rightward.
  static const _slamDistance = 60.0; // Ignore short cursor nudges.
  double _fastClosingDistance = 0;
  double _holdOpenness = 0;
  bool _pressedHandle = false;
  bool _pendingImpact = false;
  late final _return =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2200),
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _manualOpenness = null);
          _slam.value = 1;
        }
      });
  late final _slam = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
    value: 1,
  )..addListener(_onSlamFrame);

  void _onSlamFrame() {
    if (!_pendingImpact || _slam.value < .1) return;
    _pendingImpact = false;
    // Paint the closed pose before shaking either the content or native window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _manualOpenness != null ||
          _slam.value < .1 ||
          _slam.value >= .45) {
        return;
      }
      DoorKnockNotification(_knocks).dispatch(context);
    });
  }

  late final _light = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: .1), weight: 10),
    TweenSequenceItem(tween: Tween(begin: .1, end: .35), weight: 18),
    TweenSequenceItem(tween: Tween(begin: .35, end: .1), weight: 6),
    TweenSequenceItem(tween: Tween(begin: .1, end: .6), weight: 10),
    TweenSequenceItem(tween: Tween(begin: .6, end: .2), weight: 10),
    TweenSequenceItem(tween: Tween(begin: .2, end: 1), weight: 46),
  ]).animate(_slam);

  double get _openness {
    if (_manualOpenness != null) {
      return _holdOrigin != null
          ? _manualOpenness!
          : _manualOpenness! +
                (widget.openness - _manualOpenness!) *
                    Curves.easeInOutCubic.transform(_return.value);
    }
    final t = _slam.value;
    if (t < .1) {
      return _fromOpenness * (1 - Curves.easeInCubic.transform(t / .1));
    }
    if (t < .45) return 0;
    return widget.openness * Curves.easeOutCubic.transform((t - .45) / .55);
  }

  void _knock() {
    if (!widget.interactive) return;
    _fromOpenness = _openness;
    _return.stop();
    _manualOpenness = null;
    _holdOrigin = null;
    _knocks = math.min(12, _knocks + 1);
    _knockCooldown?.cancel();
    _knockCooldown = Timer(const Duration(seconds: 2), () => _knocks = 0);
    _pendingImpact = true;
    _slam.forward(from: 0);
  }

  void _handleDown(DragDownDetails details) {
    final angle = _openness;
    // Match the painted handle; leave the rest of the door as a click target.
    final handle =
        DoorlightDoorMark.handlePosition(angle) * (widget.size / 100) +
        Offset(widget.size * .2, 0);
    _pressedHandle =
        (details.localPosition - handle).distance <=
        math.max(12, widget.size * .06);
  }

  void _hold(DragStartDetails details) {
    if (!_pressedHandle) return;
    _lastDragTime = details.sourceTimeStamp;
    _fastClosingDistance = 0;
    final angle = _openness;
    _pendingImpact = false;
    _slam.stop();
    _return.stop();
    setState(() {
      _manualOpenness = angle;
      _holdOpenness = angle;
      _holdOrigin = details.globalPosition;
    });
  }

  void _moveHandle(DragUpdateDetails details) {
    final origin = _holdOrigin;
    if (origin == null) return;
    final time = details.sourceTimeStamp;
    final elapsed = time != null && _lastDragTime != null
        ? (time - _lastDragTime!).inMicroseconds / 1000000
        : 0.0;
    _lastDragTime = time;
    _fastClosingDistance =
        elapsed > 0 && details.delta.dx / elapsed >= _slamSpeed
        ? _fastClosingDistance + details.delta.dx
        : 0;
    if (_fastClosingDistance >= _slamDistance &&
        (_openness > 0 || _holdOpenness > 0)) {
      _knock();
      return;
    }
    setState(
      () => _manualOpenness =
          (_holdOpenness -
                  (details.globalPosition.dx - origin.dx) /
                      (widget.size * .4) *
                      1.4)
              .clamp(0.0, DoorlightDoorMark.maxOpenness),
    );
  }

  void _releaseHandle() {
    if (_holdOrigin == null) return;
    _holdOrigin = null;
    _return.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pendingImpact = false;
      _slam.stop();
      _return.stop();
      _slam.value = 1;
      _knockCooldown?.cancel();
      _knocks = 0;
      _manualOpenness = null;
      _holdOrigin = null;
    }
  }

  @override
  void dispose() {
    _knockCooldown?.cancel();
    _slam.dispose();
    _return.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final interactive =
        widget.interactive && !MediaQuery.disableAnimationsOf(context);
    return GestureDetector(
      excludeFromSemantics: true,
      dragStartBehavior: DragStartBehavior.down,
      onPanDown: interactive ? _handleDown : null,
      onPanStart: interactive ? _hold : null,
      onPanUpdate: interactive ? _moveHandle : null,
      onPanEnd: interactive ? (_) => _releaseHandle() : null,
      onPanCancel: interactive ? _releaseHandle : null,
      child: PlayfulTap(
        label:
            'Click to slam the door. Drag the handle left to open or right to close; move right quickly to slam.',
        onTap: interactive && widget.openness > 0 ? _knock : null,
        child: SizedBox(
          width: widget.size * 1.4,
          height: widget.size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: widget.size * .2,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_slam, _return]),
                  builder: (context, _) {
                    final t = _slam.value;
                    final impact = _manualOpenness == null && t > .1 && t < .22
                        ? math.sin((t - .1) * 160) * (1 - (t - .1) / .12) * 2
                        : 0.0;
                    return Transform.translate(
                      offset: Offset(impact, 0),
                      child: OnboardingSurface.anchorDoor(
                        context,
                        _doorAnchor,
                        DoorlightDoorMark(
                          key: const ValueKey('onboarding-door-mark'),
                          size: widget.size,
                          openness: _openness,
                          illumination:
                              widget.illumination *
                              (_manualOpenness == null
                                  ? _light.value
                                  : (_openness / 1.4).clamp(0.0, 1.0)),
                          thresholdPhase: widget.thresholdPhase,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
