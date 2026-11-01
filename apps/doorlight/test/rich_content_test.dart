import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/dm_topics.dart';
import 'package:sybl/state/rich_content.dart';

void main() {
  test('durable sticker is only an immutable asset ID and presentation', () {
    const content = StickerContent(
      'sybl.chubby-cats.angry.v1',
      StickerPresentation.hologram,
    );
    expect(
      StickerContent.parse(content.encode())!.presentation,
      StickerPresentation.hologram,
    );
    final fields = jsonDecode(content.encode()) as Map<String, dynamic>;
    for (final field in ['url', 'path', 'author', 'command']) {
      expect(
        StickerContent.parse(jsonEncode({...fields, field: 'untrusted'})),
        isNull,
      );
    }
    expect(
      StickerContent.parse(jsonEncode({...fields, 'assetId': '../../image'})),
      isNull,
    );
    expect(StickerContent.parse(jsonEncode({...fields, 'v': 1.0})), isNull);
    expect(StickerContent.parse(' ' * 1025), isNull);
    expect(
      StickerContent.parse(
        const StickerContent(
          'unknown.pack.v1',
          StickerPresentation.inline,
        ).encode(),
      ),
      isNotNull,
    );
  });

  test(
    'GIF metadata bounds source work and voice requires explicit semantics',
    () {
      expect(
        FileMediaContent.parse(
          const GifMediaContent(512, 512, 64, 1280).encode(),
        ),
        isA<GifMediaContent>(),
      );
      expect(
        FileMediaContent.parse(
          const GifMediaContent(512, 512, 65, 1300).encode(),
        ),
        isNull,
      );
      expect(
        FileMediaContent.parse(const VoiceMediaContent(300).encode()),
        isA<VoiceMediaContent>(),
      );
      expect(
        FileMediaContent.parse(const VoiceMediaContent(299).encode()),
        isNull,
      );
      expect(
        FileMediaContent.parse(const VoiceMediaContent(120001).encode()),
        isNull,
      );
      expect(
        FileMediaContent.parse('{"v":1,"kind":"voice","filename":"voice.m4a"}'),
        isNull,
      );
    },
  );

  test(
    'routing rejects conflicting tags and group slugs are not DM topics',
    () {
      final direct = ConversationScope(
        accountId: 'a',
        peerId: 'p',
        conversationId: 'c',
      );
      final group = ConversationScope(
        accountId: 'a',
        peerId: 'group:c',
        conversationId: 'c',
      );
      expect(RichContentRoute.parse(direct, {})!.dmTopicId, 'main');
      expect(
        RichContentRoute.parse(group, {
          RichContentWire.roomField: 'games',
        })!.groupRoomId,
        'games',
      );
      expect(
        RichContentRoute.parse(direct, {DmTopicWire.itemField: 'games'}),
        isNull,
      );
      expect(
        RichContentRoute.parse(group, {DmTopicWire.itemField: 'a' * 32}),
        isNull,
      );
      expect(
        RichContentRoute.parse(direct, {RichContentWire.roomField: 'games'}),
        isNull,
      );
      expect(
        RichContentRoute.parse(group, {
          RichContentWire.roomField: 'games',
          DmTopicWire.itemField: 'main',
        }),
        isNull,
      );
      expect(RichContentWire.validOperation('a' * 32), isTrue);
      expect(RichContentWire.validOperation('a' * 31), isFalse);
    },
  );
}
