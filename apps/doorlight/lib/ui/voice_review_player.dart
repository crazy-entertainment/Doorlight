import 'dart:async';
import '../core/media_retirement.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'gravity.dart';
import 'pane_activity.dart';

abstract interface class VoicePlaybackDevice {
  Stream<Duration> get positions;
  Stream<void> get completions;
  Future<void> play(String path);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

final class PlatformVoicePlayback implements VoicePlaybackDevice {
  final _player = AudioPlayer();
  @override
  Stream<Duration> get positions => _player.onPositionChanged;
  @override
  Stream<void> get completions => _player.onPlayerComplete;
  @override
  Future<void> play(String path) => _player.play(DeviceFileSource(path));
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> resume() => _player.resume();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> dispose() => _player.dispose();
}

/// Explicit playback only. The owner validates the exact staged item before
/// each play/resume; lifecycle and ownership loss retire pending completions.
class VoiceReviewPlayer extends StatefulWidget {
  const VoiceReviewPlayer({
    super.key,
    required this.path,
    required this.duration,
    required this.isCurrent,
    required this.validate,
    this.createDevice,
  });
  final String path;
  final Duration duration;
  final bool Function() isCurrent;
  final Future<bool> Function() validate;
  final VoicePlaybackDevice Function()? createDevice;
  @override
  State<VoiceReviewPlayer> createState() => _VoiceReviewPlayerState();
}

class _VoiceReviewPlayerState extends State<VoiceReviewPlayer>
    with WidgetsBindingObserver {
  static _VoiceReviewPlayerState? _active;
  static Future<void>? _handoff;
  Future<void>? _starting;
  Future<bool>? _stopping;
  late final void Function() _unregisterMedia;
  VoicePlaybackDevice? _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _watch;
  int _generation = 0;
  bool _foreground = true;
  bool _paneActive = true;
  bool _busy = false;
  bool _playing = false;
  bool _loaded = false;
  bool _failed = false;
  Duration _position = Duration.zero;

  bool get _current =>
      mounted && _foreground && _paneActive && widget.isCurrent();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = PaneActivityScope.isActive(context);
    if (_paneActive && !active) unawaited(_stop().then((_) {}));
    _paneActive = active;
  }

  @override
  void initState() {
    super.initState();
    _unregisterMedia = MediaRetirement.register(_stop);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didUpdateWidget(covariant VoiceReviewPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || !_current) {
      unawaited(_stop().then((_) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_stop().then((_) {}));
  }

  Future<bool> _stop() {
    _generation++;
    _watch?.cancel();
    _watch = null;
    _playing = false;
    _loaded = false;
    _position = Duration.zero;
    return _stopping ??= _release().whenComplete(() => _stopping = null);
  }

  Future<bool> _release() async {
    final player = _player;
    var released = player == null;
    if (player != null) {
      // A pending native play can acquire the device after an earlier stop.
      // Keep the global owner until both it and the final stop have settled.
      final starting = _starting;
      if (starting != null) {
        try {
          await player.stop();
        } catch (_) {}
        try {
          await starting;
        } catch (_) {}
      }
      try {
        await player.stop();
        released = true;
      } catch (_) {
        _failed = true;
        try {
          await player.dispose();
          released = true;
        } catch (_) {}
      }
    }
    if (released && identical(_active, this)) _active = null;
    if (mounted) setState(() {});
    return released;
  }

  Future<void> _toggle() async {
    if (_busy || _failed || !_current) return;
    _busy = true;
    final generation = ++_generation;
    final previousHandoff = _handoff;
    final handoff = Completer<void>();
    _handoff = handoff.future;
    bool owns() => _current && generation == _generation;
    try {
      if (previousHandoff != null) await previousHandoff;
      if (!owns()) return;
      if (_playing) {
        await _player!.pause();
        if (owns()) setState(() => _playing = false);
        return;
      }
      final valid = await widget.validate();
      if (!owns()) return;
      if (!valid) {
        _failed = true;
        return;
      }
      final previous = _active;
      if (previous != null && !identical(previous, this)) {
        if (!await previous._stop()) {
          _failed = true;
          return;
        }
      }
      if (!owns()) return;
      _active = this;
      final player = _player ??=
          widget.createDevice?.call() ?? PlatformVoicePlayback();
      if (_subscriptions.isEmpty) {
        _subscriptions.add(
          player.positions.listen(
            (position) {
              if (_current && _loaded) setState(() => _position = position);
            },
            onError: (_) {
              unawaited(_stop().then((_) {}));
            },
          ),
        );
        _subscriptions.add(
          player.completions.listen(
            (_) {
              if (mounted) unawaited(_stop().then((_) {}));
            },
            onError: (_) {
              unawaited(_stop().then((_) {}));
            },
          ),
        );
      }
      _watch ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!_current) unawaited(_stop().then((_) {}));
      });
      final starting = _loaded ? player.resume() : player.play(widget.path);
      _starting = starting;
      try {
        await starting;
      } finally {
        if (identical(_starting, starting)) _starting = null;
      }
      if (!owns()) {
        await _stop();
        return;
      }
      setState(() {
        _playing = true;
        _loaded = true;
      });
    } catch (_) {
      _failed = true;
      await _stop();
    } finally {
      handoff.complete();
      if (identical(_handoff, handoff.future)) _handoff = null;
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _watch?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    final player = _player;
    if (player != null) {
      unawaited(() async {
        var stopped = await _stop();
        try {
          await player.dispose();
          stopped = true;
        } catch (_) {}
        if (stopped) _unregisterMedia();
      }());
    } else {
      _unregisterMedia();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds;
    final position = _position.inMilliseconds.clamp(0, maximum);
    String time(int milliseconds) =>
        '${milliseconds ~/ 60000}:${((milliseconds ~/ 1000) % 60).toString().padLeft(2, '0')}';
    return Row(
      children: [
        Gravity(
          child: IconButton(
            tooltip: _playing ? 'Pause voice message' : 'Play voice message',
            onPressed: _failed || _busy ? null : _toggle,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_failed)
                const Gravity(child: Text('Voice playback unavailable'))
              else
                Gravity(child: Text('${time(position)} / ${time(maximum)}')),
              LinearProgressIndicator(
                value: maximum > 0 ? position / maximum : 0,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
