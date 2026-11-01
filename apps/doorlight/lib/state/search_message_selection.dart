import 'package:flutter/foundation.dart';

import 'conversation_search.dart';
import 'conversation_timeline.dart';
import 'dm_topics.dart';
import 'group_topics.dart';
import 'rich_content.dart';

/// A fresh folded native result. Search snippets are never message authority.
final class SearchMessageSnapshot {
  const SearchMessageSnapshot._(this.item);
  final ConversationTimelineItem? item;

  static SearchMessageSnapshot? fromWire(
    Object? value,
    HistorySearchHit hit, {
    required String localAuthorId,
    Set<String>? allowedRemoteAuthorIds,
  }) {
    if (value is! Map ||
        value['accountId'] != hit.scope.accountId ||
        value['peerId'] != hit.scope.peerId ||
        value['conversationId'] != hit.scope.conversationId ||
        value['kind'] != hit.scope.kind.name ||
        value['messageId'] != hit.messageId ||
        value['items'] is! List) {
      return null;
    }
    final items = value['items'] as List;
    if (items.isEmpty) return const SearchMessageSnapshot._(null);
    if (items.length != 1 || items.single is! Map) return null;
    final raw = items.single as Map;
    if (raw.keys.any((key) => key is! String) ||
        raw['daemonId'] != hit.messageId ||
        raw['authorId'] != hit.authorId ||
        !HistorySearchWire.commit(raw['versionId']) ||
        raw['timestampSeconds'] !=
            hit.createdAt.millisecondsSinceEpoch ~/ 1000 ||
        (raw['operation'] != null && raw['operation'] != 'snapshot') ||
        (hit.scope.isGroup
            ? _effectiveGroupRoom(raw) != hit.channelId
            : (raw['topicId'] ?? DmTopicWire.mainId) != hit.channelId)) {
      return null;
    }
    final parsed = const TimelineItemParser().parse(
      expectedScope: hit.scope,
      localAuthorId: localAuthorId,
      allowedRemoteAuthorIds: allowedRemoteAuthorIds,
      value: Map<String, Object?>.from(raw),
    );
    final mutation = parsed.mutation;
    if (mutation == null) return null;
    final item = mutation.item;
    if (item != null &&
        (hit.isFile ? item is! TimelineFileItem : item is! TimelineTextItem)) {
      return null;
    }
    return SearchMessageSnapshot._(item);
  }

  /// The room the native hosts derive for a group hit: the explicit room field,
  /// else the legacy `[#room] ` text prefix, else `general`. Null when the two
  /// disagree or the field is malformed. File names never carry a prefix.
  static String? _effectiveGroupRoom(Map raw) {
    final explicit = raw['roomId'];
    if (raw.containsKey('roomId') &&
        (explicit == null || !RichContentWire.validRoom(explicit))) {
      return null;
    }
    final body = raw['body'];
    String? legacy;
    if (raw['mimeType'] == TimelineWireContract.textMimeType &&
        body is String) {
      final decoded = GroupTopicCodec.decode(body);
      if (decoded.body != body) legacy = decoded.topicId;
    }
    if (explicit != null && legacy != null && explicit != legacy) return null;
    return (explicit ?? legacy ?? 'general') as String;
  }

  /// Compare authenticated content, not transport receipts or reaction timing.
  static bool sameContent(
    ConversationTimelineItem left,
    ConversationTimelineItem? right,
  ) {
    if (right == null ||
        !left.hasSameInteraction(right) ||
        left.versionId != right.versionId ||
        left.topicId != right.topicId ||
        left.topicTagged != right.topicTagged ||
        left.roomId != right.roomId ||
        left.replyTo != right.replyTo ||
        left.operationId != right.operationId) {
      return false;
    }
    if (left is TimelineTextItem && right is TimelineTextItem) {
      return left.text == right.text;
    }
    return left is TimelineFileItem &&
        right is TimelineFileItem &&
        left.fileId == right.fileId &&
        left.displayName == right.displayName &&
        left.totalBytes == right.totalBytes &&
        left.sha3 == right.sha3 &&
        left.mediaMetadata == right.mediaMetadata;
  }

  @override
  String toString() => 'SearchMessageSnapshot(<private>)';
}

typedef SearchMessageLoader =
    Future<SearchMessageSnapshot> Function(HistorySearchHit hit);

enum SearchMessageProblem { unavailable }

/// Owns one selected result while its fresh native snapshot is pending.
/// Retirement hides content immediately but retains the worker lease until the
/// actual callback, so repeated selections cannot accumulate history scans.
final class SearchMessageSelection extends ChangeNotifier {
  SearchMessageSelection({
    required this.owner,
    required this.accepts,
    required this.load,
    this.retireWorker,
  });

  final HistorySearchOwner? Function() owner;
  final bool Function(HistorySearchHit) accepts;
  final SearchMessageLoader load;
  final void Function(HistorySearchOwner)? retireWorker;
  int _generation = 0;
  bool _disposed = false;
  bool _workerActive = false;
  bool busy = false;
  HistorySearchOwner? _resultOwner;
  HistorySearchHit? _hit;
  ConversationTimelineItem? _item;
  SearchMessageProblem? problem;

  bool get hasSession => _resultOwner != null;
  bool get canSelect => !_disposed && !_workerActive;
  HistorySearchHit? get hit => _current ? _hit : null;
  ConversationTimelineItem? get item => _current ? _item : null;
  bool get _current =>
      !_disposed &&
      _resultOwner != null &&
      _resultOwner == owner() &&
      _hit != null &&
      accepts(_hit!);

  Future<bool> select(HistorySearchHit hit) async {
    final expectedOwner = owner();
    if (!canSelect ||
        expectedOwner == null ||
        hit.scope.accountId != expectedOwner.accountId ||
        !accepts(hit)) {
      return false;
    }
    retire();
    final generation = _generation;
    _resultOwner = expectedOwner;
    _hit = hit;
    busy = true;
    _workerActive = true;
    notifyListeners();
    try {
      final snapshot = await load(hit);
      if (generation != _generation || !_current) return false;
      _item = snapshot.item;
      // Native empty snapshots can also mean the repository became unavailable.
      // Do not claim that a message was deleted merely because it is absent.
      if (_item == null) problem = SearchMessageProblem.unavailable;
      return _item != null;
    } on Object {
      if (generation == _generation && _current) {
        problem = SearchMessageProblem.unavailable;
      }
      return false;
    } finally {
      _workerActive = false;
      if (!_disposed) {
        if (generation == _generation) busy = false;
        notifyListeners();
      }
    }
  }

  void retire() {
    if (_disposed) return;
    final activeOwner = _resultOwner;
    if (_workerActive && activeOwner != null) retireWorker?.call(activeOwner);
    _generation++;
    _resultOwner = null;
    _hit = null;
    _item = null;
    problem = null;
    busy = false;
    notifyListeners();
  }

  @override
  void dispose() {
    retire();
    _disposed = true;
    super.dispose();
  }
}
