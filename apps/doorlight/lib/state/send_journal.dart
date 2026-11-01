import 'dart:async';
import 'dart:convert';

import 'composer_draft.dart';
import 'conversation_scope.dart';
import 'message_reactions.dart';
import 'rich_content.dart';

final class SendJournalRecord {
  const SendJournalRecord({
    required this.operationId,
    required this.scope,
    required this.status,
    this.commitId,
    this.stageReference,
    this.reactionTarget,
  });
  final String operationId;
  final ConversationScope scope;
  final ComposerSendStatus status;
  final String? commitId;
  final String? stageReference;

  /// Only command ownership, not a second reaction-history store.
  final String? reactionTarget;

  SendJournalRecord withOutcome(ComposerSendStatus status, String? commit) =>
      SendJournalRecord(
        operationId: operationId,
        scope: scope,
        status: status,
        commitId: commit,
        stageReference: stageReference,
        reactionTarget: reactionTarget,
      );

  Map<String, Object?> toMap() => {
    'operationId': operationId,
    'scope': scope.toMap(),
    'status': status.name,
    'commitId': commitId,
    'stage': stageReference,
    if (reactionTarget != null) 'reactionTarget': reactionTarget,
  };

  static SendJournalRecord? parse(Object? value) {
    if (value is! Map ||
        (value.length != 5 && value.length != 6) ||
        !value.keys.toSet().containsAll(const {
          'operationId',
          'scope',
          'status',
          'commitId',
          'stage',
        }) ||
        value.keys.any(
          (key) => !const {
            'operationId',
            'scope',
            'status',
            'commitId',
            'stage',
            'reactionTarget',
          }.contains(key),
        ) ||
        !RichContentWire.validOperation(value['operationId'])) {
      return null;
    }
    final rawScope = value['scope'];
    if (rawScope is! Map ||
        rawScope.length != 4 ||
        (rawScope['kind'] != 'direct' && rawScope['kind'] != 'group')) {
      return null;
    }
    final scope = ConversationScope.tryParse(rawScope);
    if (scope == null ||
        [
          scope.accountId,
          scope.peerId,
          scope.conversationId,
        ].any((id) => id.length > 1024)) {
      return null;
    }
    final status = ComposerSendStatus.values
        .where((status) => status.name == value['status'])
        .firstOrNull;
    final commit = value['commitId'];
    final stage = value['stage'];
    final reaction = value['reactionTarget'];
    if (status == null ||
        (value.containsKey('reactionTarget') &&
            (!ReactionWire.identity(reaction) || stage != null)) ||
        (commit != null &&
            (commit is! String || commit.isEmpty || commit.length > 1024)) ||
        (status == ComposerSendStatus.committed && commit == null) ||
        (status != ComposerSendStatus.committed && commit != null) ||
        (stage != null && !RichContentWire.validOperation(stage))) {
      return null;
    }
    return SendJournalRecord(
      operationId: value['operationId'] as String,
      scope: scope,
      // A process restart cannot prove whether a persisted issued operation ran.
      status: status == ComposerSendStatus.pending
          ? ComposerSendStatus.unknown
          : status,
      commitId: commit as String?,
      stageReference: stage as String?,
      reactionTarget: reaction as String?,
    );
  }
}

/// Minimal crash-safe command metadata, with no text/media bytes or message
/// projection. Native/Jami commit evidence is the only reconciliation source.
final class SendJournal {
  SendJournal({
    required String? source,
    required this.persist,
    Future<String?> Function()? load,
  }) {
    if (load == null) {
      _restore(source);
    } else {
      _tail = _initialize(source, load);
    }
    initialized = _tail;
  }

  late final Future<void> initialized;

  Future<void> _initialize(
    String? legacy,
    Future<String?> Function() load,
  ) async {
    try {
      final authoritative = await load();
      _restore(authoritative ?? legacy);
      if (authoritative == null && healthy) {
        // Retain the legacy copy. Only a verified native write admits commands.
        healthy = await persist(
          jsonEncode({
            'v': 1,
            'operations': _records.values
                .map((record) => record.toMap())
                .toList(),
          }),
        );
      }
    } catch (_) {
      healthy = false;
    }
  }

  void _restore(String? source) {
    if (source == null) return;
    try {
      if (source.length > maximumBytes ||
          utf8.encode(source).length > maximumBytes) {
        throw const FormatException();
      }
      final value = jsonDecode(source);
      if (value is! Map ||
          value.length != 2 ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['operations'] is! List) {
        throw const FormatException();
      }
      final operations = value['operations'] as List;
      if (operations.length > maximumOperations) throw const FormatException();
      for (final raw in operations) {
        final record = SendJournalRecord.parse(raw);
        if (record == null || _records.containsKey(record.operationId)) {
          throw const FormatException();
        }
        _records[record.operationId] = record;
      }
    } on Object {
      healthy = false;
    }
  }

  static const preferenceKey = 'sybl.send-journal.v1';
  static const maximumOperations = 128;
  static const maximumBytes = 1024 * 1024;
  final Future<bool> Function(String) persist;
  final Map<String, SendJournalRecord> _records = {};
  final Map<String, List<Completer<SendJournalRecord>>> _waiters = {};
  Future<void> _tail = Future.value();
  bool healthy = true;
  SendJournalRecord? record(String id) => _records[id];
  Iterable<SendJournalRecord> get repairable => _records.values.where(
    (record) =>
        record.status == ComposerSendStatus.committed &&
        record.stageReference != null,
  );
  Iterable<SendJournalRecord> get unresolved => _records.values.where(
    (record) =>
        record.status == ComposerSendStatus.pending ||
        record.status == ComposerSendStatus.unknown,
  );

  bool reactionUnresolved(ConversationScope scope, String target) =>
      unresolved.any(
        (record) => record.scope == scope && record.reactionTarget == target,
      );

  Future<bool> _mutate(bool Function(Map<String, SendJournalRecord>) mutate) {
    final result = Completer<bool>();
    _tail = _tail.then((_) async {
      if (!healthy) {
        result.complete(false);
        return;
      }
      final next = Map<String, SendJournalRecord>.of(_records);
      if (!mutate(next)) {
        result.complete(false);
        return;
      }
      final encoded = jsonEncode({
        'v': 1,
        'operations': next.values.map((record) => record.toMap()).toList(),
      });
      if (utf8.encode(encoded).length > maximumBytes) {
        result.complete(false);
        return;
      }
      try {
        if (!await persist(encoded)) {
          result.complete(false);
          return;
        }
        _records
          ..clear()
          ..addAll(next);
        result.complete(true);
      } catch (_) {
        result.complete(false);
      }
    });
    return result.future;
  }

  /// Persist before any native issue. A failed acknowledgement never issues.
  Future<bool> prepare(SendJournalRecord record) => _mutate((next) {
    if (next.length >= maximumOperations ||
        next.containsKey(record.operationId) ||
        record.status != ComposerSendStatus.pending ||
        !RichContentWire.validOperation(record.operationId)) {
      return false;
    }
    if (record.reactionTarget != null &&
        (!ReactionWire.identity(record.reactionTarget) ||
            record.stageReference != null ||
            next.values.any(
              (existing) =>
                  existing.scope == record.scope &&
                  existing.reactionTarget == record.reactionTarget &&
                  (existing.status == ComposerSendStatus.pending ||
                      existing.status == ComposerSendStatus.unknown),
            ))) {
      return false;
    }
    next[record.operationId] = record;
    return true;
  });

  Future<bool> complete(
    String id,
    ConversationScope scope,
    ComposerSendStatus status, {
    String? commitId,
  }) async {
    if (status == ComposerSendStatus.pending ||
        (status == ComposerSendStatus.committed &&
            (commitId == null || commitId.isEmpty || commitId.length > 1024))) {
      return false;
    }
    final updated = await _mutate((next) {
      final current = next[id];
      if (current == null ||
          current.scope != scope ||
          current.status == ComposerSendStatus.committed) {
        return false;
      }
      next[id] = current.withOutcome(
        status,
        status == ComposerSendStatus.committed ? commitId : null,
      );
      return true;
    });
    if (updated) {
      final record = _records[id]!;
      for (final waiter
          in _waiters.remove(id) ?? <Completer<SendJournalRecord>>[]) {
        if (!waiter.isCompleted) waiter.complete(record);
      }
    }
    return updated;
  }

  Future<SendJournalRecord?> wait(
    String id, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final current = _records[id];
    if (current == null || current.status != ComposerSendStatus.pending) {
      return current;
    }
    final waiter = Completer<SendJournalRecord>();
    (_waiters[id] ??= []).add(waiter);
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      await complete(id, current.scope, ComposerSendStatus.unknown);
      return _records[id]?.status == ComposerSendStatus.committed
          ? _records[id]
          : current.withOutcome(ComposerSendStatus.unknown, null);
    } finally {
      final waiters = _waiters[id];
      waiters?.remove(waiter);
      if (waiters?.isEmpty ?? false) _waiters.remove(id);
    }
  }

  /// Call only after the original component/seed disposition is acknowledged.
  Future<bool> acknowledgeSeed(
    String id,
    ConversationScope scope,
    String commitId,
  ) async {
    if (commitId.isEmpty || commitId.length > 1024) return false;
    // Seed readiness can race the separately delivered commit callback. It is
    // itself positive commit evidence, never a reason to publish again.
    await complete(id, scope, ComposerSendStatus.committed, commitId: commitId);
    return _mutate((next) {
      final current = next[id];
      if (current == null ||
          current.scope != scope ||
          current.status != ComposerSendStatus.committed ||
          current.commitId != commitId ||
          current.stageReference == null) {
        return false;
      }
      next[id] = SendJournalRecord(
        operationId: current.operationId,
        scope: current.scope,
        status: current.status,
        commitId: current.commitId,
      );
      return true;
    });
  }

  Future<bool> acknowledge(String id) => _mutate((next) {
    final record = next[id];
    if (record == null ||
        record.status == ComposerSendStatus.pending ||
        record.status == ComposerSendStatus.unknown ||
        (record.status == ComposerSendStatus.committed &&
            record.stageReference != null)) {
      return false;
    }
    next.remove(id);
    return true;
  });
}
