import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/voice_validation.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/rich_content.dart';

void main() {
  test(
    'voice preparation uses validated duration without publishing',
    () async {
      final file = File('test/fixtures/voice-aac-lc.m4a');
      final stage = await validateComposerVoice(file.path, file.lengthSync());
      expect(stage?.kind, ComposerMediaKind.voice);
      expect(
        (FileMediaContent.parse(stage?.mediaMetadata) as VoiceMediaContent)
            .durationMilliseconds,
        1000,
      );
      expect(
        await validateComposerVoice(file.path, file.lengthSync() - 1),
        isNull,
      );
    },
  );
  test(
    'rejects forged track type, sample rate and duration in a real container',
    () {
      final source = File('test/fixtures/voice-aac-lc.m4a').readAsBytesSync();
      int payload(String type) {
        for (var i = 4; i <= source.length - 4; i++) {
          if (String.fromCharCodes(source.sublist(i, i + 4)) == type) {
            return i + 4;
          }
        }
        throw StateError('missing test box');
      }

      for (final change in <(String, int, int)>[
        ('hdlr', 8, 0x76696465), // video handler
        ('mp4a', 24, 44100 * 65536),
        ('mdhd', 16, 48000), // sample timeline disagreement
        ('stco', 8, 0), // samples in file header
      ]) {
        final bytes = Uint8List.fromList(source);
        ByteData.sublistView(
          bytes,
        ).setUint32(payload(change.$1) + change.$2, change.$3);
        expect(ValidatedVoice.parse(bytes), isNull, reason: change.$1);
      }
    },
  );
  test('validates an independently encoded one-second mono AAC-LC fixture', () {
    final bytes = File('test/fixtures/voice-aac-lc.m4a').readAsBytesSync();
    expect(ValidatedVoice.parse(bytes)?.durationMilliseconds, 1000);
    expect(
      ValidatedVoice.parse(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      isNull,
    );
    expect(
      ValidatedVoice.parse(Uint8List(ValidatedVoice.maximumBytes + 1)),
      isNull,
    );
  });
}
