import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/m4a_boxes.dart';
import 'package:sybl/state/voice_sample_table.dart';

List<int> words(List<int> values) => [
  for (final value in values)
    ...(ByteData(4)..setUint32(0, value)).buffer.asUint8List(),
];
List<int> box(String type, List<int> bytes) => [
  ...words([bytes.length + 8]),
  ...type.codeUnits,
  ...bytes,
];
VoiceSampleTable parse({
  int offset = 8,
  int count = 16,
  int delta = 1024,
  int sampleSize = 4,
  int chunkSamples = 16,
  int description = 1,
}) {
  final bytes = Uint8List.fromList([
    ...box('mdat', List.filled(64, 1)),
    ...box('stsz', words([0, sampleSize, count])),
    ...box('stts', words([0, 1, count, delta])),
    ...box('stco', words([0, 1, offset])),
    ...box('stsc', words([0, 1, 1, chunkSamples, description])),
  ]);
  final parser = M4aBoxes(bytes);
  final boxes = parser.children();
  return VoiceSampleTable.parse(parser, boxes, boxes.first);
}

void main() {
  test('counts only samples whose ranges are owned by media data', () {
    final table = parse();
    expect(table.samples, 16);
    expect(table.durationTicks, 16384);
    expect(table.payloadBytes, 64);
  });
  test(
    'rejects offsets into headers and outside media, overrun and missing samples',
    () {
      for (final offset in [0, 7, 9, 72, 0xffffffff]) {
        expect(() => parse(offset: offset), throwsFormatException);
      }
      expect(() => parse(sampleSize: 5), throwsFormatException);
      expect(() => parse(chunkSamples: 15), throwsFormatException);
      expect(() => parse(chunkSamples: 17), throwsFormatException);
      expect(() => parse(description: 2), throwsFormatException);
    },
  );
  test('rejects unbounded counts and forged AAC sample timing', () {
    expect(() => parse(count: 0xffffffff), throwsFormatException);
    expect(() => parse(count: 0), throwsFormatException);
    expect(() => parse(delta: 1), throwsFormatException);
    expect(() => parse(delta: 2048), throwsFormatException);
    expect(() => parse(sampleSize: 8193), throwsFormatException);
  });
}
