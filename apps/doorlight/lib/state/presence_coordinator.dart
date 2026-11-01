import 'dart:async';

/// What Syb-L can honestly claim about a friend right now.
enum PeerPresence {
  /// No fresh end-to-end evidence yet.
  unknown,

  /// A fresh negative (status 0, probe failure, or probe timeout).
  unreachable,

  /// Transport-verified alive, but not known to be looking at Syb-L.
  reachable,

  /// Transport-verified alive with a fresh foreground stamp.
  inApp,
}

/// Owns all per-friend presence work: one probe, verdict timer, hint cooldown, and in-app sweep per friend.
///
/// The daemon remains the transport source of truth. This coordinator only correlates its message ids and
/// schedules bounded checks; state storage stays in [AppState] through the supplied callbacks.
class PresenceCoordinator {
  PresenceCoordinator(
    this._probe,
    this._connectivitySweep,
    this._presenceOf,
    this._onEvidence,
    this._onUnreachable,
    this._log,
  );

  final Future<String> Function(String peerId) _probe;
  final Future<void> Function() _connectivitySweep;
  final PeerPresence? Function(String peerId) _presenceOf;
  final void Function(String peerId) _onEvidence;
  final void Function(String peerId) _onUnreachable;
  final void Function(String line) _log;

  final Map<String, String> _messageIds = {};
  final Map<String, Timer> _verdictTimers = {};
  final Map<String, Object> _probeTokens = {};
  final Map<String, Map<String, int>> _earlyTerminalStatuses = {};
  final Set<String> _probing = {};
  final Map<String, DateTime> _lastHints = {};
  final Map<String, Timer> _sweepTimers = {};

  Set<String> _peers = const {};
  bool _foreground = true;
  bool _dark = false;
  bool _callActive = false;
  bool _disposed = false;
  DateTime? _lastBeacon;

  Duration sweepEvery = const Duration(seconds: 25);
  Duration verdictWindow = const Duration(seconds: 10);
  Duration hintCooldown = const Duration(seconds: 30);
  Duration beaconCooldown = const Duration(seconds: 60);

  static const int _maxEarlyTerminalStatuses = 8;

  void sync({
    required Iterable<String> peers,
    required bool foreground,
    required bool dark,
    required bool callActive,
  }) {
    if (_disposed) return;
    _peers = Set.unmodifiable(peers);
    _foreground = foreground;
    _dark = dark;
    _callActive = callActive;

    for (final peer in <String>{
      ..._messageIds.keys,
      ..._verdictTimers.keys,
      ..._probeTokens.keys,
      ..._earlyTerminalStatuses.keys,
      ..._sweepTimers.keys,
      ..._probing,
      ..._lastHints.keys,
    }.difference(_peers)) {
      forget(peer);
    }
    if (_dark || !_foreground || _callActive) {
      for (final peer in _peers) {
        cancelProbe(peer);
      }
    }
    _syncSweeps();
  }

  void forget(String peerId) {
    cancelProbe(peerId);
    _lastHints.remove(peerId);
    _sweepTimers.remove(peerId)?.cancel();
  }

  void cancelProbe(String peerId) {
    _messageIds.remove(peerId);
    _verdictTimers.remove(peerId)?.cancel();
    _probeTokens.remove(peerId);
    _earlyTerminalStatuses.remove(peerId);
    // The native send cannot be cancelled. Deliberately leave `_probing` set;
    // its finally block releases that reservation when the send returns.
  }

  /// Any authenticated peer evidence makes an outstanding verdict moot.
  void recordEvidence(String peerId) {
    cancelProbe(peerId);
    _syncSweeps();
  }

  /// Correlate only the daemon status belonging to this friend's current probe.
  bool handleMessageStatus(String peerId, String messageId, int state) {
    if (!_peers.contains(peerId) || messageId.isEmpty) {
      return false;
    }
    if (_messageIds[peerId] != messageId) {
      if (!_probing.contains(peerId) ||
          !_probeTokens.containsKey(peerId) ||
          (state != 3 && state != 4)) {
        return false;
      }
      final statuses = _earlyTerminalStatuses[peerId]!;
      statuses
        ..remove(messageId)
        ..[messageId] = state;
      while (statuses.length > _maxEarlyTerminalStatuses) {
        statuses.remove(statuses.keys.first);
      }
      return true;
    }
    _resolveMessageStatus(peerId, state);
    return true;
  }

  void _resolveMessageStatus(String peerId, int state) {
    if (state == 3) {
      cancelProbe(peerId);
      _onEvidence(peerId);
    } else if (state == 4) {
      cancelProbe(peerId);
      _onUnreachable(peerId);
    }
  }

  void hint(String peerId) {
    if (!_peers.contains(peerId)) return;
    final now = DateTime.now();
    final previous = _lastHints[peerId];
    if (previous != null && now.difference(previous) <= hintCooldown) return;
    _lastHints[peerId] = now;
    unawaited(refresh(peerId));
  }

  Future<void> refreshAll() async {
    await Future.wait(_peers.map(refresh));
  }

  Future<void> refresh(String peerId) async {
    if (_disposed ||
        !_peers.contains(peerId) ||
        _dark ||
        !_foreground ||
        _callActive ||
        _probing.contains(peerId) ||
        (_verdictTimers[peerId]?.isActive ?? false)) {
      return;
    }
    _probing.add(peerId);
    final token = Object();
    _probeTokens[peerId] = token;
    _earlyTerminalStatuses[peerId] = {};
    bool current() =>
        !_disposed &&
        _peers.contains(peerId) &&
        !_dark &&
        _foreground &&
        !_callActive &&
        identical(_probeTokens[peerId], token);
    void fail(String reason) {
      final previous = _presenceOf(peerId);
      cancelProbe(peerId);
      _onUnreachable(peerId);
      _log(reason);
      if (previous == PeerPresence.inApp ||
          previous == PeerPresence.reachable) {
        _beacon();
      }
    }

    // One deadline includes both the native send and the peer's reply.
    _verdictTimers[peerId] = Timer(verdictWindow, () {
      if (current()) {
        fail(
          'probe($peerId) verdict: no evidence in ${verdictWindow.inSeconds}s',
        );
      }
    });
    var nativePending = true;
    var reservationReleased = false;
    void releaseReservation() {
      if (reservationReleased) return;
      reservationReleased = true;
      _probing.remove(peerId);
    }

    Future<String> send() async {
      try {
        return await _probe(peerId);
      } finally {
        // A timeout cannot cancel native work. Keep its reservation until it
        // actually returns, so retries cannot accumulate native sends.
        nativePending = false;
        if (!current()) releaseReservation();
      }
    }

    try {
      late final String messageId;
      try {
        messageId = await send().timeout(verdictWindow);
      } catch (error) {
        if (current()) fail('→ probe($peerId) failed: $error');
        return;
      }
      // Gates first, then the refusal log: a probe that resolves after the
      // peer was forgotten (blocked) or the app went dark must not drop that
      // peer's id into the Diagnostics ring.
      if (!current()) return;
      if (messageId.isEmpty) {
        // A native "" (trust refusal / daemon 0-id) must be visible in Diagnostics — it is otherwise
        // indistinguishable from "never probed", and release logcat redacts the native side.
        fail('→ probe($peerId) sent NOTHING (native refusal or daemon 0)');
        return;
      }
      _log('→ probe($peerId) id=$messageId');
      final earlyState = _earlyTerminalStatuses.remove(peerId)?[messageId];
      _messageIds[peerId] = messageId;
      if (earlyState != null) {
        _resolveMessageStatus(peerId, earlyState);
        return;
      }
    } finally {
      if (!nativePending) releaseReservation();
    }
  }

  /// Best-effort foreground-state announcement. It is deliberately untracked: the app is leaving and no UI
  /// verdict should be armed. Only friends already proven alive receive it, avoiding persistent dead-peer queues.
  Future<void> announceBackground() async {
    if (_disposed || _dark || _callActive) return;
    await Future.wait(
      _peers
          .where((peer) {
            final presence = _presenceOf(peer);
            return presence == PeerPresence.inApp ||
                presence == PeerPresence.reachable;
          })
          .map(_probe),
    );
  }

  void _syncSweeps() {
    for (final peer in _sweepTimers.keys.toList(growable: false)) {
      final wanted =
          _peers.contains(peer) &&
          _foreground &&
          !_dark &&
          !_callActive &&
          _presenceOf(peer) == PeerPresence.inApp;
      if (!wanted) _sweepTimers.remove(peer)?.cancel();
    }
    if (!_foreground || _dark || _callActive) return;
    for (final peer in _peers) {
      if (_presenceOf(peer) == PeerPresence.inApp) {
        _sweepTimers[peer] ??= Timer.periodic(
          sweepEvery,
          (_) => unawaited(refresh(peer)),
        );
      }
    }
  }

  void _beacon() {
    final now = DateTime.now();
    if (_lastBeacon != null && now.difference(_lastBeacon!) < beaconCooldown) {
      return;
    }
    _lastBeacon = now;
    _log('→ connectivitySweep (zombie janitor)');
    unawaited(
      _connectivitySweep().catchError(
        (Object error) => _log('connectivitySweep failed: $error'),
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _verdictTimers.values) {
      timer.cancel();
    }
    for (final timer in _sweepTimers.values) {
      timer.cancel();
    }
    _messageIds.clear();
    _verdictTimers.clear();
    _probeTokens.clear();
    _earlyTerminalStatuses.clear();
    _probing.clear();
    _lastHints.clear();
    _sweepTimers.clear();
    _peers = const {};
  }
}
