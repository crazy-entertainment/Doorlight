import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/sticker_assets.dart';
import '../state/app_state.dart';
import '../state/hologram_live.dart';

/// Decorates an existing control without replacing its action or unread badge.
/// A visible sender avatar wins over the existing return/people control.
class HologramAnchor extends StatefulWidget {
  const HologramAnchor({
    super.key,
    required this.state,
    this.peerId,
    required this.child,
  });
  final AppState state;
  final String? peerId;
  final Widget child;
  @override
  State<HologramAnchor> createState() => _HologramAnchorState();
}

class _HologramAnchorState extends State<HologramAnchor>
    with SingleTickerProviderStateMixin {
  static final _anchors = <_HologramAnchorState>{};
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3350),
  )..addListener(_tick);
  HologramPresentation? _shown;
  ImageProvider? _image;
  bool _reduced = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _anchors.add(this);
    widget.state.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _changed();
  }

  @override
  void didUpdateWidget(HologramAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_changed);
      widget.state.addListener(_changed);
      _shown = null;
      _clock.stop();
    }
    _changed();
  }

  bool _visible() {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return false;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return false;
    }
    var area = (render.localToGlobal(Offset.zero) & render.size).intersect(
      Offset.zero & MediaQuery.sizeOf(context),
    );
    RenderObject? ancestor = render.parent;
    while (ancestor != null) {
      if (ancestor is RenderOffstage && ancestor.offstage) return false;
      if (ancestor is RenderOpacity && ancestor.opacity == 0) return false;
      if (ancestor is RenderAbstractViewport && ancestor is RenderBox) {
        final viewport = ancestor as RenderBox;
        area = area.intersect(
          viewport.localToGlobal(Offset.zero) & viewport.size,
        );
      }
      ancestor = ancestor.parent;
    }
    return !area.isEmpty;
  }

  void _changed() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final presentation = widget.state.hologramPresentation;
      if (_shown != null && !identical(_shown, presentation)) {
        _clock.stop();
        setState(() {
          _shown = null;
          _image = null;
        });
      }
      if (presentation == null || _shown != null) return;
      final candidates = _anchors
          .where(
            (anchor) =>
                identical(anchor.widget.state, widget.state) &&
                anchor._visible() &&
                (anchor.widget.peerId == presentation.peer ||
                    anchor.widget.peerId == null),
          )
          .toList();
      candidates.sort(
        (a, b) => (a.widget.peerId == null ? 1 : 0).compareTo(
          b.widget.peerId == null ? 1 : 0,
        ),
      );
      if (candidates.isEmpty ||
          !identical(candidates.first, this) ||
          !widget.state.claimHologramSurface(presentation, this)) {
        return;
      }
      unawaited(_start(presentation));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _start(HologramPresentation presentation) async {
    final manifest = await bundledStickerManifest;
    final entry = manifest?.byId(presentation.asset);
    if (!mounted || entry == null) return;
    final image = AssetImage(entry.path);
    var failed = false;
    await precacheImage(
      image,
      context,
      onError: (_, _) {
        failed = true;
      },
    );
    if (!mounted ||
        failed ||
        !_visible() ||
        !identical(widget.state.hologramPresentation, presentation)) {
      return;
    }
    _reduced =
        MediaQuery.disableAnimationsOf(context) ||
        !widget.state.appSettings.chatMotionEnabled;
    setState(() {
      _shown = presentation;
      _image = image;
    });
    // Image is decoded before starting. The same first frame owns the sound.
    _clock.forward(from: 0);
    widget.state.hologramFadeStarted(presentation);
  }

  void _tick() {
    if (!mounted || _shown == null) return;
    if (!_visible() || !identical(widget.state.hologramPresentation, _shown)) {
      _clock.stop();
      final shown = _shown!;
      setState(() {
        _shown = null;
        _image = null;
      });
      widget.state.cancelHologramSurface(shown, this);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _anchors.remove(this);
    widget.state.removeListener(_changed);
    final shown = _shown;
    if (shown != null) {
      final state = widget.state;
      scheduleMicrotask(() => state.cancelHologramSurface(shown, this));
    }
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = _clock.value * 3350;
    final opacity = _reduced
        ? (ms < 3000 ? 1.0 : 0.0)
        : ms < 150
        ? ms / 150
        : ms < 3150
        ? 1.0
        : ((3350 - ms) / 200).clamp(0.0, 1.0);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        widget.child,
        if (_shown != null && _image != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: opacity,
                  child: Image(image: _image!, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
