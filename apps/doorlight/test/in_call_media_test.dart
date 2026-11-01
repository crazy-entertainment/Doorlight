import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/in_call.dart';
import 'package:sybl/state/annotation.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/theme.dart';

class _MicJami extends JamiClient {
  @override
  Future<void> setMicMuted(String callId, bool muted) async {}
}

class _WindowsAppState extends AppState {
  _WindowsAppState(super.jami, super.prefs);

  @override
  bool get speakerControlAvailable => false;

  @override
  bool get outputPickerAvailable => true;
}

class _MobileAppState extends AppState {
  _MobileAppState(super.jami, super.prefs);

  @override
  bool get speakerControlAvailable => true;

  @override
  bool get outputPickerAvailable => false;
}

void main() {
  testWidgets('phone controls prioritize mic and hangup in two stable rows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _MobileAppState(
      _MicJami(),
      await SharedPreferences.getInstance(),
    );
    addTearDown(state.dispose);
    state.jamiId = 'a' * 40;
    state.call = CallSession(
      callId: 'mobile-controls',
      dir: CallDir.outgoing,
      peerId: 'b' * 40,
      state: 'CURRENT',
      microphonePolicyApplied: true,
    );
    Widget app() => MaterialApp(
      theme: Warm.theme().copyWith(platform: TargetPlatform.android),
      home: InCallScreen(state: state),
    );

    await tester.pumpWidget(app());
    final keys = <ValueKey<String>>[
      const ValueKey('call-mic-control'),
      const ValueKey('call-camera-control'),
      const ValueKey('call-speaker-control'),
      const ValueKey('call-share-control'),
      const ValueKey('call-hang-up-control'),
    ];
    final voiceCenters = {
      for (final key in keys) key: tester.getCenter(find.byKey(key)),
    };
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byKey(keys.first),
                  matching: find.byType(Container),
                )
                .first,
          )
          .width,
      88,
    );
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byKey(keys.last),
                  matching: find.byType(SizedBox),
                )
                .first,
          )
          .width,
      88,
    );

    expect(voiceCenters[keys.first]!.dy, voiceCenters[keys.last]!.dy);
    for (final key in keys.sublist(1, 4)) {
      expect(voiceCenters[key]!.dy, lessThan(voiceCenters[keys.first]!.dy));
      expect(voiceCenters[key]!.dy, voiceCenters[keys[1]]!.dy);
    }
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byKey(keys[1]),
                  matching: find.byType(SizedBox),
                )
                .first,
          )
          .width,
      48,
    );
    expect(tester.takeException(), isNull);

    state.call!.outgoingVideo = const OutgoingVideoSource(
      kind: OutgoingVideoKind.camera,
      revision: 1,
      width: 720,
      height: 1280,
    );
    await tester.pumpWidget(app());
    for (final key in keys) {
      expect(
        tester.getCenter(find.byKey(key)).dx,
        closeTo(voiceCenters[key]!.dx, .01),
        reason: '$key must not jump sideways when video starts',
      );
    }
  });

  testWidgets('Windows output control remains available in a video call', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _WindowsAppState(
      _MicJami(),
      await SharedPreferences.getInstance(),
    );
    addTearDown(state.dispose);
    state.jamiId = 'a' * 40;
    state.call = CallSession(
      callId: 'video-call',
      dir: CallDir.outgoing,
      peerId: 'b' * 40,
      state: 'CURRENT',
      peerVideo: true,
      peerVideoKind: OutgoingVideoKind.camera,
      microphonePolicyApplied: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: InCallScreen(state: state),
      ),
    );

    expect(find.byKey(const ValueKey('call-output-control')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-speaker-control')), findsNothing);
  });

  testWidgets(
    'announced peer screen shows Control when libjami reports only video',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = _WindowsAppState(
        _MicJami(),
        await SharedPreferences.getInstance(),
      );
      addTearDown(state.dispose);
      state.jamiId = 'a' * 40;
      state.seedEmptyRuntimeSnapshotForTesting(
        selectedPeerId: 'b' * 40,
        friends: [
          FriendState(
            peerId: 'b' * 40,
            confirmed: true,
            conversationId: 'screen-dm',
          ),
        ],
      );
      state.call = CallSession(
        callId: 'remote-screen',
        dir: CallDir.outgoing,
        peerId: 'b' * 40,
        state: 'CURRENT',
        peerVideo: true,
        // Remote SDP has no SOURCE, so libjami cannot identify screen here.
        peerVideoKind: OutgoingVideoKind.camera,
        remoteActive: true,
        remoteWidth: 1080,
        remoteHeight: 2400,
        microphonePolicyApplied: true,
      );
      state.annotation.syncSources(
        localOwner: state.jamiId,
        peerOwner: state.call!.peerId,
        localRevision: 0,
        localKind: OutgoingVideoKind.off,
        peerKind: OutgoingVideoKind.camera,
        peerSourceChanged: true,
      );
      state.annotation.applyInbound(
        jsonEncode({
          'v': 1,
          't': 'src',
          'sourceOwner': state.call!.peerId,
          'sourceRevision': 7,
          'sourceKind': 'screen',
          'platform': 'android',
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: InCallScreen(state: state),
        ),
      );

      final draw = find.byKey(const ValueKey('annotation-draw-toggle'));
      final control = find.byKey(const ValueKey('remote-control-request'));
      expect(draw, findsOneWidget);
      expect(control, findsOneWidget);
      expect(
        tester.getTopLeft(control).dy,
        greaterThan(tester.getTopLeft(draw).dy),
      );
    },
  );

  testWidgets('desktop media controls expose every interactive state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _WindowsAppState(
      _MicJami(),
      await SharedPreferences.getInstance(),
    );
    addTearDown(state.dispose);
    state.jamiId = 'a' * 40;
    state.call = CallSession(
      callId: 'desktop-control-states',
      dir: CallDir.outgoing,
      peerId: 'b' * 40,
      state: 'CURRENT',
      peerVideo: true,
      microphonePolicyApplied: true,
    );
    Widget app() => MaterialApp(
      theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
      home: InCallScreen(state: state),
    );
    IconButton button(ValueKey<String> key) => tester.widget<IconButton>(
      find.descendant(of: find.byKey(key), matching: find.byType(IconButton)),
    );
    Color background(IconButton button, Set<WidgetState> states) =>
        button.style!.backgroundColor!.resolve(states)!;

    await tester.pumpWidget(app());
    final inactiveCamera = button(const ValueKey('call-camera-control'));
    final idle = background(inactiveCamera, const {});
    expect(inactiveCamera.onPressed, isNotNull);
    expect(
      background(inactiveCamera, const {WidgetState.hovered}),
      isNot(idle),
    );
    expect(
      background(inactiveCamera, const {WidgetState.pressed}),
      isNot(idle),
    );

    state.call!.outgoingVideo = const OutgoingVideoSource(
      kind: OutgoingVideoKind.camera,
      revision: 2,
      width: 1280,
      height: 720,
    );
    state.notifyListeners();
    await tester.pumpWidget(app());
    expect(
      background(button(const ValueKey('call-camera-control')), const {}),
      isNot(idle),
      reason: 'active camera has a dominant fill',
    );

    state.call!.sourceChanging = true;
    state.notifyListeners();
    await tester.pumpWidget(app());
    final disabledShare = button(const ValueKey('call-share-control'));
    expect(disabledShare.onPressed, isNull);
    expect(
      background(disabledShare, const {WidgetState.disabled}),
      isNot(background(disabledShare, const {})),
    );
  });

  testWidgets(
    'local Android-style screen share never hides the peer camera or renders two camera-off tiles',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      addTearDown(state.dispose);
      state.jamiId = 'a' * 40;
      state.call = CallSession(
        callId: 'call',
        dir: CallDir.outgoing,
        peerId: 'b' * 40,
        state: 'CURRENT',
        outgoingVideo: const OutgoingVideoSource(
          kind: OutgoingVideoKind.screen,
          revision: 7,
          width: 1080,
          height: 2400,
        ),
        peerVideo: true,
        peerVideoKind: OutgoingVideoKind.camera,
      );
      state.annotation.syncSources(
        localOwner: state.jamiId,
        peerOwner: state.call!.peerId,
        localRevision: 7,
        localKind: OutgoingVideoKind.screen,
        peerKind: OutgoingVideoKind.camera,
        peerSourceChanged: true,
      );

      Widget app() => MaterialApp(
        theme: Warm.theme(),
        home: InCallScreen(state: state),
      );
      await tester.pumpWidget(app());

      expect(find.text('connecting their camera…'), findsOneWidget);
      expect(find.text('My screen'), findsOneWidget);
      expect(find.text('camera off'), findsNothing);

      state.call!.peerVideoKind = OutgoingVideoKind.screen;
      state.notifyListeners();
      await tester.pumpWidget(app());
      expect(find.text('connecting their screen…'), findsOneWidget);
      expect(find.text('connecting their camera…'), findsNothing);

      state.call!.peerVideoKind = OutgoingVideoKind.camera;
      state.notifyListeners();
      await tester.pumpWidget(app());
      await tester.tap(find.text('My screen'));
      await tester.pump();

      expect(find.text('Starting your screen…'), findsOneWidget);
      expect(find.text('Their camera'), findsOneWidget);
      expect(find.text('camera off'), findsNothing);
      expect(state.annotation.target, AnnotationTarget.mine);

      state.call!
        ..selfTextureId = 9
        ..selfActive = true
        ..selfWidth = 1080
        ..selfHeight = 2400;
      state.notifyListeners();
      await tester.pumpWidget(app());
      expect(find.text('Starting your screen…'), findsNothing);
      expect(find.byType(Texture), findsWidgets);
      await tester.pump(const Duration(milliseconds: 33));
    },
  );

  testWidgets(
    'legacy voice mode is presented as open mic without voice activity UI',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(_MicJami(), await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      state.jamiId = 'a' * 40;
      state.call = CallSession(
        callId: 'voice-call',
        dir: CallDir.outgoing,
        peerId: 'b' * 40,
        state: 'CURRENT',
        micMode: MicrophoneMode.voiceActivated,
        microphonePolicyApplied: true,
      );

      Widget app() => MaterialApp(
        theme: Warm.theme(),
        home: InCallScreen(state: state),
      );

      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app());
      // Mic modes now live behind the chevron on the mic button.
      expect(find.byKey(const ValueKey('mic-mode-chevron')), findsOneWidget);
      expect(find.text('Voice-activated'), findsNothing);
      expect(find.byKey(const Key('voice-activity-status')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mic-mode-chevron')));
      await tester.pumpAndSettle();
      expect(find.text('Open mic'), findsOneWidget);
      expect(find.text('Push to talk'), findsOneWidget);
      expect(find.text('Voice-activated'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(state.call!.micMuted, isTrue);
      await tester.pumpWidget(app());
      expect(find.text('Muted'), findsNothing);
      expect(find.bySemanticsLabel('Muted'), findsOneWidget);
      semantics.dispose();
    },
  );
}
