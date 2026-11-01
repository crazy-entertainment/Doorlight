import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/nearby.dart';

NearbyDatagram packet(int source, {Uint8List? data}) => (
  data: data ?? NearbyProtocol.encodeAnnouncement(id(source), 'Peer $source')!,
  sender: InternetAddress(
    '10.${(source >> 16) & 255}.${(source >> 8) & 255}.${source & 255}',
  ),
);

String id(int value) => value.toRadixString(16).padLeft(40, '0');

class IngressTransport implements NearbyTransport {
  IngressTransport(this.ingress);
  final NearbyIngress ingress;

  @override
  Future<Stream<NearbyDatagram>> start() async => ingress.stream;
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<void> stop() async => ingress.close();
}

void main() {
  test(
    'single-source invalid flood is bounded before decoding and delivery',
    () {
      fakeAsync((async) {
        final ingress = NearbyIngress(now: () => async.elapsed);
        final delivered = <NearbyDatagram>[];
        ingress.stream.listen(delivered.add);
        final malformed = packet(1, data: Uint8List.fromList([0xff]));
        var admitted = 0;
        for (var i = 0; i < 100000; i++) {
          if (ingress.add(malformed)) admitted++;
        }
        expect(admitted, NearbyIngress.sourceBurst);
        expect(
          ingress.add(packet(2)),
          isTrue,
          reason: 'one flooding source cannot spend the aggregate budget',
        );
        async.elapse(Duration.zero);
        expect(delivered.length, NearbyIngress.sourceBurst + 1);
        async.elapse(const Duration(seconds: 1));
        admitted = 0;
        for (var i = 0; i < 10000; i++) {
          if (ingress.add(malformed)) admitted++;
        }
        expect(admitted, NearbyIngress.sourcePerSecond);
        ingress.close();
      });
    },
  );

  test(
    'aggregate admission bounds a many-source flood across drained batches',
    () {
      fakeAsync((async) {
        final ingress = NearbyIngress(now: () => async.elapsed);
        var delivered = 0;
        ingress.stream.listen((_) => delivered++);
        var admitted = 0;
        for (var round = 0; round < 8; round++) {
          for (var source = 1; source <= 64; source++) {
            if (ingress.add(packet(source))) admitted++;
          }
          async.elapse(Duration.zero);
        }
        expect(admitted, NearbyIngress.totalBurst);
        expect(delivered, admitted);
        async.elapse(const Duration(seconds: 1));
        admitted = 0;
        for (var round = 0; round < 4; round++) {
          for (var source = 1; source <= 64; source++) {
            if (ingress.add(packet(source))) admitted++;
          }
          async.elapse(Duration.zero);
        }
        expect(admitted, NearbyIngress.totalPerSecond);
        ingress.close();
      });
    },
  );

  test('unlistened and paused queues remain bounded across budget refills', () {
    fakeAsync((async) {
      final ingress = NearbyIngress(now: () => async.elapsed);
      var admitted = 0;
      for (var round = 0; round < 100; round++) {
        for (var source = 1; source <= 64; source++) {
          if (ingress.add(packet(source))) admitted++;
        }
        async.elapse(const Duration(seconds: 2));
      }
      expect(admitted, NearbyIngress.maxQueued);
      final delivered = <NearbyDatagram>[];
      final subscription = ingress.stream.listen(delivered.add)..pause();
      async.elapse(const Duration(seconds: 2));
      expect(delivered, isEmpty);
      expect(ingress.add(packet(100)), isFalse);
      subscription.resume();
      async.elapse(Duration.zero);
      expect(delivered.length, NearbyIngress.maxQueued);
      delivered.clear();
      subscription.pause();
      admitted = 0;
      for (var round = 0; round < 100; round++) {
        for (var source = 1; source <= 64; source++) {
          if (ingress.add(packet(source))) admitted++;
        }
        async.elapse(const Duration(seconds: 2));
      }
      expect(admitted, NearbyIngress.maxQueued);
      expect(delivered, isEmpty);
      subscription.resume();
      async.elapse(Duration.zero);
      expect(delivered.length, NearbyIngress.maxQueued);
      ingress.close();
    });
  });

  test(
    'source churn cannot evict active limits and recovers after inactivity',
    () {
      fakeAsync((async) {
        final ingress = NearbyIngress(now: () => async.elapsed);
        ingress.stream.listen((_) {});
        for (var source = 1; source <= NearbyIngress.maxSources; source++) {
          expect(ingress.add(packet(source)), isTrue);
          async.elapse(Duration.zero);
        }
        async.elapse(const Duration(seconds: 1));
        for (var source = 1000; source < 10000; source++) {
          expect(ingress.add(packet(source)), isFalse);
        }
        expect(
          ingress.add(packet(1)),
          isTrue,
          reason: 'existing sources retain their budget and table entry',
        );
        async.elapse(const Duration(seconds: 2));
        expect(ingress.add(packet(10000)), isTrue);
        ingress.close();
      });
    },
  );

  test('delivery batches yield to timers during overload', () {
    fakeAsync((async) {
      final ingress = NearbyIngress(now: () => async.elapsed);
      var delivered = 0;
      ingress.stream.listen((_) => delivered++);
      for (var source = 1; source <= NearbyIngress.maxQueued; source++) {
        expect(ingress.add(packet(source)), isTrue);
      }
      var seenAtYield = 0;
      Timer(Duration.zero, () => seenAtYield = delivered);
      async.elapse(Duration.zero);
      expect(seenAtYield, inInclusiveRange(1, NearbyIngress.batchSize));
      expect(delivered, NearbyIngress.maxQueued);
      ingress.close();
    });
  });

  test(
    'pause and close from a delivery callback discard pending work safely',
    () {
      fakeAsync((async) {
        final ingress = NearbyIngress(now: () => async.elapsed);
        var delivered = 0;
        late StreamSubscription<NearbyDatagram> subscription;
        subscription = ingress.stream.listen((_) {
          delivered++;
          subscription.pause();
        });
        for (var source = 1; source <= 64; source++) {
          expect(ingress.add(packet(source)), isTrue);
        }
        async.elapse(Duration.zero);
        expect(delivered, 1);
        subscription.onData((_) {
          delivered++;
          ingress.close();
        });
        subscription.resume();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(delivered, 2);
        expect(ingress.add(packet(100)), isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('64 normal peers refresh, bye and stop after a flood', () {
    fakeAsync((async) {
      final ingress = NearbyIngress(now: () => async.elapsed);
      final controller = NearbyController(
        transport: IngressTransport(ingress),
        now: () => DateTime(2026).add(async.elapsed),
      );
      controller.start();
      async.flushMicrotasks();
      for (var round = 0; round < 8; round++) {
        for (var source = 1; source <= 64; source++) {
          expect(ingress.add(packet(source)), isTrue);
        }
        async.elapse(Duration.zero);
        expect(controller.peers.length, 64);
        for (final peer in controller.peers) {
          expect(peer.lastSeen, DateTime(2026).add(async.elapsed));
        }
        async.elapse(NearbyController.announceInterval);
      }
      for (var i = 0; i < 10000; i++) {
        ingress.add(packet(100, data: Uint8List.fromList([0xff])));
      }
      for (var source = 1; source <= 64; source++) {
        expect(ingress.add(packet(source)), isTrue);
      }
      async.elapse(Duration.zero);
      expect(controller.peers.length, 64);
      expect(
        ingress.add(packet(1, data: NearbyProtocol.encodeBye(id(1))!)),
        isTrue,
      );
      async.elapse(Duration.zero);
      expect(controller.peers.length, 63);
      controller.stop();
      async.flushMicrotasks();
      expect(controller.peers, isEmpty);
      expect(ingress.add(packet(2)), isFalse);
      controller.dispose();
    });
  });

  test('empty and oversize datagrams consume admission without queuing', () {
    fakeAsync((async) {
      final ingress = NearbyIngress(now: () => async.elapsed);
      var delivered = 0;
      ingress.stream.listen((_) => delivered++);
      for (var i = 0; i < NearbyIngress.sourceBurst; i++) {
        expect(
          ingress.add(
            packet(
              1,
              data: Uint8List(
                i.isEven ? 0 : NearbyProtocol.maxDatagramBytes + 1,
              ),
            ),
          ),
          isFalse,
        );
      }
      expect(ingress.add(packet(1)), isFalse);
      expect(ingress.add(packet(2)), isTrue);
      async.elapse(Duration.zero);
      expect(delivered, 1);
      ingress.close();
    });
  });
}
