import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/gif_library.dart';
import 'package:sybl/state/rich_content.dart';

GifLibraryEntry entry(int id, [int bytes = 1]) => GifLibraryEntry(
  hash: id.toRadixString(16).padLeft(64, '0'),
  bytes: bytes,
  media: const GifMediaContent(1, 1, 1, 100),
);

void main() {
  test(
    'entry capacity refuses new imports without evicting existing content',
    () {
      var index = GifLibraryIndex.empty();
      for (var id = 0; id < 32; id++) {
        index = index.add(entry(id))!;
      }
      expect(index.add(entry(32)), isNull);
      expect(index.entries.length, 32);
      expect(index.add(entry(0)), same(index));
      final removed = index.remove(entry(0).hash);
      expect(removed.add(entry(32)), isNotNull);
      expect(index.entries.length, 32);
    },
  );
  test(
    'byte capacity and hash deduplication are independent of entry count',
    () {
      var index = GifLibraryIndex.empty();
      for (var id = 0; id < 16; id++) {
        index = index.add(entry(id, 4 * 1024 * 1024))!;
      }
      expect(index.totalBytes, 64 * 1024 * 1024);
      expect(index.add(entry(16)), isNull);
      expect(index.add(entry(0, 4 * 1024 * 1024)), same(index));
      expect(index.add(entry(0, 3)), isNull);
    },
  );
  test('index roundtrip and malformed entries fail closed', () {
    final index = GifLibraryIndex.empty().add(entry(1))!;
    expect(
      GifLibraryIndex.parse(index.encode())!.entries.keys,
      index.entries.keys,
    );
    expect(
      GifLibraryIndex.parse(jsonEncode({'v': 1.0, 'entries': []})),
      isNull,
    );
    expect(
      GifLibraryIndex.parse(
        jsonEncode({
          'v': 1,
          'entries': [entry(1).toMap(), entry(1).toMap()],
        }),
      ),
      isNull,
    );
    expect(
      GifLibraryEntry.parse({...entry(1).toMap(), 'hash': '../outside'}),
      isNull,
    );
    expect(GifLibraryEntry.parse({...entry(1).toMap(), 'bytes': 1.0}), isNull);
  });
}
