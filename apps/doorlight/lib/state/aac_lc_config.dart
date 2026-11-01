import 'dart:typed_data';

/// Validates the MPEG-4 elementary-stream descriptor in a voice sample entry.
/// Container timing and sample ownership are separate validation steps.
abstract final class AacLcConfig {
  static bool acceptsEsds(Uint8List bytes) {
    if (bytes.length < 4 || bytes.length > 256) return false;
    try {
      final reader = _Descriptors(bytes);
      if (reader.number(4) != 0) return false; // version and flags
      final es = reader.descriptor(3, bytes.length);
      reader.number(2); // local elementary stream identifier
      // Dependency, URL and OCR references are not part of local voice files.
      if (reader.number(1) != 0) return false;
      final decoder = reader.descriptor(4, es);
      if (reader.number(1) != 0x40 || reader.number(1) != 0x15) return false;
      reader.number(3); // decoder buffer size, not an allocation request
      final maximumRate = reader.number(4);
      final averageRate = reader.number(4);
      // Encoders may leave these descriptive fields zero. Actual payload size
      // and duration are enforced by the container validator.
      if (maximumRate > 192000 || averageRate > 192000) return false;
      final config = reader.descriptor(5, decoder);
      final length = config - reader.offset;
      if (length != 2 && length != 5) return false;
      // AAC-LC object type 2, frequency index 3 (48 kHz), one channel,
      // 1024 samples/frame, no core-coder dependency and no extension flag.
      if (reader.number(2) != 0x1188) return false;
      // Some writers include the explicit sync extension declaring no SBR.
      if (length == 5 && reader.number(3) != 0x56e500) return false;
      if (reader.offset != config || config != decoder) return false;
      final sl = reader.descriptor(6, es);
      if (sl - reader.offset != 1 || reader.number(1) != 2) return false;
      return reader.offset == sl && sl == es && es == bytes.length;
    } on FormatException {
      return false;
    }
  }
}

final class _Descriptors {
  _Descriptors(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  int number(int width) {
    if (offset > bytes.length - width) {
      throw const FormatException('voice_descriptor_bounds');
    }
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = value * 256 + bytes[offset++];
    }
    return value;
  }

  int descriptor(int tag, int parentEnd) {
    if (number(1) != tag) throw const FormatException('voice_descriptor_tag');
    var length = 0;
    for (var i = 0; i < 4; i++) {
      final next = number(1);
      length = length * 128 + (next & 127);
      if ((next & 128) == 0) {
        if (offset > parentEnd - length) {
          throw const FormatException('voice_descriptor_length');
        }
        return offset + length;
      }
    }
    throw const FormatException('voice_descriptor_length');
  }
}
