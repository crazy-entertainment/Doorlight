import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../core/jami.dart';
import 'conversation_timeline.dart';
import 'dm_topics.dart';
import 'gif_validation.dart';

/// One libjami transfer is owned by an exact direct or group conversation.
///
/// libjami file IDs are not globally unique, so no API in this controller
/// accepts a bare file ID as an owner.
typedef TransferOwner = ({String peerId, String conversationId});
typedef TransferKey = ({String peerId, String conversationId, String fileId});

final class DmTopicIntroductionTracker {
  DmTopicIntroductionTracker({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const window = Duration(minutes: 10);
  static const requiredCompletions = 3;
  static const trackedConversationLimit = 64;

  final DateTime Function() _now;
  final Map<TransferOwner, List<DateTime>> _completed = {};

  bool recordCompleted(TransferOwner owner) {
    final now = _now();
    final cutoff = now.subtract(window);
    _completed.removeWhere((_, times) {
      times.removeWhere((time) => time.isBefore(cutoff));
      return times.isEmpty;
    });
    if (!_completed.containsKey(owner) &&
        _completed.length >= trackedConversationLimit) {
      _completed.remove(_completed.keys.first);
    }
    final times = _completed.putIfAbsent(owner, () => [])..add(now);
    if (times.length < requiredCompletions) return false;
    _completed.clear();
    return true;
  }
}

TransferKey transferKey(String peerId, String conversationId, String fileId) =>
    (peerId: peerId, conversationId: conversationId, fileId: fileId);

enum XferStatus {
  offered,
  waiting,
  ongoing,
  canceling,
  finished,
  error,
  declined,
  canceled,
}

const _thumbnailMaxPngBytes = 24 * 1024;
const _thumbnailMaxBase64Chars = 32 * 1024;
const _thumbnailMaxSourceBytes = 12 * 1024 * 1024;
const _thumbnailLifetime = Duration(minutes: 2);
const _thumbnailSide = 72;
const _thumbnailPendingLimit = 16;
const _pendingDecisionLimit = 64;
final _directJamiId = RegExp(r'^[0-9a-f]{40}$');
final _receiveAttemptRandom = math.Random.secure();
String _newReceiveAttempt() => List.generate(
  16,
  (_) => _receiveAttemptRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// A live or recently completed libjami data transfer.
class FileXfer {
  FileXfer({
    required this.peerId,
    required this.conversationId,
    required this.fileId,
    required this.interactionId,
    required this.name,
    required this.size,
    required this.outgoing,
    this.authorId = '',
    this.topicId = DmTopicWire.mainId,
    this.topicTagged = false,
    this.roomId = '',
    this.status = XferStatus.offered,
    this.transferred = 0,
    this.path,
    this.previewBytes,
    this.attemptId = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String peerId;
  final String conversationId;
  final String fileId;
  String interactionId;
  String name;
  int size;
  final bool outgoing;
  String authorId;
  final String topicId;
  final bool topicTagged;
  final String roomId;
  XferStatus status;
  int transferred;
  String? path;
  Uint8List? previewBytes;
  String attemptId;
  DateTime createdAt;

  double? get progress =>
      size > 0 ? (transferred / size).clamp(0.0, 1.0) : null;

  bool get done =>
      status == XferStatus.finished ||
      status == XferStatus.error ||
      status == XferStatus.declined ||
      status == XferStatus.canceled;
}

/// A durable file entry reconstructed from one exact swarm conversation.
class FolderFile {
  FolderFile({
    required this.peerId,
    required this.conversationId,
    required this.fileId,
    required this.interactionId,
    required this.name,
    required this.size,
    this.sha3 = '',
    this.outgoing = false,
    this.authorId = '',
    this.topicId = DmTopicWire.mainId,
    this.topicTagged = false,
    this.roomId = '',
    this.downloaded = false,
    this.path,
    this.timestamp = 0,
  });

  final String peerId;
  final String conversationId;
  final String fileId;
  String interactionId;
  String name;
  int size;
  String sha3;
  final bool outgoing;
  String authorId;
  final String topicId;
  final bool topicTagged;
  final String roomId;
  bool downloaded;
  String? path;
  int timestamp;
}

/// Owns all runtime state for file transfer and the persistent shared-folder
/// projection.
///
/// The controller delegates persistence and transport to libjami through
/// [JamiClient]. It adds only client-side concerns that libjami does not own:
/// exact owner keys, in-flight de-duplication, load correlation, byte polling,
/// and the configured inbound size limit. [AppState] remains the public facade.
final class FileTransferController extends ChangeNotifier {
  FileTransferController({
    required this._jami,
    required this._accountId,
    required this._ownsConversation,
    required this._isOffline,
    required this._maxIncomingFileBytes,
    required this._log,
    this._onCompletedTransfer,
    this._onOutgoingStarted,
    this._pollInterval = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final JamiClient _jami;
  final String Function() _accountId;
  final bool Function(String peerId, String conversationId) _ownsConversation;
  final bool Function() _isOffline;
  final int Function() _maxIncomingFileBytes;
  final void Function(String message) _log;
  final void Function(FileXfer transfer)? _onCompletedTransfer;
  final void Function(TransferOwner owner)? _onOutgoingStarted;
  final Duration _pollInterval;
  final DateTime Function() _now;

  final Map<TransferKey, FileXfer> _transfers = {};
  final Map<TransferKey, FolderFile> _folder = {};

  late final Map<TransferKey, FileXfer> _transferView = UnmodifiableMapView(
    _transfers,
  );
  late final Map<TransferKey, FolderFile> _folderView = UnmodifiableMapView(
    _folder,
  );

  /// A live, structurally read-only view of transfers owned by this controller.
  ///
  /// [FileXfer] remains mutable because progress callbacks update an existing
  /// row across asynchronous native replies and identity checks intentionally
  /// reject replies for replaced rows. Collection membership, however, may
  /// only be changed by this controller.
  Map<TransferKey, FileXfer> get transfers => _transferView;

  /// A live, structurally read-only view of the durable folder projection.
  ///
  /// [FolderFile] remains mutable for the same callback-correlation reason as
  /// [FileXfer]. Consumers may observe entries, but cannot add, replace, or
  /// remove rows.
  Map<TransferKey, FolderFile> get folder => _folderView;

  final Map<TransferKey, Timer> _pollers = {};
  final Map<TransferKey, int> _pollGenerations = {};
  final Map<TransferKey, ({Object token, bool preview})> _pollBusy = {};
  final Map<TransferKey, Object> _starts = {};
  final Map<TransferKey, Object> _cancels = {};
  final Map<TransferKey, Uint8List> _pendingThumbnails = {};
  final Map<TransferKey, Timer> _thumbnailTimers = {};
  final Set<TransferKey> _thumbnailSends = {};
  final Set<TransferKey> _pendingDeclines = {};
  final Set<TransferKey> _reportedCompletions = {};
  int _nextPollGeneration = 0;

  final Map<TransferOwner, int> _folderLoadIds = {};
  final Map<TransferOwner, int> _folderLoadGenerations = {};
  final Map<TransferOwner, int> _pendingFolderLoadGenerations = {};
  final Map<({String peerId, String conversationId, int loadId}), JamiEvent>
  _earlyFolderSnapshots = {};
  int _nextFolderLoadGeneration = 0;

  bool _sendingFile = false;
  bool _disposed = false;

  bool get sendingFile => _sendingFile;

  /// Seeds an otherwise-empty projection for isolated widget fixtures.
  ///
  /// Production code must build this projection from correlated libjami
  /// events. This deliberately one-shot hook exists because a widget test has
  /// no EventChannel/native folder-load handshake to drive. Exact owner
  /// validation is still enforced.
  @visibleForTesting
  void seedEmptyFolderProjectionForTesting(Iterable<FolderFile> entries) {
    if (_disposed || _transfers.isNotEmpty || _folder.isNotEmpty) {
      throw StateError('file-transfer fixture state must start empty');
    }
    final staged = <TransferKey, FolderFile>{};
    for (final entry in entries) {
      final key = transferKey(entry.peerId, entry.conversationId, entry.fileId);
      if (entry.fileId.isEmpty || !_ownsKey(key)) {
        throw ArgumentError.value(entry, 'entries', 'invalid transfer owner');
      }
      if (staged.containsKey(key)) {
        throw ArgumentError.value(entry, 'entries', 'duplicate transfer key');
      }
      staged[key] = entry;
    }
    _folder.addAll(staged);
    _notify();
  }

  Future<void> sendFile(TransferOwner? owner, {String topicId = ''}) async {
    if (_disposed ||
        owner == null ||
        !_owns(owner) ||
        _sendingFile ||
        _isOffline() ||
        (topicId.isNotEmpty &&
            topicId != DmTopicWire.mainId &&
            !DmTopicWire.isCustomId(topicId))) {
      return;
    }
    _sendingFile = true;
    _notify();
    String? path;
    var handedOff = false;
    try {
      path = await _jami.pickFile();
      if (_disposed || path == null || path.isEmpty || !_owns(owner)) return;
      handedOff = await _jami.sendFile(
        owner.peerId,
        owner.conversationId,
        path,
        topicId: topicId,
      );
      if (handedOff) {
        _onOutgoingStarted?.call(owner);
      } else {
        _log('sendFile did not start');
      }
    } catch (error) {
      _log('sendFile failed: $error');
    } finally {
      if (!handedOff && path != null && path.isNotEmpty) {
        try {
          await _jami.discardPickedFile(path);
        } catch (error) {
          _log('discardPickedFile failed: $error');
        }
      }
      _sendingFile = false;
      _notify();
    }
  }

  Future<void> acceptFile(FileXfer transfer) async {
    if (_disposed || _isOffline()) return;
    final key = transferKey(
      transfer.peerId,
      transfer.conversationId,
      transfer.fileId,
    );
    if (!_ownsKey(key) ||
        !identical(_transfers[key], transfer) ||
        transfer.outgoing ||
        transfer.status == XferStatus.ongoing ||
        transfer.status == XferStatus.canceling ||
        transfer.status == XferStatus.finished ||
        _starts.containsKey(key)) {
      return;
    }
    final operationGuard = Object();
    _starts[key] = operationGuard;
    final attempt = _newReceiveAttempt();
    transfer.attemptId = attempt;
    try {
      final maxBytes = _maxIncomingFileBytes();
      if (maxBytes > 0 && transfer.size > maxBytes) {
        transfer.status = XferStatus.error;
        _clearThumbnail(key);
        _log(
          '→ acceptFile rejected: ${transfer.size}B over '
          '${maxBytes ~/ (1024 * 1024)}MiB cap',
        );
        _notify();
        return;
      }
      transfer.status = XferStatus.ongoing;
      _notify();
      final ok = await _jami.acceptFile(
        transfer.peerId,
        transfer.conversationId,
        transfer.interactionId,
        transfer.fileId,
        transfer.name,
        maxBytes: maxBytes,
        attemptId: attempt,
      );
      if (transfer.attemptId != attempt ||
          !_isCurrent(key, transfer, XferStatus.ongoing)) {
        return;
      }
      if (!ok) {
        transfer.status = XferStatus.error;
        _clearThumbnail(key);
        _notify();
      } else {
        _startPoll(key);
      }
    } catch (error) {
      if (transfer.attemptId == attempt &&
          _isCurrent(key, transfer, XferStatus.ongoing)) {
        transfer.status = XferStatus.error;
        _clearThumbnail(key);
        _notify();
      }
      _log('acceptFile(${transfer.fileId}) failed: $error');
    } finally {
      if (identical(_starts[key], operationGuard)) _starts.remove(key);
    }
  }

  Future<void> declineFile(FileXfer transfer) async {
    // Native cancellation owns a local receive attempt. A published sender seed
    // may serve several independent recipients and is not such an attempt.
    if (_disposed || transfer.outgoing) return;
    final key = transferKey(
      transfer.peerId,
      transfer.conversationId,
      transfer.fileId,
    );
    if (!_ownsKey(key) ||
        !identical(_transfers[key], transfer) ||
        transfer.done ||
        _cancels.containsKey(key)) {
      return;
    }
    final operationGuard = Object();
    _cancels[key] = operationGuard;
    final priorStatus = transfer.status;
    final attempt = transfer.attemptId;
    transfer.status = XferStatus.canceling;
    _notify();
    try {
      var canceled = false;
      Object? cancelError;
      try {
        canceled = await _jami.cancelFile(
          transfer.peerId,
          transfer.conversationId,
          transfer.fileId,
          attemptId: attempt,
        );
      } catch (error) {
        cancelError = error;
      }
      if (transfer.attemptId != attempt ||
          !_isCurrent(key, transfer, XferStatus.canceling)) {
        return;
      }
      var decisionSent = false;
      if (priorStatus == XferStatus.offered) {
        try {
          decisionSent = await _jami.sendFileDeclined(
            transfer.peerId,
            transfer.conversationId,
            transfer.fileId,
          );
        } catch (error) {
          _log('sendFileDeclined(${transfer.fileId}) failed: $error');
        }
      }
      if (transfer.attemptId != attempt ||
          !_isCurrent(key, transfer, XferStatus.canceling)) {
        return;
      }
      if (!canceled && !decisionSent) {
        transfer.status = priorStatus;
        _log(
          cancelError == null
              ? 'cancelFile(${transfer.fileId}) was rejected'
              : 'cancelFile(${transfer.fileId}) failed: $cancelError',
        );
        _notify();
        return;
      }
      transfer.status = priorStatus == XferStatus.offered
          ? XferStatus.declined
          : XferStatus.canceled;
      _stopPoll(key);
      _clearThumbnail(key);
      _notify();
    } finally {
      if (identical(_cancels[key], operationGuard)) _cancels.remove(key);
    }
  }

  /// Starts one correlated rebuild of an exact conversation's file history.
  ///
  /// A callback may beat the platform-method reply. Such snapshots are held
  /// only while that owner has a request in flight and are replayed once the
  /// returned native load ID is known.
  void loadFolder(TransferOwner? owner, {required int keepLast}) {
    if (_disposed || owner == null || !_owns(owner)) return;
    final generation = ++_nextFolderLoadGeneration;
    _folderLoadGenerations[owner] = generation;
    _pendingFolderLoadGenerations[owner] = generation;
    _folderLoadIds.remove(owner);
    _earlyFolderSnapshots.removeWhere(
      (key, _) =>
          key.peerId == owner.peerId &&
          key.conversationId == owner.conversationId,
    );
    _runInBackground(() async {
      try {
        final loadId = await _jami.loadFolder(
          owner.peerId,
          owner.conversationId,
          keepLast,
        );
        if (_disposed ||
            _folderLoadGenerations[owner] != generation ||
            !_owns(owner)) {
          return;
        }
        _pendingFolderLoadGenerations.remove(owner);
        if (loadId <= 0) {
          _earlyFolderSnapshots.removeWhere(
            (key, _) =>
                key.peerId == owner.peerId &&
                key.conversationId == owner.conversationId,
          );
          return;
        }
        _folderLoadIds[owner] = loadId;
        final buffered = _earlyFolderSnapshots.remove((
          peerId: owner.peerId,
          conversationId: owner.conversationId,
          loadId: loadId,
        ));
        _earlyFolderSnapshots.removeWhere(
          (key, _) =>
              key.peerId == owner.peerId &&
              key.conversationId == owner.conversationId,
        );
        if (buffered != null) {
          _applyFolderSnapshot(buffered);
          _notify();
        }
      } finally {
        if (_pendingFolderLoadGenerations[owner] == generation) {
          _pendingFolderLoadGenerations.remove(owner);
        }
      }
    }(), 'loadFolder');
  }

  Future<bool> downloadFile({
    required TransferOwner owner,
    required String fileId,
    required String interactionId,
    required String name,
    required int size,
    required bool downloaded,
    required String operation,
    String topicId = DmTopicWire.mainId,
    bool topicTagged = false,
    String roomId = '',
  }) async {
    final key = transferKey(owner.peerId, owner.conversationId, fileId);
    final topic = _topicOwnership({
      'topicId': topicId,
      'topicTagged': topicTagged,
      'roomId': roomId,
    });
    if (_disposed ||
        _isOffline() ||
        downloaded ||
        !_ownsKey(key) ||
        topic == null ||
        _starts.containsKey(key)) {
      return false;
    }
    final operationGuard = Object();
    _starts[key] = operationGuard;
    final attempt = _newReceiveAttempt();
    try {
      final existing = _transfers[key];
      if (existing != null &&
          (existing.outgoing ||
              existing.status == XferStatus.ongoing ||
              existing.status == XferStatus.canceling ||
              existing.status == XferStatus.finished ||
              existing.roomId != topic.roomId ||
              existing.topicId != topic.topicId ||
              existing.topicTagged != topic.topicTagged)) {
        return false;
      }
      final transfer =
          existing ??
          (_transfers[key] = FileXfer(
            peerId: owner.peerId,
            conversationId: owner.conversationId,
            fileId: fileId,
            interactionId: interactionId,
            name: name,
            size: size,
            outgoing: false,
            topicId: topic.topicId,
            topicTagged: topic.topicTagged,
            roomId: topic.roomId,
          ));
      final maxBytes = _maxIncomingFileBytes();
      if (maxBytes > 0 && size > maxBytes) {
        _log(
          '→ $operation rejected: ${size}B over '
          '${maxBytes ~/ (1024 * 1024)}MiB cap',
        );
        transfer.status = XferStatus.error;
        _clearThumbnail(key);
        _notify();
        return false;
      }

      transfer
        ..attemptId = attempt
        ..interactionId = interactionId
        ..name = name
        ..transferred = 0
        ..size = size
        ..path = null
        ..status = XferStatus.ongoing;
      _notify();

      final ok = await _jami.acceptFile(
        owner.peerId,
        owner.conversationId,
        interactionId,
        fileId,
        name,
        maxBytes: maxBytes,
        attemptId: attempt,
      );
      if (transfer.attemptId != attempt ||
          !_isCurrent(key, transfer, XferStatus.ongoing)) {
        return false;
      }
      if (!ok) {
        transfer.status = XferStatus.error;
        _clearThumbnail(key);
        _notify();
        return false;
      }
      _startPoll(key);
      return true;
    } catch (error) {
      final transfer = _transfers[key];
      if (!_disposed &&
          transfer != null &&
          transfer.attemptId == attempt &&
          transfer.status == XferStatus.ongoing) {
        transfer.status = XferStatus.error;
        _clearThumbnail(key);
        _notify();
      }
      _log('$operation($fileId) failed: $error');
      return false;
    } finally {
      if (identical(_starts[key], operationGuard)) _starts.remove(key);
    }
  }

  /// Retires only one friend's state. Any late native reply is invalidated by
  /// removing its generation and its exact transfer row.
  void retirePeer(String peerId) {
    if (_disposed || peerId.isEmpty) return;
    for (final key
        in _pollers.keys
            .where((candidate) => candidate.peerId == peerId)
            .toList(growable: false)) {
      _stopPoll(key);
    }
    _transfers.removeWhere((key, _) => key.peerId == peerId);
    _pollBusy.removeWhere((key, _) => key.peerId == peerId);
    _folder.removeWhere((key, _) => key.peerId == peerId);
    _starts.removeWhere((key, _) => key.peerId == peerId);
    _cancels.removeWhere((key, _) => key.peerId == peerId);
    _pendingDeclines.removeWhere((key) => key.peerId == peerId);
    _reportedCompletions.removeWhere((key) => key.peerId == peerId);
    _clearThumbnailsWhere((key) => key.peerId == peerId);
    _folderLoadIds.removeWhere((owner, _) => owner.peerId == peerId);
    _folderLoadGenerations.removeWhere((owner, _) => owner.peerId == peerId);
    _pendingFolderLoadGenerations.removeWhere(
      (owner, _) => owner.peerId == peerId,
    );
    _earlyFolderSnapshots.removeWhere((key, _) => key.peerId == peerId);
    _notify();
  }

  /// Reconciles cached state with libjami's latest durable routing snapshot.
  ///
  /// This also handles the rare case where the canonical one-to-one
  /// conversation for an existing friend changes: old callbacks, pollers, and
  /// folder rows are retired as one owner scope instead of being left hidden.
  void reconcileOwners(Iterable<TransferOwner> owners) {
    if (_disposed) return;
    final current = owners
        .where(
          (owner) => owner.peerId.isNotEmpty && owner.conversationId.isNotEmpty,
        )
        .toSet();
    bool validOwner(String peerId, String conversationId) =>
        current.contains((peerId: peerId, conversationId: conversationId));

    for (final key
        in _pollers.keys
            .where(
              (candidate) =>
                  !validOwner(candidate.peerId, candidate.conversationId),
            )
            .toList(growable: false)) {
      _stopPoll(key);
    }
    _transfers.removeWhere(
      (key, _) => !validOwner(key.peerId, key.conversationId),
    );
    _pollBusy.removeWhere(
      (key, _) => !validOwner(key.peerId, key.conversationId),
    );
    _folder.removeWhere(
      (key, _) => !validOwner(key.peerId, key.conversationId),
    );
    _starts.removeWhere(
      (key, _) => !validOwner(key.peerId, key.conversationId),
    );
    _cancels.removeWhere(
      (key, _) => !validOwner(key.peerId, key.conversationId),
    );
    _pendingDeclines.removeWhere(
      (key) => !validOwner(key.peerId, key.conversationId),
    );
    _reportedCompletions.removeWhere(
      (key) => !validOwner(key.peerId, key.conversationId),
    );
    _clearThumbnailsWhere((key) => !validOwner(key.peerId, key.conversationId));
    _folderLoadIds.removeWhere((owner, _) => !current.contains(owner));
    _folderLoadGenerations.removeWhere((owner, _) => !current.contains(owner));
    _pendingFolderLoadGenerations.removeWhere(
      (owner, _) => !current.contains(owner),
    );
    _earlyFolderSnapshots.removeWhere(
      (key, _) => !validOwner(key.peerId, key.conversationId),
    );
    _notify();
  }

  /// Applies only file-domain events. Returns true when the event belongs to
  /// this controller, even when malformed or stale input is rejected.
  bool handleEvent(JamiEvent event) {
    if (_disposed) return false;
    switch (event.type) {
      case 'incomingFile':
        _handleIncomingFile(event);
        break;
      case 'fileProgress':
        _handleFileProgress(event);
        break;
      case 'fileThumbnail':
        _handleFileThumbnail(event);
        break;
      case 'fileDeclined':
        _handleFileDeclined(event);
        break;
      case 'folderSnapshot':
        _handleFolderSnapshot(event);
        break;
      case 'folderFile':
        _handleFolderFile(event);
        break;
      default:
        return false;
    }
    _notify();
    return true;
  }

  void _handleIncomingFile(JamiEvent event) {
    final fileId = _asString(event.data['fileId']);
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    final topic = _topicOwnership(event.data);
    if (fileId.isEmpty || !_ownsEvent(event, owner) || topic == null) return;

    final key = transferKey(peerId, conversationId, fileId);
    final name = _asString(event.data['name'], 'file');
    final interactionId = _asString(event.data['interactionId']);
    final authorId = _asString(event.data['authorId']);
    final size = _asInt(event.data['size']);
    final existing = _transfers[key];
    if (existing == null) {
      final transfer = _transfers[key] = FileXfer(
        peerId: peerId,
        conversationId: conversationId,
        fileId: fileId,
        interactionId: interactionId,
        name: name,
        size: size,
        outgoing: false,
        authorId: authorId,
        topicId: topic.topicId,
        topicTagged: topic.topicTagged,
        roomId: topic.roomId,
        status: XferStatus.offered,
      );
      _adoptPendingThumbnail(key, transfer);
      _adoptPendingDecline(key, transfer);
      _hydratePreviewPath(key, transfer);
      return;
    }
    if (existing.outgoing ||
        existing.roomId != topic.roomId ||
        existing.topicId != topic.topicId ||
        existing.topicTagged != topic.topicTagged) {
      return;
    }
    if (name.isNotEmpty && name != 'file') existing.name = name;
    if (interactionId.isNotEmpty) existing.interactionId = interactionId;
    if (authorId.isNotEmpty) existing.authorId = authorId;
    if (size > 0) existing.size = size;
    if (existing.status == XferStatus.waiting) {
      existing.status = XferStatus.offered;
    }
    _adoptPendingThumbnail(key, existing);
  }

  void _handleFileProgress(JamiEvent event) {
    final fileId = _asString(event.data['fileId']);
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    final key = transferKey(peerId, conversationId, fileId);
    final existing = _transfers[key];
    final cachedMetadataLost = event.data['metadataKnown'] == false;
    final topic =
        cachedMetadataLost &&
            existing != null &&
            existing.interactionId.isNotEmpty &&
            existing.interactionId == _asString(event.data['interactionId'])
        ? (
            topicId: existing.topicId,
            topicTagged: existing.topicTagged,
            roomId: existing.roomId,
          )
        : _topicOwnership(event.data);
    if (fileId.isEmpty || !_ownsEvent(event, owner) || topic == null) return;

    final outgoing = _asBool(event.data['outgoing']);
    final eventName = _asString(event.data['name']);
    final authorId = _asString(event.data['authorId']);
    if (!outgoing &&
        (existing == null ||
            existing.attemptId.isEmpty ||
            event.data['attemptId'] != existing.attemptId)) {
      return;
    }
    if (existing != null &&
        (existing.outgoing != outgoing ||
            existing.roomId != topic.roomId ||
            existing.topicId != topic.topicId ||
            existing.topicTagged != topic.topicTagged)) {
      return;
    }

    // A receiver may see byte progress before the authenticated swarm commit
    // that contains its name/direction. Never turn that anonymous callback
    // into an actionable offer.
    if (existing == null && eventName.isEmpty) return;
    final transfer =
        existing ??
        (_transfers[key] = FileXfer(
          peerId: peerId,
          conversationId: conversationId,
          fileId: fileId,
          interactionId: _asString(event.data['interactionId']),
          name: eventName,
          size: _asInt(event.data['total']),
          outgoing: outgoing,
          authorId: authorId,
          topicId: topic.topicId,
          topicTagged: topic.topicTagged,
          roomId: topic.roomId,
        ));
    _adoptPendingDecline(key, transfer);
    if (eventName.isNotEmpty &&
        (transfer.name.isEmpty || transfer.name == 'file')) {
      transfer.name = eventName;
    }
    if (authorId.isNotEmpty) transfer.authorId = authorId;

    var next = _xferStatus(_asString(event.data['status']));
    if (!transfer.outgoing && next == XferStatus.waiting) {
      next = XferStatus.offered;
    }
    final accepted =
        transfer.status == XferStatus.ongoing ||
        transfer.status == XferStatus.canceling;
    final cancelPending = transfer.status == XferStatus.canceling;
    if (!transfer.done &&
        !(accepted &&
            (next == XferStatus.offered || next == XferStatus.waiting))) {
      // libjami cancellation is asynchronous. Do not let an in-flight
      // `ongoing` callback undo the visible cancel request; only a terminal
      // daemon event resolves it.
      if (!cancelPending || next != XferStatus.ongoing) {
        transfer.status = next;
      }
    }
    final total = _asInt(event.data['total']);
    if (total > 0) transfer.size = total;
    final transferred = _asInt(event.data['transferred']);
    if (transferred > transfer.transferred) {
      transfer.transferred = transferred;
    }
    final path = event.data['path'];
    if (path is String && path.isNotEmpty) {
      transfer.path = path;
      _maybeSendThumbnail(key, transfer);
    }

    if (transfer.status == XferStatus.ongoing ||
        transfer.status == XferStatus.canceling) {
      _startPoll(key);
    } else {
      _stopPoll(key);
    }
    if (transfer.status == XferStatus.finished) {
      _markFolderDownloaded(transfer);
      _reportCompleted(key, transfer);
    }
    if (transfer.done) _clearThumbnail(key);
  }

  void _handleFileThumbnail(JamiEvent event) {
    final fileId = _asString(event.data['fileId']);
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    if (fileId.isEmpty ||
        !_directJamiId.hasMatch(peerId) ||
        !_ownsEvent(event, owner)) {
      return;
    }

    final encoded = _asString(event.data['pngBase64']);
    if (!_isPaddedBase64(encoded)) return;
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      return;
    }
    if (bytes.isEmpty ||
        bytes.length > _thumbnailMaxPngBytes ||
        !_isBoundedThumbnailPng(bytes)) {
      return;
    }

    final key = transferKey(peerId, conversationId, fileId);
    final transfer = _transfers[key];
    if (transfer != null && !transfer.outgoing) {
      if (_isImageName(transfer.name)) {
        _setThumbnail(key, transfer, bytes);
      } else if (transfer.name != 'file') {
        _clearThumbnail(key);
      } else {
        _bufferThumbnail(key, bytes);
      }
      return;
    }
    if (transfer == null) _bufferThumbnail(key, bytes);
  }

  void _handleFileDeclined(JamiEvent event) {
    final fileId = _asString(event.data['fileId']);
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    if (fileId.isEmpty ||
        !_directJamiId.hasMatch(peerId) ||
        !_ownsEvent(event, owner)) {
      return;
    }
    final key = transferKey(peerId, conversationId, fileId);
    final transfer = _transfers[key];
    if (transfer == null) {
      if (_pendingDeclines.length >= _pendingDecisionLimit) {
        _pendingDeclines.remove(_pendingDeclines.first);
      }
      _pendingDeclines.add(key);
      return;
    }
    _pendingDeclines.add(key);
    _adoptPendingDecline(key, transfer);
  }

  void _handleFolderSnapshot(JamiEvent event) {
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final loadId = _asInt(event.data['loadId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    if (loadId <= 0 || !_ownsEvent(event, owner)) return;
    if (_pendingFolderLoadGenerations.containsKey(owner)) {
      final key = (
        peerId: peerId,
        conversationId: conversationId,
        loadId: loadId,
      );
      _earlyFolderSnapshots[key] = event;
      if (_earlyFolderSnapshots.length > 32) {
        _earlyFolderSnapshots.remove(_earlyFolderSnapshots.keys.first);
      }
      return;
    }
    _applyFolderSnapshot(event);
  }

  void _applyFolderSnapshot(JamiEvent event) {
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final loadId = _asInt(event.data['loadId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    if (_disposed ||
        !_ownsEvent(event, owner) ||
        loadId <= 0 ||
        _folderLoadIds[owner] != loadId) {
      return;
    }

    Object? rawFiles = event.data['files'];
    if (rawFiles is! List) {
      final encoded = _asString(event.data['filesJson']);
      if (encoded.length > TimelineWireContract.maxSnapshotEncodedBytes ||
          utf8.encode(encoded).length >
              TimelineWireContract.maxSnapshotEncodedBytes) {
        _log('folderSnapshot($loadId) exceeds the encoded-size contract');
        return;
      }
      try {
        rawFiles = encoded.isEmpty ? const [] : jsonDecode(encoded);
      } catch (error) {
        _log('folderSnapshot($loadId) malformed: $error');
        return;
      }
    }
    if (rawFiles is! List || rawFiles.length > 5000) {
      _log('folderSnapshot($loadId) violates the item-count contract');
      return;
    }

    final staged = <TransferKey, FolderFile>{};
    final canonicalTimes = <TransferKey, DateTime>{};
    for (final raw in rawFiles) {
      if (raw is! Map) {
        _log('folderSnapshot($loadId) contains a non-object item');
        return;
      }
      final item = <String, dynamic>{
        for (final entry in raw.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
      if (item.length != raw.length) {
        _log('folderSnapshot($loadId) contains a non-string field name');
        return;
      }
      final fileId = _boundedString(
        item['fileId'],
        TimelineWireContract.maxFileIdCodeUnits,
      );
      final interactionId = _boundedString(
        item['interactionId'],
        TimelineWireContract.maxDaemonIdCodeUnits,
      );
      final name = _boundedString(
        item['name'] ?? 'file',
        TimelineWireContract.maxDisplayNameCodeUnits,
      );
      final sha3 = _boundedString(
        item['sha3'] ?? '',
        TimelineWireContract.maxHashCodeUnits,
        allowEmpty: true,
      );
      final authorId = _boundedString(
        item['authorId'] ?? '',
        TimelineWireContract.maxAuthorIdCodeUnits,
        allowEmpty: true,
      );
      final size = item['size'] == null ? -1 : _strictInt(item['size']);
      final outgoing = item['outgoing'] == null
          ? false
          : _strictBool(item['outgoing']);
      final downloaded = item['downloaded'] == null
          ? false
          : _strictBool(item['downloaded']);
      final timestamp = item['timestamp'] == null
          ? 0
          : _strictInt(item['timestamp']);
      final topic = _topicOwnership(item);
      if (fileId == null ||
          interactionId == null ||
          name == null ||
          sha3 == null ||
          authorId == null ||
          size == null ||
          size < -1 ||
          outgoing == null ||
          downloaded == null ||
          timestamp == null ||
          timestamp < 0 ||
          topic == null) {
        _log('folderSnapshot($loadId) contains a malformed item');
        return;
      }
      final key = transferKey(peerId, conversationId, fileId);
      if (staged.containsKey(key)) {
        _log('folderSnapshot($loadId) contains a duplicate file id');
        return;
      }
      final live = _transfers[key];
      if (live != null && timestamp > 0) {
        canonicalTimes[key] = DateTime.fromMillisecondsSinceEpoch(
          timestamp * 1000,
          isUtc: true,
        );
      }
      staged[key] = FolderFile(
        peerId: peerId,
        conversationId: conversationId,
        fileId: fileId,
        interactionId: interactionId,
        name: name,
        size: size,
        sha3: sha3,
        outgoing: outgoing,
        authorId: authorId,
        topicId: topic.topicId,
        topicTagged: topic.topicTagged,
        roomId: topic.roomId,
        downloaded:
            downloaded || (live != null && live.status == XferStatus.finished),
        timestamp: timestamp,
      );
    }
    // A folder snapshot is one authoritative projection. Parse and validate
    // every row before replacing any visible state so malformed native data
    // cannot produce a plausible-looking partial history.
    _folder.removeWhere(
      (key, _) => key.peerId == peerId && key.conversationId == conversationId,
    );
    _folder.addAll(staged);
    for (final entry in canonicalTimes.entries) {
      _transfers[entry.key]?.createdAt = entry.value;
    }
  }

  void _handleFolderFile(JamiEvent event) {
    final fileId = _asString(event.data['fileId']);
    final peerId = _asString(event.data['peerJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final owner = (peerId: peerId, conversationId: conversationId);
    final topic = _topicOwnership(event.data);
    if (fileId.isEmpty || !_ownsEvent(event, owner) || topic == null) return;

    final key = transferKey(peerId, conversationId, fileId);
    final name = _asString(event.data['name'], 'file');
    final interactionId = _asString(event.data['interactionId']);
    final size = _asInt(event.data['size']);
    final sha3 = _asString(event.data['sha3']);
    final authorId = _asString(event.data['authorId']);
    final outgoing = _asBool(event.data['outgoing']);
    final downloaded = _asBool(event.data['downloaded']);
    final liveEvent = _asBool(event.data['live']);
    final timestamp = _asInt(event.data['timestamp']);
    if (timestamp > 0) {
      final transfer = _transfers[key];
      if (transfer != null) {
        transfer.createdAt = DateTime.fromMillisecondsSinceEpoch(
          timestamp * 1000,
          isUtc: true,
        );
      }
    }
    if (liveEvent && outgoing && !_transfers.containsKey(key)) {
      final transfer = _transfers[key] = FileXfer(
        peerId: peerId,
        conversationId: conversationId,
        fileId: fileId,
        interactionId: interactionId,
        name: name,
        size: size,
        outgoing: true,
        authorId: authorId,
        topicId: topic.topicId,
        topicTagged: topic.topicTagged,
        roomId: topic.roomId,
        status: XferStatus.waiting,
        createdAt: timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true)
            : null,
      );
      _adoptPendingDecline(key, transfer);
      _hydratePreviewPath(key, transfer);
    }
    final existing = _folder[key];
    if (existing != null &&
        (existing.roomId != topic.roomId ||
            existing.topicId != topic.topicId ||
            existing.topicTagged != topic.topicTagged)) {
      return;
    }
    if (existing == null) {
      _folder[key] = FolderFile(
        peerId: peerId,
        conversationId: conversationId,
        fileId: fileId,
        interactionId: interactionId,
        name: name,
        size: size,
        sha3: sha3,
        outgoing: outgoing,
        authorId: authorId,
        topicId: topic.topicId,
        topicTagged: topic.topicTagged,
        roomId: topic.roomId,
        downloaded: downloaded,
        timestamp: timestamp,
      );
      return;
    }

    if (name.isNotEmpty && name != 'file') existing.name = name;
    if (interactionId.isNotEmpty) existing.interactionId = interactionId;
    if (size > 0) existing.size = size;
    if (sha3.isNotEmpty) existing.sha3 = sha3;
    if (authorId.isNotEmpty) existing.authorId = authorId;
    if (timestamp > 0) existing.timestamp = timestamp;
    if (liveEvent) {
      if (downloaded) existing.downloaded = true;
      return;
    }

    // In-flight bytes do not prove that hash validation and rename succeeded.
    // Only completed transfer evidence can supplement the native disk query.
    final transfer = _transfers[key];
    final liveSaved =
        transfer != null && transfer.status == XferStatus.finished;
    existing.downloaded = downloaded || liveSaved;
  }

  void _markFolderDownloaded(FileXfer transfer) {
    final key = transferKey(
      transfer.peerId,
      transfer.conversationId,
      transfer.fileId,
    );
    final existing = _folder[key];
    if (existing != null) {
      existing.downloaded = true;
      if (transfer.path != null) existing.path = transfer.path;
      return;
    }
    _folder[key] = FolderFile(
      peerId: transfer.peerId,
      conversationId: transfer.conversationId,
      fileId: transfer.fileId,
      interactionId: transfer.interactionId,
      name: transfer.name,
      size: transfer.size,
      outgoing: transfer.outgoing,
      authorId: transfer.authorId,
      topicId: transfer.topicId,
      topicTagged: transfer.topicTagged,
      roomId: transfer.roomId,
      downloaded: true,
      path: transfer.path,
      timestamp: _now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  void _bufferThumbnail(TransferKey key, Uint8List bytes) {
    if (!_pendingThumbnails.containsKey(key) &&
        _pendingThumbnails.length >= _thumbnailPendingLimit) {
      _clearThumbnail(_pendingThumbnails.keys.first);
    }
    _pendingThumbnails[key] = bytes;
    _armThumbnailExpiry(key, bytes);
  }

  void _adoptPendingThumbnail(TransferKey key, FileXfer transfer) {
    final bytes = _pendingThumbnails.remove(key);
    if (bytes == null) return;
    if (!_isImageName(transfer.name) || transfer.outgoing) {
      _clearThumbnail(key);
      return;
    }
    transfer.previewBytes = bytes;
  }

  void _adoptPendingDecline(TransferKey key, FileXfer transfer) {
    if (!transfer.outgoing || !_pendingDeclines.remove(key)) return;
    transfer.status = XferStatus.declined;
    _stopPoll(key);
    _clearThumbnail(key);
  }

  void _setThumbnail(TransferKey key, FileXfer transfer, Uint8List bytes) {
    _pendingThumbnails.remove(key);
    transfer.previewBytes = bytes;
    _armThumbnailExpiry(key, bytes);
  }

  void _armThumbnailExpiry(TransferKey key, Uint8List bytes) {
    _thumbnailTimers.remove(key)?.cancel();
    _thumbnailTimers[key] = Timer(_thumbnailLifetime, () {
      _thumbnailTimers.remove(key);
      _pendingThumbnails.remove(key);
      final transfer = _transfers[key];
      if (transfer != null && identical(transfer.previewBytes, bytes)) {
        transfer.previewBytes = null;
        _notify();
      }
    });
  }

  void _clearThumbnail(TransferKey key) {
    _thumbnailTimers.remove(key)?.cancel();
    _pendingThumbnails.remove(key);
    _thumbnailSends.remove(key);
    final transfer = _transfers[key];
    if (transfer != null) transfer.previewBytes = null;
  }

  void _clearThumbnailsWhere(bool Function(TransferKey key) test) {
    final keys = <TransferKey>{
      ..._thumbnailTimers.keys,
      ..._pendingThumbnails.keys,
      ..._thumbnailSends,
      ..._transfers.keys.where(test),
    }.where(test).toList(growable: false);
    for (final key in keys) {
      _clearThumbnail(key);
    }
  }

  void _maybeSendThumbnail(TransferKey key, FileXfer transfer) {
    final path = transfer.path;
    if (_disposed ||
        !transfer.outgoing ||
        transfer.status != XferStatus.waiting ||
        path == null ||
        path.isEmpty ||
        !_directJamiId.hasMatch(key.peerId) ||
        !_isImageName(transfer.name) ||
        !_thumbnailSends.add(key)) {
      return;
    }
    _runInBackground(() async {
      var sent = false;
      try {
        final png = await _buildFileThumbnail(path);
        if (png == null ||
            _disposed ||
            !identical(_transfers[key], transfer) ||
            transfer.status != XferStatus.waiting ||
            transfer.path != path) {
          return;
        }
        sent = await _jami.sendFileThumbnail(
          key.peerId,
          key.conversationId,
          key.fileId,
          png,
        );
      } finally {
        if (!sent) _thumbnailSends.remove(key);
      }
    }(), 'fileThumbnail(${key.fileId})');
  }

  void _startPoll(TransferKey key) {
    if (_disposed || _pollers.containsKey(key) || !_ownsKey(key)) return;
    final generation = ++_nextPollGeneration;
    _pollGenerations[key] = generation;
    _pollers[key] = Timer.periodic(_pollInterval, (_) {
      unawaited(_pollFile(key, generation));
    });
  }

  void _hydratePreviewPath(TransferKey key, FileXfer transfer) {
    if (_pollBusy.containsKey(key)) return;
    final query = (token: Object(), preview: true);
    final account = _accountId();
    _pollBusy[key] = query;
    _runInBackground(() async {
      try {
        final info = await _jami.fileInfo(
          key.peerId,
          key.conversationId,
          key.fileId,
        );
        if (_disposed ||
            _accountId() != account ||
            !_ownsKey(key) ||
            _pollBusy[key] != query ||
            !identical(_transfers[key], transfer)) {
          return;
        }
        final path = info['path'];
        if (info['completed'] == true && path is String && path.isNotEmpty) {
          transfer.path = path;
          _maybeSendThumbnail(key, transfer);
          _notify();
        }
      } finally {
        if (_pollBusy[key] == query) _pollBusy.remove(key);
      }
    }(), 'fileInfo(preview)');
  }

  Future<void> _pollFile(TransferKey key, int generation) async {
    if (_disposed ||
        _pollGenerations[key] != generation ||
        _pollBusy.containsKey(key)) {
      return;
    }
    final query = (token: Object(), preview: false);
    final account = _accountId();
    _pollBusy[key] = query;
    try {
      final transfer = _transfers[key];
      if (transfer == null ||
          (transfer.status != XferStatus.ongoing &&
              transfer.status != XferStatus.canceling)) {
        if (_pollGenerations[key] == generation) _stopPoll(key);
        return;
      }
      final attempt = transfer.attemptId;
      final info = await _jami.fileInfo(
        key.peerId,
        key.conversationId,
        key.fileId,
      );
      if (_disposed ||
          _accountId() != account ||
          !_ownsKey(key) ||
          _pollGenerations[key] != generation ||
          _pollBusy[key] != query ||
          !identical(_transfers[key], transfer) ||
          transfer.attemptId != attempt) {
        return;
      }
      final current = _transfers[key];
      if (current == null ||
          (current.status != XferStatus.ongoing &&
              current.status != XferStatus.canceling) ||
          info.isEmpty) {
        return;
      }

      final total = _asInt(info['total']);
      final transferred = _asInt(info['transferred']);
      final maxBytes = _maxIncomingFileBytes();
      if (!current.outgoing &&
          maxBytes > 0 &&
          (total > maxBytes || transferred > maxBytes)) {
        _runBoolInBackground(
          _jami.cancelFile(
            key.peerId,
            key.conversationId,
            key.fileId,
            attemptId: attempt,
          ),
          'cancelFile(oversize)',
        );
        current.status = XferStatus.error;
        _log(
          '→ incoming ${key.fileId} aborted — exceeds '
          '${maxBytes ~/ (1024 * 1024)}MiB cap',
        );
        _stopPoll(key);
        _notify();
        return;
      }
      if (transferred > current.transferred) {
        current.transferred = transferred;
      }
      // The daemon reports byte progress before hash validation and final
      // rename. A full count is not a terminal transfer result.
      final path = info['path'];
      if (info['completed'] == true && path is String && path.isNotEmpty) {
        current.path = path;
        _maybeSendThumbnail(key, current);
        // Recover a missed terminal callback from native finalization evidence.
        // Zero bytes is a valid completed file, never inferred from progress.
        if (total >= 0 && transferred == total) {
          current.size = total;
          current.transferred = total;
          current.status = XferStatus.finished;
          _stopPoll(key);
          _markFolderDownloaded(current);
          _reportCompleted(key, current);
          _clearThumbnail(key);
        }
      }
      _notify();
    } catch (error) {
      if (!_disposed && _pollGenerations[key] == generation) {
        _log('fileInfo(${key.fileId}) failed: $error');
      }
    } finally {
      if (_pollBusy[key] == query) _pollBusy.remove(key);
    }
  }

  void _stopPoll(TransferKey key) {
    _pollers.remove(key)?.cancel();
    _pollGenerations.remove(key);
    // A waiting callback stops progress polling, but does not retire the
    // separately admitted preview query for this same transfer.
    if (_pollBusy[key]?.preview != true) _pollBusy.remove(key);
  }

  void _reportCompleted(TransferKey key, FileXfer transfer) {
    if (transfer.status == XferStatus.finished &&
        _reportedCompletions.add(key)) {
      _onCompletedTransfer?.call(transfer);
    }
  }

  bool _owns(TransferOwner owner) =>
      owner.peerId.isNotEmpty &&
      owner.conversationId.isNotEmpty &&
      _ownsConversation(owner.peerId, owner.conversationId);

  bool _ownsEvent(JamiEvent event, TransferOwner owner) {
    final activeAccount = _accountId();
    return activeAccount.isNotEmpty &&
        _asString(event.data['accountId']) == activeAccount &&
        _owns(owner);
  }

  bool _ownsKey(TransferKey key) =>
      _owns((peerId: key.peerId, conversationId: key.conversationId));

  bool _isCurrent(TransferKey key, FileXfer transfer, XferStatus status) =>
      !_disposed &&
      _ownsKey(key) &&
      identical(_transfers[key], transfer) &&
      transfer.status == status;

  void _runInBackground(Future<void> future, String operation) {
    unawaited(() async {
      try {
        await future;
      } catch (error) {
        if (!_disposed) _log('$operation failed: $error');
      }
    }());
  }

  void _runBoolInBackground(Future<bool> future, String operation) {
    unawaited(() async {
      try {
        if (!await future) _log('$operation was rejected');
      } catch (error) {
        _log('$operation failed: $error');
      }
    }());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final poller in _pollers.values) {
      poller.cancel();
    }
    _pollers.clear();
    _pollGenerations.clear();
    _pollBusy.clear();
    _starts.clear();
    for (final timer in _thumbnailTimers.values) {
      timer.cancel();
    }
    _thumbnailTimers.clear();
    _pendingThumbnails.clear();
    _thumbnailSends.clear();
    _pendingDeclines.clear();
    _reportedCompletions.clear();
    _folderLoadIds.clear();
    _folderLoadGenerations.clear();
    _pendingFolderLoadGenerations.clear();
    _earlyFolderSnapshots.clear();
    super.dispose();
  }
}

Future<Uint8List?> _buildFileThumbnail(String path) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final handle = await file.open();
    Uint8List source;
    try {
      final length = await handle.length();
      if (length < 1 || length > _thumbnailMaxSourceBytes) return null;
      source = await handle.read(length);
      if (source.length != length || await handle.length() != length) {
        return null;
      }
    } finally {
      await handle.close();
    }
    // A thumbnail target size does not bound GIF source decoding. Sniff actual
    // bytes as well as the name so renaming an animation cannot skip the gate.
    final gifHeader =
        source.length >= 6 &&
        (String.fromCharCodes(source.take(6)) == 'GIF87a' ||
            String.fromCharCodes(source.take(6)) == 'GIF89a');
    if ((gifHeader || path.toLowerCase().endsWith('.gif')) &&
        await validateGifDecode(source) == null) {
      return null;
    }

    buffer = await ui.ImmutableBuffer.fromUint8List(source);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    var targetWidth = descriptor.width;
    var targetHeight = descriptor.height;
    if (targetWidth <= 0 || targetHeight <= 0) return null;
    if (targetWidth > _thumbnailSide || targetHeight > _thumbnailSide) {
      if (targetWidth >= targetHeight) {
        targetHeight = math.max(
          1,
          (targetHeight * _thumbnailSide / targetWidth).round(),
        );
        targetWidth = _thumbnailSide;
      } else {
        targetWidth = math.max(
          1,
          (targetWidth * _thumbnailSide / targetHeight).round(),
        );
        targetHeight = _thumbnailSide;
      }
    }
    codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > _thumbnailMaxPngBytes) return null;
    final png = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    return _isBoundedThumbnailPng(png) ? png : null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

bool _isImageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return const {
    '.bmp',
    '.gif',
    '.jpeg',
    '.jpg',
    '.png',
    '.webp',
  }.contains(name.substring(dot).toLowerCase());
}

bool _isBoundedThumbnailPng(Uint8List bytes) {
  if (bytes.length < 33 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4e ||
      bytes[3] != 0x47 ||
      bytes[4] != 0x0d ||
      bytes[5] != 0x0a ||
      bytes[6] != 0x1a ||
      bytes[7] != 0x0a) {
    return false;
  }
  // PNG's first chunk must be the fixed 13-byte IHDR. Bounding both
  // dimensions before Image.memory sees it prevents decompression bombs.
  if (_pngUint32(bytes, 8) != 13 ||
      bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return false;
  }
  final width = _pngUint32(bytes, 16);
  final height = _pngUint32(bytes, 20);
  return width > 0 &&
      width <= _thumbnailSide &&
      height > 0 &&
      height <= _thumbnailSide;
}

int _pngUint32(Uint8List bytes, int offset) =>
    bytes[offset] << 24 |
    bytes[offset + 1] << 16 |
    bytes[offset + 2] << 8 |
    bytes[offset + 3];

bool _isPaddedBase64(String value) =>
    value.isNotEmpty &&
    value.length <= _thumbnailMaxBase64Chars &&
    value.length % 4 == 0 &&
    RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(value);

XferStatus _xferStatus(String? value) => switch (value) {
  'waiting' => XferStatus.waiting,
  'ongoing' => XferStatus.ongoing,
  'finished' => XferStatus.finished,
  'declined' => XferStatus.declined,
  'canceled' => XferStatus.canceled,
  'error' => XferStatus.error,
  _ => XferStatus.waiting,
};

int _asInt(Object? value, [int fallback = 0]) =>
    value is int ? value : int.tryParse('${value ?? ''}') ?? fallback;

String _asString(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

bool _asBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value == 'true') return true;
  if (value == 'false') return false;
  return fallback;
}

({String topicId, bool topicTagged, String roomId})? _topicOwnership(
  Map<String, dynamic> value,
) {
  final roomId = value['roomId'] ?? '';
  if (roomId is! String ||
      (roomId.isNotEmpty &&
          !RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(roomId))) {
    return null;
  }
  final rawId = value['topicId'];
  final rawTagged = value['topicTagged'];
  if (rawId == null && rawTagged == null) {
    return (topicId: DmTopicWire.mainId, topicTagged: false, roomId: roomId);
  }
  final tagged = switch (rawTagged) {
    null => false,
    _ => _strictBool(rawTagged),
  };
  final topicId = rawId ?? DmTopicWire.mainId;
  if (tagged == null ||
      topicId is! String ||
      (topicId != DmTopicWire.mainId && !DmTopicWire.isCustomId(topicId)) ||
      (!tagged && topicId != DmTopicWire.mainId)) {
    return null;
  }
  return (topicId: topicId, topicTagged: tagged, roomId: roomId);
}

String? _boundedString(
  Object? value,
  int maxCodeUnits, {
  bool allowEmpty = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > maxCodeUnits) {
    return null;
  }
  return value;
}

int? _strictInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

bool? _strictBool(Object? value) => switch (value) {
  true || 'true' => true,
  false || 'false' => false,
  _ => null,
};
