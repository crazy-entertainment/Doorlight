import 'presence_coordinator.dart';

enum CallLaunchAction { ring, chooseNotifyOrRing }

abstract final class CallLaunchPolicy {
  static CallLaunchAction forPresence(PeerPresence presence) =>
      presence == PeerPresence.reachable
      ? CallLaunchAction.chooseNotifyOrRing
      : CallLaunchAction.ring;
}
