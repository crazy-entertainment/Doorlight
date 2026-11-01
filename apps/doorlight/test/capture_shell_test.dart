import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/main.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/remote_control.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/capture_consent_gate.dart';
import 'package:sybl/ui/window_presentation.dart';

import 'app_state_test.dart' show FakeJami;

const _peer = '2222222222222222222222222222222222222222';
const _device = '3333333333333333333333333333333333333333';

class _CaptureJami extends FakeJami {
  @override
  Future<void> windowCommand(String command) async {}

  @override
  Future<Map<String, dynamic>?> windowPresentationState() async => null;

  int hostStopRequests = 0;
  bool failHostBlock = false;
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
    if (blocked) hostStopRequests++;
    if (blocked && failHostBlock) return null;
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [const Size(390, 844), const Size(320, 400)]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'capture prompt fits $size with text scale $textScale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final state = AppState(
            FakeJami(),
            await SharedPreferences.getInstance(),
          );
          addTearDown(state.dispose);
          state.seedCaptureStateForTesting(activityActive: true);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await tester.pumpWidget(
            MaterialApp(
              theme: Warm.theme(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: CaptureConsentGate(state: state),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          for (final key in [
            'capture-consent-show',
            'capture-consent-show-always',
            'capture-consent-hide',
          ]) {
            final action = find.byKey(ValueKey(key));
            await tester.ensureVisible(action);
            await tester.pump();
            expect(action.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }

  test('capture gate retires host authority before a shell rebuild', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({
      'displayName': 'Me',
      'peerId': _peer,
    });
    final jami = _CaptureJami()..accountExists = true;
    final state = AppState(jami, await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await state.init();
    jami.push('incomingCall', {'callId': 'call', 'fromJamiId': _peer});
    jami.push('callState', {
      'callId': 'call',
      'state': 'CURRENT',
      'fromJamiId': _peer,
    });
    void share() => jami.push('outgoingVideoSource', {
      'callId': 'call',
      'outgoingVideoKind': 'screen',
      'outgoingVideoRevision': 5,
      'outgoingVideoWidth': 1920,
      'outgoingVideoHeight': 1080,
    });
    share();
    await pumpEventQueue();
    final host = {
      'channelEpoch': jami.authority.channelEpoch,
      'surfaceRevision': jami.authority.surfaceRevision,
      'callId': 'call',
      'controllerAccountId': _peer,
      'controllerDeviceId': _device,
      'sourceRevision': 5,
      'hostGeneration': 1,
      'state': 'active',
      'controlCapabilities': 1,
    };
    jami.push('remoteControlState', host);
    expect(state.remoteControl.hostActive, isTrue);
    expect(jami.hostStopRequests, 0);
    state.setConversationVisible(_peer);
    expect(state.visibleConversationPeerId, _peer);

    jami.failHostBlock = true;
    jami.push('captureActivity', {'source': 'obsLog', 'active': true});
    expect(state.captureGateVisible, isTrue);
    expect(state.visibleConversationPeerId, isNull);
    state.setConversationVisible(_peer);
    expect(state.visibleConversationPeerId, isNull);
    expect(jami.hostStopRequests, 1);
    expect(state.remoteControl.hostActive, isFalse);
    expect(state.call?.connected, isTrue);
    expect(state.call?.sharingScreen, isTrue);

    // A later source publication and saved-grant projection must not restore
    // control behind the prompt, nor may a fresh request wait behind it.
    share();
    jami.push('remoteControlState', {...host, 'hostGeneration': 2});
    jami.push('remoteControlRequest', {...host, 'hostGeneration': 3});
    expect(state.remoteControl.hostActive, isFalse);
    expect(state.remoteControl.hostRequest, isNull);
    expect(state.remoteControl.canRequest, isFalse);
    await pumpEventQueue();
    expect(state.remoteControl.hostPhase, RemoteControlHostPhase.revoking);
  });

  testWidgets(
    'failed protection does not claim that OBS is active',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final jami = _CaptureJami()
        ..accountExists = false
        ..captureApplyProtectedResult =
            WindowCaptureProtectionStatus.unavailable;
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(SyblApp(state: state));
      await tester.pumpAndSettle();
      final window = WindowPresentationScope.maybeOf(
        tester.element(find.byType(CaptureConsentGate)),
      )!;
      await window.setCompact(true);
      tester.view.physicalSize = const Size(320, 360);
      await tester.pumpAndSettle();
      expect(find.byType(CompactHeader), findsOneWidget);
      expect(find.byTooltip('Default size').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
      expect(state.captureGateVisible, isTrue);
      expect(state.captureActivityActive, isFalse);
      expect(
        find.text('Screen-capture protection needs your choice.'),
        findsOneWidget,
      );
      expect(find.textContaining('OBS is recording'), findsNothing);
      expect(
        find.byKey(const ValueKey('capture-consent-error')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
