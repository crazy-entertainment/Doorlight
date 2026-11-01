import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/voice_recorder.dart';

final class Device implements VoiceCaptureDevice {
  bool allowed = true;
  bool failStop = false;
  int starts = 0;
  int closes = 0;
  Completer<void>? starting;
  @override
  Future<bool> permission({required bool request}) async => allowed;
  @override
  Future<void> start(String path) async {
    starts++;
    await starting?.future;
  }

  @override
  Future<String?> stop() async {
    if (failStop) throw StateError('release');
    return starts == 0 ? null : 'owned.m4a';
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<double> amplitude() async => -30;
}

void main() {
  test(
    'permission prompt disarms activation and never starts capture',
    () async {
      final device = Device()..allowed = false;
      final recorder = VoiceRecorder(
        device: device,
        isCurrent: () => true,
        prepare: () async => 'owned.m4a',
        renew: (_) async => true,
        discard: (_) async {},
      );
      expect(await recorder.start(), isFalse);
      await recorder.stop();
      expect(recorder.permissionInterrupted, isTrue);
      expect(device.starts, 0);
      recorder.dispose();
    },
  );
  test(
    'ownership loss during native start closes and discards only its output',
    () async {
      final device = Device()..starting = Completer<void>();
      var current = true;
      final discarded = <String>[];
      final recorder = VoiceRecorder(
        device: device,
        isCurrent: () => current,
        prepare: () async => 'owned.m4a',
        renew: (_) async => true,
        discard: (path) async {
          discarded.add(path);
        },
      );
      final start = recorder.start();
      await Future<void>.delayed(Duration.zero);
      current = false;
      device.starting!.complete();
      expect(await start, isFalse);
      expect(await recorder.stop(), isNull);
      expect(discarded, ['owned.m4a']);
      expect(device.closes, 1);
      recorder.dispose();
    },
  );
  test(
    'failed release never yields a clip or deletes the owned stage',
    () async {
      final device = Device()..failStop = true;
      final discarded = <String>[];
      final recorder = VoiceRecorder(
        device: device,
        isCurrent: () => true,
        prepare: () async => 'owned.m4a',
        renew: (_) async => true,
        discard: (path) async {
          discarded.add(path);
        },
      );
      expect(await recorder.start(), isTrue);
      expect(await recorder.stop(), isNull);
      expect(recorder.phase, VoiceRecorderPhase.failed);
      expect(discarded, isEmpty);
      expect(device.closes, 1);
      recorder.dispose();
    },
  );
}
