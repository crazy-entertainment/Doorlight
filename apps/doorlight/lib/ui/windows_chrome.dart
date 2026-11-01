import 'dart:async';

import 'package:flutter/material.dart';

import '../core/jami.dart';
import '../state/app_settings.dart';
import '../theme.dart';
import 'gravity.dart';
import 'window_presentation.dart';
import 'onboarding_surface.dart';
import 'sybl_ui.dart';
import 'window_dismiss.dart';

/// Doorlight's Windows-only title bar. Win32 still owns moving, snapping,
/// resizing, maximizing, minimizing, and close-to-tray.
class WindowsChrome extends StatefulWidget {
  const WindowsChrome({
    super.key,
    required this.jami,
    required this.child,
    this.compactContentAvailable = false,
    this.onboarding = false,
    this.renderControls = true,
    this.rememberDefaultWindowPosition = false,
    this.windowEdgeSpacing = WindowEdgeSpacing.close,
    this.dismissAnimationsEnabled = true,
    this.openAnimation = WindowCloseAnimation.tray,
    this.minimizeAnimation = WindowCloseAnimation.tray,
    this.closeAnimation = WindowCloseAnimation.tray,
    this.openDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    this.minimizeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    this.closeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
  });

  static const height = 34.0;

  static double normalTitleBarLeft(double width) =>
      width < SyblLayout.desktopBreakpoint ? 0 : SyblLayout.railWidth;

  final JamiClient jami;
  final Widget child;
  final bool compactContentAvailable;
  final bool onboarding;
  final bool renderControls;
  final bool rememberDefaultWindowPosition;
  final WindowEdgeSpacing windowEdgeSpacing;
  final bool dismissAnimationsEnabled;
  final WindowCloseAnimation openAnimation;
  final WindowCloseAnimation minimizeAnimation;
  final WindowCloseAnimation closeAnimation;
  final int openDurationMs;
  final int minimizeDurationMs;
  final int closeDurationMs;

  @override
  State<WindowsChrome> createState() => _WindowsChromeState();
}

class _WindowsChromeState extends State<WindowsChrome> {
  late final WindowPresentation presentation = WindowPresentation(
    widget.jami,
    rememberDefaultWindowPosition: widget.rememberDefaultWindowPosition,
    edgeSpacing: widget.windowEdgeSpacing,
  );

  @override
  void didUpdateWidget(covariant WindowsChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    presentation.rememberDefaultWindowPosition =
        widget.rememberDefaultWindowPosition;
    if (oldWidget.windowEdgeSpacing != widget.windowEdgeSpacing) {
      unawaited(
        presentation.setEdgeSpacing(
          widget.windowEdgeSpacing,
          reposition: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    presentation.dispose();
    super.dispose();
  }

  void _command(String command) =>
      unawaited(widget.jami.windowCommand(command));

  @override
  Widget build(BuildContext context) => WindowDismiss(
    enabled: widget.dismissAnimationsEnabled,
    openAnimation: widget.openAnimation,
    minimizeAnimation: widget.minimizeAnimation,
    closeAnimation: widget.closeAnimation,
    openDurationMs: widget.openDurationMs,
    minimizeDurationMs: widget.minimizeDurationMs,
    closeDurationMs: widget.closeDurationMs,
    child: OnboardingSurface(
      active: widget.onboarding,
      onWindowShake: (active) => _command(active ? 'shake' : 'stopShake'),
      child: Builder(builder: _buildChrome),
    ),
  );

  Widget _buildChrome(BuildContext context) {
    return WindowPresentationScope(
      controller: presentation,
      child: Overlay.wrap(
        child: widget.renderControls
            ? WindowsChromeContent(
                onboarding: widget.onboarding,
                compactContentAvailable: widget.compactContentAvailable,
                child: widget.child,
              )
            : widget.child,
      ),
    );
  }
}

/// Window controls belong to the page, below its Navigator's modal barriers.
class WindowsChromeContent extends StatelessWidget {
  const WindowsChromeContent({
    super.key,
    required this.child,
    this.onboarding = false,
    this.compactContentAvailable = false,
    this.leading,
  });
  final Widget child;
  final bool onboarding;
  final bool compactContentAvailable;

  /// Sits left of the window mode buttons, e.g. the notification bell.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final presentation = WindowPresentationScope.maybeOf(context);
    if (presentation == null) return child;
    final titleBarLeft = onboarding
        ? 0.0
        : WindowsChrome.normalTitleBarLeft(MediaQuery.sizeOf(context).width);
    final minimizeButton = _WindowButton(
      key: const ValueKey('windows-minimize-button'),
      label: 'Minimize',
      icon: Icons.horizontal_rule_rounded,
      onPressed: () => presentation.command('minimize'),
    );
    final controls = SizedBox(
      key: const ValueKey('windows-title-bar'),
      height: WindowsChrome.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Colors.transparent),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label: 'Doorlight window title bar',
                child: GestureDetector(
                  key: const ValueKey('windows-title-drag-region'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => presentation.command('drag'),
                  onDoubleTap: () => presentation.command('toggleMaximize'),
                  onSecondaryTapUp: (_) => presentation.command('systemMenu'),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            if (!onboarding && leading != null) leading!,
            if (onboarding)
              minimizeButton
            else
              WindowModeButtons(
                minimizeButton: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: minimizeButton,
                ),
              ),
            _WindowButton(
              key: const ValueKey('windows-close-button'),
              label: 'Close',
              icon: Icons.close_rounded,
              danger: true,
              onPressed: () => presentation.command('close'),
            ),
            const SizedBox(width: 3),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              if (!onboarding &&
                  presentation.compact &&
                  !compactContentAvailable)
                const CompactHeader(title: 'Doorlight'),
              Expanded(
                key: const ValueKey('windows-page-content'),
                child: Padding(
                  padding: EdgeInsets.only(
                    top: onboarding ? WindowsChrome.height : 0,
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
        if (onboarding || !presentation.compact)
          Positioned(top: 0, left: titleBarLeft, right: 0, child: controls),
      ],
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final hover = danger ? colors.danger : windowButtonHover(colors);
    return Gravity(
      // Under gravity the reset button takes the close button's place.
      resetHere: danger,
      child: Semantics(
        button: true,
        label: label,
        child: windowButtonFace(
          icon: icon,
          color: colors.muted,
          hover: hover,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

Color windowButtonHover(SyblColors colors) =>
    Color.alphaBlend(colors.ink.withValues(alpha: .16), colors.surfaceHi);

/// The flat look of a title-bar button, shared with gravity's reset button.
Widget windowButtonFace({
  Key? key,
  required IconData icon,
  required Color color,
  required Color hover,
  required VoidCallback onPressed,
}) => IconButton(
  key: key,
  onPressed: onPressed,
  icon: Icon(icon, size: 15),
  color: color,
  hoverColor: hover,
  focusColor: hover,
  highlightColor: hover,
  style: IconButton.styleFrom(
    fixedSize: const Size(40, 27),
    minimumSize: const Size(40, 27),
    padding: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
  ),
);
