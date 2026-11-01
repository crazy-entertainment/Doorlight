import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String section(String path, String start, String end) {
  final source = File(path).readAsStringSync();
  final from = source.indexOf(start);
  final to = source.indexOf(end, from + start.length);
  expect(from, greaterThanOrEqualTo(0));
  expect(to, greaterThan(from));
  return source.substring(from, to);
}

void main() {
  test('linked-device hosts use the native current-device authority', () {
    final native = section(
      '../../native/jami/src/jamidht/jamiaccount.cpp',
      'JamiAccount::getVolatileAccountDetails() const',
      'JamiAccount::lookupName(',
    );
    expect(native, contains('ConfProperties::DEVICE_ID, info->deviceId'));

    final android = section(
      'android/app/src/main/kotlin/app/sybl/sybl/JamiCore.kt',
      'fun listKnownDevices()',
      'internal fun cancelKnownDeviceRevocations(',
    );
    final windows = section(
      'windows/runner/jami_bridge.cpp',
      'void ListKnownDevices(',
      'void UpdateProfile(',
    );
    for (final host in [android, windows]) {
      expect(
        RegExp(r'getVolatileAccountDetails\(').allMatches(host),
        hasLength(2),
        reason: 'Both listing and revocation must identify the current device',
      );
      expect(host, isNot(contains('getAccountDetails(')));
    }
  });
}
