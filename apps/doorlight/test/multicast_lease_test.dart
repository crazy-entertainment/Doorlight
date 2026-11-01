import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'two discovery channels keep the native lock until the final owner leaves',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'acquireMulticastLock' ? true : null;
      });
      final client = JamiClient();
      expect(
        await Future.wait([
          client.acquireMulticastLock(),
          client.acquireMulticastLock(),
        ]),
        [true, true],
      );
      expect(calls, ['acquireMulticastLock']);
      await client.releaseMulticastLock();
      expect(calls, ['acquireMulticastLock']);
      await client.releaseMulticastLock();
      await client.releaseMulticastLock();
      expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
    },
  );

  test('failed acquisition does not own or release a native lock', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return false;
    });
    final client = JamiClient();
    expect(await client.acquireMulticastLock(), false);
    await client.releaseMulticastLock();
    expect(calls, ['acquireMulticastLock']);
  });
}
