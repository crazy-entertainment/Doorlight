import 'dart:convert';
import 'dart:math';

import 'group_topics.dart';

abstract final class DmTopicWire {
  static const mainId = 'main';
  static const itemField = 'sybl-topic-v1';
  static const mimeType = 'application/x-sybl-dm-topic+json';
  static const maxEventBytes = 4096;
  static const maxStatePageItems = 200;
  static const maxCounter = 0x7fffffff;
  static final RegExp _customId = RegExp(r'^[a-f0-9]{32}$');

  static bool isCustomId(String? value) =>
      value != null && _customId.hasMatch(value);

  static String normalizeItemTopic(String? value) =>
      value == mainId || isCustomId(value) ? value! : mainId;
}

enum DmTopicOperation {
  create('create'),
  rename('rename'),
  archive('archive'),
  read('read'),

  /// The author removed the other member. Only meaningful in a 1:1 scope.
  left('left');

  const DmTopicOperation(this.wireValue);
  final String wireValue;

  static DmTopicOperation? fromWire(String value) {
    for (final operation in values) {
      if (operation.wireValue == value) return operation;
    }
    return null;
  }
}

final class DmTopicEvent {
  const DmTopicEvent._({
    required this.operation,
    required this.topicId,
    required this.revision,
    this.name,
    this.order,
    this.archived,
    this.messageId,
  });

  const DmTopicEvent.create({
    required String topicId,
    required int revision,
    required String name,
    required int order,
  }) : this._(
         operation: DmTopicOperation.create,
         topicId: topicId,
         revision: revision,
         name: name,
         order: order,
       );

  const DmTopicEvent.rename({
    required String topicId,
    required int revision,
    required String name,
  }) : this._(
         operation: DmTopicOperation.rename,
         topicId: topicId,
         revision: revision,
         name: name,
       );

  const DmTopicEvent.archive({
    required String topicId,
    required int revision,
    required bool archived,
  }) : this._(
         operation: DmTopicOperation.archive,
         topicId: topicId,
         revision: revision,
         archived: archived,
       );

  const DmTopicEvent.read({
    required String topicId,
    required int revision,
    required String messageId,
  }) : this._(
         operation: DmTopicOperation.read,
         topicId: topicId,
         revision: revision,
         messageId: messageId,
       );

  /// Exactly `{"v":1,"op":"left","topic":"main","revision":1}`.
  const DmTopicEvent.left()
    : this._(
        operation: DmTopicOperation.left,
        topicId: DmTopicWire.mainId,
        revision: 1,
      );

  final DmTopicOperation operation;
  final String topicId;
  final int revision;
  final String? name;
  final int? order;
  final bool? archived;
  final String? messageId;

  @override
  bool operator ==(Object other) =>
      other is DmTopicEvent &&
      operation == other.operation &&
      topicId == other.topicId &&
      revision == other.revision &&
      name == other.name &&
      order == other.order &&
      archived == other.archived &&
      messageId == other.messageId;

  @override
  int get hashCode => Object.hash(
    operation,
    topicId,
    revision,
    name,
    order,
    archived,
    messageId,
  );
}

abstract final class DmTopicEventCodec {
  static String encode(DmTopicEvent event) {
    final map = <String, Object>{
      'v': 1,
      'op': event.operation.wireValue,
      'topic': event.topicId,
      'revision': event.revision,
      if (event.name != null) 'name': event.name!,
      if (event.order != null) 'order': event.order!,
      if (event.archived != null) 'archived': event.archived!,
      if (event.messageId != null) 'message': event.messageId!,
    };
    if (!_isValid(event, map.keys.toSet())) {
      throw ArgumentError.value(event, 'event', 'Invalid DM topic event');
    }
    final encoded = jsonEncode(map);
    if (utf8.encode(encoded).length > DmTopicWire.maxEventBytes) {
      throw ArgumentError.value(event, 'event', 'DM topic event is too large');
    }
    return encoded;
  }

  static DmTopicEvent? decode(String value) {
    if (utf8.encode(value).length > DmTopicWire.maxEventBytes) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic> || decoded['v'] != 1) return null;
      final operationValue = decoded['op'];
      final topicId = decoded['topic'];
      final revision = decoded['revision'];
      if (operationValue is! String || topicId is! String || revision is! int) {
        return null;
      }
      final operation = DmTopicOperation.fromWire(operationValue);
      if (operation == null) return null;
      final event = DmTopicEvent._(
        operation: operation,
        topicId: topicId,
        revision: revision,
        name: decoded['name'] as String?,
        order: decoded['order'] as int?,
        archived: decoded['archived'] as bool?,
        messageId: decoded['message'] as String?,
      );
      return _isValid(event, decoded.keys.toSet()) ? event : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static bool _isValid(DmTopicEvent event, Set<String> keys) {
    final common = {'v', 'op', 'topic', 'revision'};
    if (event.operation == DmTopicOperation.left) {
      return keys.length == 4 &&
          keys.containsAll(common) &&
          event.topicId == DmTopicWire.mainId &&
          event.revision == 1;
    }
    if (event.revision < 1 ||
        event.revision > DmTopicWire.maxCounter ||
        (!DmTopicWire.isCustomId(event.topicId) &&
            !(event.operation == DmTopicOperation.read &&
                event.topicId == DmTopicWire.mainId))) {
      return false;
    }
    switch (event.operation) {
      case DmTopicOperation.create:
        return keys.length == 6 &&
            keys.containsAll({...common, 'name', 'order'}) &&
            GroupLayoutCodec.normalizeName(event.name ?? '') == event.name &&
            event.order != null &&
            event.order! >= 0 &&
            event.order! <= DmTopicWire.maxCounter;
      case DmTopicOperation.rename:
        return keys.length == 5 &&
            keys.containsAll({...common, 'name'}) &&
            GroupLayoutCodec.normalizeName(event.name ?? '') == event.name;
      case DmTopicOperation.archive:
        return keys.length == 5 &&
            keys.containsAll({...common, 'archived'}) &&
            event.archived != null;
      case DmTopicOperation.read:
        return keys.length == 5 &&
            keys.containsAll({...common, 'message'}) &&
            _isCommitId(event.messageId);
      case DmTopicOperation.left:
        return false;
    }
  }

  static bool _isCommitId(String? value) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= 128 &&
      value.runes.every((unit) => unit >= 0x21 && unit <= 0x7e);
}

String newDmTopicId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

typedef TopicRegister<T> = ({int revision, String commitId, T value});

sealed class DmTopicRecord {
  const DmTopicRecord({required this.commitId, required this.authorId});

  final String commitId;
  final String authorId;
}

final class DmTopicEventEnvelope extends DmTopicRecord {
  const DmTopicEventEnvelope({
    required super.commitId,
    required super.authorId,
    required this.position,
    required this.event,
  });

  final int position;
  final DmTopicEvent event;
}

final class DmTopicItemEnvelope extends DmTopicRecord {
  const DmTopicItemEnvelope({
    required super.commitId,
    required super.authorId,
    required this.position,
    this.topicId,
    this.daemonRead = false,
  });

  final int position;
  final String? topicId;
  final bool daemonRead;
}

final class DmTopic {
  const DmTopic({
    required this.id,
    required this.name,
    required this.order,
    required this.createCommitId,
    required this.createdBy,
    this.archivedBy = const {},
  });

  static const main = DmTopic(
    id: DmTopicWire.mainId,
    name: DmTopicWire.mainId,
    order: -1,
    createCommitId: '',
    createdBy: '',
  );

  final String id;
  final String name;
  final int order;
  final String createCommitId;
  final String createdBy;
  final Set<String> archivedBy;

  DmTopic copyWith({String? name, Set<String>? archivedBy}) => DmTopic(
    id: id,
    name: name ?? this.name,
    order: order,
    createCommitId: createCommitId,
    createdBy: createdBy,
    archivedBy: archivedBy ?? this.archivedBy,
  );

  @override
  bool operator ==(Object other) =>
      other is DmTopic &&
      id == other.id &&
      name == other.name &&
      order == other.order &&
      createCommitId == other.createCommitId &&
      createdBy == other.createdBy &&
      archivedBy.length == other.archivedBy.length &&
      archivedBy.containsAll(other.archivedBy);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    order,
    createCommitId,
    createdBy,
    Object.hashAll(archivedBy.toList()..sort()),
  );
}

final class DmTopicState {
  const DmTopicState._({
    required this.memberIds,
    required this._records,
    required this._topics,
    required this._readFrontiers,
    required this.acceptedEventCount,
  });

  factory DmTopicState.initial(Set<String> memberIds) => DmTopicState._(
    memberIds: Set.unmodifiable(memberIds),
    records: const {},
    topics: const {DmTopicWire.mainId: DmTopic.main},
    readFrontiers: const {},
    acceptedEventCount: 0,
  );

  final Set<String> memberIds;
  final Map<String, DmTopicRecord> _records;
  final Map<String, DmTopic> _topics;
  final Map<(String, String), ({int position, String commitId})> _readFrontiers;
  final int acceptedEventCount;

  int get recordCount => _records.length;

  DmTopic? topic(String id) => _topics[id];

  List<DmTopic> get customTopics => List.unmodifiable(
    _topics.values.where((topic) => topic.id != DmTopicWire.mainId),
  );

  DmTopic? topicForItem(DmTopicItemEnvelope item) {
    final id = DmTopicWire.normalizeItemTopic(item.topicId);
    return _topics[id];
  }

  List<DmTopic> visibleTopics({
    required String localMemberId,
    String? retainedTopicId,
  }) {
    final peerIds = memberIds.where((id) => id != localMemberId).toSet();
    final stableTopics = customTopics.toList()
      ..sort(_compareTopicCreationOrder);
    final counts = <String, int>{};
    final displayNames = <String, String>{};
    for (final topic in stableTopics) {
      final key = topic.name.toLowerCase();
      final count = (counts[key] ?? 0) + 1;
      counts[key] = count;
      displayNames[topic.id] = count == 1 ? topic.name : '${topic.name} $count';
    }
    final topics =
        stableTopics
            .where(
              (topic) =>
                  !topic.archivedBy.contains(localMemberId) ||
                  topic.id == retainedTopicId,
            )
            .map((topic) => topic.copyWith(name: displayNames[topic.id]))
            .toList()
          ..sort((left, right) {
            final leftPeerArchived = left.archivedBy.any(peerIds.contains);
            final rightPeerArchived = right.archivedBy.any(peerIds.contains);
            if (leftPeerArchived != rightPeerArchived) {
              return leftPeerArchived ? 1 : -1;
            }
            return _compareTopicCreationOrder(left, right);
          });
    return List.unmodifiable([DmTopic.main, ...topics]);
  }

  static int _compareTopicCreationOrder(DmTopic left, DmTopic right) {
    final byOrder = left.order.compareTo(right.order);
    return byOrder != 0
        ? byOrder
        : left.createCommitId.compareTo(right.createCommitId);
  }

  bool effectiveRead(String itemId, {required String readerId}) {
    final item = _records[itemId];
    if (item is! DmTopicItemEnvelope ||
        !memberIds.contains(readerId) ||
        item.authorId == readerId) {
      return false;
    }
    final topicId = DmTopicWire.normalizeItemTopic(item.topicId);
    final frontier = _readFrontiers[(readerId, topicId)];
    return (frontier != null && item.position <= frontier.position) ||
        (item.topicId == null && item.daemonRead);
  }

  Map<String, int> unreadByTopic({required String localMemberId}) {
    final counts = <String, int>{for (final topic in _topics.keys) topic: 0};
    for (final record in _records.values) {
      if (record is! DmTopicItemEnvelope ||
          record.authorId == localMemberId ||
          !memberIds.contains(record.authorId) ||
          effectiveRead(record.commitId, readerId: localMemberId)) {
        continue;
      }
      final topic = topicForItem(record);
      if (topic == null) continue;
      final topicId = topic.id;
      counts[topicId] = (counts[topicId] ?? 0) + 1;
    }
    return Map.unmodifiable(counts);
  }

  int nextRevision(
    DmTopicOperation operation,
    String topicId, {
    required String authorId,
  }) {
    var latest = 0;
    for (final record in _records.values.whereType<DmTopicEventEnvelope>()) {
      final event = record.event;
      if (event.operation != operation || event.topicId != topicId) continue;
      if ((operation == DmTopicOperation.archive ||
              operation == DmTopicOperation.read) &&
          record.authorId != authorId) {
        continue;
      }
      if (event.revision > latest) latest = event.revision;
    }
    return latest >= DmTopicWire.maxCounter ? 0 : latest + 1;
  }

  /// Whether [memberId]'s newest record is a valid `left` event. Any later
  /// record by the same member (a re-add in this conversation) supersedes it.
  bool hasLeft(String memberId) {
    DmTopicRecord? newest;
    var newestPosition = -1;
    for (final record in _records.values) {
      if (record.authorId != memberId) continue;
      final position = switch (record) {
        DmTopicEventEnvelope(:final position) => position,
        DmTopicItemEnvelope(:final position) => position,
      };
      if (position > newestPosition) {
        newestPosition = position;
        newest = record;
      }
    }
    return newest is DmTopicEventEnvelope &&
        newest.event.operation == DmTopicOperation.left &&
        newest.event.topicId == DmTopicWire.mainId;
  }

  int get nextTopicOrder {
    var latest = -1;
    for (final topic in customTopics) {
      if (topic.order > latest) latest = topic.order;
    }
    return latest >= DmTopicWire.maxCounter ? -1 : latest + 1;
  }
}

abstract final class DmTopicReducer {
  /// Reconstruct one completed history snapshot without rebuilding each prefix.
  /// The first admitted occurrence of a commit wins, as in [reduce].
  static DmTopicState reduceAll(
    DmTopicState state,
    Iterable<DmTopicRecord> incoming,
  ) {
    final records = Map<String, DmTopicRecord>.of(state._records);
    for (final record in incoming) {
      if (!state.memberIds.contains(record.authorId) ||
          record.commitId.isEmpty ||
          record.commitId.length > 128) {
        continue;
      }
      records.putIfAbsent(record.commitId, () => record);
    }
    if (records.length == state._records.length) return state;
    return _rebuild(state.memberIds, records);
  }

  static DmTopicState reduce(DmTopicState state, DmTopicRecord record) {
    if (!state.memberIds.contains(record.authorId) ||
        record.commitId.isEmpty ||
        record.commitId.length > 128 ||
        state._records.containsKey(record.commitId)) {
      return state;
    }
    return _rebuild(state.memberIds, {
      ...state._records,
      record.commitId: record,
    });
  }

  static DmTopicState _rebuild(
    Set<String> memberIds,
    Map<String, DmTopicRecord> records,
  ) {
    final events = records.values.whereType<DmTopicEventEnvelope>().toList();
    final items = records.values.whereType<DmTopicItemEnvelope>().toList();
    final validEvents = events.where(_hasValidWireShape).toList();

    final creates = <String, DmTopicEventEnvelope>{};
    for (final envelope in validEvents) {
      final event = envelope.event;
      if (event.operation != DmTopicOperation.create) continue;
      final current = creates[event.topicId];
      if (current == null || _registerWins(envelope, current)) {
        creates[event.topicId] = envelope;
      }
    }

    final topics = <String, DmTopic>{DmTopicWire.mainId: DmTopic.main};
    for (final entry in creates.entries) {
      final envelope = entry.value;
      final event = envelope.event;
      topics[entry.key] = DmTopic(
        id: entry.key,
        name: event.name!,
        order: event.order!,
        createCommitId: envelope.commitId,
        createdBy: envelope.authorId,
      );
    }

    final names = <String, TopicRegister<String>>{};
    final archives = <(String, String), TopicRegister<bool>>{};
    var accepted = creates.length;
    for (final envelope in validEvents) {
      final event = envelope.event;
      if (event.operation == DmTopicOperation.create ||
          !topics.containsKey(event.topicId)) {
        continue;
      }
      switch (event.operation) {
        case DmTopicOperation.create:
          break;
        case DmTopicOperation.rename:
          final candidate = (
            revision: event.revision,
            commitId: envelope.commitId,
            value: event.name!,
          );
          final current = names[event.topicId];
          if (current == null || _valueRegisterWins(candidate, current)) {
            names[event.topicId] = candidate;
          }
          accepted++;
        case DmTopicOperation.archive:
          final key = (event.topicId, envelope.authorId);
          final candidate = (
            revision: event.revision,
            commitId: envelope.commitId,
            value: event.archived!,
          );
          final current = archives[key];
          if (current == null || _valueRegisterWins(candidate, current)) {
            archives[key] = candidate;
          }
          accepted++;
        case DmTopicOperation.read:
        case DmTopicOperation.left:
          break;
      }
    }

    for (final entry in topics.entries.toList()) {
      if (entry.key == DmTopicWire.mainId) continue;
      final archivedBy = <String>{
        for (final memberId in memberIds)
          if (archives[(entry.key, memberId)]?.value ?? false) memberId,
      };
      topics[entry.key] = entry.value.copyWith(
        name: names[entry.key]?.value,
        archivedBy: Set.unmodifiable(archivedBy),
      );
    }

    final itemsById = {for (final item in items) item.commitId: item};
    final frontiers = <(String, String), ({int position, String commitId})>{};
    for (final envelope in validEvents) {
      final event = envelope.event;
      if (event.operation != DmTopicOperation.read ||
          (event.topicId != DmTopicWire.mainId &&
              !topics.containsKey(event.topicId))) {
        continue;
      }
      final target = itemsById[event.messageId];
      if (target == null ||
          target.authorId == envelope.authorId ||
          target.position >= envelope.position ||
          DmTopicWire.normalizeItemTopic(target.topicId) != event.topicId) {
        continue;
      }
      final key = (envelope.authorId, event.topicId);
      final current = frontiers[key];
      if (current == null ||
          target.position > current.position ||
          (target.position == current.position &&
              envelope.commitId.compareTo(current.commitId) > 0)) {
        frontiers[key] = (
          position: target.position,
          commitId: envelope.commitId,
        );
      }
      accepted++;
    }

    return DmTopicState._(
      memberIds: Set.unmodifiable(memberIds),
      records: Map.unmodifiable(records),
      topics: Map.unmodifiable(topics),
      readFrontiers: Map.unmodifiable(frontiers),
      acceptedEventCount: accepted,
    );
  }

  static bool _hasValidWireShape(DmTopicEventEnvelope envelope) {
    try {
      DmTopicEventCodec.encode(envelope.event);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  static bool _registerWins(
    DmTopicEventEnvelope candidate,
    DmTopicEventEnvelope current,
  ) =>
      candidate.event.revision > current.event.revision ||
      (candidate.event.revision == current.event.revision &&
          candidate.commitId.compareTo(current.commitId) > 0);

  static bool _valueRegisterWins<T>(
    TopicRegister<T> candidate,
    TopicRegister<T> current,
  ) =>
      candidate.revision > current.revision ||
      (candidate.revision == current.revision &&
          candidate.commitId.compareTo(current.commitId) > 0);
}
