import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/sound_effects.dart';
import 'package:sybl/state/sonar_combat.dart';

typedef _AudioCall = ({String method, String player, Object? arguments});

Future<({List<_AudioCall> calls, List<MethodChannel> eventChannels})>
_mockAudioChannels({
  Completer<void>? firstResumeEntered,
  Completer<void>? releaseFirstResume,
  Future<void> Function(_AudioCall)? beforeReply,
}) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const audio = MethodChannel('xyz.luan/audioplayers');
  const global = MethodChannel('xyz.luan/audioplayers.global');
  const globalEvents = EventChannel('xyz.luan/audioplayers.global/events');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final events = <String, MockStreamHandlerEventSink>{};
  final eventChannels = <MethodChannel>[];
  final calls = <_AudioCall>[];
  var resumes = 0;
  final cacheDir = Directory('${Directory.current.path}/.dart_tool/audio-test');
  AudioCache.instance = AudioCache();
  messenger.setMockMethodCallHandler(global, (_) async => null);
  messenger.setMockStreamHandler(
    globalEvents,
    MockStreamHandler.inline(onListen: (_, sink) {}),
  );
  messenger.setMockMethodCallHandler(pathProvider, (call) async {
    if (call.method == 'getTemporaryDirectory') return cacheDir.path;
    return null;
  });
  messenger.setMockMethodCallHandler(audio, (call) async {
    final arguments = call.arguments as Map<Object?, Object?>? ?? {};
    final id = arguments['playerId'] as String? ?? '';
    calls.add((method: call.method, player: id, arguments: call.arguments));
    await beforeReply?.call(calls.last);
    if (call.method == 'create') {
      final eventChannel = MethodChannel('xyz.luan/audioplayers/events/$id');
      eventChannels.add(eventChannel);
      messenger.setMockStreamHandler(
        EventChannel(eventChannel.name),
        MockStreamHandler.inline(
          onListen: (_, sink) {
            events[id] = sink;
          },
        ),
      );
    } else if (call.method == 'setSourceUrl') {
      events[id]?.success({'event': 'audio.onPrepared', 'value': true});
    } else if (call.method == 'resume' && ++resumes == 1) {
      firstResumeEntered?.complete();
      if (releaseFirstResume != null) await releaseFirstResume.future;
    }
    return null;
  });
  addTearDown(() async {
    for (final channel in [audio, global, pathProvider, ...eventChannels]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    messenger.setMockStreamHandler(globalEvents, null);
    for (final channel in eventChannels) {
      messenger.setMockStreamHandler(EventChannel(channel.name), null);
    }
    AudioCache.instance = AudioCache();
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  });
  return (calls: calls, eventChannels: eventChannels);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'hologram effect matches the mono 48 kHz 16-bit PCM sound bank',
    () async {
      final data = await rootBundle.load(SyblSoundEvent.hologram.asset!);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(bytes.sublist(12, 16)), 'fmt ');
      expect(data.getUint16(20, Endian.little), 1);
      expect(data.getUint16(22, Endian.little), 1);
      expect(data.getUint32(24, Endian.little), 48000);
      expect(data.getUint16(34, Endian.little), 16);
    },
  );

  test(
    'every playable sound event resolves to a bundled audio asset',
    () async {
      for (final event in SyblSoundEvent.values) {
        final asset = event.asset;
        if (asset == null) continue;
        final bytes = await rootBundle.load(asset);
        expect(bytes.lengthInBytes, greaterThan(44), reason: event.name);
      }
    },
  );

  test('Sonar combat sounds are mono 48 kHz 16-bit PCM', () async {
    const combat = [
      SyblSoundEvent.sonarCharge,
      SyblSoundEvent.sonarTargetTick,
      SyblSoundEvent.sonarTargetLock,
      SyblSoundEvent.sonarMissileShot,
      SyblSoundEvent.sonarMissileEnRoute,
      SyblSoundEvent.sonarHit,
      SyblSoundEvent.sonarEnemySunk,
      SyblSoundEvent.sonarIncomingMissile,
      SyblSoundEvent.sonarIncomingMissileClose,
      SyblSoundEvent.sonarIncomingMissileKill,
      SyblSoundEvent.sonarMissileTargetLost,
      SyblSoundEvent.sonarMissileHitEachOther,
      SyblSoundEvent.sonarIncomingMissileHit,
      SyblSoundEvent.sonarWarningLowHealth,
      SyblSoundEvent.sonarOff,
      SyblSoundEvent.sonarAmbience,
    ];
    for (final event in combat) {
      final data = await rootBundle.load(event.asset!);
      expect(data.getUint16(20, Endian.little), 1, reason: event.name);
      expect(data.getUint16(22, Endian.little), 1, reason: event.name);
      expect(data.getUint32(24, Endian.little), 48000, reason: event.name);
      expect(data.getUint16(34, Endian.little), 16, reason: event.name);
    }
  });

  test(
    'incoming missile kill clip ends within 1 ms of the death animation',
    () async {
      final data = await rootBundle.load(
        SyblSoundEvent.sonarIncomingMissileKill.asset!,
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      var offset = 12;
      int? audioBytes;
      while (offset + 8 <= bytes.length) {
        final chunkSize = ByteData.sublistView(
          bytes,
        ).getUint32(offset + 4, Endian.little);
        final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
        if (id == 'data') {
          audioBytes = chunkSize;
          break;
        }
        offset += 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }
      expect(audioBytes, isNotNull);
      final durationMicros = audioBytes! * 1000000 ~/ (48000 * 2);
      expect(
        (durationMicros - SonarCombat.deathDuration.inMicroseconds).abs(),
        lessThanOrEqualTo(1000),
      );
    },
  );

  test('loops have explicit stop events and target cues can layer', () {
    expect(SyblSoundEvent.stopCharge.stops, SyblSoundEvent.sonarCharge);
    expect(
      SyblSoundEvent.stopMissileEnRoute.stops,
      SyblSoundEvent.sonarMissileEnRoute,
    );
    expect(SyblSoundEvent.stopAmbience.stops, SyblSoundEvent.sonarAmbience);
    expect(
      [
        for (final e in SyblSoundEvent.values)
          if (e.looping) e,
      ],
      [
        SyblSoundEvent.sonarCharge,
        SyblSoundEvent.sonarMissileEnRoute,
        SyblSoundEvent.sonarAmbience,
      ],
    );
    expect(SyblSoundEvent.stopIncomingWarning.stops, isNull);
    expect(SyblSoundEvent.sonarTargetTick.voices, 4);
    expect(SyblSoundEvent.sonarTargetLock.voices, 4);
  });

  test('spam-tapped sonar sounds layer on separate voices', () {
    var made = 0;
    final voices = SoundVoices<int>(
      SyblSoundEvent.sonarPulse.voices,
      () => made++,
    );
    final played = [for (var i = 0; i < 6; i++) voices.take()];
    expect(played, [0, 1, 2, 3, 0, 1]);
    expect(made, 4);
    expect(SyblSoundEvent.notification.voices, 1);
  });

  for (final boundary in [
    'stop',
    'setAudioContext',
    'setReleaseMode',
    'setSourceUrl',
    'resume',
  ]) {
    for (final action in ['stop', 'replace', 'switch', 'dispose']) {
      test('ring $action fences an in-flight $boundary', () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        String? ringId;
        var armed = false;
        final audio = await _mockAudioChannels(
          beforeReply: (call) async {
            if (armed && call.player == ringId && call.method == boundary) {
              armed = false;
              entered.complete();
              await release.future;
            }
          },
        );
        final player = SyblSoundPlayer();
        Future<void>? disposal;
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await (disposal ?? player.dispose());
        });
        await player.handle(SyblSoundEvent.incomingRing);
        ringId = audio.calls
            .firstWhere((call) => call.method == 'resume')
            .player;
        audio.calls.clear();
        armed = true;
        final starting = player.handle(SyblSoundEvent.outgoingRing);
        await entered.future.timeout(const Duration(seconds: 3));
        final retiring = action == 'dispose'
            ? disposal = player.dispose()
            : player.handle(
                action == 'switch'
                    ? SyblSoundEvent.incomingRing
                    : SyblSoundEvent.stopRinging,
              );
        final replacing = action == 'replace'
            ? player.handle(SyblSoundEvent.incomingRing)
            : Future<void>.value();
        var retired = false;
        unawaited(retiring.then((_) => retired = true));
        await Future<void>.delayed(Duration.zero);
        expect(retired, isFalse, reason: 'retirement must drain pending audio');
        release.complete();
        await Future.wait([starting, retiring, replacing]);
        final ringCalls = audio.calls
            .where(
              (call) =>
                  call.player == ringId && call.method != 'getCurrentPosition',
            )
            .toList();
        final resumes = ringCalls.where((call) => call.method == 'resume');
        final playsReplacement = action == 'replace' || action == 'switch';
        expect(
          resumes.length,
          (boundary == 'resume' ? 1 : 0) + (playsReplacement ? 1 : 0),
        );
        if (playsReplacement) {
          expect(ringCalls.last.method, 'resume');
          expect(
            ringCalls
                .lastWhere((call) => call.method == 'setSourceUrl')
                .arguments
                .toString(),
            contains('incoming_ring.wav'),
          );
          if (boundary == 'resume') {
            final first = ringCalls.indexWhere(
              (call) => call.method == 'resume',
            );
            expect(
              ringCalls
                  .sublist(first + 1, ringCalls.length - 1)
                  .any((call) => call.method == 'stop'),
              isTrue,
            );
          }
        } else {
          expect(
            ringCalls.last.method,
            action == 'dispose' ? 'dispose' : 'stop',
          );
        }
        if (action == 'dispose') {
          final count = audio.calls.length;
          await player.handle(SyblSoundEvent.incomingRing);
          expect(audio.calls, hasLength(count));
        }
      });
    }
  }

  test('ring queue recovers after a platform failure', () async {
    var failContext = true;
    final audio = await _mockAudioChannels(
      beforeReply: (call) async {
        if (call.method == 'setAudioContext' && failContext) {
          failContext = false;
          throw PlatformException(code: 'output-unavailable');
        }
      },
    );
    final player = SyblSoundPlayer();
    addTearDown(player.dispose);
    await player.handle(SyblSoundEvent.outgoingRing);
    await player.handle(SyblSoundEvent.stopRinging);
    await player.handle(SyblSoundEvent.incomingRing);
    expect(audio.calls.where((call) => call.method == 'resume'), hasLength(1));
    expect(
      audio.calls
          .lastWhere((call) => call.method != 'getCurrentPosition')
          .method,
      'resume',
    );
  });

  test('charge loop cancellation serializes a rapid restart', () async {
    final firstResume = Completer<void>.sync();
    final releaseFirstResume = Completer<void>.sync();
    final audio = await _mockAudioChannels(
      firstResumeEntered: firstResume,
      releaseFirstResume: releaseFirstResume,
    );
    final player = SyblSoundPlayer();
    addTearDown(player.dispose);
    final start = player.handle(SyblSoundEvent.sonarCharge);
    await firstResume.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail(
        'charge did not resume: ${audio.calls.map((call) => call.method).toList()}',
      ),
    );
    final stop = player.handle(SyblSoundEvent.stopCharge);
    final restart = player.handle(SyblSoundEvent.sonarCharge);
    releaseFirstResume.complete();
    await Future.wait([start, stop, restart]);
    final resumesAt = [
      for (var i = 0; i < audio.calls.length; i++)
        if (audio.calls[i].method == 'resume') i,
    ];
    expect(resumesAt, hasLength(2));
    expect(
      audio.calls
          .sublist(resumesAt.first + 1, resumesAt.last)
          .map((call) => call.method),
      contains('stop'),
    );
  });

  test(
    'incoming warning crossfades to close warning and kill starts promptly',
    () async {
      final audio = await _mockAudioChannels();
      final player = SyblSoundPlayer();
      addTearDown(player.dispose);
      await player.handle(SyblSoundEvent.sonarIncomingMissile);
      final incomingId = audio.calls
          .firstWhere(
            (call) =>
                call.method == 'setSourceUrl' &&
                call.arguments.toString().contains('sonar_IncomingMissile.wav'),
          )
          .player;
      await player.handle(SyblSoundEvent.sonarIncomingMissileClose);
      final closeSource = audio.calls.indexWhere(
        (call) =>
            call.method == 'setSourceUrl' &&
            call.arguments.toString().contains(
              'sonar_IncomingMissileClose.wav',
            ),
      );
      expect(closeSource, greaterThanOrEqualTo(0));
      final closeId = audio.calls
          .firstWhere(
            (call) =>
                call.method == 'setSourceUrl' &&
                call.arguments.toString().contains(
                  'sonar_IncomingMissileClose.wav',
                ),
          )
          .player;
      final closeResume = audio.calls.indexWhere(
        (call) => call.method == 'resume' && call.player == closeId,
      );
      expect(closeResume, greaterThan(closeSource));
      List<double> volumesFor(String playerId) => audio.calls
          .where(
            (call) => call.method == 'setVolume' && call.player == playerId,
          )
          .map((call) => (call.arguments as Map)['volume'] as double)
          .toList();
      final incomingVolumes = volumesFor(incomingId);
      final closeVolumes = volumesFor(closeId);
      expect(incomingVolumes, hasLength(11));
      final incomingRampUp = incomingVolumes.sublist(0, 6);
      final incomingRampDown = incomingVolumes.sublist(6);
      final closeRampDown = closeVolumes.sublist(0, 5);
      final closeRampUp = closeVolumes.sublist(5);
      expect(incomingRampUp.first, 0);
      expect(incomingRampUp.last, 0.35);
      expect(incomingRampDown.last, 0);
      expect(closeRampDown.last, 0);
      expect(closeRampUp.first, 0);
      expect(closeRampUp.last, 0.35);
      for (var i = 1; i < incomingRampUp.length; i++) {
        expect(incomingRampUp[i], greaterThanOrEqualTo(incomingRampUp[i - 1]));
      }
      for (var i = 1; i < incomingRampDown.length; i++) {
        expect(incomingRampDown[i], lessThanOrEqualTo(incomingRampDown[i - 1]));
      }
      for (var i = 1; i < closeRampDown.length; i++) {
        expect(closeRampDown[i], lessThanOrEqualTo(closeRampDown[i - 1]));
      }
      for (var i = 1; i < closeRampUp.length; i++) {
        expect(closeRampUp[i], greaterThanOrEqualTo(closeRampUp[i - 1]));
      }

      final stopCallsBeforeKill = audio.calls
          .where((call) => call.method == 'stop' && call.player == incomingId)
          .length;
      await player.handle(SyblSoundEvent.sonarIncomingMissileKill);
      final killId = audio.calls
          .firstWhere(
            (call) =>
                call.method == 'setSourceUrl' &&
                call.arguments.toString().contains(
                  'sonar_IncomingMissileKill.wav',
                ),
          )
          .player;
      final killResume = audio.calls.indexWhere(
        (call) => call.method == 'resume' && call.player == killId,
      );
      expect(killResume, greaterThanOrEqualTo(0));
      expect(
        audio.calls
            .where((call) => call.method == 'stop' && call.player == incomingId)
            .length,
        stopCallsBeforeKill,
        reason: 'the 250 ms warning fade must not delay the kill sound start',
      );
    },
  );
}
