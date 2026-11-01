import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/nearby.dart';

import 'app_state_test.dart' show FakeJami;

class _Store extends InMemorySharedPreferencesStore {
  _Store(bool offline)
    : super.withData({
        'flutter.displayName': 'Me',
        'flutter.connectionProfile': 'jami',
        'flutter.appearOffline': offline,
      });
  bool reject = false;
  bool throwWrite = false;
  bool failRead = false;
  int writes = 0;
  int? rejectAt;
  int? throwAt;
  Future<void> Function(int)? beforeWrite;
  Completer<void>? writeStarted;
  Completer<void>? writeRelease;
  Completer<void>? readStarted;
  Completer<void>? readRelease;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.appearOffline') {
      writes++;
      await beforeWrite?.call(writes);
      writeStarted?.complete();
      await writeRelease?.future;
      if (throwWrite || writes == throwAt) {
        throw StateError('private write details');
      }
      if (reject || writes == rejectAt) return false;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    readStarted?.complete();
    await readRelease?.future;
    if (failRead) throw StateError('private read details');
    return super.getAll();
  }
}

class _Transport implements NearbyTransport {
  int starts = 0;
  int stops = 0;
  final sent = <NearbyPacket?>[];
  StreamController<NearbyDatagram>? incoming;
  bool get bound => incoming != null;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    starts++;
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
}

Future<(AppState, FakeJami, _Store, _Transport)> _boot(bool offline) async {
  SharedPreferences.resetStatic();
  final prior = SharedPreferencesStorePlatform.instance;
  final store = _Store(offline);
  SharedPreferencesStorePlatform.instance = store;
  addTearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = prior;
  });
  final jami = FakeJami();
  final state = AppState(jami, await SharedPreferences.getInstance());
  await state.init();
  state
    ..jamiId = 'a' * 40
    ..screen = Screen.home
    ..seedCaptureStateForTesting(
      resolved: true,
      applied: WindowCaptureProtectionStatus.exclude,
    );
  final transport = _Transport();
  state.attachNearby(transport);
  await pumpEventQueue();
  if (!offline) {
    expect(state.revealNearby(), isTrue);
    await pumpEventQueue();
  }
  addTearDown(state.dispose);
  // Account adoption also persists this flag; count only the requested transition.
  store.writes = 0;
  return (state, jami, store, transport);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final offline in [false, true]) {
    for (final throws in [false, true]) {
      test(
        'failed offline rollback rereads durable state: from=$offline throw=$throws',
        () async {
          final (state, jami, store, _) = await _boot(offline);
          jami.failAppearOffline = true;
          if (throws) {
            store.throwAt = 2;
          } else {
            store.rejectAt = 2;
          }
          await state.setAppearOffline(!offline);
          expect(state.appearOffline, offline);
          expect(state.prefs.getBool('appearOffline'), !offline);
          expect(state.settingsError, contains('Could not change or restore'));
          expect(state.settingsError, isNot(contains('private')));
          expect(store.writes, 2);
          jami.failAppearOffline = false;
          await state.setAppearOffline(!offline);
          expect(state.appearOffline, !offline);
          expect(state.settingsError, isNull);
        },
      );
    }
    test(
      'failed offline rollback reread blocks further writes: from=$offline',
      () async {
        final (state, jami, store, _) = await _boot(offline);
        jami.failAppearOffline = true;
        store.rejectAt = 2;
        store.failRead = true;
        await state.setAppearOffline(!offline);
        expect(state.settingsError, contains('Could not change or restore'));
        final calls = List<String>.of(jami.calls);
        final wake = jami.backgroundWakeCalls.length;
        jami.failAppearOffline = false;
        await state.setAppearOffline(!offline);
        expect(store.writes, 2);
        expect(jami.calls, calls);
        expect(jami.backgroundWakeCalls.length, wake);
        store.failRead = false;
        await state.setAppearOffline(!offline);
        expect(state.appearOffline, !offline);
        expect(state.settingsError, isNull);
      },
    );
    for (final aba in [false, true]) {
      test(
        'offline rollback completion preserves replacement runtime: from=$offline aba=$aba',
        () async {
          final (state, jami, store, _) = await _boot(offline);
          jami.failAppearOffline = true;
          final entered = Completer<void>();
          final release = Completer<void>();
          store.beforeWrite = (number) async {
            if (number == 2) {
              entered.complete();
              await release.future;
            }
          };
          final run = state.setAppearOffline(!offline);
          await entered.future;
          final original = state.accountId;
          state.accountId = 'replacement';
          if (aba) state.accountId = original;
          state.appearOffline = !offline;
          state.settingsError = 'Replacement warning';
          final calls = List<String>.of(jami.calls);
          release.complete();
          await run;
          expect(state.appearOffline, !offline);
          expect(state.settingsError, 'Replacement warning');
          expect(jami.calls, calls);
        },
      );
    }
  }
  for (final offline in [false, true]) {
    for (final throws in [false, true]) {
      test(
        'failed offline save has no effects: from=$offline throw=$throws',
        () async {
          final (state, jami, store, transport) = await _boot(offline);
          store.reject = true;
          store.throwWrite = throws;
          final calls = List<String>.of(jami.calls);
          final wake = jami.backgroundWakeCalls.length;
          final nearby = (
            transport.starts,
            transport.stops,
            transport.sent.length,
          );
          final readiness = (state.ready, state.peerPresence);
          await state.setAppearOffline(!offline);
          await pumpEventQueue();
          expect(state.appearOffline, offline);
          expect(state.prefs.getBool('appearOffline'), offline);
          expect(jami.calls, calls);
          expect(jami.backgroundWakeCalls.length, wake);
          expect((
            transport.starts,
            transport.stops,
            transport.sent.length,
          ), nearby);
          expect(transport.bound, !offline);
          expect(state.nearby!.visible, !offline);
          expect((state.ready, state.peerPresence), readiness);
          expect(state.settingsError, contains('Could not save'));
          expect(state.settingsError, isNot(contains('private')));
          expect(store.writes, 1);
        },
      );
    }

    test('offline change waits for persistence: from=$offline', () async {
      final (state, jami, store, transport) = await _boot(offline);
      final entered = store.writeStarted = Completer<void>();
      final release = store.writeRelease = Completer<void>();
      final calls = List<String>.of(jami.calls);
      final wake = jami.backgroundWakeCalls.length;
      final pending = state.setAppearOffline(!offline);
      await entered.future;
      try {
        await pumpEventQueue();
        expect(state.appearOffline, offline);
        expect(state.changingAppearOffline, isTrue);
        expect(transport.bound, !offline);
        expect(state.nearby!.visible, !offline);
        expect(jami.calls, calls);
        expect(jami.backgroundWakeCalls.length, wake);
      } finally {
        release.complete();
        await pending;
      }
      await pumpEventQueue();
      expect(state.appearOffline, !offline);
      expect(state.prefs.getBool('appearOffline'), !offline);
      expect(transport.bound, offline);
      expect(state.changingAppearOffline, isFalse);
      expect(
        jami.calls.skip(calls.length),
        contains('appearOffline:${!offline}'),
      );
    });

    test(
      'failed offline reread blocks writes until recovery: from=$offline',
      () async {
        final (state, jami, store, transport) = await _boot(offline);
        store.reject = true;
        store.failRead = true;
        final calls = List<String>.of(jami.calls);
        final wake = jami.backgroundWakeCalls.length;
        await state.setAppearOffline(!offline);
        expect(state.appearOffline, offline);
        expect(state.prefs.getBool('appearOffline'), !offline);
        expect(state.settingsError, contains('Restart Doorlight'));
        store.reject = false;
        await state.setAppearOffline(!offline);
        expect(store.writes, 1);
        expect(jami.calls, calls);
        expect(jami.backgroundWakeCalls.length, wake);
        expect(transport.bound, !offline);
        store.failRead = false;
        await state.setAppearOffline(!offline);
        expect(store.writes, 2);
        expect(state.appearOffline, !offline);
        expect(state.settingsError, isNull);
        state.settingsError = 'Other settings warning';
        await state.setAppearOffline(offline);
        expect(state.settingsError, 'Other settings warning');
      },
    );

    for (final duringRead in [false, true]) {
      for (final aba in [false, true]) {
        test(
          'offline stale completion: from=$offline read=$duringRead aba=$aba',
          () async {
            final (state, jami, store, _) = await _boot(offline);
            store.reject = true;
            final entered = Completer<void>();
            final release = Completer<void>();
            if (duringRead) {
              store.readStarted = entered;
              store.readRelease = release;
            } else {
              store.writeStarted = entered;
              store.writeRelease = release;
            }
            final pending = state.setAppearOffline(!offline);
            await entered.future;
            final original = state.accountId;
            state.accountId = 'replacement';
            if (aba) state.accountId = original;
            state.appearOffline = offline;
            state.settingsError = 'Replacement warning';
            final calls = List<String>.of(jami.calls);
            final wake = jami.backgroundWakeCalls.length;
            release.complete();
            await pending;
            expect(state.appearOffline, offline);
            expect(state.settingsError, 'Replacement warning');
            expect(jami.calls, calls);
            expect(jami.backgroundWakeCalls.length, wake);
            expect(store.writes, 1);
          },
        );
      }
    }
  }
}
