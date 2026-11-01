import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/m4a_boxes.dart';

Uint8List box(String type, List<int> payload) => Uint8List.fromList([
  ...((ByteData(4)..setUint32(0, payload.length + 8)).buffer.asUint8List()),
  ...type.codeUnits,
  ...payload,
]);

void main() {
  test('nested framing retains exact payload bounds and owns its snapshot', () {
    final source = box('moov', box('trak', [1, 2, 3]));
    final parser = M4aBoxes(source);
    source.fillRange(0, source.length, 0);
    final movie = M4aBoxes.one(parser.children(), 'moov');
    final track = M4aBoxes.one(parser.inside(movie), 'trak');
    expect(track.start, 16);
    expect(track.length, 3);
    expect(parser.uint(track.start, 3, track.end), 0x010203);
    expect(() => parser.uint(track.start, 4, track.end), throwsFormatException);
  });

  test(
    'rejects truncation, open lengths, overflow, extensions and duplicates',
    () {
      for (final data in <List<int>>[
        [0, 0, 0],
        [0, 0, 0, 0, ...'mdat'.codeUnits],
        [0, 0, 0, 9, ...'mdat'.codeUnits],
        [0, 0, 0, 1, ...'mdat'.codeUnits, ...List.filled(8, 255)],
        box('uuid', []),
      ]) {
        expect(
          () => M4aBoxes(Uint8List.fromList(data)).children(),
          throwsFormatException,
        );
      }
      final parser = M4aBoxes(
        Uint8List.fromList([...box('moov', []), ...box('moov', [])]),
      );
      expect(
        () => M4aBoxes.one(parser.children(), 'moov'),
        throwsFormatException,
      );
    },
  );

  test('global box and nesting budgets also bound repeated traversal', () {
    final parser = M4aBoxes(box('moov', []));
    for (var i = 0; i < 512; i++) {
      parser.children();
    }
    expect(() => parser.children(), throwsFormatException);
    final nested = M4aBoxes(box('moov', []));
    expect(() => nested.children(depth: 9), throwsFormatException);
    expect(
      () => M4aBoxes(Uint8List(M4aBoxes.maximumBytes + 1)),
      throwsFormatException,
    );
  });
}
