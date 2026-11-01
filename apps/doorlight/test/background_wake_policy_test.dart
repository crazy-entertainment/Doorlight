import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/background_wake_policy.dart';

void main() {
  test('background wake is effective only for configured Android Jami', () {
    expect(
      BackgroundWakePolicy.effective(
        requested: true,
        platform: TargetPlatform.android,
        connectionProfile: 'jami',
        firebaseAvailable: true,
      ),
      isTrue,
    );

    for (final disabled
        in <
          ({
            bool requested,
            TargetPlatform platform,
            String profile,
            bool available,
          })
        >[
          (
            requested: false,
            platform: TargetPlatform.android,
            profile: 'jami',
            available: true,
          ),
          (
            requested: true,
            platform: TargetPlatform.windows,
            profile: 'jami',
            available: true,
          ),
          (
            requested: true,
            platform: TargetPlatform.android,
            profile: 'lan',
            available: true,
          ),
          (
            requested: true,
            platform: TargetPlatform.android,
            profile: 'strict',
            available: true,
          ),
          (
            requested: true,
            platform: TargetPlatform.android,
            profile: 'jami',
            available: false,
          ),
        ]) {
      expect(
        BackgroundWakePolicy.effective(
          requested: disabled.requested,
          platform: disabled.platform,
          connectionProfile: disabled.profile,
          firebaseAvailable: disabled.available,
        ),
        isFalse,
        reason: disabled.toString(),
      );
    }
  });
}
