import 'package:sybl/core/sticker_assets.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/composer_commands.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/starter_gifs.dart';
import 'package:sybl/state/send_journal.dart';
import 'package:sybl/state/dm_topics.dart';
import 'package:sybl/state/message_reactions.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/bounded_attachment_preview.dart';
import 'package:sybl/ui/gravity.dart';
import 'package:sybl/ui/sybl_ui.dart';
import 'package:sybl/ui/topic_strip_surface.dart';

const _peer = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _account = 'account';
const _conversation = 'conversation';
const _local = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _scope = ConversationScope(
  accountId: _account,
  peerId: _peer,
  conversationId: _conversation,
);

FolderFile _file(int timestamp) => FolderFile(
  peerId: _peer,
  conversationId: _conversation,
  fileId: 'file-$timestamp',
  interactionId: 'interaction-$timestamp',
  name: 'file-$timestamp.txt',
  size: 100,
  timestamp: timestamp,
);

TimelineTextItem _text(
  int timestamp,
  String text, {
  TimelineDeliveryState deliveryState = TimelineDeliveryState.sent,
  String topicId = DmTopicWire.mainId,
  bool topicTagged = false,
}) => TimelineTextItem(
  scope: _scope,
  daemonId: 'message-$timestamp',
  versionId: 'version-$timestamp',
  authorId: _peer,
  direction: TimelineDirection.incoming,
  createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true),
  text: text,
  deliveryState: deliveryState,
  topicId: topicId,
  topicTagged: topicTagged,
);

TimelineTextItem _outgoingText(
  int timestamp,
  String text, {
  TimelineDeliveryState deliveryState = TimelineDeliveryState.sent,
  Set<String> readByMemberIds = const {},
}) => TimelineTextItem(
  scope: _scope,
  daemonId: 'outgoing-$timestamp-$text',
  versionId: 'outgoing-version-$timestamp-$text',
  authorId: _local,
  direction: TimelineDirection.outgoing,
  createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true),
  text: text,
  deliveryState: deliveryState,
  readByMemberIds: readByMemberIds,
);

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  return AppState(JamiClient(), await SharedPreferences.getInstance())
    ..jamiId = _local;
}

class _MutableTimelineState extends AppState {
  _MutableTimelineState(super.jami, super.prefs);

  List<ConversationTimelineItem> items = const [];

  @override
  List<ConversationTimelineItem> get conversationItems => items;
}

class _ComposerTimelineState extends _MutableTimelineState {
  _ComposerTimelineState(super.jami, super.prefs);

  ComposerActivityKind? activity;
  final localActivity = <ComposerActivityKind>[];
  ComposerQueryResult commandResult = const ComposerQueryResult();
  ComposerResult? executedCommand;
  bool failCommand = false;
  String fixtureConversation = _conversation;
  int fileSends = 0;
  ComposerSendStatus fileOutcome = ComposerSendStatus.failedBeforeCommit;
  bool photoCancelled = true;
  @override
  bool get canCaptureComposerPhoto => true;
  @override
  Future<ComposerPreparationResult> prepareComposerPhoto(
    ComposerDraftSession draft,
    ComposerOperation operation,
  ) async {
    if (photoCancelled) {
      draft.finishPreparation(operation);
      return ComposerPreparationResult.cancelled;
    }
    return draft.replaceMedia(
          operation,
          ComposerMediaStage(
            kind: ComposerMediaKind.photo,
            label: 'photo.jpg',
            encodedBytes: 123,
          ),
        )
        ? ComposerPreparationResult.staged
        : ComposerPreparationResult.stale;
  }

  @override
  Future<ComposerPreparationResult> prepareComposerFile(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    bool gif = false,
    String? libraryHash,
    StarterGif? starterGif,
  }) async =>
      draft.replaceMedia(
        operation,
        ComposerMediaStage(
          kind: ComposerMediaKind.file,
          label: 'example.txt',
          encodedBytes: 0,
          path: '/fixture/example.txt',
        ),
      )
      ? ComposerPreparationResult.staged
      : ComposerPreparationResult.stale;

  @override
  Future<SendJournalRecord?> sendComposerFile(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    bool asHologram = false,
  }) async {
    fileSends++;
    return SendJournalRecord(
      operationId: operation.id,
      scope: draft.key.scope,
      status: fileOutcome,
      commitId: fileOutcome == ComposerSendStatus.committed
          ? 'file-commit'
          : null,
    );
  }

  @override
  ConversationScope? get selectedConversationScope => ConversationScope(
    accountId: accountId!,
    peerId: peerId ?? _peer,
    conversationId: fixtureConversation,
  );

  @override
  FriendState? get selectedFriend => FriendState(
    peerId: _peer,
    confirmed: true,
    conversationId: fixtureConversation,
    displayName: 'Friend',
  );

  @override
  ComposerActivityKind? get remoteComposerActivity => activity;

  @override
  Future<bool> setLocalComposerActivity(ComposerActivityKind kind) async {
    localActivity.add(kind);
    return true;
  }

  @override
  ComposerQueryResult resolveComposerQuery(
    String input, {
    String? groupTopicId,
  }) => commandResult;

  @override
  Future<bool> executeComposerResult(
    ComposerResult result, {
    ConversationAction? action,
  }) async {
    executedCommand = result;
    if (failCommand) throw StateError('fixture command persistence failure');
    return true;
  }
}

class _DmTopicUiState extends _MutableTimelineState {
  _DmTopicUiState(super.jami, super.prefs, this.topicState);

  DmTopicState topicState;
  String selectedTopicId = DmTopicWire.mainId;
  (String, bool)? archiveCall;
  (String, String)? renameCall;
  Map<String, int> unread = const {};
  DmTopicIntroduction introduction = DmTopicIntroduction.none;
  bool introductionFinished = false;
  bool introductionDismissed = false;

  @override
  FriendState? get selectedFriend => const FriendState(
    peerId: _peer,
    confirmed: true,
    conversationId: _conversation,
    displayName: 'Phone B',
  );

  @override
  ConversationScope? get selectedConversationScope => _scope;

  @override
  DmTopicState? get selectedDmTopicState => topicState;

  @override
  String get selectedDmTopicId => selectedTopicId;

  @override
  bool get dmTopicRowVisible => topicState.customTopics.isNotEmpty;

  @override
  Map<String, int> get selectedDmTopicUnreadByTopic => unread;

  @override
  DmTopicIntroduction get dmTopicIntroduction => introduction;

  @override
  void showDmTopicIntroductionPreview() {
    introduction = DmTopicIntroduction.preview;
    notifyListeners();
  }

  @override
  Future<void> finishDmTopicIntroduction() async {
    introductionFinished = true;
    introduction = DmTopicIntroduction.none;
    notifyListeners();
  }

  @override
  Future<void> dismissDmTopicIntroduction() async {
    introductionDismissed = true;
    introduction = DmTopicIntroduction.none;
    notifyListeners();
  }

  @override
  List<ConversationTimelineItem> get selectedDmTopicItems => List.unmodifiable(
    items.where((item) {
      if (item is TimelineDmTopicEventItem) {
        final event = DmTopicEventCodec.decode(item.eventBody);
        return event?.operation == DmTopicOperation.archive &&
            event?.topicId == selectedTopicId;
      }
      final topicId = topicState.topic(item.topicId)?.id ?? DmTopicWire.mainId;
      return topicId == selectedTopicId;
    }),
  );

  @override
  Future<bool> selectDmTopic(
    String topicId, {
    ConversationAction? action,
    bool fromHistorySearch = false,
  }) async {
    if (topicState.topic(topicId) == null) return false;
    selectedTopicId = topicId;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> setDmTopicArchived(String topicId, bool archived) async {
    archiveCall = (topicId, archived);
    return true;
  }

  @override
  Future<bool> renameDmTopic(String topicId, String name) async {
    renameCall = (topicId, name);
    return true;
  }
}

TimelineDmTopicEventItem _archiveEvent(
  int timestamp, {
  required bool archived,
}) => TimelineDmTopicEventItem(
  scope: _scope,
  daemonId: 'archive-event-$timestamp',
  versionId: 'archive-event-version-$timestamp',
  authorId: _peer,
  direction: TimelineDirection.incoming,
  createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true),
  linearizedParent: '',
  eventBody: DmTopicEventCodec.encode(
    DmTopicEvent.archive(
      topicId: '00000000000000000000000000000000',
      revision: timestamp,
      archived: archived,
    ),
  ),
);

DmTopicState _topicState({
  int customTopics = 1,
  bool peerArchived = false,
  String firstTopicName = 'vacation',
}) {
  var state = DmTopicState.initial(const {_local, _peer});
  for (var index = 0; index < customTopics; index++) {
    final id = index.toRadixString(16).padLeft(32, '0');
    state = DmTopicReducer.reduce(
      state,
      DmTopicEventEnvelope(
        commitId: 'create-$index',
        authorId: _local,
        position: index * 2 + 1,
        event: DmTopicEvent.create(
          topicId: id,
          revision: 1,
          name: index == 0 ? firstTopicName : 'topic $index',
          order: index,
        ),
      ),
    );
    if (peerArchived && index == 0) {
      state = DmTopicReducer.reduce(
        state,
        DmTopicEventEnvelope(
          commitId: 'archive-$index',
          authorId: _peer,
          position: index * 2 + 2,
          event: DmTopicEvent.archive(topicId: id, revision: 1, archived: true),
        ),
      );
    }
  }
  return state;
}

Future<_DmTopicUiState> _dmTopicUiState({
  int customTopics = 1,
  bool peerArchived = false,
  String firstTopicName = 'vacation',
}) async {
  SharedPreferences.setMockInitialValues({});
  return _DmTopicUiState(
      JamiClient(),
      await SharedPreferences.getInstance(),
      _topicState(
        customTopics: customTopics,
        peerArchived: peerArchived,
        firstTopicName: firstTopicName,
      ),
    )
    ..accountId = _account
    ..jamiId = _local;
}

Future<_MutableTimelineState> _mutableTimelineState() async {
  SharedPreferences.setMockInitialValues({});
  return _MutableTimelineState(
    JamiClient(),
    await SharedPreferences.getInstance(),
  )..jamiId = _local;
}

Future<_ComposerTimelineState> _composerTimelineState() async {
  SharedPreferences.setMockInitialValues({});
  return _ComposerTimelineState(
      JamiClient(),
      await SharedPreferences.getInstance(),
    )
    ..accountId = _account
    ..jamiId = _local;
}

Widget _timelineApp(
  AppState state, {
  List<ConversationTimelineItem> timeline = const [],
  List<FolderFile> files = const [],
  List<FileXfer> live = const [],
  GroupState? group,
}) => MaterialApp(
  theme: Warm.theme(),
  home: Scaffold(
    body: SizedBox(
      height: 440,
      child: ConversationTimelineView(
        state: state,
        live: live,
        timeline: timeline,
        legacyFiles: files,
        group: group,
      ),
    ),
  ),
);

Widget _liveTimelineApp(_MutableTimelineState state) => MaterialApp(
  theme: Warm.theme(),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: state,
      builder: (context, _) => ConversationTimelineView(
        state: state,
        live: const [],
        timeline: state.items,
        legacyFiles: const [],
      ),
    ),
  ),
);

Widget _composerApp(
  _ComposerTimelineState state, {
  required Future<bool> Function(String) onSend,
}) => MaterialApp(
  theme: Warm.theme(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: ConversationComposer(
        state: state,
        hintText: 'Message Friend',
        fileLabel: 'Share a file',
        onSend: onSend,
      ),
    ),
  ),
);

Widget _chatStageApp(
  AppState state, {
  required String conversationId,
  bool disableAnimations = false,
  bool confirmed = true,
}) => MaterialApp(
  theme: Warm.theme(),
  builder: disableAnimations
      ? (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        )
      : null,
  home: Scaffold(
    body: ChatStage(
      state: state,
      friend: FriendState(
        peerId: _peer,
        confirmed: confirmed,
        conversationId: conversationId,
        displayName: 'Friend',
      ),
    ),
  ),
);

ScrollableState _scrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('file-timeline')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

class _LoadingTimelineState extends _ComposerTimelineState {
  _LoadingTimelineState(super.jami, super.prefs);

  bool loading = false;

  @override
  bool get chatLoading => loading;
}

Future<_LoadingTimelineState> _loadingTimelineState() async {
  SharedPreferences.setMockInitialValues({});
  return _LoadingTimelineState(
      JamiClient(),
      await SharedPreferences.getInstance(),
    )
    ..accountId = _account
    ..jamiId = _local;
}

Widget _flightApp(
  _ComposerTimelineState state, {
  required Future<bool> Function(String) onSend,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: Warm.theme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(
    body: Column(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) => ConversationTimelineView(
              state: state,
              live: const [],
              timeline: state.items,
              legacyFiles: const [],
            ),
          ),
        ),
        ConversationComposer(
          state: state,
          hintText: 'Message Friend',
          fileLabel: 'Share a file',
          onSend: onSend,
        ),
      ],
    ),
  ),
);

/// Each place a message can be seen: the composer or its bubble.
({bool composer, Rect? bubble}) _sightings(
  WidgetTester tester,
  String id,
  String body,
) {
  final field = tester.widget<TextField>(
    find.byKey(const ValueKey('chat-composer')),
  );
  final bubble = find.byKey(ValueKey('message-bubble-$id'));
  final bubbleShown =
      bubble.evaluate().isNotEmpty &&
      tester
          .widgetList<Opacity>(
            find.ancestor(of: bubble, matching: find.byType(Opacity)),
          )
          .every((opacity) => opacity.opacity > 0);
  return (
    composer: field.controller!.text.trim() == body,
    bubble: bubbleShown
        ? tester.getRect(
            find.descendant(of: bubble, matching: find.byType(SelectableText)),
          )
        : null,
  );
}

/// The part of a streaming message shown so far.
String _streamed(WidgetTester tester, String id) {
  final text = tester.widget<SelectableText>(
    find.descendant(
      of: find.byKey(ValueKey('streaming-text:$id'), skipOffstage: false),
      matching: find.byType(SelectableText, skipOffstage: false),
    ),
  );
  return text.data ?? (text.textSpan!.children!.first as TextSpan).text!;
}

/// [tops] of a message seen frame by frame while a new one enters below it:
/// it glides up from [from] over several frames, never back down.
void _expectGlide(List<double> tops, double from, String reason) {
  final to = tops.last;
  expect(to, lessThan(from - 10), reason: '$reason moves up: $tops');
  var previous = from;
  for (final top in tops) {
    expect(top, lessThanOrEqualTo(previous + 1e-6), reason: '$reason: $tops');
    previous = top;
  }
  final between = tops.where((top) => top < from - .5 && top > to + .5);
  expect(
    between.toSet().length,
    greaterThanOrEqualTo(3),
    reason: '$reason glides: $tops',
  );
}

void main() {
  testWidgets(
    'reaction counts show own selection and the six-choice menu fits enlarged text',
    (tester) async {
      final state = await _composerTimelineState();
      state.screen = Screen.home;
      final message = 'f' * 40;
      state.items = [
        TimelineTextItem(
          scope: _scope,
          daemonId: message,
          versionId: message,
          authorId: _peer,
          direction: TimelineDirection.incoming,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          text: 'React to this message',
          reactions: MessageReactions.fromWire({
            'messageId': message,
            'complete': true,
            'entries': [
              {'commitId': '1' * 40, 'authorId': _local, 'emoji': '👍'},
              {'commitId': '2' * 40, 'authorId': _local, 'emoji': '👍'},
              {'commitId': '3' * 40, 'authorId': _peer, 'emoji': '👍'},
            ],
          }, messageId: message)!,
        ),
      ];
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ConversationTimelineView(
              state: state,
              live: const [],
              timeline: state.items,
              legacyFiles: const [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final count = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, '👍 2'),
      );
      expect(count.selected, isTrue);
      await tester.longPress(find.text('React to this message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('React'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      for (final emoji in ReactionWire.palette) {
        expect(
          find.descendant(of: dialog, matching: find.text(emoji)),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final attachment in [false, true]) {
    testWidgets(
      'message selection menu starts a scoped reply (attachment: $attachment)',
      (tester) async {
        final state = await _composerTimelineState();
        state.screen = Screen.home;
        state.items = [
          attachment
              ? TimelineFileItem(
                  scope: _scope,
                  daemonId: 'file-message',
                  versionId: 'file-message',
                  authorId: _peer,
                  direction: TimelineDirection.incoming,
                  createdAt: DateTime.fromMillisecondsSinceEpoch(
                    1000,
                    isUtc: true,
                  ),
                  fileId: 'file-id',
                  displayName: 'Reply to this message',
                  totalBytes: 100,
                  sha3: null,
                  downloaded: false,
                )
              : _text(1, 'Reply to this message'),
        ];
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: state,
                builder: (context, _) => Column(
                  children: [
                    Expanded(
                      child: ConversationTimelineView(
                        state: state,
                        live: const [],
                        timeline: state.items,
                        legacyFiles: const [],
                      ),
                    ),
                    ConversationComposer(
                      state: state,
                      hintText: 'Message Friend',
                      fileLabel: 'Share a file',
                      onSend: (_) async => true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.longPress(find.text('Reply to this message'));
        await tester.pumpAndSettle();
        expect(find.text('Reply'), findsOneWidget);
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
        expect(find.text('Replying to Friend'), findsOneWidget);
        expect(find.byTooltip('Cancel reply'), findsOneWidget);
        await tester.tap(find.byTooltip('Cancel reply'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('Reply to this message'),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('Reply'), findsOneWidget);
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Cancel reply'), findsOneWidget);
        await tester.tap(find.byTooltip('Cancel reply'));
        await tester.pumpAndSettle();
        Focus.of(
          tester.element(find.text('Reply to this message')),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(find.text('Reply'), findsOneWidget);
        expect(find.text('Copy'), attachment ? findsNothing : findsOneWidget);
        state.setProtectedSurfaceLocked(true);
        await tester.pump();
        state.setProtectedSurfaceLocked(false);
        await tester.pump();
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Cancel reply'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'reply preview resolves history and cancels without clearing text',
    (tester) async {
      final state = await _composerTimelineState();
      state.screen = Screen.home;
      state.items = [_text(1, 'Original message')];
      addTearDown(state.dispose);
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      await tester.enterText(find.byType(TextField).first, 'My draft');
      expect(
        state.beginReply(
          state.items.single,
          owner: state.conversationActionOwner,
        ),
        isTrue,
      );
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      await tester.pump();
      expect(find.text('Original message'), findsOneWidget);
      expect(find.text('Replying to Friend'), findsOneWidget);
      state.items = const [];
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      expect(find.text('Message unavailable'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pump();
      expect(find.byKey(const ValueKey('reply-preview')), findsNothing);
      expect(find.text('My draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await bundledStickerManifest;
  });
  testWidgets(
    'camera cancellation keeps the draft and accepted photo waits for Send',
    (tester) async {
      final state = await _composerTimelineState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      await tester.tap(find.byKey(const ValueKey('send-file-button')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'caption',
      );
      await tester.tap(find.byTooltip('Take photo'));
      await tester.pump();
      expect(find.text('example.txt'), findsOneWidget);
      expect(find.text('caption'), findsOneWidget);
      expect(state.fileSends, 0);
      state.photoCancelled = false;
      await tester.tap(find.byTooltip('Take photo'));
      await tester.pump();
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('caption'), findsOneWidget);
      expect(state.fileSends, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'sticker selection stages without publishing and keyboard restores the caret',
    (tester) async {
      await tester.runAsync(() async {
        await bundledStickerManifest;
      });
      final state = await _composerTimelineState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      final field = find.byKey(const ValueKey('chat-composer'));
      await tester.enterText(field, 'caption');
      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.tap(find.byKey(const ValueKey('composer-picker-button')));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      await tester.ensureVisible(find.text('Angry cat'));
      await tester.pump();
      await tester.tap(find.text('Angry cat'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('composer-media-preview')),
        findsOneWidget,
      );
      expect(state.fileSends, 0);
      expect(controller.text, 'caption');
      await tester.tap(find.byKey(const ValueKey('composer-picker-button')));
      await tester.pump();
      expect(controller.selection.baseOffset, 3);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final textSucceeded in [true, false]) {
    testWidgets(
      'staged file batch stops or advances on exact text outcome: $textSucceeded',
      (tester) async {
        final state = await _composerTimelineState();
        addTearDown(state.dispose);
        var textSends = 0;
        await tester.pumpWidget(
          _composerApp(
            state,
            onSend: (_) async {
              textSends++;
              return textSucceeded;
            },
          ),
        );
        await tester.tap(find.byKey(const ValueKey('send-file-button')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('composer-media-preview')),
          findsOneWidget,
        );
        expect(state.fileSends, 0);
        await tester.enterText(
          find.byKey(const ValueKey('chat-composer')),
          'caption',
        );
        await tester.tap(find.byKey(const ValueKey('send-chat-button')));
        await tester.pump();
        expect(textSends, 1);
        expect(state.fileSends, textSucceeded ? 1 : 0);
        expect(
          find.byKey(const ValueKey('composer-media-preview')),
          findsOneWidget,
        );
        final controller = tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!;
        expect(controller.text, textSucceeded ? '' : 'caption');
        if (textSucceeded) {
          state.fileOutcome = ComposerSendStatus.committed;
          await tester.tap(find.byKey(const ValueKey('send-chat-button')));
          await tester.pump();
          expect(textSends, 1);
          expect(state.fileSends, 2);
          expect(
            find.byKey(const ValueKey('composer-media-preview')),
            findsNothing,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'command failure restores retry and preserves the command draft',
    (tester) async {
      final state = await _composerTimelineState();
      addTearDown(state.dispose);
      state.commandResult = const ComposerQueryResult(
        results: [
          ComposerResult(
            kind: ComposerResultKind.createTopic,
            label: 'Create vacation',
            topicName: 'vacation',
          ),
        ],
        isSendableText: false,
        isExactAction: true,
      );
      state.failCommand = true;
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      final field = find.byType(TextField);
      await tester.enterText(field, '/topic create vacation');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<TextField>(field).controller!.text,
        '/topic create vacation',
      );
      state.failCommand = false;
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a caret move does not change the submitted draft revision', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    final sent = Completer<bool>();
    await tester.pumpWidget(_composerApp(state, onSend: (_) => sent.future));
    final field = find.byType(TextField);
    await tester.enterText(field, 'same draft');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    tester.widget<TextField>(field).controller!.selection =
        const TextSelection.collapsed(offset: 0);
    sent.complete(true);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('send completion cannot own an A-B-A conversation visit', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.peerId = _peer;
    final sent = Completer<bool>();
    await tester.pumpWidget(_composerApp(state, onSend: (_) => sent.future));
    final field = find.byType(TextField);
    await tester.enterText(field, 'same draft');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    state.peerId = 'c' * 40;
    state.peerId = _peer;
    sent.complete(true);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'same draft');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final draft in ['new draft', 'first draft']) {
    testWidgets('send completion preserves revised draft: $draft', (
      tester,
    ) async {
      final state = await _composerTimelineState();
      addTearDown(state.dispose);
      final sent = Completer<bool>();
      await tester.pumpWidget(_composerApp(state, onSend: (_) => sent.future));
      final field = find.byType(TextField);
      await tester.enterText(field, 'first draft');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.enterText(field, 'intermediate edit');
      await tester.enterText(field, draft);
      sent.complete(true);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, draft);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('successful send clears only the unchanged draft', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    final sent = Completer<bool>();
    await tester.pumpWidget(_composerApp(state, onSend: (_) => sent.future));
    final field = find.byType(TextField);
    await tester.enterText(field, 'first draft');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    sent.complete(true);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shared topic surface honors topics, full width, and off', (
    tester,
  ) async {
    Future<void> pump(TopicStripSurfaceSettings settings) => tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            height: 180,
            child: TopicStripSurface(
              settings: settings,
              endpoint: 124,
              pillBottom: 39,
            ),
          ),
        ),
      ),
    );

    await pump(const TopicStripSurfaceSettings());
    expect(
      tester.getSize(find.byKey(const ValueKey('topic-strip-surface'))).width,
      124,
    );
    await pump(
      const TopicStripSurfaceSettings(
        coverage: TopicStripSurfaceCoverage.fullWidth,
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('topic-strip-surface'))).width,
      300,
    );
    await pump(
      const TopicStripSurfaceSettings(coverage: TopicStripSurfaceCoverage.off),
    );
    expect(
      find.byKey(const ValueKey('topic-strip-surface-off')),
      findsOneWidget,
    );
  });
  testWidgets('DM topic row appears only after the first custom topic', (
    tester,
  ) async {
    final plain = await _dmTopicUiState(customTopics: 0);
    addTearDown(plain.dispose);
    await tester.pumpWidget(
      _chatStageApp(plain, conversationId: _conversation),
    );
    expect(find.byKey(const ValueKey('dm-topic-strip')), findsNothing);

    final topics = await _dmTopicUiState();
    addTearDown(topics.dispose);
    await tester.pumpWidget(
      _chatStageApp(topics, conversationId: _conversation),
    );
    expect(find.byKey(const ValueKey('dm-topic-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('dm-topic-pill:main')), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('dm-topic-pill:00000000000000000000000000000000'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('dm-topic-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('dm-topic-strip-card')), findsNothing);
  });

  testWidgets('DM topic surface ends at the add pill', (tester) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    await tester.pump();

    final surface = tester.getRect(
      find.byKey(const ValueKey('dm-topic-surface')),
    );
    final add = tester.getRect(find.byKey(const ValueKey('dm-topic-add')));
    final pill = tester.getRect(
      find
          .descendant(
            of: find.byKey(const ValueKey('dm-topic-pill:main')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.right, closeTo(add.right, .01));
    expect(surface.bottom - pill.bottom, closeTo(20, .01));

    final rightFade = tester.getRect(
      find.byKey(const ValueKey('dm-topic-surface-right-fade')),
    );
    expect(rightFade.width, closeTo(14, .01));
    expect(rightFade.right, closeTo(add.right, .01));

    final mainColor = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('dm-topic-surface-main-color')),
    );
    final gradient = (mainColor.decoration as BoxDecoration).gradient!;
    expect(gradient.colors.first.a, closeTo(.42, .001));
    expect(gradient.stops, [0, closeTo(42.5 / 57.5, .001), 1]);
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    for (final filter in tester.widgetList<BackdropFilter>(
      find.byType(BackdropFilter),
    )) {
      expect(filter.filter.toString(), contains('2.0'));
    }
  });

  testWidgets('DM topic surface follows topic label and chat width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 600);
    addTearDown(tester.view.resetPhysicalSize);
    final state = await _dmTopicUiState(
      firstTopicName: 'longer vacation plans',
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.pump();

    final surface = tester.getRect(
      find.byKey(const ValueKey('dm-topic-surface')),
    );
    final add = tester.getRect(find.byKey(const ValueKey('dm-topic-add')));
    expect(surface.right, closeTo(add.right, .01));
  });

  testWidgets('DM topic surface follows the visible topic viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.resetPhysicalSize);
    final state = await _dmTopicUiState(customTopics: 20);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.pump();

    final strip = tester.getRect(find.byKey(const ValueKey('dm-topic-strip')));
    var surface = tester.getRect(
      find.byKey(const ValueKey('dm-topic-surface')),
    );
    expect(find.byKey(const ValueKey('dm-topic-add')), findsNothing);
    expect(surface.right, closeTo(strip.right, .01));

    await tester.drag(
      find.byKey(const ValueKey('dm-topic-scroll')),
      const Offset(-3000, 0),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    final add = tester.getRect(find.byKey(const ValueKey('dm-topic-add')));
    surface = tester.getRect(find.byKey(const ValueKey('dm-topic-surface')));
    expect(surface.right, closeTo(add.right, .01));
  });

  testWidgets('topic suggestions never interrupt the chat', (tester) async {
    final state = await _dmTopicUiState(customTopics: 0);
    addTearDown(state.dispose);
    state.introduction = DmTopicIntroduction.suggestion;
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    expect(find.byKey(const ValueKey('dm-topic-introduction')), findsNothing);
    expect(find.text('Keep this batch tidy?'), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
  });

  testWidgets('partial topic commands stay text-only', (tester) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.commandResult = const ComposerQueryResult(
      results: [
        ComposerResult(
          kind: ComposerResultKind.createTopic,
          label: '/topic create',
          executable: false,
        ),
      ],
      isSendableText: false,
    );
    await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer')),
      '/topic cr',
    );
    await tester.pump();

    expect(find.text('/topic create'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer-command-action-icon')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('composer-command-popup')),
      findsOneWidget,
    );
  });

  for (final size in const [Size(390, 800), Size(1200, 800)]) {
    testWidgets('command popup lines up with the text box at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = await _composerTimelineState();
      addTearDown(state.dispose);
      state.commandResult = const ComposerQueryResult(
        results: [
          ComposerResult(
            kind: ComposerResultKind.gravity,
            label: '/gravity',
            description: 'FIRST LAW!!',
            showActionIcon: true,
          ),
        ],
        isSendableText: false,
      );
      await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        '/gra',
      );
      await tester.pump();

      final popup = tester.getRect(
        find.byKey(const ValueKey('composer-command-popup')),
      );
      final field = tester.getRect(find.byKey(const ValueKey('chat-composer')));
      expect(popup.left, moreOrLessEquals(field.left, epsilon: 1));
      expect(popup.right, moreOrLessEquals(field.right, epsilon: 1));
    });
  }

  testWidgets('Tab completes the selected slash command', (tester) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.commandResult = const ComposerQueryResult(
      results: [
        ComposerResult(
          kind: ComposerResultKind.gravity,
          label: '/gravity',
          showActionIcon: true,
        ),
      ],
      isSendableText: false,
    );
    var sent = 0;
    await tester.pumpWidget(
      _composerApp(
        state,
        onSend: (_) async {
          sent++;
          return true;
        },
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(field, '/gra');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(tester.widget<TextField>(field).controller!.text, '/gravity');
    expect(sent, 0);
    final focused = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(focused.focusNode.hasFocus, isTrue);
  });

  testWidgets('exact topic action is compact and runs instead of sending', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    const result = ComposerResult(
      kind: ComposerResultKind.createTopic,
      label: 'Create vacation',
      topicName: 'vacation',
      showActionIcon: true,
    );
    state.commandResult = const ComposerQueryResult(
      results: [result],
      isSendableText: false,
      isExactAction: true,
    );
    final sent = <String>[];
    await tester.pumpWidget(
      _composerApp(
        state,
        onSend: (body) async {
          sent.add(body);
          return true;
        },
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer')),
      '/topic create vacation',
    );
    await tester.pump();

    expect(find.text('Create vacation'), findsOneWidget);
    expect(find.text('Phone B'), findsNothing);
    expect(
      find.byKey(const ValueKey('composer-command-action-icon')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-command-submit')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('send-chat-button')));
    await tester.pump();
    expect(state.executedCommand, result);
    expect(sent, isEmpty);
  });

  testWidgets('cross-chat command shows identity only on the right', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.commandResult = const ComposerQueryResult(
      results: [
        ComposerResult(
          kind: ComposerResultKind.switchTopic,
          label: 'vacation',
          ownerKey: 'other',
          conversationId: 'other-conversation',
          topicId: 'other-topic',
          chatDisplayName: 'Phone A',
          showChatIdentity: true,
        ),
      ],
      isSendableText: false,
    );
    await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));

    await tester.enterText(find.byKey(const ValueKey('chat-composer')), '/vac');
    await tester.pump();

    expect(find.text('vacation'), findsOneWidget);
    expect(find.text('Phone A'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Phone A')).dx,
      greaterThan(tester.getCenter(find.text('vacation')).dx),
    );
  });

  testWidgets('unknown slash text is sent as a normal message', (tester) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    final sent = <String>[];
    await tester.pumpWidget(
      _composerApp(
        state,
        onSend: (body) async {
          sent.add(body);
          return true;
        },
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer')),
      '/does-not-exist',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-chat-button')));
    await tester.pump();

    expect(sent, ['/does-not-exist']);
    expect(state.executedCommand, isNull);
    expect(find.byKey(const ValueKey('composer-command-popup')), findsNothing);
  });

  testWidgets('arrow keys and Enter activate the selected command row', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    const first = ComposerResult(
      kind: ComposerResultKind.switchTopic,
      label: 'plans',
      ownerKey: _peer,
      conversationId: _conversation,
      topicId: 'plans',
    );
    const second = ComposerResult(
      kind: ComposerResultKind.switchTopic,
      label: 'planning',
      ownerKey: _peer,
      conversationId: _conversation,
      topicId: 'planning',
    );
    state.commandResult = const ComposerQueryResult(
      results: [first, second],
      isSendableText: false,
    );
    await tester.pumpWidget(_composerApp(state, onSend: (_) async => true));
    await tester.enterText(find.byKey(const ValueKey('chat-composer')), '/pla');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(state.executedCommand, second);
  });

  testWidgets('DM topic selection filters messages and keeps plus in the row', (
    tester,
  ) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    state.items = [
      _text(1, 'main message'),
      _text(2, 'topic message', topicId: topicId, topicTagged: true),
    ];

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    expect(find.text('main message'), findsOneWidget);
    expect(find.text('topic message'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('dm-topic-pill:$topicId')));
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    expect(state.selectedTopicId, topicId);
    expect(find.text('main message'), findsNothing);
    expect(find.text('topic message'), findsOneWidget);

    final row = tester.getRect(find.byKey(const ValueKey('dm-topic-strip')));
    final add = tester.getRect(find.byKey(const ValueKey('dm-topic-add')));
    expect(row.overlaps(add), isTrue);
  });

  testWidgets('hold opens the anchored topic menu and main has no actions', (
    tester,
  ) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    await tester.longPress(
      find.byKey(const ValueKey('dm-topic-pill:$topicId')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('dm-topic-anchored-menu')),
      findsOneWidget,
    );
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Archive for me'), findsOneWidget);

    await tester.tap(find.text('Archive for me'));
    await tester.pumpAndSettle();
    expect(state.archiveCall, (topicId, true));

    await tester.longPress(find.byKey(const ValueKey('dm-topic-pill:main')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dm-topic-anchored-menu')), findsNothing);
  });

  testWidgets('secondary click opens the anchored topic menu', (tester) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    await tester.tap(
      find.byKey(const ValueKey('dm-topic-pill:$topicId')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dm-topic-anchored-menu')),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dm-topic-anchored-menu')),
      findsOneWidget,
    );
  });

  testWidgets('keyboard context action opens the focused topic menu', (
    tester,
  ) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    final pill = find.byKey(ValueKey('dm-topic-pill:$topicId'));

    await tester.tap(pill);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dm-topic-anchored-menu')),
      findsOneWidget,
    );
  });

  testWidgets('plus opens the same anchored menu as a normal pill', (
    tester,
  ) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    await tester.tap(find.byKey(const ValueKey('dm-topic-add')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dm-topic-anchored-menu')),
      findsOneWidget,
    );
    expect(find.text('New topic'), findsOneWidget);
    expect(find.text('Archived topics'), findsNothing);
  });

  testWidgets('peer archive is a centered system marker, not a message', (
    tester,
  ) async {
    final state = await _dmTopicUiState();
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    state
      ..selectedTopicId = topicId
      ..items = [
        _text(1, 'before', topicId: topicId, topicTagged: true),
        _archiveEvent(2, archived: true),
        _text(3, 'after', topicId: topicId, topicTagged: true),
      ];

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    expect(find.text('Phone B archived this topic'), findsOneWidget);
    expect(
      find.text('They will not receive notifications here.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dm-topic-marker:archive-event-2')),
      findsOneWidget,
    );
    expect(find.text('Sent to you'), findsNothing);
  });

  testWidgets('peer archive offers a clear local archive action', (
    tester,
  ) async {
    final state = await _dmTopicUiState(peerArchived: true);
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    state.selectedTopicId = topicId;

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    final action = find.byKey(const ValueKey('dm-topic-archive-for-me-too'));
    expect(action, findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Archive for me too'),
      findsOneWidget,
    );

    await tester.tap(action);
    await tester.pump();
    expect(state.archiveCall, (topicId, true));
  });

  testWidgets('peer-archived topic exposes its state to accessibility', (
    tester,
  ) async {
    final state = await _dmTopicUiState(peerArchived: true);
    addTearDown(state.dispose);
    const topicId = '00000000000000000000000000000000';
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('dm-topic-pill:$topicId')))
          .label,
      contains('archived by'),
    );
  });

  testWidgets('an off-screen unread topic shows the correct row-edge marker', (
    tester,
  ) async {
    final state = await _dmTopicUiState(customTopics: 14);
    addTearDown(state.dispose);
    final lastTopicId = 13.toRadixString(16).padLeft(32, '0');
    state.unread = {lastTopicId: 3};
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('dm-topic-unread-edge-right')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dm-topic-unread-edge-left')),
      findsNothing,
    );

    await tester.drag(
      find.byKey(const ValueKey('dm-topic-scroll')),
      const Offset(-5000, 0),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dm-topic-unread-edge-right')),
      findsNothing,
    );
  });

  testWidgets('opens at newest and keeps a new live item visible', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    final files = [for (var i = 1; i <= 30; i++) _file(i)];

    await tester.pumpWidget(_timelineApp(state, files: files));
    expect(_scrollable(tester).position.pixels, 0);
    expect(find.text('file-30.txt'), findsOneWidget);

    final withIncoming = [...files, _file(31)];
    await tester.pumpWidget(_timelineApp(state, files: withIncoming));
    await tester.pump();

    expect(_scrollable(tester).position.pixels, 0);
    expect(find.text('file-31.txt'), findsOneWidget);
    final timelineRect = tester.getRect(
      find.byKey(const ValueKey('file-timeline')),
    );
    expect(
      timelineRect.overlaps(tester.getRect(find.text('file-31.txt'))),
      isTrue,
    );
  });

  testWidgets('prepending older history preserves the viewport offset', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    final files = [for (var i = 10; i < 40; i++) _file(i)];
    await tester.pumpWidget(_timelineApp(state, files: files));
    final position = _scrollable(tester).position;
    position.jumpTo(500);
    await tester.pump();
    final before = position.pixels;

    await tester.pumpWidget(_timelineApp(state, files: [_file(1), ...files]));
    await tester.pump();

    expect(_scrollable(tester).position.pixels, closeTo(before, .01));
    final updated = _scrollable(tester).position;
    updated.jumpTo(updated.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('file-1.txt'), findsOneWidget);
  });

  testWidgets('new text streams by character and respects motion setting', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _timelineApp(state, timeline: [_text(100, 'already here')]),
    );
    expect(
      find.byKey(const ValueKey('chat-entry-motion:message-100')),
      findsNothing,
    );

    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'already here'), _text(200, 'just arrived')],
      ),
    );
    final stream = find.byKey(const ValueKey('streaming-text:message-200'));
    expect(stream, findsOneWidget);
    // It lands first, then streams.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300 + 96));
    final partial = _streamed(tester, 'message-200');
    expect(partial, isNotEmpty);
    expect('just arrived'.startsWith(partial), isTrue);
    expect(partial, isNot('just arrived'));
    await tester.pumpAndSettle();
    expect(find.text('just arrived'), findsOneWidget);

    state.appSettings = state.appSettings.withChatMotionEnabled(false);
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _text(100, 'already here'),
          _text(200, 'just arrived'),
          _text(300, 'motion disabled'),
        ],
      ),
    );
    expect(
      find.byKey(const ValueKey('chat-entry-motion:message-300')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('streaming-text:message-300')),
      findsNothing,
    );
    expect(find.text('motion disabled'), findsOneWidget);
  });

  testWidgets('under gravity own messages leave the composer, others drop', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    gravityImpactSound = (_, _) {};
    addTearDown(() => gravityMode.value = false);
    final state = await _mutableTimelineState();
    addTearDown(state.dispose);
    state.items = [_text(100, 'hello')];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    gravityMode.value = true;
    for (var i = 0; i < 250; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final composer = tester.getRect(
      find.byKey(const ValueKey('conversation-composer')),
    );

    state.items = [...state.items, _outgoingText(200, 'mine')];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final mine = tester.getRect(
      find.byKey(const ValueKey('message-bubble-outgoing-200-mine')),
    );
    expect(mine.bottom, closeTo(composer.top, 1));
    expect(mine.height, lessThan(10));
    expect(mine.left, greaterThanOrEqualTo(composer.left - .5));
    expect(mine.right, lessThanOrEqualTo(composer.right + .5));

    state.items = [...state.items, _text(300, 'theirs')];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final theirs = tester.getRect(
      find.byKey(const ValueKey('message-bubble-message-300')),
    );
    expect(theirs.bottom, lessThan(15));
    expect(theirs.height, greaterThan(20));
  });

  testWidgets('under gravity each sent message shows exactly once', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    gravityImpactSound = (_, _) {};
    addTearDown(() => gravityMode.value = false);
    final state = await _mutableTimelineState();
    addTearDown(state.dispose);
    state.items = [_text(100, 'hello')];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    gravityMode.value = true;
    for (var i = 0; i < 250; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final sent = <String>[];
    final heights = <String, double>{};
    void expectEachOnce(String when) {
      for (final id in sent) {
        final bubble = find.byKey(ValueKey('message-bubble-$id'));
        expect(bubble, findsOneWidget, reason: '$id $when');
        // A message already out never squeezes out of the composer again.
        if (heights[id] case final full?) {
          expect(
            tester.getSize(bubble).height,
            closeTo(full, .5),
            reason: '$id $when',
          );
        }
      }
    }

    for (final (at, text) in [(200, 'one'), (210, 'two'), (220, 'three')]) {
      final item = _outgoingText(at, text);
      sent.add(item.daemonId);
      state.items = [...state.items, item];
      await tester.pumpWidget(
        _chatStageApp(state, conversationId: _conversation),
      );
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectEachOnce('frame $i after sending $text');
      }
      heights[item.daemonId] = tester
          .getSize(find.byKey(ValueKey('message-bubble-${item.daemonId}')))
          .height;
    }
  });

  testWidgets('keyboard toggles under gravity never duplicate or move the '
      'composer while its line holds', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    gravityImpactSound = (_, _) {};
    addTearDown(() => gravityMode.value = false);
    final state = await _mutableTimelineState();
    addTearDown(state.dispose);
    state.items = [_text(100, 'hello'), _outgoingText(110, 'hi')];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    // This drop order shatters a tooltip-bearing control during keyboard resize.
    gravityRandom = math.Random(20);
    gravityMode.value = true;
    for (var i = 0; i < 250; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    var shattered = false;
    for (final inset in [300.0, 0.0, 300.0, 0.0, 300.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        shattered |= gravityDebug().broken > 0;
        final field = find.byKey(const ValueKey('chat-composer'));
        expect(field, findsOneWidget, reason: 'inset $inset frame $i');
        final bar = tester.getRect(
          find.byKey(const ValueKey('conversation-composer')),
        );
        final rect = tester.getRect(field);
        expect(
          bar.inflate(.5).contains(rect.topLeft) &&
              bar.inflate(.5).contains(rect.bottomRight),
          isTrue,
          reason: 'inset $inset frame $i: field $rect left bar $bar',
        );
      }
    }
    expect(shattered, isTrue);
  });

  testWidgets('a pending request waits for acceptance without a composer', (
    tester,
  ) async {
    final state = await _mutableTimelineState();
    addTearDown(state.dispose);

    // Jami already names the conversation while the request is pending.
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation, confirmed: false),
    );
    expect(find.text('Waiting for Friend to accept'), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-composer')), findsNothing);
    expect(find.textContaining('Draft limit'), findsNothing);
  });

  testWidgets('the first message animates out of an empty conversation', (
    tester,
  ) async {
    final state = await _mutableTimelineState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    expect(find.byKey(const ValueKey('file-timeline')), findsOneWidget);
    expect(find.text('Your conversation starts here'), findsOneWidget);

    state.items = [_text(100, 'first arrival')];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    // The splash fades out instead of vanishing.
    expect(find.text('Your conversation starts here'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Your conversation starts here'), findsNothing);
    // Its slot opens from zero height, below the viewport's onstage check.
    expect(
      find.byKey(
        const ValueKey('chat-entry-motion:message-100'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('persistent text and fallback files share one chronology', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(200, 'second'), _text(400, 'fourth')],
        files: [_file(100), _file(300)],
      ),
    );

    final positions = [
      tester.getTopLeft(find.text('file-100.txt')).dy,
      tester.getTopLeft(find.text('second')).dy,
      tester.getTopLeft(find.text('file-300.txt')).dy,
      tester.getTopLeft(find.text('fourth')).dy,
    ];
    expect(positions, orderedEquals([...positions]..sort()));
  });

  testWidgets(
    'inward timestamps face the conversation and receipts stay last',
    (tester) async {
      final state = await _state();
      addTearDown(state.dispose);
      state.appSettings = state.appSettings.withMessageTimestampStyle(
        MessageTimestampStyle.inward,
      );

      final incoming = _text(100, 'incoming');
      final outgoing = _outgoingText(
        200,
        'outgoing',
        deliveryState: TimelineDeliveryState.delivered,
      );
      final outgoingLast = _outgoingText(
        250,
        'outgoing last',
        deliveryState: TimelineDeliveryState.delivered,
      );
      await tester.pumpWidget(
        _timelineApp(state, timeline: [incoming, outgoing, outgoingLast]),
      );

      final incomingTime = DateTime.fromMillisecondsSinceEpoch(
        100 * 1000,
        isUtc: true,
      ).toLocal();
      final outgoingTime = DateTime.fromMillisecondsSinceEpoch(
        250 * 1000,
        isUtc: true,
      ).toLocal();
      String clock(DateTime value) =>
          '${value.hour.toString().padLeft(2, '0')}:'
          '${value.minute.toString().padLeft(2, '0')}';
      final incomingBubble = tester.getRect(
        find.byKey(const ValueKey('message-bubble-message-100')),
      );
      final outgoingBubble = tester.getRect(
        find.byKey(const ValueKey('message-bubble-outgoing-200-outgoing')),
      );
      final outgoingLastBubble = tester.getRect(
        find.byKey(const ValueKey('message-bubble-outgoing-250-outgoing last')),
      );
      expect(
        tester.getRect(find.text(clock(incomingTime))).left,
        greaterThan(incomingBubble.right),
      );
      expect(
        tester.getRect(find.text(clock(outgoingTime))).right,
        lessThan(outgoingLastBubble.left),
      );
      expect(outgoingLastBubble.right, outgoingBubble.right);
      expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
      expect(find.byIcon(Icons.done_rounded), findsNothing);
    },
  );

  testWidgets('after-pause receipt appears without another chat event', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    state.appSettings = state.appSettings.withMessageReceiptVisibility(
      MessageReceiptVisibility.afterPause,
    );
    final message = TimelineTextItem(
      scope: _scope,
      daemonId: 'pause-receipt',
      versionId: 'pause-receipt-version',
      authorId: _local,
      direction: TimelineDirection.outgoing,
      createdAt: DateTime.now().subtract(
        const Duration(minutes: 4, seconds: 59),
      ),
      text: 'wait for the receipt',
      deliveryState: TimelineDeliveryState.delivered,
    );

    await tester.pumpWidget(_timelineApp(state, timeline: [message]));
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  testWidgets('receipt visibility updates existing and new messages live', (
    tester,
  ) async {
    final state = await _mutableTimelineState();
    addTearDown(state.dispose);
    state.appSettings = state.appSettings
        .withMessageReceiptStyle(MessageReceiptStyle.whatsapp)
        .withMessageReceiptVisibility(MessageReceiptVisibility.afterPause);
    state.items = [
      TimelineTextItem(
        scope: _scope,
        daemonId: 'existing-receipt',
        versionId: 'existing-receipt-version',
        authorId: _local,
        direction: TimelineDirection.outgoing,
        createdAt: DateTime.now(),
        text: 'existing',
        deliveryState: TimelineDeliveryState.delivered,
      ),
    ];
    await tester.pumpWidget(_liveTimelineApp(state));
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);

    state.appSettings = state.appSettings.withMessageReceiptVisibility(
      MessageReceiptVisibility.always,
    );
    state.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);

    state.items = [
      ...state.items,
      TimelineTextItem(
        scope: _scope,
        daemonId: 'new-receipt',
        versionId: 'new-receipt-version',
        authorId: _local,
        direction: TimelineDirection.outgoing,
        createdAt: DateTime.now(),
        text: 'new',
        deliveryState: TimelineDeliveryState.read,
      ),
    ];
    state.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);

    state.appSettings = state.appSettings.withMessageReceiptVisibility(
      MessageReceiptVisibility.afterPause,
    );
    state.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
  });

  testWidgets('WhatsApp metadata shares the message text flow', (tester) async {
    final state = await _state();
    addTearDown(state.dispose);
    state.appSettings = state.appSettings.withMessageTimestampStyle(
      MessageTimestampStyle.whatsapp,
    );

    await tester.pumpWidget(
      _timelineApp(state, timeline: [_outgoingText(100, 'short')]),
    );
    await tester.pumpAndSettle();

    final bubble = find.byKey(
      const ValueKey('message-bubble-outgoing-100-short'),
    );
    final text = tester.widget<SelectableText>(
      find.descendant(of: bubble, matching: find.byType(SelectableText)),
    );
    expect(text.textSpan?.children, contains(isA<WidgetSpan>()));
  });

  testWidgets('short WhatsApp metadata stays on the text line', (tester) async {
    final state = await _state();
    addTearDown(state.dispose);
    state.appSettings = state.appSettings.withMessageTimestampStyle(
      MessageTimestampStyle.whatsapp,
    );
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'short'), _outgoingText(400, 'short too')],
      ),
    );

    final incoming = tester.getSize(
      find.byKey(const ValueKey('message-bubble-message-100')),
    );
    final outgoing = tester.getSize(
      find.byKey(const ValueKey('message-bubble-outgoing-400-short too')),
    );
    expect(outgoing.height, closeTo(incoming.height, .01));
    expect(outgoing.width, greaterThan(incoming.width));
  });

  testWidgets('receipt styles map sent, delivered, and read distinctly', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);

    Future<void> pump(
      MessageReceiptStyle style,
      TimelineDeliveryState delivery,
    ) async {
      state.appSettings = state.appSettings.withMessageReceiptStyle(style);
      await tester.pumpWidget(
        _timelineApp(
          state,
          timeline: [_outgoingText(100, 'probe', deliveryState: delivery)],
        ),
      );
      await tester.pumpAndSettle();
    }

    // WhatsApp: ✓ sent · ✓✓ delivered · ✓✓ recolored read.
    await pump(MessageReceiptStyle.whatsapp, TimelineDeliveryState.sent);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    await pump(MessageReceiptStyle.whatsapp, TimelineDeliveryState.delivered);
    Color doubleCheckColor() =>
        tester.widget<Icon>(find.byIcon(Icons.done_all_rounded)).color!;
    final delivered = doubleCheckColor();
    await pump(MessageReceiptStyle.whatsapp, TimelineDeliveryState.read);
    expect(
      doubleCheckColor(),
      isNot(delivered),
      reason: 'read is the green pass over the same double check',
    );

    // Syb-L: one outbound arrow, double arrow, then green double arrow.
    await pump(MessageReceiptStyle.sybl, TimelineDeliveryState.sent);
    expect(find.byIcon(Icons.north_east_rounded), findsOneWidget);
    await pump(MessageReceiptStyle.sybl, TimelineDeliveryState.delivered);
    Color syblDoubleColor() =>
        tester.widget<Icon>(find.byIcon(Icons.multiple_stop_rounded)).color!;
    final syblDelivered = syblDoubleColor();
    await pump(MessageReceiptStyle.sybl, TimelineDeliveryState.read);
    expect(syblDoubleColor(), isNot(syblDelivered));

    // Messenger: ○ sent · ○✓ delivered · the reader's avatar for direct read.
    await pump(MessageReceiptStyle.messenger, TimelineDeliveryState.sent);
    expect(
      find.byKey(const ValueKey('messenger-receipt-sent')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    await pump(MessageReceiptStyle.messenger, TimelineDeliveryState.delivered);
    expect(
      find.byKey(const ValueKey('messenger-receipt-delivered')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await pump(MessageReceiptStyle.messenger, TimelineDeliveryState.read);
    expect(find.byKey(const ValueKey('messenger-receipt-read')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SyblAvatar && widget.size == 14,
      ),
      findsOneWidget,
      reason: 'messenger read is the tiny reader avatar',
    );

    // Groups use one fixed compact receipt, independent of private DM settings.
    const group = GroupState(
      conversationId: _conversation,
      title: 'Crew',
      memberCount: 2,
      canManageMembers: false,
      memberDisplayNames: {_peer: 'Friend'},
      memberIds: [_peer],
      activeMemberIds: {_peer},
      invitedMemberIds: {},
    );
    state.appSettings = state.appSettings
        .withMessageReceiptStyle(MessageReceiptStyle.messenger)
        .withMessageReceiptVisibility(MessageReceiptVisibility.afterPause);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _outgoingText(
            now,
            'group read',
            deliveryState: TimelineDeliveryState.read,
            readByMemberIds: const {_peer},
          ),
        ],
        group: group,
      ),
    );
    expect(find.byKey(const ValueKey('messenger-receipt-read')), findsNothing);
    expect(find.byKey(const ValueKey('group-receipt')), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    final count = find.byKey(const ValueKey('group-receipt-count'));
    expect(count, findsOneWidget);
    expect(tester.widget<Text>(count).data, '1');
    final positioned = tester.widget<Positioned>(
      find.ancestor(of: count, matching: find.byType(Positioned)).first,
    );
    expect(positioned.left, 12);
    expect(positioned.bottom, -1);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Read by 1 of 1',
      ),
      findsOneWidget,
    );
  });

  testWidgets('receipt style is independent of every timestamp layout', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    for (final receiptStyle in MessageReceiptStyle.values) {
      state.appSettings = state.appSettings.withMessageReceiptStyle(
        receiptStyle,
      );
      for (final timestampStyle in MessageTimestampStyle.values) {
        state.appSettings = state.appSettings.withMessageTimestampStyle(
          timestampStyle,
        );
        await tester.pumpWidget(
          _timelineApp(
            state,
            timeline: [
              _outgoingText(
                100,
                'receipt-$receiptStyle-$timestampStyle',
                deliveryState: TimelineDeliveryState.delivered,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final receipt = switch (receiptStyle) {
          MessageReceiptStyle.whatsapp => find.byIcon(Icons.done_all_rounded),
          MessageReceiptStyle.sybl => find.byIcon(Icons.multiple_stop_rounded),
          MessageReceiptStyle.messenger => find.byKey(
            const ValueKey('messenger-receipt-delivered'),
          ),
        };
        expect(
          receipt,
          findsOneWidget,
          reason:
              '$timestampStyle must not select or hide $receiptStyle semantics',
        );
      }
    }
  });

  testWidgets('same-author text and attachments share one timed block', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);

    // Three messages inside the five-minute block: one avatar/name header.
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _text(100, 'first'),
          _text(160, 'second'),
          _text(220, 'third'),
        ],
      ),
    );
    expect(find.byType(SyblAvatar), findsOneWidget);

    // A same-author attachment uses the same avatar/name/time block.
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'first'), _text(160, 'second')],
        files: [_file(180)],
      ),
    );
    await tester.pump();
    expect(find.byType(SyblAvatar), findsOneWidget);
    final local = DateTime.fromMillisecondsSinceEpoch(
      180 * 1000,
      isUtc: true,
    ).toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final attachmentRect = tester.getRect(
      find.byKey(const ValueKey('attachment::file-180')),
    );
    final timeRect = tester.getRect(find.text(time));
    expect(attachmentRect.overlaps(timeRect), isFalse);
    expect(
      timeRect.top < attachmentRect.bottom &&
          timeRect.bottom > attachmentRect.top,
      isTrue,
      reason:
          'the block timestamp belongs beside its last attachment: '
          'attachment=$attachmentRect time=$timeRect',
    );
    expect(timeRect.left, greaterThan(attachmentRect.right));

    // Exactly five minutes still groups; anything later starts a new block.
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'first'), _text(100 + 5 * 60, 'on the edge')],
      ),
    );
    await tester.pump();
    expect(find.byType(SyblAvatar), findsOneWidget);

    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'first'), _text(100 + 5 * 60 + 1, 'late')],
      ),
    );
    await tester.pump();
    expect(find.byType(SyblAvatar), findsNWidgets(2));

    state.appSettings = state.appSettings.withRepeatMessageAuthorAfterPause(
      false,
    );
    expect(state.repeatMessageAuthorAfterPause, isFalse);
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'first'), _text(100 + 5 * 60 + 1, 'late')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SyblAvatar), findsOneWidget);
    expect(
      find.byKey(const ValueKey('message-bubble-message-100')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('message-bubble-message-401')),
      findsOneWidget,
    );
  });

  testWidgets('group topics render the same bounded bubbles as DMs', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    const group = GroupState(
      conversationId: _conversation,
      title: 'Crew',
      memberCount: 2,
      canManageMembers: false,
      memberDisplayNames: {_peer: 'Friend'},
      memberIds: [_local, _peer],
      activeMemberIds: {_local, _peer},
      invitedMemberIds: {},
    );
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _text(100, 'topic message'),
          _outgoingText(120, 'my topic message'),
        ],
        group: group,
      ),
    );

    final incoming = find.byKey(const ValueKey('message-bubble-message-100'));
    final outgoing = find.byKey(
      const ValueKey('message-bubble-outgoing-120-my topic message'),
    );
    expect(incoming, findsOneWidget);
    expect(outgoing, findsOneWidget);
    final widget = tester.widget<Container>(incoming);
    expect(widget.decoration, isA<BoxDecoration>());
    expect(widget.padding, isNotNull);
    expect(find.text('topic message'), findsOneWidget);
    expect(
      tester.getCenter(incoming).dx,
      lessThan(tester.getCenter(outgoing).dx),
    );
    expect(
      tester.getRect(incoming).left,
      lessThan(tester.getRect(outgoing).left),
    );
  });

  testWidgets('a group attachment keeps its trailing clock beside the card', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    const group = GroupState(
      conversationId: _conversation,
      title: 'Group',
      memberCount: 2,
      canManageMembers: false,
      memberDisplayNames: {_peer: 'Friend'},
      memberIds: [_local, _peer],
      activeMemberIds: {_local, _peer},
      invitedMemberIds: {},
    );

    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(100, 'before')],
        files: [_file(180)],
        group: group,
      ),
    );

    expect(find.byType(SyblAvatar), findsOneWidget);
    final attachment = tester.getRect(
      find.byKey(const ValueKey('attachment::file-180')),
    );
    final local = DateTime.fromMillisecondsSinceEpoch(
      180 * 1000,
      isUtc: true,
    ).toLocal();
    final clock = tester.getRect(
      find.text(
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}',
      ),
    );
    expect(clock.left, greaterThan(attachment.right));
    expect(clock.top, lessThan(attachment.bottom));
    expect(clock.bottom, greaterThan(attachment.top));
  });

  testWidgets('consecutive outgoing messages extend one bubble block', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _outgoingText(100, 'one'),
          _outgoingText(120, 'two'),
          _outgoingText(140, 'three'),
        ],
      ),
    );

    expect(
      find.byKey(
        const ValueKey('message-block:outgoing-100-one:outgoing-140-three'),
      ),
      findsOneWidget,
    );
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(find.text('three'), findsOneWidget);
  });

  testWidgets('an interposed reply preserves you, them, you chronology', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _outgoingText(100, 'you first'),
          _text(120, 'their reply'),
          _outgoingText(140, 'you again'),
        ],
      ),
    );

    expect(
      find.byKey(
        const ValueKey(
          'message-block:outgoing-100-you first:outgoing-100-you first',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('message-block:message-120:message-120')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey(
          'message-block:outgoing-140-you again:outgoing-140-you again',
        ),
      ),
      findsOneWidget,
    );
    final tops = [
      tester.getTopLeft(find.text('you first')).dy,
      tester.getTopLeft(find.text('their reply')).dy,
      tester.getTopLeft(find.text('you again')).dy,
    ];
    expect(tops[0], lessThan(tops[1]));
    expect(tops[1], lessThan(tops[2]));
  });

  testWidgets('sender clock skew cannot reorder committed messages', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [
          _outgoingText(100, '1'),
          _outgoingText(101, '2'),
          _text(200, '3'),
          _text(201, '4'),
          _outgoingText(102, '5'),
          _text(202, '6'),
        ],
      ),
    );

    final tops = [
      for (final text in ['1', '2', '3', '4', '5', '6'])
        tester.getTopLeft(find.text(text)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('live receive request stays in chronology with compact actions', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    final offer = FileXfer(
      peerId: _peer,
      conversationId: _conversation,
      fileId: 'offered-file',
      interactionId: 'offered-interaction',
      name: 'photo.jpg',
      size: 200,
      outgoing: false,
      status: XferStatus.offered,
      previewBytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(300 * 1000, isUtc: true),
    );
    await tester.pumpWidget(
      _timelineApp(
        state,
        timeline: [_text(200, 'before'), _text(400, 'after')],
        live: [offer],
      ),
    );

    final positions = [
      tester.getTopLeft(find.text('before')).dy,
      tester
          .getTopLeft(find.byKey(const ValueKey('attachment::offered-file')))
          .dy,
      tester.getTopLeft(find.text('after')).dy,
    ];
    expect(positions, orderedEquals([...positions]..sort()));
    expect(
      find.byKey(const ValueKey('decline-transfer:offered-file')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('accept-transfer:offered-file')),
      findsOneWidget,
    );
    expect(find.text('Decline'), findsNothing);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Dismiss transfer status'), findsNothing);
    // Static previews decode off the UI isolate. Wait for this widget's
    // actual bounded decode, pumping the fake async zone between real events.
    final renderedPreview = find.descendant(
      of: find.byType(BoundedAttachmentPreview),
      matching: find.byType(Image),
    );
    for (
      var attempt = 0;
      attempt < 100 && renderedPreview.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(renderedPreview, findsOneWidget);
    expect(
      (tester.widget<Image>(renderedPreview).image as ResizeImage)
          .imageProvider,
      isA<MemoryImage>(),
    );
  });

  testWidgets('sender sees pending, accepted, and declined file decisions', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    final transfer = FileXfer(
      peerId: _peer,
      conversationId: _conversation,
      fileId: 'sent-file',
      interactionId: 'sent-interaction',
      name: 'notes.txt',
      size: 200,
      outgoing: true,
      authorId: _local,
      status: XferStatus.waiting,
    );

    await tester.pumpWidget(_timelineApp(state, live: [transfer]));
    expect(
      find.byKey(const ValueKey('transfer-status-pending')),
      findsOneWidget,
    );

    transfer
      ..status = XferStatus.ongoing
      ..transferred = 100;
    await tester.pumpWidget(_timelineApp(state, live: [transfer]));
    await tester.pumpAndSettle();
    // While bytes move the subtitle + progress bar carry the status; the
    // duplicate status icon is gone.
    expect(
      find.byKey(const ValueKey('transfer-status-accepted')),
      findsNothing,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(AnimatedSize), findsOneWidget);

    transfer.status = XferStatus.declined;
    await tester.pumpWidget(_timelineApp(state, live: [transfer]));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('transfer-status-declined')),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Dismiss transfer status'), findsNothing);
  });

  testWidgets('completed transfer shows check to sender and open to receiver', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    final transfer = FileXfer(
      peerId: _peer,
      conversationId: _conversation,
      fileId: 'completed-file',
      interactionId: 'completed-interaction',
      name: 'notes.txt',
      path: 'received-notes.txt',
      size: 200,
      outgoing: true,
      authorId: _local,
      status: XferStatus.finished,
    );

    await tester.pumpWidget(_timelineApp(state, live: [transfer]));
    expect(
      find.byKey(const ValueKey('transfer-status-complete')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('open-received-file:notes.txt')),
      findsNothing,
    );

    final received = FileXfer(
      peerId: _peer,
      conversationId: _conversation,
      fileId: 'completed-file',
      interactionId: 'completed-interaction',
      name: 'notes.txt',
      path: 'received-notes.txt',
      size: 200,
      outgoing: false,
      authorId: _peer,
      status: XferStatus.finished,
    );
    await tester.pumpWidget(_timelineApp(state, live: [received]));
    expect(
      find.byKey(const ValueKey('transfer-status-complete')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('open-received-file:notes.txt')),
      findsOneWidget,
    );
  });

  testWidgets('composer exposes Enter as its send action', (tester) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(composer.textInputAction, TextInputAction.send);
    expect(composer.onSubmitted, isNotNull);
  });

  testWidgets(
    'typing indicator is fixed above the composer and animates without scrolling',
    (tester) async {
      final state = await _composerTimelineState();
      addTearDown(state.dispose);
      state.items = [for (var i = 1; i <= 40; i++) _text(i, 'message $i')];
      await tester.pumpWidget(
        _chatStageApp(state, conversationId: _conversation),
      );
      final position = _scrollable(tester).position..jumpTo(240);
      await tester.pump();
      final before = position.pixels;

      state.activity = ComposerActivityKind.typing;
      await tester.pumpWidget(
        _chatStageApp(state, conversationId: _conversation),
      );

      final label = find.text('Friend is typing…');
      expect(label, findsOneWidget);
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: label, matching: find.byType(FadeTransition)).first,
      );
      final slide = tester.widget<SlideTransition>(
        find.ancestor(of: label, matching: find.byType(SlideTransition)).first,
      );
      expect(fade.opacity.value, 0);
      expect(slide.position.value.dy, greaterThan(0));

      await tester.pump(const Duration(milliseconds: 90));
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      expect(slide.position.value.dy, inExclusiveRange(0, .35));
      await tester.pump(const Duration(milliseconds: 90));
      expect(fade.opacity.value, 1);
      expect(slide.position.value, Offset.zero);
      // The indicator lines up with the text field's left edge, not the
      // pane edge (pane padding + 48 px attach button + gap).
      expect(
        tester.getTopLeft(label).dx,
        closeTo(
          tester.getTopLeft(find.byKey(const ValueKey('chat-composer'))).dx,
          1,
        ),
      );
      expect(
        tester.getBottomRight(label).dy,
        lessThanOrEqualTo(
          tester
              .getTopLeft(find.byKey(const ValueKey('conversation-composer')))
              .dy,
        ),
      );
      expect(state.items, hasLength(40));
      expect(position.pixels, closeTo(before, .01));

      state.activity = null;
      await tester.pumpWidget(
        _chatStageApp(state, conversationId: _conversation),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester
            .widget<FadeTransition>(
              find
                  .ancestor(of: label, matching: find.byType(FadeTransition))
                  .first,
            )
            .opacity
            .value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      expect(label, findsNothing);
      expect(position.pixels, closeTo(before, .01));
    },
  );

  testWidgets('reduced motion removes indicator translation', (tester) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _chatStageApp(
        state,
        conversationId: _conversation,
        disableAnimations: true,
      ),
    );

    state.activity = ComposerActivityKind.typing;
    await tester.pumpWidget(
      _chatStageApp(
        state,
        conversationId: _conversation,
        disableAnimations: true,
      ),
    );
    final label = find.text('Friend is typing…');
    expect(label, findsOneWidget);
    expect(
      tester
          .widgetList<SlideTransition>(
            find.ancestor(of: label, matching: find.byType(SlideTransition)),
          )
          .map((transition) => transition.position.value.dy),
      everyElement(0),
    );
  });

  testWidgets('composer focus loss sends idle', (tester) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-composer')),
      'draft',
    );
    expect(state.localActivity, contains(ComposerActivityKind.typing));

    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pump();
    expect(state.localActivity.last, ComposerActivityKind.idle);
  });

  testWidgets('composer pause sends idle while preserving the draft', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );

    final composer = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(composer, 'draft');
    expect(state.localActivity.last, ComposerActivityKind.typing);

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.enterText(composer, 'draft continues');
    await tester.pump(const Duration(milliseconds: 1499));
    expect(state.localActivity.last, ComposerActivityKind.typing);
    await tester.pump(const Duration(milliseconds: 1));

    expect(state.localActivity.last, ComposerActivityKind.idle);
    expect(find.text('draft continues'), findsOneWidget);
  });

  testWidgets('a draft is retired when its exact conversation owner changes', (
    tester,
  ) async {
    final state = await _composerTimelineState()
      ..fixtureConversation = 'conversation-one';
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: 'conversation-one'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer')),
      'private draft for the old conversation',
    );
    expect(find.text('private draft for the old conversation'), findsOneWidget);

    state.fixtureConversation = 'conversation-two';
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: 'conversation-two'),
    );
    await tester.pump();

    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(composer.controller?.text, isEmpty);
  });

  testWidgets('a draft cannot cross an account identity replacement', (
    tester,
  ) async {
    final state = await _composerTimelineState()
      ..accountId = 'account-one';
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer')),
      'private draft for account one',
    );

    state.accountId = 'account-two';
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    await tester.pump();

    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(composer.controller?.text, isEmpty);
  });

  testWidgets('a sent message rises and fades into its place, never from the '
      'composer', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.items = [_text(100, 'hello')];
    const body = 'sent text';
    final mine = _outgoingText(200, body);
    await tester.pumpWidget(
      _flightApp(
        state,
        onSend: (_) async {
          state.items = [...state.items, mine];
          state.notifyListeners();
          return true;
        },
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('chat-composer')), body);
    await tester.pump();
    final composer = find.byKey(const ValueKey('chat-composer'));
    final composerTop = tester.getRect(composer).top;
    final older = find.byKey(const ValueKey('message-bubble-message-100'));
    final olderTop = tester.getRect(older).top;
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    final bubble = find.byKey(
      ValueKey('message-bubble-${mine.daemonId}'),
      skipOffstage: false,
    );
    final motion = find.byKey(
      ValueKey('chat-entry-motion:${mine.daemonId}'),
      skipOffstage: false,
    );
    expect(motion, findsOneWidget);
    final rising = <({Rect rect, double opacity})>[];
    final olderTops = <double>[];
    final counts = <int>[];
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      olderTops.add(tester.getRect(older).top);
      if (motion.evaluate().isNotEmpty) {
        rising.add((
          rect: tester.getRect(bubble),
          opacity: tester
              .widget<Opacity>(
                find
                    .descendant(of: motion, matching: find.byType(Opacity))
                    .first,
              )
              .opacity,
        ));
      }
      final seen = _sightings(tester, mine.daemonId, body);
      counts.add([seen.composer, seen.bubble != null].where((v) => v).length);
    }
    expect(counts.every((count) => count == 1), isTrue, reason: '$counts');
    await tester.pumpAndSettle();
    final home = tester.getRect(bubble);
    expect(rising, isNotEmpty);
    expect(rising.first.rect.top, greaterThan(home.top + 1));
    expect(rising.first.opacity, inExclusiveRange(0, 1));
    for (var i = 0; i < rising.length; i++) {
      final frame = rising[i];
      expect(frame.rect.left, closeTo(home.left, .5));
      expect(frame.rect.right, closeTo(home.right, .5));
      expect(frame.rect.top, inInclusiveRange(home.top - .5, home.top + 14.5));
      expect(frame.rect.top, lessThan(composerTop));
      if (i == 0) continue;
      expect(frame.rect.top, lessThanOrEqualTo(rising[i - 1].rect.top + 1e-6));
      expect(frame.opacity, greaterThanOrEqualTo(rising[i - 1].opacity));
    }
    _expectGlide(olderTops, olderTop, 'older message');
    expect(find.text(body), findsOneWidget);
  });

  testWidgets('reduced motion sends and receives without entry motion', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.items = [_text(100, 'hello')];
    const body = 'still text';
    final mine = _outgoingText(200, body);
    await tester.pumpWidget(
      _flightApp(
        state,
        disableAnimations: true,
        onSend: (_) async {
          state.items = [...state.items, mine];
          state.notifyListeners();
          return true;
        },
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('chat-composer')), body);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    final seen = _sightings(tester, mine.daemonId, body);
    expect(seen.bubble, isNotNull);
    expect(seen.composer, isFalse);

    state.items = [...state.items, _text(300, 'theirs')];
    state.notifyListeners();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('chat-entry-motion:message-300')),
      findsNothing,
    );
    expect(find.text('theirs'), findsOneWidget);
  });

  testWidgets('a received message rises and fades in, then streams', (
    tester,
  ) async {
    final state = await _composerTimelineState();
    addTearDown(state.dispose);
    state.items = [_outgoingText(100, 'mine')];
    await tester.pumpWidget(_flightApp(state, onSend: (_) async => true));
    final older = find.byKey(
      const ValueKey('message-bubble-outgoing-100-mine'),
    );
    final olderTop = tester.getRect(older).top;
    state.items = [...state.items, _text(200, 'theirs, at length')];
    state.notifyListeners();
    await tester.pump();
    // Its slot starts empty, so look past the viewport's onstage check.
    final motion = find.byKey(
      const ValueKey('chat-entry-motion:message-200'),
      skipOffstage: false,
    );
    expect(motion, findsOneWidget);
    final bubble = find.byKey(
      const ValueKey('message-bubble-message-200'),
      skipOffstage: false,
    );
    final rising = <({double top, double opacity, String shown})>[];
    final olderTops = <double>[];
    // The rise and glide take 220 ms; the text waits for them.
    for (var frame = 0; frame < 13; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      olderTops.add(tester.getRect(older).top);
      rising.add((
        top: tester.getRect(bubble).top,
        opacity: tester
            .widget<Opacity>(
              find.descendant(of: motion, matching: find.byType(Opacity)).first,
            )
            .opacity,
        shown: _streamed(tester, 'message-200'),
      ));
    }
    await tester.pump(const Duration(milliseconds: 40));
    final settled = tester.getRect(bubble).top;
    expect(rising.first.top, greaterThan(settled + 5));
    for (var i = 1; i < rising.length; i++) {
      expect(rising[i].top, lessThanOrEqualTo(rising[i - 1].top + 1e-6));
      expect(rising[i].opacity, greaterThanOrEqualTo(rising[i - 1].opacity));
    }
    expect(rising.first.opacity, inExclusiveRange(0, 1));
    expect(rising.every((frame) => frame.shown.isEmpty), isTrue);
    _expectGlide(olderTops, olderTop, 'older message');
    // Then the text streams in letter by letter.
    await tester.pump(const Duration(milliseconds: 100));
    final partial = _streamed(tester, 'message-200');
    expect(partial, isNotEmpty);
    expect(partial, isNot('theirs, at length'));
    expect('theirs, at length'.startsWith(partial), isTrue);
    await tester.pumpAndSettle();
    expect(motion, findsNothing);
    expect(find.text('theirs, at length'), findsOneWidget);
  });

  testWidgets('history, older pages and conversation switches do not animate', (
    tester,
  ) async {
    final state = await _loadingTimelineState();
    addTearDown(state.dispose);
    state.loading = true;
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    state.items = [_text(100, 'loaded'), _text(200, 'history')];
    state.loading = false;
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    expect(find.text('history'), findsOneWidget);
    for (final id in ['message-100', 'message-200']) {
      expect(find.byKey(ValueKey('chat-entry-motion:$id')), findsNothing);
    }

    state.items = [_text(50, 'older page'), ...state.items];
    await tester.pumpWidget(
      _chatStageApp(state, conversationId: _conversation),
    );
    expect(
      find.byKey(const ValueKey('chat-entry-motion:message-50')),
      findsNothing,
    );

    state.items = [_text(300, 'elsewhere')];
    await tester.pumpWidget(_chatStageApp(state, conversationId: 'other'));
    expect(find.text('elsewhere'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-entry-motion:message-300')),
      findsNothing,
    );

    state.items = [...state.items, _text(400, 'news')];
    await tester.pumpWidget(_chatStageApp(state, conversationId: 'other'));
    expect(
      find.byKey(const ValueKey('chat-entry-motion:message-400')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });
}
