import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'sybl_ui.dart';
import 'pane_activity.dart';
import 'window_presentation.dart';

/// One live tree across window sizes. Hidden panes retain their scroll/drafts,
/// but cannot paint, tick, take focus, or expose accessibility actions.
class WindowsPaneLayout extends StatefulWidget {
  const WindowsPaneLayout({
    super.key,
    required this.compact,
    required this.showPeople,
    required this.railWidth,
    required this.rail,
    required this.pane,
    required this.divider,
    this.adaptiveResize = false,
  });
  final bool compact;
  final bool showPeople;
  final double railWidth;
  final Widget rail;
  final Widget pane;
  final Widget divider;
  final bool adaptiveResize;

  @override
  State<WindowsPaneLayout> createState() => _WindowsPaneLayoutState();
}

class _WindowsPaneLayoutState extends State<WindowsPaneLayout> {
  double _peopleWidth = 320;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: widget.compact ? 1 : 0, end: widget.compact ? 1 : 0),
    duration: SyblMotion.duration(
      context,
      WindowPresentation.animationDuration,
    ),
    curve: WindowPresentation.animationCurve,
    builder: (context, progress, _) => TweenAnimationBuilder<double>(
      tween: Tween(end: widget.railWidth),
      duration: SyblMotion.duration(context, const Duration(milliseconds: 280)),
      curve: Curves.easeOutCubic,
      builder: (context, wideRailWidth, _) => TweenAnimationBuilder<double>(
        tween: Tween(
          begin: widget.showPeople ? 0 : 1,
          end: widget.showPeople ? 0 : 1,
        ),
        duration: SyblMotion.duration(
          context,
          WindowPresentation.animationDuration,
        ),
        curve: WindowPresentation.animationCurve,
        builder: (context, focus, _) => LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            if (progress == 1) _peopleWidth = width;
            final peopleWidth = widget.adaptiveResize ? width : _peopleWidth;
            final railWidth = lerpDouble(
              wideRailWidth,
              peopleWidth,
              progress * (1 - focus),
            )!;
            final railLeft = -wideRailWidth * progress * focus;
            final dividerWidth = 1 - progress;
            final paneLeft = railLeft + railWidth + dividerWidth;
            // The outgoing pane slides under the window edge instead of being
            // crushed into a narrow column before it leaves the screen.
            final paneWidth = math.max(
              width - paneLeft,
              math.min(320.0, width),
            );
            final railHidden = progress == 1 && focus == 1;
            final paneHidden = progress == 1 && focus == 0;
            final moving =
                (progress > 0 && progress < 1) ||
                (progress > 0 && focus > 0 && focus < 1);
            Widget activePane(Widget child, bool hidden, bool active) =>
                PaneActivityScope(
                  active: active,
                  child: Offstage(
                    offstage: hidden,
                    child: TickerMode(
                      enabled: !hidden,
                      child: ExcludeFocus(
                        excluding: !active,
                        child: ExcludeSemantics(
                          excluding: !active,
                          child: IgnorePointer(
                            ignoring: moving || !active,
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
            return ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: railLeft,
                    top: 0,
                    bottom: 0,
                    width: railWidth,
                    child: activePane(
                      widget.rail,
                      railHidden,
                      !widget.compact || widget.showPeople,
                    ),
                  ),
                  Positioned(
                    left: railLeft + railWidth,
                    top: 0,
                    bottom: 0,
                    width: dividerWidth,
                    child: Offstage(
                      offstage: progress == 1,
                      child: ExcludeSemantics(child: widget.divider),
                    ),
                  ),
                  Positioned(
                    left: paneLeft,
                    top: 0,
                    bottom: 0,
                    width: paneWidth,
                    child: activePane(
                      widget.pane,
                      paneHidden,
                      !widget.compact || !widget.showPeople,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
