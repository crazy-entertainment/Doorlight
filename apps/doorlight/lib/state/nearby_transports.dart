import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/services.dart';

import '../core/jami.dart';
import 'nearby.dart';

NearbyTransport nearbyTransport(
  JamiClient jami, {
  required void Function() onPermissionRequired,
  bool Function()? googleAllowed,
}) => MultiNearbyTransport([
  UdpNearbyTransport.forPlatform(jami, broadcast: true),
  RadioNearbyTransport(
    onPermissionRequired: onPermissionRequired,
    googleAllowed: googleAllowed,
  ),
]);

/// Each carrier has the same visibility lifetime; one failed carrier does not
/// take the others offline. Device linking does not use this transport.
final class MultiNearbyTransport implements NearbyTransport {
  MultiNearbyTransport(this.transports);

  final List<NearbyTransport> transports;
  final _active = <NearbyTransport, StreamSubscription<NearbyDatagram>>{};
  final _cleanups = <Future<void>>{};
  bool _starting = false;
  final _random = Random.secure();
  NearbyIngress? _ingress;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    await stop();
    final ingress = NearbyIngress();
    _ingress = ingress;
    _starting = true;
    Object? failure;
    for (final transport in transports) {
      try {
        final stream = await transport.start();
        _active[transport] = stream.listen(
          ingress.add,
          onError: (Object error) => _failed(transport, error, ingress),
          onDone: () =>
              _failed(transport, StateError('Nearby carrier closed'), ingress),
        );
      } on Object catch (error) {
        failure = error;
        await _stopCarrier(transport);
      }
    }
    _starting = false;
    if (_active.isEmpty) {
      ingress.close();
      _ingress = null;
      throw failure ?? StateError('No nearby carrier available');
    }
    return ingress.stream;
  }

  void _failed(NearbyTransport transport, Object error, NearbyIngress ingress) {
    if (!identical(_ingress, ingress)) return;
    final subscription = _active.remove(transport);
    if (subscription == null) return;
    final cleanup = subscription
        .cancel()
        .catchError((Object _) {})
        .then((_) => _stopCarrier(transport));
    _cleanups.add(cleanup);
    unawaited(cleanup.whenComplete(() => _cleanups.remove(cleanup)));
    if (!_starting && _active.isEmpty) ingress.addError(error);
  }

  @override
  Future<void> send(Uint8List data) async {
    if (NearbyProtocol.decode(data) case final NearbyMissile missile) {
      data = NearbyProtocol.encodeMissile(
        missile.id,
        missile.at,
        missile.permille,
        missile.level,
        nonce:
            missile.nonce ??
            List.generate(
              8,
              (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
            ).join(),
      )!;
    }
    // A native permission/adaptor failure must not suppress the LAN send.
    final carriers = _active.keys.toList();
    if (carriers.isEmpty) {
      throw StateError('Nearby send failed on all active carriers');
    }
    final result = Completer<void>();
    var failures = 0;
    for (final carrier in carriers) {
      unawaited(
        Future<void>.sync(() => carrier.send(data)).then(
          (_) {
            if (!result.isCompleted) result.complete();
          },
          onError: (Object _) {
            if (++failures == carriers.length && !result.isCompleted) {
              result.completeError(
                StateError('Nearby send failed on all active carriers'),
              );
            }
          },
        ),
      );
    }
    await result.future;
  }

  @override
  Future<void> stop() async {
    final subscriptions = _active.values.toList();
    final carriers = _active.keys.toList();
    _active.clear();
    _ingress?.close();
    _ingress = null;
    await Future.wait([
      for (final subscription in subscriptions)
        subscription.cancel().catchError((Object _) {}),
      ..._cleanups,
      ...carriers.map(_stopCarrier),
    ]);
  }

  static Future<void> _stopCarrier(NearbyTransport carrier) async {
    try {
      await carrier.stop();
    } on Object {
      // Other carriers still need their cleanup.
    }
  }
}

/// BLE reads and Google byte payloads use a four-byte big-endian sequence
/// followed by the same strict JSON as LAN. No radio address is a trusted ID.
final class RadioNearbyTransport implements NearbyTransport {
  RadioNearbyTransport({
    required this.onPermissionRequired,
    this.googleAllowed,
  });
  final void Function() onPermissionRequired;
  final bool Function()? googleAllowed;
  static const _methods = MethodChannel('syb.l/nearby_radio');
  static const _events = EventChannel('syb.l/nearby_radio_events');
  final _clock = Stopwatch()..start();
  final _seen = <String, ({Duration at, ListQueue<int> sequences})>{};
  StreamSubscription<dynamic>? _subscription;
  NearbyIngress? _ingress;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    await stop();
    final ingress = NearbyIngress();
    _ingress = ingress;
    _subscription = _events.receiveBroadcastStream().listen(
      (event) => _receive(event, ingress),
      onError: ingress.addError,
    );
    try {
      final available = await _methods.invokeMethod<bool>('start', {
        'googleAllowed': googleAllowed?.call() == true,
      });
      if (available != true) throw StateError('Nearby radio unavailable');
    } on Object {
      await stop();
      rethrow;
    }
    return ingress.stream;
  }

  void _receive(dynamic event, NearbyIngress ingress) {
    if (!identical(_ingress, ingress) || event is! Map) return;
    if (event['permissionRequired'] == true) {
      onPermissionRequired();
      return;
    }
    final source = event['source'];
    final frame = event['frame'];
    if (source is! String ||
        source.length > 100 ||
        !(source.startsWith('ble:') || source.startsWith('google:')) ||
        frame is! Uint8List ||
        frame.length <= 4 ||
        frame.length > 512) {
      return;
    }
    final now = _clock.elapsed;
    _seen.removeWhere(
      (_, value) => now - value.at > const Duration(seconds: 6),
    );
    final prior = _seen[source];
    if (prior == null && _seen.length >= 64) return;
    final sequences = prior?.sequences ?? ListQueue<int>();
    final sequence = ByteData.sublistView(frame).getUint32(0);
    _seen[source] = (at: now, sequences: sequences);
    if (sequences.contains(sequence)) return;
    if (sequences.length >= 8) sequences.removeFirst();
    sequences.add(sequence);
    ingress.add((data: Uint8List.sublistView(frame, 4), sender: source));
  }

  @override
  Future<void> send(Uint8List data) async {
    if (_ingress == null || data.length > 508) return;
    final kind = switch (NearbyProtocol.decode(data)) {
      NearbyAnnouncement(:final ping) => ping ? 'ping' : 'announce',
      NearbyMissile() => 'missile',
      NearbyBye() => 'bye',
      _ => null,
    };
    if (kind != null) {
      final sent = await _methods.invokeMethod<bool>('send', {
        'data': data,
        'kind': kind,
      });
      if (sent != true) throw StateError('Nearby radio rejected send');
    }
  }

  @override
  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    _ingress?.close();
    _ingress = null;
    _seen.clear();
    if (subscription == null) return;
    try {
      await _methods.invokeMethod<void>('stop');
    } finally {
      await subscription.cancel();
    }
  }
}
