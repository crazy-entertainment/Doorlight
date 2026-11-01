import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/wake_capabilities.dart';

void main() {
  const peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  String repeated(String value, int count) => List.filled(count, value).join();

  test('records bounded device handles and persists them', () {
    final capabilities = WakeCapabilities();
    expect(capabilities.record(peer, repeated('x', 43)), isTrue);
    expect(capabilities.record('bad', repeated('x', 43)), isFalse);
    expect(capabilities.record(peer, 'bad'), isFalse);
    for (var index = 0; index < 10; index++) {
      capabilities.record(
        peer,
        '${index.toRadixString(36)}${repeated('A', 42)}',
      );
    }
    final restored = WakeCapabilities.decode(capabilities.encode());
    expect(restored.handlesFor([peer]), hasLength(8));
    expect(restored.handlesFor([peer]), contains('9${repeated('A', 42)}'));
  });

  test('fans out without duplicates and trims revoked peers', () {
    final capabilities = WakeCapabilities({
      peer: [repeated('x', 43), repeated('y', 43)],
      other: [repeated('x', 43)],
    });
    expect(capabilities.handlesFor([peer, other]), {
      repeated('x', 43),
      repeated('y', 43),
    });
    expect(capabilities.trim({other}), isTrue);
    expect(capabilities.handlesFor([peer]), isEmpty);
    expect(jsonDecode(capabilities.encode()), contains(other));
  });

  test('corrupt persistence fails closed', () {
    expect(WakeCapabilities.decode('{broken').handlesFor([peer]), isEmpty);
  });
}
