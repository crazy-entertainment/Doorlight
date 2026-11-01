import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/debug.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/theme.dart';

class _FailedHistory implements ConversationTimelineRepository {
  @override
  Future<TimelineLoadHandle> startLoad(
    TimelineLoadRequest request,
  ) async => throw StateError(
    'private-path C:/private/identity aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bearer-wake-secret private-message',
  );
  @override
  Future<void> cancelLoad(String daemonLoadId) async {}
}

class _HistoryState extends AppState {
  _HistoryState(super.jami, super.prefs, this.timeline);
  final ConversationTimelineController timeline;
  @override
  ConversationTimelineController get conversationTimeline => timeline;
}

void main() {
  testWidgets('history diagnostics never render raw exception contents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final timeline = ConversationTimelineController(
      scope: ConversationScope(
        accountId: 'local',
        peerId: 'peer',
        conversationId: 'conversation',
      ),
      localAuthorId: 'local',
      repository: _FailedHistory(),
    );
    addTearDown(timeline.dispose);
    await timeline.refresh();
    expect(timeline.lastError, isNotNull);
    final state = _HistoryState(
      JamiClient(),
      await SharedPreferences.getInstance(),
      timeline,
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: DebugScreen(state: state),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('diagnostics-status')));
    await tester.pumpAndSettle();
    for (final canary in [
      'private-path',
      'C:/private',
      'aaaaaaaaaa',
      'bearer-wake-secret',
      'private-message',
    ]) {
      expect(find.textContaining(canary), findsNothing);
    }
    expect(find.text('Chat history could not be loaded.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final width in [320.0, 700.0]) {
    testWidgets('diagnostics status fills the row at $width', (tester) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: DebugScreen(state: state),
        ),
      );
      final status = find.byKey(const ValueKey('diagnostics-status'));
      final rect = tester.getRect(status);
      expect(rect.left, closeTo(12, .1));
      expect(rect.right, closeTo(width - 12, .1));
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.textContaining('newest first'), findsNothing);
      await tester.tap(status);
      await tester.pumpAndSettle();
      expect(find.text('Status details'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
