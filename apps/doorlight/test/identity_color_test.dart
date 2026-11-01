import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/identity_color.dart';

void main() {
  test(
    'the hue palette covers all 24 stable colors across native boundaries',
    () {
      expect(IdentityColor.palette, hasLength(24));
      expect(IdentityColor.palette.toSet(), IdentityColor.values.toSet());
      expect(
        PresenceWireContract.identityColors,
        IdentityColor.values.map((color) => color.storageValue).toSet(),
      );
      final android = File(
        'android/app/src/main/kotlin/app/sybl/sybl/IdentityColorWire.kt',
      ).readAsStringSync();
      final windows = File(
        'windows/runner/identity_color_wire.h',
      ).readAsStringSync();
      final androidEntries = RegExp(r'"([a-z]+)" to 0x([A-Fa-f0-9]+)')
          .allMatches(android)
          .map((match) => MapEntry(match[1]!, int.parse(match[2]!, radix: 16)));
      final windowsEntries = RegExp(r'\{"([a-z]+)", 0x([a-f0-9]+)u\}')
          .allMatches(windows)
          .map((match) => MapEntry(match[1]!, int.parse(match[2]!, radix: 16)));
      final expected = {
        for (final color in IdentityColor.values)
          color.storageValue: color.argb,
      };
      expect(Map.fromEntries(androidEntries), expected);
      expect(Map.fromEntries(windowsEntries), expected);
      expect(IdentityColor.amber.argb, 0xFFF2B775);
      expect(IdentityColor.sky.argb, 0xFF7FAFD8);
      expect(IdentityColor.tryParse('ultraviolet'), isNull);
    },
  );

  test('automatic colors are stable and normalized', () {
    expect(
      IdentityColor.automaticFor(' BBBB '),
      IdentityColor.automaticFor('bbbb'),
    );
    expect(IdentityColor.automaticFor(''), isA<IdentityColor>());
  });

  test(
    'recommendations include the current choice, favor gaps and keep hue order',
    () {
      final result = IdentityColor.recommended([
        IdentityColor.red,
        IdentityColor.blue,
      ], current: IdentityColor.sky);
      expect(result, hasLength(6));
      expect(result.toSet(), hasLength(6));
      expect(result, contains(IdentityColor.sky));
      expect(
        result.any(
          (color) => const {
            IdentityColor.lime,
            IdentityColor.sage,
            IdentityColor.green,
            IdentityColor.emerald,
            IdentityColor.mint,
          }.contains(color),
        ),
        isTrue,
      );
      final positions = result.map(IdentityColor.palette.indexOf).toList();
      expect(positions, orderedEquals([...positions]..sort()));
      expect(
        IdentityColor.recommended([
          IdentityColor.blue,
          IdentityColor.red,
          IdentityColor.red,
        ], current: IdentityColor.sky),
        result,
      );
      for (final current in IdentityColor.values) {
        final noFriends = IdentityColor.recommended(const [], current: current);
        expect(noFriends, hasLength(6));
        expect(noFriends.toSet(), hasLength(6));
        expect(noFriends, contains(current));
      }
    },
  );
}
