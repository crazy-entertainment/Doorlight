import 'notice.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/jami.dart';
import '../state/app_settings.dart';
import '../theme.dart';
import 'gravity.dart';
import 'sybl_ui.dart';

enum CompactSurface { conversation, directAudio, groupAudio }

/// Window presentation only. Conversation, notification and call state remain
/// owned by AppState. Native code owns placement, DPI and the topmost flag.
class WindowPresentation extends ChangeNotifier with WidgetsBindingObserver {
  static const animationDuration = Duration(milliseconds: 220);
  static const Curve animationCurve = _WindowPresentationCurve();
  WindowPresentation(
    this.jami, {
    this.rememberDefaultWindowPosition = false,
    WindowEdgeSpacing edgeSpacing = WindowEdgeSpacing.close,
  }) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(setEdgeSpacing(edgeSpacing, reposition: false));
    unawaited(refresh());
  }
  final JamiClient jami;
  bool rememberDefaultWindowPosition;
  bool compact = false;
  bool defaultSize = true;
  bool animating = false;
  bool pinned = false;
  CompactSurface surface = CompactSurface.conversation;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  // Window commands share one native boundary. A call arriving during a pin
  // or mode change must still receive its requested geometry.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _pending.then((_) async {
      if (_disposed) return;
      await action();
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => unawaited(refresh());

  Future<void> refresh() => _enqueue(() async {
    try {
      final state = await jami.windowPresentationState();
      if (_disposed || state == null) return;
      final nativeCompact = state['compact'] as bool;
      final nativeDefault = state['defaultSize'] as bool;
      final nativeAnimating = state['animating'] == true;
      if (compact == nativeCompact &&
          defaultSize == nativeDefault &&
          animating == nativeAnimating) {
        return;
      }
      compact = nativeCompact;
      defaultSize = nativeDefault;
      animating = nativeAnimating;
      notifyListeners();
    } on MissingPluginException {
      // Widget-only hosts have no native window.
    } on PlatformException {
      // Preserve the last confirmed state while the native window is unavailable.
    }
  });

  Future<void> toggleSize({bool animate = false}) async {
    await refresh();
    await setCompact(!compact && defaultSize, animate: animate);
  }

  Future<void> setEdgeSpacing(
    WindowEdgeSpacing spacing, {
    bool reposition = true,
  }) => _enqueue(() async {
    try {
      await jami.setWindowEdgeSpacing(spacing.name, reposition: reposition);
    } on MissingPluginException {
      // Widget-only hosts have no native window.
    } on PlatformException {
      // The saved preference is reapplied when the window becomes available.
    }
  });

  Future<void> setCompact(bool value, {bool animate = false}) =>
      _enqueue(() async {
        if (compact == value && (value || defaultSize)) return;
        final command = value
            ? 'compact'
            : rememberDefaultWindowPosition
            ? 'expand'
            : 'resetWindow';
        await jami.windowCommand(animate ? '${command}Animated' : command);
        compact = value;
        defaultSize = !value;
        animating = animate;
        surface = CompactSurface.conversation;
        if (!_disposed) notifyListeners();
      });

  Future<void> togglePin() => _enqueue(() async {
    await jami.windowCommand(pinned ? 'unpin' : 'pin');
    pinned = !pinned;
    if (!_disposed) notifyListeners();
  });

  Future<void> fit(CompactSurface value) => _enqueue(() async {
    if (!compact || surface == value) return;
    await jami.windowCommand(switch (value) {
      CompactSurface.conversation => 'compact',
      CompactSurface.directAudio => 'compactDirectAudio',
      CompactSurface.groupAudio => 'compactGroupAudio',
    });
    surface = value;
  });

  void command(String command) => unawaited(jami.windowCommand(command));
}

/// Matches the interpolation used by the native window.
class _WindowPresentationCurve extends Curve {
  const _WindowPresentationCurve();
  @override
  double transformInternal(double t) => 1 - (1 - t) * (1 - t) * (1 - t);
}

class WindowPresentationScope extends InheritedNotifier<WindowPresentation> {
  const WindowPresentationScope({
    super.key,
    required WindowPresentation controller,
    required super.child,
  }) : super(notifier: controller);
  static WindowPresentation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WindowPresentationScope>()
      ?.notifier;
  static bool isCompact(BuildContext context) =>
      maybeOf(context)?.compact ?? false;
}

class CompactIconButton extends StatelessWidget {
  const CompactIconButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.active = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  @override
  Widget build(BuildContext context) => Gravity(
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: active
          ? (context.syblColors.neutralButtonForeground ??
                context.syblColors.amber)
          : context.syblColors.muted,
      style: IconButton.styleFrom(
        backgroundColor: active
            ? (context.syblColors.neutralButtonPressed ??
                  context.syblColors.surfaceHi)
            : Colors.transparent,
        minimumSize: const Size(26, 28),
        maximumSize: const Size(26, 28),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
  );
}

class WindowModeButtons extends StatelessWidget {
  const WindowModeButtons({super.key, this.onExpand, this.minimizeButton});
  final Widget? minimizeButton;
  final VoidCallback? onExpand;
  Future<void> _attempt(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on PlatformException catch (error) {
      if (context.mounted) {
        showNotice(error.message ?? 'The window could not be updated.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final window = WindowPresentationScope.maybeOf(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CompactIconButton(
          label: window.pinned ? 'Unpin' : 'Pin',
          icon: window.pinned ? Icons.push_pin : Icons.push_pin_outlined,
          active: window.pinned,
          onPressed: () => unawaited(_attempt(context, window.togglePin)),
        ),
        ?minimizeButton,
        CompactIconButton(
          label: window.compact || !window.defaultSize
              ? 'Default size'
              : 'Compact',
          icon: window.compact || !window.defaultSize
              ? Icons.open_in_full
              : Icons.close_fullscreen,
          onPressed: () {
            onExpand?.call();
            unawaited(
              _attempt(
                context,
                () => window.toggleSize(
                  animate: SyblMotion.duration(context) != Duration.zero,
                ),
              ),
            );
          },
        ),
        if (window.compact)
          CompactIconButton(
            label: 'Close',
            icon: Icons.close,
            onPressed: () => window.command('close'),
          ),
      ],
    );
  }
}

/// Integrated content header: no second title bar in the compact window.
class CompactHeader extends StatelessWidget {
  const CompactHeader({
    super.key,
    required this.title,
    this.onBack,
    this.unreadElsewhere = 0,
    this.leading,
    this.actions = const [],
    this.onExpand,
    this.titleWidget,
  });
  final String title;
  final VoidCallback? onBack;
  final int unreadElsewhere;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onExpand;
  final Widget? titleWidget;
  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final window = WindowPresentationScope.maybeOf(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: colors.desk,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            Badge(
              isLabelVisible: unreadElsewhere > 0,
              backgroundColor: colors.accentFill,
              child: CompactIconButton(
                label: unreadElsewhere > 0
                    ? '$unreadElsewhere unread elsewhere'
                    : 'Back',
                icon: Icons.arrow_back_rounded,
                onPressed: onBack,
              ),
            ),
          if (leading != null)
            Padding(padding: const EdgeInsets.only(right: 4), child: leading!),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => window?.command('drag'),
              onDoubleTap: titleWidget == null
                  ? () => window?.command('toggleMaximize')
                  : null,
              onSecondaryTapUp: (_) => window?.command('systemMenu'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child:
                    titleWidget ??
                    Gravity(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
              ),
            ),
          ),
          ...actions,
          if (window != null) WindowModeButtons(onExpand: onExpand),
        ],
      ),
    );
  }
}
