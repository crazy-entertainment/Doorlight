import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/aac_lc_config.dart';

List<int> descriptor(int tag, List<int> payload) => [
  tag,
  payload.length,
  ...payload,
];
Uint8List esds(List<int> config, {int objectType = 0x40, int flags = 0}) {
  final decoder = descriptor(4, [
    objectType,
    0x15,
    0,
    0,
    0,
    0,
    1,
    0x77,
    0,
    0,
    1,
    0x77,
    0,
    ...descriptor(5, config),
  ]);
  return Uint8List.fromList([
    0,
    0,
    0,
    0,
    ...descriptor(3, [
      0,
      1,
      flags,
      ...decoder,
      ...descriptor(6, [2]),
    ]),
  ]);
}

void main() {
  test('accepts mono 48 kHz AAC-LC with explicit absent SBR', () {
    expect(AacLcConfig.acceptsEsds(esds([0x11, 0x88])), isTrue);
    expect(AacLcConfig.acceptsEsds(esds([0x11, 0x88, 0x56, 0xe5, 0])), isTrue);
  });
  test(
    'rejects other codecs, channels, rates, extensions and external references',
    () {
      for (final config in [
        [0x12, 0x08], // 44.1 kHz
        [0x11, 0x90], // stereo
        [0x29, 0x88], // HE-AAC
        [0x11, 0x89], // extension flag
        [0x11, 0x88, 0x56, 0xe5, 0x80], // SBR present
      ]) {
        expect(AacLcConfig.acceptsEsds(esds(config)), isFalse);
      }
      expect(
        AacLcConfig.acceptsEsds(esds([0x11, 0x88], objectType: 0x66)),
        isFalse,
      );
      expect(AacLcConfig.acceptsEsds(esds([0x11, 0x88], flags: 0x40)), isFalse);
    },
  );
  test('rejects every truncation and trailing descriptors', () {
    final valid = esds([0x11, 0x88]);
    for (var i = 0; i < valid.length; i++) {
      expect(
        AacLcConfig.acceptsEsds(Uint8List.sublistView(valid, 0, i)),
        isFalse,
      );
    }
    expect(AacLcConfig.acceptsEsds(Uint8List.fromList([...valid, 0])), isFalse);
    final huge = Uint8List.fromList(valid)..[5] = 127;
    expect(AacLcConfig.acceptsEsds(huge), isFalse);
  });
}
