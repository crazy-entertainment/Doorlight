import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/identity_color.dart';
import 'package:sybl/state/presence_color_cache.dart';

void main() {
  test('a flood coalesces to the latest color and serializes slow writes', () {
    fakeAsync((time) {
      final writes = <(String, IdentityColor)>[];
      final first = Completer<void>();
      final cache = PresenceColorCache(
        write: (peer, color) {
          writes.add((peer, color));
          return writes.length == 1 ? first.future : Future.value();
        },
        remove: (_) async {},
        onError: (error, stack) => fail('$error'),
      );
      cache.update('peer', IdentityColor.amber);
      for (var i = 0; i < 10000; i++) {
        cache.update('peer', IdentityColor.values[i % 8]);
      }
      cache.update('peer', IdentityColor.teal);
      time.elapse(const Duration(seconds: 30));
      expect(writes, [('peer', IdentityColor.amber)]);
      first.complete();
      time.flushMicrotasks();
      expect(writes.last, ('peer', IdentityColor.teal));
      expect(writes.length, 2);
      cache.update('friend', IdentityColor.sage);
      time.elapse(PresenceColorCache.writeInterval);
      expect(writes.last, ('friend', IdentityColor.sage));
      cache.dispose();
    });
  });

  test('many peers cannot grow persistence work without bound', () {
    fakeAsync((time) {
      var writes = 0;
      final cache = PresenceColorCache(
        write: (_, _) async {
          writes++;
        },
        remove: (_) async {},
        onError: (error, stack) => fail('$error'),
      );
      for (var i = 0; i < 10000; i++) {
        cache.update('peer-$i', IdentityColor.sky);
      }
      time.flushMicrotasks();
      expect(writes, 1);
      time.elapse(const Duration(seconds: 100));
      expect(writes, 1 + PresenceColorCache.maxPendingPeers);
      cache.dispose();
    });
  });

  test('removal waits for an existing write and retires queued colors', () {
    fakeAsync((time) {
      final pending = Completer<void>();
      var writes = 0;
      var removed = false;
      final cache = PresenceColorCache(
        write: (_, _) {
          writes++;
          return pending.future;
        },
        remove: (_) async {},
        onError: (error, stack) => fail('$error'),
      );
      cache.update('peer', IdentityColor.rose);
      cache.update('peer', IdentityColor.teal);
      cache.forget('peer').then((_) {
        removed = true;
      });
      time.flushMicrotasks();
      expect(removed, isFalse);
      pending.complete();
      time.flushMicrotasks();
      expect(removed, isTrue);
      time.elapse(const Duration(seconds: 10));
      expect(writes, 1);
      cache.dispose();
    });
  });

  test('a new relationship writes only after the old color is removed', () {
    fakeAsync((time) {
      final first = Completer<void>();
      final events = <String>[];
      final cache = PresenceColorCache(
        write: (_, color) {
          events.add('write:${color.storageValue}');
          return color == IdentityColor.amber ? first.future : Future.value();
        },
        remove: (_) async {
          events.add('remove');
        },
        onError: (error, stack) => fail('$error'),
      );
      cache.update('peer', IdentityColor.amber);
      cache.forget('peer');
      expect(cache.isRetiring('peer'), isTrue);
      cache.update('peer', IdentityColor.teal);
      time.elapse(const Duration(seconds: 3));
      expect(events, ['write:amber']);
      first.complete();
      time.flushMicrotasks();
      expect(events, ['write:amber', 'remove', 'write:teal']);
      expect(cache.isRetiring('peer'), isFalse);
      cache.dispose();
    });
  });
}
