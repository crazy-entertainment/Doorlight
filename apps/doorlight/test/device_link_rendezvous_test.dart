import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/device_link_rendezvous.dart';
import 'package:sybl/state/nearby.dart';

final _offer = 'jami-auth://${'a' * 64}/123456/doorlight-v1';

class _Bus {
  final Set<_Transport> transports = {};

  void send(_Transport from, Uint8List bytes) {
    for (final target in transports) {
      if (!identical(target, from)) target.deliver(bytes);
    }
  }
}

class _Transport implements NearbyTransport {
  _Transport(this.bus);
  final _Bus bus;
  final sent = <Uint8List>[];
  StreamController<NearbyDatagram>? _incoming;
  Object? startError;
  Completer<void>? startGate;
  bool failSend = false;
  int stops = 0;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    await startGate?.future;
    if (startError case final error?) throw error;
    _incoming = StreamController<NearbyDatagram>.broadcast(sync: true);
    bus.transports.add(this);
    return _incoming!.stream;
  }

  @override
  Future<void> send(Uint8List data) async {
    if (failSend) throw const SocketException('send failed');
    final copy = Uint8List.fromList(data);
    sent.add(copy);
    bus.send(this, copy);
  }

  @override
  Future<void> stop() async {
    stops++;
    bus.transports.remove(this);
    await _incoming?.close();
    _incoming = null;
  }

  void deliver(List<int> bytes) {
    _incoming?.add((
      data: Uint8List.fromList(bytes),
      sender: InternetAddress.loopbackIPv4,
    ));
  }
}

Uint8List _packet(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test(
    'closing waits for an in-flight bind and releases it before returning',
    () async {
      final bus = _Bus();
      final transport = _Transport(bus)..startGate = Completer<void>();
      final session = DeviceLinkRendezvous(
        role: DeviceLinkRendezvousRole.destination,
        transport: transport,
      );
      final opening = session.start();
      var closed = false;
      final closing = session.close().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      transport.startGate!.complete();
      await opening;
      await closing;
      expect(bus.transports, isEmpty);
      expect(transport.stops, 1);
      expect(session.status, DeviceLinkRendezvousStatus.stopped);
      session.dispose();
    },
  );

  test(
    'QR routes one published offer; source must explicitly select it',
    () async {
      final bus = _Bus();
      final sourceTransport = _Transport(bus);
      final destinationTransport = _Transport(bus);
      final source = DeviceLinkRendezvous(
        role: DeviceLinkRendezvousRole.source,
        transport: sourceTransport,
      );
      final destination = DeviceLinkRendezvous(
        role: DeviceLinkRendezvousRole.destination,
        transport: destinationTransport,
      );
      addTearDown(source.close);
      addTearDown(destination.close);

      await source.start();
      await destination.start();
      expect(source.qrText, isNull);
      expect(destination.sources, isEmpty);
      expect(source.reveal('  Existing device\u202e'), isTrue);
      final qr = source.qrText!;
      final token = DeviceLinkRendezvous.sourceTokenFromQr(qr)!;
      expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        DeviceLinkRendezvous.sourceTokenFromQr('$qr?name=Desktop'),
        isNull,
      );
      expect(DeviceLinkRendezvous.sourceTokenFromQr(qr.toUpperCase()), isNull);
      expect(destination.sources.single.name, 'Existing device');

      expect(destination.selectSource(token), isTrue);
      expect(
        await destination.sendOffer(offer: _offer, name: 'New phone'),
        isTrue,
      );
      expect(source.offers, hasLength(1));
      final candidate = source.offers.single;
      expect(candidate.offer, _offer);
      expect(candidate.name, 'New phone');
      expect(source.selectedOffer, isNull);
      expect(source.selectOffer(candidate.nonce), isTrue);
      expect(source.selectedOffer?.nonce, candidate.nonce);
      expect(
        await destination.sendOffer(offer: _offer, name: 'New phone'),
        isFalse,
      );
    },
  );

  test('rejects malformed packets, bad offers, and replayed nonces', () async {
    final bus = _Bus();
    final sourceTransport = _Transport(bus);
    final source = DeviceLinkRendezvous(
      role: DeviceLinkRendezvousRole.source,
      transport: sourceTransport,
    );
    addTearDown(source.close);
    await source.start();
    source.reveal('Desktop');
    final token = DeviceLinkRendezvous.sourceTokenFromQr(source.qrText!)!;
    final sender = _Transport(bus);
    await sender.start();
    addTearDown(sender.stop);

    expect(source.selectOffer('f' * 64), isFalse);
    await sender.send(
      _packet({
        'v': 1,
        'type': 'offer',
        'token': token,
        'nonce': 'e' * 64,
        'offer': 'jami-auth://bad',
        'name': 'Phone',
      }),
    );
    final valid = _packet({
      'v': 1,
      'type': 'offer',
      'token': token,
      'nonce': 'b' * 64,
      'offer': _offer,
      'name': 'Phone',
    });
    await sender.send(valid);
    await sender.send(valid);
    await sender.send(
      _packet({
        'v': 1,
        'type': 'offer',
        'token': token,
        'nonce': 'c' * 64,
        'offer': 'jami-auth://bad',
        'name': 'Phone',
      }),
    );
    await sender.send(
      _packet({
        'v': 1,
        'type': 'offer',
        'token': token,
        'nonce': 'd' * 64,
        'offer': _offer,
        'name': 'Phone',
        'extra': true,
      }),
    );
    sourceTransport.deliver(List<int>.filled(513, 0));
    expect(source.offers, hasLength(1));
    expect(source.offers.single.nonce, 'b' * 64);
  });

  test(
    'source hints expire and destination cannot send after five minutes',
    () {
      fakeAsync((async) {
        final bus = _Bus();
        final origin = DateTime.utc(2026, 1, 1);
        DateTime now() => origin.add(async.elapsed);
        final sourceTransport = _Transport(bus);
        final destinationTransport = _Transport(bus);
        final source = DeviceLinkRendezvous(
          role: DeviceLinkRendezvousRole.source,
          transport: sourceTransport,
          now: now,
        );
        final destination = DeviceLinkRendezvous(
          role: DeviceLinkRendezvousRole.destination,
          transport: destinationTransport,
          now: now,
        );
        unawaited(source.start());
        unawaited(destination.start());
        async.flushMicrotasks();
        source.reveal('Desktop');
        final token = DeviceLinkRendezvous.sourceTokenFromQr(source.qrText!)!;
        expect(destination.sources, hasLength(1));
        expect(destination.selectSource(token), isTrue);
        async.elapse(DeviceLinkRendezvous.sourceHintLifetime);
        expect(destination.sources, isEmpty);
        async.elapse(DeviceLinkRendezvous.lifetime);
        expect(destination.status, DeviceLinkRendezvousStatus.expired);
        bool? sent;
        destination
            .sendOffer(offer: _offer, name: 'Phone')
            .then((result) => sent = result);
        async.flushMicrotasks();
        expect(destinationTransport.stops, 1);
        expect(sent, isFalse);
        unawaited(source.close());
        unawaited(destination.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'transport failure is actionable and close releases its owner',
    () async {
      final bus = _Bus();
      final transport = _Transport(bus)
        ..startError = const SocketException('no Wi-Fi');
      final session = DeviceLinkRendezvous(
        role: DeviceLinkRendezvousRole.destination,
        transport: transport,
      );
      await session.start();
      expect(session.status, DeviceLinkRendezvousStatus.error);
      expect(session.error, contains('Check Wi-Fi'));
      await session.close();
      expect(transport.stops, 1); // failed start cleanup owns the stop.
      expect(session.status, DeviceLinkRendezvousStatus.stopped);
    },
  );
}
