import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/main.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/ui/sybl_ui.dart';

const _peer = '2222222222222222222222222222222222222222';

final Finder _card = find.byKey(const ValueKey('account-card'));

/// The decoration actually painted, rather than the target the
/// `AnimatedContainer` is heading towards.
BoxDecoration _paintedRing(WidgetTester tester) =>
    tester
            .renderObject<RenderDecoratedBox>(
              find
                  .descendant(of: _card, matching: find.byType(DecoratedBox))
                  .first,
            )
            .decoration
        as BoxDecoration;

({double min, double max}) _ringAlpha(BoxDecoration ring) {
  final colors = (ring.gradient! as SweepGradient).colors;
  return (
    min: colors.fold(1.0, (low, c) => c.a < low ? c.a : low),
    max: colors.fold(0.0, (high, c) => c.a > high ? c.a : high),
  );
}

/// Longer than the 180 ms implicit swap, and never `pumpAndSettle`, which the
/// repeating pre-connect spin would stall forever.
Future<void> _settleRing(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Plays the native side of Android sensitive-surface protection.
class _SecureSurfaceJami extends JamiClient {
  @override
  Future<bool> setAndroidSensitiveSurface({required bool visible}) async =>
      visible;
}

class _StableAppState extends AppState {
  _StableAppState(super.jami, super.prefs);

  @override
  Future<void> init() async {}
}

Future<_StableAppState> _callState() async {
  SharedPreferences.setMockInitialValues({});
  final state =
      _StableAppState(
          _SecureSurfaceJami(),
          await SharedPreferences.getInstance(),
        )
        ..screen = Screen.home
        ..displayName = 'You'
        ..jamiId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        ..registration = 'REGISTERED'
        ..call = CallSession(
          callId: 'call',
          dir: CallDir.outgoing,
          peerId: _peer,
          state: 'CURRENT',
        );
  state.seedEmptyRuntimeSnapshotForTesting(
    selectedPeerId: _peer,
    friends: const [
      FriendState(
        peerId: _peer,
        confirmed: true,
        conversationId: 'conversation',
        displayName: 'Phone A',
        presence: PeerPresence.inApp,
      ),
    ],
  );
  // The Windows capture gate is not under test here; resolve it so the shell
  // renders.
  state.seedCaptureStateForTesting(
    resolved: true,
    applied: WindowCaptureProtectionStatus.exclude,
  );
  return state;
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required AppState state,
  Size size = const Size(800, 450),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(SyblApp(state: state));
  await tester.pump();
}

void main() {
  testWidgets(
    'Doorlight motion follows its own setting, independently of Windows',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final state = await _callState();
      addTearDown(state.dispose);
      await _pumpApp(tester, state: state);
      final surface = find.byKey(const ValueKey('account-card'));
      expect(MediaQuery.disableAnimationsOf(tester.element(surface)), isFalse);
      state.appSettings = state.appSettings.withChatMotionEnabled(false);
      state.notifyListeners();
      await tester.pump();
      expect(MediaQuery.disableAnimationsOf(tester.element(surface)), isTrue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: false);
      await tester.pump();
      expect(MediaQuery.disableAnimationsOf(tester.element(surface)), isTrue);
      state.appSettings = state.appSettings.withChatMotionEnabled(true);
      state.notifyListeners();
      await tester.pump();
      expect(MediaQuery.disableAnimationsOf(tester.element(surface)), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  testWidgets(
    'a later invitation requires replacement after the original card closes',
    (tester) async {
      final state = await _callState();
      addTearDown(state.dispose);
      state.call = null;
      state.accountId = 'fixture';
      state.inviteContinuation.stage('doorlight://add/${'b' * 40}?name=Mara');
      await _pumpApp(tester, state: state, size: const Size(800, 700));
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Add Mara'), findsOneWidget);
      state.inviteContinuation.stage('doorlight://add/${'c' * 40}?name=Lee');
      await tester.pump();
      expect(find.text('Add Mara'), findsOneWidget);
      expect(find.text('Add Lee'), findsNothing);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Open a different invitation?'), findsOneWidget);
      await tester.tap(find.text('Replace invitation'));
      await tester.pumpAndSettle();
      expect(find.text('Add Lee'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(state.pendingInvite, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'capture gating preserves an open invitation for a fresh confirmation',
    (tester) async {
      final state = await _callState();
      addTearDown(state.dispose);
      state.call = null;
      state.accountId = 'fixture';
      state.inviteContinuation.stage('sybl://add/${'b' * 40}?name=Mara');
      final record = state.inviteContinuation.pending;
      await _pumpApp(tester, state: state, size: const Size(800, 700));
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Add Mara'), findsOneWidget);
      state.seedCaptureStateForTesting(
        resolved: false,
        applied: WindowCaptureProtectionStatus.exclude,
      );
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Add Mara'), findsNothing);
      expect(state.inviteContinuation.pending, same(record));
      state.seedCaptureStateForTesting(
        resolved: true,
        applied: WindowCaptureProtectionStatus.exclude,
      );
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Add Mara'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final shownBeforeGate in [false, true]) {
    testWidgets(
      'capture gate removes ${shownBeforeGate ? 'visible' : 'deferred'} private snackbars',
      (tester) async {
        final state = await _callState();
        addTearDown(state.dispose);
        await _pumpApp(tester, state: state, size: const Size(800, 600));
        state.callEndedNote = 'Private call result';
        state.notifyListeners();
        if (shownBeforeGate) {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Private call result'), findsOneWidget);
        }
        state.seedCaptureStateForTesting(
          resolved: false,
          applied: WindowCaptureProtectionStatus.exclude,
        );
        state.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey('capture-consent-gate')),
          findsOneWidget,
        );
        expect(find.text('Private call result'), findsNothing);
        expect(state.visibleConversationPeerId, isNull);
        expect(state.call?.callId, 'call');
        state.seedCaptureStateForTesting(
          resolved: true,
          applied: WindowCaptureProtectionStatus.exclude,
        );
        state.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Private call result'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'Windows call leaves the chat still with direct header controls',
    (tester) async {
      final state = await _callState();
      addTearDown(state.dispose);

      await _pumpApp(tester, state: state);

      expect(find.byKey(const ValueKey('friend-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-call-stage')), findsNothing);
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-call-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-call-mic')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-call-video')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-call-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-call-leave')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-active-call-button')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'mobile outgoing audio call stays in the DM until explicitly opened',
    (tester) async {
      final state = await _callState();
      addTearDown(state.dispose);
      state.call = null;

      await _pumpApp(tester, state: state, size: const Size(390, 844));
      await tester.tap(find.text('Phone A'));
      await tester.pumpAndSettle();
      state.call = CallSession(
        callId: 'call',
        dir: CallDir.outgoing,
        peerId: _peer,
        state: 'CURRENT',
      );
      state.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('compact-call-stage')), findsNothing);
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(find.byKey(const ValueKey('friend-list')), findsNothing);
      expect(
        find.byKey(const ValueKey('open-active-call-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('open-active-call-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('compact-call-stage')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-composer')), findsNothing);
      expect(
        find.byKey(const ValueKey('minimize-call-button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('minimize-call-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('compact-call-stage')), findsNothing);
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(find.text('Phone A'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'mobile incoming call slides over People before the answer screen',
    (tester) async {
      final state = await _callState();
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'incoming',
        dir: CallDir.incoming,
        peerId: _peer,
        state: 'RINGING',
      );

      await _pumpApp(tester, state: state, size: const Size(390, 844));

      expect(find.byKey(const ValueKey('friend-list')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('incoming-call-banner-incoming')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chat-composer')), findsNothing);
      final entryGate = tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byKey(const ValueKey('incoming-call-banner-incoming')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(entryGate.ignoring, isTrue);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('open-incoming-call')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(); // Native confirms the sensitive surface.

      expect(find.text('incoming call'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('minimize-call-button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'mobile account card spins while connecting and is solid when connected',
    (tester) async {
      final state = await _callState();
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'connecting',
        dir: CallDir.outgoing,
        peerId: _peer,
        state: 'CONNECTING',
      );

      await _pumpApp(tester, state: state, size: const Size(390, 844));
      await _settleRing(tester);

      expect(find.textContaining('calling Phone A'), findsOneWidget);
      final cardRect = tester.getRect(_card);
      final avatarRect = tester.getRect(
        find.descendant(of: _card, matching: find.byType(SyblAvatar)),
      );
      final connecting = _paintedRing(tester);
      expect(connecting.gradient, isA<SweepGradient>());
      expect(
        connecting.color,
        isNull,
        reason: 'a flat fill would be hidden under the gradient anyway',
      );
      expect(_ringAlpha(connecting).min, lessThan(.35), reason: 'a segment');
      expect(_ringAlpha(connecting).max, greaterThan(.65), reason: 'is lit');
      final firstAngle =
          ((connecting.gradient! as SweepGradient).transform
                  as GradientRotation)
              .radians;
      await tester.pump(const Duration(milliseconds: 16));
      final nextAngle =
          ((_paintedRing(tester).gradient! as SweepGradient).transform
                  as GradientRotation)
              .radians;
      expect(nextAngle, isNot(firstAngle), reason: 'the visible ring rotates');

      state.call = CallSession(
        callId: 'connected',
        dir: CallDir.outgoing,
        peerId: _peer,
        state: 'CURRENT',
      );
      state.notifyListeners();
      // Halfway through the 180 ms swap. The rendered decoration is where a
      // fade-out-then-pop shows up; the AnimatedContainer's own target cannot.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final mid = _paintedRing(tester);
      expect(mid.gradient, isA<SweepGradient>());
      expect(
        _ringAlpha(mid).min,
        greaterThan(0),
        reason: 'the ring fills in rather than emptying out',
      );
      expect(_ringAlpha(mid).max, greaterThan(.95));

      await tester.pumpAndSettle();
      final connected = _paintedRing(tester);
      expect(
        _ringAlpha(connected).min,
        greaterThan(.95),
        reason: 'one complete outline',
      );
      expect(connected.color, isNull);

      state.call = null;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(_paintedRing(tester).gradient, isNull, reason: 'nothing frozen');

      // The outline never took space of its own.
      expect(tester.getRect(_card), cardRect);
      expect(
        tester.getRect(
          find.descendant(of: _card, matching: find.byType(SyblAvatar)),
        ),
        avatarRect,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
