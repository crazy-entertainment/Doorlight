import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sybl/state/appearance_bridge.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _Store extends InMemorySharedPreferencesStore {
  _Store() : super.withData({});
  bool reject = false;
  Completer<void>? hold;
  int writes = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.appSettings') {
      writes++;
      await hold?.future;
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}

Future<(AppState, AppearanceBridge, _Store)> _boot() async {
  SharedPreferences.setMockInitialValues({});
  final store = _Store();
  SharedPreferencesStorePlatform.instance = store;
  final state = AppState(FakeJami(), await SharedPreferences.getInstance());
  addTearDown(state.dispose);
  await state.init();
  final bridge = AppearanceBridge(
    state,
    epoch: 'f5911e61-0e15-48d3-9440-1147e200b4aa',
  );
  addTearDown(bridge.dispose);
  return (state, bridge, store);
}

String _patch(
  AppearanceBridge bridge,
  Map<String, Object> patch, {
  Map<String, Object>? snapshot,
}) {
  final base = snapshot ?? bridge.snapshot;
  return jsonEncode({
    'v': 1,
    'type': 'patch',
    'id': 'request-1',
    'epoch': base['epoch'],
    'revision': base['revision'],
    'patch': patch,
  });
}

Map<String, dynamic> _decode(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final throwing in [false, true]) {
    test(
      'an older failed publication cannot discard the newest snapshot: throw=$throwing',
      () async {
        final (state, bridge, _) = await _boot();
        const channel = MethodChannel('syb.l/appearance_bridge');
        final first = Completer<bool>();
        final published = <Map<String, dynamic>>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              published.add(_decode(call.arguments as String));
              if (published.length == 1) return first.future;
              return true;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        bridge.start();
        await pumpEventQueue();
        await state.setVibeOpacity(38);
        await state.setVibeOpacity(100);
        if (throwing) {
          first.completeError(PlatformException(code: 'synthetic'));
        } else {
          first.complete(false);
        }
        await pumpEventQueue();
        expect(published.length, 2);
        expect(published.last, bridge.snapshot);
      },
    );
  }

  test('native false acknowledgement remains retryable', () async {
    final (_, bridge, _) = await _boot();
    const channel = MethodChannel('syb.l/appearance_bridge');
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => ++attempts > 1);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    bridge.start();
    await pumpEventQueue();
    expect(attempts, 1);
    bridge.refresh();
    await pumpEventQueue();
    expect(attempts, 2);
  });

  test(
    'starting during an in-flight save waits for the settled document',
    () async {
      final (state, _, store) = await _boot();
      final held = Completer<void>();
      store.hold = held;
      store.reject = true;
      final mutation = state.setVibeOpacity(14);
      await pumpEventQueue();
      final bridge = AppearanceBridge(state);
      addTearDown(bridge.dispose);
      const channel = MethodChannel('syb.l/appearance_bridge');
      final snapshots = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            snapshots.add(_decode(call.arguments as String));
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      bridge.start();
      await pumpEventQueue();
      expect(snapshots, isEmpty);
      held.complete();
      expect(await mutation, isFalse);
      await pumpEventQueue();
      expect((snapshots.single['appearance'] as Map)['vibeOpacity'], 100);
    },
  );

  test(
    'patch persists atomically through app authority and preserves other settings',
    () async {
      final (state, bridge, store) = await _boot();
      final before = bridge.snapshot;
      final count = store.writes;
      final result = _decode(
        await bridge.handle(
          _patch(bridge, {
            'theme': 'disaccord',
            'vibe': 'rain',
            'vibeOpacity': 31,
            'vibeIntensity': 84,
            'vibeAnimated': false,
          }),
        ),
      );
      expect(result['ok'], isTrue);
      expect(result.containsKey('error'), isFalse);
      expect(store.writes, count + 1);
      expect(state.appearancePreset, AppearancePreset.disaccord);
      expect(state.appSettings.ambientVibe, AmbientVibe.rain);
      expect(state.chatMotionEnabled, isFalse);
      final saved = jsonDecode(state.prefs.getString('appSettings')!) as Map;
      expect((saved['appearance'] as Map)['preset'], 'calm');
      expect(state.appSettings.messageAlertsEnabled, isTrue);
      expect(bridge.snapshot['revision'], (before['revision'] as int) + 1);
      final countAfter = store.writes;
      expect(
        _decode(
          await bridge.handle(_patch(bridge, {'theme': 'disaccord'})),
        )['ok'],
        isTrue,
      );
      expect(
        store.writes,
        countAfter,
        reason: 'An echoed confirmed value needs no write.',
      );
    },
  );

  test(
    'app changes publish snapshots without writing back or leaking private state',
    () async {
      final (state, bridge, store) = await _boot();
      const channel = MethodChannel('syb.l/appearance_bridge');
      final published = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'publish');
            published.add(_decode(call.arguments as String));
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      bridge.start();
      await pumpEventQueue();
      final count = store.writes;
      expect(await state.setVibeOpacity(46), isTrue);
      await pumpEventQueue();
      expect(store.writes, count + 1);
      expect((published.last['appearance'] as Map)['vibeOpacity'], 46);
      expect(published.last.keys.toSet(), {
        'v',
        'type',
        'epoch',
        'revision',
        'writable',
        'appearance',
      });
      expect((published.last['appearance'] as Map).keys.toSet(), {
        'theme',
        'vibe',
        'vibeOpacity',
        'vibeIntensity',
        'vibeAnimated',
      });
    },
  );

  test(
    'optimistic values stay private; concurrent requests fail busy; failed saves roll back',
    () async {
      final (state, bridge, store) = await _boot();
      final original = bridge.snapshot;
      final held = Completer<void>();
      store.hold = held;
      store.reject = true;
      final pending = bridge.handle(_patch(bridge, {'vibeOpacity': 7}));
      await pumpEventQueue();
      expect(
        state.appSettings.vibeOpacity,
        7,
        reason: 'AppState is optimistic during a save.',
      );
      expect((bridge.snapshot['appearance'] as Map)['vibeOpacity'], 100);
      expect(bridge.snapshot['writable'], isFalse);
      expect(
        _decode(await bridge.handle(_patch(bridge, {'vibe': 'snow'})))['error'],
        'busy',
      );
      held.complete();
      expect(_decode(await pending)['error'], 'save_failed');
      expect(bridge.snapshot['appearance'], original['appearance']);
      expect(bridge.snapshot['revision'], original['revision']);
      store.hold = null;
      store.reject = false;
      expect(
        _decode(await bridge.handle(_patch(bridge, {'vibe': 'snow'})))['ok'],
        isTrue,
      );
    },
  );

  test(
    'app changes, replacement, lock cycles and new sessions fence stale commands',
    () async {
      final (state, bridge, store) = await _boot();
      final old = bridge.snapshot;
      await state.setAmbientVibe(AmbientVibe.halloween);
      expect(
        _decode(
          await bridge.handle(_patch(bridge, {'vibe': 'rain'}, snapshot: old)),
        )['error'],
        'stale',
      );
      final locked = bridge.snapshot;
      state.setProtectedSurfaceLocked(true);
      expect(
        _decode(await bridge.handle(_patch(bridge, {'vibe': 'rain'})))['error'],
        'busy',
      );
      state.setProtectedSurfaceLocked(false);
      expect(
        _decode(
          await bridge.handle(
            _patch(bridge, {'vibe': 'rain'}, snapshot: locked),
          ),
        )['error'],
        'stale',
      );
      final previousOwner = bridge.snapshot;
      state.accountId = 'replacement';
      expect(
        _decode(
          await bridge.handle(
            _patch(bridge, {'vibe': 'rain'}, snapshot: previousOwner),
          ),
        )['error'],
        'stale',
      );
      final replacement = AppearanceBridge(
        state,
        epoch: '6d43c156-41ae-4cad-b2c0-bbcad20e4914',
      );
      addTearDown(replacement.dispose);
      final writes = store.writes;
      expect(
        _decode(
          await replacement.handle(_patch(bridge, {'vibe': 'rain'})),
        )['error'],
        'stale',
      );
      expect(store.writes, writes);
    },
  );

  for (final patch in <Map<String, Object>>[
    {},
    {'theme': 'calm'},
    {'theme': 'unknown'},
    {'vibe': 'storm'},
    {'vibeOpacity': -1},
    {'vibeOpacity': 101},
    {'vibeIntensity': 1.0},
    {'vibeAnimated': 1},
    {'vibeOpacity': '20'},
    {'appLockEnabled': false},
  ]) {
    test('rejects invalid field/types/ranges: $patch', () async {
      final (_, bridge, store) = await _boot();
      final count = store.writes;
      expect(
        _decode(await bridge.handle(_patch(bridge, patch)))['error'],
        'invalid',
      );
      expect(store.writes, count);
    });
  }

  test('rejects malformed, oversized and unknown envelope fields', () async {
    final (_, bridge, store) = await _boot();
    final count = store.writes;
    final request = _decode(_patch(bridge, {'vibe': 'rain'}))..['extra'] = 1;
    for (final frame in ['[1]', '{', ' ' * 4097, jsonEncode(request)]) {
      expect(_decode(await bridge.handle(frame))['error'], 'invalid');
    }
    expect(store.writes, count);
  });

  test(
    'UI lock readiness is required independently of settled settings',
    () async {
      final (state, _, _) = await _boot();
      var unlocked = false;
      final bridge = AppearanceBridge(state, canEdit: () => unlocked);
      addTearDown(bridge.dispose);
      expect(bridge.snapshot['writable'], isFalse);
      expect(
        _decode(await bridge.handle(_patch(bridge, {'vibe': 'snow'})))['error'],
        'busy',
      );
      unlocked = true;
      expect(
        _decode(await bridge.handle(_patch(bridge, {'vibe': 'snow'})))['ok'],
        isTrue,
      );
    },
  );
}
