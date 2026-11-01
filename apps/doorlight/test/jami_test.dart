import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/outgoing_video.dart';

String _avatarBase64() =>
    base64Encode(image.encodePng(image.Image(width: 2, height: 2)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const core = MethodChannel('syb.l/core');
  const eventChannel = EventChannel('syb.l/events');
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(core, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  test(
    'notification launch requires paired native authority and exact route',
    () async {
      final wire = <String, Object?>{
        'ownerKey': 'group:conversation',
        'conversationId': 'conversation',
        'topicId': 'topic',
        'startCall': true,
        'accountId': 'account',
        'actionToken': 'a' * 64,
      };
      final target = ConversationLaunchTarget.tryParse(wire)!;
      expect(
        ConversationLaunchTarget.tryParse({...wire, 'accountId': null}),
        isNull,
      );
      expect(
        ConversationLaunchTarget.tryParse({...wire, 'actionToken': null}),
        isNull,
      );
      expect(
        ConversationLaunchTarget.tryParse({...wire, 'actionToken': 'bad'}),
        isNull,
      );
      final calls = <MethodCall>[];
      Object? acknowledgment;
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return acknowledgment;
      });
      final client = JamiClient();
      expect(await client.consumeConversationLaunch(target), isFalse);
      expect(calls.single.method, 'consumeMessageOpen');
      expect(calls.single.arguments, wire);
      acknowledgment = true;
      expect(await client.consumeConversationLaunch(target), isTrue);
    },
  );

  test(
    'recording grant keeps exact scope and refuses absent renewal',
    () async {
      final calls = <MethodCall>[];
      Object? reply = 'private/picked-owned/voice.m4a';
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return reply;
      });
      final client = JamiClient();
      final path = await client.prepareVoiceRecording(
        accountId: 'account',
        peerJamiId: 'group:conversation',
        conversationId: 'conversation',
      );
      expect(path, 'private/picked-owned/voice.m4a');
      expect(calls.single.method, 'prepareVoiceRecording');
      expect(calls.single.arguments, {
        'accountId': 'account',
        'peerJamiId': 'group:conversation',
        'conversationId': 'conversation',
      });
      reply = null;
      expect(await client.renewVoiceRecording(path!), isFalse);
      expect(calls.last.arguments, {'path': path});
      reply = true;
      expect(await client.renewVoiceRecording(path), isTrue);
    },
  );

  test(
    'Windows host authority methods preserve the native acknowledgement',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      final valid = <String, Object>{
        'channelEpoch': 4,
        'surfaceRevision': 3,
        'hostGeneration': 8,
        'revokedThrough': 8,
        'blocked': true,
        'releaseComplete': true,
        'state': 'inactive',
      };
      Object? reply = valid;
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return reply;
      });
      final client = JamiClient();
      final authority = await client.remoteControlHostAuthority();
      expect(authority?.channelEpoch, 4);
      expect(authority?.revokedThrough, 8);
      expect(authority?.releaseComplete, isTrue);
      await client.setRemoteControlProtectedSurface(
        channelEpoch: 4,
        surfaceRevision: 3,
        blocked: true,
      );
      expect(calls.last.method, 'remoteControlSetProtectedSurface');
      expect(calls.last.arguments, {
        'channelEpoch': 4,
        'surfaceRevision': 3,
        'blocked': true,
      });
      for (final bad in <Object?>[
        false,
        null,
        {...valid, 'blocked': 'true'},
        {...valid, 'channelEpoch': 0},
        {...valid, 'state': 'stopping'},
        {...valid, 'revokedThrough': -1},
        {...valid, 'releaseComplete': null},
      ]) {
        reply = bad;
        expect(await client.remoteControlHostAuthority(), isNull);
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls.clear();
      expect(await client.remoteControlHostAuthority(), isNull);
      expect(
        await client.setRemoteControlProtectedSurface(
          channelEpoch: 4,
          surfaceRevision: 4,
          blocked: true,
        ),
        isNull,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'events decode valid maps and degrade malformed payloads to unknown',
    () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) => sink = events,
        ),
      );
      final received = <JamiEvent>[];
      final subscription = JamiClient().events().listen(received.add);
      await pumpEventQueue();

      sink.success(<Object?, Object?>{
        'type': 'presence',
        'status': 2,
        7: 'discarded',
      });
      sink.success(<String, Object?>{'status': 0});
      sink.success(<String, Object?>{'type': 9});
      sink.success('not a map');
      await pumpEventQueue();

      expect(received.map((e) => e.type), [
        'presence',
        'unknown',
        'unknown',
        'unknown',
      ]);
      expect(received.first.data, {'type': 'presence', 'status': 2});
      expect(received[1].data, {'status': 0});
      expect(received.last.data, isEmpty);
      await subscription.cancel();
    },
  );

  test('an EventChannel error does not cancel later decoded events', () async {
    late MockStreamHandlerEventSink sink;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (arguments, events) => sink = events),
    );
    final received = <JamiEvent>[];
    final errors = <Object>[];
    final subscription = JamiClient().events().listen(
      received.add,
      onError: errors.add,
    );
    await pumpEventQueue();

    sink.error(code: 'bad_event', message: 'malformed envelope');
    sink.success(<String, Object?>{
      'type': 'deviceAnnounced',
      'announced': true,
    });
    await pumpEventQueue();

    expect(errors, [
      isA<PlatformException>().having((e) => e.code, 'code', 'bad_event'),
    ]);
    expect(received.single.type, 'deviceAnnounced');
    await subscription.cancel();
  });

  test(
    'annotation overlay uses one bounded host method on Windows and Android',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final client = JamiClient();
      const snapshot = <String, Object?>{'active': false};

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await client.setAnnotationOverlay(snapshot), isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await client.setAnnotationOverlay(snapshot), isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(await client.setAnnotationOverlay(snapshot), isFalse);

      expect(calls, hasLength(2));
      expect(
        calls.map((call) => call.method),
        everyElement('setAnnotationOverlay'),
      );
      expect(calls.map((call) => call.arguments), everyElement(snapshot));
    },
  );

  test('composer activity uses one typed bounded host method', () async {
    late MethodCall sent;
    messenger.setMockMethodCallHandler(core, (call) async {
      sent = call;
      return true;
    });

    expect(
      await JamiClient().sendComposerActivity(
        'account-a',
        'b' * 40,
        'conversation-a',
        ComposerActivityKind.typing,
      ),
      isTrue,
    );
    expect(sent.method, 'sendComposerActivity');
    expect(sent.arguments, {
      'accountId': 'account-a',
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'kind': 'typing',
    });
    expect(
      ComposerActivityKind.fromWire('typing'),
      ComposerActivityKind.typing,
    );
    expect(ComposerActivityKind.fromWire('recording'), isNull);
  });

  test('file thumbnail uses one exact base64 host method', () async {
    late MethodCall sent;
    messenger.setMockMethodCallHandler(core, (call) async {
      sent = call;
      return true;
    });
    final png = base64Decode('iVBORw0KGgo=');

    expect(
      await JamiClient().sendFileThumbnail(
        'b' * 40,
        'conversation-a',
        'file-a',
        png,
      ),
      isTrue,
    );
    expect(sent.method, 'sendFileThumbnail');
    expect(sent.arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'fileId': 'file-a',
      'pngBase64': base64Encode(png),
    });
  });

  test('file decline uses one exact host method', () async {
    late MethodCall sent;
    messenger.setMockMethodCallHandler(core, (call) async {
      sent = call;
      return true;
    });

    expect(
      await JamiClient().sendFileDeclined('b' * 40, 'conversation-a', 'file-a'),
      isTrue,
    );
    expect(sent.method, 'sendFileDeclined');
    expect(sent.arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'fileId': 'file-a',
    });
  });

  test('DM topic send methods use one exact native contract', () async {
    final sent = <MethodCall>[];
    messenger.setMockMethodCallHandler(core, (call) async {
      sent.add(call);
      return switch (call.method) {
        'sendDmTopicEvent' => 'commit-a',
        'loadDmTopicState' => 41,
        _ => true,
      };
    });
    final client = JamiClient();
    const topic = '0123456789abcdef0123456789abcdef';

    expect(
      await client.sendChatMessage('b' * 40, 'conversation-a', 'hello'),
      isTrue,
    );
    expect(
      await client.sendChatMessage(
        'b' * 40,
        'conversation-a',
        'plans',
        topicId: topic,
      ),
      isTrue,
    );
    expect(
      await client.sendFile(
        'b' * 40,
        'conversation-a',
        'photo.jpg',
        topicId: topic,
      ),
      isTrue,
    );
    expect(
      await client.sendDmTopicEvent('b' * 40, 'conversation-a', '{"v":1}'),
      'commit-a',
    );
    expect(
      await client.loadDmTopicState(
        'b' * 40,
        'conversation-a',
        fromMessage: 'cursor-a',
      ),
      41,
    );

    expect(sent[0].arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'body': 'hello',
      'replyTo': '',
      'topicId': '',
    });
    expect(sent[1].arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'body': 'plans',
      'replyTo': '',
      'topicId': topic,
    });
    expect(sent[2].method, 'sendFile');
    expect(sent[2].arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'path': 'photo.jpg',
      'name': null,
      'topicId': topic,
    });
    expect(sent[3].method, 'sendDmTopicEvent');
    expect(sent[3].arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'body': '{"v":1}',
    });
    expect(sent[4].method, 'loadDmTopicState');
    expect(sent[4].arguments, {
      'peerJamiId': 'b' * 40,
      'conversationId': 'conversation-a',
      'fromMessage': 'cursor-a',
      'pageSize': 200,
    });
  });

  test(
    'window capture protection maps exact native outcomes fail-closed',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final values = <Object?>[
        'none',
        'exclude',
        'monitor',
        'unavailable',
        'unknown',
      ];
      var index = 0;
      messenger.setMockMethodCallHandler(core, (call) async {
        expect(call.method, 'windowCaptureProtectionStatus');
        return values[index++];
      });
      final client = JamiClient();

      expect(
        await client.windowCaptureProtectionStatus(),
        WindowCaptureProtectionStatus.none,
      );
      expect(
        await client.windowCaptureProtectionStatus(),
        WindowCaptureProtectionStatus.exclude,
      );
      expect(
        await client.windowCaptureProtectionStatus(),
        WindowCaptureProtectionStatus.monitor,
      );
      expect(
        await client.windowCaptureProtectionStatus(),
        WindowCaptureProtectionStatus.unavailable,
      );
      expect(
        await client.windowCaptureProtectionStatus(),
        WindowCaptureProtectionStatus.unavailable,
        reason: 'an unknown wire value must never read as protected',
      );
    },
  );

  test('capture-protection apply sends the request and returns only the '
      'confirmed native state', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final sent = <Map<Object?, Object?>>[];
    final results = <Object?>['exclude', 'none', 'unavailable', 'garbage'];
    var index = 0;
    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'applyWindowCaptureProtection');
      sent.add(call.arguments as Map<Object?, Object?>);
      return results[index++];
    });
    final client = JamiClient();

    expect(
      await client.applyWindowsCaptureProtection(protect: true),
      WindowCaptureProtectionStatus.exclude,
    );
    expect(sent.last, {'protect': true});
    expect(
      await client.applyWindowsCaptureProtection(protect: false),
      WindowCaptureProtectionStatus.none,
    );
    expect(sent.last, {'protect': false});
    // The result is the native truth, not an echo: a protect request may
    // come back unavailable, and garbage maps conservatively.
    expect(
      await client.applyWindowsCaptureProtection(protect: true),
      WindowCaptureProtectionStatus.unavailable,
    );
    expect(
      await client.applyWindowsCaptureProtection(protect: true),
      WindowCaptureProtectionStatus.unavailable,
    );
  });

  test('Windows capture apply reads Android applied privacy truth', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'androidCaptureProtectionStatus');
      return 'none';
    });

    expect(
      await JamiClient().applyWindowsCaptureProtection(protect: false),
      WindowCaptureProtectionStatus.none,
    );
  });

  test(
    'Android privacy toggle sends intent and returns applied truth',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return (call.arguments as Map)['enabled'] == true ? 'exclude' : 'none';
      });
      final client = JamiClient();

      expect(
        await client.applyAndroidCaptureProtection(protect: true),
        WindowCaptureProtectionStatus.exclude,
      );
      expect(calls.last.method, 'setAndroidCaptureProtection');
      expect(calls.last.arguments, {'enabled': true});
      expect(
        await client.applyAndroidCaptureProtection(protect: false),
        WindowCaptureProtectionStatus.none,
      );
      expect(calls.last.arguments, {'enabled': false});
    },
  );

  test('Android launch invite is consumed through one typed method', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'takePendingInviteLink');
      return 'sybl://add/${'a' * 40}?name=Mara';
    });
    expect(
      await JamiClient().takeInitialInviteLink(),
      'sybl://add/${'a' * 40}?name=Mara',
    );
  });

  test(
    'Android message notifications use typed chat routes and settings',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        if (call.method == 'takePendingConversation') {
          return {'ownerKey': 'b' * 40, 'conversationId': 'conversation'};
        }
        if (call.method == 'setMessageNotificationPreview') return true;
        return null;
      });
      final client = JamiClient();

      final target = await client.takeInitialConversation();
      expect(target?.ownerKey, 'b' * 40);
      expect(target?.conversationId, 'conversation');
      await client.setMessageNotificationPreview(false, appLockEnabled: true);
      await client.dismissMessageNotification('conversation');

      expect(calls.map((call) => call.method), [
        'takePendingConversation',
        'setMessageNotificationPreview',
        'dismissMessageNotification',
      ]);
      expect(calls[1].arguments, {
        'showMessage': false,
        'appLockEnabled': true,
      });
      expect(calls[2].arguments, {'conversationId': 'conversation'});
    },
  );

  test('message notification settings are a no-op on Windows', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(core, (call) async {
      calls.add(call);
      return true;
    });

    await JamiClient().setMessageNotificationPreview(
      false,
      appLockEnabled: true,
    );

    expect(calls, isEmpty);
  });

  test('profile display names are bounded by strict UTF-8 bytes', () async {
    final emojiBoundary = '😀' * 64;
    expect(ProfileWireContract.decodeDisplayName('x' * 256), 'x' * 256);
    expect(ProfileWireContract.decodeDisplayName(emojiBoundary), emojiBoundary);
    expect(ProfileWireContract.decodeDisplayName('x' * 257), isNull);
    expect(
      ProfileWireContract.decodeDisplayName(String.fromCharCode(0xd800)),
      isNull,
    );

    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'listFriends');
      return <String, Object?>{
        'revision': 7,
        'friends': <Object?>[
          <String, Object?>{
            'peerJamiId': 'bounded',
            'confirmed': true,
            'conversationId': 'conv-bounded',
            'displayName': emojiBoundary,
            'avatar': 'must-not-be-ingested',
            'description': 'must-not-be-ingested',
          },
          <String, Object?>{
            'peerJamiId': 'oversized',
            'confirmed': true,
            'conversationId': 'conv-oversized',
            'displayName': 'x' * 257,
          },
        ],
      };
    });

    final friends = await JamiClient().listFriends();
    expect(friends.friends[0].displayName, emojiBoundary);
    expect(friends.friends[1].displayName, isEmpty);
  });

  test('profile avatars are bounded images with safe decoded dimensions', () {
    final avatar = _avatarBase64();
    expect(ProfileWireContract.decodeAvatar(avatar), avatar);
    final jpeg = base64Encode(
      image.encodeJpg(image.Image(width: 2, height: 2)),
    );
    expect(ProfileWireContract.decodeAvatar(jpeg), jpeg);
    expect(ProfileWireContract.decodeAvatar('not base64'), isNull);
    expect(
      ProfileWireContract.decodeAvatar(
        'iVBORw0KGgoAAAANSUhEUgAA//8AAP//CAYAAAC2BdlQAAAAAElFTkSuQmCC',
      ),
      isNull,
    );
    expect(
      ProfileWireContract.decodeAvatar(
        base64Encode(
          List<int>.filled(ProfileWireContract.maxAvatarBytes + 1, 7),
        ),
      ),
      isNull,
    );
  });

  test('group projection is bounded and role typed', () async {
    final alice = 'a' * 40;
    final bob = 'b' * 40;
    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'listFriends');
      return <String, Object?>{
        'revision': 8,
        'friends': const <Object?>[],
        'groups': <Object?>[
          <String, Object?>{
            'conversationId': 'group-conversation',
            'title': 'The Crew',
            'description': 'sybl-group-layout:v1:eyJjIjpbXSwiciI6W119',
            'memberCount': 3,
            'canManageMembers': true,
            'localRole': 'admin',
            'members': <Object?>[
              <String, Object?>{
                'peerJamiId': alice,
                'role': 'admin',
                'displayName': 'Alice',
                'avatarBase64': _avatarBase64(),
              },
              <String, Object?>{'peerJamiId': bob, 'role': 'invited'},
              <String, Object?>{'peerJamiId': 'malformed', 'role': 'member'},
            ],
          },
        ],
      };
    });

    final result = await JamiClient().listFriends();
    final group = result.groups.single;
    expect(group.title, 'The Crew');
    expect(group.memberCount, 3);
    expect(group.canManageMembers, isTrue);
    expect(group.localRole, JamiGroupMemberRole.admin);
    expect(group.description, startsWith('sybl-group-layout:v1:'));
    expect(group.members, hasLength(2));
    expect(group.members[0].role, JamiGroupMemberRole.admin);
    expect(group.members[0].displayName, 'Alice');
    expect(group.members[0].avatarBase64, isNotEmpty);
    expect(group.members[1].role, JamiGroupMemberRole.invited);
  });

  test('presence metadata accepts only bounded display-safe values', () {
    expect(PresenceWireContract.decodePlatform('android'), 'android');
    expect(PresenceWireContract.decodePlatform('windows'), 'windows');
    expect(PresenceWireContract.decodePlatform('linux'), isEmpty);
    expect(
      PresenceWireContract.decodeActivity('Team Fortress 2'),
      'Team Fortress 2',
    );
    expect(PresenceWireContract.decodeActivity('x' * 97), isEmpty);
    expect(PresenceWireContract.decodeActivity('private"title'), isEmpty);
    expect(
      PresenceWireContract.decodeActivity(String.fromCharCode(0xd800)),
      isEmpty,
    );
  });

  test('known-device projection is bounded, validated, and sorted', () async {
    final current = 'f' * 40;
    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'listKnownDevices');
      return <Object?>[
        <String, Object?>{'id': 'b' * 40, 'name': 'Phone', 'current': false},
        <String, Object?>{'id': current, 'name': 'This PC', 'current': 'true'},
        <String, Object?>{
          'id': '../${'c' * 40}',
          'name': 'invalid target',
          'current': false,
        },
        <String, Object?>{
          'id': 'd' * 40,
          'name': 'bad\nname',
          'current': false,
        },
        for (var index = 0; index < 70; index++)
          <String, Object?>{
            'id': index.toRadixString(16).padLeft(40, '0'),
            'name': 'Device $index',
            'current': false,
          },
      ];
    });

    final devices = await JamiClient().listKnownDevices();

    expect(devices, hasLength(KnownDeviceWireContract.maxDevices));
    expect(devices.first.id, current);
    expect(devices.first.current, isTrue);
    expect(devices.any((device) => device.id.startsWith('../')), isFalse);
    expect(
      devices.singleWhere((device) => device.id == 'd' * 40).name,
      isEmpty,
    );
  });

  test('known-device revocation sends the exact account and device', () async {
    final id = 'b' * 40;
    messenger.setMockMethodCallHandler(core, (call) async {
      expect(call.method, 'revokeKnownDevice');
      expect(call.arguments, {'accountId': 'account-a', 'deviceId': id});
      return {'accountId': 'account-a', 'deviceId': id, 'status': 'revoked'};
    });

    expect(
      await JamiClient().revokeKnownDevice(id, accountId: 'account-a'),
      JamiDeviceRevocationStatus.revoked,
    );
  });

  test(
    'known-device revocation rejects Boolean initiation as completion',
    () async {
      messenger.setMockMethodCallHandler(core, (call) async => true);
      expect(
        await JamiClient().revokeKnownDevice('b' * 40, accountId: 'account-a'),
        JamiDeviceRevocationStatus.unavailable,
        reason:
            'a Boolean reply contains no authoritative account/device completion',
      );
    },
  );

  test(
    'known-device completion requires exact account device and known status',
    () async {
      final id = 'b' * 40;
      for (final response in <Object?>[
        false,
        null,
        {'accountId': 'account-b', 'deviceId': id, 'status': 'revoked'},
        {'accountId': 'account-a', 'deviceId': 'c' * 40, 'status': 'revoked'},
        {'accountId': 'account-a', 'deviceId': id, 'status': true},
        {'accountId': 'account-a', 'deviceId': id, 'status': 'accepted'},
      ]) {
        messenger.setMockMethodCallHandler(core, (call) async => response);
        expect(
          await JamiClient().revokeKnownDevice(id, accountId: 'account-a'),
          JamiDeviceRevocationStatus.unavailable,
        );
      }
      for (final entry in {
        'credentials': JamiDeviceRevocationStatus.credentials,
        'network': JamiDeviceRevocationStatus.network,
        'timeout': JamiDeviceRevocationStatus.timeout,
        'pending': JamiDeviceRevocationStatus.pending,
        'refused': JamiDeviceRevocationStatus.refused,
        'account-changed': JamiDeviceRevocationStatus.accountChanged,
      }.entries) {
        messenger.setMockMethodCallHandler(
          core,
          (call) async => {
            'accountId': 'account-a',
            'deviceId': id,
            'status': entry.key,
          },
        );
        expect(
          await JamiClient().revokeKnownDevice(id, accountId: 'account-a'),
          entry.value,
        );
      }
    },
  );

  test('invalid revocation target never crosses the native channel', () async {
    var invoked = false;
    messenger.setMockMethodCallHandler(core, (call) async {
      invoked = true;
      return true;
    });
    expect(
      await JamiClient().revokeKnownDevice('../device', accountId: 'account-a'),
      JamiDeviceRevocationStatus.refused,
    );
    expect(
      await JamiClient().revokeKnownDevice('b' * 40, accountId: ''),
      JamiDeviceRevocationStatus.accountChanged,
    );
    expect(invoked, isFalse);
  });

  testWidgets('missing revocation reply times out and ignores late success', (
    tester,
  ) async {
    final reply = Completer<Object?>();
    final id = 'b' * 40;
    messenger.setMockMethodCallHandler(core, (call) => reply.future);
    final result = JamiClient().revokeKnownDevice(id, accountId: 'account-a');
    await tester.pump();
    await tester.pump(const Duration(seconds: 35));
    expect(await result, JamiDeviceRevocationStatus.timeout);
    reply.complete({
      'accountId': 'account-a',
      'deviceId': id,
      'status': 'revoked',
    });
    await tester.pump();
    expect(await result, JamiDeviceRevocationStatus.timeout);
  });

  test(
    'typed wrappers send payloads and use defensive return fallbacks',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ensureAccount' => <Object?, Object?>{
            7: 'discarded',
            'jamiId': 'abc',
          },
          'fileInfo' => <Object?, Object?>{false: 9, 'total': 12},
          'restoreIdentity' => <Object?, Object?>{
            null: 'discarded',
            'accountId': 'acc',
          },
          'placeCall' => <Object?, Object?>{
            'callId': 'call1',
            'cameraOn': false,
          },
          'listFriends' => <Object?, Object?>{
            'revision': 9,
            'friends': <Object?>[
              <Object?, Object?>{
                'peerJamiId': 'peer1',
                'confirmed': true,
                'conversationId': 'conv1',
              },
            ],
          },
          'addFriend' => true,
          'answerCall' => true,
          'setPresenceSubscriptions' => true,
          'loadFolder' => 42,
          'cancelChatLoad' => true,
          'cancelDmTopicStateLoad' => true,
          'setOutgoingVideoSource' => true,
          'listScreenSources' => <Object?>[
            <Object?, Object?>{
              'id': '2',
              'label': 'Display 3',
              'primary': true,
              'left': -800,
              'top': 1080,
              'width': 800,
              'height': 600,
            },
          ],
          'startVideo' => true,
          'stopVideo' => false,
          _ => null,
        };
      });
      final client = JamiClient();

      expect(
        await client.ensureAccount(
          'Ada',
          preferredAccountId: 'acc0',
          preferredPeerId: 'peer0',
        ),
        {'jamiId': 'abc'},
      );
      final ensure = calls.removeAt(0);
      expect(ensure.method, 'ensureAccount');
      expect(ensure.arguments, {
        'displayName': 'Ada',
        'preferredAccountId': 'acc0',
        'preferredPeerId': 'peer0',
        'createIfMissing': false,
      });

      final placement = await client.placeCall(
        'peer',
        withVideo: true,
        initialAudioMuted: true,
      );
      expect(placement.callId, 'call1');
      expect(placement.cameraOn, isFalse);
      final place = calls.removeAt(0);
      expect(place.method, 'placeCall');
      expect(place.arguments, {
        'peerJamiId': 'peer',
        'withVideo': true,
        'initialAudioMuted': true,
      });

      await client.answerCall('call1', initialAudioMuted: true);
      final answer = calls.removeAt(0);
      expect(answer.method, 'answerCall');
      expect(answer.arguments, {'callId': 'call1', 'initialAudioMuted': true});

      final friends = await client.listFriends();
      expect(friends.revision, 9);
      expect(friends.friends.single.peerJamiId, 'peer1');
      expect(friends.friends.single.conversationId, 'conv1');
      expect(friends.friends.single.confirmed, isTrue);
      expect(calls.removeAt(0).method, 'listFriends');

      expect(
        await client.addFriend('peer2', expectedAccountId: 'account-a'),
        isTrue,
      );
      final addFriend = calls.removeAt(0);
      expect(addFriend.arguments, {
        'peerJamiId': 'peer2',
        'expectedAccountId': 'account-a',
      });

      await client.setPresenceSubscriptions(['peer1', 'peer2']);
      final subscriptions = calls.removeAt(0);
      expect(subscriptions.arguments, {
        'peerJamiIds': ['peer1', 'peer2'],
      });

      await client.setPresenceMetadata(shareActivity: true, color: 'violet');
      final metadata = calls.removeAt(0);
      expect(metadata.method, 'setPresenceMetadata');
      expect(metadata.arguments, {'shareActivity': true, 'color': 'violet'});

      expect(await client.startVideo('call1'), isTrue);
      final startVideo = calls.removeAt(0);
      expect(startVideo.method, 'startVideo');
      expect(startVideo.arguments, {'callId': 'call1'});

      expect(await client.stopVideo('call1'), isFalse);
      final stopVideo = calls.removeAt(0);
      expect(stopVideo.method, 'stopVideo');
      expect(stopVideo.arguments, {'callId': 'call1'});

      expect(
        await client.setOutgoingVideoSource(
          'call1',
          OutgoingVideoKind.screen,
          sourceId: '2',
        ),
        isTrue,
      );
      final setSource = calls.removeAt(0);
      expect(setSource.method, 'setOutgoingVideoSource');
      expect(setSource.arguments, {
        'callId': 'call1',
        'kind': 'screen',
        'sourceId': '2',
      });

      final screens = await client.listScreenSources('call1');
      expect(screens.single.id, '2');
      expect(screens.single.primary, isTrue);
      expect(screens.single.bounds.left, -800);
      final listSources = calls.removeAt(0);
      expect(listSources.method, 'listScreenSources');
      expect(listSources.arguments, {'callId': 'call1'});

      await client.switchCamera('call1');
      final switchCamera = calls.removeAt(0);
      expect(switchCamera.method, 'switchCamera');
      expect(switchCamera.arguments, {'callId': 'call1'});

      await client.setMicMuted('call1', true);
      final mute = calls.removeAt(0);
      expect(mute.method, 'setMicMuted');
      expect(mute.arguments, {'callId': 'call1', 'muted': true});

      await client.setAudioTransmissionMode(
        'call1',
        AudioTransmissionMode.voiceActivated,
      );
      final transmissionMode = calls.removeAt(0);
      expect(transmissionMode.method, 'setAudioTransmissionMode');
      expect(transmissionMode.arguments, {
        'callId': 'call1',
        'mode': 'voiceActivated',
      });

      expect(await client.hasCameraPermission(), isFalse);
      expect(await client.createVideoTexture('remote'), -1);
      expect(await client.fileInfo('peer1', 'conv1', 'file1'), {'total': 12});
      final fileInfo = calls.singleWhere((call) => call.method == 'fileInfo');
      expect(fileInfo.arguments, {
        'peerJamiId': 'peer1',
        'conversationId': 'conv1',
        'fileId': 'file1',
      });
      expect(
        await client.acceptFile(
          'peer1',
          'conv1',
          'interaction1',
          'file1',
          'photo.jpg',
          maxBytes: 2147483648,
          attemptId: '0123456789abcdef0123456789abcdef',
        ),
        isFalse,
      );
      final acceptFile = calls.singleWhere(
        (call) => call.method == 'acceptFile',
      );
      expect(acceptFile.method, 'acceptFile');
      expect(acceptFile.arguments, {
        'peerJamiId': 'peer1',
        'conversationId': 'conv1',
        'interactionId': 'interaction1',
        'fileId': 'file1',
        'name': 'photo.jpg',
        'maxBytes': 2147483648,
        'attemptId': '0123456789abcdef0123456789abcdef',
      });
      expect(
        await client.cancelFile(
          'peer1',
          'conv1',
          'file1',
          attemptId: '0123456789abcdef0123456789abcdef',
        ),
        isFalse,
      );
      expect(
        calls.singleWhere((call) => call.method == 'cancelFile').arguments,
        {
          'peerJamiId': 'peer1',
          'conversationId': 'conv1',
          'fileId': 'file1',
          'attemptId': '0123456789abcdef0123456789abcdef',
        },
      );
      expect(await client.loadFolder('peer1', 'conv1', 200), 42);
      final loadFolder = calls.singleWhere(
        (call) => call.method == 'loadFolder',
      );
      expect(loadFolder.arguments, {
        'peerJamiId': 'peer1',
        'conversationId': 'conv1',
        'n': 200,
      });
      expect(await client.cancelChatLoad(0xffffffff), isTrue);
      final cancelChatLoad = calls.singleWhere(
        (call) => call.method == 'cancelChatLoad',
      );
      expect(cancelChatLoad.arguments, {'loadId': 0xffffffff});
      expect(await client.cancelDmTopicStateLoad(0xffffffff), isTrue);
      expect(
        calls
            .singleWhere((call) => call.method == 'cancelDmTopicStateLoad')
            .arguments,
        {'loadId': 0xffffffff},
      );
      expect(
        await client.restoreIdentity(
          'backup.gz',
          'secret',
          connectionProfile: 'strict',
          dhtBootstrap: 'bootstrap.example',
          turnServer: 'turn.example',
          turnRealm: 'realm',
          turnUser: 'user',
          turnPassword: 'password',
          appearOffline: true,
          expectedAccountId: 'existing-owner',
          expectedJamiId: 'e' * 40,
        ),
        {'accountId': 'acc'},
      );
      final restore = calls.singleWhere(
        (call) => call.method == 'restoreIdentity',
      );
      expect(restore.arguments, {
        'filePath': 'backup.gz',
        'passphrase': 'secret',
        'connectionProfile': 'strict',
        'dhtBootstrap': 'bootstrap.example',
        'turnServer': 'turn.example',
        'turnRealm': 'realm',
        'turnUser': 'user',
        'turnPassword': 'password',
        'appearOffline': true,
        'expectedAccountId': 'existing-owner',
        'expectedJamiId': 'e' * 40,
      });
      expect(
        await client.backupIdentity(
          'secret',
          settingsDocument: '{"schemaVersion":12}',
        ),
        isFalse,
      );
      final backup = calls.singleWhere(
        (call) => call.method == 'backupIdentity',
      );
      expect(backup.arguments, {
        'passphrase': 'secret',
        'settingsDocument': '{"schemaVersion":12}',
      });
    },
  );

  test('identity backup rejects an oversized settings document', () async {
    var called = false;
    messenger.setMockMethodCallHandler(core, (call) async {
      called = true;
      return true;
    });

    final saved = await JamiClient().backupIdentity(
      'secret',
      settingsDocument: 'x' * (JamiClient.maxSettingsDocumentBytes + 1),
    );

    expect(saved, isFalse);
    expect(called, isFalse);
  });

  test('important commands require an explicit true acknowledgement', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(core, (call) async {
      methods.add(call.method);
      return false;
    });
    final client = JamiClient();
    final commands = <Future<void> Function()>[
      () => client.answerCall('call'),
      () => client.hangUp('call'),
      () => client.refuse('call'),
      () => client.setPresenceSubscriptions(['peer']),
      () => client.removeContact('peer'),
    ];

    for (final command in commands) {
      await expectLater(command(), throwsStateError);
    }
    expect(methods, [
      'answerCall',
      'hangUp',
      'refuse',
      'setPresenceSubscriptions',
      'removeContact',
    ]);
  });

  test('MethodChannel PlatformException propagates to the caller', () async {
    messenger.setMockMethodCallHandler(
      core,
      (call) async => throw PlatformException(
        code: 'daemon_command_failed',
        message: call.method,
      ),
    );

    await expectLater(
      JamiClient().setSpeaker(true),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'daemon_command_failed',
        ),
      ),
    );
  });

  test(
    'desktop microphone devices use the native input-device methods',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return switch (call.method) {
          'audioInputs' => <String>['Built-in microphone', 'USB microphone'],
          'setAudioInput' => true,
          _ => null,
        };
      });

      final client = JamiClient();
      expect(await client.audioInputs(), [
        'Built-in microphone',
        'USB microphone',
      ]);
      expect(await client.setAudioInput(1), isTrue);
      expect(calls.map((call) => call.method), [
        'audioInputs',
        'setAudioInput',
      ]);
      expect(calls.last.arguments, {'index': 1});
    },
  );
}
