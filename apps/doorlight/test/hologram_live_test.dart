import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/hologram_live.dart';

final peer = 'a' * 40;
final conversation = 'b' * 40;
final operation = 'c' * 32;
final commit = 'd' * 40;
const asset = 'sybl.chubby-cats.angry.v1';

class Harness {
  int clock = 0, sequence = 0;
  bool allowed = true;
  final sent = <({String peer, HologramPacket packet})>[];
  final shown = <HologramPresentation>[];
  late final live = HologramLive(
    now: () => clock,
    randomNonce: () => (++sequence).toRadixString(16).padLeft(32, '0'),
    eligible: (_, _) => allowed,
    assetEligible: (value) => value == asset,
    send: (peer, packet) => sent.add((peer: peer, packet: packet)),
    show: shown.add,
  );
  String prepare({String? op}) {
    live.receive(
      peer,
      HologramPacket('prepare', conversation, op ?? operation),
    );
    return sent.last.packet.nonce!;
  }

  void present(String nonce, {String? op, String? id}) => live.receive(
    peer,
    HologramPacket(
      'present',
      conversation,
      op ?? operation,
      nonce: nonce,
      commit: id ?? commit,
    ),
  );
  void durable({
    String? author,
    String? op,
    bool hologram = true,
    String image = asset,
  }) => live.liveCommit(
    author: author ?? peer,
    conversation: conversation,
    operation: op ?? operation,
    commit: commit,
    asset: image,
    hologram: hologram,
  );
}

void main() {
  test(
    'control parser rejects duplicate, unknown, oversized and malformed fields',
    () {
      final valid = HologramPacket('prepare', conversation, operation).encode();
      expect(HologramPacket.parse(valid)?.operation, operation);
      expect(
        HologramPacket.parse(valid.replaceFirst('"v":1', '"v":1,"v":1')),
        isNull,
      );
      expect(
        HologramPacket.parse(valid.replaceFirst('"v":1', '"v":1,"extra":0')),
        isNull,
      );
      expect(
        HologramPacket.parse(valid.replaceFirst('"v":1', '"v":1.0')),
        isNull,
      );
      expect(HologramPacket.parse(' ' * 1025), isNull);
      expect(
        HologramPacket.parse(
          HologramPacket(
            'ready',
            conversation,
            operation,
            nonce: 'bad',
          ).encode(),
        ),
        isNull,
      );
    },
  );

  for (final commitFirst in [true, false]) {
    test(
      'requires a fresh nonce and exact live commit, commitFirst=$commitFirst',
      () {
        final h = Harness();
        final nonce = h.prepare();
        if (commitFirst) {
          h.durable();
        } else {
          h.present(nonce);
        }
        expect(h.shown, isEmpty);
        if (commitFirst) {
          h.present(nonce);
        } else {
          h.durable();
        }
        expect(h.shown, hasLength(1));
        h.present(nonce);
        h.durable();
        expect(h.shown, hasLength(1));
        expect(h.live.isCurrent(h.shown.single), isTrue);
        h.clock = 3350;
        expect(h.live.isCurrent(h.shown.single), isFalse);
      },
    );
  }

  test(
    'history before prepare, expired and invalidated nonces never present',
    () {
      final h = Harness();
      h.durable();
      final nonce = h.prepare();
      h.present(nonce);
      expect(h.shown, isEmpty);
      h.clock = 5000;
      h.durable();
      expect(h.shown, isEmpty);
      final fresh = h.prepare();
      h.live.invalidate();
      h.present(fresh);
      h.durable();
      expect(h.shown, isEmpty);
    },
  );

  test('author, mode, asset and privacy must all remain eligible', () {
    final h = Harness();
    final nonce = h.prepare();
    h.present(nonce);
    h.durable(author: 'e' * 40);
    h.durable(hologram: false);
    h.durable(image: 'unknown');
    expect(h.shown, isEmpty);
    h.allowed = false;
    h.durable();
    expect(h.shown, isEmpty);
    h.live.invalidate();
    h.allowed = true;
    h.present(nonce);
    h.durable();
    expect(h.shown, isEmpty);
  });

  test(
    'readiness is capped at four, frozen before publication, and expires',
    () {
      final h = Harness();
      expect(h.live.begin(operation, conversation, [peer]), isTrue);
      expect(h.sent.single.packet.type, 'prepare');
      for (var index = 1; index <= 5; index++) {
        h.live.receive(
          peer,
          HologramPacket(
            'ready',
            conversation,
            operation,
            nonce: index.toRadixString(16).padLeft(32, '0'),
          ),
        );
      }
      h.clock = 1000;
      h.live.freeze(operation);
      h.live.receive(
        peer,
        HologramPacket('ready', conversation, operation, nonce: 'f' * 32),
      );
      h.live.committed(operation, commit);
      expect(
        h.sent.where((entry) => entry.packet.type == 'present'),
        hasLength(4),
      );
      h.live.committed(operation, commit);
      expect(h.sent, hasLength(5));
      expect(h.live.begin('e' * 32, conversation, [peer]), isTrue);
      h.clock = 6000;
      h.live.freeze('e' * 32);
      h.live.committed('e' * 32, commit);
      expect(h.sent, hasLength(6));
    },
  );

  test('late readiness cannot create a visual opportunity', () {
    final h = Harness();
    h.live.begin(operation, conversation, [peer]);
    h.clock = 1000;
    h.live.receive(
      peer,
      HologramPacket('ready', conversation, operation, nonce: 'f' * 32),
    );
    h.live.freeze(operation);
    h.live.committed(operation, commit);
    expect(h.sent, hasLength(1));
  });

  test(
    'bounded pending handshakes and cooldowns never queue presentations',
    () {
      final h = Harness();
      for (var index = 1; index <= 17; index++) {
        h.live.receive(
          peer,
          HologramPacket(
            'prepare',
            conversation,
            index.toRadixString(16).padLeft(32, '0'),
          ),
        );
      }
      expect(h.sent, hasLength(16));
      h.live.invalidate();
      final nonce = h.prepare();
      h.durable();
      h.present(nonce);
      final count = h.sent.length;
      h.clock = 4000;
      h.live.receive(peer, HologramPacket('prepare', conversation, 'e' * 32));
      expect(h.sent, hasLength(count));
      h.clock = 10000;
      h.live.receive(peer, HologramPacket('prepare', conversation, 'e' * 32));
      expect(h.sent, hasLength(count + 1));
      expect(h.shown, hasLength(1));
    },
  );
}
