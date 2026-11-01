import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'nearby_protocol.dart';

/// Sonar's minigame rules, shared by the shooter and the target so both
/// sides agree on a missile's flight without a clock exchange.
abstract final class SonarCombat {
  /// Taps on a person's picture inside this window charge one missile.
  static const Duration chargeWindow = Duration(seconds: 2);

  /// A level-0 missile takes [slowFlight] on a wide bow; a full charge takes
  /// [fastFlight] and flies nearly straight.
  static const Duration slowFlight = Duration(milliseconds: 6000);
  static const Duration fastFlight = Duration(milliseconds: 2500);
  static const double wideBow = .55;
  static const double flatBow = .04;

  /// Firing while hidden is an explicit reveal for this long.
  static const Duration fireReveal = Duration(seconds: 15);

  /// A destroyed sonar waits this long before a fresh hold works again.
  static const Duration rearm = deathDuration;
  static const Duration prefire = Duration(milliseconds: 500);
  static const Duration deathDuration = Duration(milliseconds: 10511);
  static const Duration lostDuration = Duration(milliseconds: 4905);

  /// Extra target brackets are earned in complete groups of ten taps.
  static int brackets(int taps) => 1 + taps ~/ 10;

  static double lossChance(int level) => lerpDouble(.30, .02, _share(level))!;
  static double collisionChance(int a, int b) =>
      lerpDouble(.35, .06, (_share(a) + _share(b)) / 2)!;

  /// The nonce travels with the shot, so both ends agree without another packet.
  static bool losesTarget(String? nonce, int level) =>
      nonce != null &&
      int.parse(nonce.substring(0, 8), radix: 16) % 1000 <
          lossChance(level) * 1000;

  static bool collide(String a, int aLevel, String b, int bLevel) {
    final ordered = [a, b]..sort();
    final roll =
        (int.parse(ordered[0].substring(0, 8), radix: 16) ^
            int.parse(ordered[1].substring(8), radix: 16)) %
        1000;
    return roll < collisionChance(aLevel, bLevel) * 1000;
  }

  /// One missile per shooter per this gap is accepted.
  static const Duration shooterSpacing = Duration(seconds: 2);

  /// Bounds missiles in flight towards you, whatever the LAN sends.
  static const int maxIncoming = 8;

  /// You and someone are trading fire while both shot within this.
  static const Duration engagement = Duration(seconds: 60);

  /// The shooter's target going dark this soon after impact counts as sunk.
  static const Duration sunkWindow = Duration(milliseconds: 1500);

  /// The incoming-close warning plays this long before impact.
  static const Duration closeWarning = Duration(milliseconds: 1500);

  /// Remaining time at or under this share of the full window is low.
  static const double lowShare = .25;

  /// Under 10 taps is level 0; every further 2 taps adds one, up to 6.
  static int level(int taps) =>
      (taps ~/ 2 - 4).clamp(0, NearbyProtocol.maxLevel);

  /// Damage in thousandths of the full window, uniform in the level's range.
  static int roll(int level, math.Random random) =>
      NearbyProtocol.minMissile +
      random.nextInt(
        NearbyProtocol.maxMissileAt(level) - NearbyProtocol.minMissile + 1,
      );

  static double _share(int level) =>
      level.clamp(0, NearbyProtocol.maxLevel) / NearbyProtocol.maxLevel;

  /// Flight time from the level alone.
  static Duration flight(int level) => Duration(
    milliseconds: lerpDouble(
      slowFlight.inMilliseconds,
      fastFlight.inMilliseconds,
      _share(level),
    )!.round(),
  );

  /// How far the path bows out, as a share of its length.
  static double bow(int level) => lerpDouble(wideBow, flatBow, _share(level))!;
}

/// What the Nearby controller reports for the stage and the sound bank.
enum SonarCue {
  /// A tap on a person while charging; [SonarEvent.step] counts it.
  charge,

  /// Your missile left; [SonarEvent.level] sets its flight.
  launched,

  /// Your missile reached [SonarEvent.peer].
  impact,

  /// Your target went dark right after your hit.
  sunk,

  /// Your missile ended early, e.g. Nearby stopped.
  missileGone,
  targetLost,
  collision,
  shutdown,

  /// Someone's missile is on its way to you.
  incoming,
  incomingClose,
  incomingEnded,

  /// A missile landed on you; [SonarEvent.low] once little time is left.
  hit,

  /// A missile ended your visibility.
  destroyed,
  rearmed,
  ambienceOn,
  ambienceOff,
}

final class SonarEvent {
  const SonarEvent(
    this.cue, {
    this.peer,
    this.step = 0,
    this.level = 0,
    this.low = false,
    this.inbound = false,
  });

  final SonarCue cue;
  final String? peer;
  final int step;
  final int level;
  final bool low;
  final bool inbound;
}
