import 'package:flutter/foundation.dart';

abstract final class BackgroundWakePolicy {
  static bool effective({
    required bool requested,
    required TargetPlatform platform,
    required String connectionProfile,
    required bool firebaseAvailable,
  }) =>
      requested &&
      platform == TargetPlatform.android &&
      connectionProfile == 'jami' &&
      firebaseAvailable;
}
