import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/overlay_bridge.dart';
import 'overlay_bridge_test.dart' show BridgeState;
import 'overlay_settings_test.dart' show MemoryOverlayStore;
import 'app_state_test.dart' show FakeJami;

class TrackingState extends BridgeState {
  TrackingState(super.jami, super.prefs);
  int retired = 0;
  @override
  void retireWidgetOverlaySession() {
    retired++;
    super.retireWidgetOverlaySession();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a new native connection lease retires private state even if the disconnect event was overtaken',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = TrackingState(
        FakeJami(),
        await SharedPreferences.getInstance(),
      );
      const channel = MethodChannel('syb.l/overlay_bridge');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final configurations = <Map>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') {
          configurations.add(call.arguments as Map);
        }
        return true;
      });
      final bridge = OverlayBridge(state, store: MemoryOverlayStore());
      addTearDown(() {
        bridge.dispose();
        state.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      Future<void> input(Map<String, Object> value) =>
          messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('input', value),
            ),
            (_) {},
          );
      bridge.start();
      await input({'type': 'connection', 'connected': true, 'lease': 1});
      expect(state.retired, 0);
      await bridge.handle(
        '{"v":1,"type":"command","id":"surface","epoch":"${bridge.epoch}",'
        '"command":"chat.surface","args":{"token":"conversation-A","visible":true}}',
      );
      await input({
        'type': 'compose',
        'lease': 1,
        'owner': 'conversation-A',
        'text': 'Old connection draft',
      });
      expect((bridge.snapshot['input'] as Map)['compose'], isNotEmpty);
      expect(configurations.last['quickChatAllowed'], isTrue);
      // Native can enqueue disconnect lease2 then connect lease3 before the platform
      // thread runs. Its current-lease check suppresses lease2, delivering only lease3.
      await input({'type': 'connection', 'connected': true, 'lease': 3});
      expect(
        state.retired,
        1,
        reason:
            'Replacement connection must invalidate the previous conversation/call tokens.',
      );
      expect((bridge.snapshot['input'] as Map)['compose'], isEmpty);
      expect((bridge.snapshot['input'] as Map)['submission'], isEmpty);
      expect(configurations.last['quickChatAllowed'], isFalse);
      await input({
        'type': 'compose',
        'lease': 1,
        'owner': 'conversation-A',
        'text': 'Delayed old draft',
      });
      expect((bridge.snapshot['input'] as Map)['compose'], isEmpty);
      await input({'type': 'connection', 'connected': true, 'lease': 3});
      expect(state.retired, 1);
    },
  );
}
