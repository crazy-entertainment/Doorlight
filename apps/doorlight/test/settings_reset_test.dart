import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/settings_pane.dart';

class _ResetState extends AppState {
  _ResetState(super.jami, super.prefs);

  int resets = 0;

  @override
  Future<bool> resetDoorlight() async {
    resets++;
    return true;
  }
}

void main() {
  testWidgets('reset waits three seconds and requires final confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _ResetState(
      JamiClient(),
      await SharedPreferences.getInstance(),
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SettingsPane(
            state: state,
            onClose: () {},
            onOpenDiagnostics: () {},
          ),
        ),
      ),
    );
    final reset = find.byKey(const ValueKey('reset-doorlight-button'));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pump();
    final proceed = find.byKey(const ValueKey('reset-doorlight-continue'));
    expect(tester.widget<FilledButton>(proceed).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(state.resets, 0);
    if (proceed.evaluate().isEmpty) {
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 2));
    expect(tester.widget<FilledButton>(proceed).onPressed, isNull);
    expect(state.resets, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<FilledButton>(proceed).onPressed, isNotNull);
    await tester.tap(proceed);
    await tester.pumpAndSettle();
    expect(state.resets, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.resets, 0);

    await tester.tap(reset);
    await tester.pump();
    expect(tester.widget<FilledButton>(proceed).onPressed, isNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(proceed);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-doorlight-confirm')));
    await tester.pumpAndSettle();
    expect(state.resets, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop settings have one content scroll and a fixed section strip',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = _ResetState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: SettingsPane(
              state: state,
              onClose: () {},
              onOpenDiagnostics: () {},
            ),
          ),
        ),
      );
      expect(find.text('Back'), findsNothing);
      expect(
        find.ancestor(
          of: find.byIcon(Icons.close_rounded),
          matching: find.byType(IconButton),
        ),
        findsNothing,
      );
      expect(find.byType(Scrollbar), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-section-rail')),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      for (final section in [
        'profile',
        'appearance',
        'notifications',
        'voice',
        'connection',
        'files',
        'safety',
        'advanced',
      ]) {
        expect(
          tester.getSize(find.byKey(ValueKey('settings-jump-$section'))),
          const Size(48, 48),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
