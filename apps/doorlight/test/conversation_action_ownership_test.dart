import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/dm_topics.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/pane_activity.dart';

import 'app_state_test.dart' show FakeJami;

class _DelayedTopicJami extends FakeJami {
  Completer<String>? commit;

  @override
  Future<String> sendDmTopicEvent(
    String peer,
    String conversation,
    String body,
  ) async {
    final result = await super.sendDmTopicEvent(peer, conversation, body);
    return commit == null ? result : await commit!.future;
  }
}

Future<AppState> _boot(WidgetTester tester, FakeJami fake) async {
  late AppState state;
  final first = 'b' * 40;
  final second = 'c' * 40;
  fake.daemonFriends[first] = JamiFriend(
    peerJamiId: first,
    confirmed: true,
    conversationId: 'conv-first',
  );
  fake.daemonFriends[second] = JamiFriend(
    peerJamiId: second,
    confirmed: true,
    conversationId: 'conv-second',
  );
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({
      'displayName': 'Synthetic',
      'selectedFriendId': first,
    });
    state = AppState(fake, await SharedPreferences.getInstance());
    await state.init();
    await state.selectFriend(first);
    await pumpEventQueue();
  });
  addTearDown(state.dispose);
  return state;
}

Widget _composer(AppState state) => MaterialApp(
  theme: Warm.theme(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: ListenableBuilder(
        listenable: state,
        builder: (_, _) => ConversationComposer(
          state: state,
          hintText: 'Message',
          fileLabel: 'File',
          onSend: state.sendText,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'a rendered peer-archive action cannot affect a replacement chat',
    (tester) async {
      const topicId = '0123456789abcdef0123456789abcdef';
      final fake = FakeJami();
      for (final (conversation, peer) in [
        ('conv-first', 'b' * 40),
        ('conv-second', 'c' * 40),
      ]) {
        fake.dmTopicHistory[conversation] = [
          for (final (commit, event) in [
            (
              'archive',
              const DmTopicEvent.archive(
                topicId: topicId,
                revision: 1,
                archived: true,
              ),
            ),
            (
              'create',
              const DmTopicEvent.create(
                topicId: topicId,
                revision: 1,
                name: 'vacation',
                order: 0,
              ),
            ),
          ])
            {
              'commitId': commit,
              'authorId': peer,
              'mimeType': DmTopicWire.mimeType,
              'topicId': DmTopicWire.mainId,
              'linearizedParent': '',
              'eventBody': DmTopicEventCodec.encode(event),
            },
        ];
      }
      final state = await _boot(tester, fake);
      await tester.runAsync(() async {
        await state.selectDmTopic(topicId);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (_, _) =>
                  ChatStage(state: state, friend: state.selectedFriend!),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('dm-topic-archive-for-me-too'));
      expect(button.hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        await state.selectFriend('c' * 40);
        await pumpEventQueue();
        await state.selectDmTopic(topicId);
      });
      final count = fake.sentDmTopicEvents.length;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(fake.sentDmTopicEvents, hasLength(count));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a rendered command cannot target a selection made before the next frame',
    (tester) async {
      final fake = FakeJami();
      final state = await _boot(tester, fake);
      await tester.pumpWidget(_composer(state));
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        '/topic create vacation',
      );
      await tester.pump();
      final row = find.byKey(const ValueKey('composer-command-result-0'));
      expect(row.hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        await state.selectFriend('c' * 40);
      });
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(fake.sentDmTopicEvents, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dialog in ['rename', 'archived']) {
    testWidgets('$dialog dialog cannot submit on a later A-B-A visit', (
      tester,
    ) async {
      final fake = FakeJami();
      final state = await _boot(tester, fake);
      await tester.runAsync(() async {
        expect(await state.createDmTopic('vacation'), isTrue);
      });
      final topicId = state.selectedDmTopicId;
      if (dialog == 'archived') {
        fake.nextDmTopicCommitId = 'archive-commit';
        await tester.runAsync(() async {
          expect(await state.setDmTopicArchived(topicId, true), isTrue);
        });
      }
      final originalCount = fake.sentDmTopicEvents.length;
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (_, _) => ChatStage(
                key: ValueKey(state.peerId),
                state: state,
                friend: state.selectedFriend!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (dialog == 'rename') {
        await tester.longPress(find.byKey(ValueKey('dm-topic-pill:$topicId')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('dm-topic-name-field')),
          'new name',
        );
      } else {
        await tester.tap(find.byKey(const ValueKey('dm-topic-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Archived topics'));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        await state.selectFriend('c' * 40);
        await state.selectFriend('b' * 40);
      });
      await tester.pumpAndSettle();
      if (dialog == 'rename') {
        await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      } else {
        await tester.tap(find.byTooltip('Unarchive vacation'));
      }
      await tester.pumpAndSettle();
      expect(fake.sentDmTopicEvents, hasLength(originalCount));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('real create and switch commands clear their unchanged draft', (
    tester,
  ) async {
    final fake = FakeJami();
    final state = await _boot(tester, fake);
    await tester.pumpWidget(_composer(state));
    final field = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(field, '/topic create vacation');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(fake.sentDmTopicEvents, hasLength(1));
    expect(state.selectedDmTopicId, isNot('main'));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.enterText(field, '/main');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(state.selectedDmTopicId, 'main');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'delayed command loses authority across retained pane hide and return',
    (tester) async {
      final fake = _DelayedTopicJami();
      final state = await _boot(tester, fake);
      fake.commit = Completer<String>();
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, value, child) =>
              PaneActivityScope(active: value, child: child!),
          child: _composer(state),
        ),
      );
      final field = find.byKey(const ValueKey('chat-composer'));
      const command = '/topic create vacation';
      await tester.enterText(field, command);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(fake.sentDmTopicEvents, hasLength(1));
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      fake.commit!.complete('stale-topic-commit');
      await tester.pumpAndSettle();
      expect(state.selectedDmTopicId, 'main');
      expect(tester.widget<TextField>(field).controller!.text, command);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      fake.commit = null;
      fake.nextDmTopicCommitId = 'fresh-topic-commit';
      await tester.enterText(field, '/topic create fresh topic');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(fake.sentDmTopicEvents, hasLength(2));
      expect(state.selectedDmTopicId, isNot('main'));
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final outcome in [
    'edit undo',
    'navigation',
    'account replacement',
    'author replacement',
  ]) {
    testWidgets('delayed create keeps draft and selection after $outcome', (
      tester,
    ) async {
      final fake = _DelayedTopicJami();
      final state = await _boot(tester, fake);
      fake.commit = Completer<String>();
      await tester.pumpWidget(_composer(state));
      final field = find.byKey(const ValueKey('chat-composer'));
      const command = '/topic create vacation';
      await tester.enterText(field, command);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      if (outcome == 'edit undo') {
        await tester.enterText(field, 'edit');
        await tester.enterText(field, command);
      } else if (outcome == 'navigation') {
        await tester.runAsync(() async {
          await state.selectFriend('c' * 40);
          await state.selectFriend('b' * 40);
        });
      } else if (outcome == 'account replacement') {
        state.accountId = 'replacement';
      } else {
        state.jamiId = 'd' * 40;
      }
      // Keyboard and popup paths must not admit a second pending command.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(fake.sentDmTopicEvents, hasLength(1));
      final popup = find.byKey(const ValueKey('composer-command-result-0'));
      expect(popup.hitTestable(), findsOneWidget);
      await tester.tap(popup);
      await tester.pump();
      expect(fake.sentDmTopicEvents, hasLength(1));
      fake.commit!.complete('new-topic-commit');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        outcome == 'account replacement' ? isEmpty : command,
      );
      if (outcome != 'edit undo') expect(state.selectedDmTopicId, 'main');
      if (outcome == 'account replacement' || outcome == 'author replacement') {
        expect(state.selectedDmTopicState?.customTopics ?? [], isEmpty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final route in ['stay', 'A-B', 'A-B-A']) {
    testWidgets('topic submission owns its opening selection: $route', (
      tester,
    ) async {
      final first = 'b' * 40;
      final second = 'c' * 40;
      final fake = FakeJami();
      fake.daemonFriends[first] = JamiFriend(
        peerJamiId: first,
        confirmed: true,
        conversationId: 'conv-first',
      );
      fake.daemonFriends[second] = JamiFriend(
        peerJamiId: second,
        confirmed: true,
        conversationId: 'conv-second',
      );
      late AppState state;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({
          'displayName': 'Synthetic',
          'selectedFriendId': first,
        });
        state = AppState(fake, await SharedPreferences.getInstance());
        await state.init();
        await state.selectFriend(first);
        await pumpEventQueue();
      });
      addTearDown(state.dispose);
      await tester.runAsync(() async {
        expect(await state.createDmTopic('Existing topic'), isTrue);
      });
      fake.sentDmTopicEvents.clear();
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) => ChatStage(
                key: ValueKey(state.peerId),
                state: state,
                friend: state.selectedFriend!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dm-topic-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New topic'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('dm-topic-name-field')),
        'Original topic',
      );
      if (route != 'stay') {
        await tester.runAsync(() async {
          fake.push('openConversation', {
            'ownerKey': second,
            'conversationId': 'conv-second',
          });
          await pumpEventQueue();
          if (route == 'A-B-A') {
            fake.push('openConversation', {
              'ownerKey': first,
              'conversationId': 'conv-first',
            });
            await pumpEventQueue();
          }
        });
      }
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pump();
      // Check the real AppState's outgoing destination before the route animation.
      expect(
        fake.sentDmTopicEvents.map((event) => event.peerId),
        route == 'stay' ? [first] : isEmpty,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
