import 'package:flutter/material.dart';

/// An unobtrusive pointer, touch and keyboard target for optional discoveries.
class PlayfulTap extends StatefulWidget {
  const PlayfulTap({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;

  @override
  State<PlayfulTap> createState() => _PlayfulTapState();
}

class _PlayfulTapState extends State<PlayfulTap> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    enabled: widget.onTap != null,
    onShowFocusHighlight: (value) => setState(() => _focused = value),
    mouseCursor: SystemMouseCursors.basic,
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onTap?.call();
          return null;
        },
      ),
    },
    child: Semantics(
      button: widget.onTap != null,
      label: widget.onTap == null ? null : widget.label,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: _focused && widget.onTap != null
                ? Border.all(color: Theme.of(context).colorScheme.primary)
                : null,
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}
