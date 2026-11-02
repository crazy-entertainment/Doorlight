import 'dart:math';

import 'package:flutter/services.dart';

import 'conversation_scope.dart';
import 'conversation_timeline.dart';

enum ComposerOperationKind { picker, camera, recording, sendText, sendMedia }

enum ComposerSendStatus { pending, committed, failedBeforeCommit, unknown }

enum ComposerMediaKind { file, photo, sticker, gif, voice }

/// Local navigation identity, never a content-body claim of routing authority.
final class ComposerDraftKey {
  const ComposerDraftKey(this.scope, this.topic);

  final ConversationScope scope;
  final String topic;

  @override
  bool operator ==(Object other) =>
      other is ComposerDraftKey && scope == other.scope && topic == other.topic;

  @override
  int get hashCode => Object.hash(scope, topic);
}

final class ComposerMediaStage {
  ComposerMediaStage({
    required this.kind,
    required this.label,
    required this.encodedBytes,
    this.path,
    this.assetId,
    this.mediaMetadata,
    this.contentHash,
  });

  final Object identity = Object();
  final ComposerMediaKind kind;
  final String label;
  final int encodedBytes;
  final String? path;
  final String? assetId;
  final String? mediaMetadata;

  /// Local validated bytes only; never a message-routing or native authority.
  final String? contentHash;
}

final class ComposerOperation {
  ComposerOperation._(
    this.kind,
    this.owner,
    this.revision,
    this.textRevision,
    this.mediaRevision,
    this.stage,
    this.replyTo,
    this.replyRevision,
  ) : id = List.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static final Random _random = Random.secure();
  final String id;
  final ComposerOperationKind kind;
  final Object owner;
  final int revision;
  final int textRevision;
  final int mediaRevision;
  final ComposerMediaStage? stage;
  final String replyTo;
  final int replyRevision;
  ComposerSendStatus status = ComposerSendStatus.pending;
  String? commitId;
}

/// In-memory drafts only. Native/Jami publication and the minimal issued-command
/// journal own durable outcomes; this object is not a second message store.
final class ComposerDraftSession {
  ComposerDraftSession(this.key);

  final ComposerDraftKey key;
  TextEditingValue _text = TextEditingValue.empty;
  ComposerMediaStage? _media;
  Object? _owner;
  int _revision = 0;
  int _textRevision = 0;
  int _mediaRevision = 0;
  String _replyTo = '';
  int _replyRevision = 0;
  final Map<ComposerOperationKind, ComposerOperation> _operations = {};

  TextEditingValue get text => _text;
  ComposerMediaStage? get media => _media;
  String get replyTo => _replyTo;
  int get revision => _revision;
  bool get mediaAlreadyCommitted {
    final operation = _operations[ComposerOperationKind.sendMedia];
    return _media != null &&
        operation?.status == ComposerSendStatus.committed &&
        identical(operation?.stage, _media);
  }

  /// Once issued, source disposal belongs to native seed acknowledgement,
  /// including a committed operation whose original surface was left.
  bool mayDiscardStage(ComposerMediaStage stage) {
    final operation = _operations[ComposerOperationKind.sendMedia];
    return operation == null ||
        !identical(operation.stage, stage) ||
        operation.status == ComposerSendStatus.failedBeforeCommit;
  }

  bool blocked(ComposerOperationKind kind) {
    final status = _operations[kind]?.status;
    return status == ComposerSendStatus.pending ||
        status == ComposerSendStatus.unknown;
  }

  bool get isEmpty =>
      _text.text.isEmpty &&
      _media == null &&
      _replyTo.isEmpty &&
      !_operations.values.any(
        (operation) =>
            operation.status == ComposerSendStatus.pending ||
            operation.status == ComposerSendStatus.unknown,
      );

  void _disarmPreparations() => _operations.removeWhere(
    (kind, _) =>
        kind != ComposerOperationKind.sendText &&
        kind != ComposerOperationKind.sendMedia,
  );

  /// [owner] includes account lifetime and the navigation visit. Deactivation
  /// disarms actions without throwing away text or a valid replacement stage.
  void activate(Object owner) {
    if (_owner == owner) return;
    _owner = owner;
    _disarmPreparations();
  }

  void deactivate(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _disarmPreparations();
  }

  bool updateText(Object owner, TextEditingValue value) {
    if (_owner != owner ||
        value.text.length > TimelineWireContract.maxTextCodeUnits) {
      return false;
    }
    if (_text.text != value.text) {
      _revision++;
      _textRevision++;
    }
    // Selection and composing ranges remain intact, including ZWJ/IME text.
    _text = value;
    return true;
  }

  /// Only the commit ID belongs in a draft; previews resolve current history.
  bool setReply(Object owner, String daemonId) {
    if (_owner != owner ||
        daemonId.length > TimelineWireContract.maxDaemonIdCodeUnits) {
      return false;
    }
    if (_replyTo == daemonId) return true;
    _replyTo = daemonId;
    _replyRevision++;
    _revision++;
    return true;
  }

  /// A successful local command may intentionally change the selected topic.
  /// Its original draft is cleared only at the captured revision; no other
  /// topic's draft participates in that transition.
  bool clearExecutedCommand(int expectedRevision) {
    if (_revision != expectedRevision) return false;
    _text = TextEditingValue.empty;
    _replyTo = '';
    _replyRevision++;
    _textRevision++;
    _revision++;
    return true;
  }

  ComposerOperation? begin(ComposerOperationKind kind, Object owner) {
    if (_owner != owner) return null;
    if (kind == ComposerOperationKind.sendMedia && mediaAlreadyCommitted) {
      return null;
    }
    final previous = _operations[kind];
    if (previous != null &&
        (kind == ComposerOperationKind.sendText ||
            kind == ComposerOperationKind.sendMedia) &&
        (previous.status == ComposerSendStatus.pending ||
            previous.status == ComposerSendStatus.unknown)) {
      return null;
    }
    return _operations[kind] = ComposerOperation._(
      kind,
      owner,
      _revision,
      _textRevision,
      _mediaRevision,
      _media,
      _replyTo,
      _replyRevision,
    );
  }

  bool owns(ComposerOperation operation, {bool unchanged = true}) =>
      _owner == operation.owner &&
      identical(_operations[operation.kind], operation) &&
      (!unchanged || operation.revision == _revision);

  /// Caller validates the candidate and retains the previous stage for disposal
  /// only when no issued operation owns it.
  bool replaceMedia(ComposerOperation operation, ComposerMediaStage candidate) {
    if (operation.kind == ComposerOperationKind.sendText ||
        operation.kind == ComposerOperationKind.sendMedia ||
        !owns(operation) ||
        blocked(ComposerOperationKind.sendMedia) ||
        candidate.encodedBytes < 0) {
      return false;
    }
    _media = candidate;
    _revision++;
    _mediaRevision++;
    finishPreparation(operation);
    return true;
  }

  /// Cancelling or completing a picker must not keep an otherwise empty draft
  /// pinned forever, or disarm a newer picker that owns the same surface.
  void finishPreparation(ComposerOperation operation) {
    if (operation.kind != ComposerOperationKind.sendText &&
        operation.kind != ComposerOperationKind.sendMedia &&
        identical(_operations[operation.kind], operation)) {
      _operations.remove(operation.kind);
    }
  }

  bool removeMedia(Object owner, ComposerMediaStage stage) {
    if (_owner != owner ||
        blocked(ComposerOperationKind.sendMedia) ||
        !identical(_media, stage)) {
      return false;
    }
    _media = null;
    _revision++;
    _mediaRevision++;
    return true;
  }

  /// Record exact results even after navigation; clear only a component still
  /// owned by this visit and its original component revision.
  bool complete(
    ComposerOperation operation,
    ComposerSendStatus status, {
    String? commitId,
  }) {
    if (status == ComposerSendStatus.committed &&
        (commitId == null || commitId.isEmpty)) {
      throw ArgumentError('A committed operation requires a commit ID');
    }
    if (operation.status == ComposerSendStatus.committed) return false;
    operation.status = status;
    operation.commitId = commitId;
    if (status != ComposerSendStatus.committed ||
        !owns(operation, unchanged: false)) {
      return false;
    }
    if (operation.kind == ComposerOperationKind.sendText &&
        operation.textRevision == _textRevision &&
        operation.replyRevision == _replyRevision) {
      _text = TextEditingValue.empty;
      _textRevision++;
      _replyTo = '';
      _replyRevision++;
    } else if (operation.kind == ComposerOperationKind.sendMedia &&
        operation.mediaRevision == _mediaRevision &&
        identical(_media, operation.stage)) {
      _media = null;
      _mediaRevision++;
    } else {
      return false;
    }
    _revision++;
    return true;
  }
}

final class ComposerDraftStore {
  ComposerDraftStore({this.maximumDrafts = 32});

  final int maximumDrafts;
  final Map<ComposerDraftKey, ComposerDraftSession> _drafts = {};

  bool get hasUnfinishedDrafts => _drafts.values.any((draft) => !draft.isEmpty);

  /// Timeline actions can address only the draft currently mounted for this
  /// exact conversation and topic. They cannot activate an old navigation visit.
  bool selectReply(ComposerDraftKey key, String daemonId) {
    final draft = _drafts[key];
    final owner = draft?._owner;
    return draft != null && owner != null && draft.setReply(owner, daemonId);
  }

  ComposerDraftSession? acquire(ComposerDraftKey key) {
    final existing = _drafts[key];
    if (existing != null) return existing;
    if (_drafts.length >= maximumDrafts) {
      // Unsent content is never evicted to make room for another conversation.
      _drafts.removeWhere((_, draft) => draft.isEmpty);
    }
    if (_drafts.length >= maximumDrafts) return null;
    return _drafts[key] = ComposerDraftSession(key);
  }

  void reconcile(
    String operationId,
    ComposerSendStatus status, {
    String? commitId,
  }) {
    for (final draft in _drafts.values) {
      for (final operation in draft._operations.values) {
        if (operation.id == operationId) {
          draft.complete(operation, status, commitId: commitId);
          return;
        }
      }
    }
  }
}
