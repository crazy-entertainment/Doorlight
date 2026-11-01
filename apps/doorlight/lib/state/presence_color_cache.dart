import 'dart:async';

import 'identity_color.dart';

/// Best-effort cosmetic persistence. Peer traffic must not create an unbounded
/// platform write queue. Live presence is independent of this cache.
class PresenceColorCache {
  PresenceColorCache({
    required this.write,
    required this.remove,
    required this.onError,
  });

  static const maxPendingPeers = 64;
  static const writeInterval = Duration(seconds: 1);
  final Future<void> Function(String peer, IdentityColor color) write;
  final Future<void> Function(String peer) remove;
  final void Function(Object error, StackTrace stack) onError;
  final _pending = <String, IdentityColor>{};
  final _retirements = <String, Future<void>>{};
  Timer? _cooldown;
  Future<void>? _inFlight;
  String? _writingPeer;
  bool _disposed = false;

  void update(String peer, IdentityColor color) {
    if (_disposed ||
        (!_pending.containsKey(peer) && _pending.length >= maxPendingPeers)) {
      return;
    }
    _pending[peer] = color;
    _drain();
  }

  void _drain() {
    if (_disposed ||
        _cooldown != null ||
        _inFlight != null ||
        _pending.isEmpty) {
      return;
    }
    final available = _pending.keys.where(
      (peer) => !_retirements.containsKey(peer),
    );
    if (available.isEmpty) return;
    final peer = available.first;
    final color = _pending.remove(peer)!;
    _writingPeer = peer;
    _cooldown = Timer(writeInterval, () {
      _cooldown = null;
      _drain();
    });
    _inFlight = Future<void>.sync(() => write(peer, color))
        .catchError((Object error, StackTrace stack) => onError(error, stack))
        .whenComplete(() {
          _inFlight = null;
          _writingPeer = null;
          _drain();
        });
  }

  bool isRetiring(String peer) => _retirements.containsKey(peer);

  /// Retire the old relationship's storage after its submitted write. Updates
  /// for a newly added relationship wait until the removal barrier completes.
  Future<void> forget(String peer) {
    _pending.remove(peer);
    final existing = _retirements[peer];
    if (existing != null) return existing;
    final retiring = _forget(peer);
    _retirements[peer] = retiring;
    return retiring;
  }

  Future<void> _forget(String peer) async {
    try {
      if (_writingPeer == peer) await _inFlight;
      await remove(peer);
    } finally {
      _retirements.remove(peer);
      _drain();
    }
  }

  void dispose() {
    _disposed = true;
    _cooldown?.cancel();
    _pending.clear();
  }
}
