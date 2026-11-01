import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/nearby.dart';

final String own = 'a' * 40;
final String peerA = 'b' * 40;
final String peerB = 'c' * 40;

Uint8List json(Object value) => utf8.encode(jsonEncode(value));

Uint8List missile(String from, String at, int permille, [int level = 6]) =>
    NearbyProtocol.encodeMissile(from, at, permille, level)!;

class _Transport implements NearbyTransport {
  final List<NearbyPacket?> sent = [];
  StreamController<NearbyDatagram>? incoming;
  Completer<void>? sendGate;
  bool failSend = false;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    incoming = StreamController<NearbyDatagram>();
    return incoming!.stream;
  }

  @override
  Future<void> send(Uint8List data) async {
    await sendGate?.future;
    if (failSend) throw StateError('send failed');
    sent.add(NearbyProtocol.decode(data));
  }

  @override
  Future<void> stop() async {
    unawaited(incoming?.close());
    incoming = null;
  }

  int get announcements => sent.whereType<NearbyAnnouncement>().length;
  int get byes => sent.whereType<NearbyBye>().length;
  List<NearbyMissile> get missiles => sent.whereType<NearbyMissile>().toList();
}

void main() {
  group('missile codec', () {
    test('round-trips shooter, target, damage and level', () {
      final packet = NearbyProtocol.decode(missile(peerA, own, 425, 4));
      expect(
        packet,
        isA<NearbyMissile>()
            .having((m) => m.id, 'id', peerA)
            .having((m) => m.at, 'at', own)
            .having((m) => m.permille, 'permille', 425)
            .having((m) => m.level, 'level', 4),
      );
      expect(utf8.decode(missile(peerA, own, 200, 0)).length, lessThan(512));
    });

    test('rejects every malformed or out-of-bounds missile', () {
      Map<String, Object?> base() => {
        'doorlight': 1,
        'id': peerA,
        'at': own,
        'missile': 300,
        'lvl': 2,
      };
      final cases = <String, Map<String, Object?>>{
        'missing lvl': base()..remove('lvl'),
        'missing at': base()..remove('at'),
        'missing missile': base()..remove('missile'),
        'lvl -1': base()..['lvl'] = -1,
        'lvl 7': base()..['lvl'] = 7,
        'lvl string': base()..['lvl'] = '2',
        'lvl double': base()..['lvl'] = 2.5,
        'permille 199': base()..['missile'] = 199,
        'permille over level 0 max': base()
          ..['lvl'] = 0
          ..['missile'] = 251,
        'permille over level 2 max': base()..['missile'] = 351,
        'permille 551': base()
          ..['lvl'] = 6
          ..['missile'] = 551,
        'permille double': base()..['missile'] = 300.5,
        'permille bool': base()..['missile'] = true,
        'at uppercase': base()..['at'] = own.toUpperCase(),
        'at short': base()..['at'] = 'a' * 39,
        'self target': base()..['at'] = peerA,
        'unknown key': base()..['extra'] = 1,
        'plus name': base()..['name'] = 'x',
        'version 2': base()..['doorlight'] = 2,
      };
      for (final entry in cases.entries) {
        expect(
          NearbyProtocol.decode(json(entry.value)),
          isNull,
          reason: entry.key,
        );
      }
      expect(NearbyProtocol.decode(json(base())), isA<NearbyMissile>());
      // The ceiling of each level is itself valid.
      for (var level = 0; level <= 6; level++) {
        expect(
          NearbyProtocol.decode(
            json(
              base()
                ..['lvl'] = level
                ..['missile'] = 250 + 50 * level,
            ),
          ),
          isA<NearbyMissile>(),
          reason: 'level $level',
        );
      }
    });

    test('encoder refuses what the decoder would reject', () {
      expect(NearbyProtocol.encodeMissile(peerA, own, 199, 0), isNull);
      expect(NearbyProtocol.encodeMissile(peerA, own, 251, 0), isNull);
      expect(NearbyProtocol.encodeMissile(peerA, own, 300, 7), isNull);
      expect(NearbyProtocol.encodeMissile(peerA, own, 300, -1), isNull);
      expect(NearbyProtocol.encodeMissile(peerA, peerA, 300, 2), isNull);
      expect(NearbyProtocol.encodeMissile('jami:$peerA', own, 300, 2), isNull);
      expect(NearbyProtocol.encodeMissile(peerA, '', 300, 2), isNull);
    });
  });

  group('combat math', () {
    test('ten taps earn a bracket and good aim reduces failure odds', () {
      expect([0, 9, 10, 19, 20, 30].map(SonarCombat.brackets), [
        1,
        1,
        2,
        2,
        3,
        4,
      ]);
      expect(SonarCombat.lossChance(6), lessThan(SonarCombat.lossChance(0)));
      expect(
        SonarCombat.collisionChance(6, 6),
        lessThan(SonarCombat.collisionChance(0, 0)),
      );
      const a = '000001f400000000', b = '000001f400000010';
      expect(SonarCombat.losesTarget('0000000000000000', 0), isTrue);
      expect(SonarCombat.losesTarget(a, 0), isFalse);
      expect(SonarCombat.collide(a, 0, b, 6), SonarCombat.collide(b, 6, a, 0));
      expect(
        SonarCombat.rearm,
        greaterThanOrEqualTo(SonarCombat.deathDuration),
      );
    });
    test('level comes from taps in the charge window', () {
      final levels = {
        for (final taps in [0, 1, 5, 9, 10, 11, 12, 14, 16, 18, 19, 20, 30])
          taps: SonarCombat.level(taps),
      };
      expect(levels, {
        0: 0,
        1: 0,
        5: 0,
        9: 0,
        10: 1,
        11: 1,
        12: 2,
        14: 3,
        16: 4,
        18: 5,
        19: 5,
        20: 6,
        30: 6,
      });
    });

    test('damage rolls stay inside each level and reach both ends', () {
      final random = math.Random(7);
      for (var level = 0; level <= 6; level++) {
        final rolls = [
          for (var i = 0; i < 4000; i++) SonarCombat.roll(level, random),
        ];
        expect(rolls.reduce(math.min), 200, reason: 'level $level');
        expect(rolls.reduce(math.max), 250 + 50 * level, reason: '$level');
      }
    });

    test('flight is slow and bowed at level 0, fast and flat at 6', () {
      expect(SonarCombat.flight(0), const Duration(milliseconds: 6000));
      expect(SonarCombat.flight(6), const Duration(milliseconds: 2500));
      expect(SonarCombat.bow(0), SonarCombat.wideBow);
      expect(SonarCombat.bow(6), SonarCombat.flatBow);
      for (var level = 1; level <= 6; level++) {
        expect(
          SonarCombat.flight(level),
          lessThan(SonarCombat.flight(level - 1)),
        );
        expect(SonarCombat.bow(level), lessThan(SonarCombat.bow(level - 1)));
      }
    });
  });

  group('controller combat', () {
    late _Transport transport;
    late NearbyController controller;
    late List<SonarEvent> cues;
    late DateTime epoch;
    late FakeAsync clock;

    void withController(void Function(FakeAsync async) body) {
      fakeAsync((async) {
        epoch = DateTime.utc(2026, 10);
        transport = _Transport();
        cues = [];
        controller = NearbyController(
          transport: transport,
          ownId: own,
          ownName: 'Me',
          now: () => epoch.add(async.elapsed),
          random: math.Random(3),
        );
        controller.combat.listen(cues.add);
        clock = async;
        controller.start();
        async.flushMicrotasks();
        body(async);
        controller.dispose();
        async.flushMicrotasks();
      });
    }

    void deliver(FakeAsync async, Uint8List data) {
      transport.incoming!.add((
        data: data,
        sender: InternetAddress.loopbackIPv4,
      ));
      async.flushMicrotasks();
    }

    Iterable<SonarCue> kinds() {
      clock.flushMicrotasks();
      return cues.map((cue) => cue.cue);
    }

    test('a missile aimed at someone else does nothing', () {
      withController((async) {
        controller.goVisible();
        final until = controller.visibleUntil;
        deliver(async, missile(peerA, peerB, 550));
        expect(controller.incoming, 0);
        async.elapse(const Duration(seconds: 7));
        expect(controller.visibleUntil, until);
        expect(kinds(), isNot(contains(SonarCue.incoming)));
      });
    });

    test('a hidden device ignores missiles', () {
      withController((async) {
        deliver(async, missile(peerA, own, 550));
        expect(controller.incoming, 0);
        async.elapse(const Duration(seconds: 7));
        expect(kinds(), isEmpty);
        expect(controller.destroyed, isFalse);
      });
    });

    test(
      'manual shutdown preserves an incoming shot and makes its hit fatal',
      () {
        withController((async) {
          controller.goVisible();
          deliver(async, missile(peerA, own, 200));
          controller.shutdown();
          expect(controller.visible, isFalse);
          expect(controller.incoming, 1);
          expect(kinds(), contains(SonarCue.shutdown));
          async.elapse(SonarCombat.flight(6));
          expect(controller.destroyed, isTrue);
          expect(kinds(), contains(SonarCue.destroyed));
          async.elapse(SonarCombat.deathDuration);
          expect(controller.destroyed, isFalse);
        });
      },
    );

    test('a lost incoming missile never hits or destroys after shutdown', () {
      withController((async) {
        controller.goVisible();
        deliver(
          async,
          NearbyProtocol.encodeMissile(
            peerA,
            own,
            200,
            0,
            nonce: '0000000000000000',
          )!,
        );
        controller.shutdown();
        async.elapse(SonarCombat.flight(0));
        expect(controller.incoming, 0);
        expect(controller.destroyed, isFalse);
        expect(kinds(), contains(SonarCue.targetLost));
        expect(kinds(), isNot(contains(SonarCue.destroyed)));
        expect(
          cues.singleWhere((e) => e.cue == SonarCue.targetLost).inbound,
          isTrue,
        );
      });
    });

    test('opposing missiles can collide without either dealing damage', () {
      withController((async) {
        controller.goVisible();
        final until = controller.visibleUntil;
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        for (var i = 0; i < 12; i++) {
          controller.aim(peerA);
        }
        async.elapse(SonarCombat.chargeWindow);
        final out = transport.missiles.single;
        expect(SonarCombat.losesTarget(out.nonce, out.level), isFalse);
        final nonce =
            [
              for (var i = 500; i < 10000; i++)
                '${i.toRadixString(16).padLeft(8, '0')}00000000',
            ].firstWhere(
              (n) =>
                  !SonarCombat.losesTarget(n, 0) &&
                  SonarCombat.collide(out.nonce!, out.level, n, 0),
            );
        deliver(
          async,
          NearbyProtocol.encodeMissile(peerA, own, 200, 0, nonce: nonce)!,
        );
        async.elapse(SonarCombat.flight(0));
        expect(kinds(), contains(SonarCue.collision));
        expect(kinds(), isNot(contains(SonarCue.impact)));
        expect(kinds(), isNot(contains(SonarCue.hit)));
        expect(controller.visibleUntil, until);
        expect(controller.incoming, 0);
        expect(controller.missileInFlight, isFalse);
      });
    });

    test('a hit lands at receipt plus the flight for its level', () {
      for (final level in [0, 3, 6]) {
        withController((async) {
          controller.goVisible();
          final until = controller.visibleUntil!;
          deliver(async, missile(peerA, own, 250, level));
          expect(controller.incoming, 1);
          final flight = SonarCombat.flight(level);
          async.elapse(flight - const Duration(milliseconds: 1));
          expect(controller.visibleUntil, until, reason: 'level $level');
          expect(kinds(), contains(SonarCue.incomingClose));
          async.elapse(const Duration(milliseconds: 1));
          // 250 ‰ of 5:00 is 75 s.
          expect(
            controller.visibleUntil,
            until.subtract(const Duration(seconds: 75)),
          );
          expect(controller.lastHit!.lost, const Duration(seconds: 75));
          expect(kinds().last, SonarCue.hit);
          expect(cues.last.low, isFalse);
        });
      }
    });

    test('the incoming-close warning plays just before impact', () {
      withController((async) {
        controller.goVisible();
        deliver(async, missile(peerA, own, 300, 6));
        async.elapse(
          SonarCombat.flight(6) -
              SonarCombat.closeWarning -
              const Duration(milliseconds: 1),
        );
        expect(kinds(), [SonarCue.incoming]);
        expect(controller.incomingClose, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(kinds(), [SonarCue.incoming, SonarCue.incomingClose]);
        expect(controller.incomingClose, isTrue);
        deliver(async, missile(peerB, own, 200, 0));
        expect(
          controller.incomingClose,
          isTrue,
          reason: 'a farther missile cannot mute the closer warning',
        );
        async.elapse(SonarCombat.closeWarning);
        expect(controller.incoming, 1);
        expect(controller.incomingClose, isFalse);
      });
    });

    test('one missile per shooter per 2 s, and a bound on all of them', () {
      withController((async) {
        controller.goVisible();
        deliver(async, missile(peerA, own, 200));
        deliver(async, missile(peerA, own, 200));
        expect(controller.incoming, 1);
        async.elapse(const Duration(milliseconds: 1999));
        deliver(async, missile(peerA, own, 200));
        expect(controller.incoming, 1);
        async.elapse(const Duration(milliseconds: 1));
        deliver(async, missile(peerA, own, 200));
        expect(controller.incoming, 2);
      });
      withController((async) {
        controller.goVisible();
        for (var i = 0; i < SonarCombat.maxIncoming + 3; i++) {
          deliver(
            async,
            missile(i.toRadixString(16).padLeft(40, '0'), own, 200),
          );
        }
        expect(controller.incoming, SonarCombat.maxIncoming);
      });
    });

    test('a lethal hit ends visibility, re-arms after 10 s, never '
        're-announces', () {
      withController((async) {
        controller.goVisible();
        // 3:00 left, then 2 × 550 ‰ (2:45 each) empties it.
        async.elapse(const Duration(minutes: 2));
        deliver(async, missile(peerA, own, 550));
        async.elapse(SonarCombat.flight(6));
        expect(controller.visible, isTrue);
        expect(cues.last.low, isTrue, reason: '0:15 left is low');
        async.elapse(const Duration(seconds: 1));
        deliver(async, missile(peerA, own, 550));
        expect(controller.incoming, 1);
        async.elapse(SonarCombat.flight(6));
        expect(controller.visible, isFalse);
        expect(controller.destroyed, isTrue);
        expect(transport.sent.last, isA<NearbyBye>());
        expect(kinds(), contains(SonarCue.destroyed));
        final announced = transport.announcements;

        expect(controller.goVisible(), isFalse, reason: 'cracked');
        deliver(async, missile(peerB, own, 550));
        expect(controller.incoming, 0, reason: 'destroyed ignores missiles');
        async.elapse(SonarCombat.rearm - const Duration(milliseconds: 1));
        expect(controller.goVisible(), isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.destroyed, isFalse);
        expect(kinds().last, SonarCue.rearmed);
        async.elapse(const Duration(seconds: 30));
        expect(transport.announcements, announced, reason: 'no auto reveal');
        expect(controller.visible, isFalse);
        expect(controller.goVisible(), isTrue, reason: 'a fresh hold works');
      });
    });

    test('aiming needs a heard target and one shot at a time', () {
      withController((async) {
        expect(controller.aim(peerA), isFalse, reason: 'not heard');
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        deliver(async, NearbyProtocol.encodeAnnouncement(peerB, 'B')!);
        expect(controller.aim(own), isFalse);
        expect(controller.aim(peerA), isTrue);
        expect(controller.chargeTarget, peerA);
        expect(controller.aim(peerB), isFalse, reason: 'already charging');
        for (var i = 1; i < 12; i++) {
          expect(controller.aim(peerA), isTrue);
        }
        expect(controller.chargeTaps, 12);
        async.elapse(SonarCombat.chargeWindow);
        expect(controller.chargeTarget, isNull);
        final shot = transport.missiles.single;
        expect(shot.at, peerA);
        expect(shot.level, 2, reason: '12 taps in 2 s');
        expect(shot.permille, inInclusiveRange(200, 350));
        expect(controller.missileInFlight, isTrue);
        expect(controller.aim(peerB), isFalse, reason: 'missile in flight');
        // Keep the targets heard through the flight.
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        deliver(async, NearbyProtocol.encodeAnnouncement(peerB, 'B')!);
        async.elapse(SonarCombat.flight(2));
        expect(kinds(), contains(SonarCue.impact));
        expect(controller.aim(peerB), isTrue);
      });
    });

    test('firing while hidden reveals for exactly 15 s', () {
      withController((async) {
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        final launched = epoch.add(SonarCombat.chargeWindow);
        expect(controller.visibleUntil, launched.add(SonarCombat.fireReveal));
        expect(transport.sent.first, isA<NearbyAnnouncement>());
        expect(transport.sent[1], isA<NearbyMissile>());
        async.elapse(SonarCombat.fireReveal - const Duration(milliseconds: 1));
        expect(controller.visible, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.visible, isFalse);
        expect(transport.sent.last, isA<NearbyBye>());
      });
    });

    test('closing Sonar drops a charge, so it never fires or reveals', () {
      withController((async) {
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.watch();
        expect(controller.aim(peerA), isTrue);
        controller.unwatch();
        expect(controller.chargeTarget, isNull);
        async.elapse(SonarCombat.chargeWindow * 2);
        expect(controller.visible, isFalse);
        expect(transport.sent, isEmpty);
      });
    });

    test('firing while visible keeps the window', () {
      withController((async) {
        controller.goVisible();
        final until = controller.visibleUntil;
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        expect(controller.visibleUntil, until);
      });
    });

    test('rejected launch has no launch or impact cue', () {
      withController((async) {
        controller.goVisible();
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        transport.failSend = true;
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        expect(controller.missileInFlight, isFalse);
        expect(controller.sendError, 'Nearby send failed');
        expect(kinds(), isNot(contains(SonarCue.launched)));
        async.elapse(SonarCombat.flight(0));
        expect(kinds(), isNot(contains(SonarCue.impact)));
      });
    });

    test('hiding before send completion cancels the local missile', () {
      withController((async) {
        controller.goVisible();
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        transport.sendGate = Completer<void>();
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        expect(controller.missileInFlight, isTrue);
        controller.endVisible();
        transport.sendGate!.complete();
        async.flushMicrotasks();
        expect(controller.missileInFlight, isFalse);
        expect(kinds(), isNot(contains(SonarCue.launched)));
        expect(kinds(), isNot(contains(SonarCue.impact)));
      });
    });

    test('the target going dark right after impact counts as sunk', () {
      withController((async) {
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        async.elapse(const Duration(seconds: 3));
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        async.elapse(SonarCombat.flight(0) - const Duration(seconds: 3));
        expect(kinds(), isNot(contains(SonarCue.sunk)));
        async.elapse(const Duration(milliseconds: 300));
        deliver(async, NearbyProtocol.encodeBye(peerA)!);
        expect(kinds(), contains(SonarCue.sunk));
      });
      withController((async) {
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        async.elapse(const Duration(seconds: 3));
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        async.elapse(SonarCombat.flight(0) - const Duration(seconds: 3));
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        async.elapse(const Duration(seconds: 2));
        deliver(async, NearbyProtocol.encodeBye(peerA)!);
        expect(kinds(), isNot(contains(SonarCue.sunk)));
      });
    });

    test('ambience plays only while trading fire with Sonar open', () {
      withController((async) {
        controller.goVisible();
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        deliver(async, missile(peerA, own, 200));
        expect(controller.ambience, isFalse, reason: 'Sonar is closed');
        controller.watch();
        expect(controller.ambience, isTrue);
        expect(kinds().last, SonarCue.ambienceOn);
        controller.unwatch();
        expect(controller.ambience, isFalse);
        expect(kinds().last, SonarCue.ambienceOff);
        controller.watch();
        expect(controller.ambience, isTrue);
        // The exchange lapses 60 s after the older of the two shots.
        async.elapse(SonarCombat.engagement - const Duration(milliseconds: 1));
        expect(controller.ambience, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.ambience, isFalse);
        expect(kinds().last, SonarCue.ambienceOff);
      });
    });

    test('ambience needs both directions and stops when destroyed', () {
      withController((async) {
        controller
          ..watch()
          ..goVisible();
        deliver(async, missile(peerA, own, 200));
        expect(controller.ambience, isFalse, reason: 'only they fired');
        async.elapse(const Duration(seconds: 3));
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        expect(controller.ambience, isTrue);
        // 3:55 left; two 550 hits (2:45 each) empty it.
        deliver(async, missile(peerA, own, 550));
        async.elapse(SonarCombat.flight(6));
        deliver(async, missile(peerA, own, 550));
        async.elapse(SonarCombat.flight(6));
        expect(controller.destroyed, isTrue);
        expect(controller.ambience, isFalse);
      });
    });

    test('stopping Nearby ends a missile in flight and the ambience', () {
      withController((async) {
        controller
          ..watch()
          ..goVisible();
        deliver(async, missile(peerA, own, 200));
        deliver(async, NearbyProtocol.encodeAnnouncement(peerA, 'A')!);
        controller.aim(peerA);
        async.elapse(SonarCombat.chargeWindow);
        expect(controller.ambience, isTrue);
        controller.stop();
        async.flushMicrotasks();
        expect(controller.missileInFlight, isFalse);
        expect(controller.incoming, 0);
        expect(
          kinds(),
          containsAll([SonarCue.missileGone, SonarCue.ambienceOff]),
        );
      });
    });
  });
}
