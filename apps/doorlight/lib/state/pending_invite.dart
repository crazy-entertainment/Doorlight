import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/invite_link.dart';

/// A local continuation, never a trust grant or transferable setting.
final class PendingInvite {
  PendingInvite(this.invite, this.receivedAt);

  final SyblInviteLink invite;
  final DateTime receivedAt;

  bool isCurrent(DateTime now) =>
      !now.isBefore(receivedAt) &&
      now.difference(receivedAt) < PendingInviteStore.lifetime;
}

/// One persisted public hint, plus one bounded, memory-only replacement offer.
/// Reopening the same link never extends its original continuation deadline.
final class PendingInviteStore extends ChangeNotifier {
  PendingInviteStore({
    required Object? source,
    required this.persist,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _pending = _decode(source);
    if (source != null && _pending == null) unawaited(_write(null));
    _scheduleExpiry();
  }

  static const preferenceKey = 'doorlight.pendingInvite.v1';
  static const lifetime = Duration(hours: 24);
  final Future<bool> Function(String?) persist;
  final DateTime Function() _now;
  PendingInvite? _pending;
  PendingInvite? _replacement;
  Timer? _expiry;
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;
  bool persistenceFailed = false;
  int presentationRevision = 0;

  PendingInvite? get pending =>
      _pending?.isCurrent(_now()) == true ? _pending : null;
  PendingInvite? get replacement =>
      _replacement?.isCurrent(_now()) == true ? _replacement : null;

  PendingInvite? _decode(Object? source) {
    if (source is! String || source.length > 2048) return null;
    try {
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> ||
          value.length != 3 ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['receivedAt'] is! int) {
        return null;
      }
      final invite = SyblInviteLink.tryParse(value['link']);
      if (invite == null) return null;
      final record = PendingInvite(
        invite,
        DateTime.fromMillisecondsSinceEpoch(
          value['receivedAt'] as int,
          isUtc: true,
        ),
      );
      return record.isCurrent(_now()) ? record : null;
    } on Object {
      // A corrupt public hint must not block account recovery or reveal payloads.
      return null;
    }
  }

  String _encode(PendingInvite record) => jsonEncode({
    'version': 1,
    'link': record.invite.canonicalUri,
    'receivedAt': record.receivedAt.millisecondsSinceEpoch,
  });

  Future<bool> _write(String? source) {
    final result = _writes.then((_) async {
      try {
        return await persist(source);
      } on Object {
        return false;
      }
    });
    _writes = result.then((saved) {
      if (_disposed) return;
      if (persistenceFailed != !saved) {
        persistenceFailed = !saved;
        notifyListeners();
      }
    });
    return result;
  }

  void stage(Object? value) {
    if (_disposed) return;
    final invite = SyblInviteLink.tryParse(value);
    if (invite == null) return;
    if (invite == pending?.invite) {
      presentationRevision++;
      notifyListeners();
      return;
    }
    final record = PendingInvite(
      invite,
      DateTime.fromMillisecondsSinceEpoch(
        _now().millisecondsSinceEpoch,
        isUtc: true,
      ),
    );
    if (pending == null) {
      _pending = record;
      unawaited(_write(_encode(record)));
    } else {
      // Never retarget an existing replacement confirmation either.
      if (replacement != null) return;
      _replacement = record;
    }
    _scheduleExpiry();
    presentationRevision++;
    notifyListeners();
  }

  bool acceptReplacement(PendingInvite record, PendingInvite? previous) {
    if (_disposed ||
        !identical(replacement, record) ||
        !identical(pending, previous)) {
      return false;
    }
    _pending = record;
    _replacement = null;
    unawaited(_write(_encode(record)));
    _scheduleExpiry();
    presentationRevision++;
    notifyListeners();
    return true;
  }

  void rejectReplacement(PendingInvite record) {
    if (_disposed || !identical(_replacement, record)) return;
    _replacement = null;
    _scheduleExpiry();
    notifyListeners();
  }

  /// Await persisted removal before issuing a trust request. A failed clear must not send:
  /// otherwise a restart could offer an already-issued request for retry.
  Future<bool> discard(PendingInvite record) async {
    if (_disposed || !identical(pending, record)) return false;
    // Retain the exact owner until removal is acknowledged. Clearing it before
    // the await lets a duplicate open enqueue a fresh copy behind this removal.
    final saved = await _write(null);
    if (!saved || _disposed || !identical(_pending, record)) return false;
    _pending = null;
    _scheduleExpiry();
    notifyListeners();
    // Successful storage is not permission to use an expired continuation.
    return record.isCurrent(_now());
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    if (_disposed) return;
    final times = [
      if (pending case final record?) record.receivedAt.add(lifetime),
      if (replacement case final record?) record.receivedAt.add(lifetime),
    ]..sort();
    if (times.isEmpty) return;
    _expiry = Timer(times.first.difference(_now()), () {
      if (_disposed) return;
      if (_pending != null && pending == null) {
        _pending = null;
        unawaited(_write(null));
      }
      if (_replacement != null && replacement == null) _replacement = null;
      _scheduleExpiry();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _expiry?.cancel();
    super.dispose();
  }
}
