import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/main.dart';
import 'package:sybl/state/app_state.dart';

class _AppearanceState extends AppState {
  _AppearanceState(super.jami, super.prefs);

  @override
  Future<void> init() async {}

  void loadAppearance(AppearancePreset preset) {
    appSettings = appSettings.withAppearancePreset(preset);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const core = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final appearances = <bool>[];

  setUp(() {
    appearances.clear();
    messenger.setMockMethodCallHandler(core, (call) async {
      if (call.method == 'setWindowAppearance') {
        appearances.add((call.arguments as Map)['disaccord'] as bool);
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(core, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('native appearance is a Windows-only command', () async {
    final client = JamiClient();
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      await client.setWindowAppearance(disaccord: true);
    }
    expect(appearances, isEmpty);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await client.setWindowAppearance(disaccord: true);
    await client.setWindowAppearance(disaccord: false);
    expect(appearances, [true, false]);
  });

  testWidgets(
    'startup and preset changes synchronize the Windows border',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = _AppearanceState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(SyblApp(state: state));
      await tester.pump();
      expect(appearances, [false]);
      for (final preset in [
        AppearancePreset.disaccord,
        AppearancePreset.cozy,
        AppearancePreset.disaccord,
        AppearancePreset.midnight,
      ]) {
        state.loadAppearance(preset);
        await tester.pump();
      }
      expect(appearances, [false, true, false, true, false]);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
