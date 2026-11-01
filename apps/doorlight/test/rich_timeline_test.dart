import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/rich_content.dart';

void main() {
  final direct = ConversationScope(
    accountId: 'account',
    peerId: 'peer',
    conversationId: 'conversation',
  );
  final group = ConversationScope(
    accountId: 'account',
    peerId: 'group:group',
    conversationId: 'group',
  );
  const parser = TimelineItemParser();
  Map<String, Object?> envelope(ConversationScope scope) => {
    ...scope.toMap(),
    'daemonId': 'commit',
    'versionId': 'commit',
    'authorId': 'peer',
    'timestampSeconds': 1,
    'mimeType': RichContentWire.stickerMime,
    'body': const StickerContent(
      'sybl.chubby-cats.angry.v1',
      StickerPresentation.inline,
    ).encode(),
    'operationId': 'a' * 32,
  };
  TimelineParseResult parse(
    ConversationScope scope,
    Map<String, Object?> value,
  ) => parser.parse(
    expectedScope: scope,
    localAuthorId: 'local',
    allowedRemoteAuthorIds: {'peer'},
    value: value,
  );

  test(
    'departed group author requires native authenticated history evidence',
    () {
      final historical = {
        ...envelope(group),
        'authorId': 'departed',
        'authenticatedGroupHistory': true,
      };
      expect(parse(group, historical).item!.authorId, 'departed');
      expect(
        parse(group, {
          ...historical,
          'authenticatedGroupHistory': false,
        }).isAccepted,
        isFalse,
      );
      expect(
        parse(group, {
          ...historical,
          'authenticatedGroupHistory': 'true',
        }).isAccepted,
        isFalse,
      );
      expect(
        parse(direct, {
          ...envelope(direct),
          'authorId': 'third-party',
          'authenticatedGroupHistory': true,
        }).isAccepted,
        isFalse,
      );
    },
  );

  test('sticker retains signed operation and room through receipt merge', () {
    final first =
        parse(group, {...envelope(group), 'roomId': 'games'}).item!
            as TimelineStickerItem;
    expect(first.sticker!.assetId, 'sybl.chubby-cats.angry.v1');
    final updated = first.withDeliveryState(TimelineDeliveryState.read);
    expect(updated.operationId, 'a' * 32);
    expect(updated.roomId, 'games');
    expect(
      first.mergeCompatible(updated)!.deliveryState,
      TimelineDeliveryState.read,
    );
    final conflicting = parse(group, {
      ...envelope(group),
      'roomId': 'general',
    }).item!;
    expect(first.mergeCompatible(conflicting), isNull);
  });

  test(
    'bounded unsupported stickers are placeholders and editions are rejected',
    () {
      final unknown =
          parse(direct, {...envelope(direct), 'body': '{"v":2}'}).item!
              as TimelineStickerItem;
      expect(unknown.sticker, isNull);
      for (final delta in [
        {'operation': 'edit'},
        {'deleted': true},
        {'versionId': 'edition'},
        {'body': 'x' * 1025},
        {'body': '😀' * 257},
      ]) {
        expect(
          parse(direct, {...envelope(direct), ...delta}).isAccepted,
          isFalse,
        );
      }
    },
  );

  test(
    'conflicting signed routing and malformed operation IDs are quarantined',
    () {
      expect(
        parse(direct, {...envelope(direct), 'roomId': 'games'}).isAccepted,
        isFalse,
      );
      expect(
        parse(group, {...envelope(group), 'topicTagged': true}).isAccepted,
        isFalse,
      );
      expect(
        parse(group, {...envelope(group), 'roomId': 'INVALID'}).isAccepted,
        isFalse,
      );
      expect(
        parse(direct, {...envelope(direct), 'operationId': 'wrong'}).isAccepted,
        isFalse,
      );
    },
  );

  test(
    'file metadata classifies only explicit valid voice and survives copies',
    () {
      final file = {
        ...envelope(direct),
        'mimeType': TimelineWireContract.fileMimeType,
        'body': {
          'fileId': 'file',
          'displayName': 'voice.m4a',
          'totalBytes': 100,
        },
      };
      final ordinary = parse(direct, file).item! as TimelineFileItem;
      expect(ordinary.media, isNull);
      final voice =
          parse(direct, {
                ...file,
                'mediaMetadata': const VoiceMediaContent(500).encode(),
              }).item!
              as TimelineFileItem;
      expect(voice.media, isA<VoiceMediaContent>());
      expect(
        voice.withDeliveryState(TimelineDeliveryState.read).mediaMetadata,
        voice.mediaMetadata,
      );
      expect(voice.mergeCompatible(ordinary), isNull);
      final unsupported =
          parse(direct, {...file, 'mediaMetadata': '{"v":2}'}).item!
              as TimelineFileItem;
      expect(unsupported.media, isNull);
    },
  );
}
