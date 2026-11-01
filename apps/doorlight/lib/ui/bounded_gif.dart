import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../state/gif_validation.dart';
import '../core/media_retirement.dart';

/// Explicit playback keeps history and reduced-motion previews still. Only one
/// instance can animate, and each decoded image has a single disposable owner.
class BoundedGif extends StatefulWidget {
  const BoundedGif({
    super.key,
    this.path,
    this.bytes,
    required this.size,
    this.isCurrent,
    this.validate,
  });
  final String? path;
  final Uint8List? bytes;
  final double size;
  final bool Function()? isCurrent;
  final Future<bool> Function()? validate;

  @override
  State<BoundedGif> createState() => _BoundedGifState();
}

class _BoundedGifState extends State<BoundedGif> with WidgetsBindingObserver {
  static _BoundedGifState? _active;
  Uint8List? _bytes;
  ui.Image? _image;
  int _generation = 0;
  bool _playing = false;
  bool _failed = false;
  bool _enabled = true;
  Future<void>? _loading;
  Future<void>? _playback;
  late final void Function() _unregisterMedia;

  @override
  void initState() {
    super.initState();
    _unregisterMedia = MediaRetirement.register(() async {
      _stop();
      ++_generation;
      await _loading;
      await _playback;
      return true;
    });
    WidgetsBinding.instance.addObserver(this);
    _startLoading();
  }

  @override
  void didUpdateWidget(BoundedGif oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.bytes != widget.bytes) {
      _stop();
      _bytes = null;
      _image?.dispose();
      _image = null;
      _failed = false;
      _startLoading();
    } else if (_image == null &&
        !_failed &&
        _loading == null &&
        (widget.isCurrent?.call() ?? true)) {
      _startLoading();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = TickerMode.valuesOf(context).enabled;
    if (!_enabled || MediaQuery.disableAnimationsOf(context)) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop();
  }

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  void _startLoading() {
    final loading = _load();
    _loading = loading;
    unawaited(
      loading.whenComplete(() {
        if (identical(_loading, loading)) _loading = null;
      }),
    );
  }

  Future<void> _load() async {
    final generation = ++_generation;
    ui.Codec? codec;
    try {
      if (!_current(generation) ||
          (widget.validate != null && !await widget.validate!())) {
        return;
      }
      if (!_current(generation)) return;
      Uint8List bytes;
      if (widget.bytes != null) {
        if (widget.bytes!.length > ValidatedGif.maximumBytes) {
          throw const FormatException();
        }
        bytes = Uint8List.fromList(widget.bytes!);
      } else {
        final path = widget.path;
        if (path == null ||
            await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.file) {
          throw const FormatException();
        }
        final file = await File(path).open();
        try {
          final length = await file.length();
          if (length < 1 || length > ValidatedGif.maximumBytes) {
            throw const FormatException();
          }
          bytes = await file.read(length);
          if (bytes.length != length || await file.length() != length) {
            throw const FormatException();
          }
        } finally {
          await file.close();
        }
      }
      if (!_current(generation)) return;
      if (await validateGifDecode(bytes) == null) {
        throw const FormatException();
      }
      if (!_current(generation)) return;
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!_current(generation)) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _bytes = bytes;
        _image = frame.image;
      });
    } catch (_) {
      if (_current(generation)) setState(() => _failed = true);
    } finally {
      codec?.dispose();
    }
  }

  bool _visible() {
    if (!mounted || !_enabled || !(widget.isCurrent?.call() ?? true)) {
      return false;
    }
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return false;
    }
    var area = render.localToGlobal(Offset.zero) & render.size;
    area = area.intersect(Offset.zero & MediaQuery.sizeOf(context));
    RenderObject? ancestor = render.parent;
    while (ancestor != null) {
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

  void _stop() {
    if (!_playing) return;
    ++_generation;
    if (_active == this) _active = null;
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _play() async {
    if (_playback != null) return;
    final playback = _animate();
    _playback = playback;
    try {
      await playback;
    } finally {
      if (identical(_playback, playback)) _playback = null;
    }
  }

  Future<void> _animate() async {
    final bytes = _bytes;
    if (bytes == null || !_visible()) return;
    _active?._stop();
    _active = this;
    final generation = ++_generation;
    setState(() => _playing = true);
    ui.Codec? codec;
    try {
      if (widget.validate != null && !await widget.validate!()) return;
      if (!_current(generation) || !_visible()) return;
      codec = await ui.instantiateImageCodec(bytes);
      while (_current(generation) && _visible()) {
        final frame = await codec.getNextFrame();
        if (!_current(generation) || !_visible()) {
          frame.image.dispose();
          break;
        }
        final old = _image;
        setState(() => _image = frame.image);
        old?.dispose();
        var remaining = frame.duration.inMilliseconds;
        if (remaining < 20) remaining = 100;
        // Long still frames must not retain a playback lease off screen.
        while (remaining > 0 && _current(generation) && _visible()) {
          final step = remaining > 50 ? 50 : remaining;
          await Future<void>.delayed(Duration(milliseconds: step));
          remaining -= step;
        }
      }
    } catch (_) {
      // Decoder/device failures leave a still preview; no path diagnostics.
    } finally {
      codec?.dispose();
      if (mounted && generation == _generation) _stop();
    }
  }

  @override
  void dispose() {
    _unregisterMedia();
    ++_generation;
    if (_active == this) _active = null;
    WidgetsBinding.instance.removeObserver(this);
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (_image != null)
          RawImage(image: _image, fit: BoxFit.contain)
        else
          Icon(_failed ? Icons.broken_image_outlined : Icons.image_outlined),
        if (_bytes != null)
          Center(
            child: IconButton.filledTonal(
              tooltip: _playing ? 'Pause GIF' : 'Play GIF',
              onPressed: _playing ? _stop : () => unawaited(_play()),
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            ),
          ),
      ],
    ),
  );
}
