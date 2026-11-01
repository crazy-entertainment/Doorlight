import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

enum VoiceRecorderPhase {
  idle,
  permissionRequired,
  starting,
  recording,
  stopping,
  stopped,
  failed,
}

abstract interface class VoiceCaptureDevice {
  Future<bool> permission({required bool request});
  Future<void> start(String path);
  Future<String?> stop();
  Future<double> amplitude();
  Future<void> close();
}

final class PlatformVoiceCapture implements VoiceCaptureDevice {
  final _recorder = AudioRecorder();
  @override
  Future<bool> permission({required bool request}) =>
      _recorder.hasPermission(request: request);
  @override
  Future<void> start(String path) => _recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.aacLc,
      sampleRate: 48000,
      numChannels: 1,
      bitRate: 96000,
    ),
    path: path,
  );
  @override
  Future<String?> stop() => _recorder.stop();
  @override
  Future<double> amplitude() async => (await _recorder.getAmplitude()).current;
  @override
  Future<void> close() => _recorder.dispose();
}

/// One composer-owned capture. Native leases arbitrate the microphone; this
/// object only renews a valid lease, samples the meter and awaits real release.
final class VoiceRecorder extends ChangeNotifier {
  VoiceRecorder({
    required this.device,
    required this.isCurrent,
    required this.prepare,
    required this.renew,
    required this.discard,
  });
  final VoiceCaptureDevice device;
  final bool Function() isCurrent;
  final Future<String?> Function() prepare;
  final Future<bool> Function(String) renew;
  final Future<void> Function(String) discard;
  VoiceRecorderPhase phase = VoiceRecorderPhase.idle;
  final List<double> _amplitudes = [];
  List<double> get amplitudes => List.unmodifiable(_amplitudes);
  final Stopwatch _elapsed = Stopwatch();
  Duration get elapsed => _elapsed.elapsed;
  String? _path;
  String? completedPath;
  bool permissionInterrupted = false;
  bool interrupted = false;
  Timer? _timer;
  bool _polling = false;
  bool _stopRequested = false;
  bool _closed = false;
  Future<bool>? _starting;
  Future<String?>? _stopping;
  int _ticks = 0;

  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<bool> start() {
    if (_closed || phase != VoiceRecorderPhase.idle || !isCurrent()) {
      return Future.value(false);
    }
    phase = VoiceRecorderPhase.starting;
    _changed();
    return _starting = _start();
  }

  Future<bool> _start() async {
    try {
      if (!await device.permission(request: false)) {
        // A system prompt disarms this activation, even if permission is granted.
        await device.permission(request: true);
        permissionInterrupted = true;
        phase = VoiceRecorderPhase.permissionRequired;
        _changed();
        return false;
      }
      if (_stopRequested || !isCurrent()) return false;
      _path = await prepare();
      if (_path == null) throw const FormatException('voice_grant');
      if (_stopRequested || !isCurrent()) return false;
      await device.start(_path!);
      if (_stopRequested || !isCurrent()) return false;
      phase = VoiceRecorderPhase.recording;
      _elapsed.start();
      _timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => unawaited(_pulse()),
      );
      _changed();
      return true;
    } catch (_) {
      phase = VoiceRecorderPhase.failed;
      _changed();
      return false;
    } finally {
      if (phase != VoiceRecorderPhase.recording) {
        // Do not await our own start future through stop().
        unawaited(
          Future<void>.microtask(() async {
            await stop();
          }),
        );
      }
    }
  }

  Future<void> _pulse() async {
    if (_polling || phase != VoiceRecorderPhase.recording) return;
    if (!isCurrent() || elapsed >= const Duration(seconds: 120)) {
      interrupted = true;
      unawaited(stop());
      return;
    }
    _polling = true;
    try {
      if (++_ticks % 5 == 0 && !await renew(_path!)) {
        interrupted = true;
        unawaited(stop());
        return;
      }
      final value = await device.amplitude();
      if (phase != VoiceRecorderPhase.recording || !isCurrent()) return;
      if (value.isFinite) {
        _amplitudes.add(value.clamp(-120, 0));
        if (_amplitudes.length > 120) _amplitudes.removeAt(0);
        _changed();
      }
    } catch (_) {
      interrupted = true;
      unawaited(stop());
    } finally {
      _polling = false;
    }
  }

  Future<String?> stop() {
    _stopRequested = true;
    _timer?.cancel();
    return _stopping ??= _stop();
  }

  Future<String?> _stop() async {
    await _starting;
    phase = VoiceRecorderPhase.stopping;
    _changed();
    try {
      String? result;
      try {
        result = await device.stop();
      } catch (_) {
        // Still attempt teardown, but never turn a failed stop into a usable
        // clip or infer release from this best-effort recovery.
        try {
          await device.close();
        } catch (_) {}
        rethrow;
      }
      await device.close();
      _elapsed.stop();
      if (result != null && result != _path) {
        throw const FormatException('voice_output_owner');
      }
      if (_path != null && (result == null || _closed || !isCurrent())) {
        await discard(_path!);
      }
      completedPath = !_closed && isCurrent() ? result : null;
      phase = VoiceRecorderPhase.stopped;
      _changed();
      return completedPath;
    } catch (_) {
      // Unconfirmed release retains the native occupied slot and private file.
      phase = VoiceRecorderPhase.failed;
      _changed();
      return null;
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(stop());
    super.dispose();
  }
}
