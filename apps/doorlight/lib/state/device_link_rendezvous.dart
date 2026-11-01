import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'device_pairing.dart';
import 'nearby.dart';

enum DeviceLinkRendezvousRole { source, destination }

enum DeviceLinkRendezvousStatus { stopped, starting, ready, error, expired }

@immutable
final class DeviceLinkSourceHint {
  const DeviceLinkSourceHint({
    required this.token,
    required this.name,
    required this.lastSeen,
  });

  /// A one-visit routing token, never an account or trust identity.
  final String token;
  final String name;
  final DateTime lastSeen;
}

@immutable
final class DeviceLinkOfferCandidate {
  const DeviceLinkOfferCandidate({
    required this.nonce,
    required this.offer,
    required this.name,
    required this.receivedAt,
  });

  /// The offer remains untrusted until a user selects and approves it.
  final String nonce, offer, name;
  final DateTime receivedAt;

  @override
  String toString() => 'DeviceLinkOfferCandidate(<private>)';
}

/// Local, one-shot routing for the ordinary Jami device-link offer.
/// The token only addresses a visible source session; it never grants trust or
/// causes native pairing/approval. The injected transport owns UDP bounds and
/// platform multicast-lock ownership (use a dedicated port and shared lease).
final class DeviceLinkRendezvous extends ChangeNotifier {
  DeviceLinkRendezvous({
    required this.role,
    required this.transport,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _token = _randomToken();

  static const Duration lifetime = Duration(minutes: 5);
  static const Duration sourceHintLifetime = Duration(seconds: 6);
  static const Duration announceInterval = Duration(milliseconds: 1500);
  static const int maxPacketBytes = 512;
  static const int maxSources = 64;
  static const int maxCandidates = 8;
  static const int maxSeenNonces = 32;
  static final RegExp _tokenPattern = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _qrPattern = RegExp(
    r'^doorlight://link-local/([0-9a-f]{64})$',
  );

  final DeviceLinkRendezvousRole role;
  final NearbyTransport transport;
  final DateTime Function() _now;
  final String _token;
  final Map<String, DeviceLinkSourceHint> _sources = {};
  final Map<String, DeviceLinkOfferCandidate> _offers = {};
  final Set<String> _seenNonces = {};
  final List<String> _nonceOrder = [];
  StreamSubscription<NearbyDatagram>? _subscription;
  Future<void>? _stopFuture;
  Timer? _announceTimer;
  Timer? _expiryTimer;
  Timer? _staleTimer;
  DateTime? _expiresAt;
  DateTime? _visibleUntil;
  String? _selectedSourceToken;
  String? _selectedOfferNonce;
  DeviceLinkRendezvousStatus _status = DeviceLinkRendezvousStatus.stopped;
  String? _error;
  bool _closed = false;
  bool _disposed = false;
  bool _sentOffer = false;
  Future<void>? _startFuture;

  DeviceLinkRendezvousStatus get status => _status;
  String? get error => _error;
  bool get visible => role == DeviceLinkRendezvousRole.source && _activeSource;
  bool get _activeSource =>
      _isAlive && _visibleUntil != null && _now().isBefore(_visibleUntil!);
  bool get _isAlive =>
      !_closed &&
      (_expiresAt == null
          ? role == DeviceLinkRendezvousRole.source
          : _now().isBefore(_expiresAt!)) &&
      _status == DeviceLinkRendezvousStatus.ready;
  String? get qrText => visible ? 'doorlight://link-local/$_token' : null;
  String? get selectedSourceToken => _selectedSourceToken;
  DeviceLinkOfferCandidate? get selectedOffer {
    _prune();
    return _offers[_selectedOfferNonce];
  }

  List<DeviceLinkSourceHint> get sources {
    _prune();
    return List.unmodifiable(
      _sources.values.toList()
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen)),
    );
  }

  List<DeviceLinkOfferCandidate> get offers {
    _prune();
    return List.unmodifiable(_offers.values.toList());
  }

  static String? sourceTokenFromQr(String value) {
    final match = _qrPattern.firstMatch(value);
    return match?.group(1);
  }

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    if (_closed || _status != DeviceLinkRendezvousStatus.stopped) {
      return;
    }
    _status = DeviceLinkRendezvousStatus.starting;
    _error = null;
    notifyListeners();
    try {
      final stream = await transport.start();
      if (_closed) {
        _stopFuture ??= _stopTransport();
        await _stopFuture;
        return;
      }
      _subscription = stream.listen(_receive, onError: transportFailed);
      _expiresAt = _now().add(lifetime);
      _status = DeviceLinkRendezvousStatus.ready;
      final expiry = _expiresAt!;
      _expiryTimer = Timer(lifetime, () => _expire(expiry));
      _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_closed) return;
        final sourcesBefore = _sources.length;
        final offersBefore = _offers.length;
        _prune();
        if (sourcesBefore != _sources.length ||
            offersBefore != _offers.length) {
          notifyListeners();
        }
      });
    } on Object {
      _fail('Could not start local device linking. Check Wi-Fi and try again.');
      _stopFuture ??= _stopTransport();
      await _stopFuture;
    }
    if (!_closed) notifyListeners();
  }

  /// Explicitly reveals this source for one bounded visit.
  bool reveal(String name) {
    if (role != DeviceLinkRendezvousRole.source || !_isAlive) return false;
    final cleanName = _name(name);
    if (cleanName == null) return false;
    _visibleUntil = _expiresAt;
    _sendSource(cleanName);
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(announceInterval, (_) {
      if (!_activeSource) {
        _stopAnnouncing();
      } else {
        _sendSource(cleanName);
      }
    });
    notifyListeners();
    return true;
  }

  /// Stops advertising. Existing offer candidates remain visible until expiry.
  Future<void> hide() async {
    if (!visible) return;
    final packet = _encode({'v': 1, 'type': 'bye', 'token': _token});
    if (packet != null) {
      try {
        await transport.send(packet);
      } on Object {
        _stopAnnouncing();
        _error = 'Could not stop local discovery cleanly.';
      }
    }
    _stopAnnouncing();
    if (!_closed) notifyListeners();
  }

  /// Selects the exact QR/hint token to route one ordinary native offer to.
  /// Selection has no trust or native side effect.
  bool selectSource(String token) {
    if (role != DeviceLinkRendezvousRole.destination ||
        !_isAlive ||
        !_tokenPattern.hasMatch(token)) {
      return false;
    }
    _selectedSourceToken = token;
    notifyListeners();
    return true;
  }

  bool selectOffer(String nonce) {
    if (role != DeviceLinkRendezvousRole.source || !_isAlive) return false;
    _prune();
    if (!_offers.containsKey(nonce)) return false;
    _selectedOfferNonce = nonce;
    notifyListeners();
    return true;
  }

  /// Broadcasts a published native offer to the selected source. Delivery is
  /// only a hint: the source must select and explicitly authorize it in-app.
  Future<bool> sendOffer({required String offer, required String name}) async {
    final targetToken = _selectedSourceToken;
    if (role != DeviceLinkRendezvousRole.destination ||
        !_isAlive ||
        targetToken == null ||
        _sentOffer ||
        !DevicePairingSnapshot.validOffer(offer)) {
      return false;
    }
    final cleanName = _name(name);
    if (cleanName == null) return false;
    final packet = _encode({
      'v': 1,
      'type': 'offer',
      'token': targetToken,
      'nonce': _randomToken(),
      'offer': offer,
      'name': cleanName,
    });
    if (packet == null) return false;
    // A send exception cannot prove that no datagram escaped. Do not replay
    // an uncertain local offer from this visit.
    _sentOffer = true;
    try {
      await transport.send(packet);
      return true;
    } on Object {
      _error =
          'Could not confirm the link request. Start a fresh attempt after checking Wi-Fi.';
      notifyListeners();
      return false;
    }
  }

  Future<void> close() async {
    if (_closed) {
      await _stopFuture;
      return;
    }
    _closed = true;
    _announceTimer?.cancel();
    _announceTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    await _startFuture;
    await _subscription?.cancel();
    _subscription = null;
    _sources.clear();
    _offers.clear();
    _seenNonces.clear();
    _nonceOrder.clear();
    _selectedSourceToken = null;
    _selectedOfferNonce = null;
    _visibleUntil = null;
    _expiresAt = null;
    _status = DeviceLinkRendezvousStatus.stopped;
    _stopFuture ??= _stopTransport();
    await _stopFuture;
    _status = DeviceLinkRendezvousStatus.stopped;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }

  void _receive(NearbyDatagram datagram) {
    if (!_isAlive || datagram.data.length > maxPacketBytes) return;
    final packet = _decode(datagram.data);
    if (packet == null) return;
    final type = packet['type'];
    final token = packet['token'] as String;
    if (type == 'source' && role == DeviceLinkRendezvousRole.destination) {
      if (token == _selectedSourceToken) return;
      final name = _name(packet['name'] as String);
      if (name == null) return;
      _prune();
      if (!_sources.containsKey(token) && _sources.length >= maxSources) {
        return;
      }
      _sources[token] = DeviceLinkSourceHint(
        token: token,
        name: name,
        lastSeen: _now(),
      );
      notifyListeners();
    } else if (type == 'bye' && role == DeviceLinkRendezvousRole.destination) {
      if (_sources.remove(token) != null) notifyListeners();
      if (_selectedSourceToken == token) _selectedSourceToken = null;
    } else if (type == 'offer' &&
        role == DeviceLinkRendezvousRole.source &&
        token == _token &&
        _activeSource) {
      final nonce = packet['nonce'] as String;
      final offer = packet['offer'] as String;
      final name = _name(packet['name'] as String);
      if (name == null || _seenNonces.contains(nonce)) return;
      _prune();
      if (_offers.length >= maxCandidates) return;
      _seenNonces.add(nonce);
      _nonceOrder.add(nonce);
      if (_nonceOrder.length > maxSeenNonces) {
        _seenNonces.remove(_nonceOrder.removeAt(0));
      }
      _offers[nonce] = DeviceLinkOfferCandidate(
        nonce: nonce,
        offer: offer,
        name: name,
        receivedAt: _now(),
      );
      notifyListeners();
    }
  }

  void _sendSource(String name) {
    final packet = _encode({
      'v': 1,
      'type': 'source',
      'token': _token,
      'name': name,
    });
    if (packet != null) {
      unawaited(
        transport.send(packet).catchError((Object _) {
          _stopAnnouncing();
          _error = 'Local discovery is unavailable. Check Wi-Fi and try again.';
          if (!_closed) notifyListeners();
        }),
      );
    }
  }

  void transportFailed(Object _) {
    _fail('Local device linking stopped. Check Wi-Fi and try again.');
    unawaited(_subscription?.cancel());
    _subscription = null;
    _stopFuture ??= _stopTransport();
  }

  Future<void> _stopTransport() async {
    try {
      await transport.stop();
    } on Object {
      _error =
          'The local network socket could not be released. Close linking and retry.';
      if (!_disposed) notifyListeners();
    }
  }

  void _fail(String message) {
    _error = message;
    _status = DeviceLinkRendezvousStatus.error;
    _stopAnnouncing();
    _sources.clear();
    _offers.clear();
    if (!_closed) notifyListeners();
  }

  void _stopAnnouncing() {
    _announceTimer?.cancel();
    _announceTimer = null;
    _visibleUntil = null;
  }

  void _expire(DateTime expiry) {
    if (_closed || _expiresAt != expiry || _now().isBefore(expiry)) return;
    _closed = true;
    _stopAnnouncing();
    _sources.clear();
    _offers.clear();
    _seenNonces.clear();
    _nonceOrder.clear();
    _selectedSourceToken = null;
    _selectedOfferNonce = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    _status = DeviceLinkRendezvousStatus.expired;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _stopFuture ??= _stopTransport();
    if (!_disposed) notifyListeners();
  }

  void _prune() {
    final now = _now();
    _sources.removeWhere(
      (_, value) => now.difference(value.lastSeen) >= sourceHintLifetime,
    );
    _offers.removeWhere(
      (_, value) => now.difference(value.receivedAt) >= lifetime,
    );
    if (_selectedOfferNonce != null &&
        !_offers.containsKey(_selectedOfferNonce)) {
      _selectedOfferNonce = null;
    }
  }

  static Uint8List? _encode(Map<String, Object> value) {
    final bytes = utf8.encode(jsonEncode(value));
    return bytes.isEmpty || bytes.length > maxPacketBytes
        ? null
        : Uint8List.fromList(bytes);
  }

  static Map<String, Object>? _decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxPacketBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> ||
          value['v'] is! int ||
          value['v'] != 1) {
        return null;
      }
      final type = value['type'];
      final token = value['token'];
      if (type is! String ||
          token is! String ||
          !_tokenPattern.hasMatch(token)) {
        return null;
      }
      final expectedKeys = switch (type) {
        'source' => const {'v', 'type', 'token', 'name'},
        'bye' => const {'v', 'type', 'token'},
        'offer' => const {'v', 'type', 'token', 'nonce', 'offer', 'name'},
        _ => null,
      };
      if (expectedKeys == null ||
          value.length != expectedKeys.length ||
          !value.keys.toSet().containsAll(expectedKeys)) {
        return null;
      }
      if (type == 'source') {
        if (value['name'] is! String ||
            _name(value['name'] as String) == null) {
          return null;
        }
      } else if (type == 'offer') {
        final nonce = value['nonce'];
        final offer = value['offer'];
        final name = value['name'];
        if (nonce is! String ||
            !_tokenPattern.hasMatch(nonce) ||
            offer is! String ||
            !DevicePairingSnapshot.validOffer(offer) ||
            name is! String ||
            _name(name) == null) {
          return null;
        }
      }
      return Map<String, Object>.from(value);
    } on Object {
      return null;
    }
  }

  static String? _name(String value) {
    if (value.runes.length > NearbyProtocol.maxNameChars ||
        utf8.encode(value).length > 256) {
      return null;
    }
    final clean = NearbyProtocol.sanitizeName(value);
    return clean.isEmpty ? null : clean;
  }

  static String _randomToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
