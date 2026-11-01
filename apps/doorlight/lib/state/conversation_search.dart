import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'conversation_scope.dart';
import 'dm_topics.dart';

abstract final class HistorySearchWire {
  static const maximumQueryCodeUnits = 256;
  static const maximumSnippetCodeUnits = 512;
  static const maximumResults = 200;
  static const maximumScopes = 512;
  static const pageSize = 20;
  static final _commit = RegExp(r'^[0-9a-f]{40}$');
  static final _room = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');

  static bool commit(Object? value) =>
      value is String && value.length == 40 && _commit.hasMatch(value);

  static bool text(Object? value, int maximum, {bool singleLine = false}) {
    if (value is! String || value.isEmpty || value.length > maximum) {
      return false;
    }
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit < 32 && (singleLine || !const [9, 10, 13].contains(unit)) ||
          unit == 127) {
        return false;
      }
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length) return false;
        final low = value.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return utf8.encode(value).length <= maximum * 4;
  }

  static bool channel(ConversationScope scope, Object? value) {
    if (value is! String) return false;
    if (scope.isGroup) {
      return value.length <= 32 && _room.firstMatch(value)?.group(0) == value;
    }
    return value == DmTopicWire.mainId ||
        value.length == 32 && DmTopicWire.isCustomId(value);
  }
}

/// Private session input. Native search receives the escaped ECMAScript literal,
/// with no author/time/cursor filter that could discard an edition before folding.
@immutable
final class HistorySearchQuery {
  const HistorySearchQuery._(this.literal, this.pattern);
  final String literal;
  final String pattern;

  static HistorySearchQuery? parse(String input) {
    if (input.length > HistorySearchWire.maximumQueryCodeUnits) return null;
    final literal = input.trim();
    if (!HistorySearchWire.text(
      literal,
      HistorySearchWire.maximumQueryCodeUnits,
      singleLine: true,
    )) {
      return null;
    }
    const syntax = r'\^$.|?*+()[]{}';
    final pattern = StringBuffer();
    for (final unit in literal.codeUnits) {
      final character = String.fromCharCode(unit);
      if (syntax.contains(character)) pattern.write(r'\');
      pattern.write(character);
    }
    return HistorySearchQuery._(literal, pattern.toString());
  }

  @override
  String toString() => 'HistorySearchQuery(<private>)';
}

@immutable
final class HistorySearchHit {
  const HistorySearchHit._(
    this.scope,
    this.messageId,
    this.authorId,
    this.channelId,
    this.createdAt,
    this.snippet,
    this.isFile,
  );
  final ConversationScope scope;
  final String messageId;
  final String authorId;
  final String channelId;
  final DateTime createdAt;
  final String snippet;
  final bool isFile;

  static HistorySearchHit? fromWire(Object? value, ConversationScope scope) {
    if (value is! Map ||
        ConversationScope.tryParse(value) != scope ||
        !HistorySearchWire.commit(value['messageId']) ||
        !HistorySearchWire.commit(value['authorId']) ||
        !HistorySearchWire.channel(scope, value['channelId']) ||
        !HistorySearchWire.text(
          value['snippet'],
          HistorySearchWire.maximumSnippetCodeUnits,
        ) ||
        (value['contentKind'] != 'text' && value['contentKind'] != 'file')) {
      return null;
    }
    final seconds = value['timestampSeconds'];
    if (seconds is! int || seconds < 0 || seconds > 8640000000000) return null;
    return HistorySearchHit._(
      scope,
      value['messageId'] as String,
      value['authorId'] as String,
      value['channelId'] as String,
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
      value['snippet'] as String,
      value['contentKind'] == 'file',
    );
  }

  @override
  String toString() => 'HistorySearchHit(<private>)';
}

@immutable
final class HistorySearchBatch {
  const HistorySearchBatch._(this.hits, this.truncated);
  static const empty = HistorySearchBatch._([], false);
  final List<HistorySearchHit> hits;
  final bool truncated;

  static HistorySearchBatch? fromWire(
    Object? value,
    ConversationScope scope,
    int limit,
  ) {
    if (limit < 1 ||
        limit > HistorySearchWire.maximumResults ||
        value is! Map ||
        value['truncated'] is! bool ||
        value['hits'] is! List) {
      return null;
    }
    final raw = value['hits'] as List;
    if (raw.length > limit) return null;
    final hits = <HistorySearchHit>[];
    final ids = <String>{};
    for (final item in raw) {
      final hit = HistorySearchHit.fromWire(item, scope);
      if (hit == null || !ids.add(hit.messageId)) return null;
      hits.add(hit);
    }
    return HistorySearchBatch._(
      List.unmodifiable(hits),
      value['truncated'] as bool,
    );
  }
}

typedef HistorySearchOwner = ({String accountId, Object lifetime});

/// Settles only after the native worker's terminal event. An observation timeout
/// must not release this lease and permit another native worker to accumulate.
typedef HistorySearchBackend =
    Future<HistorySearchBatch> Function(
      ConversationScope scope,
      HistorySearchQuery query,
      int limit,
    );

enum HistorySearchProblem { invalidQuery, unavailable }

/// One active native query, one latest debounced intent, and bounded session
/// results. Retirement discards results immediately, but does not pretend that
/// the native worker has stopped. A replacement query waits for its completion.
final class ConversationSearch extends ChangeNotifier {
  ConversationSearch({
    required this.owner,
    required this.scopes,
    required this.accepts,
    required this.search,
    this.retireWorker,
    this.debounce = const Duration(milliseconds: 300),
  });

  final HistorySearchOwner? Function() owner;
  final Iterable<ConversationScope> Function() scopes;
  final bool Function(HistorySearchHit) accepts;
  final HistorySearchBackend search;
  final void Function(HistorySearchOwner)? retireWorker;
  final Duration debounce;
  Timer? _timer;
  _SearchIntent? _queued;
  bool _active = false;
  HistorySearchOwner? _activeOwner;
  bool _activeRetired = false;
  bool _disposed = false;
  int _generation = 0;
  int _visible = HistorySearchWire.pageSize;
  final List<HistorySearchHit> _hits = [];
  HistorySearchOwner? _resultOwner;
  bool busy = false;
  bool limited = false;
  HistorySearchProblem? problem;

  bool get _visibleOwner => _resultOwner != null && _resultOwner == owner();
  bool get hasSession => _resultOwner != null;
  List<HistorySearchHit> get results => _visibleOwner
      ? List.unmodifiable(_hits.where(accepts).take(_visible))
      : const [];
  bool get hasMore => _visibleOwner && _visible < resultCount;
  int get resultCount => _visibleOwner ? _hits.where(accepts).length : 0;

  void setQuery(String input, {ConversationScope? scope}) {
    if (_disposed) return;
    _retire();
    final currentOwner = owner();
    if (input.trim().isEmpty ||
        currentOwner == null ||
        currentOwner.accountId.isEmpty) {
      notifyListeners();
      return;
    }
    // Invalid input still belongs to this privacy lifetime. Its route must
    // retire on lock or account replacement even though no worker starts.
    _resultOwner = currentOwner;
    final query = HistorySearchQuery.parse(input);
    if (query == null) {
      problem = HistorySearchProblem.invalidQuery;
      notifyListeners();
      return;
    }
    final candidates = <ConversationScope>{};
    var overflow = false;
    for (final candidate in scopes()) {
      if (candidate.accountId != currentOwner.accountId ||
          scope != null && candidate != scope) {
        continue;
      }
      if (candidates.length == HistorySearchWire.maximumScopes &&
          !candidates.contains(candidate)) {
        overflow = true;
        break;
      }
      candidates.add(candidate);
    }
    final intent = _SearchIntent(
      _generation,
      currentOwner,
      query,
      List.unmodifiable(candidates),
      overflow,
    );
    busy = candidates.isNotEmpty;
    _timer = Timer(debounce, () {
      _timer = null;
      if (!_owns(intent)) return;
      _queued = intent;
      unawaited(_drain());
    });
    notifyListeners();
  }

  bool _owns(_SearchIntent intent) =>
      !_disposed && intent.generation == _generation && intent.owner == owner();

  Future<void> _drain() async {
    if (_active || _queued == null) return;
    final intent = _queued!;
    _queued = null;
    if (!_owns(intent)) return;
    _active = true;
    _activeOwner = intent.owner;
    _activeRetired = false;
    limited = intent.overflow;
    try {
      for (final scope in intent.scopes) {
        if (!_owns(intent)) return;
        final remaining = HistorySearchWire.maximumResults - _hits.length;
        if (remaining == 0) {
          limited = true;
          break;
        }
        // Membership may change during another conversation's search.
        if (!scopes().contains(scope)) continue;
        final batch = await search(scope, intent.query, remaining);
        if (!_owns(intent)) return;
        if (batch.hits.length > remaining ||
            batch.hits.any((hit) => hit.scope != scope)) {
          throw const FormatException('Invalid search boundary');
        }
        limited |= batch.truncated;
        _hits.addAll(batch.hits.where(accepts));
        _hits.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        notifyListeners();
      }
    } on Object {
      if (_owns(intent)) {
        problem = HistorySearchProblem.unavailable;
        limited = true;
      }
    } finally {
      _active = false;
      _activeOwner = null;
      if (_owns(intent)) {
        busy = false;
        notifyListeners();
      }
      if (!_disposed && _queued != null) unawaited(_drain());
    }
  }

  void showMore() {
    if (_disposed || !hasMore) return;
    _visible = (_visible + HistorySearchWire.pageSize).clamp(0, _hits.length);
    notifyListeners();
  }

  void _retire() {
    final activeOwner = _activeOwner;
    if (_active && !_activeRetired && activeOwner != null) {
      _activeRetired = true;
      retireWorker?.call(activeOwner);
    }
    _generation++;
    _timer?.cancel();
    _timer = null;
    _queued = null;
    _hits.clear();
    _resultOwner = null;
    _visible = HistorySearchWire.pageSize;
    busy = false;
    limited = false;
    problem = null;
  }

  void retire() {
    if (_disposed) return;
    _retire();
    notifyListeners();
  }

  @override
  void dispose() {
    _retire();
    _disposed = true;
    super.dispose();
  }
}

final class _SearchIntent {
  const _SearchIntent(
    this.generation,
    this.owner,
    this.query,
    this.scopes,
    this.overflow,
  );
  final int generation;
  final HistorySearchOwner owner;
  final HistorySearchQuery query;
  final List<ConversationScope> scopes;
  final bool overflow;
}
