import 'm4a_boxes.dart';

/// Verifies the byte ownership and decode-time budget of a non-fragmented AAC
/// track. No offsets from the file are followed before their bounds are checked.
final class VoiceSampleTable {
  const VoiceSampleTable(this.samples, this.durationTicks, this.payloadBytes);
  final int samples;
  final int durationTicks;
  final int payloadBytes;
  static const maximumSamples =
      5626; // 120 seconds at 48 kHz, plus encoder delay

  static VoiceSampleTable parse(
    M4aBoxes parser,
    List<M4aBox> tables,
    M4aBox media,
  ) {
    int read(M4aBox box, int offset, [int width = 4]) =>
        parser.uint(box.start + offset, width, box.end);
    void require(bool value) {
      if (!value) throw const FormatException('voice_sample_table');
    }

    int entries(M4aBox box, int stride) {
      require(read(box, 0) == 0);
      final count = read(box, 4);
      require(
        count > 0 &&
            count <= maximumSamples &&
            box.length == 8 + count * stride,
      );
      return count;
    }

    final sizesBox = M4aBoxes.one(tables, 'stsz');
    require(read(sizesBox, 0) == 0);
    final fixedSize = read(sizesBox, 4);
    final count = read(sizesBox, 8);
    require(
      count > 0 &&
          count <= maximumSamples &&
          sizesBox.length == 12 + (fixedSize == 0 ? count * 4 : 0),
    );
    final sizes = List<int>.generate(count, (index) {
      final size = fixedSize == 0 ? read(sizesBox, 12 + index * 4) : fixedSize;
      require(size > 0 && size <= 8192);
      return size;
    });

    final timing = M4aBoxes.one(tables, 'stts');
    final timeEntries = entries(timing, 8);
    var timedSamples = 0;
    var ticks = 0;
    for (var i = 0; i < timeEntries; i++) {
      final run = read(timing, 8 + i * 8);
      final delta = read(timing, 12 + i * 8);
      require(
        run > 0 && run <= count - timedSamples && delta > 0 && delta <= 1024,
      );
      // AAC-LC has 1024 PCM samples per access unit. Only the final unit may
      // describe a shortened tail; earlier short units can forge a small duration.
      require(delta == 1024 || (run == 1 && i == timeEntries - 1));
      timedSamples += run;
      ticks += run * delta;
    }
    require(timedSamples == count && ticks <= 120 * 48000 + 1024);

    final offsets = tables
        .where((box) => box.type == 'stco' || box.type == 'co64')
        .toList();
    require(offsets.length == 1);
    final chunkOffsets = offsets.single;
    final offsetWidth = chunkOffsets.type == 'co64' ? 8 : 4;
    final chunks = entries(chunkOffsets, offsetWidth);
    require(chunks <= count);
    final mapping = M4aBoxes.one(tables, 'stsc');
    final mappings = entries(mapping, 12);
    require(mappings <= chunks);
    final starts = <int>[];
    final perChunk = <int>[];
    for (var i = 0; i < mappings; i++) {
      final first = read(mapping, 8 + i * 12);
      final samples = read(mapping, 12 + i * 12);
      require(
        first >= 1 &&
            first <= chunks &&
            (i == 0 ? first == 1 : first > starts.last) &&
            samples >= 1 &&
            samples <= count &&
            read(mapping, 16 + i * 12) == 1,
      );
      starts.add(first);
      perChunk.add(samples);
    }
    var sample = 0;
    var mapIndex = 0;
    var previousEnd = media.start;
    var payloadBytes = 0;
    for (var chunk = 1; chunk <= chunks; chunk++) {
      if (mapIndex + 1 < mappings && starts[mapIndex + 1] == chunk) mapIndex++;
      final offset = read(
        chunkOffsets,
        8 + (chunk - 1) * offsetWidth,
        offsetWidth,
      );
      require(offset >= previousEnd && offset <= media.end);
      var end = offset;
      final amount = perChunk[mapIndex];
      require(amount <= count - sample);
      for (var i = 0; i < amount; i++) {
        final size = sizes[sample++];
        require(size <= media.end - end);
        end += size;
        payloadBytes += size;
      }
      previousEnd = end;
    }
    require(sample == count && payloadBytes > 0);
    return VoiceSampleTable(count, ticks, payloadBytes);
  }
}
