import 'package:flutter/widgets.dart';

/// Retaining a pane for layout continuity does not retain authority to capture,
/// play media, or complete a composer action after the user leaves it.
class PaneActivityScope extends InheritedWidget {
  const PaneActivityScope({
    super.key,
    required this.active,
    required super.child,
  });
  final bool active;
  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaneActivityScope>()?.active ??
      true;
  @override
  bool updateShouldNotify(PaneActivityScope oldWidget) =>
      active != oldWidget.active;
}
