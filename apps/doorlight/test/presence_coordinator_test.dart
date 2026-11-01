import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/presence_coordinator.dart';

void main() {
  const peer = 'peer';
  late _PresenceHarness harness;

  setUp(() => harness = _PresenceHarness(peer));
  tearDown(() => harness.coordinator.dispose());

  test(
    'a terminal event between native completion and ID correlation survives',
    () async {
      final refresh = harness.coordinator.refresh(peer);
      final delivered = Completer<void>();
      harness.probes.single.complete('just-returned-id');
      scheduleMicrotask(() {
        expect(
          harness.coordinator.handleMessageStatus(peer, 'just-returned-id', 3),
          isTrue,
        );
        delivered.complete();
      });
      await refresh;
      await delivered.future;
      expect(harness.presence, PeerPresence.reachable);
    },
  );

  test('a hung native send expires without accumulating native sends', () {
    fakeAsync((clock) {
      var completed = false;
      harness.coordinator.refresh(peer).then((_) => completed = true);
      clock.elapse(const Duration(seconds: 9));
      expect(harness.presence, PeerPresence.unknown);
      clock.elapse(const Duration(seconds: 1));
      expect(harness.presence, PeerPresence.unreachable);
      expect(completed, isTrue);
      harness.coordinator.refresh(peer);
      expect(harness.probeCalls, 1);

      harness.probes.single.complete('late-id');
      clock.flushMicrotasks();
      expect(
        harness.coordinator.handleMessageStatus(peer, 'late-id', 3),
        isFalse,
      );
      expect(harness.presence, PeerPresence.unreachable);
      harness.coordinator.refresh(peer);
      expect(harness.probeCalls, 2);
      harness.probes.last.complete('new-id');
      clock.flushMicrotasks();
      harness.coordinator.handleMessageStatus(peer, 'new-id', 3);
      expect(harness.presence, PeerPresence.reachable);
    });
  });

  test('a slow native send does not restart the reply deadline', () {
    fakeAsync((clock) {
      harness.coordinator.refresh(peer);
      clock.elapse(const Duration(seconds: 8));
      harness.probes.single.complete('slow-id');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 2));
      expect(harness.presence, PeerPresence.unreachable);
      expect(
        harness.coordinator.handleMessageStatus(peer, 'slow-id', 3),
        isFalse,
      );
    });
  });

  test(
    'fresh evidence cancels the deadline even while native send is hung',
    () {
      fakeAsync((clock) {
        harness.coordinator.refresh(peer);
        harness.presence = PeerPresence.reachable;
        harness.coordinator.recordEvidence(peer);
        clock.elapse(const Duration(seconds: 20));
        expect(harness.presence, PeerPresence.reachable);
        expect(harness.logs, isEmpty);
        harness.probes.single.completeError(StateError('late native failure'));
        clock.flushMicrotasks();
        expect(harness.presence, PeerPresence.reachable);
      });
    },
  );

  for (final gate in ['dark', 'background', 'call', 'forget', 'dispose']) {
    test(
      '$gate cancels the pending deadline without a false offline verdict',
      () {
        fakeAsync((clock) {
          harness.coordinator.refresh(peer);
          if (gate == 'forget') {
            harness.coordinator.forget(peer);
          } else if (gate == 'dispose') {
            harness.coordinator.dispose();
          } else {
            harness.coordinator.sync(
              peers: [peer],
              foreground: gate != 'background',
              dark: gate == 'dark',
              callActive: gate == 'call',
            );
          }
          clock.elapse(const Duration(seconds: 20));
          expect(harness.presence, PeerPresence.unknown);
          expect(harness.logs, isEmpty);
          harness.probes.single.complete('retired-id');
          clock.flushMicrotasks();
          expect(harness.presence, PeerPresence.unknown);
        });
      },
    );
  }

  test(
    'evidence before the native message id prevents a stale verdict',
    () async {
      final refresh = harness.coordinator.refresh(peer);
      expect(harness.probeCalls, 1);

      harness.presence = PeerPresence.reachable;
      harness.coordinator.recordEvidence(peer);
      harness.probes.single.complete('late-id');
      await refresh;

      expect(
        harness.coordinator.handleMessageStatus(peer, 'late-id', 4),
        isFalse,
      );
      expect(harness.presence, PeerPresence.reachable);
    },
  );

  test(
    'an early displayed status resolves only its returned message id',
    () async {
      final refresh = harness.coordinator.refresh(peer);
      expect(
        harness.coordinator.handleMessageStatus(peer, 'unrelated-id', 4),
        isTrue,
      );
      expect(
        harness.coordinator.handleMessageStatus(peer, 'displayed-id', 3),
        isTrue,
      );

      harness.probes.single.complete('displayed-id');
      await refresh;

      expect(harness.presence, PeerPresence.reachable);
      expect(
        harness.coordinator.handleMessageStatus(peer, 'displayed-id', 4),
        isFalse,
      );
    },
  );

  test('an early failure resolves after the matching id is returned', () async {
    final refresh = harness.coordinator.refresh(peer);
    expect(
      harness.coordinator.handleMessageStatus(peer, 'failed-id', 4),
      isTrue,
    );

    harness.probes.single.complete('failed-id');
    await refresh;

    expect(harness.presence, PeerPresence.unreachable);
    expect(
      harness.coordinator.handleMessageStatus(peer, 'failed-id', 3),
      isFalse,
    );
  });

  test(
    'a second refresh stays suppressed until the native send returns',
    () async {
      final first = harness.coordinator.refresh(peer);
      expect(harness.probeCalls, 1);

      harness.coordinator.recordEvidence(peer);
      await harness.coordinator.refresh(peer);
      expect(harness.probeCalls, 1);

      harness.probes.single.complete('retired-id');
      await first;

      final next = harness.coordinator.refresh(peer);
      expect(harness.probeCalls, 2);
      harness.probes.last.complete('next-id');
      await next;
    },
  );

  test(
    'an empty native id makes stale positive presence unreachable',
    () async {
      harness.presence = PeerPresence.inApp;
      final refresh = harness.coordinator.refresh(peer);

      harness.probes.single.complete('');
      await refresh;

      expect(harness.presence, PeerPresence.unreachable);
      expect(harness.sweepCalls, 1);
    },
  );

  test(
    'a thrown native probe makes stale positive presence unreachable',
    () async {
      harness.presence = PeerPresence.inApp;
      final refresh = harness.coordinator.refresh(peer);

      harness.probes.single.completeError(StateError('send failed'));
      await refresh;

      expect(harness.presence, PeerPresence.unreachable);
      expect(harness.sweepCalls, 1);
    },
  );

  test('an empty result after forget cannot mutate retired presence', () async {
    harness.presence = PeerPresence.inApp;
    final refresh = harness.coordinator.refresh(peer);
    harness.coordinator.forget(peer);

    harness.probes.single.complete('');
    await refresh;

    expect(harness.presence, PeerPresence.inApp);
    expect(harness.sweepCalls, 0);
  });

  test('a thrown result after dark cannot mutate retired presence', () async {
    harness.presence = PeerPresence.inApp;
    final refresh = harness.coordinator.refresh(peer);
    harness.coordinator.sync(
      peers: const [peer],
      foreground: true,
      dark: true,
      callActive: false,
    );

    harness.probes.single.completeError(StateError('late failure'));
    await refresh;

    expect(harness.presence, PeerPresence.inApp);
    expect(harness.sweepCalls, 0);
  });
}

class _PresenceHarness {
  _PresenceHarness(this.peer) {
    coordinator = PresenceCoordinator(
      (_) {
        probeCalls++;
        final probe = Completer<String>();
        probes.add(probe);
        return probe.future;
      },
      () async => sweepCalls++,
      (_) => presence,
      (_) => presence = PeerPresence.reachable,
      (_) => presence = PeerPresence.unreachable,
      logs.add,
    )..sync(peers: [peer], foreground: true, dark: false, callActive: false);
  }

  final String peer;
  final List<Completer<String>> probes = [];
  final List<String> logs = [];
  late final PresenceCoordinator coordinator;
  PeerPresence presence = PeerPresence.unknown;
  int probeCalls = 0;
  int sweepCalls = 0;
}
