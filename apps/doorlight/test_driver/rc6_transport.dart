import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/remote_control.dart';

// This entrypoint runs in the Windows Flutter engine. It uses the production
// messenger, JamiClient and JamiChannels. It does not start an account or call.
class _TransportBinding extends BindingBase
    with SchedulerBinding, ServicesBinding {}

const _harness = MethodChannel('syb.l/rc6-transport-test');
const _core = MethodChannel('syb.l/core');
const _events = MethodChannel('syb.l/events');
const _deadline = Duration(seconds: 5);

void _require(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<RemoteControlHostAuthority> _status(JamiClient client) async {
  final value = await client.remoteControlHostAuthority().timeout(_deadline);
  _require(value != null, 'Native authority response is missing or malformed.');
  return value!;
}

Future<void> _waitFor(bool Function() condition, String message) async {
  final deadline = DateTime.now().add(_deadline);
  while (!condition()) {
    _require(DateTime.now().isBefore(deadline), message);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _expectMissing(Future<Object?> Function() call) async {
  try {
    await call().timeout(_deadline);
  } on MissingPluginException {
    return;
  }
  throw StateError('A destroyed channel still has a registered handler.');
}

Future<void> main() async {
  _TransportBinding();
  final checks = <String>[];
  final events = <RemoteControlHostAuthority>[];
  final eventData = <Map<String, dynamic>>[];
  final streamErrors = <Object>[];
  final client = JamiClient();
  RemoteControlController? projection;
  StreamSubscription<JamiEvent>? subscription;

  void listen() {
    subscription = client.events().listen((event) {
      if (event.type != 'remoteControlHostAuthority') return;
      final authority = RemoteControlHostAuthority.tryParse(event.data);
      if (authority == null) {
        streamErrors.add('Malformed authority event: ${event.data}');
      } else {
        events.add(authority);
        eventData.add(Map<String, dynamic>.of(event.data));
        projection?.applyNativeHostAuthority(event.data);
      }
    }, onError: streamErrors.add);
  }

  Future<void> cancel() async {
    await subscription?.cancel().timeout(_deadline);
    subscription = null;
  }

  try {
    // Epoch zero is the native pre-listener state. JamiClient must not treat it
    // as an initialized authority acknowledgement.
    final initial = await _core.invokeMapMethod<String, Object?>(
      'remoteControlHostAuthority',
    );
    _require(
      initial?['channelEpoch'] == 0 &&
          initial?['blocked'] == true &&
          initial?['state'] == 'inactive' &&
          initial?['releaseComplete'] == true &&
          initial?['hostGeneration'] == 0,
      'Host did not start blocked without a listener.',
    );
    _require(
      await client.remoteControlHostAuthority() == null,
      'The typed client accepted the uninitialized channel epoch.',
    );
    final disconnected = await client.setRemoteControlProtectedSurface(
      channelEpoch: 1,
      surfaceRevision: 1,
      blocked: false,
    );
    _require(
      disconnected == null,
      'An unattached EventChannel opened host permission.',
    );
    final stillDisconnected = await _core.invokeMapMethod<String, Object?>(
      'remoteControlHostAuthority',
    );
    _require(
      stillDisconnected?['blocked'] == true &&
          stillDisconnected?['surfaceRevision'] == 0,
      'The disconnected native host changed permission.',
    );
    checks.add('initial native block and disconnected-open rejection');

    listen();
    await _waitFor(
      () => events.any((event) => event.channelEpoch > 0),
      'EventChannel listen did not deliver a new native epoch.',
    );
    var current = await _status(client);
    _require(
      current.blocked && current.revoked,
      'Listen inherited permission.',
    );
    checks.add('real EventChannel listen and typed authority event');

    for (final arguments in <Object?>[
      null,
      false,
      {'channelEpoch': current.channelEpoch, 'surfaceRevision': 1},
      {
        'channelEpoch': current.channelEpoch,
        'surfaceRevision': 1,
        'blocked': 'false',
      },
      {
        'channelEpoch': current.channelEpoch,
        'surfaceRevision': 1.0,
        'blocked': false,
      },
      {'channelEpoch': 0, 'surfaceRevision': 1, 'blocked': false},
    ]) {
      var rejected = false;
      try {
        await _core
            .invokeMethod<Object?>(
              'remoteControlSetProtectedSurface',
              arguments,
            )
            .timeout(_deadline);
      } on PlatformException catch (error) {
        rejected = error.code == 'invalid_control_authority';
      }
      _require(rejected, 'Invalid authority arguments were not rejected.');
    }
    checks.add('production method validation and error envelopes');

    const revision = 0x100000005;
    final opened = await client.setRemoteControlProtectedSurface(
      channelEpoch: current.channelEpoch,
      surfaceRevision: revision,
      blocked: false,
    );
    _require(
      opened != null &&
          !opened.blocked &&
          opened.revoked &&
          opened.surfaceRevision == revision &&
          opened.hostGeneration == 0,
      'The int64 surface handshake did not open an inactive host.',
    );
    await _waitFor(
      () => events.any(
        (event) => event.surfaceRevision == revision && !event.blocked,
      ),
      'The int64 authority event did not cross the engine.',
    );
    checks.add('int64 request, response and event round trip');

    // Both requests cross the real engine before either result is consumed.
    final oldOpen = client.setRemoteControlProtectedSurface(
      channelEpoch: current.channelEpoch,
      surfaceRevision: revision + 1,
      blocked: false,
    );
    final block = client.setRemoteControlProtectedSurface(
      channelEpoch: current.channelEpoch,
      surfaceRevision: revision + 2,
      blocked: true,
    );
    final blocked = await block.timeout(_deadline);
    final lateOpen = await oldOpen.timeout(_deadline);
    _require(
      blocked?.blocked == true && blocked?.revoked == true,
      'Block did not return a complete native stop acknowledgement.',
    );
    _require(
      lateOpen?.surfaceRevision == revision + 1,
      'The earlier request lost its own revision.',
    );
    current = await _status(client);
    _require(
      current.blocked && current.surfaceRevision == revision + 2,
      'Consuming an earlier open result changed native block state.',
    );
    checks.add('ordered overlapping requests and late open-result consumption');

    final oldEpoch = current.channelEpoch;
    final oldEpochReply = client.setRemoteControlProtectedSurface(
      channelEpoch: oldEpoch,
      surfaceRevision: revision + 3,
      blocked: false,
    );
    await cancel();
    final detached = await _status(client);
    _require(
      detached.channelEpoch > oldEpoch && detached.blocked && detached.revoked,
      'Cancel did not revoke and advance the channel epoch.',
    );
    listen();
    await _waitFor(
      () => events.any((event) => event.channelEpoch > detached.channelEpoch),
      'Relisten did not establish a new native epoch.',
    );
    final lateEpoch = await oldEpochReply.timeout(_deadline);
    _require(lateEpoch?.channelEpoch == oldEpoch, 'Old reply epoch changed.');
    current = await _status(client);
    final stale = await client.setRemoteControlProtectedSurface(
      channelEpoch: oldEpoch,
      surfaceRevision: revision + 100,
      blocked: false,
    );
    _require(
      stale?.channelEpoch == current.channelEpoch && stale?.blocked == true,
      'A stale epoch opened a successor listener.',
    );
    checks.add('cancel, relisten, late epoch result and stale-open rejection');

    for (final generation in [1, 0x100000001]) {
      final allowed = await client.allowRemoteControl(
        callId: 'rc6-no-call',
        controllerAccountId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        controllerDeviceId:
            '1111111111111111111111111111111111111111111111111111111111111111',
        sourceRevision: 1,
        hostGeneration: generation,
        persistDevice: false,
      );
      _require(
        !allowed,
        'A start without a current consent request succeeded.',
      );
    }
    _require(
      (await _status(client)).hostGeneration == 0,
      'A grant was created.',
    );
    checks.add(
      'start without current consent rejects int32 and int64 generations',
    );

    final leased = await client.setRemoteControlProtectedSurface(
      channelEpoch: current.channelEpoch,
      surfaceRevision: 1,
      blocked: false,
    );
    _require(leased?.blocked == false, 'Fresh lease handshake failed.');
    // The headless harness supplies no owner HWND and thus no host safety timer.
    // No renewal is sent. AuthorityStatus must still see the elapsed lease.
    await Future<void>.delayed(const Duration(milliseconds: 1750));
    final expired = await _status(client);
    _require(
      expired.blocked && expired.revoked && expired.surfaceRevision == 1,
      'Permission did not expire without a platform safety timer.',
    );
    final staleRenewal = await client.setRemoteControlProtectedSurface(
      channelEpoch: current.channelEpoch,
      surfaceRevision: 1,
      blocked: false,
    );
    _require(
      staleRenewal?.blocked == true &&
          staleRenewal!.surfaceRevision > expired.surfaceRevision,
      'An expired same-revision renewal reopened permission.',
    );
    checks.add('silent lease expiry without a host timer or renewal');

    final fresh = await client.setRemoteControlProtectedSurface(
      channelEpoch: current.channelEpoch,
      surfaceRevision: staleRenewal!.surfaceRevision + 1,
      blocked: false,
    );
    _require(fresh?.blocked == false, 'A fresh lease handshake failed.');
    _require(
      await client.stopRemoteControlHost(),
      'Native Stop was not complete.',
    );
    _require(
      (await _status(client)).blocked,
      'Native Stop left permission open.',
    );
    checks.add('fresh handshake and production native Stop acknowledgement');

    final projectionEvents = events.length;
    projection = RemoteControlController(JamiRemoteControlTransport(client));
    await projection.initializeHostAuthority();
    void syncProjection(bool available) {
      projection!.syncCall(
        live: true,
        foreground: available,
        hostAvailable: available,
        callId: 'rc6-no-call',
        peerId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        peerScreenActive: false,
        peerSourceRevision: null,
        localScreenActive: true,
        localSourceRevision: 1,
      );
    }

    // Synthetic Dart availability exercises the production projection and
    // channel handshake. Native still has no authenticated call or grant.
    syncProjection(true);
    await _waitFor(
      () => events.length > projectionEvents && !events.last.blocked,
      'The production Dart projection did not open a surface.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final stable = await _status(client);
    _require(
      !stable.blocked && stable.revoked,
      'The projection did not settle.',
    );
    final staleProjectionEvent = Map<String, dynamic>.of(
      eventData.lastWhere((event) => event['blocked'] == false),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    final renewed = await _status(client);
    _require(
      !renewed.blocked &&
          renewed.revoked &&
          renewed.surfaceRevision == stable.surfaceRevision &&
          events.length - projectionEvents < 20,
      'Authority event feedback changed the stable surface or lost its lease.',
    );
    checks.add(
      'production Dart projection converges and renews a stable surface',
    );

    syncProjection(false);
    await _waitFor(
      () => projection!.hostPhase == RemoteControlHostPhase.idle,
      'The hidden-surface projection did not reach acknowledged idle.',
    );
    final hidden = await _status(client);
    _require(hidden.blocked && hidden.revoked, 'Hidden surface stayed open.');
    projection.applyNativeHostAuthority(staleProjectionEvent);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final afterStale = await _status(client);
    _require(
      afterStale.blocked &&
          afterStale.revoked &&
          afterStale.surfaceRevision == hidden.surfaceRevision &&
          projection.hostPhase == RemoteControlHostPhase.idle,
      'A captured stale authority event reopened the hidden surface.',
    );
    projection.dispose();
    projection = null;
    checks.add('capture or lock availability block rejects a stale real event');

    await cancel();
    await _harness.invokeMethod<void>('destroyChannels').timeout(_deadline);
    await _expectMissing(() => client.remoteControlHostAuthority());
    await _expectMissing(() => _events.invokeMethod<Object?>('listen'));
    await _harness.invokeMethod<void>('createChannels').timeout(_deadline);
    listen();
    final priorEvents = events.length;
    await _waitFor(
      () => events.length > priorEvents,
      'New channels did not deliver an authority event.',
    );
    current = await _status(client);
    _require(
      current.blocked && current.revoked && current.hostGeneration == 0,
      'New channels inherited old host authority.',
    );
    await cancel();
    checks.add('real messenger handler removal and channel reconstruction');

    _require(streamErrors.isEmpty, 'Event stream errors: $streamErrors');
    await _harness.invokeMethod<void>('complete', {
      'ok': true,
      'checks': checks,
      'authorityEvents': events.length,
    });
  } catch (error, stack) {
    projection?.dispose();
    projection = null;
    await cancel();
    await _harness.invokeMethod<void>('complete', {
      'ok': false,
      'checks': checks,
      'failure': '$error\n$stack',
    });
  }
}
