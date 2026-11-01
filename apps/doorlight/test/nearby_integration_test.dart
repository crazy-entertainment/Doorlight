import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/sound_effects.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/nearby.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/add_friend_dialog.dart';
import 'package:sybl/ui/add_friend_pane.dart';
import 'package:sybl/ui/friend_connection_page.dart';
import 'package:sybl/ui/notification_bell.dart';
import 'package:sybl/ui/sonar_button.dart';

const _ownId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _maraId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Transport implements NearbyTransport {
  int starts = 0;
  int stops = 0;
  final sent = <NearbyPacket?>[];
  StreamController<NearbyDatagram>? incoming;

  bool get bound => incoming != null;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    starts++;
    incoming = StreamController<NearbyDatagram>();
    return incoming!.stream;
  }

  @override
  Future<void> send(Uint8List data) async =>
      sent.add(NearbyProtocol.decode(data));

  @override
  Future<void> stop() async {
    stops++;
    unawaited(incoming?.close());
    incoming = null;
  }

  void announce(String id, String name, {bool ping = false}) => incoming!.add((
    data: NearbyProtocol.encodeAnnouncement(id, name, ping: ping)!,
    sender: InternetAddress.loopbackIPv4,
  ));

  void fire(String from, int permille, int level) => incoming!.add((
    data: NearbyProtocol.encodeMissile(from, _ownId, permille, level)!,
    sender: InternetAddress.loopbackIPv4,
  ));
}

class _Jami extends JamiClient {
  @override
  Future<void> setAppearOffline(bool on, {String? expectedAccountId}) async {}

  @override
  Future<void> setPresenceSubscriptions(Iterable<String> peerJamiIds) async {}
}

final class _State extends AppState {
  _State(super.jami, super.prefs);

  final added = <String>[];
  final hints = <String?>[];

  @override
  Future<bool> addFriend(String hex, {String? nameHint}) async {
    added.add(hex);
    hints.add(nameHint);
    return true;
  }
}

Future<(_State, _Transport)> _homeState() async {
  SharedPreferences.setMockInitialValues({});
  final state = _State(_Jami(), await SharedPreferences.getInstance())
    ..jamiId = _ownId
    ..displayName = 'Peer'
    ..accountId = 'account'
    ..screen = Screen.home
    ..seedCaptureStateForTesting(
      resolved: true,
      applied: WindowCaptureProtectionStatus.exclude,
    );
  final transport = _Transport();
  state.attachNearby(transport);
  await pumpEventQueue();
  return (state, transport);
}

const _linaId = 'cccccccccccccccccccccccccccccccccccccccc';

/// Opens Nearby as a page from the Add a friend pane.
Future<(_State, _Transport)> _openNearby(
  WidgetTester tester, {
  Map<String, String> before = const {_maraId: 'Mara'},
  bool reduceMotion = false,
  double textScale = 1,
  VoidCallback? onClose,
}) async {
  late _State state;
  late _Transport transport;
  await tester.runAsync(() async {
    (state, transport) = await _homeState();
  });
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      builder: (context, child) => RepaintBoundary(
        key: const ValueKey('nearby-preview'),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: AddFriendPane(
          state: state,
          onClose: onClose ?? () {},
          isCurrent: () => true,
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    for (final MapEntry(key: id, value: name) in before.entries) {
      transport.announce(id, name);
    }
    await pumpEventQueue();
  });
  await tester.tap(find.byKey(const ValueKey('connection-nearby')));
  await tester.pumpAndSettle();
  return (state, transport);
}

double _opacity(WidgetTester tester, Finder finder) => tester
    .widgetList<Opacity>(
      find.ancestor(of: finder, matching: find.byType(Opacity)),
    )
    .fold(1.0, (value, opacity) => value * opacity.opacity);

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      'Sonar target hierarchy renders on ${mobile ? 'phone' : 'desktop'}',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(700, 500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        debugDefaultTargetPlatformOverride = mobile
            ? TargetPlatform.android
            : TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        for (final font in ['HankenGrotesk', 'Fraunces']) {
          await (FontLoader(font)
                ..addFont(rootBundle.load('assets/fonts/$font-Variable.ttf')))
              .load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        await _openNearby(
          tester,
          before: {_maraId: 'phone-b'},
          textScale: mobile ? 2 : 1,
        );
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('Fire at phone-b'), findsOneWidget);
        expect(find.bySemanticsLabel('Add phone-b'), findsOneWidget);
        await expectLater(
          find.byKey(const ValueKey('nearby-preview')),
          matchesGoldenFile(
            'goldens/nearby_${mobile ? 'phone_text200' : 'desktop'}.png',
          ),
        );
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  testWidgets('compact desktop keeps Sonar fixed above scrolling people', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(450, 430)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final font in ['HankenGrotesk', 'Fraunces']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font-Variable.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final ids = [for (var i = 1; i <= 8; i++) '$i' * 40];
    final (state, _) = await _openNearby(
      tester,
      before: {for (final id in ids) id: 'Peer'},
    );
    await expectLater(
      find.byKey(const ValueKey('nearby-preview')),
      matchesGoldenFile('goldens/nearby_desktop_compact_450x430.png'),
    );
    expect(state.revealNearby(), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2));
    expect(state.nearby!.visible, isTrue);

    final sonar = tester.getRect(
      find.byKey(const ValueKey('nearby-sonar-button')),
    );
    final countdown = tester.getRect(
      find.byKey(const ValueKey('nearby-countdown')),
    );
    final status = tester.getRect(find.text('Visible nearby.'));
    final visibility = tester.getRect(find.text('Visibility'));
    final overflow = tester.getRect(
      find.byKey(const ValueKey('nearby-overflow-scroll')),
    );
    expect(sonar.bottom, lessThanOrEqualTo(visibility.top));
    expect(countdown.bottom, lessThanOrEqualTo(visibility.top));
    expect(status.bottom, lessThanOrEqualTo(visibility.top));
    expect(overflow.height, greaterThan(0));
    expect(overflow.bottom, lessThanOrEqualTo(visibility.top));
    expect(find.bySemanticsLabel('Fire at Peer'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
    final peopleScroll = find.descendant(
      of: find.byKey(const ValueKey('nearby-overflow-scroll')),
      matching: find.byType(Scrollable),
    );
    final peoplePosition = tester
        .state<ScrollableState>(peopleScroll.first)
        .position;
    expect(peoplePosition.maxScrollExtent, greaterThan(0));
    await tester.drag(peopleScroll.first, const Offset(0, -1000));
    await tester.pump(const Duration(milliseconds: 300));
    expect(peoplePosition.pixels, greaterThan(0));
    expect(find.bySemanticsLabel('Fire at Peer'), findsAtLeastNWidgets(1));
    state.nearby!.endVisible();
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('visibility disclosure is readable before reveal ($platform)', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (_, transport) = await _openNearby(tester, before: {});
      await tester.tap(find.text('Visibility'));
      await tester.pumpAndSettle();
      expect(find.text('Your visibility'), findsOneWidget);
      expect(find.textContaining('Bluetooth name'), findsOneWidget);
      expect(
        find.textContaining('Google Nearby runs only while you are visible'),
        platform == TargetPlatform.android ? findsOneWidget : findsNothing,
      );
      expect(transport.sent, isEmpty);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  test(
    'listening follows the foreground, unlocked, online home screen',
    () async {
      final (state, transport) = await _homeState();
      addTearDown(state.dispose);
      expect(transport.bound, isTrue);
      expect(state.nearby!.listening, isTrue);

      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(transport.bound, isFalse, reason: 'hidden app binds nothing');
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(transport.bound, isTrue);

      state.setProtectedSurfaceLocked(true);
      await pumpEventQueue();
      expect(transport.bound, isFalse, reason: 'app lock stops Nearby');
      state.setProtectedSurfaceLocked(false);
      await pumpEventQueue();
      expect(transport.bound, isTrue);

      state
        ..appearOffline = true
        ..notifyListeners();
      await pumpEventQueue();
      expect(transport.bound, isFalse, reason: 'Go offline also hides Nearby');
      state
        ..appearOffline = false
        ..screen = Screen.onboarding
        ..notifyListeners();
      await pumpEventQueue();
      expect(transport.bound, isFalse, reason: 'no identity screen, no socket');
    },
  );

  test('a disallow queued behind a pending start still wins', () async {
    final (state, transport) = await _homeState();
    addTearDown(state.dispose);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(state.nearby!.status, NearbyStatus.stopped);
    // Resume then lock in the same turn: the start is still queued.
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    state.setProtectedSurfaceLocked(true);
    await pumpEventQueue();
    expect(transport.bound, isFalse);
    expect(state.nearby!.status, NearbyStatus.stopped);
  });

  test('going offline stops Nearby and says bye', () async {
    final (state, transport) = await _homeState();
    addTearDown(state.dispose);
    expect(state.revealNearby(), isTrue);
    unawaited(state.setAppearOffline(true));
    await pumpEventQueue();
    expect(transport.bound, isFalse);
    expect(transport.sent.last, isA<NearbyBye>());
  });

  test('fast pulses all sound; only the first one announces', () async {
    final (state, transport) = await _homeState();
    addTearDown(state.dispose);
    expect(state.pulseNearby(), isFalse);
    expect(state.revealNearby(), isTrue);
    await pumpEventQueue();
    final sounds = <SyblSoundEvent>[];
    state.soundEvents.listen(sounds.add);
    final sent = transport.sent.length;

    expect(state.pulseNearby(), isTrue);
    expect(state.pulseNearby(), isTrue);
    await pumpEventQueue();
    expect(sounds, [SyblSoundEvent.sonarPulse, SyblSoundEvent.sonarPulse]);
    expect(transport.sent.length, sent + 1);
  });

  test(
    'revealing announces once with the sonar and stops with the app',
    () async {
      final (state, transport) = await _homeState();
      addTearDown(state.dispose);
      final sounds = <SyblSoundEvent>[];
      state.soundEvents.listen(sounds.add);

      expect(state.revealNearby(), isTrue);
      await pumpEventQueue();
      expect(sounds, [SyblSoundEvent.sonarSend]);
      expect(
        transport.sent.single,
        isA<NearbyAnnouncement>()
            .having((p) => p.id, 'id', _ownId)
            .having((p) => p.name, 'name', 'Peer'),
      );

      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(state.nearby!.visible, isFalse);
      expect(transport.sent.last, isA<NearbyBye>());
    },
  );

  test(
    'a stranger arriving plays the received sonar without revealing us',
    () async {
      final (state, transport) = await _homeState();
      addTearDown(state.dispose);
      final sounds = <SyblSoundEvent>[];
      state.soundEvents.listen(sounds.add);

      transport.announce(_maraId, 'Mara');
      await pumpEventQueue();
      expect(sounds, [SyblSoundEvent.sonarReceived]);
      expect(state.nearby!.pendingWave, isTrue);
      expect(transport.sent, isEmpty);
    },
  );

  for (final page in [false, true]) {
    testWidgets('a nearby person opens explicit confirmation (page: $page)', (
      tester,
    ) async {
      late _State state;
      late _Transport transport;
      await tester.runAsync(() async {
        (state, transport) = await _homeState();
      });
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => page
                  ? AddFriendPane(
                      state: state,
                      onClose: () {},
                      isCurrent: () => true,
                    )
                  : FilledButton(
                      onPressed: () =>
                          showAddFriendDialog(context, state: state),
                      child: const Text('Open'),
                    ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        transport.announce(_maraId, 'Mara');
        await pumpEventQueue();
      });
      if (!page) {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(ValueKey(page ? 'connection-nearby' : 'open-nearby')),
      );
      await tester.pumpAndSettle();
      if (page) {
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(FriendConnectionPage), findsOneWidget);
      }

      expect(find.textContaining('waved back'), findsNothing);
      expect(
        state.nearby!.pendingWave,
        isFalse,
        reason: 'opening acknowledges',
      );
      expect(find.text('Mara'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('nearby-add-$_maraId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nearby-add-$_maraId')));
      await tester.pumpAndSettle();

      if (page) {
        // Add on a named nearby row is itself the single confirmation.
        expect(find.text('Add Mara'), findsNothing);
        expect(state.added, [_maraId]);
        expect(state.hints, ['Mara']);
        await tester.pump(const Duration(seconds: 7));
        return;
      }
      expect(find.byKey(const ValueKey('nearby-close')), findsNothing);
      expect(find.text('Add Mara'), findsOneWidget);
      if (page) expect(find.byType(AlertDialog), findsNothing);
      expect(state.added, isEmpty, reason: 'nothing is sent before Add');
      await tester.tap(find.byKey(const ValueKey('confirm-add-friend-button')));
      await tester.pumpAndSettle();
      expect(state.added, [_maraId]);
      expect(state.hints, ['Mara']);
      // Peers expire on their own timers; let them run out before teardown.
      await tester.pump(const Duration(seconds: 7));
    });
  }

  testWidgets('hidden and alone, Nearby sends no waves and settles', (
    tester,
  ) async {
    // pumpAndSettle inside would time out on a looping idle wave.
    final (_, transport) = await _openNearby(tester, before: const {});
    expect(tester.hasRunningAnimations, isFalse);
    expect(transport.sent, isEmpty);
  });

  testWidgets('a ping ripples out of its sender until it fades', (
    tester,
  ) async {
    final (_, transport) = await _openNearby(tester);
    await tester.runAsync(() async {
      transport.announce(_maraId, 'Mara', ping: true);
      await pumpEventQueue();
    });
    await tester.pump();
    // The sender's ripple runs 3.6 s.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.hasRunningAnimations, isTrue, reason: 'ripple still out');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse, reason: 'then it settles');
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('your ripple echoes off people instead of a comet', (
    tester,
  ) async {
    final (state, _) = await _openNearby(tester);
    double scale() => tester
        .widget<Transform>(find.byKey(const ValueKey('nearby-avatar-$_maraId')))
        .transform
        .getMaxScaleOnAxis();
    expect(scale(), closeTo(1, .001));
    expect(state.revealNearby(), isTrue);
    await tester.runAsync(pumpEventQueue);
    var peak = 1.0;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      peak = math.max(peak, scale());
    }
    expect(peak, greaterThan(1.05), reason: 'the echo pulses their picture');
    expect(
      find.byKey(const ValueKey('nearby-wave-landed')),
      findsOneWidget,
      reason: 'Mara waved before Sonar opened',
    );
    state.nearby!.endVisible();
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('a drag that starts on a person never fires or reveals', (
    tester,
  ) async {
    final (state, transport) = await _openNearby(tester);
    final target = find.byKey(const ValueKey('nearby-target-$_maraId'));
    await tester.drag(target, const Offset(0, -80));
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(pumpEventQueue);
    final nearby = state.nearby!;
    expect(nearby.chargeTarget, isNull);
    expect(nearby.visible, isFalse);
    expect(transport.sent, isEmpty);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('nobody can be targeted while still coming through the door', (
    tester,
  ) async {
    final (state, transport) = await _openNearby(tester);
    await tester.runAsync(() async {
      transport.announce(_linaId, 'Lina');
      await pumpEventQueue();
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('nearby-target-$_linaId')),
      warnIfMissed: false,
    );
    expect(state.nearby!.chargeTarget, isNull);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nearby-target-$_linaId')));
    expect(state.nearby!.chargeTarget, _linaId, reason: 'through the door');
    await tester.pump(const Duration(seconds: 10));
    state.nearby!.endVisible();
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('tapping a person charges, then the missile launches', (
    tester,
  ) async {
    final (state, transport) = await _openNearby(tester);
    final sounds = <SyblSoundEvent>[];
    final listening = state.soundEvents.listen(sounds.add);
    addTearDown(listening.cancel);
    final target = find.byKey(const ValueKey('nearby-target-$_maraId'));
    for (var i = 0; i < 12; i++) {
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 100));
    }
    final nearby = state.nearby!;
    expect(nearby.chargeTarget, _maraId, reason: 'brackets frame Mara');
    expect(nearby.chargeTaps, 12);
    expect(transport.sent.whereType<NearbyMissile>(), isEmpty);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.runAsync(pumpEventQueue);
    expect(nearby.chargeTarget, isNull);
    final shot = transport.sent.whereType<NearbyMissile>().single;
    expect(shot.at, _maraId);
    expect(shot.level, 2, reason: '12 taps in the window');
    expect(nearby.visible, isTrue, reason: 'firing hidden reveals you');
    expect(
      sounds.where((sound) => sound == SyblSoundEvent.sonarTargetTick),
      hasLength(11),
    );
    expect(
      sounds.where((sound) => sound == SyblSoundEvent.sonarTargetLock),
      hasLength(1),
    );
    expect(sounds, isNot(contains(SyblSoundEvent.sonarCharge)));
    expect(
      sounds,
      containsAllInOrder([
        SyblSoundEvent.sonarMissileShot,
        SyblSoundEvent.sonarMissileEnRoute,
      ]),
    );
    await tester.pump(SonarCombat.flight(2));
    await tester.runAsync(pumpEventQueue);
    expect(sounds, contains(SyblSoundEvent.stopMissileEnRoute));
    expect(
      sounds,
      contains(
        SonarCombat.losesTarget(shot.nonce, shot.level)
            ? SyblSoundEvent.sonarMissileTargetLost
            : SyblSoundEvent.sonarHit,
      ),
    );
    nearby.endVisible();
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('a hit turns the timer red and drains it', (tester) async {
    final (state, transport) = await _openNearby(tester);
    expect(state.revealNearby(), isTrue);
    await tester.pump();
    Text countdown() => tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('nearby-countdown')),
        matching: find.byType(Text),
      ),
    );
    final colors = tester
        .element(find.byKey(const ValueKey('nearby-countdown')))
        .syblColors;
    expect(countdown().style!.color, colors.amber);
    await tester.runAsync(() async {
      transport.fire(_maraId, 550, 6);
      await Future<void>.delayed(
        SonarCombat.flight(6) + const Duration(milliseconds: 200),
      );
    });
    final nearby = state.nearby!;
    expect(nearby.lastHit?.lost, const Duration(seconds: 165));
    await tester.pump();
    expect(countdown().style!.color, colors.danger, reason: 'red at impact');
    String shown() => tester
        .widget<Semantics>(
          find.descendant(
            of: find.byKey(const ValueKey('nearby-countdown')),
            matching: find.byType(Semantics),
          ),
        )
        .properties
        .label!;
    expect(shown(), startsWith('04:'), reason: 'drain starts from before');
    await tester.pump(const Duration(milliseconds: 1500));
    expect(shown(), startsWith('02:'), reason: 'then shows the real time');
    expect(countdown().style!.color, isNot(colors.amber));
    await tester.pump(SonarButton.hitRecovery);
    expect(countdown().style!.color, colors.amber, reason: 'eased back');
    nearby.endVisible();
    await tester.pump(const Duration(seconds: 7));
  });

  test(
    'manual shutdown sounds once, then an incoming hit plays the death recording',
    () async {
      final (state, transport) = await _homeState();
      addTearDown(state.dispose);
      final sounds = <SyblSoundEvent>[];
      final subscription = state.soundEvents.listen(sounds.add);
      addTearDown(subscription.cancel);
      final destroyed = state.nearby!.combat.firstWhere(
        (event) => event.cue == SonarCue.destroyed,
      );
      expect(state.revealNearby(), isTrue);
      transport.fire(_maraId, 200, 6);
      await pumpEventQueue();
      state.nearby!.shutdown();
      await destroyed.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(state.nearby!.destroyed, isTrue);
      expect(sounds.where((s) => s == SyblSoundEvent.sonarOff), hasLength(1));
      expect(sounds, contains(SyblSoundEvent.sonarIncomingMissileKill));
      expect(sounds, isNot(contains(SyblSoundEvent.sonarIncomingMissileHit)));
      expect(sounds, contains(SyblSoundEvent.stopMissileEnRoute));
    },
  );

  testWidgets('a newcomer arrives through a door, then Add sends once', (
    tester,
  ) async {
    var closed = 0;
    final (state, transport) = await _openNearby(
      tester,
      onClose: () => closed++,
    );
    await tester.runAsync(() async {
      transport.announce(_linaId, 'Lina');
      await pumpEventQueue();
    });
    await tester.pump();
    final add = find.byKey(const ValueKey('nearby-add-$_linaId'));
    expect(add, findsOneWidget);
    expect(_opacity(tester, add), 0, reason: 'still coming through the door');
    await tester.pumpAndSettle();
    expect(_opacity(tester, add), 1);
    expect(tester.hasRunningAnimations, isFalse, reason: 'the door is gone');
    expect(find.bySemanticsLabel('Add Lina'), findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(state.added, [_linaId]);
    expect(state.hints, ['Lina']);
    // Sent from Nearby, which leaves straight for the new chat.
    expect(find.byType(FriendConnectionPage), findsNothing);
    expect(closed, 1);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('reduced motion shows a newcomer at once', (tester) async {
    final (_, transport) = await _openNearby(tester, reduceMotion: true);
    expect(find.byKey(const ValueKey('nearby-wave-landed')), findsOneWidget);
    await tester.runAsync(() async {
      transport.announce(_linaId, 'Lina');
      await pumpEventQueue();
    });
    await tester.pump();
    final add = find.byKey(const ValueKey('nearby-add-$_linaId'));
    expect(add, findsOneWidget);
    expect(_opacity(tester, add), 1);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('a ping rings the bell, which opens Sonar', (tester) async {
    late _State state;
    late _Transport transport;
    await tester.runAsync(() async {
      (state, transport) = await _homeState();
    });
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: Center(child: NotificationBell(state: state)),
        ),
      ),
    );
    final badge = find.byKey(const ValueKey('nearby-wave-badge'));
    expect(tester.widget<AnimatedScale>(badge).scale, 0);

    await tester.tap(find.byKey(const ValueKey('notification-bell')));
    await tester.pumpAndSettle();
    expect(find.text('No notifications'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      transport.announce(_maraId, 'Mara', ping: true);
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(badge).scale, 1);

    final before = sonarOpenRequests.value;
    await tester.tap(find.byKey(const ValueKey('notification-bell')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A device is pinging you'));
    await tester.pumpAndSettle();
    expect(sonarOpenRequests.value, before + 1);
  });

  testWidgets('a received wave lands on you with a haptic', (tester) async {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    late _State state;
    late _Transport transport;
    await tester.runAsync(() async {
      (state, transport) = await _homeState();
    });
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: AddFriendPane(
            state: state,
            onClose: () {},
            isCurrent: () => true,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      transport.announce(_maraId, 'Mara');
      await pumpEventQueue();
    });
    await tester.tap(find.byKey(const ValueKey('connection-nearby')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('nearby-wave-landed')), findsNothing);
    expect(haptics, isEmpty);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nearby-wave-landed')), findsOneWidget);
    expect(find.bySemanticsLabel('Mara waved at you'), findsOneWidget);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('eight people on a small phone never overlap their Add', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ids = [for (var i = 0; i < 8; i++) '$i' * 40];
    await _openNearby(tester, before: {for (final id in ids) id: 'P${id[0]}'});
    final rects = [
      for (final id in ids)
        tester.getRect(find.byKey(ValueKey('nearby-add-$id'))),
    ];
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].overlaps(rects[j]),
          isFalse,
          reason: '${ids[i]} and ${ids[j]}',
        );
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
  });
}
