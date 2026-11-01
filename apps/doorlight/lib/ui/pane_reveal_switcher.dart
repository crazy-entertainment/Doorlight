import 'package:flutter/material.dart';

import 'sybl_ui.dart';
import 'pane_activity.dart';

/// Pages keep their full layout and share the existing backdrop. At every
/// horizontal position only one page paints, so text/composers never ghost.
class PaneRevealSwitcher extends StatefulWidget {
  const PaneRevealSwitcher({super.key, required this.child});
  final Widget child;

  @override
  State<PaneRevealSwitcher> createState() => _PaneRevealSwitcherState();
}

class _Page {
  _Page(this.child, this.revealed);
  final key = UniqueKey();
  Widget child;
  double revealed;
}

class _PaneRevealSwitcherState extends State<PaneRevealSwitcher>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  )..addStatusListener(_finished);
  late _Page _current = _Page(widget.child, 1);
  final _previous = <_Page>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = SyblMotion.duration(
      context,
      const Duration(milliseconds: 220),
    );
    if (_controller.duration == Duration.zero) _controller.value = 1;
  }

  @override
  void didUpdateWidget(PaneRevealSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Widget.canUpdate(_current.child, widget.child)) {
      _current.child = widget.child;
      return;
    }
    _current.revealed = Curves.easeOutCubic.transform(_controller.value);
    _previous.add(_current);
    // Retain only pages that still own a visible strip on interruption.
    var covered = 0.0;
    for (final page in _previous.reversed.toList()) {
      if (page.revealed <= covered) {
        _previous.remove(page);
      } else {
        covered = page.revealed;
      }
    }
    _current = _Page(widget.child, 0);
    if (_controller.duration == Duration.zero) {
      _previous.clear();
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  void _finished(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous.isNotEmpty) {
      setState(_previous.clear);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parentActive = PaneActivityScope.isActive(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        final progress = Curves.easeOutCubic.transform(_controller.value);
        _current.revealed = progress;
        var covered = progress;
        final clips = <_Page, (double, double)>{};
        for (final page in _previous.reversed) {
          final end = page.revealed > covered ? page.revealed : covered;
          clips[page] = (covered, end);
          covered = end;
        }
        Widget layer(_Page page, double start, double end, bool outgoing) =>
            ClipRect(
              key: page.key,
              clipper: _PageStrip(start, end),
              child: PaneActivityScope(
                active: parentActive && !outgoing && progress == 1,
                child: IgnorePointer(
                  ignoring: !parentActive || outgoing || progress < 1,
                  child: ExcludeFocus(
                    excluding: !parentActive || outgoing || progress < 1,
                    child: ExcludeSemantics(
                      excluding: !parentActive || outgoing || progress < 1,
                      child: TickerMode(
                        enabled: parentActive && !outgoing,
                        child: page.child,
                      ),
                    ),
                  ),
                ),
              ),
            );
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final page in _previous)
              layer(page, clips[page]!.$1, clips[page]!.$2, true),
            layer(_current, 0, progress, false),
          ],
        );
      },
    );
  }
}

class _PageStrip extends CustomClipper<Rect> {
  const _PageStrip(this.start, this.end);
  final double start;
  final double end;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(size.width * start, 0, size.width * end, size.height);

  @override
  bool shouldReclip(covariant _PageStrip old) =>
      start != old.start || end != old.end;
}
