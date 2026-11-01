import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const android = 'android/app/src/main';
  const kotlin = '$android/kotlin/app/sybl/sybl';

  test('launcher intents cannot dispatch privileged diagnostic commands', () {
    final manifest = File('$android/AndroidManifest.xml').readAsStringSync();
    final receiver = RegExp(
      r'<receiver\b[^>]*android:name="\.StressControlReceiver"[^>]*/>',
    ).firstMatch(manifest)?.group(0);
    expect(receiver, isNotNull);
    expect(receiver, contains('android:permission="android.permission.DUMP"'));
    final activity = File('$kotlin/MainActivity.kt').readAsStringSync();
    expect(activity, isNot(contains('STRESS_COMMAND')));
    final dispatch = File(
      '$kotlin/StressControlReceiver.kt',
    ).readAsStringSync();
    expect(dispatch, contains('intent.action != "app.sybl.sybl.STRESS"'));
    expect(dispatch, contains('!JamiCore.hasEventSink()'));
  });

  test(
    'headless presence uses native visibility, not an optimistic Dart default',
    () {
      final core = File('$kotlin/JamiCore.kt').readAsStringSync();
      expect(core, contains('@Volatile private var activityResumed = false'));
      expect(
        core,
        contains('internal val foreground: Boolean get() = activityResumed'),
      );
      expect(core, contains('activityResumed = resumed'));
      final activity = File('$kotlin/MainActivity.kt').readAsStringSync();
      expect(activity, contains('JamiCore.setActivityResumed(true)'));
      expect(activity, contains('JamiCore.setActivityResumed(false)'));
      expect(activity, isNot(contains('JamiCore.foreground =')));
    },
  );

  test(
    'Android consent uses the authenticated binding, not a profile name',
    () {
      final host = File(
        '$kotlin/AndroidRemoteControlHost.kt',
      ).readAsStringSync();
      final calls = RegExp(r'showConsent\(')
          .allMatches(host)
          .where(
            (m) => !host.substring(0, m.start).endsWith('internal fun '),
          )
          .toList();
      expect(calls, hasLength(1));
      expect(
        host.substring(calls.single.start),
        matches(RegExp(r'^showConsent\(\s*request\.binding,')),
      );
      final prompt = host.substring(
        host.indexOf('internal fun showConsent('),
        host.indexOf('fun hideConsent('),
      );
      expect(prompt, contains('binding.controllerAccount'));
      expect(prompt, contains('binding.controllerDevice'));
      expect(prompt, isNot(contains('remoteHelpPeerName')));
    },
  );
}
