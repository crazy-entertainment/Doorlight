import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared pointer/keyboard hold lifetime. Removing a call presentation releases
/// its hold just like pointer cancellation or focus loss.
class MicrophonePressTarget extends StatefulWidget {
  const MicrophonePressTarget({
    super.key,
    required this.pushToTalk,
    required this.onHold,
    required this.onToggle,
    required this.child,
    this.enabled = true,
  });
  final bool pushToTalk;
  final bool enabled;
  final ValueChanged<bool> onHold;
  final VoidCallback onToggle;
  final Widget child;
  @override
  State<MicrophonePressTarget> createState() => _MicrophonePressTargetState();
}

class _MicrophonePressTargetState extends State<MicrophonePressTarget> {
  bool _held = false;
  void _hold(bool down) {
    if (down && (!widget.enabled || !widget.pushToTalk)) return;
    if (_held == down) return;
    _held = down;
    widget.onHold(down);
  }

  @override
  void didUpdateWidget(MicrophonePressTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_held && (!widget.enabled || !widget.pushToTalk)) {
      _held = false;
      oldWidget.onHold(false);
    }
  }

  @override
  void dispose() {
    if (_held) widget.onHold(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (focused) {
      if (!focused) _hold(false);
    },
    onKeyEvent: (_, event) {
      if (event.logicalKey != LogicalKeyboardKey.space &&
          event.logicalKey != LogicalKeyboardKey.enter) {
        return KeyEventResult.ignored;
      }
      if (!widget.enabled) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        if (widget.pushToTalk) {
          _hold(true);
        } else {
          widget.onToggle();
        }
      } else if (event is KeyUpEvent) {
        _hold(false);
      }
      return KeyEventResult.handled;
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled && !widget.pushToTalk ? widget.onToggle : null,
      onTapDown: widget.enabled && widget.pushToTalk
          ? (_) => _hold(true)
          : null,
      onTapUp: (_) => _hold(false),
      onTapCancel: () => _hold(false),
      child: widget.child,
    ),
  );
}
