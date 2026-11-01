import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/gif_validation.dart';

Uint8List gif({
  int width = 1,
  int height = 1,
  int frames = 1,
  int delay = 2,
  int left = 0,
  int frameWidth = 1,
}) {
  List<int> word(int value) => [value & 255, value >> 8];
  return Uint8List.fromList([
    ...'GIF89a'.codeUnits,
    ...word(width),
    ...word(height),
    0x80,
    0,
    0,
    0,
    0,
    0,
    255,
    255,
    255,
    for (var index = 0; index < frames; index++) ...[
      0x21,
      0xf9,
      4,
      0,
      ...word(delay),
      0,
      0,
      0x2c,
      ...word(left),
      0,
      0,
      ...word(frameWidth),
      1,
      0,
      0,
      2,
      2,
      0x44,
      0x01,
      0,
    ],
    0x3b,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full codec validation accepts bounded frames and refuses non-GIF data',
    () async {
      final result = await validateGifDecode(gif(frames: 3));
      expect(result?.frames, 3);
      expect(result?.width, 1);
      expect(await validateGifDecode(Uint8List.fromList([1, 2, 3])), isNull);
      expect(await validateGifDecode(gif(width: 513)), isNull);
    },
  );
  test('valid GIF metadata and delay normalization', () {
    final parsed = ValidatedGif.parse(gif(frames: 3))!;
    expect(parsed.frames, 3);
    expect(parsed.cycleMilliseconds, 60);
    expect(ValidatedGif.parse(gif(delay: 0))!.cycleMilliseconds, 100);
    expect(ValidatedGif.parse(gif(frames: 120))!.frames, 120);
    expect(ValidatedGif.parse(gif(frames: 121)), isNull);
    expect(ValidatedGif.parse(gif(delay: 1000))!.cycleMilliseconds, 10000);
    expect(ValidatedGif.parse(gif(delay: 1001)), isNull);
  });

  test(
    'canvas work, screen dimensions, ratio and frame rectangles bound decoding',
    () {
      expect(
        ValidatedGif.parse(gif(width: 512, height: 512, frames: 64)),
        isNotNull,
      );
      expect(
        ValidatedGif.parse(gif(width: 512, height: 512, frames: 65)),
        isNull,
      );
      expect(ValidatedGif.parse(gif(width: 513, height: 512)), isNull);
      expect(ValidatedGif.parse(gif(width: 5, height: 1)), isNull);
      expect(ValidatedGif.parse(gif(width: 0)), isNull);
      expect(ValidatedGif.parse(gif(left: 1)), isNull);
      expect(ValidatedGif.parse(gif(frameWidth: 2)), isNull);
      expect(
        ValidatedGif.parse(Uint8List(ValidatedGif.maximumBytes + 1)),
        isNull,
      );
    },
  );

  test('every truncated structural prefix and trailing bytes fail closed', () {
    final bytes = gif();
    for (var length = 0; length < bytes.length; length++) {
      expect(
        ValidatedGif.parse(Uint8List.sublistView(bytes, 0, length)),
        isNull,
        reason: '$length',
      );
    }
    expect(ValidatedGif.parse(Uint8List.fromList([...bytes, 0])), isNull);
    bytes[0] = 0;
    expect(ValidatedGif.parse(bytes), isNull);
  });
}
