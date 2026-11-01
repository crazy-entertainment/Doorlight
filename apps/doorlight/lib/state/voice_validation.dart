import 'dart:typed_data';

import 'aac_lc_config.dart';
import 'm4a_boxes.dart';
import 'voice_sample_table.dart';

final class ValidatedVoice {
  const ValidatedVoice._(this.durationMilliseconds);
  final int durationMilliseconds;
  static const maximumBytes = M4aBoxes.maximumBytes;

  static ValidatedVoice? parse(Uint8List bytes) {
    try {
      return _VoiceParser(M4aBoxes(bytes)).parse();
    } on FormatException {
      return null;
    }
  }
}

final class _VoiceParser {
  _VoiceParser(this.boxes);
  final M4aBoxes boxes;
  void require(bool value) {
    if (!value) throw const FormatException('voice_format');
  }

  int read(M4aBox box, int offset, [int width = 4]) =>
      boxes.uint(box.start + offset, width, box.end);
  String text(M4aBox box, int offset) {
    read(box, offset);
    return String.fromCharCodes(
      boxes.bytes.sublist(box.start + offset, box.start + offset + 4),
    );
  }

  void allowed(List<M4aBox> list, Set<String> types) {
    require(list.every((box) => types.contains(box.type)));
    for (final type in types.difference({'free'})) {
      require(list.where((box) => box.type == type).length <= 1);
    }
  }

  (int, int) time(M4aBox box, {required bool movie}) {
    final version = read(box, 0, 1);
    require(read(box, 1, 3) == 0 && (version == 0 || version == 1));
    require(
      box.length ==
          (movie ? (version == 0 ? 100 : 112) : (version == 0 ? 24 : 36)),
    );
    final scale = read(box, version == 0 ? 12 : 20);
    final ticks = read(box, version == 0 ? 16 : 24, version == 0 ? 4 : 8);
    require(scale > 0 && scale <= 1000000 && ticks > 0);
    return (scale, ticks);
  }

  ValidatedVoice parse() {
    final root = boxes.children();
    allowed(root, {'ftyp', 'moov', 'mdat', 'free'});
    final brand = M4aBoxes.one(root, 'ftyp');
    require(brand.length >= 8 && brand.length <= 64 && brand.length % 4 == 0);
    require({'M4A ', 'isom', 'iso2', 'mp41', 'mp42'}.contains(text(brand, 0)));
    final media = M4aBoxes.one(root, 'mdat');
    require(media.length > 0);
    final movie = boxes.inside(M4aBoxes.one(root, 'moov'));
    allowed(movie, {'mvhd', 'trak', 'udta', 'free'});
    // Metadata is never used as codec, timing or file ownership authority.
    for (final metadata in movie.where((box) => box.type == 'udta')) {
      require(metadata.length <= 65536);
    }
    final (movieScale, movieTicks) = time(
      M4aBoxes.one(movie, 'mvhd'),
      movie: true,
    );
    require(
      movieTicks * 1000 >= 300 * movieScale && movieTicks <= 120 * movieScale,
    );
    final track = boxes.inside(M4aBoxes.one(movie, 'trak'));
    allowed(track, {'tkhd', 'mdia', 'edts', 'free'});
    final header = M4aBoxes.one(track, 'tkhd');
    final version = read(header, 0, 1);
    require(version == 0 || version == 1);
    require(header.length == (version == 0 ? 84 : 96));
    require(
      read(header, version == 0 ? 20 : 28, version == 0 ? 4 : 8) == movieTicks,
    );
    final mediaBoxes = boxes.inside(M4aBoxes.one(track, 'mdia'));
    allowed(mediaBoxes, {'mdhd', 'hdlr', 'minf'});
    final (scale, ticks) = time(M4aBoxes.one(mediaBoxes, 'mdhd'), movie: false);
    require(scale == 48000);
    final handler = M4aBoxes.one(mediaBoxes, 'hdlr');
    require(
      handler.length >= 24 &&
          handler.length <= 1024 &&
          read(handler, 0) == 0 &&
          text(handler, 8) == 'soun',
    );
    final minf = boxes.inside(M4aBoxes.one(mediaBoxes, 'minf'));
    allowed(minf, {'smhd', 'dinf', 'stbl'});
    final sound = M4aBoxes.one(minf, 'smhd');
    require(sound.length == 8 && read(sound, 0) == 0);
    final data = boxes.inside(M4aBoxes.one(minf, 'dinf'));
    allowed(data, {'dref'});
    final references = M4aBoxes.one(data, 'dref');
    require(read(references, 0) == 0 && read(references, 4) == 1);
    final urls = boxes.inside(references, skip: 8);
    require(
      urls.length == 1 &&
          urls.single.type == 'url ' &&
          urls.single.length == 4 &&
          read(urls.single, 0) == 1,
    );
    final tables = boxes.inside(M4aBoxes.one(minf, 'stbl'));
    allowed(tables, {
      'stsd',
      'stts',
      'stsc',
      'stsz',
      'stco',
      'co64',
      'sgpd',
      'sbgp',
    });
    final descriptions = M4aBoxes.one(tables, 'stsd');
    require(read(descriptions, 0) == 0 && read(descriptions, 4) == 1);
    final entries = boxes.inside(descriptions, skip: 8);
    require(entries.length == 1 && entries.single.type == 'mp4a');
    final audio = entries.single;
    require(
      read(audio, 0, 6) == 0 &&
          read(audio, 6, 2) == 1 &&
          read(audio, 8, 8) == 0,
    );
    require(
      read(audio, 16, 2) == 1 &&
          read(audio, 18, 2) == 16 &&
          read(audio, 20) == 0 &&
          read(audio, 24) == 48000 * 65536,
    );
    final config = boxes.inside(audio, skip: 28);
    allowed(config, {'esds', 'btrt'});
    final esds = M4aBoxes.one(config, 'esds');
    require(
      AacLcConfig.acceptsEsds(
        Uint8List.sublistView(boxes.bytes, esds.start, esds.end),
      ),
    );
    for (final rate in config.where((box) => box.type == 'btrt')) {
      require(rate.length == 12);
    }
    final samples = VoiceSampleTable.parse(boxes, tables, media);
    final roll = tables.where((box) => box.type == 'sgpd').toList();
    final groups = tables.where((box) => box.type == 'sbgp').toList();
    require(roll.length == groups.length);
    if (roll.isNotEmpty) {
      final description = roll.single;
      require(
        description.length == 18 &&
            read(description, 0) == 0x01000000 &&
            text(description, 4) == 'roll' &&
            read(description, 8) == 2 &&
            read(description, 12) == 1 &&
            read(description, 16, 2) == 0xffff,
      );
      final group = groups.single;
      require(
        group.length == 20 &&
            read(group, 0) == 0 &&
            text(group, 4) == 'roll' &&
            read(group, 8) == 1 &&
            read(group, 12) == samples.samples &&
            read(group, 16) == 1,
      );
    }
    require(samples.durationTicks == ticks);
    var trim = 0;
    final edits = track.where((box) => box.type == 'edts');
    if (edits.isNotEmpty) {
      final editBoxes = boxes.inside(edits.single);
      allowed(editBoxes, {'elst'});
      final edit = M4aBoxes.one(editBoxes, 'elst');
      final version = read(edit, 0, 1);
      require(
        (version == 0 || version == 1) &&
            read(edit, 1, 3) == 0 &&
            read(edit, 4) == 1,
      );
      final width = version == 0 ? 4 : 8;
      require(
        edit.length == 12 + 2 * width && read(edit, 8, width) == movieTicks,
      );
      trim = read(edit, 8 + width, width);
      require(trim <= 2048 && read(edit, 8 + 2 * width) == 65536);
    }
    // AAC encodes full access units. The final unit may have fewer than 1024
    // audible samples after priming/edit trimming; bound that tail padding and
    // permit at most one movie-timescale tick of rounding.
    final tail = (ticks - trim) * movieScale - movieTicks * scale;
    require(
      ticks > trim && tail >= -scale && tail <= 1023 * movieScale + scale,
    );
    return ValidatedVoice._((movieTicks * 1000 / movieScale).round());
  }
}
