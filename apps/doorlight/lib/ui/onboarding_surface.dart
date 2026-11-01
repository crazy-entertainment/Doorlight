import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'gravity.dart';

class DoorKnockNotification extends Notification {
  const DoorKnockNotification(this.count);
  final int count;
}

/// One continuous light field shared by setup, app panes and window controls.
class OnboardingSurface extends StatefulWidget {
  const OnboardingSurface({
    super.key,
    required this.child,
    this.active = true,
    this.onWindowShake,
    this.reuseAncestor = true,
  });

  final Widget child;

  /// Enables the onboarding door-knock effects; lighting is always present.
  final bool active;
  final ValueChanged<bool>? onWindowShake;
  final bool reuseAncestor;

  static Widget anchorDoor(BuildContext context, GlobalKey key, Widget door) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SurfaceScope>();
    if (scope != null && !scope.doorAnchors.contains(key)) {
      scope.doorAnchors.add(key);
    }
    if (scope != null) scope.repaint.value++;
    return SizedBox(key: key, child: door);
  }

  @override
  State<OnboardingSurface> createState() => _OnboardingSurfaceState();
}

class _OnboardingSurfaceState extends State<OnboardingSurface>
    with SingleTickerProviderStateMixin {
  final _doorAnchors = <GlobalKey>[];
  final _surface = GlobalKey();
  final _repaint = ValueNotifier(0);
  late final AnimationController _shake;
  double _strength = 0;
  bool _windowShaking = false;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      value: 1,
    );
  }

  void _stopShake() {
    _shake.stop();
    _shake.value = 1;
    if (_windowShaking) widget.onWindowShake?.call(false);
    _windowShaking = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _stopShake();
  }

  @override
  void didUpdateWidget(OnboardingSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) _stopShake();
  }

  bool _knock(DoorKnockNotification knock) {
    if (!widget.active || MediaQuery.disableAnimationsOf(context)) return false;
    _strength = (knock.count * .7).clamp(0, 8);
    _shake.forward(from: 0);
    if (knock.count >= 8) {
      _windowShaking = true;
      widget.onWindowShake?.call(true);
    }
    return true;
  }

  @override
  void dispose() {
    _stopShake();
    _shake.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The desktop shell owns the full-window field; the screen also works
    // independently on mobile without painting a second, misaligned field.
    if (widget.reuseAncestor &&
        context.dependOnInheritedWidgetOfExactType<_SurfaceScope>() != null) {
      return widget.child;
    }
    final colors = context.syblColors;
    return _SurfaceScope(
      doorAnchors: _doorAnchors,
      repaint: _repaint,
      child: DecoratedBox(
        key: const ValueKey('onboarding-warm-surface'),
        decoration: BoxDecoration(color: colors.bg),
        child: CustomPaint(
          key: _surface,
          painter: _DoorGlowPainter(_doorAnchors, _surface, colors, _repaint),
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _repaint.value++;
              return false;
            },
            child: NotificationListener<DoorKnockNotification>(
              onNotification: _knock,
              child: AnimatedBuilder(
                animation: _shake,
                child: widget.child,
                builder: (context, child) => Transform.translate(
                  key: const ValueKey('onboarding-content-shake'),
                  offset: Offset(
                    math.sin(_shake.value * math.pi * 8) *
                        (1 - _shake.value) *
                        _strength,
                    0,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SurfaceScope extends InheritedWidget {
  const _SurfaceScope({
    required this.doorAnchors,
    required this.repaint,
    required super.child,
  });

  final List<GlobalKey> doorAnchors;
  final ValueNotifier<int> repaint;

  @override
  bool updateShouldNotify(_SurfaceScope oldWidget) => false;
}

class _DoorGlowPainter extends CustomPainter {
  _DoorGlowPainter(
    this.doorAnchors,
    this.surface,
    this.colors,
    Listenable repaint,
  ) : super(repaint: repaint);

  final List<GlobalKey> doorAnchors;
  final GlobalKey surface;
  final SyblColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    // Incoming and outgoing welcome pages can briefly coexist during a fade.
    doorAnchors.removeWhere((key) {
      final element = key.currentContext;
      return element is! RenderObjectElement || !element.renderObject.attached;
    });
    // Setup pages without the door retain the same warm, full-window surface.
    var center = Offset(size.width * .5, size.height * .3);
    if (doorAnchors.isNotEmpty) {
      final door =
          (doorAnchors.last.currentContext as RenderObjectElement).renderObject;
      final field = surface.currentContext?.findRenderObject();
      if (door is RenderBox && field is RenderBox && door.hasSize) {
        center = field.globalToLocal(
          door.localToGlobal(
            Offset(door.size.width * .495, door.size.height * .46),
          ),
        );
      }
    }
    // Keep the original window-sized light field; only its anchor changes.
    final gradient = colors.lightField(
      center: Alignment(
        center.dx * 2 / size.width - 1,
        center.dy * 2 / size.height - 1,
      ),
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = gradient.createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant _DoorGlowPainter oldDelegate) =>
      doorAnchors != oldDelegate.doorAnchors || colors != oldDelegate.colors;
}

/// A titled, bordered choice card shared by setup and Add a friend.
class SetupChoice extends StatelessWidget {
  const SetupChoice({
    super.key,
    required this.icon,
    required this.title,
    required this.onPressed,
    this.padding = const EdgeInsets.all(17),
  });
  final IconData icon;
  final EdgeInsets padding;
  final String title;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final phone =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    return Gravity(
      child: Material(
        color: onPressed == null
            ? context.syblColors.surface.withValues(alpha: .5)
            : context.syblColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              border: Border.all(color: context.syblColors.lineStrong),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(icon, color: context.syblColors.amber, size: 24),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: phone ? 17 : 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: context.syblColors.faint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
