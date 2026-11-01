import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/gif_recents.dart';
import 'package:sybl/state/gif_library_store.dart';

String hash(int value) => value.toRadixString(16).padLeft(64, '0');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'recent ordering is bounded, deduplicated, and contains only hashes',
    () {
      var recent = GifRecents.empty();
      for (var i = 0; i < 40; i++) {
        recent = recent.use(hash(i))!;
      }
      expect(recent.hashes.length, 12);
      recent = recent.use(hash(30))!;
      expect(recent.hashes.first, hash(30));
      expect(recent.hashes.toSet().length, 12);
      expect(
        recent.encode().length,
        lessThanOrEqualTo(GifRecents.maximumBytes),
      );
      expect(GifRecents.parse(recent.encode())!.hashes, recent.hashes);
      expect(recent.order([hash(1), hash(30), hash(39)], (entry) => entry), [
        hash(30),
        hash(39),
        hash(1),
      ]);
      expect(recent.use('../outside'), isNull);
      expect(
        GifRecents.parse(
          jsonEncode({
            'v': 1,
            'hashes': [hash(1), hash(1)],
          }),
        ),
        isNull,
      );
      expect(
        GifRecents.parse(
          jsonEncode({'v': 1, 'hashes': List.generate(13, hash)}),
        ),
        isNull,
      );
      expect(GifRecents.parse(jsonEncode({'v': 1.0, 'hashes': []})), isNull);
    },
  );
  test(
    'starter recents survive restart without personal media or quota consumption',
    () async {
      final scratch = await Directory(
        '../../local/tmp',
      ).createTemp('gif-recents-');
      addTearDown(() => scratch.delete(recursive: true));
      final root = Directory('${scratch.path}/library');
      final store = GifLibraryStore(() async => root);
      for (var i = 0; i < 20; i++) {
        expect(await store.recordUsed(hash(i)), isTrue);
      }
      expect(store.index.entries, isEmpty);
      expect(store.index.totalBytes, 0);
      final restarted = GifLibraryStore(() async => root);
      expect(await restarted.reload(), isTrue);
      expect(restarted.recents.hashes, store.recents.hashes);
      expect(
        await root.list().where((entry) => entry.path.endsWith('.gif')).isEmpty,
        isTrue,
      );
      final file = File('${root.path}/recent.json');
      await file.writeAsString('{broken');
      expect(await restarted.reload(), isTrue);
      expect(restarted.recents.hashes, isEmpty);
      expect(await restarted.recordUsed(hash(3)), isFalse);
      expect(await file.readAsString(), '{broken');
    },
  );
}
