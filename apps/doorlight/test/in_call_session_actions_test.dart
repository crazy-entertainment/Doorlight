import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/in_call.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/window_presentation.dart';

class _State extends AppState {
  _State(super.jami, super.prefs);
  final actions = <String>[];
  @override
  bool get outputPickerAvailable => false;
  @override
  Future<void> setMicMode(MicrophoneMode mode) async =>
      actions.add('mic:${call?.callId}:${mode.name}');
  @override
  Future<void> toggleCamera() async => actions.add('camera:${call?.callId}');
}

class _Window extends WindowPresentation {
  _Window(super.jami) {
    compact = true;
  }
  final expansion = Completer<void>();
  @override
  Future<void> refresh() async {}
  @override
  Future<void> setCompact(bool value, {bool animate = false}) =>
      expansion.future;
}

CallSession _call(String id) => CallSession(
  callId: id,
  dir: CallDir.outgoing,
  peerId: 'b' * 40,
  state: 'CURRENT',
  microphonePolicyApplied: true,
);

Future<_State> _state() async {
  SharedPreferences.setMockInitialValues({});
  return _State(JamiClient(), await SharedPreferences.getInstance())
    ..call = _call('old');
}

Widget _app(_State state, {_Window? window}) {
  final screen = InCallScreen(state: state);
  return MaterialApp(
    theme: Warm.theme(),
    home: Scaffold(
      body: window == null
          ? screen
          : WindowPresentationScope(controller: window, child: screen),
    ),
  );
}

void main() {
  testWidgets(
    'captured microphone callback rejects a replacement before rebuild',
    (tester) async {
      final state = await _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(state));
      final callback = tester
          .widget<PopupMenuButton<MicrophoneMode>>(
            find.byType(PopupMenuButton<MicrophoneMode>),
          )
          .onSelected!;
      state.call = _call('replacement');
      callback(MicrophoneMode.open);
      expect(state.actions, isEmpty);
      await tester.pumpWidget(_app(state));
      tester
          .widget<PopupMenuButton<MicrophoneMode>>(
            find.byType(PopupMenuButton<MicrophoneMode>),
          )
          .onSelected!(MicrophoneMode.pushToTalk);
      expect(state.actions, ['mic:replacement:pushToTalk']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an open microphone menu cannot transfer to a rebuilt session', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(state));
    await tester.tap(find.byKey(const ValueKey('mic-mode-chevron')));
    await tester.pumpAndSettle();
    state.call = _call('replacement');
    await tester.pumpWidget(_app(state));
    await tester.tap(find.text('Open mic'));
    await tester.pumpAndSettle();
    expect(state.actions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final outcome in ['replacement', 'unmounted', 'same']) {
    testWidgets('compact camera expansion preserves session: $outcome', (
      tester,
    ) async {
      final state = await _state();
      final window = _Window(state.jami);
      addTearDown(state.dispose);
      addTearDown(window.dispose);
      await tester.pumpWidget(_app(state, window: window));
      await tester.tap(find.byIcon(Icons.videocam_outlined));
      await tester.pump();
      if (outcome == 'replacement') state.call = _call('replacement');
      if (outcome == 'unmounted') await tester.pumpWidget(const SizedBox());
      window.expansion.complete();
      await tester.pump();
      expect(state.actions, outcome == 'same' ? ['camera:old'] : isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
