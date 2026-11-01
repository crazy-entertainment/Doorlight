import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/chat_archive.dart';

ArchivedChat _chat(String label, {int items = 1, String text = 'hi'}) =>
    ArchivedChat(
      peerLabel: label,
      archivedAt: DateTime.utc(2026, 10, 8),
      topics: const {'0123456789abcdef0123456789abcdef': 'trip'},
      items: [
        for (var i = 0; i < items; i++)
          ArchivedChatItem(
            mine: i.isEven,
            at: DateTime.utc(2026),
            topic: 'main',
            text: text,
          ),
      ],
    );

void main() {
  late Directory root;
  late ChatArchiveStore store;
  String sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sybl-chat-archive-');
    store = ChatArchiveStore(() async => root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('round-trips text, sticker and file items', () async {
    final chat = ArchivedChat(
      peerLabel: 'Mara',
      archivedAt: DateTime.utc(2026, 10, 8),
      topics: const {},
      items: [
        ArchivedChatItem(mine: true, at: DateTime.utc(2026), topic: 'main', text: 'a'),
        ArchivedChatItem(
          mine: false,
          at: DateTime.utc(2026),
          topic: 'main',
          stickerId: 'wave',
        ),
        ArchivedChatItem(
          mine: false,
          at: DateTime.utc(2026),
          topic: 'main',
          fileName: 'x.pdf',
          fileSize: 3,
          fileDownloaded: true,
        ),
      ],
    );
    expect(await store.write('acc1', 'peer', chat), ChatArchiveWriteResult.saved);
    final listed = (await store.list('acc1'))!.single;
    expect(listed.id, ChatArchiveStore.idFor('peer'));
    expect(listed.chat!.items.map((item) => item.text), ['a', null, null]);
    expect(listed.chat!.items[1].stickerId, 'wave');
    expect(listed.chat!.items[2].fileDownloaded, isTrue);
  });

  test('item and byte bounds refuse without writing', () async {
    expect(
      await store.write(
        'acc1',
        'peer',
        _chat('big', items: ChatArchiveStore.maximumItems + 1),
      ),
      ChatArchiveWriteResult.tooLarge,
    );
    expect(
      await store.write('acc1', 'peer', _chat('big', text: 'x' * (4 << 20))),
      ChatArchiveWriteResult.tooLarge,
    );
    expect(await store.list('acc1'), isEmpty);
  });

  test('archive count is bounded but a rewrite is allowed', () async {
    for (var i = 0; i < ChatArchiveStore.maximumArchives; i++) {
      expect(
        await store.write('acc1', 'peer-$i', _chat('P$i')),
        ChatArchiveWriteResult.saved,
      );
    }
    expect(
      await store.write('acc1', 'one-more', _chat('X')),
      ChatArchiveWriteResult.full,
    );
    expect(
      await store.write('acc1', 'peer-0', _chat('P0 again')),
      ChatArchiveWriteResult.saved,
    );
  });

  test('writes leave no temporary files behind', () async {
    await store.write('acc1', 'peer', _chat('A'));
    await store.write('acc1', 'peer', _chat('B'));
    final names = Directory('${root.path}${sep}acc1')
        .listSync()
        .map((entry) => entry.path.split(sep).last)
        .toList();
    expect(names, ['${ChatArchiveStore.idFor('peer')}.json']);
    expect((await store.list('acc1'))!.single.chat!.peerLabel, 'B');
  });

  test('a corrupt file is listed as unreadable and can be deleted', () async {
    await Directory('${root.path}${sep}acc1').create();
    final id = ChatArchiveStore.idFor('peer');
    await File('${root.path}${sep}acc1$sep$id.json').writeAsString('{nope');
    final entry = (await store.list('acc1'))!.single;
    expect(entry.chat, isNull);
    expect(await store.delete('acc1', entry.id), isTrue);
    expect(await store.list('acc1'), isEmpty);
  });

  test('accounts are isolated and deleteAccount removes only one', () async {
    await store.write('acc1', 'peer', _chat('A'));
    await store.write('acc2', 'peer', _chat('B'));
    expect(await store.deleteAccount('acc1'), isTrue);
    expect(await Directory('${root.path}${sep}acc1').exists(), isFalse);
    expect((await store.list('acc2'))!.single.chat!.peerLabel, 'B');
  });

  test('an unsafe account ID never becomes a path', () async {
    expect(
      await store.write('../escape', 'peer', _chat('A')),
      ChatArchiveWriteResult.unavailable,
    );
    expect(await store.deleteAccount('../escape'), isFalse);
  });

  test('no storage means nothing to delete', () async {
    final none = ChatArchiveStore(() async => null);
    expect(await none.deleteAccount('acc1'), isTrue);
    expect(await none.list('acc1'), isEmpty);
  });
}
