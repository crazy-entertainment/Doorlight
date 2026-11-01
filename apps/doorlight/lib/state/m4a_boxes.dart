import 'dart:typed_data';

/// Bounded ISO-BMFF box framing for the voice validator. This establishes only
/// framing; callers must validate track, codec, timing and sample ownership.
final class M4aBoxes {
  factory M4aBoxes(Uint8List source) {
    if (source.length > maximumBytes) {
      throw const FormatException('voice_size');
    }
    return M4aBoxes._(Uint8List.fromList(source));
  }

  M4aBoxes._(this.bytes) : _remaining = 512;

  static const maximumBytes = 2 * 1024 * 1024;
  final Uint8List bytes;
  int _remaining;

  int uint(int offset, int width, int end) {
    if (width < 1 ||
        width > 8 ||
        offset < 0 ||
        end > bytes.length ||
        offset > end - width) {
      throw const FormatException('voice_bounds');
    }
    var result = 0;
    for (var i = 0; i < width; i++) {
      // Values outside a signed 63-bit integer are not meaningful offsets or
      // times in this bounded file and must not wrap during accumulation.
      if (result > 0x7fffffffffffff) {
        throw const FormatException('voice_integer');
      }
      result = result * 256 + bytes[offset + i];
    }
    return result;
  }

  List<M4aBox> children({int start = 0, int? end, int depth = 0}) {
    final limit = end ?? bytes.length;
    if (depth > 8 || start < 0 || limit > bytes.length || start > limit) {
      throw const FormatException('voice_bounds');
    }
    final result = <M4aBox>[];
    var cursor = start;
    while (cursor < limit) {
      if (--_remaining < 0 || limit - cursor < 8) {
        throw const FormatException('voice_boxes');
      }
      var size = uint(cursor, 4, limit);
      final type = String.fromCharCodes(bytes.sublist(cursor + 4, cursor + 8));
      var header = 8;
      if (size == 1) {
        size = uint(cursor + 8, 8, limit);
        header = 16;
      }
      // Open-ended boxes and UUID extensions are outside our recorded subset.
      if (size < header || size > limit - cursor || type == 'uuid') {
        throw const FormatException('voice_box');
      }
      result.add(M4aBox(type, cursor + header, cursor + size, depth));
      cursor += size;
    }
    return result;
  }

  List<M4aBox> inside(M4aBox box, {int skip = 0}) =>
      children(start: box.start + skip, end: box.end, depth: box.depth + 1);

  static M4aBox one(List<M4aBox> boxes, String type) {
    final matches = boxes.where((box) => box.type == type).toList();
    if (matches.length != 1) throw const FormatException('voice_structure');
    return matches.single;
  }
}

final class M4aBox {
  const M4aBox(this.type, this.start, this.end, this.depth);
  final String type;
  final int start;
  final int end;
  final int depth;
  int get length => end - start;
}
