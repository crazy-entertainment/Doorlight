import 'dart:ui';

/// Geometry shared by video rendering and annotation hit-testing.
class VideoViewport {
  final Size viewport;
  final Size source;
  final Rect contentRect;

  VideoViewport({required this.viewport, required this.source})
    : contentRect = containedRect(viewport, source);

  static Rect containedRect(Size viewport, Size source) {
    if (viewport.width <= 0 ||
        viewport.height <= 0 ||
        source.width <= 0 ||
        source.height <= 0) {
      return Rect.zero;
    }
    final scale = (viewport.width / source.width).clamp(
      0.0,
      viewport.height / source.height,
    );
    final size = Size(source.width * scale, source.height * scale);
    return Rect.fromLTWH(
      (viewport.width - size.width) / 2,
      (viewport.height - size.height) / 2,
      size.width,
      size.height,
    );
  }

  Offset? normalize(Offset pointer) {
    if (contentRect.isEmpty || !contentRect.contains(pointer)) return null;
    return Offset(
      (pointer.dx - contentRect.left) / contentRect.width,
      (pointer.dy - contentRect.top) / contentRect.height,
    );
  }

  Offset denormalize(Offset normalized) => Offset(
    contentRect.left + normalized.dx * contentRect.width,
    contentRect.top + normalized.dy * contentRect.height,
  );
}
