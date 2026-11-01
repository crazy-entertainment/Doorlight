import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/voice_gesture.dart';

void main() {
  test(
    'short release starts locked once; only completed held start releases to send',
    () {
      final tap = VoiceGesture()..press();
      final token = tap.activation!;
      expect(tap.release(), VoiceGestureEffect.start);
      expect(tap.release(), VoiceGestureEffect.none);
      expect(tap.holdThreshold(token), VoiceGestureEffect.none);
      tap.started(token);
      expect(tap.phase, VoiceGesturePhase.locked);
      final hold = VoiceGesture()..press();
      final heldToken = hold.activation!;
      expect(hold.holdThreshold(heldToken), VoiceGestureEffect.start);
      hold.started(heldToken);
      expect(hold.release(), VoiceGestureEffect.stopAndSend);
      expect(hold.release(), VoiceGestureEffect.none);
    },
  );
  test('cancel wins over lock and later async start cannot revive it', () {
    final gesture = VoiceGesture()..press();
    final token = gesture.activation!;
    gesture.holdThreshold(token);
    expect(gesture.drag(left: true, up: true), VoiceGestureEffect.discard);
    expect(gesture.started(token), VoiceGestureEffect.discard);
    expect(gesture.release(), VoiceGestureEffect.none);
    gesture.stopped(token, validReview: true);
    expect(gesture.phase, VoiceGesturePhase.idle);
  });
  test('interruption and early release never arm a delayed send', () {
    for (final earlyRelease in [true, false]) {
      final gesture = VoiceGesture()..press();
      final token = gesture.activation!;
      gesture.holdThreshold(token);
      expect(
        earlyRelease ? gesture.release() : gesture.interrupt(),
        VoiceGestureEffect.stopToReview,
      );
      expect(gesture.started(token), VoiceGestureEffect.stopToReview);
      expect(gesture.release(), VoiceGestureEffect.none);
      gesture.stopped(token, validReview: true);
      expect(gesture.phase, VoiceGesturePhase.review);
    }
  });
  test('stale completions cannot change a new activation', () {
    final gesture = VoiceGesture()..accessibleStart();
    final old = gesture.activation!;
    gesture.interrupt();
    gesture.stopped(old, validReview: false);
    gesture.accessibleStart();
    expect(gesture.started(old), VoiceGestureEffect.discard);
    expect(gesture.stopped(old, validReview: true), isFalse);
    expect(gesture.phase, VoiceGesturePhase.startingLocked);
  });
}
