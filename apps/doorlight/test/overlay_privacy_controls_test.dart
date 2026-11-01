import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/overlay_settings.dart';
import 'package:sybl/ui/overlay_settings_controls.dart';

import 'app_state_test.dart' show FakeJami;

class PrivacyControlState extends AppState {
  PrivacyControlState(super.jami, super.prefs);
  int revocations = 0;
  Completer<bool>? revokeResult;
  @override
  bool get appearanceBridgeWritable => false;
  @override
  Future<bool> revokeWidgetChatConsent() async {
    revocations++;
    return revokeResult == null ? true : await revokeResult!.future;
  }
}

void main() {
  for (final mode in ['not imported', 'damaged', 'busy']) {
    testWidgets('Hide chat remains usable when overlay settings are $mode', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        if (mode == 'damaged') PreferencesOverlayStore.key: 'invalid document',
        if (mode == 'busy')
          PreferencesOverlayStore.key: jsonEncode({
            'v': 1,
            'imported': true,
            'revision': 1,
            'values': <String, Object>{},
          }),
      });
      final state = PrivacyControlState(
        FakeJami(),
        await SharedPreferences.getInstance(),
      );
      if (mode == 'busy') state.overlaySettings.busy = true;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OverlaySettingsControls(state: state)),
        ),
      );
      final button = find.widgetWithText(TextButton, 'Hide chat in Game Bar');
      expect(button, findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pump();
      expect(state.revocations, 1);
    });
  }

  testWidgets(
    'Hide chat prevents duplicate revocations and allows retry after failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = PrivacyControlState(
        FakeJami(),
        await SharedPreferences.getInstance(),
      );
      state.revokeResult = Completer<bool>();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OverlaySettingsControls(state: state)),
        ),
      );
      final button = find.widgetWithText(TextButton, 'Hide chat in Game Bar');
      await tester.tap(button);
      await tester.pump();
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(state.revocations, 1);
      state.revokeResult!.complete(false);
      await tester.pump();
      expect(find.text('Couldn’t hide chat. Try again.'), findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      state.revokeResult = null;
      await tester.tap(button);
      await tester.pump();
      expect(state.revocations, 2);
      expect(find.text('Couldn’t hide chat. Try again.'), findsNothing);
    },
  );
}
