import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/main.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/ui/playful_door.dart';
import 'package:sybl/ui/windows_chrome.dart';

class _StartupState extends AppState {
  _StartupState(super.jami, super.prefs);
  int retries = 0;
  int discards = 0;
  bool recovery = false;
  @override
  bool get canDiscardIdentityRestore => recovery;
  @override
  Object? get identityRestoreRecoveryOwner => ('account', 'token');
  @override
  Future<bool> discardIdentityRestore(Object? confirmedOwner) async {
    expect(confirmedOwner, ('account', 'token'));
    discards++;
    return true;
  }

  @override
  Future<void> init() async {}
  @override
  Future<void> retryBoot() async {
    retries++;
  }
}

void main() {
  setUpAll(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final font in ['HankenGrotesk', 'Fraunces']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font-Variable.ttf'))).load();
    }
  });

  testWidgets('unfinished import removal requires visible confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _StartupState(
      JamiClient(),
      await SharedPreferences.getInstance(),
    );
    addTearDown(state.dispose);
    state.seedCaptureStateForTesting(
      resolved: true,
      applied: WindowCaptureProtectionStatus.exclude,
    );
    state.recovery = true;
    state.pendingIdentityRecovery = true;
    state.bootError = 'An unfinished restore needs attention.';
    await tester.pumpWidget(SyblApp(state: state));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Remove unfinished import'));
    await tester.pumpAndSettle();
    expect(state.discards, 0);
    expect(
      find.textContaining('Your backup file stays unchanged'),
      findsOneWidget,
    );
    await tester.tap(find.text('Keep restore'));
    await tester.pumpAndSettle();
    expect(state.discards, 0);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Remove unfinished import'));
    await tester.tap(find.text('Remove unfinished import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove import'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(state.discards, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(700, 500), const Size(390, 844)]) {
    testWidgets(
      'startup shares the welcome surface at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final state = _StartupState(
          JamiClient(),
          await SharedPreferences.getInstance(),
        );
        addTearDown(state.dispose);
        state.seedCaptureStateForTesting(
          resolved: true,
          applied: WindowCaptureProtectionStatus.exclude,
        );
        const capture = ValueKey('startup-capture');
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: SyblApp(state: state),
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(PlayfulDoor), findsOneWidget);
        expect(find.text('warming up…'), findsOneWidget);
        expect(
          tester.widget<WindowsChrome>(find.byType(WindowsChrome)).onboarding,
          isTrue,
        );
        state.bootError = "Couldn't start the engine.";
        state.bootErrorDetails =
            'Step: Checking for an unfinished identity restore\nThe native calling and messaging engine is unavailable.\nCode: native_startup_failed';
        state.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await expectLater(
          find.byKey(capture),
          matchesGoldenFile(
            'goldens/startup_error_${size.width.toInt()}x${size.height.toInt()}.png',
          ),
        );
        await tester.tap(find.text('Try again'));
        expect(state.retries, 1);
        await tester.tap(find.text('Technical details'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Code: native_startup_failed'),
          findsOneWidget,
        );
        final doorBeforeScroll = tester.getRect(find.byType(PlayfulDoor));
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(PlayfulDoor)), doorBeforeScroll);
        expect(
          doorBeforeScroll.top,
          greaterThanOrEqualTo(WindowsChrome.height + 24),
        );
        await expectLater(
          find.byKey(capture),
          matchesGoldenFile(
            'goldens/startup_details_scrolled_${size.width.toInt()}x${size.height.toInt()}.png',
          ),
        );
        state.bootError =
            "Couldn't start the engine. Restart Doorlight to try again.";
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        state.notifyListeners();
        await tester.pump();
        await tester.ensureVisible(find.text('Try again'));
        expect(tester.takeException(), isNull);
        expect(
          tester.getTopLeft(find.byType(PlayfulDoor)).dy,
          greaterThanOrEqualTo(WindowsChrome.height + 24),
        );
        tester.view.physicalSize = const Size(390, 169);
        await tester.pump();
        expect(find.byType(PlayfulDoor), findsNothing);
        await tester.ensureVisible(find.text('Try again'));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Try again'));
        expect(state.retries, 2);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
