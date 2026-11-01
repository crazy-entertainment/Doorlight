import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/in_call.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/state/remote_control.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/remote_control_surface.dart';

const _peer = '0123456789abcdef0123456789abcdef01234567';
const _otherPeer = '1123456789abcdef0123456789abcdef01234567';
const _device = 'abcdef0123456789abcdef0123456789abcdef01';

class _RemoteJami extends JamiClient {
  final List<String> operations = [];
  RemoteControlHostAuthority authority = const RemoteControlHostAuthority(
    channelEpoch: 1,
    surfaceRevision: 0,
    hostGeneration: 0,
    revokedThrough: 0,
    blocked: true,
    releaseComplete: true,
    state: 'inactive',
  );
  @override
  Future<RemoteControlHostAuthority?> remoteControlHostAuthority() async =>
      authority;
  @override
  Future<RemoteControlHostAuthority?> setRemoteControlProtectedSurface({
    required int channelEpoch,
    required int surfaceRevision,
    required bool blocked,
  }) async {
    operations.add(blocked ? 'surface-block' : 'surface-open');
    authority = RemoteControlHostAuthority(
      channelEpoch: channelEpoch,
      surfaceRevision: surfaceRevision,
      hostGeneration: 0,
      revokedThrough: blocked ? 1 : authority.revokedThrough,
      blocked: blocked,
      releaseComplete: true,
      state: 'inactive',
    );
    return authority;
  }

  @override
  Future<bool> openRemoteControlAccessibilitySettings() async {
    operations.add('open-accessibility-settings');
    return true;
  }

  @override
  Future<bool> requestRemoteControl({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required List<String> capabilities,
    required String identityColor,
    required String androidPacket,
  }) async {
    operations.add('request:$callId:$sourceRevision');
    return true;
  }

  @override
  Future<bool> sendRemoteControlInput({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required List<List<Object>> events,
    required String androidPacket,
  }) async {
    operations.add('input:$callId:$sourceRevision');
    return true;
  }

  @override
  Future<bool> endRemoteControl({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required String androidPacket,
  }) async {
    operations.add('end:$callId:$sourceRevision');
    return true;
  }

  @override
  Future<bool> denyRemoteControl({
    required String callId,
    required String controllerAccountId,
    required String controllerDeviceId,
    required int sourceRevision,
    required int hostGeneration,
  }) async {
    operations.add('deny:$callId:$sourceRevision');
    return true;
  }

  @override
  Future<bool> stopRemoteControlHost() async {
    operations.add('stop-host');
    return true;
  }
}

Future<AppState> _state(
  _RemoteJami jami, {
  bool includeOtherPeer = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(jami, prefs)
    ..jamiId = 'fedcba9876543210fedcba9876543210fedcba98';
  state.seedEmptyRuntimeSnapshotForTesting(
    selectedPeerId: _peer,
    friends: [
      FriendState(
        peerId: _peer,
        confirmed: true,
        conversationId: 'conversation',
        displayName: 'Alex',
      ),
      if (includeOtherPeer)
        const FriendState(
          peerId: _otherPeer,
          confirmed: true,
          conversationId: 'other-conversation',
          displayName: 'Morgan',
        ),
    ],
  );
  // This fixture renders a live call without booting the application. Match
  // the confirmed protection state required before that surface is available.
  state.seedCaptureStateForTesting(
    resolved: true,
    applied: WindowCaptureProtectionStatus.exclude,
  );
  return state;
}

Widget _app(AppState state, {double textScale = 1, GlobalKey? boundary}) =>
    MaterialApp(
      theme: Warm.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(key: boundary, child: child!),
      ),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) => InCallScreen(state: state),
      ),
    );

void main() {
  setUpAll(() async {
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'Android setup discloses Accessibility access before opening settings',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final jami = _RemoteJami();
      final state = await _state(jami);
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'host-call',
        dir: CallDir.outgoing,
        peerId: _peer,
        state: 'CURRENT',
        outgoingVideo: const OutgoingVideoSource(
          kind: OutgoingVideoKind.screen,
          revision: 9,
          width: 1080,
          height: 1920,
        ),
      );

      await tester.pumpWidget(_app(state));
      final setup = find.byKey(
        const Key('remote-control-android-accessibility'),
      );
      expect(find.text('Set up remote help'), findsOneWidget);
      expect(
        tester.getRect(setup).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('call-control-row'))).top,
        ),
      );
      expect(tester.getRect(setup).left, 12);
      await tester.tap(setup);
      await tester.pumpAndSettle();

      expect(find.text('Remote help permission'), findsOneWidget);
      expect(
        find.textContaining('Doorlight remote help and enable the service'),
        findsOneWidget,
      );
      expect(jami.operations, isNot(contains('open-accessibility-settings')));

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(jami.operations, isNot(contains('open-accessibility-settings')));

      await tester.tap(
        find.byKey(const Key('remote-control-android-accessibility')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(jami.operations, contains('open-accessibility-settings'));

      state.remoteControlAccessibilityEnabled = true;
      state.notifyListeners();
      await tester.pump();
      expect(find.text('Remote help permission enabled'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(setup).onPressed, isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('manual app lock retires pending and active remote authority', () async {
    final hostJami = _RemoteJami();
    final hostState = await _state(hostJami);
    addTearDown(hostState.dispose);
    hostState.call = CallSession(
      callId: 'host-call',
      dir: CallDir.outgoing,
      peerId: _peer,
      state: 'CURRENT',
      outgoingVideo: const OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        revision: 9,
        width: 1920,
        height: 1080,
      ),
    );
    hostState.remoteControl.syncCall(
      live: true,
      foreground: true,
      callId: 'host-call',
      peerId: _peer,
      peerScreenActive: false,
      peerSourceRevision: null,
      localScreenActive: true,
      localSourceRevision: 9,
    );
    hostState.remoteControl.applyNativeHostRequest({
      'callId': 'host-call',
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 1,
      'controlCapabilities': 15,
      'persistentAvailable': true,
    });
    expect(hostState.remoteControl.hostRequest, isNotNull);

    hostState.setProtectedSurfaceLocked(true);
    await pumpEventQueue();

    expect(hostState.remoteControl.hostRequest, isNull);
    expect(hostJami.operations, contains('deny:host-call:9'));

    hostState.setProtectedSurfaceLocked(false);
    hostState.remoteControl.applyNativeHostRequest({
      'callId': 'host-call',
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 2,
      'controlCapabilities': 15,
      'persistentAvailable': true,
    });
    hostState.remoteControl.applyNativeHostState({
      'callId': 'host-call',
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 2,
      'state': 'active',
    });
    expect(hostState.remoteControl.hostActive, isTrue);
    hostState.setProtectedSurfaceLocked(true);
    await pumpEventQueue();
    expect(hostState.remoteControl.hostActive, isFalse);
    expect(hostJami.operations, contains('stop-host'));

    final controllerJami = _RemoteJami();
    final controllerState = await _state(controllerJami);
    addTearDown(controllerState.dispose);
    controllerState.call = CallSession(
      callId: 'controller-call',
      dir: CallDir.outgoing,
      peerId: _peer,
      state: 'CURRENT',
      peerVideo: true,
      peerVideoKind: OutgoingVideoKind.screen,
      remoteActive: true,
      remoteWidth: 1920,
      remoteHeight: 1080,
    );
    controllerState.annotation.syncSources(
      localOwner: controllerState.jamiId,
      peerOwner: _peer,
      localRevision: 1,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.screen,
    );
    controllerState.annotation.applyInbound(
      '{"v":1,"t":"src","sourceOwner":"$_peer",'
      '"sourceRevision":4,"sourceKind":"screen"}',
    );
    controllerState.remoteControl.syncCall(
      live: true,
      foreground: true,
      callId: 'controller-call',
      peerId: _peer,
      peerScreenActive: true,
      peerSourceRevision: 4,
      localScreenActive: false,
      localSourceRevision: 1,
    );
    expect(await controllerState.requestRemoteControl(), isTrue);
    controllerState.remoteControl.applyNativeControllerState({
      'callId': 'controller-call',
      'peerJamiId': _peer,
      'peerDeviceId': _device,
      'sourceRevision': 4,
      'controlCapabilities': 15,
      'state': 'active',
    });
    expect(controllerState.remoteControl.isControlling, isTrue);

    controllerState.setProtectedSurfaceLocked(true);
    await pumpEventQueue();

    expect(controllerState.remoteControl.isControlling, isFalse);
    expect(controllerJami.operations, contains('end:controller-call:4'));
  });

  testWidgets('screen viewer can request and always stop remote control', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final jami = _RemoteJami();
    final state = await _state(jami);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'call-1',
      dir: CallDir.outgoing,
      peerId: _peer,
      state: 'CURRENT',
      peerVideo: true,
      peerVideoKind: OutgoingVideoKind.screen,
      remoteActive: true,
      remoteWidth: 1920,
      remoteHeight: 1080,
    );
    state.annotation.syncSources(
      localOwner: state.jamiId,
      peerOwner: _peer,
      localRevision: 1,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.screen,
    );
    await tester.pumpWidget(_app(state));
    expect(find.byKey(const Key('remote-control-preparing')), findsNothing);
    expect(find.byKey(const Key('remote-control-request')), findsNothing);

    state.annotation.applyInbound(
      '{"v":1,"t":"src","sourceOwner":"$_peer",'
      '"sourceRevision":4,"sourceKind":"screen","platform":"windows"}',
    );
    await tester.pump();
    expect(find.text('Alex'), findsOneWidget);
    expect(find.byKey(const Key('remote-control-request')), findsOneWidget);
    expect(
      find.byTooltip('Request temporary control of their mouse and keyboard.'),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.byKey(const Key('remote-control-request'))).top,
      greaterThan(
        tester
            .getRect(find.byKey(const ValueKey('annotation-draw-toggle')))
            .bottom,
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('remote-control-request')),
        matching: find.byIcon(Icons.near_me_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('remote-control-request')));
    await tester.pump();
    expect(jami.operations, contains('request:call-1:4'));
    expect(find.text('Asking Alex…'), findsOneWidget);

    state.remoteControl.applyNativeControllerState({
      'callId': 'call-1',
      'peerJamiId': _peer,
      'peerDeviceId': _device,
      'sourceRevision': 4,
      'controlCapabilities': 117,
      'state': 'active',
    });
    await tester.pump();
    final hud = find.byKey(const Key('remote-control-controller-hud'));
    expect(find.byKey(const Key('remote-control-stop')), findsOneWidget);
    expect(find.byKey(const Key('remote-control-active')), findsNothing);
    expect(find.text('Controlling Alex'), findsNothing);
    expect(hud, findsOneWidget);
    expect(tester.getSize(hud).width, lessThanOrEqualTo(140));
    expect(
      tester.getRect(hud).right,
      moreOrLessEquals(tester.getSize(find.byType(InCallScreen)).width - 12),
    );
    expect(
      tester.getSize(find.byKey(const Key('remote-control-stop'))).width,
      lessThanOrEqualTo(44),
    );
    expect(
      tester.getRect(find.byType(RemoteControlSurface)).right,
      lessThanOrEqualTo(tester.getRect(hud).left),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('call-control-row'))).left,
      greaterThanOrEqualTo(
        tester.getRect(find.byType(RemoteControlSurface)).right,
      ),
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(const ValueKey('remote-control-target-icon')),
          )
          .icon,
      Icons.phone_android_outlined,
    );

    await tester.tap(find.byKey(const Key('remote-control-stop')));
    await tester.pumpAndSettle();
    expect(state.remoteControl.phase, RemoteControlPhase.ended);
    expect(jami.operations, contains('end:call-1:4'));
    expect(find.byKey(const Key('remote-control-stop')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('control rail uses a touch gesture for an Android target', (
    tester,
  ) async {
    final jami = _RemoteJami();
    final state = await _state(jami);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'call-phone',
      dir: CallDir.outgoing,
      peerId: _peer,
      state: 'CURRENT',
      peerVideo: true,
      peerVideoKind: OutgoingVideoKind.screen,
      remoteActive: true,
      remoteWidth: 1080,
      remoteHeight: 1920,
    );
    state.annotation.syncSources(
      localOwner: state.jamiId,
      peerOwner: _peer,
      localRevision: 1,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.screen,
    );
    const source =
        '{"v":1,"t":"src","sourceOwner":"$_peer",'
        '"sourceRevision":4,"sourceKind":"screen"}';
    state.annotation.applyInbound(source);

    await tester.pumpWidget(_app(state));

    final request = find.byKey(const Key('remote-control-request'));
    expect(request, findsOneWidget);
    expect(
      find.byTooltip('Request temporary control of their shared device.'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: request,
        matching: find.byIcon(Icons.ads_click_outlined),
      ),
      findsOneWidget,
    );

    state.annotation.applyInbound(
      source.replaceFirst('}', ',"platform":"android"}'),
    );
    await tester.pump();
    expect(
      find.byTooltip(
        'Request temporary control of their phone: taps, scrolling, typing, Back, Home and Recents.',
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: request,
        matching: find.byIcon(Icons.touch_app_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'draw and control are explicit mutually exclusive pointer modes',
    (tester) async {
      final jami = _RemoteJami();
      final state = await _state(jami);
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'call-modes',
        dir: CallDir.outgoing,
        peerId: _peer,
        state: 'CURRENT',
        peerVideo: true,
        peerVideoKind: OutgoingVideoKind.screen,
        remoteActive: true,
        remoteWidth: 1920,
        remoteHeight: 1080,
      );
      state.annotation.syncSources(
        localOwner: state.jamiId,
        peerOwner: _peer,
        localRevision: 1,
        localKind: OutgoingVideoKind.off,
        peerKind: OutgoingVideoKind.screen,
      );
      state.annotation.applyInbound(
        '{"v":1,"t":"src","sourceOwner":"$_peer",'
        '"sourceRevision":4,"sourceKind":"screen"}',
      );
      state.remoteControl.syncCall(
        live: true,
        foreground: true,
        callId: 'call-modes',
        peerId: _peer,
        peerScreenActive: true,
        peerSourceRevision: 4,
        localScreenActive: false,
        localSourceRevision: 1,
      );
      state.setAnnotationEnabled(true);

      await tester.pumpWidget(_app(state));
      expect(state.callInteractionMode, CallInteractionMode.draw);

      await tester.tap(find.byKey(const Key('remote-control-request')));
      await tester.pump();
      expect(state.annotation.enabled, isFalse);
      expect(state.callInteractionMode, CallInteractionMode.requestingControl);

      state.remoteControl.applyNativeControllerState({
        'callId': 'call-modes',
        'peerJamiId': _peer,
        'peerDeviceId': _device,
        'sourceRevision': 4,
        'controlCapabilities': 15,
        'state': 'active',
      });
      await tester.pump();
      expect(state.callInteractionMode, CallInteractionMode.control);

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(jami.operations, contains('input:call-modes:4'));

      await tester.tap(find.byKey(const ValueKey('annotation-draw-toggle')));
      await tester.pumpAndSettle();
      expect(state.callInteractionMode, CallInteractionMode.draw);
      expect(jami.operations, contains('end:call-modes:4'));
      state.setAnnotationEnabled(false);
    },
  );

  testWidgets('controllee prompt is explicit, default-deny and device-bound', (
    tester,
  ) async {
    final jami = _RemoteJami();
    final state = await _state(jami);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'call-2',
      dir: CallDir.outgoing,
      peerId: _peer,
      state: 'CURRENT',
      outgoingVideo: const OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        revision: 9,
        width: 1920,
        height: 1080,
      ),
    );
    state.remoteControl.syncCall(
      live: true,
      foreground: true,
      callId: 'call-2',
      peerId: _peer,
      peerScreenActive: false,
      peerSourceRevision: null,
      localScreenActive: true,
      localSourceRevision: 9,
    );
    state.remoteControl.applyNativeHostRequest({
      'callId': 'call-2',
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 1,
      'controlCapabilities': 15,
      'persistentAvailable': true,
    });

    await tester.pumpWidget(_app(state));
    // The prompt must describe the grant the implementation actually makes:
    // mouse/keyboard bound to the shared screen, acting as the user in ordinary
    // apps. It must NOT claim whole-computer reach - SendInput is UIPI-limited
    // to equal-or-lower integrity and cannot touch elevated windows or the
    // secure desktop, and remote pointer movement is clamped to the shared
    // source rectangle by MapToVirtualDesktop.
    expect(find.textContaining('see only your shared screen'), findsOneWidget);
    expect(find.text('Allow control of your computer?'), findsOneWidget);
    final identity = tester.widget<Text>(
      find.byKey(const Key('remote-control-authenticated-identity')),
    );
    expect(identity.data, 'Authenticated account\n$_peer\nDevice\n$_device');
    expect(identity.textDirection, TextDirection.ltr);
    expect(find.textContaining('apps you’re signed into'), findsOneWidget);
    expect(
      find.text('Some protected system screens can’t be controlled.'),
      findsOneWidget,
    );
    expect(find.textContaining('control your whole computer'), findsNothing);
    expect(find.textContaining('everything on'), findsNothing);
    expect(find.byKey(const Key('remote-control-allow-once')), findsOneWidget);
    expect(find.byKey(const Key('remote-control-allow-device')), findsNothing);
    expect(find.text('Always allow'), findsNothing);
    expect(find.textContaining('Skip next time'), findsNothing);

    final noButton = find.byKey(const Key('remote-control-deny'));
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final (size, scale) in [
      (const Size(1280, 800), 1.0),
      (const Size(390, 844), 2.0),
    ]) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = size;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        _app(state, textScale: scale, boundary: boundary),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(noButton);
      await tester.pumpAndSettle();
      expect(noButton.hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('remote-control-allow-once')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final output = Platform.environment['SYBL_FIXTURE_SCREENSHOTS'];
      if (output != null) {
        await tester.runAsync(() async {
          final surface =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await surface.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$output/remote-help-consent-${size.width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
          } finally {
            image.dispose();
          }
        });
      }
    }
    expect(
      tester.widget<TextButton>(noButton).autofocus,
      isTrue,
      reason: 'the safe answer must own initial keyboard focus',
    );
    await tester.tap(noButton);
    await tester.pump();
    expect(jami.operations, contains('deny:call-2:9'));
    expect(find.byKey(const Key('remote-control-deny')), findsNothing);
  });

  testWidgets('consent identifies the authenticated requester, not a profile', (
    tester,
  ) async {
    final jami = _RemoteJami();
    final state = await _state(jami, includeOtherPeer: true);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'call-other',
      dir: CallDir.incoming,
      peerId: _otherPeer,
      state: 'CURRENT',
      outgoingVideo: const OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        revision: 12,
        width: 1920,
        height: 1080,
      ),
    );
    state.remoteControl.syncCall(
      live: true,
      foreground: true,
      callId: 'call-other',
      peerId: _otherPeer,
      peerScreenActive: false,
      peerSourceRevision: null,
      localScreenActive: true,
      localSourceRevision: 12,
    );
    state.remoteControl.applyNativeHostRequest({
      'callId': 'call-other',
      'controllerAccountId': _otherPeer,
      'controllerDeviceId': _device,
      'sourceRevision': 12,
      'hostGeneration': 1,
      'controlCapabilities': 15,
      'persistentAvailable': true,
    });

    await tester.pumpWidget(_app(state));

    expect(
      find.text('Authenticated account\n$_otherPeer\nDevice\n$_device'),
      findsOneWidget,
    );
    expect(find.textContaining('Let Morgan help'), findsNothing);
    expect(find.textContaining('Let Alex help'), findsNothing);
  });

  testWidgets('host keeps one compact active Stop control on PC and phone', (
    tester,
  ) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final jami = _RemoteJami();
    final state = await _state(jami);
    addTearDown(state.dispose);
    state.call = CallSession(
      callId: 'call-phone-host',
      dir: CallDir.incoming,
      peerId: _peer,
      state: 'CURRENT',
      outgoingVideo: const OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        revision: 9,
        width: 1080,
        height: 2400,
      ),
    );
    state.remoteControl.syncCall(
      live: true,
      foreground: true,
      callId: 'call-phone-host',
      peerId: _peer,
      peerScreenActive: false,
      peerSourceRevision: null,
      localScreenActive: true,
      localSourceRevision: 9,
    );
    await tester.pump();
    state.remoteControl.applyNativeHostRequest({
      'callId': 'call-phone-host',
      'channelEpoch': jami.authority.channelEpoch,
      'surfaceRevision': jami.authority.surfaceRevision,
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 1,
      'controlCapabilities': 15,
      'persistentAvailable': true,
    });
    state.remoteControl.applyNativeHostState({
      'callId': 'call-phone-host',
      'channelEpoch': jami.authority.channelEpoch,
      'surfaceRevision': jami.authority.surfaceRevision,
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 9,
      'hostGeneration': 1,
      'state': 'active',
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(_app(state));
      final stop = find.byKey(const Key('remote-control-host-stop'));
      expect(stop, findsOneWidget);
      expect(find.text('Alex is helping — control is on'), findsOneWidget);
      expect(find.text('Stop control'), findsOneWidget);
      expect(tester.getSize(stop).height, greaterThanOrEqualTo(40));
    }

    final stop = find.byKey(const Key('remote-control-host-stop'));
    await tester.tap(stop);
    await tester.pump();
    expect(jami.operations, contains('surface-block'));
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'mobile screen viewing permits rotation and offers bounded text entry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final orientationCalls = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationCalls.add(call.arguments);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final jami = _RemoteJami();
      final state = await _state(jami);
      addTearDown(state.dispose);
      state.call = CallSession(
        callId: 'call-mobile',
        dir: CallDir.outgoing,
        peerId: _peer,
        state: 'CURRENT',
        peerVideo: true,
        peerVideoKind: OutgoingVideoKind.screen,
        remoteActive: true,
        remoteWidth: 1080,
        remoteHeight: 1920,
      );
      state.annotation.syncSources(
        localOwner: state.jamiId,
        peerOwner: _peer,
        localRevision: 1,
        localKind: OutgoingVideoKind.off,
        peerKind: OutgoingVideoKind.screen,
      );
      state.annotation.applyInbound(
        '{"v":1,"t":"src","sourceOwner":"$_peer",'
        '"sourceRevision":4,"sourceKind":"screen"}',
      );
      state.remoteControl.syncCall(
        live: true,
        foreground: true,
        callId: 'call-mobile',
        peerId: _peer,
        peerScreenActive: true,
        peerSourceRevision: 4,
        localScreenActive: false,
        localSourceRevision: 1,
      );

      await tester.pumpWidget(_app(state));
      await tester.pump();
      expect(
        orientationCalls.last,
        containsAll(<String>[
          'DeviceOrientation.portraitUp',
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ]),
      );
      await tester.tap(find.byKey(const Key('remote-control-request')));
      await tester.pump();
      state.remoteControl.applyControlleePacket(
        callId: 'call-mobile',
        peerId: _peer,
        peerDeviceId: _device,
        payload:
            '{"caps":["mouse","keyboard","text","clipboard"],'
            '"epoch":7,"sourceRevision":4,"t":"grant",'
            '"token":"00112233445566778899aabbccddeeff","v":1}',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('remote-control-keyboard')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('remote-control-text-field')),
        findsOneWidget,
      );
      expect(find.text('Type on Alex\u2019s device'), findsOneWidget);
      expect(
        find.byKey(const Key('remote-control-text-cancel')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('remote-control-text-send')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('remote-control-text-field')),
            )
            .maxLength,
        1000,
      );
      await tester.enterText(
        find.byKey(const Key('remote-control-text-field')),
        '👨‍👩‍👧‍👦' * 1000,
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('remote-control-text-send')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('remote-control-text-field')),
        'hello from phone',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('remote-control-text-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remote-control-text-field')), findsNothing);
      expect(jami.operations, contains('input:call-mobile:4'));

      await tester.tap(find.byKey(const Key('remote-control-stop')));
      await tester.pumpAndSettle();
      expect(
        orientationCalls.last,
        contains('DeviceOrientation.landscapeLeft'),
        reason: 'screen viewing, not remote-control state, owns rotation',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(orientationCalls.last, <String>['DeviceOrientation.portraitUp']);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
