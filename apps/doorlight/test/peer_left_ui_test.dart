import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/dm_topics.dart';
import 'package:sybl/state/nearby.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/add_friend_pane.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/friend_rail.dart';
import 'package:sybl/ui/sybl_ui.dart';

const _local = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peer = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _sent = 'cccccccccccccccccccccccccccccccccccccccc';
const _incoming = 'dddddddddddddddddddddddddddddddddddddddd';
const _stranger = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _conversation = 'conversation';
final _scope = ConversationScope(
  accountId: 'account',
  peerId: _peer,
  conversationId: _conversation,
);
const _friend = FriendState(
  peerId: _peer,
  confirmed: true,
  conversationId: _conversation,
  displayName: 'Mara',
);

final class _LeftState extends AppState {
  _LeftState(super.jami, super.prefs);

  Set<String> left = {_peer};
  Map<String, FriendState> known = const {_peer: _friend};
  final actions = <String>[];
  ({String convId, String fromJamiId, bool isGroup})? incoming;

  @override
  Map<String, FriendState> get friends => known;
  @override
  Iterable<FriendState> get visibleFriends => known.values;
  @override
  bool peerLeft(String peerId) => left.contains(peerId);
  @override
  FriendState? get selectedFriend => _friend;
  @override
  ConversationScope? get selectedConversationScope => _scope;
  @override
  List<ConversationTimelineItem> get selectedDmTopicItems => [
    TimelineTextItem(
      scope: _scope,
      daemonId: 'hello',
      versionId: 'hello',
      authorId: _peer,
      direction: TimelineDirection.incoming,
      createdAt: DateTime.utc(2026),
      text: 'hello there',
    ),
    TimelineDmTopicEventItem(
      scope: _scope,
      daemonId: 'left',
      versionId: 'left',
      authorId: _peer,
      direction: TimelineDirection.incoming,
      createdAt: DateTime.utc(2026, 1, 2),
      linearizedParent: '',
      eventBody: DmTopicEventCodec.encode(const DmTopicEvent.left()),
    ),
  ];

  @override
  Future<FriendRemovalResult> archiveLeftChat(String p) async {
    actions.add('archive:$p');
    return (peerId: p, status: FriendRemovalStatus.removed, warning: null);
  }

  @override
  Future<FriendRemovalResult> deleteLeftChat(String p) async {
    actions.add('delete:$p');
    return (peerId: p, status: FriendRemovalStatus.removed, warning: null);
  }

  @override
  ({String convId, String fromJamiId, bool isGroup})? incomingRequestFrom(
    String peerId,
  ) => incoming?.fromJamiId == peerId ? incoming : null;

  @override
  Future<void> allowConnectFrom(String convId) async =>
      actions.add('accept:$convId');
}

Future<_LeftState> _state() async {
  SharedPreferences.setMockInitialValues({});
  return _LeftState(_Jami(), await SharedPreferences.getInstance())
    ..jamiId = _local
    ..accountId = 'account'
    ..screen = Screen.home
    ..registration = 'REGISTERED'
    ..seedCaptureStateForTesting(
      resolved: true,
      applied: WindowCaptureProtectionStatus.exclude,
    );
}

class _Jami extends JamiClient {
  @override
  Future<void> setAppearOffline(bool on, {String? expectedAccountId}) async {}

  @override
  Future<void> setPresenceSubscriptions(Iterable<String> peerJamiIds) async {}
}

class _Transport implements NearbyTransport {
  StreamController<NearbyDatagram>? incoming;

  @override
  Future<Stream<NearbyDatagram>> start() async {
    incoming = StreamController<NearbyDatagram>();
    return incoming!.stream;
  }

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> stop() async {
    unawaited(incoming?.close());
    incoming = null;
  }

  void announce(String id, String name) => incoming!.add((
    data: NearbyProtocol.encodeAnnouncement(id, name)!,
    sender: InternetAddress.loopbackIPv4,
  ));
}

void main() {
  testWidgets('a removed-you chat shows the line and replaces the composer', (
    tester,
  ) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: ChatStage(state: state, friend: _friend),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Mara removed you'), findsOneWidget);
    expect(find.text("You can't send messages here anymore."), findsOneWidget);
    expect(find.byType(ConversationComposer), findsNothing);
    expect(find.text('Archive chat'), findsOneWidget);
    expect(find.text('Delete chat'), findsOneWidget);
    for (final key in ['voice-call-button', 'video-call-button']) {
      expect(
        tester.widget<SyblPillIconButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
        reason: key,
      );
    }

    await tester.tap(find.byKey(const ValueKey('peer-left-delete')));
    await tester.pump();
    expect(state.actions, ['delete:$_peer']);
  });

  testWidgets('an active chat keeps its composer', (tester) async {
    final state = await _state()
      ..left = {};
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: ChatStage(state: state, friend: _friend),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ConversationComposer), findsOneWidget);
    expect(find.byKey(const ValueKey('peer-left-actions')), findsNothing);
    expect(
      tester
          .widget<SyblPillIconButton>(
            find.byKey(const ValueKey('voice-call-button')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('the rail row offers Archive, Delete or Cancel', (tester) async {
    final state = await _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: FriendRail(
            state: state,
            onOpenFriend: (_) {},
            onOpenGroup: (_) {},
            onAddFriend: () {},
            onCreateGroup: () {},
            onInviteFriend: () {},
            onOpenSettings: () {},
          ),
        ),
      ),
    );
    expect(find.text('removed you'), findsOneWidget);
    final close = find.byKey(const ValueKey('friend-left-remove-$_peer'));

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('Remove Mara?'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.actions, isEmpty);

    await tester.tap(close);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('left-chat-archive')));
    await tester.pumpAndSettle();
    expect(state.actions, ['archive:$_peer']);

    await tester.tap(close);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('left-chat-delete')));
    await tester.pumpAndSettle();
    expect(state.actions, ['archive:$_peer', 'delete:$_peer']);
  });

  testWidgets('Nearby shows Friends, Request sent, Accept and Add', (
    tester,
  ) async {
    late _LeftState state;
    final transport = _Transport();
    await tester.runAsync(() async {
      state = await _state()
        ..left = {}
        ..known = const {
          _peer: _friend,
          _sent: FriendState(
            peerId: _sent,
            confirmed: false,
            conversationId: 'conv-sent',
          ),
        }
        ..incoming = (
          convId: 'conv-in',
          fromJamiId: _incoming,
          isGroup: false,
        );
      state.attachNearby(transport);
      await pumpEventQueue();
    });
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: AddFriendPane(
            state: state,
            onClose: () {},
            isCurrent: () => true,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      transport
        ..announce(_peer, 'Mara')
        ..announce(_sent, 'Sam')
        ..announce(_incoming, 'Ines')
        ..announce(_stranger, 'Noor');
      await pumpEventQueue();
    });
    await tester.tap(find.byKey(const ValueKey('connection-nearby')));
    await tester.pumpAndSettle();

    Text label(String id) =>
        tester.widget<Text>(find.byKey(ValueKey('nearby-state-$id')));
    expect(label(_peer).data, 'Friends');
    expect(label(_sent).data, 'Request sent');
    expect(find.byKey(const ValueKey('nearby-accept-$_incoming')), findsOne);
    expect(find.byKey(const ValueKey('nearby-add-$_stranger')), findsOne);
    expect(find.byKey(const ValueKey('nearby-add-$_incoming')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nearby-accept-$_incoming')));
    await tester.pump();
    expect(state.actions, ['accept:conv-in']);

    // A friend who removed you is offered Add again.
    state
      ..left = {_peer}
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nearby-add-$_peer')), findsOne);
  });
}
