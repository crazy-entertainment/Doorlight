import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/remote_control.dart';

// Drives the real controller, JamiRemoteControlTransport and JamiClient against
// a mock platform handler, so the values that reach native for an outgoing
// Windows clipboard send are the ones the native session compares.

const _call = 'call-1';
const _peer = '0123456789abcdef0123456789abcdef01234567';
const _device = 'abcdef0123456789abcdef0123456789abcdef01';
const _text = 'synthetic clipboard payload';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  var epoch = 1;
  var surface = 0;
  Future<bool>? clipboardDecision;

  Map<String, Object?> authority({bool blocked = true}) => {
    'channelEpoch': epoch,
    'surfaceRevision': surface,
    'hostGeneration': 0,
    'revokedThrough': 0,
    'blocked': blocked,
    'releaseComplete': true,
    'state': 'inactive',
  };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    calls = [];
    epoch = 1;
    surface = 0;
    clipboardDecision = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'remoteControlHostAuthority':
          return authority();
        case 'remoteControlSetProtectedSurface':
          final args = call.arguments as Map;
          epoch = args['channelEpoch'] as int;
          surface = args['surfaceRevision'] as int;
          return authority(blocked: args['blocked'] as bool);
        case 'remoteControlRequest':
        case 'remoteClipboardHostSend':
        case 'remoteClipboardSend':
          return true;
        case 'remoteClipboardControllerAccept':
          return await (clipboardDecision ?? Future.value(true));
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  MethodCall single(String method) {
    final matching = calls.where((call) => call.method == method).toList();
    expect(matching, hasLength(1), reason: 'calls to $method');
    return matching.single;
  }

  for (final allowed in [true, false]) {
    test(
      'Windows acceptance delegates the clipboard effect to native ($allowed)',
      () async {
        final controller = RemoteControlController(
          JamiRemoteControlTransport(JamiClient()),
        );
        addTearDown(controller.dispose);
        controller.syncCall(
          live: true,
          foreground: true,
          callId: _call,
          peerId: _peer,
          peerScreenActive: true,
          peerSourceRevision: 4,
          localScreenActive: false,
          localSourceRevision: 9,
        );
        expect(await controller.requestControl(), isTrue);
        controller.applyNativeControllerState({
          'callId': _call,
          'peerJamiId': _peer,
          'peerDeviceId': _device,
          'sourceRevision': 4,
          'controlCapabilities': 15,
          'state': 'active',
        });
        const id = '00112233445566778899aabbccddeeff';
        controller.applyNativeClipboardRequest({
          'callId': _call,
          'peerJamiId': _peer,
          'peerDeviceId': _device,
          'sourceRevision': 4,
          'id': id,
          'promptGeneration': 8,
          'text': _text,
          'clipboardBytes': _text.length,
        }, forController: true);
        final prompt = controller.clipboardRequest!;
        clipboardDecision = Future.value(allowed);
        var dartWrites = 0;
        expect(
          await controller.acceptClipboard((_) async {
            dartWrites++;
          }, expectedRequest: prompt),
          allowed,
        );
        expect(dartWrites, 0);
        expect(single('remoteClipboardControllerAccept').arguments, {
          'callId': _call,
          'peerJamiId': _peer,
          'sourceRevision': 4,
          'id': id,
          'promptGeneration': 8,
        });
      },
    );
  }

  test(
    'a Windows host send carries every binding value of its owner',
    () async {
      final controller = RemoteControlController(
        JamiRemoteControlTransport(JamiClient()),
      );
      addTearDown(controller.dispose);
      controller.syncCall(
        live: true,
        foreground: true,
        callId: _call,
        peerId: _peer,
        peerScreenActive: false,
        peerSourceRevision: null,
        localScreenActive: true,
        localSourceRevision: 9,
      );
      await pumpEventQueue();
      controller.applyNativeHostState({
        'channelEpoch': epoch,
        'surfaceRevision': surface,
        'callId': _call,
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 7,
        'state': 'active',
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      expect(controller.hostActive, isTrue);

      expect(
        await controller.sendClipboardFromReader(() async => _text),
        isTrue,
      );

      final call = single('remoteClipboardHostSend');
      final args = Map<String, Object?>.from(call.arguments as Map);
      // Compared without printing: a failure must not echo clipboard text.
      expect(args.remove('text') == _text, isTrue);
      expect(args['hostGeneration'], isNot(0));
      expect(args['controllerDeviceId'], isNotEmpty);
      expect(args, {
        'callId': _call,
        'peerJamiId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 7,
      });
      expect(calls.where((c) => c.method == 'remoteClipboardSend'), isEmpty);
    },
  );

  test('a Windows controller send carries every binding value', () async {
    final controller = RemoteControlController(
      JamiRemoteControlTransport(JamiClient()),
    );
    addTearDown(controller.dispose);
    controller.syncCall(
      live: true,
      foreground: true,
      callId: _call,
      peerId: _peer,
      peerScreenActive: true,
      peerSourceRevision: 4,
      localScreenActive: false,
      localSourceRevision: 9,
    );
    expect(await controller.requestControl(), isTrue);
    controller.applyNativeControllerState({
      'callId': _call,
      'peerJamiId': _peer,
      'peerDeviceId': _device,
      'sourceRevision': 4,
      'controlCapabilities': 15,
      'state': 'active',
    });
    expect(controller.phase, RemoteControlPhase.controlling);

    expect(await controller.sendClipboardFromReader(() async => _text), isTrue);

    final call = single('remoteClipboardSend');
    final args = Map<String, Object?>.from(call.arguments as Map);
    expect(args.remove('text') == _text, isTrue);
    expect(args, {'callId': _call, 'peerJamiId': _peer, 'sourceRevision': 4});
    expect(calls.where((c) => c.method == 'remoteClipboardHostSend'), isEmpty);
  });
}
