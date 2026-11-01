import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/group_topics.dart';

void main() {
  test('general uses an envelope and legacy plain messages map to general', () {
    expect(GroupTopicCodec.encode('general', 'hello'), '[#general] hello');
    final decoded = GroupTopicCodec.decode('hello');
    expect(decoded.topicId, 'general');
    expect(decoded.body, 'hello');
  });

  test('topic-looking user text remains in its selected topic', () {
    final wire = GroupTopicCodec.encode('general', '[#games] literal');
    final decoded = GroupTopicCodec.decode(wire);
    expect(decoded.topicId, 'general');
    expect(decoded.body, '[#games] literal');
  });

  test('dynamic topic ids use the backwards-readable durable prefix', () {
    expect(
      GroupTopicCodec.encode('family-news', 'hello'),
      '[#family-news] hello',
    );
    final decoded = GroupTopicCodec.decode('[#family-news] hello');
    expect(decoded.topicId, 'family-news');
    expect(decoded.body, 'hello');
  });

  test('group layout round-trips collections and stable room ids', () {
    final layout = GroupLayout.defaults
        .addCollection('Family')
        .addRoom('Photos', GroupRoomKind.text, collectionId: 'family')
        .addRoom('Kitchen', GroupRoomKind.voice);
    final decoded = GroupLayoutCodec.decode(GroupLayoutCodec.encode(layout));

    expect(decoded.collections.map((item) => item.name), contains('Family'));
    expect(decoded.room('photos')?.collectionId, 'family');
    expect(decoded.room('kitchen')?.kind, GroupRoomKind.voice);
  });

  test('removing a collection safely keeps its rooms outside', () {
    final layout = GroupLayout.defaults.removeCollection('topics');
    expect(layout.room('general')?.collectionId, isNull);
    expect(
      layout.rooms.where((room) => room.kind == GroupRoomKind.text),
      isNotEmpty,
    );
  });

  test('malformed or foreign descriptions keep the compatible defaults', () {
    expect(
      GroupLayoutCodec.decode('ordinary description').room('general'),
      isNotNull,
    );
    expect(
      GroupLayoutCodec.decode(
        '${GroupLayoutCodec.marker}not_base64!',
      ).room('general'),
      isNotNull,
    );
  });
}
