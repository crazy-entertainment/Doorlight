import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android rechecks removal at every direct ring and Answer boundary', () {
    final source = File(
      'android/app/src/main/kotlin/app/sybl/sybl/JamiCore.kt',
    ).readAsStringSync();
    for (final boundaries in [
      [
        'for ((callId, pending) in incomingCalls.snapshot())',
        '// The daemon persists',
      ],
      [
        'private fun showIncomingCallNotification',
        'private fun cancelIncomingCallNotification',
      ],
      [
        'private fun surfacePendingIncomingCallIfIdle',
        'fun saveAppSettingsDocument',
      ],
      ['private fun claimCurrent(', 'private fun retireGlareSiblings'],
      [
        'val admission = incomingCallAdmission(',
        'val winner = JamiCore.currentWinnerCallId',
      ],
    ]) {
      final start = source.indexOf(boundaries[0]);
      final end = source.indexOf(boundaries[1], start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      expect(
        source.substring(start, end),
        contains('directCallAllowed('),
        reason: 'Missing removal check at ${boundaries[0]}',
      );
    }
    final answer = source.substring(
      source.indexOf('fun answerCall(callId:'),
      source.indexOf('fun refuse(callId:'),
    );
    expect(answer, contains('answerRetainedIncomingCall('));
    expect(answer, contains('allowed = ::directCallAllowed'));
    expect(answer, isNot(contains('audioMedia(initialAudioMuted)')));
  });

  test(
    'denied outgoing CURRENT still releases its native media slot on terminal',
    () {
      final source = File(
        'android/app/src/main/kotlin/app/sybl/sybl/JamiCore.kt',
      ).readAsStringSync();
      final start = source.indexOf(
        'if (JamiCore.rejectedCallIds.contains(callId))',
      );
      final end = source.indexOf('val fromHex = JamiCore.callPeer', start);
      final terminal = source.substring(start, end);
      expect(
        terminal,
        contains(
          'if (JamiCore.activeCallId == callId || JamiCore.placingOutgoing)',
        ),
      );
      expect(
        terminal,
        contains(
          'JamiCore.handleCallState(accountId, callId, state, code, retiredPeer)',
        ),
      );
      expect(
        terminal.indexOf('JamiCore.handleCallState('),
        lessThan(terminal.indexOf('JamiCore.rejectedCallIds.remove(callId)')),
      );
    },
  );
}
