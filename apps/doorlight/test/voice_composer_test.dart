import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/voice_recorder.dart';
import 'package:sybl/state/send_journal.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/pane_activity.dart';

final class _Capture implements VoiceCaptureDevice {
  int starts = 0;
  int stops = 0;
  Completer<String?>? pendingStop;
  @override
  Future<bool> permission({required bool request}) async => true;
  @override
  Future<void> start(String path) async {
    starts++;
  }

  @override
  Future<String?> stop() async {
    stops++;
    return pendingStop == null ? 'owned.m4a' : await pendingStop!.future;
  }

  @override
  Future<void> close() async {}
  @override
  Future<double> amplitude() async => -24;
}

final class _State extends AppState {
  _State(super.jami, super.prefs);
  final capture = _Capture();
  int voiceSends = 0;
  @override
  Future<SendJournalRecord?> sendComposerFile(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    bool asHologram = false,
  }) async {
    voiceSends++;
    return null;
  }

  @override
  bool get canRecordComposerVoice => true;
  @override
  VoiceRecorder createComposerRecorder(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    VoiceCaptureDevice? device,
  }) => VoiceRecorder(
    device: capture,
    isCurrent: () => draft.owns(operation),
    prepare: () async => 'owned.m4a',
    renew: (_) async => true,
    discard: (_) async {},
  );
  // Validator coverage uses an independently encoded fixture in its own tests.
  // This seam keeps the widget test independent of real microphones and IO.
  @override
  Future<ComposerPreparationResult> prepareComposerVoice(
    ComposerDraftSession draft,
    ComposerOperation operation,
    VoiceRecorder recorder,
  ) async {
    final path = await recorder.stop();
    if (path == null || !draft.owns(operation)) {
      return ComposerPreparationResult.stale;
    }
    return draft.replaceMedia(
          operation,
          ComposerMediaStage(
            kind: ComposerMediaKind.voice,
            label: 'Voice message.m4a',
            encodedBytes: 1000,
            path: path,
            mediaMetadata:
                '{"v":1,"kind":"voice","codec":"aac-lc","container":"m4a","durationMs":1000}',
          ),
        )
        ? ComposerPreparationResult.staged
        : ComposerPreparationResult.stale;
  }
}

void main() {
  for (final pendingReview in [false, true]) {
    testWidgets(
      'retained pane retires voice and preserves draft (pending review: $pendingReview)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final state = _State(_Jami(), await SharedPreferences.getInstance())
          ..accountId = 'account'
          ..jamiId = 'a' * 40;
        addTearDown(state.dispose);
        const group = GroupState(
          conversationId: 'group',
          title: 'Group',
          memberCount: 1,
          canManageMembers: true,
          memberIds: [],
          activeMemberIds: {},
          invitedMemberIds: {},
        );
        state.seedEmptyRuntimeSnapshotForTesting(
          friends: const [],
          groups: const [group],
          selectedFixtureGroupId: 'group',
        );
        final active = ValueNotifier(true);
        addTearDown(active.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme().copyWith(platform: TargetPlatform.android),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (context, value, child) => PaneActivityScope(
                  active: value,
                  child: Offstage(offstage: !value, child: child!),
                ),
                child: ConversationComposer(
                  state: state,
                  hintText: 'Message',
                  fileLabel: 'Attach',
                  groupTopicId: 'general',
                  onSend: (_) async => false,
                ),
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), 'Keep this text');
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        final pointer = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('voice-record-button'))),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await pointer.moveBy(const Offset(0, -80));
        await pointer.up();
        await tester.pump();
        expect(state.capture.starts, 1);
        expect(
          find.byKey(const ValueKey('voice-recording-controls')),
          findsOneWidget,
        );
        final stopped = Completer<String?>();
        state.capture.pendingStop = stopped;
        if (pendingReview) {
          await tester.tap(find.byTooltip('Stop recording'));
          await tester.pump();
        }
        active.value = false;
        await tester.pump();
        expect(state.capture.stops, 1);
        expect(state.voiceSends, 0);
        active.value = true;
        await tester.pump();
        stopped.complete('owned.m4a');
        state.capture.pendingStop = null;
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(controller),
        );
        expect(controller.text, 'Keep this text');
        expect(find.text('Voice message.m4a'), findsNothing);
        expect(
          find.byKey(const ValueKey('voice-recording-controls')),
          findsNothing,
        );
        expect(state.voiceSends, 0);
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('voice-record-button')));
        await tester.pump();
        expect(state.capture.starts, 2);
        await tester.tap(find.byTooltip('Stop recording'));
        await tester.pump();
        expect(find.text('Voice message.m4a'), findsOneWidget);
        expect(controller.text, '');
        expect(state.voiceSends, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final gestureKind in [
    'tap',
    'hold',
    'lock',
    'cancel',
    'interrupted-send',
  ]) {
    testWidgets('mobile voice gesture: $gestureKind', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = _State(_Jami(), await SharedPreferences.getInstance())
        ..accountId = 'account'
        ..jamiId = 'a' * 40;
      addTearDown(state.dispose);
      const group = GroupState(
        conversationId: 'group',
        title: 'Group',
        memberCount: 1,
        canManageMembers: true,
        memberIds: [],
        activeMemberIds: {},
        invitedMemberIds: {},
      );
      state.seedEmptyRuntimeSnapshotForTesting(
        friends: const [],
        groups: const [group],
        selectedFixtureGroupId: 'group',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            body: ConversationComposer(
              state: state,
              hintText: 'Message',
              fileLabel: 'Attach',
              groupTopicId: 'general',
              onSend: (_) async => false,
            ),
          ),
        ),
      );
      final mic = find.byKey(const ValueKey('voice-record-button'));
      final pointer = await tester.startGesture(tester.getCenter(mic));
      if (gestureKind != 'tap') {
        await tester.pump(const Duration(milliseconds: 400));
      }
      if (gestureKind == 'lock') await pointer.moveBy(const Offset(0, -80));
      if (gestureKind == 'cancel') await pointer.moveBy(const Offset(-80, 0));
      if (gestureKind == 'interrupted-send') {
        state.capture.pendingStop = Completer<String?>();
        await pointer.up();
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        state.capture.pendingStop!.complete('owned.m4a');
      } else {
        await pointer.up();
      }
      await tester.pump();
      expect(state.capture.starts, 1);
      expect(state.voiceSends, gestureKind == 'hold' ? 1 : 0);
      if (gestureKind == 'tap' || gestureKind == 'lock') {
        expect(
          find.byKey(const ValueKey('voice-recording-controls')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Stop recording'));
        await tester.pump();
      }
      expect(
        find.byKey(const ValueKey('voice-recording-controls')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('desktop Stop stages voice and preserves the unsent text draft', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = _State(JamiClient(), await SharedPreferences.getInstance())
      ..accountId = 'account'
      ..jamiId = 'a' * 40;
    addTearDown(state.dispose);
    const group = GroupState(
      conversationId: 'group',
      title: 'Group',
      memberCount: 1,
      canManageMembers: true,
      memberIds: [],
      activeMemberIds: {},
      invitedMemberIds: {},
    );
    state.seedEmptyRuntimeSnapshotForTesting(
      friends: const [],
      groups: const [group],
      selectedFixtureGroupId: 'group',
    );
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: ConversationComposer(
            state: state,
            hintText: 'Message',
            fileLabel: 'Attach',
            groupTopicId: 'general',
            onSend: (text) async {
              sent.add(text);
              return true;
            },
          ),
        ),
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(field, 'Keep this text');
    final controller = tester.widget<TextField>(field).controller!;
    await tester.tap(find.byKey(const ValueKey('voice-record-button')));
    await tester.pump();
    expect(state.capture.starts, 1);
    expect(
      find.byKey(const ValueKey('voice-recording-controls')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      closeTo(0.6, 0.001),
    );
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('voice-recording-controls')),
      findsNothing,
    );
    expect(find.text('Voice message.m4a'), findsOneWidget);
    expect(controller.text, 'Keep this text');
    expect(sent, isEmpty);
    expect(state.capture.stops, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard voice message?'), findsOneWidget);
    // Two callbacks queued before rebuilding cannot dismiss the owning chat.
    final keep = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Keep recording'))
        .onPressed!;
    keep();
    keep();
    await tester.pumpAndSettle();
    expect(find.text('Voice message.m4a'), findsOneWidget);
    await tester.tap(find.byTooltip('Send voice message'));
    await tester.pump();
    expect(state.voiceSends, 1);
    expect(controller.text, 'Keep this text');
    expect(sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _Jami extends JamiClient {
  @override
  Future<void> discardPickedFile(String path) async {}
}
