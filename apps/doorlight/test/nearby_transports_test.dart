import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/nearby.dart';
import 'package:sybl/state/nearby_transports.dart';

class _Carrier implements NearbyTransport {
  final incoming = StreamController<NearbyDatagram>();
  final sent = <Uint8List>[];
  bool failStart = false;
  bool failSend = false;
  int stops = 0;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  Completer<void>? sendGate;
  @override
  Future<Stream<NearbyDatagram>> start() async {
    await startGate?.future;
    if (failStart) throw StateError('unavailable');
    return incoming.stream;
  }

  @override
  Future<void> send(Uint8List data) async {
    await sendGate?.future;
    if (failSend) throw StateError('denied');
    sent.add(data);
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    unawaited(incoming.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final own = 'a' * 40;
  final peer = 'b' * 40;
  final hello = NearbyProtocol.encodeAnnouncement(own, 'Me')!;

  test(
    'failure during fallback startup does not poison the healthy carrier',
    () async {
      final lan = _Carrier();
      final radio = _Carrier()..startGate = Completer<void>();
      final transport = MultiNearbyTransport([lan, radio]);
      final starting = transport.start();
      await pumpEventQueue();
      lan.incoming.addError(StateError('LAN failed during radio startup'));
      await pumpEventQueue();
      radio.startGate!.complete();
      final errors = <Object>[];
      final subscription = (await starting).listen((_) {}, onError: errors.add);
      await pumpEventQueue();
      expect(errors, isEmpty);
      await transport.send(hello);
      expect(radio.sent, [hello]);
      await transport.stop();
      await subscription.cancel();
    },
  );

  test(
    'stop awaits cleanup of an already failed carrier before restart',
    () async {
      final lan = _Carrier();
      final radio = _Carrier()..stopGate = Completer<void>();
      final transport = MultiNearbyTransport([lan, radio]);
      await transport.start();
      radio.incoming.addError(StateError('radio lost'));
      await pumpEventQueue();
      var stopped = false;
      final stopping = transport.stop().then((_) => stopped = true);
      await pumpEventQueue();
      expect(stopped, isFalse);
      radio.stopGate!.complete();
      await stopping;
      expect(stopped, isTrue);
    },
  );

  test('an unavailable radio and a send failure do not disable LAN', () async {
    final lan = _Carrier();
    final absent = _Carrier()..failStart = true;
    final denied = _Carrier()..failSend = true;
    final transport = MultiNearbyTransport([absent, lan, denied]);
    final received = <NearbyDatagram>[];
    final subscription = (await transport.start()).listen(received.add);
    await transport.send(hello);
    expect(lan.sent, [hello]);
    lan.incoming.add((data: hello, sender: InternetAddress.loopbackIPv4));
    await pumpEventQueue();
    expect(received, hasLength(1));
    denied.incoming.addError(StateError('adapter lost'));
    await pumpEventQueue();
    await transport.send(hello);
    expect(lan.sent, hasLength(2));
    await transport.stop();
    await subscription.cancel();
    expect(lan.stops, 1);
    expect(absent.stops, 1);
    expect(denied.stops, 1);
  });

  test('all active carrier send failures are reported', () async {
    final lan = _Carrier()..failSend = true;
    final radio = _Carrier()..failSend = true;
    final transport = MultiNearbyTransport([lan, radio]);
    await transport.start();
    await expectLater(transport.send(hello), throwsStateError);
    await transport.stop();
  });

  test('fast LAN success does not wait for a slow radio send', () async {
    final lan = _Carrier();
    final radio = _Carrier()..sendGate = Completer<void>();
    final transport = MultiNearbyTransport([lan, radio]);
    await transport.start();
    var completed = false;
    final sending = transport.send(hello).then((_) => completed = true);
    await pumpEventQueue();
    final returnedBeforeRadio = completed;
    radio.sendGate!.complete();
    await sending;
    expect(returnedBeforeRadio, isTrue);
    expect(lan.sent, [hello]);
    expect(radio.sent, [hello]);
    await transport.stop();
  });

  test('all carriers receive the same unique shot identifier', () async {
    final lan = _Carrier();
    final radio = _Carrier();
    final transport = MultiNearbyTransport([lan, radio]);
    await transport.start();
    final shot = NearbyProtocol.encodeMissile(own, peer, 200, 0)!;
    await transport.send(shot);
    await transport.send(shot);
    expect(lan.sent[0], radio.sent[0]);
    expect(lan.sent[1], radio.sent[1]);
    final first = NearbyProtocol.decode(lan.sent[0]) as NearbyMissile;
    final second = NearbyProtocol.decode(lan.sent[1]) as NearbyMissile;
    expect(first.nonce, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(first.nonce, isNot(second.nonce));
    await transport.stop();
  });

  test('a delayed copy cannot apply a shot twice after shooter cooldown', () {
    fakeAsync((clock) {
      final carrier = _Carrier();
      final controller = NearbyController(
        transport: carrier,
        ownId: own,
        ownName: 'Me',
        now: () => DateTime.utc(2026).add(clock.elapsed),
      );
      controller.start();
      clock.flushMicrotasks();
      controller.goVisible();
      final shot = NearbyProtocol.encodeMissile(
        peer,
        own,
        200,
        0,
        nonce: '0123456789abcdef',
      )!;
      final cues = <SonarEvent>[];
      controller.combat.listen(cues.add);
      carrier.incoming.add((data: shot, sender: InternetAddress.loopbackIPv4));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 3));
      carrier.incoming.add((data: shot, sender: 'ble:peer'));
      clock.flushMicrotasks();
      expect(cues.where((cue) => cue.cue == SonarCue.incoming), hasLength(1));
      controller.dispose();
      clock.flushMicrotasks();
    });
  });

  test('nonce validation preserves strict decoding and legacy input', () {
    final legacy = NearbyProtocol.encodeMissile(own, peer, 200, 0)!;
    expect((NearbyProtocol.decode(legacy) as NearbyMissile).nonce, isNull);
    final values = jsonDecode(utf8.decode(legacy)) as Map<String, dynamic>;
    for (final nonce in [null, 7, '', 'ABCDEF0123456789', '0' * 17]) {
      expect(
        NearbyProtocol.decode(
          utf8.encode(jsonEncode({...values, 'nonce': nonce})),
        ),
        isNull,
      );
    }
    expect(
      NearbyProtocol.encodeMissile(own, peer, 200, 0, nonce: 'invalid'),
      isNull,
    );
  });

  group('radio bridge', () {
    const methods = MethodChannel('syb.l/nearby_radio');
    const events = MethodChannel('syb.l/nearby_radio_events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return call.method == 'stop' ? null : true;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });

    Future<void> emit(Object event) => messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );

    test(
      'hidden start sends no identity; permission requests end visibility',
      () async {
        var requests = 0;
        final radio = RadioNearbyTransport(
          onPermissionRequired: () => requests++,
        );
        final received = <NearbyDatagram>[];
        final subscription = (await radio.start()).listen(received.add);
        expect(calls.map((call) => call.method), ['start']);
        expect(calls.single.arguments, {'googleAllowed': false});
        await emit({'permissionRequired': true});
        expect(requests, 1);
        await radio.send(hello);
        expect((calls.last.arguments as Map)['kind'], 'announce');
        await radio.send(
          NearbyProtocol.encodeAnnouncement(own, 'Me', ping: true)!,
        );
        expect((calls.last.arguments as Map)['kind'], 'ping');
        final frame = Uint8List(hello.length + 4)
          ..setRange(4, hello.length + 4, hello);
        ByteData.sublistView(frame).setUint32(0, 1);
        await emit({'source': 'ble:peer', 'frame': frame});
        await emit({'source': 'ble:peer', 'frame': frame});
        await emit({'source': 'untrusted', 'frame': frame});
        await emit({'source': 'ble:peer', 'frame': Uint8List(513)});
        await pumpEventQueue();
        expect(received, hasLength(1));
        expect(received.single.data, hello);
        await radio.stop();
        await subscription.cancel();
        await radio.send(hello);
        expect(calls.last.method, 'stop');
      },
    );

    test('a native false result is a send failure', () async {
      final radio = RadioNearbyTransport(onPermissionRequired: () {});
      await radio.start();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return call.method == 'stop' ? null : false;
      });
      await expectLater(radio.send(hello), throwsStateError);
      await radio.stop();
    });

    test(
      'radio startup rereads explicit Google consent on every start',
      () async {
        var allowed = true;
        final radio = RadioNearbyTransport(
          onPermissionRequired: () {},
          googleAllowed: () => allowed,
        );
        await radio.start();
        expect(calls.last.arguments, {'googleAllowed': true});
        allowed = false;
        await radio.start();
        expect(calls.last.arguments, {'googleAllowed': false});
        await radio.stop();
      },
    );
  });
}
