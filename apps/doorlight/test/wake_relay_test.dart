import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/wake_relay.dart';

void main() {
  test('relay base URL accepts one HTTPS origin only', () {
    expect(WakeRelayConfig.validBaseUrl('https://wake.example'), isTrue);
    expect(WakeRelayConfig.validBaseUrl('https://wake.example/'), isTrue);
    expect(WakeRelayConfig.validBaseUrl('http://wake.example'), isFalse);
    expect(WakeRelayConfig.validBaseUrl('https://wake.example/path'), isFalse);
    expect(WakeRelayConfig.validBaseUrl('https://user@wake.example'), isFalse);
    expect(WakeRelayConfig.validBaseUrl(''), isFalse);
  });

  test('wake sends one empty request per unique valid handle', () async {
    final seen = <Uri>[];
    final relay = WakeRelay(
      baseUrl: 'https://wake.example',
      post: (uri) async => seen.add(uri),
    );
    final handle = List.filled(43, 'A').join();
    await relay.wake([handle, handle, 'bad']);
    expect(seen, [Uri.parse('https://wake.example/v1/wakes/$handle')]);
  });

  test('relay failure never fails the Jami operation', () async {
    final relay = WakeRelay(
      baseUrl: 'https://wake.example',
      post: (_) => Future.error(StateError('offline')),
    );
    await expectLater(relay.wake([List.filled(43, 'A').join()]), completes);
  });
}
