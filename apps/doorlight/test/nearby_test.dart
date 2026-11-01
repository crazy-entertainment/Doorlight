import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/nearby.dart';

final String own = 'a' * 40;
final String peerA = 'b' * 40;
final String peerB = 'c' * 40;
final String peerC = 'd' * 40;

Uint8List json(Object value) => utf8.encode(jsonEncode(value));

Uint8List hello(String id, [String name = 'Peer']) =>
    NearbyProtocol.encodeAnnouncement(id, name)!;

class FakeTransport implements NearbyTransport {
  Object? startError;
  int starts = 0;
  int stops = 0;
  final List<NearbyPacket?> sent = [];
  StreamController<NearbyDatagram>? incoming;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    starts++;
    if (startError != null) throw startError!;
    incoming = StreamController<NearbyDatagram>();
    return incoming!.stream;
  }

  @override
  Future<void> send(Uint8List data) async =>
      sent.add(NearbyProtocol.decode(data));

  @override
  Future<void> stop() async {
    stops++;
    unawaited(incoming?.close());
    incoming = null;
  }

  void deliver(Uint8List data) =>
      incoming!.add((data: data, sender: InternetAddress.loopbackIPv4));

  int get announcements => sent.whereType<NearbyAnnouncement>().length;
  int get byes => sent.whereType<NearbyBye>().length;
}

void main() {
  group('codec', () {
    test('round-trips announcement and bye', () {
      final hi = NearbyProtocol.decode(hello(peerA, '  Ada  '));
      expect(hi, isA<NearbyAnnouncement>());
      expect((hi! as NearbyAnnouncement).name, 'Ada');
      expect(hi.id, peerA);
      final bye = NearbyProtocol.decode(NearbyProtocol.encodeBye(peerA)!);
      expect(bye, isA<NearbyBye>());
      expect(bye!.id, peerA);
      expect(
        NearbyProtocol.decode(json({'doorlight': 1, 'id': peerA, 'name': ''})),
        isA<NearbyAnnouncement>(),
      );
    });

    test('rejects each malformed class without throwing', () {
      final cases = <String, List<int>>{
        'empty': const [],
        'not utf8': [0xff, 0xfe, 0x7b],
        'not json': utf8.encode('{doorlight'),
        'array': json([1, peerA]),
        'missing name': json({'doorlight': 1, 'id': peerA}),
        'missing version': json({'id': peerA, 'name': 'x'}),
        'missing id': json({'doorlight': 1, 'name': 'x'}),
        'unknown key': json({
          'doorlight': 1,
          'id': peerA,
          'name': 'x',
          'extra': 1,
        }),
        'bye plus name': json({
          'doorlight': 1,
          'id': peerA,
          'name': 'x',
          'bye': true,
        }),
        'bye false': json({'doorlight': 1, 'id': peerA, 'bye': false}),
        'version 2': json({'doorlight': 2, 'id': peerA, 'name': 'x'}),
        'version string': json({'doorlight': '1', 'id': peerA, 'name': 'x'}),
        'version double': utf8.encode(
          '{"doorlight":1.0,"id":"$peerA","name":"x"}',
        ),
        'uppercase id': json({
          'doorlight': 1,
          'id': peerA.toUpperCase(),
          'name': 'x',
        }),
        'jami: uri id': json({
          'doorlight': 1,
          'id': 'jami:$peerA',
          'name': 'x',
        }),
        'padded id': json({'doorlight': 1, 'id': ' $peerA', 'name': 'x'}),
        'short id': json({'doorlight': 1, 'id': 'b' * 39, 'name': 'x'}),
        'id not string': json({'doorlight': 1, 'id': 7, 'name': 'x'}),
        'name not string': json({'doorlight': 1, 'id': peerA, 'name': 7}),
        'name too long': json({'doorlight': 1, 'id': peerA, 'name': 'n' * 65}),
        'control char': json({'doorlight': 1, 'id': peerA, 'name': 'a\nb'}),
        'C1 control': json({'doorlight': 1, 'id': peerA, 'name': 'a\u0085b'}),
        'bidi override': json({
          'doorlight': 1,
          'id': peerA,
          'name': 'a\u202Eb',
        }),
        'bidi isolate': json({'doorlight': 1, 'id': peerA, 'name': 'a\u2066b'}),
        'oversized': json({'doorlight': 1, 'id': peerA, 'name': 'x' * 600}),
        'deep nesting': utf8.encode('[' * 400),
      };
      for (final entry in cases.entries) {
        expect(NearbyProtocol.decode(entry.value), isNull, reason: entry.key);
      }
      // 64 characters after trimming is the limit, measured in code points.
      expect(
        NearbyProtocol.decode(
          json({'doorlight': 1, 'id': peerA, 'name': '  ${'é' * 64}  '}),
        ),
        isNotNull,
      );
    });

    test('encoder refuses non-canonical ids and sanitizes names', () {
      expect(NearbyProtocol.encodeAnnouncement('', 'x'), isNull);
      expect(NearbyProtocol.encodeAnnouncement('jami:$peerA', 'x'), isNull);
      expect(NearbyProtocol.encodeBye(peerA.toUpperCase()), isNull);
      final packet = NearbyProtocol.decode(
        NearbyProtocol.encodeAnnouncement(peerA, ' a\u202Eb\n${'z' * 80}')!,
      );
      expect(packet, isA<NearbyAnnouncement>());
      final name = (packet! as NearbyAnnouncement).name;
      expect(name, startsWith('ab'));
      expect(name.runes.length, NearbyProtocol.maxNameChars);
    });
  });

  group('controller', () {
    late FakeTransport transport;
    late NearbyController controller;

    void withController(
      void Function(FakeAsync async) body, {
      String ownId = 'own',
    }) {
      fakeAsync((async) {
        final epoch = DateTime.utc(2026, 10);
        transport = FakeTransport();
        controller = NearbyController(
          transport: transport,
          ownId: ownId == 'own' ? own : ownId,
          ownName: 'Me',
          now: () => epoch.add(async.elapsed),
        );
        body(async);
        controller.dispose();
        async.flushMicrotasks();
      });
    }

    void startListening(FakeAsync async) {
      controller.start();
      async.flushMicrotasks();
      expect(controller.status, NearbyStatus.listening);
    }

    void deliver(FakeAsync async, Uint8List data) {
      transport.deliver(data);
      async.flushMicrotasks();
    }

    test('listening is passive and sends nothing', () {
      withController((async) {
        startListening(async);
        deliver(async, hello(peerA));
        async.elapse(const Duration(minutes: 10));
        expect(transport.sent, isEmpty);
      });
    });

    test('start and stop are idempotent across rapid toggles', () {
      withController((async) {
        controller.start();
        controller.start();
        controller.stop();
        controller.start();
        controller.stop();
        controller.stop();
        controller.start();
        async.flushMicrotasks();
        expect(controller.status, NearbyStatus.listening);
        expect(transport.starts, 3);
        expect(transport.stops, 2);
        controller.start();
        async.flushMicrotasks();
        expect(transport.starts, 3);
        controller.stop();
        controller.stop();
        async.flushMicrotasks();
        expect(controller.status, NearbyStatus.stopped);
        expect(transport.stops, 3);
      });
    });

    test('transport bind failure becomes error state', () {
      withController((async) {
        transport.startError = const SocketException('bind failed');
        Object? thrown;
        controller.start().then((_) {}, onError: (Object e) => thrown = e);
        async.flushMicrotasks();
        expect(thrown, isNull);
        expect(controller.status, NearbyStatus.error);
        expect(controller.error, isA<SocketException>());
        expect(controller.goVisible(), isFalse);
        transport.startError = null;
        controller.start();
        async.flushMicrotasks();
        expect(controller.status, NearbyStatus.listening);
        expect(controller.error, isNull);
      });
    });

    test('manual pulses announce only while visible and are rate-limited', () {
      withController((async) {
        startListening(async);
        expect(controller.pulse(), isFalse, reason: 'hidden sends nothing');
        expect(transport.sent, isEmpty);
        expect(controller.goVisible(), isTrue);
        final afterReveal = transport.sent.length;
        expect(controller.pulse(), isTrue);
        expect(transport.sent.length, afterReveal + 1);
        expect(controller.pulse(), isFalse, reason: 'within the cooldown');
        async.elapse(NearbyController.pulseCooldown);
        final before = transport.sent.length;
        expect(controller.pulse(), isTrue);
        expect(transport.sent.length, before + 1);
      });
    });

    test('own-id packets are ignored', () {
      withController((async) {
        startListening(async);
        deliver(async, hello(own));
        expect(controller.peers, isEmpty);
        expect(controller.pendingWave, isFalse);
      });
    });

    test('peers expire 6 s after their last packet or on bye', () {
      withController((async) {
        startListening(async);
        deliver(async, hello(peerA, 'Ada'));
        deliver(async, hello(peerB, 'Bob'));
        expect(controller.peers.map((p) => p.id), containsAll([peerA, peerB]));
        expect(controller.peers.firstWhere((p) => p.id == peerA).name, 'Ada');

        async.elapse(const Duration(seconds: 4));
        deliver(async, hello(peerA, 'Ada'));
        async.elapse(const Duration(milliseconds: 1999));
        expect(controller.peers, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.peers.map((p) => p.id), [peerA]);
        async.elapse(const Duration(seconds: 4));
        expect(controller.peers, isEmpty);

        deliver(async, hello(peerC));
        deliver(async, NearbyProtocol.encodeBye(peerC)!);
        expect(controller.peers, isEmpty);
      });
    });

    test('visible window announces periodically then byes at window end', () {
      withController((async) {
        startListening(async);
        expect(controller.goVisible(), isTrue);
        expect(controller.visible, isTrue);
        expect(
          controller.visibleUntil,
          DateTime.utc(2026, 10).add(const Duration(minutes: 5)),
        );
        async.flushMicrotasks();
        expect(transport.announcements, 1);
        expect((transport.sent.first! as NearbyAnnouncement).name, 'Me');
        expect(transport.sent.first!.id, own);

        async.elapse(const Duration(milliseconds: 1500));
        expect(transport.announcements, 2);
        async.elapse(
          const Duration(minutes: 5) - const Duration(milliseconds: 1501),
        );
        expect(controller.visible, isTrue);
        expect(transport.byes, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.visible, isFalse);
        expect(controller.visibleUntil, isNull);
        // t = 0, 1.5, ... 298.5 s.
        expect(transport.announcements, 200);
        expect(transport.byes, 1);
        expect(transport.sent.last, isA<NearbyBye>());

        async.elapse(const Duration(minutes: 1));
        expect(transport.sent, hasLength(201));
      });
    });

    test('endVisible stops announcing and sends one bye', () {
      withController((async) {
        startListening(async);
        controller.goVisible(window: const Duration(seconds: 30));
        async.elapse(const Duration(seconds: 3));
        controller.endVisible();
        controller.endVisible();
        async.elapse(const Duration(minutes: 1));
        expect(transport.announcements, 3);
        expect(transport.byes, 1);
        expect(controller.visible, isFalse);
      });
    });

    test('stop while visible sends bye and stops announcing', () {
      withController((async) {
        startListening(async);
        controller.goVisible();
        controller.stop();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 6));
        expect(transport.announcements, 1);
        expect(transport.byes, 1);
        expect(controller.visible, isFalse);
      });
    });

    test('empty own id never sends', () {
      withController((async) {
        startListening(async);
        expect(controller.goVisible(), isFalse);
        expect(controller.visible, isFalse);
        controller.endVisible();
        async.elapse(const Duration(minutes: 6));
        expect(transport.sent, isEmpty);
      }, ownId: '');
    });

    test('clearing own id while visible ends visibility', () {
      withController((async) {
        startListening(async);
        controller.goVisible();
        controller.ownId = '';
        async.elapse(const Duration(minutes: 6));
        expect(transport.announcements, 1);
        expect(transport.byes, 1);
        expect(transport.sent.last!.id, own);
      });
    });

    test('sonarReceived is limited to one event per 60 s', () {
      withController((async) {
        final events = <String>[];
        controller.sonarReceived.listen(events.add);
        startListening(async);
        deliver(async, hello(peerA));
        deliver(async, hello(peerB));
        expect(events, [peerA]);
        async.elapse(const Duration(seconds: 59));
        deliver(async, hello(peerC));
        expect(events, [peerA]);
        async.elapse(const Duration(seconds: 1));
        deliver(async, NearbyProtocol.encodeBye(peerC)!);
        deliver(async, hello(peerC));
        // peerC was heard 1 s ago, so it is not a new arrival.
        expect(events, [peerA]);
      });
    });

    test('sonarReceived fires only for peers unseen for 5 minutes', () {
      withController((async) {
        final events = <String>[];
        controller.sonarReceived.listen(events.add);
        startListening(async);
        deliver(async, hello(peerA));
        async.elapse(const Duration(minutes: 2));
        deliver(async, hello(peerA));
        expect(events, [peerA]);
        async.elapse(const Duration(minutes: 5));
        deliver(async, hello(peerA));
        expect(events, [peerA, peerA]);
      });
    });

    test('a known peer\'s ping always reaches sonarReceived', () {
      withController((async) {
        final events = <String>[];
        controller.sonarReceived.listen(events.add);
        startListening(async);
        deliver(async, hello(peerA));
        controller.goVisible();
        expect(
          (transport.sent.last! as NearbyAnnouncement).ping,
          isTrue,
          reason: 'revealing pings',
        );
        async.elapse(NearbyController.pulseCooldown);
        controller.pulse();
        expect((transport.sent.last! as NearbyAnnouncement).ping, isTrue);
        Uint8List ping() =>
            NearbyProtocol.encodeAnnouncement(peerA, 'Peer', ping: true)!;
        deliver(async, ping());
        expect(events, [peerA, peerA], reason: 'even while visible');
        deliver(async, ping());
        expect(events, hasLength(2), reason: 'within the ping cooldown');
        async.elapse(NearbyController.pulseCooldown);
        deliver(async, ping());
        expect(events, hasLength(3));
        deliver(
          async,
          json({'doorlight': 1, 'id': peerB, 'name': 'x', 'ping': 1}),
        );
        expect(controller.peers.map((p) => p.id), [peerA], reason: 'strict');
      });
    });

    test('no sonar or wave while visible, and arrival never makes visible', () {
      withController((async) {
        final events = <String>[];
        controller.sonarReceived.listen(events.add);
        startListening(async);
        controller.goVisible(window: const Duration(seconds: 10));
        deliver(async, hello(peerA));
        expect(events, isEmpty);
        expect(controller.pendingWave, isFalse);
        expect(controller.peers.map((p) => p.id), [peerA]);
        async.elapse(const Duration(seconds: 10));
        expect(controller.visible, isFalse);
        final sentBefore = transport.sent.length;
        deliver(async, hello(peerB));
        expect(events, [peerB]);
        expect(controller.visible, isFalse);
        async.elapse(const Duration(minutes: 1));
        expect(transport.sent, hasLength(sentBefore));
      });
    });

    test('pendingWave is set by a new arrival and cleared on request', () {
      withController((async) {
        var notifications = 0;
        controller.addListener(() => notifications++);
        startListening(async);
        expect(controller.pendingWave, isFalse);
        deliver(async, hello(peerA));
        expect(controller.pendingWave, isTrue);
        final before = notifications;
        controller.clearPendingWave();
        expect(controller.pendingWave, isFalse);
        expect(notifications, before + 1);
        controller.clearPendingWave();
        expect(notifications, before + 1);
        deliver(async, hello(peerA));
        expect(controller.pendingWave, isFalse);
      });
    });

    test(
      'while Sonar is watched nothing raises the wave; events still flow',
      () {
        withController((async) {
          final events = <String>[];
          controller.sonarReceived.listen(events.add);
          startListening(async);
          deliver(async, hello(peerA));
          expect(controller.pendingWave, isTrue);
          controller.watch();
          expect(
            controller.pendingWave,
            isFalse,
            reason: 'opening acknowledges',
          );
          deliver(async, hello(peerB));
          deliver(
            async,
            NearbyProtocol.encodeAnnouncement(peerA, 'Peer', ping: true)!,
          );
          expect(events, [
            peerA,
            peerA,
          ], reason: 'the stage still sees the ping');
          expect(controller.pendingWave, isFalse);
          controller.unwatch();
          async.elapse(NearbyController.pulseCooldown);
          deliver(
            async,
            NearbyProtocol.encodeAnnouncement(peerA, 'Peer', ping: true)!,
          );
          expect(controller.pendingWave, isTrue);
        });
      },
    );

    test('malformed datagrams are ignored', () {
      withController((async) {
        startListening(async);
        deliver(async, Uint8List.fromList([0xff, 0x00]));
        deliver(async, json({'doorlight': 1, 'id': peerA, 'name': 'a\u202Eb'}));
        expect(controller.peers, isEmpty);
        expect(controller.status, NearbyStatus.listening);
      });
    });

    test('peer table is bounded against id flooding', () {
      withController((async) {
        startListening(async);
        for (var i = 0; i < NearbyController.maxPeers + 10; i++) {
          deliver(async, hello(i.toRadixString(16).padLeft(40, '0')));
        }
        expect(controller.peers, hasLength(NearbyController.maxPeers));
      });
    });
  });
}
