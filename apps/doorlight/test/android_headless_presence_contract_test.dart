import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('service-only restart cannot report foreground presence', () {
    final core = File(
      'android/app/src/main/kotlin/app/sybl/sybl/JamiCore.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/app/sybl/sybl/MainActivity.kt',
    ).readAsStringSync();

    expect(core, contains('@Volatile private var activityResumed = false'));
    expect(core, contains('foreground: Boolean get() = activityResumed'));
    expect(
      RegExp(
        r'foreground\s*=\s*(?:shareForegroundPresence\s*&&\s*)?foreground',
      ).hasMatch(core),
      isTrue,
    );
    expect(activity, contains('JamiCore.setActivityResumed(true)'));
    expect(activity, contains('JamiCore.setActivityResumed(false)'));
    expect(activity, isNot(contains('JamiCore.foreground =')));
  });
}
