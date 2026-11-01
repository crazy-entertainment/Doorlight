import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/jami.dart';
import 'nearby_protocol.dart';
import 'sonar_combat.dart';

export 'nearby_protocol.dart';
export 'sonar_combat.dart';

typedef NearbyDatagram = ({Uint8List data, Object sender});

/// Admission happens before decoding or asynchronous delivery. UDP source
/// addresses are unauthenticated, so both source and aggregate budgets apply.
/// The explicit queue also bounds retention before listening and while paused.
final class NearbyIngress {
  NearbyIngress({Duration Function()? now}) {
    final clock = Stopwatch()..start();
    _now = now ?? (() => clock.elapsed);
    _total = _IngressBudget(totalBurst, _now());
    _events = StreamController<NearbyDatagram>(
      sync: true,
      onListen: _schedule,
      onPause: _cancelFlush,
      onResume: _schedule,
      onCancel: _discard,
    );
  }

  static const int maxQueued = 128;
  static const int maxSources = 256;
  static const int totalBurst = 256;
  static const int totalPerSecond = 128;
  static const int sourceBurst = 8;
  static const int sourcePerSecond = 4;
  static const int batchSize = 32;
  static const Duration batchTime = Duration(milliseconds: 2);

  late final Duration Function() _now;
  late final _IngressBudget _total;
  late final StreamController<NearbyDatagram> _events;
  final ListQueue<NearbyDatagram> _queue = ListQueue();
  final Map<String, _IngressBudget> _sources = {};
  Timer? _flush;
  Object? _error;
  bool _closed = false;
  bool _cancelled = false;

  Stream<NearbyDatagram> get stream => _events.stream;

  bool add(NearbyDatagram datagram) {
    if (_closed || _cancelled) return false;
    final now = _now();
    final source = switch (datagram.sender) {
      InternetAddress(:final address) => 'udp:$address',
      String value => 'radio:$value',
      _ => '',
    };
    if (source.isEmpty || source.length > 128) return false;
    var budget = _sources[source];
    if (budget == null) {
      // Retire only fully replenished sources, never evict an active limiter
      // to let address churn reset its allowance.
      if (_sources.length >= maxSources) {
        _sources.removeWhere(
          (_, value) => now - value.last >= const Duration(seconds: 2),
        );
      }
      if (_sources.length >= maxSources) return false;
      budget = _IngressBudget(sourceBurst, now);
      _sources[source] = budget;
    }
    if (!budget.take(now, sourceBurst, sourcePerSecond)) return false;
    if (!_total.take(now, totalBurst, totalPerSecond)) return false;
    if (datagram.data.isEmpty ||
        datagram.data.length > NearbyProtocol.maxDatagramBytes ||
        _queue.length >= maxQueued) {
      return false;
    }
    _queue.add(datagram);
    _schedule();
    return true;
  }

  void addError(Object error) {
    if (_closed || _cancelled) return;
    _error ??= error;
    _schedule();
  }

  void _schedule() {
    if (_closed ||
        _cancelled ||
        _flush != null ||
        !_events.hasListener ||
        _events.isPaused ||
        (_queue.isEmpty && _error == null)) {
      return;
    }
    _flush = Timer(Duration.zero, _drain);
  }

  void _drain() {
    _flush = null;
    final work = Stopwatch()..start();
    var count = 0;
    while (!_closed &&
        !_cancelled &&
        !_events.isPaused &&
        _queue.isNotEmpty &&
        count < batchSize &&
        work.elapsed < batchTime) {
      count++;
      _events.add(_queue.removeFirst());
    }
    if (!_closed && !_cancelled && !_events.isPaused && _error != null) {
      final error = _error!;
      _error = null;
      _events.addError(error);
    }
    _schedule();
  }

  void _cancelFlush() {
    _flush?.cancel();
    _flush = null;
  }

  void _discard() {
    _cancelled = true;
    _cancelFlush();
    _queue.clear();
    _sources.clear();
    _error = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _discard();
    // A consumer may stop Nearby from inside a synchronous data callback.
    scheduleMicrotask(() => unawaited(_events.close()));
  }
}

final class _IngressBudget {
  _IngressBudget(int burst, this.last) : tokens = burst.toDouble();

  Duration last;
  double tokens;

  bool take(Duration now, int burst, int perSecond) {
    final elapsed = now - last;
    if (elapsed > Duration.zero) {
      tokens = (tokens + elapsed.inMicroseconds * perSecond / 1000000).clamp(
        0,
        burst.toDouble(),
      );
      last = now;
    }
    if (tokens < 1) return false;
    tokens--;
    return true;
  }
}

/// Datagram carrier for Nearby. [start] throws when the socket cannot be
/// bound; [NearbyController] turns that into [NearbyStatus.error].
abstract interface class NearbyTransport {
  Future<Stream<NearbyDatagram>> start();
  Future<void> send(Uint8List data);
  Future<void> stop();
}

/// UDP multicast transport on [NearbyProtocol.group]. On Android the Wi-Fi
/// multicast lock is held while started; otherwise the radio filters the
/// group's packets.
final class UdpNearbyTransport implements NearbyTransport {
  UdpNearbyTransport({
    this.acquireMulticastLock,
    this.releaseMulticastLock,
    this.port = NearbyProtocol.port,
    this.broadcast = false,
    @visibleForTesting this.bindSocket = RawDatagramSocket.bind,
  });

  factory UdpNearbyTransport.forPlatform(
    JamiClient client, {
    int port = NearbyProtocol.port,
    bool broadcast = false,
  }) => defaultTargetPlatform == TargetPlatform.android
      ? UdpNearbyTransport(
          port: port,
          broadcast: broadcast,
          acquireMulticastLock: client.acquireMulticastLock,
          releaseMulticastLock: client.releaseMulticastLock,
        )
      : UdpNearbyTransport(port: port, broadcast: broadcast);

  final Future<bool> Function()? acquireMulticastLock;
  final Future<void> Function()? releaseMulticastLock;
  final int port;
  final bool broadcast;
  final Future<RawDatagramSocket> Function(
    dynamic host,
    int port, {
    bool reuseAddress,
    bool reusePort,
    int ttl,
  })
  bindSocket;

  static final InternetAddress _group = InternetAddress(NearbyProtocol.group);

  bool _ownsPlatformLock = false;
  RawDatagramSocket? _socket;
  NearbyIngress? _datagrams;
  Timer? _readResume;
  bool _joined = false;
  bool _broadcastReady = false;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    if (_socket != null) await stop();
    _ownsPlatformLock = await _platformLock(acquireMulticastLock) == true;
    final RawDatagramSocket socket;
    RawDatagramSocket? opening;
    try {
      opening = socket = await _bind();
      socket.multicastLoopback = false;
      // Limited broadcast works with any subnet mask, unlike guessing .255.
      if (broadcast) {
        try {
          socket.broadcastEnabled = true;
          _broadcastReady = true;
        } on SocketException {
          // A blocked broadcast path must not disable multicast.
        }
      }
      _joined = await _joinGroup(socket);
      if (!_joined && !_broadcastReady) {
        throw const SocketException('Nearby could not join the LAN group');
      }
    } catch (_) {
      opening?.close();
      _joined = false;
      _broadcastReady = false;
      if (_ownsPlatformLock) {
        _ownsPlatformLock = false;
        await _platformLock(releaseMulticastLock);
      }
      rethrow;
    }
    final datagrams = NearbyIngress();
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final work = Stopwatch()..start();
        var count = 0;
        while (count < NearbyIngress.batchSize &&
            work.elapsed < NearbyIngress.batchTime) {
          final d = socket.receive();
          if (d == null) return;
          count++;
          datagrams.add((data: d.data, sender: d.address));
        }
        // Leave excess packets in the OS's bounded receive buffer. Even an
        // all-rejected flood must yield instead of draining in a tight loop.
        socket.readEventsEnabled = false;
        _readResume = Timer(const Duration(milliseconds: 10), () {
          _readResume = null;
          if (identical(_socket, socket)) socket.readEventsEnabled = true;
        });
      },
      onError: datagrams.addError,
      onDone: datagrams.close,
    );
    _socket = socket;
    _datagrams = datagrams;
    return datagrams.stream;
  }

  @override
  Future<void> send(Uint8List data) async {
    final socket = _socket;
    if (socket == null) throw StateError('Nearby UDP transport is stopped');
    Object? failure;
    var sent = false;
    for (final destination in [
      if (_joined) _group,
      if (_broadcastReady) InternetAddress('255.255.255.255'),
    ]) {
      try {
        sent = socket.send(data, destination, port) == data.length || sent;
      } on SocketException catch (error) {
        failure = error;
      }
    }
    if (!sent) throw failure ?? StateError('Nearby UDP send was rejected');
  }

  @override
  Future<void> stop() async {
    final socket = _socket;
    final datagrams = _datagrams;
    _socket = null;
    _joined = false;
    _broadcastReady = false;
    _datagrams = null;
    _readResume?.cancel();
    _readResume = null;
    if (socket == null) return;
    socket.close();
    datagrams?.close();
    if (_ownsPlatformLock) {
      _ownsPlatformLock = false;
      await _platformLock(releaseMulticastLock);
    }
  }

  Future<RawDatagramSocket> _bind() async {
    // SO_REUSEPORT lets a second Doorlight instance share the port where the OS supports it; Windows does not.
    if (!Platform.isWindows) {
      try {
        return await bindSocket(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
          reusePort: true,
        );
      } on Object {
        // Fall through to a plain reuseAddress bind.
      }
    }
    return bindSocket(InternetAddress.anyIPv4, port, reuseAddress: true);
  }

  /// Best effort on every IPv4 interface; one failing adapter (VPN, virtual
  /// switch) must not prevent discovery on the others.
  Future<bool> _joinGroup(RawDatagramSocket socket) async {
    var joined = false;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        try {
          socket.joinMulticast(_group, interface);
          joined = true;
        } on Object {
          // Ignore this interface.
        }
      }
    } on Object {
      // Fall back to the OS default interface below.
    }
    if (joined) return true;
    try {
      socket.joinMulticast(_group);
      return true;
    } on Object {
      return false;
    }
  }

  static Future<Object?> _platformLock(Future<Object?> Function()? call) async {
    if (call == null) return null;
    try {
      return await call();
    } on MissingPluginException {
      // Host without the native bridge (tests, Windows).
    } on PlatformException {
      // Discovery still works on networks that do not filter multicast.
    }
    return null;
  }
}

enum NearbyStatus { stopped, starting, listening, error }

@immutable
final class NearbyPeer {
  const NearbyPeer({
    required this.id,
    required this.name,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final DateTime lastSeen;
}

/// Doorlight's Nearby state machine.
///
/// Listening is passive and sends nothing. The device announces itself only
/// inside an explicit [goVisible] window, then sends a bye and stops on its
/// own. An unseen peer appearing while this device is not visible never makes
/// it visible; it raises [pendingWave] and a rate-limited [sonarReceived].
/// A peer's deliberate ping (reveal or tap) always raises [sonarReceived] and
/// [pendingWave], visible or not: it is a notification, not a discovery.
/// While Sonar is on screen ([watching]) nothing raises [pendingWave]: the
/// stage itself shows every arrival and ping.
///
/// Sonar combat: [aim] charges a missile at a person for
/// [SonarCombat.chargeWindow], then sends it once. A missile only ever
/// shortens the receiver's own visibility window; it is unauthenticated,
/// bounded and rate limited, and ignored unless aimed at this visible,
/// intact device. A hit that empties the window ends visibility and blocks a
/// new reveal for [SonarCombat.rearm]; nothing re-announces on its own.
class NearbyController extends ChangeNotifier {
  NearbyController({
    required this._transport,
    this._ownId = '',
    this._ownName = '',
    DateTime Function()? now,
    math.Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? math.Random();

  static const Duration defaultVisibleWindow = Duration(minutes: 5);
  static const Duration announceInterval = Duration(milliseconds: 1500);
  static const Duration peerTimeout = Duration(seconds: 6);
  static const Duration sonarRecency = Duration(minutes: 5);
  static const Duration sonarCooldown = Duration(seconds: 60);

  /// Bounds what a hostile LAN can make this controller remember.
  static const int maxPeers = 64;
  static const int maxRemembered = 1024;

  final NearbyTransport _transport;
  final DateTime Function() _now;
  final math.Random _random;
  String _ownId;
  String _ownName;

  NearbyStatus _status = NearbyStatus.stopped;
  Object? _error;
  StreamSubscription<NearbyDatagram>? _subscription;
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;

  DateTime? _visibleUntil;
  int _visibilityGeneration = 0;
  Timer? _announceTimer;
  Timer? _windowTimer;

  final Map<String, NearbyPeer> _peers = {};
  final Map<String, Timer> _expiry = {};
  final Map<String, DateTime> _lastHeard = {};
  DateTime? _lastSonar;
  DateTime? _lastPing;
  bool _pendingWave = false;
  final StreamController<String> _sonar = StreamController.broadcast();
  final StreamController<void> _announced = StreamController.broadcast();
  final StreamController<SonarEvent> _combat = StreamController.broadcast();

  String? _chargeTarget;
  int _chargeTaps = 0;
  Timer? _chargeTimer;
  ({String target, int level, String nonce, DateTime end})? _outgoing;
  Timer? _collisionTimer;
  bool _manuallyOff = false;
  bool _launching = false;
  Timer? _outgoingTimer;
  DateTime? _targetGoneAt;
  ({String target, DateTime until})? _sinkWatch;
  final List<_Incoming> _incoming = [];
  final Map<String, DateTime> _lastMissileFrom = {};
  final Map<String, DateTime> _missileNonces = {};
  DateTime? _rearmAt;
  Timer? _rearmTimer;
  ({DateTime at, Duration lost})? _lastHit;
  final Map<String, DateTime> _firedAt = {};
  final Map<String, DateTime> _firedBy = {};
  bool _ambience = false;
  Timer? _ambienceTimer;

  NearbyStatus get status => _status;
  bool get listening => _status == NearbyStatus.listening;
  Object? get error => _error;
  String? _sendError;
  String? get sendError => _sendError;
  bool get visible => _visibleUntil != null;
  DateTime? get visibleUntil => _visibleUntil;
  bool get pendingWave => _pendingWave;
  Stream<String> get sonarReceived => _sonar.stream;

  int _watchers = 0;
  bool get watching => _watchers > 0;

  /// Sonar opened: acknowledges the pending wave and keeps it down until
  /// [unwatch].
  void watch() {
    _watchers++;
    clearPendingWave();
    _syncAmbience();
  }

  void unwatch() {
    if (_watchers > 0) _watchers--;
    // A charge belongs to the Sonar it was started on: closing Sonar drops
    // it, so nothing fires (and reveals you) once it is gone.
    if (!watching && _chargeTarget != null) {
      _cancelCharge();
      if (!_disposed) notifyListeners();
    }
    _syncAmbience();
  }

  /// Combat cues for the stage and the sound bank.
  Stream<SonarEvent> get combat => _combat.stream;

  /// The person a missile is charging at, and the taps so far.
  String? get chargeTarget => _chargeTarget;
  int get chargeTaps => _chargeTaps;
  bool get missileInFlight => _outgoing != null || _launching;

  /// Missiles on their way to you.
  int get incoming => _incoming.length;
  bool get incomingClose => _incoming.any((shot) => !shot._close.isActive);

  /// A missile ended visibility; reveal stays blocked until [rearmAt].
  bool get destroyed => _rearmAt != null;
  DateTime? get rearmAt => _rearmAt;

  /// The latest hit on you and the time it actually took.
  ({DateTime at, Duration lost})? get lastHit => _lastHit;

  /// Plays while you and someone traded fire recently and Sonar is open.
  bool get ambience => _ambience;

  /// One event per announcement actually handed to the transport.
  Stream<void> get announced => _announced.stream;

  /// Discovered peers, most recently heard first. Never includes [ownId].
  List<NearbyPeer> get peers =>
      _peers.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  String get ownId => _ownId;
  set ownId(String value) {
    if (value == _ownId) return;
    if (visible) endVisible();
    _ownId = value;
    _removePeer(value);
  }

  set ownName(String value) => _ownName = value;

  Future<void> start() => _enqueue(_start);
  Future<void> stop() => _enqueue(_stop);

  /// Announces immediately, then every [announceInterval] until [window]
  /// elapses, then sends a bye. Returns false when not listening or without an
  /// own id. Calling again while visible restarts the window.
  bool goVisible({Duration window = defaultVisibleWindow}) {
    if (_disposed ||
        !listening ||
        _ownId.isEmpty ||
        destroyed ||
        window <= Duration.zero) {
      return false;
    }
    _cancelVisibilityTimers();
    _sendError = null;
    _manuallyOff = false;
    _visibleUntil = _now().add(window);
    _announce(ping: true);
    _announceTimer = Timer.periodic(announceInterval, (_) {
      final until = _visibleUntil;
      if (until == null || !_now().isBefore(until)) {
        endVisible();
      } else {
        _announce();
      }
    });
    _windowTimer = Timer(window, endVisible);
    notifyListeners();
    return true;
  }

  /// Minimum gap between manual pulses, so tapping can't flood the LAN.
  static const Duration pulseCooldown = Duration(seconds: 1);
  DateTime? _lastPulse;

  /// Sends one extra announcement while visible; false when hidden or within
  /// [pulseCooldown] of the previous pulse.
  bool pulse() {
    if (_disposed || !visible) return false;
    final now = _now();
    final last = _lastPulse;
    if (last != null && now.difference(last) < pulseCooldown) return false;
    _lastPulse = now;
    _announce(ping: true);
    return true;
  }

  void shutdown() {
    if (!visible) return;
    _manuallyOff = true;
    _cancelCharge();
    _cue(const SonarEvent(SonarCue.shutdown));
    endVisible(keepIncoming: true);
  }

  void endVisible({bool keepIncoming = false}) {
    if (!visible) return;
    _visibilityGeneration++;
    _launching = false;
    _cancelVisibilityTimers();
    if (!keepIncoming) _clearIncoming();
    _visibleUntil = null;
    final bye = NearbyProtocol.encodeBye(_ownId);
    if (bye != null) {
      unawaited(
        _send(bye).then((sent) {
          if (!sent) _recordSendFailure();
        }),
      );
    }
    if (!_disposed) notifyListeners();
  }

  /// Starts charging a missile at [target], or counts one more tap on the
  /// target already charging. Needs a listening device with an id, a target
  /// currently heard, no other charge or missile of yours in flight, and an
  /// intact sonar. Returns whether the tap counted.
  bool aim(String target) {
    if (_disposed) return false;
    if (_chargeTarget != null) {
      if (_chargeTarget != target) return false;
      _chargeTaps++;
      _cue(SonarEvent(SonarCue.charge, peer: target, step: _chargeTaps));
      notifyListeners();
      return true;
    }
    if (!listening ||
        _ownId.isEmpty ||
        target == _ownId ||
        !_peers.containsKey(target) ||
        _outgoing != null ||
        _launching ||
        destroyed) {
      return false;
    }
    _chargeTarget = target;
    _chargeTaps = 1;
    _chargeTimer = Timer(SonarCombat.chargeWindow, _launch);
    _cue(SonarEvent(SonarCue.charge, peer: target, step: 1));
    notifyListeners();
    return true;
  }

  void _launch() {
    unawaited(_launchMissile());
  }

  Future<void> _launchMissile() async {
    final target = _chargeTarget;
    final taps = _chargeTaps;
    _cancelCharge();
    if (target == null || _disposed) return;
    final level = SonarCombat.level(taps);
    final nonce = List.generate(
      8,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final packet = NearbyProtocol.encodeMissile(
      _ownId,
      target,
      SonarCombat.roll(level, _random),
      level,
      nonce: nonce,
    );
    if (packet == null ||
        !listening ||
        destroyed ||
        !_peers.containsKey(target)) {
      notifyListeners();
      return;
    }
    // Firing while hidden is itself an explicit, short reveal.
    if (!visible && !goVisible(window: SonarCombat.fireReveal)) return;
    final generation = _visibilityGeneration;
    _launching = true;
    _sendError = null;
    notifyListeners();
    final sent = await _send(packet);
    if (_disposed ||
        generation != _visibilityGeneration ||
        !listening ||
        !visible ||
        destroyed) {
      return;
    }
    _launching = false;
    if (!sent) {
      _recordSendFailure();
      return;
    }
    _outgoing = (
      target: target,
      level: level,
      nonce: nonce,
      end: _now().add(SonarCombat.flight(level)),
    );
    _targetGoneAt = null;
    _sinkWatch = null;
    _outgoingTimer = SonarCombat.losesTarget(nonce, level)
        ? Timer(SonarCombat.flight(level) * .45, _loseOutgoing)
        : Timer(SonarCombat.flight(level), _impact);
    _firedAt[target] = _now();
    _cue(SonarEvent(SonarCue.launched, peer: target, level: level));
    _checkCollision();
    _syncAmbience();
    notifyListeners();
  }

  void _impact() {
    final out = _outgoing;
    _outgoing = null;
    _outgoingTimer = null;
    if (out == null || _disposed) return;
    final now = _now();
    _cue(SonarEvent(SonarCue.impact, peer: out.target, level: out.level));
    // Nobody tells a shooter a hit was lethal; the target going dark right
    // around the impact is the honest hint.
    final gone = _targetGoneAt;
    if (gone != null && now.difference(gone) <= const Duration(seconds: 1)) {
      _cue(SonarEvent(SonarCue.sunk, peer: out.target));
    } else {
      _sinkWatch = (target: out.target, until: now.add(SonarCombat.sunkWindow));
    }
    notifyListeners();
  }

  void _loseOutgoing() {
    final out = _outgoing;
    if (out == null || _disposed) return;
    _outgoing = null;
    _outgoingTimer = null;
    _cue(SonarEvent(SonarCue.targetLost, peer: out.target, level: out.level));
    notifyListeners();
  }

  void _checkCollision() {
    final out = _outgoing;
    if (out == null ||
        _collisionTimer != null ||
        SonarCombat.losesTarget(out.nonce, out.level)) {
      return;
    }
    final shot = _incoming
        .where(
          (s) =>
              s.from == out.target &&
              s.nonce != null &&
              !SonarCombat.losesTarget(s.nonce, s.level),
        )
        .firstOrNull;
    if (shot == null ||
        !SonarCombat.collide(out.nonce, out.level, shot.nonce!, shot.level)) {
      return;
    }
    final remaining = out.end.difference(_now());
    if (remaining <= SonarCombat.prefire) return;
    _collisionTimer = Timer(remaining * .35, () {
      _collisionTimer = null;
      if (_disposed ||
          _outgoing?.nonce != out.nonce ||
          !_incoming.remove(shot)) {
        return;
      }
      shot.cancel();
      _outgoingTimer?.cancel();
      _outgoingTimer = null;
      _outgoing = null;
      _cue(SonarEvent(SonarCue.collision, peer: out.target));
      notifyListeners();
    });
  }

  /// A person left the stage; they may be the target of your missile.
  void _gone(String id) {
    if (_outgoing?.target == id) _targetGoneAt = _now();
    final watch = _sinkWatch;
    if (watch == null || watch.target != id) return;
    _sinkWatch = null;
    if (_now().isBefore(watch.until)) {
      _cue(SonarEvent(SonarCue.sunk, peer: id));
    }
  }

  void _onMissile(NearbyMissile missile) {
    if (missile.at != _ownId || !visible || destroyed) return;
    final now = _now();
    // One shot can arrive over several carriers with different latencies.
    if (missile.nonce case final nonce?) {
      _missileNonces.removeWhere(
        (_, at) => now.difference(at) >= const Duration(minutes: 1),
      );
      final key = '${missile.id}:$nonce';
      if (_missileNonces.containsKey(key) ||
          _missileNonces.length >= maxRemembered) {
        return;
      }
      _missileNonces[key] = now;
    }
    final last = _lastMissileFrom[missile.id];
    if (last != null && now.difference(last) < SonarCombat.shooterSpacing) {
      return;
    }
    if (_incoming.length >= SonarCombat.maxIncoming) return;
    _lastMissileFrom.removeWhere(
      (_, at) => now.difference(at) >= SonarCombat.shooterSpacing,
    );
    if (_lastMissileFrom.length >= maxRemembered) return;
    _lastMissileFrom[missile.id] = now;
    final flight = SonarCombat.flight(missile.level);
    late final _Incoming shot;
    shot = _Incoming(
      missile.id,
      missile.permille.clamp(
        NearbyProtocol.minMissile,
        NearbyProtocol.maxMissile,
      ),
      Timer(
        SonarCombat.losesTarget(missile.nonce, missile.level)
            ? flight * .45
            : flight,
        () {
          if (SonarCombat.losesTarget(missile.nonce, missile.level)) {
            if (!_incoming.remove(shot)) return;
            shot.cancel();
            _cue(
              SonarEvent(
                SonarCue.targetLost,
                peer: missile.id,
                level: missile.level,
                inbound: true,
              ),
            );
            notifyListeners();
          } else {
            _landIncoming(shot);
          }
        },
      ),
      Timer(flight - SonarCombat.closeWarning, () {
        _cue(SonarEvent(SonarCue.incomingClose, peer: missile.id));
      }),
      nonce: missile.nonce,
      level: missile.level,
    );
    _incoming.add(shot);
    _firedBy[missile.id] = now;
    _cue(SonarEvent(SonarCue.incoming, peer: missile.id, level: missile.level));
    _checkCollision();
    _syncAmbience();
    notifyListeners();
  }

  void _landIncoming(_Incoming shot) {
    if (!_incoming.remove(shot)) return;
    shot.cancel();
    final until = _visibleUntil;
    if (_disposed || (until == null && !_manuallyOff) || destroyed) return;
    final now = _now();
    final lost = Duration(
      microseconds: defaultVisibleWindow.inMicroseconds * shot.permille ~/ 1000,
    );
    final left = until?.difference(now) ?? Duration.zero;
    _lastHit = (at: now, lost: lost < left ? lost : left);
    final next = until?.subtract(lost) ?? now;
    if (!next.isAfter(now)) {
      const rearm = SonarCombat.rearm;
      _rearmAt = now.add(rearm);
      _rearmTimer = Timer(rearm, () {
        _rearmAt = null;
        _rearmTimer = null;
        if (_disposed) return;
        _cue(const SonarEvent(SonarCue.rearmed));
        notifyListeners();
      });
      _cancelCharge();
      _manuallyOff = false;
      _cue(SonarEvent(SonarCue.destroyed, peer: shot.from));
      endVisible(keepIncoming: true);
      _clearIncoming();
      _syncAmbience();
      notifyListeners();
      return;
    }
    _visibleUntil = next;
    _windowTimer?.cancel();
    _windowTimer = Timer(next.difference(now), endVisible);
    _cue(
      SonarEvent(
        SonarCue.hit,
        peer: shot.from,
        low:
            next.difference(now) <= defaultVisibleWindow * SonarCombat.lowShare,
      ),
    );
    notifyListeners();
  }

  /// On while you fired at someone who fired at you, both within
  /// [SonarCombat.engagement], and only while Sonar is on screen.
  void _syncAmbience() {
    _ambienceTimer?.cancel();
    _ambienceTimer = null;
    final now = _now();
    bool stale(DateTime at) => now.difference(at) >= SonarCombat.engagement;
    _firedAt.removeWhere((_, at) => stale(at));
    _firedBy.removeWhere((_, at) => stale(at));
    DateTime? lapse;
    for (final MapEntry(key: id, value: fired) in _firedAt.entries) {
      final by = _firedBy[id];
      if (by == null) continue;
      final end = (fired.isBefore(by) ? fired : by).add(SonarCombat.engagement);
      if (lapse == null || end.isAfter(lapse)) lapse = end;
    }
    final on =
        !_disposed && watching && listening && !destroyed && lapse != null;
    if (on) _ambienceTimer = Timer(lapse.difference(now), _syncAmbience);
    if (on == _ambience) return;
    _ambience = on;
    _cue(SonarEvent(on ? SonarCue.ambienceOn : SonarCue.ambienceOff));
  }

  void _cue(SonarEvent event) {
    if (!_disposed) _combat.add(event);
  }

  void _cancelCharge() {
    _chargeTimer?.cancel();
    _chargeTimer = null;
    _chargeTarget = null;
    _chargeTaps = 0;
  }

  void _clearIncoming() {
    _collisionTimer?.cancel();
    _collisionTimer = null;
    for (final shot in _incoming) {
      shot.cancel();
    }
    _incoming.clear();
    _cue(const SonarEvent(SonarCue.incomingEnded));
  }

  /// Nearby stopped: nothing of yours stays charging or in flight.
  void _endCombat() {
    _collisionTimer?.cancel();
    _collisionTimer = null;
    _manuallyOff = false;
    _cancelCharge();
    _clearIncoming();
    _outgoingTimer?.cancel();
    _outgoingTimer = null;
    _sinkWatch = null;
    if (_outgoing case final out?) {
      _outgoing = null;
      _cue(SonarEvent(SonarCue.missileGone, peer: out.target));
    }
    _syncAmbience();
  }

  void clearPendingWave() {
    if (!_pendingWave || _disposed) return;
    _pendingWave = false;
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _serial.then((_) => operation());
    _serial = next.catchError((Object _) {});
    return next;
  }

  Future<void> _start() async {
    if (_disposed || listening) return;
    _cancelSubscription();
    _status = NearbyStatus.starting;
    _error = null;
    notifyListeners();
    try {
      final stream = await _transport.start();
      if (_disposed) {
        await _safeStopTransport();
        return;
      }
      _subscription = stream.listen(_onDatagram, onError: _onTransportError);
      _status = NearbyStatus.listening;
    } on Object catch (error) {
      _status = NearbyStatus.error;
      _error = error;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _stop() async {
    if (_status == NearbyStatus.stopped) return;
    endVisible();
    _cancelSubscription();
    await _safeStopTransport();
    _clearPeers();
    _status = NearbyStatus.stopped;
    _endCombat();
    _error = null;
    if (!_disposed) notifyListeners();
  }

  void _onTransportError(Object error) {
    if (_disposed) return;
    // A failed socket hears nothing further; no badge or sonar in error state.
    _cancelSubscription();
    _clearPeers();
    _cancelVisibilityTimers();
    _visibilityGeneration++;
    _launching = false;
    _visibleUntil = null;
    _status = NearbyStatus.error;
    _error = error;
    _endCombat();
    notifyListeners();
  }

  void _onDatagram(NearbyDatagram datagram) {
    if (_disposed) return;
    final packet = NearbyProtocol.decode(datagram.data);
    if (packet == null || packet.id == _ownId) return;
    switch (packet) {
      case NearbyBye(:final id):
        if (_removePeer(id)) {
          _gone(id);
          notifyListeners();
        }
      case NearbyAnnouncement(:final id, :final name, :final ping):
        _onAnnouncement(id, name, ping: ping);
      case final NearbyMissile missile:
        _onMissile(missile);
    }
  }

  void _onAnnouncement(String id, String name, {bool ping = false}) {
    final now = _now();
    if (!_peers.containsKey(id) && _peers.length >= maxPeers) return;
    final heard = _lastHeard.remove(id);
    final fresh = heard == null || now.difference(heard) >= sonarRecency;
    _rememberHeard(id, now);
    _peers[id] = NearbyPeer(id: id, name: name, lastSeen: now);
    _expiry.remove(id)?.cancel();
    _expiry[id] = Timer(peerTimeout, () {
      _expiry.remove(id);
      if (_peers.remove(id) != null && !_disposed) {
        _gone(id);
        notifyListeners();
      }
    });
    if (ping) {
      // Senders already space pings by [pulseCooldown]; this bounds a LAN
      // spraying pings under many ids.
      final last = _lastPing;
      if (last == null || now.difference(last) >= pulseCooldown) {
        _lastPing = now;
        if (!watching) _pendingWave = true;
        _sonar.add(id);
      }
    } else if (fresh && !visible) {
      if (!watching) _pendingWave = true;
      final last = _lastSonar;
      if (last == null || now.difference(last) >= sonarCooldown) {
        _lastSonar = now;
        _sonar.add(id);
      }
    }
    notifyListeners();
  }

  void _rememberHeard(String id, DateTime now) {
    _lastHeard.removeWhere((_, at) => now.difference(at) >= sonarRecency);
    while (_lastHeard.length >= maxRemembered) {
      _lastHeard.remove(_lastHeard.keys.first);
    }
    _lastHeard[id] = now;
  }

  bool _removePeer(String id) {
    _expiry.remove(id)?.cancel();
    return _peers.remove(id) != null;
  }

  void _clearPeers() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    _peers.clear();
  }

  void _announce({bool ping = false}) {
    final packet = NearbyProtocol.encodeAnnouncement(
      _ownId,
      _ownName,
      ping: ping,
    );
    if (packet == null || _ownId.isEmpty || !listening) return;
    final generation = _visibilityGeneration;
    unawaited(
      _send(packet).then((sent) {
        if (_disposed || generation != _visibilityGeneration || !visible) {
          return;
        }
        if (sent) {
          _announced.add(null);
        } else {
          _recordSendFailure();
        }
      }),
    );
  }

  Future<bool> _send(Uint8List data) async {
    if (_ownId.isEmpty || !listening) return false;
    try {
      await _transport.send(data);
      return true;
    } on Object {
      return false;
    }
  }

  void _recordSendFailure() {
    _sendError = 'Nearby send failed';
    if (!_disposed) notifyListeners();
  }

  void _cancelVisibilityTimers() {
    _announceTimer?.cancel();
    _announceTimer = null;
    _windowTimer?.cancel();
    _windowTimer = null;
  }

  // Not awaited: a cancelled transport stream has nothing left to flush, and the stop/rebind that follows is what
  // releases the socket.
  void _cancelSubscription() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  Future<void> _safeStopTransport() async {
    try {
      await _transport.stop();
    } on Object {
      // Stopping is best effort; the next start rebinds.
    }
  }

  @override
  void dispose() {
    _collisionTimer?.cancel();
    if (_disposed) return;
    endVisible();
    _disposed = true;
    _cancelVisibilityTimers();
    _cancelCharge();
    _clearIncoming();
    _outgoingTimer?.cancel();
    _rearmTimer?.cancel();
    _ambienceTimer?.cancel();
    _clearPeers();
    _cancelSubscription();
    if (_status != NearbyStatus.stopped) unawaited(_safeStopTransport());
    unawaited(_sonar.close());
    unawaited(_announced.close());
    unawaited(_combat.close());
    super.dispose();
  }
}

final class _Incoming {
  _Incoming(
    this.from,
    this.permille,
    this._land,
    this._close, {
    this.nonce,
    this.level = 0,
  });
  final String from;
  final int permille;
  final Timer _land;
  final Timer _close;
  final String? nonce;
  final int level;

  void cancel() {
    _land.cancel();
    _close.cancel();
  }
}
