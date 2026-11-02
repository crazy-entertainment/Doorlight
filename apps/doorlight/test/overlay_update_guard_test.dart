import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/overlay_bridge.dart';

import 'app_state_test.dart' show FakeJami;
import 'overlay_bridge_test.dart' show BridgeState;
import 'overlay_settings_test.dart' show MemoryOverlayStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/overlay_bridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'trusted composition blocks updates; heartbeat and rejected input are not activity',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = BridgeState(
        FakeJami(),
        await SharedPreferences.getInstance(),
      );
      var activity = 0;
      var now = DateTime.utc(2026, 11, 1);
      final bridge = OverlayBridge(
        state,
        store: MemoryOverlayStore(),
        epoch: 'update-test',
        onUserActivity: () => activity++,
        now: () => now,
      );
      messenger.setMockMethodCallHandler(channel, (_) async => true);
      addTearDown(() {
        bridge.dispose();
        state.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      Future<void> input(Map<String, Object> value) =>
          messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('input', {'lease': 1, ...value}),
            ),
            (_) {},
          );
      Future<String> command(
        String name,
        Map<String, Object> args,
        String id,
      ) => bridge.handle(
        jsonEncode({
          'v': 1,
          'type': 'command',
          'id': id,
          'epoch': bridge.epoch,
          'command': name,
          'args': args,
        }),
      );
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      expect(state.widgetUpdateBusy, true);
      await command('update.presence', {
        'busy': false,
        'activity': false,
      }, 'presence');
      await command('chat.surface', {
        'token': 'conversation-A',
        'visible': true,
      }, 'surface');
      await bridge.tick();
      await input({'type': 'cursor', 'x': 1, 'y': 2});
      await input({'type': 'compose', 'owner': 'wrong', 'text': 'private'});
      expect(activity, 0);
      expect(state.widgetUpdateBusy, false);
      await input({
        'type': 'compose',
        'owner': 'conversation-A',
        'text': 'private',
      });
      expect(activity, 1);
      expect(state.widgetUpdateBusy, true);
      await input({'type': 'cancel', 'owner': 'conversation-A'});
      expect(state.widgetUpdateBusy, false);
      final result =
          jsonDecode(await command('update.capabilities', {}, 'capabilities'))
              as Map;
      expect(result['ok'], true);
      expect((result['result'] as Map)['desktopIdleGuard'], true);
      expect(activity, 2);
      await command('update.presence', {
        'busy': true,
        'activity': false,
      }, 'drafts');
      expect(state.widgetUpdateBusy, true);
      await command('update.presence', {
        'busy': false,
        'activity': false,
      }, 'idle');
      expect(state.widgetUpdateBusy, false);
      now = now.add(const Duration(seconds: 4));
      await bridge.tick();
      expect(state.widgetUpdateBusy, true);
      expect(activity, 2);
      await input({'type': 'connection', 'connected': false});
      expect(state.widgetUpdateBusy, false);
    },
  );
}
