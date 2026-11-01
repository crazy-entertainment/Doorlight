import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;

import '../core/image_bounds.dart';
import '../state/gif_validation.dart';
import 'bounded_gif.dart';

const _maximumSourceBytes = 4 * 1024 * 1024;
const _maximumPreviewBytes = 48 * 1024;
const _previewSide = 96;

/// A completed attachment is never handed directly to Flutter's image codec.
/// The source is bounded and sniffed; static images become a small PNG first.
class BoundedAttachmentPreview extends StatefulWidget {
  const BoundedAttachmentPreview({
    super.key,
    required this.path,
    required this.previewBytes,
    required this.size,
    required this.fallback,
  });

  final String? path;
  final Uint8List? previewBytes;
  final double size;
  final Widget fallback;

  @override
  State<BoundedAttachmentPreview> createState() =>
      _BoundedAttachmentPreviewState();
}

class _BoundedAttachmentPreviewState extends State<BoundedAttachmentPreview> {
  late Future<AttachmentPreview?> _preview;

  @override
  void initState() {
    super.initState();
    _preview = loadBoundedAttachmentPreview(widget.path, widget.previewBytes);
  }

  @override
  void didUpdateWidget(BoundedAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.previewBytes != widget.previewBytes) {
      _preview = loadBoundedAttachmentPreview(widget.path, widget.previewBytes);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AttachmentPreview?>(
    future: _preview,
    builder: (context, snapshot) {
      final preview = snapshot.data;
      if (preview == null) return widget.fallback;
      if (preview.gif) {
        return BoundedGif(bytes: preview.bytes, size: widget.size);
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.memory(
          preview.bytes,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: (widget.size * 3).round(),
          cacheHeight: (widget.size * 3).round(),
          errorBuilder: (_, _, _) => widget.fallback,
        ),
      );
    },
  );
}

class AttachmentPreview {
  const AttachmentPreview(this.bytes, {required this.gif});
  final Uint8List bytes;
  final bool gif;
}

Future<AttachmentPreview?> loadBoundedAttachmentPreview(
  String? path,
  Uint8List? previewBytes,
) async {
  Uint8List? source;
  if (path != null && path.trim().isNotEmpty) {
    source = await _readBoundedFile(path);
  }
  source ??= previewBytes;
  if (source == null || source.isEmpty || source.length > _maximumSourceBytes) {
    return null;
  }
  if (_isGif(source)) {
    return ValidatedGif.parse(source) == null
        ? null
        : AttachmentPreview(Uint8List.fromList(source), gif: true);
  }
  final png = await Isolate.run(() => _encodeStaticPreview(source!));
  return png == null ? null : AttachmentPreview(png, gif: false);
}

Future<Uint8List?> _readBoundedFile(String path) async {
  try {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final handle = await File(path).open();
    try {
      final length = await handle.length();
      if (length < 1 || length > _maximumSourceBytes) return null;
      final bytes = await handle.read(length);
      if (bytes.length != length || await handle.length() != length) {
        return null;
      }
      return Uint8List.fromList(bytes);
    } finally {
      await handle.close();
    }
  } catch (_) {
    return null;
  }
}

bool _isGif(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x38 &&
    (bytes[4] == 0x37 || bytes[4] == 0x39) &&
    bytes[5] == 0x61;

Uint8List? _encodeStaticPreview(Uint8List source) {
  try {
    final pixels = decodeBoundedRaster(
      source,
      maxEncodedBytes: _maximumSourceBytes,
    );
    if (pixels == null) return null;
    final resized = pixels.width >= pixels.height
        ? image.copyResize(pixels, width: _previewSide)
        : image.copyResize(pixels, height: _previewSide);
    final png = Uint8List.fromList(image.encodePng(resized));
    return png.length <= _maximumPreviewBytes ? png : null;
  } catch (_) {
    return null;
  }
}
