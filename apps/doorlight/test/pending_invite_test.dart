import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/pending_invite.dart';

const _first = 'sybl://add/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?name=Mara';
const _second =
    'doorlight://add/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?name=Lee';
const _third = 'sybl://add/cccccccccccccccccccccccccccccccccccccccc?name=Sam';

void main() {
  test(
    'duplicate opens cannot restore a continuation during removal',
    () async {
      var now = DateTime.utc(2026, 9, 21);
      String? source;
      final removal = Completer<bool>();
      final store = PendingInviteStore(
        source: null,
        now: () => now,
        persist: (value) async {
          if (value == null && !await removal.future) return false;
          source = value;
          return true;
        },
      );
      addTearDown(store.dispose);
      store.stage(_first);
      await pumpEventQueue();
      final original = store.pending!;
      final clear = store.discard(original);
      await pumpEventQueue();
      now = now.add(const Duration(hours: 23));
      store.stage(_first);
      removal.complete(true);
      expect(await clear, isTrue);
      await pumpEventQueue();
      final restarted = PendingInviteStore(
        source: source,
        persist: (_) async => true,
        now: () => now,
      );
      addTearDown(restarted.dispose);
      expect(
        restarted.pending,
        isNull,
        reason: 'Removal must not be followed by replay of the same invitation',
      );
    },
  );

  test(
    'removal completion cannot admit an expired or disposed owner',
    () async {
      for (final dispose in [false, true]) {
        var now = DateTime.utc(2026, 9, 21);
        final removal = Completer<bool>();
        final store = PendingInviteStore(
          source: null,
          now: () => now,
          persist: (value) async => value != null || await removal.future,
        );
        store.stage(_first);
        final clear = store.discard(store.pending!);
        await pumpEventQueue();
        if (dispose) {
          store.dispose();
        } else {
          now = now.add(const Duration(hours: 24));
        }
        removal.complete(true);
        expect(await clear, isFalse);
        if (!dispose) store.dispose();
      }
    },
  );

  test(
    'restart retains one public hint without extending the deadline',
    () async {
      var now = DateTime.utc(2026, 9, 21);
      String? source;
      Future<bool> persist(String? value) async {
        source = value;
        return true;
      }

      final first = PendingInviteStore(
        source: null,
        persist: persist,
        now: () => now,
      );
      first.stage(_first);
      await pumpEventQueue();
      final saved = source;
      now = now.add(const Duration(hours: 23));
      first.stage(_first);
      await pumpEventQueue();
      expect(source, saved);
      first.dispose();
      final restored = PendingInviteStore(
        source: source,
        persist: persist,
        now: () => now,
      );
      addTearDown(restored.dispose);
      expect(restored.pending!.invite.displayName, 'Mara');
      now = now.add(const Duration(hours: 1));
      expect(restored.pending, isNull);
    },
  );

  test('a replacement stays memory-only and cannot be retargeted', () async {
    String? source;
    final store = PendingInviteStore(
      source: null,
      persist: (value) async {
        source = value;
        return true;
      },
    );
    addTearDown(store.dispose);
    store.stage(_first);
    final displayed = store.pending!;
    store.stage(_second);
    final replacement = store.replacement!;
    store.stage(_third);
    await pumpEventQueue();
    expect(store.pending, same(displayed));
    expect(store.replacement, same(replacement));
    expect(jsonDecode(source!)['link'], _first);
    expect(store.acceptReplacement(replacement, null), isFalse);
    expect(store.acceptReplacement(replacement, displayed), isTrue);
    await pumpEventQueue();
    expect(store.pending!.invite.displayName, 'Lee');
    expect(source, isNot(contains('Sam')));
    expect(store.replacement, isNull);
    expect(await store.discard(displayed), isFalse);
    expect(store.pending!.invite.displayName, 'Lee');
  });

  test(
    'writes serialize and durable removal precedes request admission',
    () async {
      final write = Completer<bool>();
      final writes = <String?>[];
      final store = PendingInviteStore(
        source: null,
        persist: (value) async {
          writes.add(value);
          return writes.length == 1 ? write.future : true;
        },
      );
      addTearDown(store.dispose);
      store.stage(_first);
      final record = store.pending!;
      var completed = false;
      final clear = store.discard(record).then((result) {
        completed = true;
        return result;
      });
      await pumpEventQueue();
      expect(writes, hasLength(1));
      expect(completed, isFalse);
      write.complete(true);
      expect(await clear, isTrue);
      expect(writes, hasLength(2));
      expect(writes.last, isNull);
    },
  );

  test(
    'failed removal remains visible and cannot authorize a request',
    () async {
      final store = PendingInviteStore(
        source: null,
        persist: (value) async => value != null,
      );
      addTearDown(store.dispose);
      store.stage(_first);
      final record = store.pending!;
      expect(await store.discard(record), isFalse);
      expect(store.pending, same(record));
      expect(store.persistenceFailed, isTrue);
    },
  );

  test(
    'rejected storage errors never escape with invitation contents',
    () async {
      final store = PendingInviteStore(
        source: null,
        persist: (_) async => throw StateError('private'),
      );
      addTearDown(store.dispose);
      store.stage(_first);
      expect(await store.discard(store.pending!), isFalse);
      expect(store.persistenceFailed, isTrue);
    },
  );

  test(
    'corrupt, future, expired and oversized records cannot resume',
    () async {
      final now = DateTime.utc(2026, 9, 21);
      String record(Object version, Object time, {String link = _first}) =>
          jsonEncode({'version': version, 'receivedAt': time, 'link': link});
      for (final source in <Object>[
        42,
        '{',
        'x' * 2049,
        record(2, now.millisecondsSinceEpoch),
        record(1.0, now.millisecondsSinceEpoch),
        record(1, now.add(const Duration(seconds: 1)).millisecondsSinceEpoch),
        record(
          1,
          now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch,
        ),
        record(1, 'yesterday'),
        record(1, now.millisecondsSinceEpoch, link: 'sybl://add/invalid'),
        record(1, 999999999999999999),
      ]) {
        final store = PendingInviteStore(
          source: source,
          persist: (_) async => true,
          now: () => now,
        );
        expect(store.pending, isNull);
        store.dispose();
      }
      await pumpEventQueue();
    },
  );

  testWidgets(
    '24-hour expiry removes the on-screen continuation and stored hint',
    (tester) async {
      final start = tester.binding.clock.now();
      String? source;
      final store = PendingInviteStore(
        source: null,
        now: tester.binding.clock.now,
        persist: (value) async {
          source = value;
          return true;
        },
      );
      addTearDown(store.dispose);
      store.stage(_first);
      await tester.pump();
      expect(store.pending!.receivedAt, start);
      await tester.pump(const Duration(hours: 24));
      expect(store.pending, isNull);
      expect(source, isNull);
    },
  );
}
