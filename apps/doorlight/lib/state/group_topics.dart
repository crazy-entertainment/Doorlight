import 'dart:convert';

enum GroupRoomKind {
  text('text'),
  voice('voice');

  const GroupRoomKind(this.wireValue);
  final String wireValue;
}

final class GroupRoom {
  const GroupRoom({
    required this.id,
    required this.name,
    required this.kind,
    this.collectionId,
  });

  final String id;
  final String name;
  final GroupRoomKind kind;
  final String? collectionId;

  GroupRoom copyWith({
    String? name,
    String? collectionId,
    bool outside = false,
  }) => GroupRoom(
    id: id,
    name: name ?? this.name,
    kind: kind,
    collectionId: outside ? null : collectionId ?? this.collectionId,
  );
}

final class GroupCollection {
  const GroupCollection({required this.id, required this.name});

  final String id;
  final String name;

  GroupCollection copyWith({String? name}) =>
      GroupCollection(id: id, name: name ?? this.name);
}

final class GroupLayout {
  const GroupLayout({required this.collections, required this.rooms});

  static const defaults = GroupLayout(
    collections: [
      GroupCollection(id: 'topics', name: 'Topics'),
      GroupCollection(id: 'voice-chats', name: 'Voice chats'),
    ],
    rooms: [
      GroupRoom(
        id: 'general',
        name: 'general',
        kind: GroupRoomKind.text,
        collectionId: 'topics',
      ),
      GroupRoom(
        id: 'games',
        name: 'games',
        kind: GroupRoomKind.text,
        collectionId: 'topics',
      ),
      GroupRoom(
        id: 'clips',
        name: 'clips',
        kind: GroupRoomKind.text,
        collectionId: 'topics',
      ),
      GroupRoom(
        id: 'voice',
        name: 'voice',
        kind: GroupRoomKind.voice,
        collectionId: 'voice-chats',
      ),
    ],
  );

  final List<GroupCollection> collections;
  final List<GroupRoom> rooms;

  GroupRoom get initialTextRoom =>
      rooms.firstWhere((room) => room.kind == GroupRoomKind.text);

  GroupRoom? room(String id) {
    for (final room in rooms) {
      if (room.id == id) return room;
    }
    return null;
  }

  GroupLayout addCollection(String name) {
    final normalized = GroupLayoutCodec.normalizeName(name);
    if (normalized == null) return this;
    return GroupLayout(
      collections: [
        ...collections,
        GroupCollection(
          id: GroupLayoutCodec.uniqueId(normalized, [
            ...collections.map((item) => item.id),
            ...rooms.map((item) => item.id),
          ]),
          name: normalized,
        ),
      ],
      rooms: rooms,
    );
  }

  GroupLayout renameCollection(String id, String name) {
    final normalized = GroupLayoutCodec.normalizeName(name);
    if (normalized == null) return this;
    return GroupLayout(
      collections: [
        for (final item in collections)
          item.id == id ? item.copyWith(name: normalized) : item,
      ],
      rooms: rooms,
    );
  }

  GroupLayout removeCollection(String id) => GroupLayout(
    collections: [
      for (final item in collections)
        if (item.id != id) item,
    ],
    rooms: [
      for (final room in rooms)
        room.collectionId == id ? room.copyWith(outside: true) : room,
    ],
  );

  GroupLayout addRoom(String name, GroupRoomKind kind, {String? collectionId}) {
    final normalized = GroupLayoutCodec.normalizeName(name);
    if (normalized == null ||
        (collectionId != null &&
            !collections.any((item) => item.id == collectionId))) {
      return this;
    }
    return GroupLayout(
      collections: collections,
      rooms: [
        ...rooms,
        GroupRoom(
          id: GroupLayoutCodec.uniqueId(normalized, [
            ...collections.map((item) => item.id),
            ...rooms.map((item) => item.id),
          ]),
          name: normalized,
          kind: kind,
          collectionId: collectionId,
        ),
      ],
    );
  }

  GroupLayout renameRoom(String id, String name) {
    final normalized = GroupLayoutCodec.normalizeName(name);
    if (normalized == null) return this;
    return GroupLayout(
      collections: collections,
      rooms: [
        for (final room in rooms)
          room.id == id ? room.copyWith(name: normalized) : room,
      ],
    );
  }
}

abstract final class GroupLayoutCodec {
  static const marker = 'sybl-group-layout:v1:';
  static const maxDescriptionBytes = 8192;
  static const maxCollections = 16;
  static const maxRooms = 64;
  static final RegExp _id = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');

  static String? normalizeName(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        utf8.encode(name).length > 64 ||
        name.runes.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return name;
  }

  static String uniqueId(String name, Iterable<String> used) {
    var base = name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (base.isEmpty || !RegExp(r'^[a-z0-9]').hasMatch(base)) base = 'room';
    if (base.length > 28) base = base.substring(0, 28);
    final occupied = used.toSet();
    if (!occupied.contains(base)) return base;
    for (var suffix = 2; ; suffix++) {
      final candidate = '$base-$suffix';
      if (!occupied.contains(candidate)) return candidate;
    }
  }

  static String encode(GroupLayout layout) {
    _validate(layout);
    final json = jsonEncode({
      'c': [
        for (final item in layout.collections) {'i': item.id, 'n': item.name},
      ],
      'r': [
        for (final room in layout.rooms)
          {
            'i': room.id,
            'n': room.name,
            'k': room.kind.wireValue,
            if (room.collectionId != null) 'c': room.collectionId,
          },
      ],
    });
    final payload = base64UrlEncode(utf8.encode(json)).replaceAll('=', '');
    final description = '$marker$payload';
    if (utf8.encode(description).length > maxDescriptionBytes) {
      throw ArgumentError.value(
        layout,
        'layout',
        'encoded layout is too large',
      );
    }
    return description;
  }

  static GroupLayout decode(String description) {
    if (!description.startsWith(marker)) return GroupLayout.defaults;
    try {
      if (utf8.encode(description).length > maxDescriptionBytes) {
        return GroupLayout.defaults;
      }
      var payload = description.substring(marker.length);
      payload += '=' * ((4 - payload.length % 4) % 4);
      final value = jsonDecode(utf8.decode(base64Url.decode(payload)));
      if (value is! Map || value['c'] is! List || value['r'] is! List) {
        return GroupLayout.defaults;
      }
      final collections = <GroupCollection>[];
      for (final raw in value['c'] as List) {
        if (raw is! Map || raw['i'] is! String || raw['n'] is! String) {
          return GroupLayout.defaults;
        }
        collections.add(
          GroupCollection(id: raw['i'] as String, name: raw['n'] as String),
        );
      }
      final rooms = <GroupRoom>[];
      for (final raw in value['r'] as List) {
        if (raw is! Map ||
            raw['i'] is! String ||
            raw['n'] is! String ||
            raw['k'] is! String ||
            (raw.containsKey('c') && raw['c'] is! String)) {
          return GroupLayout.defaults;
        }
        final kind = switch (raw['k']) {
          'text' => GroupRoomKind.text,
          'voice' => GroupRoomKind.voice,
          _ => null,
        };
        if (kind == null) return GroupLayout.defaults;
        rooms.add(
          GroupRoom(
            id: raw['i'] as String,
            name: raw['n'] as String,
            kind: kind,
            collectionId: raw['c'] as String?,
          ),
        );
      }
      final layout = GroupLayout(
        collections: List.unmodifiable(collections),
        rooms: List.unmodifiable(rooms),
      );
      _validate(layout);
      return layout;
    } on Object {
      return GroupLayout.defaults;
    }
  }

  static void _validate(GroupLayout layout) {
    if (layout.collections.length > maxCollections ||
        layout.rooms.isEmpty ||
        layout.rooms.length > maxRooms) {
      throw const FormatException('invalid group layout size');
    }
    final ids = <String>{};
    for (final item in layout.collections) {
      if (!_id.hasMatch(item.id) ||
          normalizeName(item.name) != item.name ||
          !ids.add(item.id)) {
        throw const FormatException('invalid group collection');
      }
    }
    final collectionIds = ids.toSet();
    var hasTextRoom = false;
    for (final room in layout.rooms) {
      if (!_id.hasMatch(room.id) ||
          normalizeName(room.name) != room.name ||
          !ids.add(room.id) ||
          (room.collectionId != null &&
              !collectionIds.contains(room.collectionId))) {
        throw const FormatException('invalid group room');
      }
      hasTextRoom |= room.kind == GroupRoomKind.text;
    }
    if (!hasTextRoom) {
      throw const FormatException('group layout needs a text room');
    }
  }
}

final class GroupTopicMessage {
  const GroupTopicMessage(this.topicId, this.body);
  final String topicId;
  final String body;
}

abstract final class GroupTopicCodec {
  static final RegExp _prefix = RegExp(r'^\[#([a-z0-9][a-z0-9-]{0,31})\] ');

  static String encode(String topicId, String body) {
    if (!GroupLayoutCodec._id.hasMatch(topicId)) {
      throw ArgumentError.value(topicId, 'topicId');
    }
    return '[#$topicId] $body';
  }

  static GroupTopicMessage decode(String body) {
    final match = _prefix.firstMatch(body);
    if (match == null) return GroupTopicMessage('general', body);
    return GroupTopicMessage(match.group(1)!, body.substring(match.end));
  }
}
