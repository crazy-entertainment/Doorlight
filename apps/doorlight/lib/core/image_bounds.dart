import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// Check allocation budgets before entering a raster decoder. In particular,
/// image's JPEG startDecode allocates coefficient blocks while reading SOF.
image.Decoder? boundedRasterDecoder(
  Uint8List bytes, {
  required int maxEncodedBytes,
  int maxDimension = 4096,
  int maxPixels = 4 * 1024 * 1024,
}) {
  if (bytes.length < 12 || bytes.length > maxEncodedBytes) return null;
  bool dimensions(int w, int h) =>
      w > 0 &&
      h > 0 &&
      w <= maxDimension &&
      h <= maxDimension &&
      w * h <= maxPixels;
  try {
    final image.Decoder decoder;
    if (bytes[0] == 0xff && bytes[1] == 0xd8) {
      if (!_boundedJpeg(bytes, dimensions)) return null;
      decoder = image.JpegDecoder();
    } else if (bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71) {
      decoder = image.PngDecoder();
    } else if (bytes[0] == 71 && bytes[1] == 73 && bytes[2] == 70) {
      decoder = image.GifDecoder();
    } else if (String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      decoder = image.WebPDecoder();
    } else if (bytes[0] == 66 && bytes[1] == 77) {
      if (!_boundedBmp(bytes, dimensions)) return null;
      decoder = image.BmpDecoder();
    } else {
      return null; // Do not invoke decoders for unrelated document/container formats.
    }
    final info = decoder.startDecode(bytes);
    if (info == null || !dimensions(info.width, info.height)) return null;
    if (decoder is image.WebPDecoder) {
      if (decoder.info!.hasAnimation) return null;
    } else if (info.numFrames != 1) {
      return null;
    }
    if (decoder is image.GifDecoder &&
        decoder.info!.frames.any(
          (frame) => !dimensions(frame.width, frame.height),
        )) {
      return null;
    }
    if (decoder is image.PngDecoder && decoder.info.isAnimated) return null;
    return decoder;
  } catch (_) {
    return null;
  }
}

bool _boundedBmp(Uint8List bytes, bool Function(int, int) dimensions) {
  if (bytes.length < 54) return false;
  final data = ByteData.sublistView(bytes);
  final header = data.getUint32(14, Endian.little);
  if (![40, 56, 108, 124].contains(header) || 14 + header > bytes.length) {
    return false;
  }
  final width = data.getInt32(18, Endian.little);
  final height = data.getInt32(22, Endian.little).abs();
  final bits = data.getUint16(28, Endian.little);
  final compression = data.getUint32(30, Endian.little);
  final colors = data.getUint32(46, Endian.little);
  final pixelsAt = data.getUint32(10, Endian.little);
  if (!dimensions(width, height) ||
      data.getUint16(26, Endian.little) != 1 ||
      ![1, 4, 8, 16, 24, 32].contains(bits) ||
      ![0, 3, 6].contains(compression)) {
    return false;
  }
  final maskBytes = header == 40 && compression != 0
      ? (compression == 6 ? 16 : 12)
      : 0;
  final metadataEnd = 14 + header + maskBytes;
  if (metadataEnd > bytes.length ||
      pixelsAt < metadataEnd ||
      pixelsAt > bytes.length) {
    return false;
  }
  if (bits <= 8) {
    if (compression != 0 || colors > 1 << bits) return false;
    final count = colors == 0 ? 1 << bits : colors;
    // BmpInfo allocates this palette inside startDecode, before pixel bounds.
    if (count * 4 > pixelsAt - metadataEnd) return false;
  }
  return true;
}

bool _boundedJpeg(Uint8List bytes, bool Function(int, int) dimensions) {
  var offset = 2;
  var frameSeen = false;
  while (offset < bytes.length) {
    if (bytes[offset++] != 0xff) return false;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return false;
    final marker = bytes[offset++];
    if (marker == 0xda) {
      return frameSeen; // The decoder validates scan contents.
    }
    if (marker == 0xd9 || marker == 0 || marker == 0xd8) return false;
    if (marker == 1 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return false;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return false;
    final isFrame =
        marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc;
    if (isFrame) {
      if (frameSeen || ![0xc0, 0xc1, 0xc2].contains(marker) || length < 8) {
        return false;
      }
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      final count = bytes[offset + 7];
      if (bytes[offset + 2] != 8 ||
          !dimensions(width, height) ||
          count < 1 ||
          count > 4 ||
          length != 8 + count * 3) {
        return false;
      }
      final ids = <int>{};
      var blocks = 0;
      for (var index = 0; index < count; index++) {
        final at = offset + 8 + index * 3;
        final h = bytes[at + 1] >> 4, v = bytes[at + 1] & 15;
        if (!ids.add(bytes[at]) ||
            h < 1 ||
            h > 4 ||
            v < 1 ||
            v > 4 ||
            bytes[at + 2] > 3) {
          return false;
        }
        blocks += h * v;
      }
      if (blocks > 10) return false;
      frameSeen = true;
    }
    offset += length;
  }
  return false;
}

/// Decode only one bounded static image. PNG's Dart decoder inflates the whole
/// IDAT stream, so verify its expansion budget with a non-retaining sink first.
image.Image? decodeBoundedRaster(
  Uint8List bytes, {
  required int maxEncodedBytes,
}) {
  final decoder = boundedRasterDecoder(bytes, maxEncodedBytes: maxEncodedBytes);
  if (decoder == null) return null;
  try {
    if (decoder is image.PngDecoder) {
      final info = decoder.info;
      // Includes 16-bit RGBA rows and Adam7 filter/rounding overhead.
      final sink = _ExpansionBudget(
        info.width * info.height * 8 + info.height * 8 + 65536,
      );
      final inflate = ZLibDecoder().startChunkedConversion(sink);
      final data = ByteData.sublistView(bytes);
      var offset = 8;
      while (offset + 12 <= bytes.length) {
        final length = data.getUint32(offset);
        if (length > bytes.length - offset - 12) return null;
        if (data.getUint32(offset + 4) == 0x49444154) {
          inflate.add(
            Uint8List.sublistView(bytes, offset + 8, offset + 8 + length),
          );
        }
        offset += length + 12;
      }
      inflate.close();
    }
    final pixels = decoder.decodeFrame(0);
    // PNG stores iCCP compressed during decode. JPEG export would later inflate
    // it without a limit, including after crop/resize clones the profile.
    // Profile/QR import needs pixels and orientation, not embedded ICC data.
    pixels?.iccProfile = null;
    return pixels;
  } catch (_) {
    return null;
  }
}

class _ExpansionBudget implements Sink<List<int>> {
  _ExpansionBudget(this.remaining);
  int remaining;
  @override
  void add(List<int> data) {
    remaining -= data.length;
    if (remaining < 0) {
      throw const FormatException('Image expansion exceeds budget');
    }
  }

  @override
  void close() {}
}
