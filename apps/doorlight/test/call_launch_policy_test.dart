import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/call_launch_policy.dart';
import 'package:sybl/state/presence_coordinator.dart';

void main() {
  test('in-app peers ring directly', () {
    expect(
      CallLaunchPolicy.forPresence(PeerPresence.inApp),
      CallLaunchAction.ring,
    );
  });

  test('background-reachable peers offer notify or ring', () {
    expect(
      CallLaunchPolicy.forPresence(PeerPresence.reachable),
      CallLaunchAction.chooseNotifyOrRing,
    );
  });

  test('unknown and unreachable peers keep the normal ring path', () {
    expect(
      CallLaunchPolicy.forPresence(PeerPresence.unknown),
      CallLaunchAction.ring,
    );
    expect(
      CallLaunchPolicy.forPresence(PeerPresence.unreachable),
      CallLaunchAction.ring,
    );
  });
}
