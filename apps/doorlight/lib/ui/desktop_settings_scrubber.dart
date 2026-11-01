import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';

/// Desktop settings navigation. Geometry is measured from the content rather
/// than a second list of settings, including conditional and expanded rows.
class DesktopSettingsScrubber extends StatefulWidget {
  const DesktopSettingsScrubber({
    super.key,
    required this.controller,
    required this.sectionKeys,
    required this.viewportKey,
    required this.animationsEnabled,
  });

  final ScrollController controller;
  final List<GlobalKey> sectionKeys;
  final GlobalKey viewportKey;
  final bool animationsEnabled;

  @override
  State<DesktopSettingsScrubber> createState() =>
      DesktopSettingsScrubberState();
}

class DesktopSettingsScrubberState extends State<DesktopSettingsScrubber>
    with TickerProviderStateMixin {
  static const sections = [
    ('profile', 'Profile', Icons.person_outline_rounded),
    ('appearance', 'Appearance', Icons.palette_outlined),
    ('notifications', 'Notifications', Icons.notifications_none_rounded),
    ('voice', 'Calls', Icons.mic_none_rounded),
    ('connection', 'Network', Icons.wifi_rounded),
    ('files', 'Files & Storage', Icons.folder_outlined),
    ('safety', 'Privacy & Security', Icons.shield_outlined),
    ('advanced', 'Advanced', Icons.tune_rounded),
  ];
  static const _settle = Duration(milliseconds: 180);
  final _railKey = GlobalKey();
  late final AnimationController _layout;
  late final AnimationController _dots;
  late final Ticker _wheel;
  List<double> _from = [], _to = [], _starts = List.filled(8, 0);
  List<double> _lengths = List.filled(7, 1);
  double _span = 420, _progress = 0, _wheelTarget = 0, _wheelPosition = 0;
  double _idleGap = 48;
  Duration _wheelTime = Duration.zero;
  int _active = 0;
  bool _expanded = false, _measuring = false;
  _ScrubDrag? _drag;
  Timer? _idle, _pinTimer;

  double get _maximum => widget.controller.hasClients
      ? widget.controller.position.maxScrollExtent
      : 0;
  double get _top => 28;
  double get _bottom => _top + _span;
  double _clampY(double y) => y.clamp(_top, _bottom);
  double _ease(double t) => t * t * (3 - 2 * t);
  Duration _duration(Duration value) =>
      widget.animationsEnabled ? value : Duration.zero;

  List<double> get _positions {
    if (_to.isEmpty) return _restPositions();
    final t = const Cubic(.2, .8, .2, 1).transform(_layout.value);
    return List.generate(8, (i) => lerpDouble(_from[i], _to[i], t)!);
  }

  List<double> _restPositions() {
    final gap = math.min(_idleGap, _span / 7);
    final start = _top + (_span - gap * 7) / 2;
    return List.generate(8, (i) => start + i * gap);
  }

  @override
  void initState() {
    super.initState();
    _layout = AnimationController(vsync: this, duration: _settle)
      ..addListener(_repaint)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finishHandoff();
      });
    _dots = AnimationController(vsync: this)..addListener(_repaint);
    _wheel = createTicker(_wheelTick);
    widget.controller.addListener(_scrolled);
    _queueMeasure();
  }

  @override
  void didUpdateWidget(covariant DesktopSettingsScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    _queueMeasure();
  }

  void _queueMeasure() {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted || !widget.controller.hasClients) return;
      final viewport = widget.viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox) return;
      final origin = viewport.localToGlobal(Offset.zero).dy + 24;
      final offset = widget.controller.offset;
      final starts = <double>[];
      for (final key in widget.sectionKeys) {
        final box = key.currentContext?.findRenderObject();
        if (box is! RenderBox) return;
        starts.add(
          (box.localToGlobal(Offset.zero).dy - origin + offset).clamp(
            0.0,
            _maximum,
          ),
        );
      }
      final lengths = List.generate(
        7,
        (i) => math.max(1.0, starts[i + 1] - starts[i]),
      );
      final changed = List.generate(
        8,
        (i) => (_starts[i] - starts[i]).abs(),
      ).any((difference) => difference > .5);
      _starts = starts;
      _lengths = lengths;
      if (changed) {
        _readPosition();
        _relayout();
        _repaint();
      }
    });
  }

  void refreshMetrics() => _queueMeasure();

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _readPosition({bool preferPrevious = false}) {
    if (!widget.controller.hasClients) return;
    final offset = widget.controller.offset;
    _active = 0;
    for (var i = 0; i < 8; i++) {
      final reverseBoundary =
          preferPrevious && i > 0 && (offset - _starts[i]).abs() < .5;
      if (offset >= _starts[i] - .5 && !reverseBoundary) _active = i;
    }
    if (_maximum > 0 &&
        offset >= _maximum - 1 &&
        !(preferPrevious && (offset - _starts[7]).abs() < .5)) {
      _active = 7;
    }
    final end = _active < 7 ? _starts[_active + 1] : _maximum;
    _progress =
        ((offset - _starts[_active]) / math.max(1.0, end - _starts[_active]))
            .clamp(0.0, 1.0);
    if (_maximum > 0 && offset >= _maximum - 1) _progress = 1;
  }

  void _scrolled() {
    if (_drag != null) return;
    final previous = _active;
    _readPosition();
    _reveal();
    if (_active != previous) _relayout();
    _repaint();
  }

  double _relative(int index) {
    final shortest = _lengths.reduce(math.min);
    final longest = _lengths.reduce(math.max);
    return ((_lengths[index] - shortest) / math.max(1.0, longest - shortest))
        .clamp(0.0, 1.0);
  }

  List<double> _targets() {
    if (!_expanded || _active == 7) {
      return _restPositions();
    }
    // At short desktop sizes, reserve every icon before allocating expansion.
    final reserve = math.min(48.0, math.max(40.0, (_span - 80) / 6));
    var gap = math.min(_span - 6 * reserve, 80 + _relative(_active) * 76);
    final pin = _drag?.pin;
    final up = pin?.$1 == _active + 1;
    if (pin != null) {
      final available = up
          ? pin.$2 - _top - _active * 40
          : _bottom - pin.$2 - (6 - _active) * 40;
      gap = math.min(gap, math.max(40.0, available));
    }
    final contextGap = (_span - gap) / 6;
    final start = pin == null
        ? _top + _active * contextGap
        : up
        ? pin.$2 - gap
        : pin.$2;
    final end = start + gap;
    return List.generate(
      8,
      (i) => i <= _active
          ? (_active == 0 ? start : _top + (start - _top) * i / _active)
          : (i == 7
                ? _bottom
                : end + (_bottom - end) * (i - _active - 1) / (6 - _active)),
    );
  }

  void _relayout() {
    _from = _positions;
    _to = _targets();
    _layout.duration = _duration(_settle);
    if (_layout.duration == Duration.zero) {
      _layout.value = 1;
      _finishHandoff();
    } else {
      _layout.forward(from: 0);
    }
  }

  void _reveal() {
    _idle?.cancel();
    if (!_expanded) {
      _expanded = true;
      _relayout();
    }
    _dots.animateTo(1, duration: _duration(const Duration(milliseconds: 160)));
    if (_drag != null) return;
    _idle = Timer(const Duration(milliseconds: 450), () {
      _dots.animateTo(
        0,
        duration: _duration(const Duration(milliseconds: 180)),
        curve: Curves.easeInOut,
      );
      if (!mounted || _drag != null) return;
      _expanded = false;
      _relayout();
    });
  }

  /// Register with Flutter's signal resolver so the underlying Scrollable does
  /// not also apply the wheel delta. Touch/trackpad gestures retain native input.
  void handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_drag != null || !widget.controller.hasClients) return;
      if (!widget.animationsEnabled) {
        widget.controller.jumpTo(
          (widget.controller.offset + event.scrollDelta.dy).clamp(
            0.0,
            _maximum,
          ),
        );
        return;
      }
      _wheelTarget =
          ((_wheel.isActive ? _wheelTarget : widget.controller.offset) +
                  event.scrollDelta.dy)
              .clamp(0.0, _maximum);
      if (!_wheel.isActive) {
        _wheelPosition = widget.controller.offset;
        _wheelTime = Duration.zero;
        _wheel.start();
      }
    });
  }

  void _wheelTick(Duration time) {
    final elapsed = _wheelTime == Duration.zero
        ? 16.0
        : (time - _wheelTime).inMicroseconds / 1000;
    _wheelTime = time;
    final distance = _wheelTarget - _wheelPosition;
    if (distance.abs() < .5) {
      _wheel.stop();
      widget.controller.jumpTo(_wheelTarget.clamp(0.0, _maximum));
    } else {
      _wheelPosition += distance * (1 - math.exp(-math.min(40, elapsed) / 65));
      widget.controller.jumpTo(_wheelPosition.clamp(0.0, _maximum));
    }
  }

  void stopWheel() => _wheel.stop();
  double _localY(PointerEvent event) {
    final box = _railKey.currentContext!.findRenderObject()! as RenderBox;
    return box.globalToLocal(event.position).dy;
  }

  void _start(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    stopWheel();
    final y = _clampY(_localY(event)), positions = _positions;
    var nearest = 0;
    for (var i = 1; i < 8; i++) {
      if ((positions[i] - y).abs() < (positions[nearest] - y).abs()) {
        nearest = i;
      }
    }
    final index = (positions[nearest] - y).abs() <= 24
        ? nearest
        : positions.lastIndexWhere((point) => point <= y).clamp(0, 7);
    if (index != _active) {
      _active = index;
      _progress = 0;
      _scrub();
    }
    _drag = _ScrubDrag(event.pointer, _localY(event), y, _progress, (
      index,
      positions[index],
    ));
    _reveal();
    _relayout();
    _handoff();
    _repaint();
  }

  void _handoff() {
    _pinTimer?.cancel();
    final session = _drag!;
    session.checkpoint = session.pin!.$1;
    session.handoff = true;
    _pinTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted || _drag != session) return;
      session.pin = null;
      _relayout();
    });
  }

  void _finishHandoff() {
    final drag = _drag;
    if (drag == null || drag.pin != null || !drag.handoff) return;
    drag.entryY = drag.y;
    drag.entryProgress = _progress;
    drag.handoff = false;
  }

  void _move(PointerMoveEvent event) {
    final drag = _drag;
    if (drag == null || event.pointer != drag.pointer) return;
    final client = _localY(event), movement = client - drag.lastClient;
    if (movement == 0) return;
    drag.movingUp = movement < 0;
    drag.lastClient = client;
    drag.y = _clampY(drag.originY + client - drag.originClient);
    final positions = _positions;
    if (drag.handoff) {
      final end = positions[math.min(_active + 1, 7)];
      _progress =
          (_progress + movement / math.max(44.0, end - positions[_active]))
              .clamp(0.0, 1.0);
      drag.entryY = drag.y;
      drag.entryProgress = _progress;
    } else {
      // Expansion can move a captured checkpoint away from the pointer. Keep
      // that entry boundary reachable from its captured position, while the
      // pointer/dot and all other checkpoints retain their screen geometry.
      final forwardBoundary = drag.checkpoint == _active + 1
          ? math.min(positions[math.min(_active + 1, 7)], drag.entryY)
          : positions[math.min(_active + 1, 7)];
      final backwardBoundary = drag.checkpoint == _active
          ? math.max(positions[_active], drag.entryY)
          : positions[_active];
      final forward = movement > 0 && _active < 7 && drag.y >= forwardBoundary;
      final backward = movement < 0 && _active > 0 && drag.y < backwardBoundary;
      if (forward || backward) {
        final checkpoint = forward ? _active + 1 : _active;
        drag.pin = (checkpoint, positions[checkpoint]);
        _active += forward ? 1 : -1;
        _progress = forward ? 0 : 1;
        drag.entryY = drag.y;
        drag.entryProgress = _progress;
        _relayout();
        _handoff();
      } else {
        final p = drag.entryProgress;
        _progress =
            (drag.y >= drag.entryY
                    ? p +
                          (drag.y - drag.entryY) /
                              math.max(
                                1.0,
                                positions[math.min(_active + 1, 7)] -
                                    drag.entryY,
                              ) *
                              (1 - p)
                    : p -
                          (drag.entryY - drag.y) /
                              math.max(1.0, drag.entryY - positions[_active]) *
                              p)
                .clamp(0.0, 1.0);
      }
    }
    _scrub();
    _repaint();
  }

  void _scrub() {
    if (!widget.controller.hasClients) return;
    final start = _starts[_active];
    final end = _active < 7 ? _starts[_active + 1] : _maximum;
    widget.controller.jumpTo(
      (start + _progress * (end - start)).clamp(0.0, _maximum),
    );
  }

  void _release(PointerEvent event) {
    if (_drag?.pointer != event.pointer) return;
    final movingUp = _drag!.movingUp;
    _pinTimer?.cancel();
    _drag = null;
    _readPosition(preferPrevious: movingUp);
    _relayout();
    _reveal();
    _repaint();
  }

  void _select(int index) {
    if (_drag != null || !widget.controller.hasClients) return;
    stopWheel();
    if (!widget.animationsEnabled) {
      widget.controller.jumpTo(_starts[index]);
      return;
    }
    widget.controller.animateTo(
      _starts[index],
      duration: _duration(const Duration(milliseconds: 320)),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final gap = math.min(
        (constraints.maxHeight - 56) / 7,
        (constraints.maxHeight * .092).clamp(60.0, 72.0),
      );
      final span = math.max(280.0, gap * 7);
      final idleGap = (constraints.maxHeight * .075).clamp(48.0, 56.0);
      if ((_span - span).abs() > .5 || (_idleGap - idleGap).abs() > .5) {
        _span = span;
        _idleGap = idleGap;
        _from = _to = _targets();
        _queueMeasure();
      }
      final positions = _positions, colors = context.syblColors;
      final blend = _ease(_expanded && _active < 7 ? _progress : 0);
      final drag = _drag;
      final distance = drag == null
          ? 0.0
          : positions.map((y) => (y - drag.y).abs()).reduce(math.min);
      final dragOpacity = drag == null
          ? 0.0
          : _ease(((distance - 26) / 16).clamp(0.0, 1.0));
      return Center(
        child: SizedBox(
          key: _railKey,
          width: 56,
          height: _span + 56,
          child: MouseRegion(
            cursor: drag == null
                ? SystemMouseCursors.grab
                : SystemMouseCursors.grabbing,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _start,
              onPointerMove: _move,
              onPointerUp: _release,
              onPointerCancel: _release,
              onPointerSignal: handlePointerSignal,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: positions.first - 28,
                    left: 0,
                    right: 0,
                    height: positions.last - positions.first + 56,
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: ColoredBox(
                            color: colors.desk.withValues(
                              alpha: drag == null ? .72 : .84,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < 7; i++) _buildDots(i, positions, colors),
                  for (var i = 0; i < 8; i++)
                    Positioned(
                      top: positions[i] - 24,
                      left: 4,
                      width: 48,
                      height: 48,
                      child: Semantics(
                        selected: i == _active,
                        child: Center(
                          child: AnimatedContainer(
                            key: ValueKey(
                              'settings-jump-active-${sections[i].$2}',
                            ),
                            duration: _duration(
                              const Duration(milliseconds: 90),
                            ),
                            curve: Curves.linear,
                            width: i == _active
                                ? 48 - 8 * blend
                                : i == _active + 1
                                ? 40 + 8 * blend
                                : 40,
                            height: i == _active
                                ? 48 - 8 * blend
                                : i == _active + 1
                                ? 40 + 8 * blend
                                : 40,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              color: i == _active
                                  ? Color.alphaBlend(
                                      colors.amber.withValues(alpha: .10),
                                      colors.surface,
                                    )
                                  : colors.surface,
                              border: Border.all(color: colors.lineStrong),
                            ),
                            child: OverflowBox(
                              minWidth: 48,
                              maxWidth: 48,
                              minHeight: 48,
                              maxHeight: 48,
                              child: IconButton(
                                key: ValueKey(
                                  'settings-jump-${sections[i].$1}',
                                ),
                                tooltip: sections[i].$2,
                                onPressed: () => _select(i),
                                padding: EdgeInsets.zero,
                                iconSize: 20,
                                icon: Icon(
                                  sections[i].$3,
                                  color: i == _active
                                      ? colors.amber
                                      : colors.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (drag != null)
                    Positioned(
                      top: drag.y - 6,
                      left: 22,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: dragOpacity,
                          child: Container(
                            key: const ValueKey('settings-drag-dot'),
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.amber,
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x24000000),
                                  blurRadius: 5,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: (drag?.y ?? positions[_active]) - 13,
                    right: 67,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: drag == null ? 0 : 1,
                        duration: _duration(const Duration(milliseconds: 120)),
                        child: Container(
                          key: const ValueKey('settings-scroll-section-label'),
                          constraints: const BoxConstraints(maxWidth: 180),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colors.bg,
                            border: Border.all(color: colors.lineStrong),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            sections[_active].$2,
                            style: TextStyle(fontSize: 11, color: colors.ink),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Semantics(
                        container: true,
                        key: const ValueKey('settings-section-progress'),
                        label: '${sections[_active].$2}, remaining',
                        value: '${((1 - _progress) * 100).round()}',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _buildDots(int index, List<double> positions, SyblColors colors) {
    final height = positions[index + 1] - positions[index] - 58;
    final count = 3 + (4 * _relative(index)).round();
    final visible = _expanded && index == _active && height >= 20;
    final offset = widget.controller.hasClients
        ? widget.controller.offset
        : 0.0;
    final sectionProgress = index == _active
        ? _progress
        : ((offset - _starts[index]) /
                  math.max(1.0, _starts[index + 1] - _starts[index]))
              .clamp(0.0, 1.0);
    final focus = sectionProgress * (count - 1);
    final scale = MediaQuery.devicePixelRatioOf(context);
    final baseSize = math.max(1.6, 2 / scale);
    double pixelAligned(double value) => (value * scale).round() / scale;
    // One field fade keeps the dots in the same compositing space. Give the
    // smallest dots two physical pixels and the same pixel phase, so identical
    // dots cannot alternate between a bright pixel and several dim fragments.
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: _duration(const Duration(milliseconds: 160)),
          opacity: visible ? 1 : 0,
          child: Opacity(
            opacity: _dots.value,
            child: Stack(
              children: List.generate(count, (j) {
                final distance = (j - focus).abs();
                final weight = math.exp(-.5 * math.pow(distance / .65, 2));
                final size = baseSize + 3.6 * weight;
                final alpha =
                    .55 + .45 * math.exp(-.5 * math.pow(distance / .9, 2));
                final y =
                    positions[index] +
                    33 +
                    j / (count - 1) * math.max(0.0, height - 6);
                return Positioned(
                  top: pixelAligned(y) - size / 2,
                  left: pixelAligned(28) - size / 2,
                  width: size,
                  height: size,
                  child: Container(
                    key: ValueKey('settings-section-dot-$index-$j'),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.lerp(
                        colors.muted,
                        colors.amber,
                        weight,
                      )!.withValues(alpha: alpha),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrolled);
    _idle?.cancel();
    _pinTimer?.cancel();
    _wheel.dispose();
    _layout.dispose();
    _dots.dispose();
    super.dispose();
  }
}

class _ScrubDrag {
  _ScrubDrag(
    this.pointer,
    this.originClient,
    this.originY,
    this.entryProgress,
    this.pin,
  ) : lastClient = originClient,
      y = originY,
      entryY = originY;
  final int pointer;
  final double originClient, originY;
  double lastClient, y, entryY, entryProgress;
  (int, double)? pin;
  bool handoff = false;
  bool movingUp = false;
  int checkpoint = 0;
}
