import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Google SDK cannot start before enabled-radio checks, including retries',
    () {
      final source = File(
        'android/app/src/main/kotlin/app/sybl/sybl/NearbyRadio.kt',
      ).readAsStringSync();
      final start = source.substring(
        source.indexOf('private fun startGoogle()'),
        source.indexOf('private fun googleStartFinished('),
      );
      expect(
        start,
        contains(
          'if (!googleAllowed || googleStarts.pending != 0 || !googleRadiosEnabled()) return',
        ),
      );
      expect(
        start.indexOf('!googleRadiosEnabled()'),
        lessThan(start.indexOf('google.startAdvertising(')),
      );
      expect(source, contains('?.isWifiEnabled == true &&'));
      expect(source, contains('adapter?.isEnabled == true'));
      expect(
        source,
        contains('if (googleStarted && !googleRadiosEnabled()) stopGoogle()'),
      );
      expect(
        source,
        contains(
          'val current = epoch == revealGeneration && visible && running && googleStarted && googleRadiosEnabled()',
        ),
      );
      // Direct BLE must remain independent of the Google SDK/radio guard.
      expect(source, contains('if (bleAllowed(true)) startServer()'));
      expect(source, isNot(contains('setWifiEnabled(')));
    },
  );
}
