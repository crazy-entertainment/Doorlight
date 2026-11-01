import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/chat_stage.dart';

const _group = GroupState(
  conversationId: 'fixture-group',
  title: 'Synthetic group',
  memberCount: 1,
  canManageMembers: true,
  memberIds: [],
  activeMemberIds: {},
  invitedMemberIds: {},
);

void main() {
  for (final route in ['stay', 'A-B', 'A-B-A']) {
    testWidgets('group send completion owns its topic visit: $route', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state =
          AppState(JamiClient(), await SharedPreferences.getInstance())
            ..accountId = 'synthetic-account'
            ..jamiId = 'a' * 40;
      addTearDown(state.dispose);
      state.seedEmptyRuntimeSnapshotForTesting(
        friends: const [],
        groups: const [_group],
        selectedFixtureGroupId: _group.conversationId,
      );
      expect(
        await state.selectGroupTopic(_group.conversationId, 'general'),
        isTrue,
      );

      final completion = Completer<bool>();
      final submitted = <({String topicId, String body})>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ListenableBuilder(
                listenable: state,
                builder: (context, _) {
                  final topicId = state.selectedGroupTopicId(_group);
                  return ConversationComposer(
                    key: const ValueKey('group-composer-fixture-group'),
                    state: state,
                    hintText: 'Message #$topicId',
                    fileLabel: 'Share a synthetic file',
                    groupTopicId: topicId,
                    onSend: (body) {
                      submitted.add((topicId: topicId, body: body));
                      return completion.future;
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('chat-composer'));
      await tester.enterText(field, 'original draft');
      final controller = tester.widget<TextField>(field).controller!;
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(submitted, [(topicId: 'general', body: 'original draft')]);

      if (route != 'stay') {
        expect(
          await state.selectGroupTopic(_group.conversationId, 'games'),
          isTrue,
        );
        await tester.pump();
        expect(
          tester
              .widget<ConversationComposer>(find.byType(ConversationComposer))
              .groupTopicId,
          'games',
        );
        if (route == 'A-B-A') {
          expect(
            await state.selectGroupTopic(_group.conversationId, 'general'),
            isTrue,
          );
          await tester.pump();
        }
      }
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.text, route == 'A-B' ? isEmpty : 'original draft');
      if (route == 'A-B') await tester.enterText(field, 'games draft');

      completion.complete(true);
      await tester.pump();

      expect(
        controller.text,
        route == 'stay'
            ? isEmpty
            : route == 'A-B'
            ? 'games draft'
            : 'original draft',
      );
      expect(submitted, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
