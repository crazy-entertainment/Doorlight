import 'dart:async';
import 'media_retirement.dart';

import 'package:audioplayers/audioplayers.dart';

enum SyblSoundEvent {
  notification('notification.wav'),
  // Play at the start of an admitted incoming hologram's fade-in, never merely
  // because its durable message arrived or was loaded from history.
  hologram('hologram_cat.wav'),
  userJoin('user_join.wav'),
  userLeft('user_left.wav'),
  incomingRing('incoming_ring.wav'),
  outgoingRing('outgoing_ring.wav'),
  callConnected('call_connected.wav'),
  callEnded('call_ended.wav'),
  cameraOn('camera_on.wav'),
  cameraOff('camera_off.wav'),
  screenShareOn('screen_share_on.wav'),
  screenShareOff('screen_share_off.wav'),
  micMute('mic_mute.wav'),
  micUnmute('mic_unmute.wav'),
  deafen('deafen.wav'),
  undeafen('undeafen.wav'),
  // Nearby: your own reveal, and someone else's reaching you.
  sonarSend('sonar_send.wav'),
  sonarReceived('sonar_received.wav'),
  // A manual pulse sent by tapping your picture while visible.
  sonarPulse('sonar_pulse.wav'),
  // Sonar combat. Charge loops while held; en route and ambience loop until
  // their stop event.
  sonarCharge('sonar_charge.wav'),
  sonarTargetTick('sonar_targetTick.wav'),
  sonarTargetLock('sonar_targetLock.wav'),
  sonarMissileShot('sonar_missileShot.wav'),
  sonarMissileEnRoute('sonar_missileEnRoute.wav'),
  sonarHit('sonar_hit.wav'),
  sonarEnemySunk('sonar_enemy_sunk.wav'),
  sonarIncomingMissile('sonar_IncomingMissile.wav'),
  sonarIncomingMissileClose('sonar_IncomingMissileClose.wav'),
  sonarIncomingMissileKill('sonar_IncomingMissileKill.wav'),
  sonarMissileTargetLost('sonar_missileTargetLost.wav'),
  sonarMissileHitEachOther('sonar_missileHitEachOther.wav'),
  sonarIncomingMissileHit('sonar_IncomingMissileHit.wav'),
  sonarWarningLowHealth('sonar_warning_lowhealth.wav'),
  sonarOff('sonar_off.wav'),
  sonarAmbience('sonar_underwater_ambience.wav'),
  stopCharge(null),
  stopMissileEnRoute(null),
  stopAmbience(null),
  stopIncomingWarning(null),
  stopRinging(null),
  stopHologram(null);

  const SyblSoundEvent(this.fileName);

  final String? fileName;
  String? get asset => fileName == null ? null : 'assets/sounds/$fileName';
  String? get assetSource => fileName == null ? null : 'sounds/$fileName';
  bool get ringing => this == incomingRing || this == outgoingRing;
  bool get looping =>
      this == sonarCharge ||
      this == sonarMissileEnRoute ||
      this == sonarAmbience;

  /// The loop a stop event ends.
  SyblSoundEvent? get stops => switch (this) {
    stopCharge => sonarCharge,
    stopMissileEnRoute => sonarMissileEnRoute,
    stopAmbience => sonarAmbience,
    _ => null,
  };

  /// Sounds that may be spam-tapped overlap instead of cutting each other off.
  int get voices => switch (this) {
    sonarSend ||
    sonarReceived ||
    sonarPulse ||
    sonarTargetTick ||
    sonarTargetLock => 4,
    _ => 1,
  };
}

/// Round-robin voices for one effect: each play takes the next voice, so a
/// quick repeat starts on a fresh voice while the earlier one rings out.
final class SoundVoices<T> {
  SoundVoices(this.capacity, this._create);

  final int capacity;
  final T Function() _create;
  final List<T> all = [];
  int _next = 0;

  T take() {
    final index = _next;
    _next = (_next + 1) % capacity;
    if (index == all.length) all.add(_create());
    return all[index];
  }
}

/// Owns short local effects. It never sends sound events to another device.
final class SyblSoundPlayer {
  SyblSoundPlayer() {
    _unregisterMedia = MediaRetirement.register(_retireHologram);
  }
  late final void Function() _unregisterMedia;
  Future<void>? _hologramStarting;

  Future<bool> _retireHologram() async {
    _hologramGeneration++;
    final player = _effects[SyblSoundEvent.hologram];
    if (player == null) return true;
    final starting = _hologramStarting;
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
      return true;
    } catch (_) {
      try {
        await player.dispose();
        _effects.remove(SyblSoundEvent.hologram);
        _preparedHologram = null;
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  final Map<SyblSoundEvent, AudioPlayer> _effects = {};
  final Map<SyblSoundEvent, SoundVoices<AudioPlayer>> _layered = {};
  final Map<SyblSoundEvent, AudioPlayer> _loops = {};
  final Set<SyblSoundEvent> _loopStarted = {};
  // Bumped by each stop, so a loop still starting when its stop arrives
  // silences itself instead of playing on.
  final Map<SyblSoundEvent, int> _loopGeneration = {};
  final Map<SyblSoundEvent, Future<void>> _loopOperations = {};
  final Set<Future<void>> _pendingLoops = {};
  final AudioPlayer _ring = AudioPlayer();
  int _ringGeneration = 0;
  Future<void> _ringOperation = Future<void>.value();
  final AudioPlayer _incomingWarning = AudioPlayer();
  final AudioPlayer _incomingCloseWarning = AudioPlayer();
  int _warningGeneration = 0;
  bool _warningActive = false;
  bool _warningClose = false;
  final AudioContext _context = AudioContextConfig(
    focus: AudioContextConfigFocus.mixWithOthers,
  ).build();

  Future<AudioPlayer?>? _preparedHologram;
  int _hologramGeneration = 0;
  bool _disposed = false;

  Future<void> prepareHologram() async {
    await _hologramPlayer();
  }

  Future<AudioPlayer?> _hologramPlayer() => _preparedHologram ??= () async {
    final player = _effects.putIfAbsent(
      SyblSoundEvent.hologram,
      AudioPlayer.new,
    );
    try {
      await player.setAudioContext(_context);
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setSource(AssetSource(SyblSoundEvent.hologram.assetSource!));
      return _disposed ? null : player;
    } catch (_) {
      return null;
    }
  }();

  Future<void> handle(SyblSoundEvent event) async {
    try {
      if (_disposed) return;
      if (event == SyblSoundEvent.stopHologram) {
        await _retireHologram();
        return;
      }
      if (event == SyblSoundEvent.hologram) {
        final generation = ++_hologramGeneration;
        final player = await _hologramPlayer();
        if (player == null || _disposed || generation != _hologramGeneration) {
          return;
        }
        await player.seek(Duration.zero);
        if (_disposed || generation != _hologramGeneration) return;
        final starting = player.resume();
        _hologramStarting = starting;
        try {
          await starting;
        } finally {
          if (identical(_hologramStarting, starting)) _hologramStarting = null;
        }
        if (_disposed || generation != _hologramGeneration) await player.stop();
        return;
      }
      if (event == SyblSoundEvent.stopRinging) {
        _ringGeneration++;
        await _queueRingOperation(_ring.stop);
        return;
      }
      if (event == SyblSoundEvent.stopIncomingWarning) {
        await _stopIncomingWarning();
        return;
      }
      if (event.stops case final loop?) {
        _loopGeneration[loop] = (_loopGeneration[loop] ?? 0) + 1;
        _loopStarted.remove(loop);
        await _queueLoopOperation(loop, () async {
          await _loops[loop]?.stop();
        });
        return;
      }
      final source = event.assetSource;
      if (source == null) return;
      if (event == SyblSoundEvent.sonarIncomingMissile) {
        await _startIncomingWarning(close: false);
        return;
      }
      if (event == SyblSoundEvent.sonarIncomingMissileClose) {
        await _startIncomingWarning(close: true);
        return;
      }
      if (event == SyblSoundEvent.sonarIncomingMissileKill) {
        unawaited(handle(SyblSoundEvent.stopIncomingWarning));
        unawaited(handle(SyblSoundEvent.stopAmbience));
      }
      if (event.looping) {
        if (_loopStarted.contains(event)) return;
        _loopStarted.add(event);
        final generation = _loopGeneration[event] ?? 0;
        await _queueLoopOperation(
          event,
          () => _startLoop(event, source, generation),
        );
        return;
      }
      if (event.ringing) {
        final generation = ++_ringGeneration;
        await _queueRingOperation(() => _startRing(source, generation));
        return;
      }
      final player = event.voices > 1
          ? _layered
                .putIfAbsent(
                  event,
                  () => SoundVoices(event.voices, AudioPlayer.new),
                )
                .take()
          : _effects.putIfAbsent(event, AudioPlayer.new);
      // Reloading the asset on every play delays quick repeats; rewind the
      // loaded one instead so a second tap restarts it at once.
      if (player.source == null) {
        await player.setAudioContext(_context);
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSource(AssetSource(source));
      } else {
        await player.seek(Duration.zero);
      }
      await player.resume();
    } catch (_) {
      // A missing output device must not break the call state machine.
    }
  }

  Future<void> _queueRingOperation(Future<void> Function() operation) {
    final work = _ringOperation.then((_) => operation());
    // Keep the queue usable after an output-device failure.
    _ringOperation = work.catchError((Object _) {});
    return work;
  }

  Future<void> _startRing(String source, int generation) async {
    bool current() => !_disposed && generation == _ringGeneration;
    if (!current()) return;
    await _ring.stop();
    if (!current()) return;
    await _ring.setAudioContext(_context);
    if (!current()) return;
    await _ring.setReleaseMode(ReleaseMode.loop);
    if (!current()) return;
    await _ring.setSource(AssetSource(source));
    if (!current()) return;
    await _ring.resume();
    if (!current()) await _ring.stop();
  }

  Future<void> _queueLoopOperation(
    SyblSoundEvent event,
    Future<void> Function() operation,
  ) {
    final previous = _loopOperations[event];
    final work = previous == null
        ? operation()
        : previous.then((_) => operation(), onError: (Object _) => operation());
    late final Future<void> queued;
    queued = work.whenComplete(() {
      if (identical(_loopOperations[event], queued)) {
        _loopOperations.remove(event);
      }
      _pendingLoops.remove(queued);
    });
    _loopOperations[event] = queued;
    _pendingLoops.add(queued);
    return queued;
  }

  Future<void> _startLoop(
    SyblSoundEvent event,
    String source,
    int generation,
  ) async {
    try {
      final player = _loops.putIfAbsent(event, AudioPlayer.new);
      await player.stop();
      if (_disposed || generation != (_loopGeneration[event] ?? 0)) return;
      await player.setAudioContext(_context);
      if (_disposed || generation != (_loopGeneration[event] ?? 0)) return;
      await player.setReleaseMode(ReleaseMode.loop);
      if (_disposed || generation != (_loopGeneration[event] ?? 0)) return;
      await player.play(AssetSource(source));
      if (_disposed || generation != (_loopGeneration[event] ?? 0)) {
        await player.stop();
      }
    } catch (_) {
      if (generation == (_loopGeneration[event] ?? 0)) {
        _loopStarted.remove(event);
      }
      rethrow;
    }
  }

  Future<void> _startIncomingWarning({required bool close}) async {
    if (_warningActive && close == _warningClose) return;
    _warningActive = true;
    _warningClose = close;
    final generation = ++_warningGeneration;
    final incomingVolume = close ? 0.0 : 0.35;
    final closeVolume = close ? 0.35 : 0.0;
    final incoming = _incomingWarning;
    final closer = _incomingCloseWarning;
    final target = close ? closer : incoming;
    final event = close
        ? SyblSoundEvent.sonarIncomingMissileClose
        : SyblSoundEvent.sonarIncomingMissile;
    await target.setAudioContext(_context);
    await target.setReleaseMode(close ? ReleaseMode.stop : ReleaseMode.loop);
    await target.setVolume(0);
    await target.play(AssetSource(event.assetSource!));
    if (_disposed || generation != _warningGeneration) {
      await target.stop();
      return;
    }
    await Future.wait([
      _fadeWarning(incoming, incomingVolume, generation),
      _fadeWarning(closer, closeVolume, generation),
    ]);
    if (close && generation == _warningGeneration) await incoming.stop();
  }

  Future<void> _stopIncomingWarning() async {
    final generation = ++_warningGeneration;
    _warningActive = false;
    _warningClose = false;
    await Future.wait([
      _fadeWarning(_incomingWarning, 0, generation),
      _fadeWarning(_incomingCloseWarning, 0, generation),
    ]);
    if (!_disposed && generation == _warningGeneration) {
      await _incomingWarning.stop();
      await _incomingCloseWarning.stop();
    }
  }

  Future<void> _fadeWarning(
    AudioPlayer player,
    double volume,
    int generation,
  ) async {
    final from = player.volume;
    for (var step = 1; step <= 5; step++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_disposed || generation != _warningGeneration) return;
      await player.setVolume(from + (volume - from) * step / 5);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _ringGeneration++;
    _warningGeneration++;
    _hologramGeneration++;
    await _queueRingOperation(_ring.dispose);
    for (final loop in _loopGeneration.keys.toList()) {
      _loopGeneration[loop] = _loopGeneration[loop]! + 1;
      _loopStarted.remove(loop);
    }
    await Future.wait(_pendingLoops.toList());
    await Future.wait([for (final player in _loops.values) player.stop()]);
    await _preparedHologram;
    await _incomingWarning.dispose();
    await _incomingCloseWarning.dispose();
    await Future.wait([
      for (final player in _effects.values) player.dispose(),
      for (final player in _loops.values) player.dispose(),
      for (final voices in _layered.values)
        for (final player in voices.all) player.dispose(),
    ]);
    _effects.clear();
    _layered.clear();
    _loops.clear();
    _unregisterMedia();
  }
}
