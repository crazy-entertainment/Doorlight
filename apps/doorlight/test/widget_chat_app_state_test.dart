import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_draft.dart';

import 'app_state_test.dart' as fixture;

class _WidgetJami extends fixture.FakeJami {
  bool holdNextChatLoad = false;
  Completer<void>? heldLoadStarted;
  int? heldLoadId;
  String? heldPeer;
  String? heldConversation;
  String? heldCursor;
  List<Map<String, Object?>> olderItems = const [];
  bool holdSend = false;
  final sendStarted = Completer<void>();
  final sendResult = Completer<String>();
  int ownedSendCalls = 0;
  String? lastOwnedBody;
  bool commitOwnedSends = false;

  @override
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
  }) async {
    if (holdNextChatLoad) {
      holdNextChatLoad = false;
      final id = nextChatLoadId++;
      calls.add(
        'loadChat:$peerJamiId:$conversationId:$fromMessage:$pageSize:$id',
      );
      heldLoadId = id;
      heldPeer = peerJamiId;
      heldConversation = conversationId;
      heldCursor = fromMessage;
      heldLoadStarted?.complete();
      return id;
    }
    final id = nextChatLoadId++;
    calls.add(
      'loadChat:$peerJamiId:$conversationId:$fromMessage:$pageSize:$id',
    );
    final items = fromMessage.isEmpty
        ? chatHistory[conversationId] ?? const <Object?>[]
        : olderItems;
    final hasMore = fromMessage.isEmpty && items.length >= pageSize;
    push('chatSnapshot', {
      'accountId': accountId,
      'peerJamiId': peerJamiId,
      'conversationId': conversationId,
      'loadId': id,
      'requestedCursor': fromMessage,
      'nextCursor': hasMore ? 'older-cursor' : '',
      'hasMore': hasMore,
      'items': items,
    });
    return id;
  }

  void completeHeldLoad() {
    final id = heldLoadId!;
    push('chatSnapshot', {
      'accountId': accountId,
      'peerJamiId': heldPeer,
      'conversationId': heldConversation,
      'loadId': id,
      'requestedCursor': heldCursor,
      'nextCursor': '',
      'hasMore': false,
      'items': const <Object?>[],
    });
  }

  @override
  Future<String> sendOwnedMessage({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
    required String mimeType,
    required String body,
    required String operationId,
    String replyTo = '',
    String topicId = '',
    String roomId = '',
  }) async {
    ownedSendCalls++;
    lastOwnedBody = body;
    if (commitOwnedSends) {
      push('sendOperationCompleted', {
        'accountId': accountId,
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'operationId': operationId,
        'status': 'committed',
        'commitId': 'commit-$operationId',
      });
      return 'pending';
    }
    if (holdSend) {
      if (!sendStarted.isCompleted) sendStarted.complete();
      return sendResult.future;
    }
    return 'unknown';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _WidgetJami jami;
  late AppState state;

  Future<void> boot({bool consent = true, bool twoFriends = false}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final preferences = <String, Object>{
      'accountId': 'acc1',
      'displayName': 'Me',
      if (consent) 'widgetChatCaptureConsent.v1': true,
    };
    SharedPreferences.setMockInitialValues(preferences);
    jami = _WidgetJami()..accountRegistration = 'REGISTERED';
    jami.daemonFriends[fixture.peer] = JamiFriend(
      peerJamiId: fixture.peer,
      confirmed: true,
      conversationId: fixture.peerConversation,
      displayName: 'First friend',
    );
    jami.chatHistory[fixture.peerConversation] = List.generate(
      50,
      (index) => {
        'accountId': 'acc1',
        'peerId': fixture.peer,
        'conversationId': fixture.peerConversation,
        'daemonId': 'message-$index',
        'versionId': 'message-$index',
        'mimeType': 'text/plain',
        'authorId': fixture.peer,
        'timestampSeconds': 1700000000 + index,
        'body': 'sample message $index',
        'topicId': 'main',
        'topicTagged': false,
      },
    );
    if (twoFriends) {
      jami.daemonFriends[fixture.otherFriend] = JamiFriend(
        peerJamiId: fixture.otherFriend,
        confirmed: true,
        conversationId: 'conv-other',
        displayName: 'Second friend',
      );
    }
    state = AppState(jami, await SharedPreferences.getInstance());
    await state.init();
    await state.selectFriend(fixture.peer);
  }

  tearDown(() {
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Map<String, dynamic> chatSnapshot() =>
      Map<String, dynamic>.from(state.widgetOverlaySnapshot['chat']! as Map);

  Map<String, dynamic> voiceSnapshot() =>
      Map<String, dynamic>.from(state.widgetOverlaySnapshot['voice']! as Map);

  for (final consent in [false, true]) {
    test(
      'widget status prioritizes disconnect and lock with consent=$consent',
      () async {
        await boot(consent: consent);
        state.setProtectedSurfaceLocked(true);
        state.screen = Screen.loading;
        expect(chatSnapshot()['status'], 'disconnected');
        state.screen = Screen.home;
        expect(chatSnapshot()['status'], 'locked');
        state.setProtectedSurfaceLocked(false);
        expect(chatSnapshot()['status'], consent ? 'ready' : 'consent');
      },
    );
  }

  test(
    'consent request can be queued in background but granted only in foreground',
    () async {
      await boot(consent: false);
      final requested = await state.handleWidgetOverlayCommand(
        'chat.enable',
        const {},
      );
      expect(requested['pendingConsent'], isTrue);
      final request = state.widgetChatConsentRequest;
      expect(request, isNotNull);

      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(state.widgetChatConsentRequest, isNull);
      expect(await state.grantWidgetChatConsent(request!), isFalse);
      expect(chatSnapshot()['status'], 'consent');

      final queued = await state.handleWidgetOverlayCommand(
        'chat.enable',
        const {},
      );
      expect(queued['pendingConsent'], isTrue);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final foregroundRequest = state.widgetChatConsentRequest;
      expect(foregroundRequest, isNotNull);
      expect(await state.grantWidgetChatConsent(foregroundRequest!), isTrue);
      expect(chatSnapshot()['status'], 'ready');
    },
  );

  test(
    'Windows capture-off skips explanation only after chat.enable and revoke sticks',
    () async {
      await boot(consent: false);
      state.appSettings = state.appSettings.withWindowsCaptureProtectionEnabled(
        false,
      );

      expect(chatSnapshot()['status'], 'consent');
      final enabled = await state.handleWidgetOverlayCommand(
        'chat.enable',
        const {},
      );
      expect(enabled['pendingConsent'], isFalse);
      expect(state.widgetChatConsentRequest, isNull);
      expect(chatSnapshot()['status'], 'ready');
      expect(state.prefs.getBool('widgetChatCaptureConsent.v1'), isTrue);

      expect(await state.revokeWidgetChatConsent(), isTrue);
      expect(chatSnapshot()['status'], 'consent');
      expect(state.widgetChatConsentRequest, isNull);
      expect(
        (await state.handleWidgetOverlayCommand(
          'chat.enable',
          const {},
        ))['pendingConsent'],
        isFalse,
      );
      expect(chatSnapshot()['status'], 'ready');
    },
  );

  test('Doorlight reset refuses an in-flight overlay document write', () async {
    await boot();
    state.overlaySettings.busy = true;

    expect(await state.resetDoorlight(), isFalse);
    expect(state.resettingDoorlight, isFalse);
    expect(state.resetDoorlightPending, isFalse);
    expect(jami.calls, isNot(contains('resetDoorlight')));
  });

  test(
    'widget selection stays scoped and lock or disconnect invalidates its token',
    () async {
      await boot(twoFriends: true);
      final initial = chatSnapshot();
      final choices = (initial['conversations'] as List).cast<Map>();
      final second = choices.singleWhere(
        (item) => item['label'] == 'Second friend',
      );
      final token = second['id'] as String;

      await state.handleWidgetOverlayCommand('chat.select', {
        'token': token,
        'conversation': token,
      });
      expect(state.peerId, fixture.peer);
      expect(chatSnapshot()['selected'], token);

      state.setProtectedSurfaceLocked(true);
      expect(chatSnapshot()['status'], 'locked');
      expect(chatSnapshot()['messages'], isEmpty);
      await expectLater(
        state.handleWidgetOverlayCommand('chat.select', {
          'token': token,
          'conversation': token,
        }),
        throwsA(isA<StateError>()),
      );

      state.setProtectedSurfaceLocked(false);
      state.retireWidgetOverlaySession();
      await expectLater(
        state.handleWidgetOverlayCommand('chat.select', {
          'token': token,
          'conversation': token,
        }),
        throwsA(isA<StateError>()),
      );
      expect(chatSnapshot()['messages'], isEmpty);
    },
  );

  test(
    'visible widget timeline receives scoped live edits, status, refreshes and privacy drops',
    () async {
      await boot(twoFriends: true);
      final appPeerBefore = state.peerId;
      final appMessageIdsBefore = state.conversationItems
          .map((item) => item.daemonId)
          .toList();
      final second = (chatSnapshot()['conversations'] as List)
          .cast<Map>()
          .singleWhere((item) => item['label'] == 'Second friend');
      final token = second['id'] as String;
      final liveId = 'a' * 40;
      await state.handleWidgetOverlayCommand('chat.select', {
        'token': token,
        'conversation': token,
      });
      expect(state.peerId, appPeerBefore);

      Map<String, Object?> wire({
        required String id,
        required String author,
        required String text,
        String? version,
        String? operation,
        bool deleted = false,
      }) => {
        'accountId': 'acc1',
        'peerId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'daemonId': id,
        'versionId': version ?? id,
        'mimeType': 'text/plain',
        'authorId': author,
        'timestampSeconds': 1700000000,
        'body': text,
        'operation': ?operation,
        if (deleted) 'deleted': true,
        'topicId': 'main',
        'topicTagged': false,
      };

      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'item': wire(id: liveId, author: fixture.otherFriend, text: 'live'),
      });
      await pumpEventQueue();
      var messages = (chatSnapshot()['messages'] as List).cast<Map>();
      expect(messages.any((item) => item['id'] == liveId), isTrue);
      expect(state.peerId, appPeerBefore);
      expect(
        state.conversationItems.map((item) => item.daemonId),
        appMessageIdsBefore,
      );

      var reactionNotifications = 0;
      void onReactionProjectionChanged() => reactionNotifications++;
      state.addListener(onReactionProjectionChanged);
      jami.push('chatReaction', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'item': {
          'accountId': 'acc1',
          'peerId': fixture.otherFriend,
          'conversationId': 'conv-other',
          'messageId': liveId,
          'reaction': {
            'commitId': 'd' * 40,
            'authorId': fixture.otherFriend,
            'emoji': '👍',
          },
        },
      });
      await pumpEventQueue();
      state.removeListener(onReactionProjectionChanged);
      expect(reactionNotifications, greaterThan(0));

      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'item': wire(
          id: liveId,
          version: 'b' * 40,
          author: fixture.otherFriend,
          text: 'edited live',
          operation: 'edit',
        ),
      });
      await pumpEventQueue();
      messages = (chatSnapshot()['messages'] as List).cast<Map>();
      expect(
        messages.singleWhere((item) => item['id'] == liveId)['text'],
        'edited live',
      );

      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'item': wire(
          id: liveId,
          version: 'c' * 40,
          author: fixture.otherFriend,
          text: '',
          deleted: true,
        ),
      });
      await pumpEventQueue();
      expect(
        (chatSnapshot()['messages'] as List).cast<Map>().any(
          (item) => item['id'] == liveId,
        ),
        isFalse,
      );

      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'item': wire(
          id: 'widget-owned',
          author: jami.accountJamiId,
          text: 'owned',
        ),
      });
      await pumpEventQueue();
      jami.push('messageStatus', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'messageId': 'widget-owned',
        'state': 3,
      });
      await pumpEventQueue();
      expect(
        (chatSnapshot()['messages'] as List).cast<Map>().singleWhere(
          (item) => item['id'] == 'widget-owned',
        )['status'],
        'read',
      );

      final beforeRefresh = jami.calls
          .where(
            (entry) =>
                entry.startsWith('loadChat:') && entry.contains(':conv-other:'),
          )
          .length;
      jami.push('chatRefreshRequired', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
      });
      await pumpEventQueue(times: 5);
      expect(
        jami.calls
            .where(
              (entry) =>
                  entry.startsWith('loadChat:') &&
                  entry.contains(':conv-other:'),
            )
            .length,
        beforeRefresh + 1,
      );

      final beforeSyncApp = jami.calls
          .where(
            (entry) =>
                entry.startsWith('loadChat:') && entry.contains(':conv-other:'),
          )
          .length;
      jami.push('conversationSyncFinished', const {});
      await pumpEventQueue(times: 5);
      expect(
        jami.calls
            .where(
              (entry) =>
                  entry.startsWith('loadChat:') &&
                  entry.contains(':conv-other:'),
            )
            .length,
        beforeSyncApp + 1,
      );

      state.setProtectedSurfaceLocked(true);
      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': fixture.otherFriend,
        'conversationId': 'conv-other',
        'item': wire(
          id: 'widget-after-lock',
          author: fixture.otherFriend,
          text: 'must stay hidden',
        ),
      });
      expect(chatSnapshot()['status'], 'locked');
      expect(chatSnapshot()['messages'], isEmpty);
      state.setProtectedSurfaceLocked(false);
      expect(chatSnapshot()['status'], 'ready');
      expect(chatSnapshot()['selected'], isNull);
      expect(chatSnapshot()['messages'], isEmpty);
      expect(state.peerId, appPeerBefore);
    },
  );

  test('delayed history is rejected after the account owner changes', () async {
    await boot();
    final chat = chatSnapshot();
    final token =
        ((chat['conversations'] as List).single as Map)['id'] as String;
    await state.handleWidgetOverlayCommand('chat.select', {
      'token': token,
      'conversation': token,
    });

    jami
      ..holdNextChatLoad = true
      ..heldLoadStarted = Completer<void>();
    final loading = state.handleWidgetOverlayCommand('chat.history', {
      'token': token,
      'conversation': token,
    });
    await jami.heldLoadStarted!.future;
    state.accountId = 'acc2';
    jami.completeHeldLoad();

    await expectLater(loading, throwsA(isA<StateError>()));
    expect(chatSnapshot()['messages'], isEmpty);
    expect(
      jami.calls.where((entry) => entry.startsWith('loadChat:')).length,
      3,
    );
  });

  test(
    'older history window moves back and chat.latest restores the live tail',
    () async {
      await boot();
      final token =
          ((chatSnapshot()['conversations'] as List).single as Map)['id']
              as String;
      await state.handleWidgetOverlayCommand('chat.select', {
        'token': token,
        'conversation': token,
      });
      final initial = (chatSnapshot()['messages'] as List).cast<Map>();
      expect(initial, hasLength(48));
      expect(initial.first['id'], 'message-47');
      expect(initial.last['id'], 'message-0');

      jami.olderItems = List.generate(
        50,
        (index) => {
          'accountId': 'acc1',
          'peerId': fixture.peer,
          'conversationId': fixture.peerConversation,
          'daemonId': 'older-$index',
          'versionId': 'older-$index',
          'mimeType': 'text/plain',
          'authorId': fixture.peer,
          'timestampSeconds': 1699999900 + index,
          'body': 'older message $index',
          'topicId': 'main',
          'topicTagged': false,
        },
      );
      await state.handleWidgetOverlayCommand('chat.history', {
        'token': token,
        'conversation': token,
      });
      final older = (chatSnapshot()['messages'] as List).cast<Map>();
      expect(older, hasLength(48));
      expect(older.first['id'], 'older-45');
      expect(older.last['id'], 'message-48');
      expect(chatSnapshot()['hasOlder'], isTrue);

      await state.handleWidgetOverlayCommand('chat.latest', {
        'token': token,
        'conversation': token,
      });
      final latest = (chatSnapshot()['messages'] as List).cast<Map>();
      expect(latest.first['id'], 'message-47');
      expect(latest.last['id'], 'message-0');
    },
  );

  test(
    'unknown send does not echo or retry, and old selection cannot send',
    () async {
      await boot();
      final token =
          ((chatSnapshot()['conversations'] as List).single as Map)['id']
              as String;
      await state.handleWidgetOverlayCommand('chat.select', {
        'token': token,
        'conversation': token,
      });
      final before = (chatSnapshot()['messages'] as List).length;

      final result = await state.handleWidgetOverlayCommand('chat.send', {
        'token': token,
        'conversation': token,
        'text': 'No optimistic echo',
        'operationId': 'a' * 32,
      });
      expect(result['status'], ComposerSendStatus.pending.name);
      expect(result['ok'], isTrue);
      await pumpEventQueue();
      expect(
        (chatSnapshot()['submission'] as Map)['status'],
        ComposerSendStatus.unknown.name,
      );
      expect((chatSnapshot()['messages'] as List).length, before);
      expect(jami.ownedSendCalls, 1);
      expect(jami.lastOwnedBody, 'No optimistic echo');
      expect(
        state.sendJournal.record('a' * 32)?.status,
        ComposerSendStatus.unknown,
      );

      state.retireWidgetOverlaySession();
      await expectLater(
        state.handleWidgetOverlayCommand('chat.send', {
          'token': token,
          'conversation': token,
          'text': 'Must not dispatch',
        }),
        throwsA(isA<StateError>()),
      );
      expect(jami.ownedSendCalls, 1);
    },
  );

  test(
    'committed widget sends release journal capacity beyond its limit',
    () async {
      await boot();
      jami.commitOwnedSends = true;
      final token =
          ((chatSnapshot()['conversations'] as List).single as Map)['id']
              as String;
      await state.handleWidgetOverlayCommand('chat.select', {
        'token': token,
        'conversation': token,
      });
      for (var index = 0; index < 130; index++) {
        final operation = index.toRadixString(16).padLeft(32, '0');
        final admitted = await state.handleWidgetOverlayCommand('chat.send', {
          'token': token,
          'conversation': token,
          'text': 'message $index',
          'operationId': operation,
        });
        expect(admitted['status'], 'pending');
        await pumpEventQueue();
        expect(state.sendingChatMessage, isFalse);
        expect((chatSnapshot()['submission'] as Map)['status'], 'committed');
        expect(state.sendJournal.record(operation), isNull);
      }
      expect(jami.ownedSendCalls, 130);
    },
  );

  test(
    'slow send admission and receipt survive fresh connection tokens without replay',
    () async {
      await boot();
      jami.holdSend = true;
      final first = ((chatSnapshot()['conversations'] as List).single as Map);
      final token = first['id'] as String;
      final draftKey = first['draftKey'];
      await state.handleWidgetOverlayCommand('chat.select', {
        'token': token,
        'conversation': token,
      });
      final admitted = await state.handleWidgetOverlayCommand('chat.send', {
        'token': token,
        'conversation': token,
        'text': 'Waiting for commit',
        'operationId': 'b' * 32,
      });
      expect(admitted['status'], 'pending');
      expect(jami.sendResult.isCompleted, isFalse);
      state.retireWidgetOverlaySession();
      final next = ((chatSnapshot()['conversations'] as List).single as Map);
      expect(next['id'], isNot(token));
      expect(next['draftKey'], draftKey);
      final freshToken = next['id'] as String;
      await state.handleWidgetOverlayCommand('chat.select', {
        'token': freshToken,
        'conversation': freshToken,
      });
      expect(chatSnapshot()['draftKey'], draftKey);
      expect((chatSnapshot()['submission'] as Map)['status'], 'pending');
      jami.sendResult.complete('unknown');
      await pumpEventQueue();
      expect((chatSnapshot()['submission'] as Map)['status'], 'unknown');
      expect(jami.ownedSendCalls, 1);
      jami.push('sendOperationCompleted', {
        'accountId': 'acc1',
        'peerJamiId': fixture.peer,
        'conversationId': fixture.peerConversation,
        'operationId': 'b' * 32,
        'status': 'committed',
        'commitId': 'confirmed-late',
      });
      await pumpEventQueue();
      expect((chatSnapshot()['submission'] as Map)['status'], 'committed');
      expect(state.sendJournal.record('b' * 32), isNull);
      expect(jami.ownedSendCalls, 1);
      await expectLater(
        state.handleWidgetOverlayCommand('chat.send', {
          'token': token,
          'conversation': token,
          'text': 'Old authority',
        }),
        throwsA(isA<StateError>()),
      );
      state.accountId = 'acc2';
      final replacement =
          ((chatSnapshot()['conversations'] as List).single as Map);
      expect(replacement['draftKey'], isNot(draftKey));
      expect(chatSnapshot()['submission'], isNull);
    },
  );

  test(
    'remote meter needs current native revision and expires to unknown',
    () async {
      await boot();
      jami.push('callState', {
        'accountId': 'acc1',
        'accountRevision': '7',
        'callId': 'call-1',
        'state': 'CURRENT',
        'fromJamiId': fixture.peer,
        'micMuted': 'true',
        'speakerOn': 'false',
        'peerVideo': 'false',
        'selfActive': 'false',
        'remoteActive': 'false',
      });
      await Future<void>.delayed(Duration.zero);

      void meter({String revision = '7', String call = 'call-1'}) =>
          jami.push('remoteAudioMeter', {
            'accountId': 'acc1',
            'accountRevision': revision,
            'callId': call,
            'streamId': '${call}_AUDIO',
            'level': '0.03',
          });

      meter(revision: '6');
      expect((voiceSnapshot()['participants'] as List)[1]['speaking'], isNull);
      meter();
      expect((voiceSnapshot()['participants'] as List)[1]['speaking'], isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1050));
      expect((voiceSnapshot()['participants'] as List)[1]['speaking'], isNull);

      meter();
      expect((voiceSnapshot()['participants'] as List)[1]['speaking'], isTrue);
      jami.push('callState', {
        'accountId': 'acc1',
        'accountRevision': '7',
        'callId': 'call-1',
        'state': 'HUNGUP',
        'fromJamiId': fixture.peer,
      });
      meter();
      expect((voiceSnapshot()['participants'] as List), isEmpty);
    },
  );
}
