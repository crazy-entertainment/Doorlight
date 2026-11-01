import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/gif_library.dart';
import 'package:sybl/state/gif_library_store.dart';
import 'package:sybl/state/rich_content.dart';

import 'gif_validation_test.dart' show gif;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late Directory root;
  late GifLibraryStore store;
  setUp(() async {
    scratch = await Directory('../../local/tmp').createTemp('gif-library-test-');
    root = Directory('${scratch.path}/library');
    store = GifLibraryStore(() async => root);
  });
  tearDown(() async => scratch.delete(recursive: true));

  test(
    'imports deduplicate, survive restart, and remove only the private copy',
    () async {
      final source = await File(
        '${scratch.path}/original.gif',
      ).writeAsBytes(gif(frames: 3));
      expect(await store.import(source.path), GifLibraryResult.saved);
      expect(await store.import(source.path), GifLibraryResult.saved);
      expect(store.index.entries.length, 1);
      final hash = store.index.entries.keys.single;
      final restarted = GifLibraryStore(() async => root);
      expect(await restarted.reload(), isTrue);
      expect(await restarted.read(hash), await source.readAsBytes());
      expect(await restarted.remove(hash), GifLibraryResult.removed);
      expect(await restarted.reload(), isTrue);
      expect(restarted.index.entries, isEmpty);
      expect(await source.exists(), isTrue);
      expect(await File('${root.path}/$hash.gif').exists(), isFalse);
    },
  );

  test(
    'valid but mismatched metadata rejects intact media without rewriting it',
    () async {
      final sourceBytes = gif(frames: 3);
      final source = await File(
        '${scratch.path}/original.gif',
      ).writeAsBytes(sourceBytes);
      expect(await store.import(source.path), GifLibraryResult.saved);
      final entry = store.index.entries.values.single;
      final mismatched = GifLibraryIndex.empty().add(
        GifLibraryEntry(
          hash: entry.hash,
          bytes: entry.bytes,
          media: const GifMediaContent(2, 2, 3, 300),
        ),
      )!;
      final indexFile = File('${root.path}/index.json');
      final indexText = mismatched.encode();
      await indexFile.writeAsString(indexText);
      final restarted = GifLibraryStore(() async => root);
      expect(await restarted.reload(), isFalse);
      expect(restarted.available, isFalse);
      expect(await indexFile.readAsString(), indexText);
      expect(
        await File('${root.path}/${entry.fileName}').readAsBytes(),
        sourceBytes,
      );
      expect(await source.readAsBytes(), sourceBytes);
    },
  );

  test(
    'corrupt indexed content fails closed without overwriting evidence',
    () async {
      final source = await File(
        '${scratch.path}/original.gif',
      ).writeAsBytes(gif());
      expect(await store.import(source.path), GifLibraryResult.saved);
      final hash = store.index.entries.keys.single;
      final indexBefore = await File('${root.path}/index.json').readAsBytes();
      await File('${root.path}/$hash.gif').writeAsBytes([1, 2, 3]);
      expect(await store.reload(), isFalse);
      expect(await store.read(hash), isNull);
      expect(await store.import(source.path), GifLibraryResult.unavailable);
      expect(await File('${root.path}/index.json').readAsBytes(), indexBefore);
    },
  );

  test(
    'unpublished interrupted copies are reclaimed, concurrent imports serialize',
    () async {
      expect(await store.reload(), isTrue);
      final orphan = File('${root.path}/${'a' * 64}.gif');
      await orphan.writeAsBytes(gif());
      expect(await store.reload(), isTrue);
      expect(await orphan.exists(), isFalse);
      final first = await File(
        '${scratch.path}/first.gif',
      ).writeAsBytes(gif(frames: 2));
      final second = await File(
        '${scratch.path}/second.gif',
      ).writeAsBytes(gif(frames: 3));
      expect(
        await Future.wait([
          store.import(first.path),
          store.import(second.path),
        ]),
        [GifLibraryResult.saved, GifLibraryResult.saved],
      );
      expect(store.index.entries.length, 2);
      expect(await store.reload(), isTrue);
      expect(store.index.entries.length, 2);
    },
  );

  test('invalid input does not consume a library slot', () async {
    final source = await File(
      '${scratch.path}/large.gif',
    ).writeAsBytes(gif(width: 513));
    expect(await store.import(source.path), GifLibraryResult.invalid);
    expect(store.index.entries, isEmpty);
    expect(await store.reload(), isTrue);
  });

  test(
    'retired save cannot publish its index or alter the owned source',
    () async {
      final source = await File(
        '${scratch.path}/received.gif',
      ).writeAsBytes(gif(frames: 3));
      final bytes = await source.readAsBytes();
      var current = true;
      var validations = 0;
      expect(
        await store.import(
          source.path,
          isCurrent: () => current,
          authorize: (_) async {
            validations++;
            if (validations == 2) current = false;
            return true;
          },
        ),
        GifLibraryResult.stale,
      );
      expect(store.index.entries, isEmpty);
      expect(await source.readAsBytes(), bytes);
      expect(await store.reload(), isTrue);
      expect(store.index.entries, isEmpty);
      expect(
        await root.list().where((file) => file.path.endsWith('.gif')).isEmpty,
        isTrue,
      );
    },
  );
}
