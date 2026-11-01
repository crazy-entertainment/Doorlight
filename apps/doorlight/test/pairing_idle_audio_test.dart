import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/media_retirement.dart';
import 'package:sybl/main.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _Link extends FakeJami {
  _Link() {
    accountExists = false;
  }

  int begins = 0;

  @override
  Future<Map<String, dynamic>> devicePairing({
    required String action,
    required String flowToken,
    String accountId = '',
    String expectedAccountId = '',
    String uri = '',
    String code = '',
    String settingsDocument = '',
    Map<String, String> network = const {},
    bool appearOffline = false,
  }) async {
    if (action == 'begin') begins++;
    if (action == 'discard') {
      return {
        'status': 'discarded',
        'flowToken': flowToken,
        'accountId': 'new-account',
      };
    }
    return {
      'flowToken': flowToken,
      'accountId': 'new-account',
      'ownerAccountId': '',
      'role': 'destination',
      'operation': 123456,
      'status': 'waiting',
      'terminal': false,
      'uri': 'jami-auth://${'b' * 64}/123456/doorlight-v1',
      'code': '',
      'peerId': '',
      'peerDeviceId': '',
      'deviceId': '',
      'error': '',
      'invalidCode': false,
    };
  }
}

void main() {
  testWidgets('idle app audio cannot block destination link admission', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const audio = MethodChannel('xyz.luan/audioplayers');
    const global = MethodChannel('xyz.luan/audioplayers.global');
    const globalEvents = MethodChannel('xyz.luan/audioplayers.global/events');
    final calls = <String>[];
    var disposingShell = false;
    final playerEvents = <MethodChannel>[];
    messenger.setMockMethodCallHandler(global, (_) async => null);
    messenger.setMockMethodCallHandler(globalEvents, (_) async => null);
    messenger.setMockMethodCallHandler(audio, (call) async {
      calls.add(call.method);
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        final events = MethodChannel('xyz.luan/audioplayers/events/$id');
        playerEvents.add(events);
        messenger.setMockMethodCallHandler(events, (_) async => null);
      }
      if ((call.method == 'stop' && !disposingShell) ||
          call.method.startsWith('setSource')) {
        throw PlatformException(code: 'audio_output_unavailable');
      }
      return null;
    });
    addTearDown(() {
      for (final channel in [audio, global, globalEvents, ...playerEvents]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    SharedPreferences.setMockInitialValues({});
    final native = _Link();
    late AppState state;
    await tester.runAsync(() async {
      state = AppState(native, await SharedPreferences.getInstance());
      await tester.pumpWidget(SyblApp(state: state));
      await state.init();
    });
    addTearDown(state.dispose);
    await tester.pump();
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(state.screen, Screen.onboarding);
    expect(calls.where((method) => method.startsWith('setSource')), isEmpty);

    await tester.runAsync(() async {
      expect(await state.beginDevicePairing(destination: true), isTrue);
      expect(native.begins, 1);
      expect(await state.devicePairing.cancel(), isTrue);
    });
    expect(calls, isNot(contains('stop')));

    final unregister = MediaRetirement.register(() async => false);
    try {
      await tester.runAsync(() async {
        expect(await state.beginDevicePairing(destination: true), isFalse);
      });
      expect(native.begins, 1);
      expect(state.devicePairingStartError, contains('playback'));
    } finally {
      unregister();
    }
    disposingShell = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {});
  });
}
