import 'package:flutter/material.dart';

import '../state/surface_protection.dart';

/// Marks [child] as private for Android screen-capture protection. While
/// protection is armed but not yet confirmed (or failed), a neutral
/// placeholder replaces the child so no private frame reaches a capturable
/// surface. Call surfaces pass `gate: false`: they still hold protection, but
/// protection must never delay or block placing, answering or ending a call.
class CaptureSensitiveScope extends StatefulWidget {
  const CaptureSensitiveScope({
    super.key,
    required this.protection,
    required this.child,
    this.gate = true,
  });

  final SensitiveSurfaceProtection protection;
  final Widget child;
  final bool gate;

  @override
  State<CaptureSensitiveScope> createState() => _CaptureSensitiveScopeState();
}

class _CaptureSensitiveScopeState extends State<CaptureSensitiveScope> {
  // The user's explicit Show after a failure; lasts for this surface only, so
  // a blocked chat never stops them from reaching its call controls.
  bool _shownAnyway = false;

  @override
  void initState() {
    super.initState();
    widget.protection.addListener(_changed);
    widget.protection.acquire();
  }

  @override
  void didUpdateWidget(CaptureSensitiveScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.protection, widget.protection)) return;
    oldWidget.protection.removeListener(_changed);
    oldWidget.protection.release();
    widget.protection.addListener(_changed);
    widget.protection.acquire();
  }

  @override
  void dispose() {
    widget.protection.removeListener(_changed);
    widget.protection.release();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final protection = widget.protection;
    if (!widget.gate || _shownAnyway || protection.revealAllowed) {
      return widget.child;
    }
    return ColoredBox(
      key: const ValueKey('capture-sensitive-placeholder'),
      color: Theme.of(context).colorScheme.surface,
      child: protection.failed
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Screenshot protection could not be turned on, so this is hidden.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey('capture-sensitive-retry'),
                          onPressed: protection.refresh,
                          child: const Text('Try again'),
                        ),
                        TextButton(
                          key: const ValueKey('capture-sensitive-show'),
                          onPressed: () => setState(() => _shownAnyway = true),
                          child: const Text('Show anyway'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          // Fills a bounded slot; collapses in a loose one (corner previews).
          : const SizedBox.shrink(),
    );
  }
}
