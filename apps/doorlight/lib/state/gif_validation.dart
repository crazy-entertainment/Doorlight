import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decode every structurally admitted frame once, disposing it immediately.
/// Source canvas/frame bounds precede codec construction; display sizing is
/// never treated as a limit on decoder work.
Future<ValidatedGif?> validateGifDecode(Uint8List source) async {
  if (source.length > ValidatedGif.maximumBytes) return null;
  final bytes = Uint8List.fromList(source);
  final validated = ValidatedGif.parse(bytes);
  if (validated == null) return null;
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    if (codec.frameCount != validated.frames) return null;
    for (var index = 0; index < validated.frames; index++) {
      final frame = await codec.getNextFrame();
      try {
        if (frame.image.width != validated.width ||
            frame.image.height != validated.height) {
          return null;
        }
      } finally {
        frame.image.dispose();
      }
    }
    return validated;
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}

/// Structural work bounds are checked before handing any GIF to an image codec.
/// This is not a claim that Flutter target/cache dimensions constrain decoding.
final class ValidatedGif {
  const ValidatedGif(
    this.width,
    this.height,
    this.frames,
    this.cycleMilliseconds,
  );

  final int width;
  final int height;
  final int frames;
  final int cycleMilliseconds;

  static const maximumBytes = 4 * 1024 * 1024;
  static const maximumCanvasWork = 16777216;

  static ValidatedGif? parse(Uint8List bytes) {
    if (bytes.length < 14 || bytes.length > maximumBytes) return null;
    try {
      return _GifReader(bytes).parse();
    } on FormatException {
      return null;
    }
  }
}

final class _GifReader {
  _GifReader(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  Never invalid() => throw const FormatException('Invalid or over-limit GIF');
  int byte() {
    if (offset >= bytes.length) invalid();
    return bytes[offset++];
  }

  int word() => byte() | (byte() << 8);
  void skip(int count) {
    if (count < 0 || count > bytes.length - offset) invalid();
    offset += count;
  }

  void subBlocks({bool requireData = false}) {
    var data = false;
    for (;;) {
      final count = byte();
      if (count == 0) {
        if (requireData && !data) invalid();
        return;
      }
      data = true;
      skip(count);
    }
  }

  ValidatedGif parse() {
    final signature = String.fromCharCodes(bytes.take(6));
    if (signature != 'GIF87a' && signature != 'GIF89a') invalid();
    offset = 6;
    final width = word();
    final height = word();
    if (width < 1 ||
        height < 1 ||
        width > 512 ||
        height > 512 ||
        width > height * 4 ||
        height > width * 4) {
      invalid();
    }
    final packed = byte();
    byte(); // Background index.
    byte(); // Pixel aspect ratio; canvas work uses encoded pixel dimensions.
    final globalPalette = packed & 0x80 != 0;
    if (globalPalette) skip(3 * (1 << ((packed & 7) + 1)));
    var frames = 0;
    var cycle = 0;
    var delay = 100;
    var controlPending = false;
    for (;;) {
      switch (byte()) {
        case 0x3b:
          if (offset != bytes.length || frames == 0 || controlPending) {
            invalid();
          }
          return ValidatedGif(width, height, frames, cycle);
        case 0x21:
          final label = byte();
          if (label == 0xf9) {
            if (controlPending || byte() != 4) invalid();
            final flags = byte();
            if (flags & 0xe0 != 0 || ((flags >> 2) & 7) > 3) invalid();
            final hundredths = word();
            delay = hundredths < 2 ? 100 : hundredths * 10;
            byte(); // Transparent color index.
            if (byte() != 0) invalid();
            controlPending = true;
          } else if (label == 0xff) {
            if (byte() != 11) invalid();
            skip(11);
            subBlocks();
          } else if (label == 0xfe) {
            subBlocks();
          } else {
            // Plain-text rendering and unknown extensions are outside v1.
            invalid();
          }
        case 0x2c:
          final left = word();
          final top = word();
          final frameWidth = word();
          final frameHeight = word();
          if (frameWidth < 1 ||
              frameHeight < 1 ||
              left + frameWidth > width ||
              top + frameHeight > height) {
            invalid();
          }
          final flags = byte();
          if (flags & 0x18 != 0) invalid();
          final localPalette = flags & 0x80 != 0;
          if (localPalette) skip(3 * (1 << ((flags & 7) + 1)));
          if (!globalPalette && !localPalette) invalid();
          final codeSize = byte();
          if (codeSize < 2 || codeSize > 8) invalid();
          subBlocks(requireData: true);
          frames++;
          cycle += delay;
          if (frames > 120 ||
              cycle > 10000 ||
              width * height * frames > ValidatedGif.maximumCanvasWork) {
            invalid();
          }
          delay = 100;
          controlPending = false;
        default:
          invalid();
      }
    }
  }
}
