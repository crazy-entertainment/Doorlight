import 'notice.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;

import '../core/jami.dart';
import '../core/image_bounds.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'gravity.dart';

typedef DecodedProfileImage = ({Uint8List previewBytes, image.Image pixels});

/// Decodes once, applies EXIF orientation once, and gives preview and export
/// the exact same pixels.
DecodedProfileImage? decodeProfileImage(Uint8List bytes) {
  if (!ProfileWireContract.isBoundedAvatarBytes(
    bytes,
    maxEncodedBytes: JamiClient.maxProfileImageBytes,
  )) {
    return null;
  }
  final decoded = decodeBoundedRaster(
    bytes,
    maxEncodedBytes: JamiClient.maxProfileImageBytes,
  );
  if (decoded == null) return null;
  final pixels = image.bakeOrientation(decoded);
  return (
    previewBytes: Uint8List.fromList(image.encodePng(pixels)),
    pixels: pixels,
  );
}

@visibleForTesting
Matrix4 profilePictureTransform({
  required double scale,
  required double x,
  required double y,
}) => Matrix4.identity()
  ..setEntry(0, 0, scale)
  ..setEntry(1, 1, scale)
  ..setEntry(2, 2, scale)
  ..setEntry(0, 3, x)
  ..setEntry(1, 3, y);

@visibleForTesting
image.Image cropProfileImage({
  required image.Image source,
  required Matrix4 transform,
  required double viewport,
  required double previewScale,
}) {
  final scale = transform.getMaxScaleOnAxis();
  final cropPreview = viewport / scale;
  final previewWidth = source.width * previewScale;
  final previewHeight = source.height * previewScale;
  final leftPreview = (-transform.entry(0, 3) / scale).clamp(
    0,
    math.max(0, previewWidth - cropPreview),
  );
  final topPreview = (-transform.entry(1, 3) / scale).clamp(
    0,
    math.max(0, previewHeight - cropPreview),
  );
  final cropSize = (cropPreview / previewScale)
      .round()
      .clamp(1, math.min(source.width, source.height))
      .toInt();
  final left = (leftPreview / previewScale)
      .round()
      .clamp(0, source.width - cropSize)
      .toInt();
  final top = (topPreview / previewScale)
      .round()
      .clamp(0, source.height - cropSize)
      .toInt();
  return image.copyCrop(
    source,
    x: left,
    y: top,
    width: cropSize,
    height: cropSize,
  );
}

Future<bool?> showProfilePictureEditor(
  BuildContext context, {
  required AppState state,
}) async {
  final path = await state.pickProfileImage();
  if (path == null || path.isEmpty) return null;

  Uint8List bytes;
  DecodedProfileImage? decoded;
  try {
    if (!context.mounted) return null;
    try {
      decoded = decodeProfileImage(await File(path).readAsBytes());
      bytes = decoded?.previewBytes ?? Uint8List(0);
    } catch (_) {
      decoded = null;
      bytes = Uint8List(0);
    }
  } finally {
    try {
      await state.discardPickedFile(path);
    } catch (_) {
      // Windows intentionally owns no picker copy; Android cleanup is
      // best-effort and native refuses paths outside its staging directory.
    }
  }
  final source = decoded;
  if (source == null || bytes.isEmpty || !context.mounted) {
    if (context.mounted) {
      showNotice('That file is not a supported image');
    }
    return false;
  }

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ProfilePictureEditor(
      state: state,
      sourceBytes: bytes,
      source: source.pixels,
    ),
  );
}

@visibleForTesting
Widget profilePictureEditorForTesting({
  required AppState state,
  required Uint8List sourceBytes,
  required image.Image source,
}) => _ProfilePictureEditor(
  state: state,
  sourceBytes: sourceBytes,
  source: source,
);

class _ProfilePictureEditor extends StatefulWidget {
  const _ProfilePictureEditor({
    required this.state,
    required this.sourceBytes,
    required this.source,
  });

  final AppState state;
  final Uint8List sourceBytes;
  final image.Image source;

  @override
  State<_ProfilePictureEditor> createState() => _ProfilePictureEditorState();
}

class _ProfilePictureEditorState extends State<_ProfilePictureEditor> {
  final TransformationController _controller = TransformationController();
  late double _viewport;
  late double _previewScale;
  late double _previewWidth;
  late double _previewHeight;
  late double _coverScale;
  late double _zoom;
  bool _initialized = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final sourceMax = math.max(widget.source.width, widget.source.height);
    _previewScale = math.min(1, 1200 / sourceMax);
    _previewWidth = widget.source.width * _previewScale;
    _previewHeight = widget.source.height * _previewScale;
  }

  void _fitViewport(double viewport) {
    if (_initialized && viewport == _viewport) return;
    final previousViewport = _initialized ? _viewport : viewport;
    final previous = _controller.value;
    _viewport = viewport;
    _coverScale = math.max(
      _viewport / _previewWidth,
      _viewport / _previewHeight,
    );
    if (!_initialized) {
      _initialized = true;
      _reset(notify: false);
    } else {
      // Scale the display, preserving the exact same selected source pixels.
      final ratio = viewport / previousViewport;
      _zoom = previous.getMaxScaleOnAxis() * ratio;
      _controller.value = profilePictureTransform(
        scale: _zoom,
        x: previous.entry(0, 3) * ratio,
        y: previous.entry(1, 3) * ratio,
      );
    }
  }

  void _reset({bool notify = true}) {
    final tx = (_viewport - _previewWidth * _coverScale) / 2;
    final ty = (_viewport - _previewHeight * _coverScale) / 2;
    _controller.value = profilePictureTransform(
      scale: _coverScale,
      x: tx,
      y: ty,
    );
    _zoom = _coverScale;
    if (notify && mounted) setState(() {});
  }

  void _setZoom(double next) {
    final matrix = _controller.value;
    final previous = matrix.getMaxScaleOnAxis();
    final scale = next.clamp(_coverScale, _coverScale * 8).toDouble();
    final ratio = scale / previous;
    final center = _viewport / 2;
    var tx = center - (center - matrix.entry(0, 3)) * ratio;
    var ty = center - (center - matrix.entry(1, 3)) * ratio;
    tx = tx.clamp(_viewport - _previewWidth * scale, 0).toDouble();
    ty = ty.clamp(_viewport - _previewHeight * scale, 0).toDouble();
    _controller.value = profilePictureTransform(scale: scale, x: tx, y: ty);
    setState(() => _zoom = scale);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final cropped = cropProfileImage(
      source: widget.source,
      transform: _controller.value,
      viewport: _viewport,
      previewScale: _previewScale,
    );
    final resized = image.copyResize(cropped, width: 384, height: 384);
    final encoded = image.encodeJpg(resized, quality: 88);
    final saved = await widget.state.updateProfileAvatar(base64Encode(encoded));
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _saving = false);
    showNotice('Could not update your profile picture');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildViewport() => Gravity(
    child: Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: context.syblColors.surfaceTop,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox.square(
        key: const ValueKey('profile-picture-viewport'),
        dimension: _viewport,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _controller,
              constrained: false,
              minScale: _coverScale,
              maxScale: _coverScale * 8,
              boundaryMargin: EdgeInsets.zero,
              clipBehavior: Clip.hardEdge,
              onInteractionUpdate: (_) {
                final value = _controller.value.getMaxScaleOnAxis();
                if ((value - _zoom).abs() > .0001) {
                  setState(() => _zoom = value);
                }
              },
              child: SizedBox(
                width: _previewWidth,
                height: _previewHeight,
                child: Image.memory(
                  widget.sourceBytes,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.high,
                  // Decode at preview size. Full-resolution decodes of
                  // odd/huge sources are what made the editor stutter
                  // and tear while dragging.
                  cacheWidth: _previewWidth.ceil(),
                  cacheHeight: _previewHeight.ceil(),
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: context.syblColors.amber, width: 3),
                  boxShadow: const [
                    BoxShadow(color: Color(0x73000000), spreadRadius: 999),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildZoom() => SizedBox(
    height: 48,
    child: Row(
      children: [
        Gravity(
          child: Icon(
            Icons.image_outlined,
            size: 17,
            color: context.syblColors.faint,
          ),
        ),
        Expanded(
          child: Gravity(
            child: Slider(
              key: const ValueKey('profile-picture-zoom'),
              label: 'Zoom',
              min: _coverScale,
              max: _coverScale * 8,
              divisions: 140,
              value: _zoom.clamp(_coverScale, _coverScale * 8).toDouble(),
              onChanged: _saving ? null : _setZoom,
            ),
          ),
        ),
        Gravity(
          child: IconButton(
            tooltip: 'Reset crop',
            onPressed: _saving ? null : () => _reset(),
            icon: const Icon(Icons.center_focus_strong_rounded, size: 18),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(20),
    constraints: const BoxConstraints(minWidth: 0, maxWidth: 368),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Gravity(
            child: Text(
              'Profile picture',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.syblColors.display.copyWith(fontSize: 20),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewport = math.max(
                  1.0,
                  math.min(
                    320.0,
                    math.min(constraints.maxWidth, constraints.maxHeight - 48),
                  ),
                );
                _fitViewport(viewport);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [_buildViewport(), _buildZoom()],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              Gravity(
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              Gravity(
                child: FilledButton.icon(
                  key: const ValueKey('save-profile-picture'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded, size: 18),
                  label: Text(_saving ? 'Saving' : 'Use picture'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
