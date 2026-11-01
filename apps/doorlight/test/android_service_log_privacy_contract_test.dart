import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android service failure logs do not include exception payloads', () {
    for (final file in [
      'CallForegroundService',
      'PushForegroundService',
      'SybLFirebaseMessagingService',
    ]) {
      final source = File(
        'android/app/src/main/kotlin/app/sybl/sybl/$file.kt',
      ).readAsStringSync();
      expect(
        source,
        isNot(contains(', e)')),
        reason: '$file logs raw exception contents',
      );
      expect(source, isNot(contains(', e.message')));
      expect(source, isNot(contains(', e.toString()')));
    }
  });
}
