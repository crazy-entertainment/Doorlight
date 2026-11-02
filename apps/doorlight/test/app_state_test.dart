import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show MaterialApp, IconButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/media_retirement.dart';
import 'package:sybl/core/invite_link.dart';
import 'package:sybl/core/sound_effects.dart';
import 'package:sybl/state/annotation.dart';
import 'package:sybl/state/remote_control.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/screens/incoming.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/friend_rail.dart' show friendLabel;
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/composer_commands.dart';
import 'package:sybl/state/dm_topics.dart';
import 'package:sybl/state/group_topics.dart';
import 'package:sybl/state/group_calls.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/state/send_journal.dart';
import 'package:sybl/state/composer_draft.dart';

String _avatarBase64() =>
    base64Encode(image.encodePng(image.Image(width: 2, height: 2)));

/// Channel-free [JamiClient]: overrides every method the tested paths touch. Anything NOT overridden
/// hits a real MethodChannel and throws MissingPluginException — loud by design, so a test that wanders
/// onto an unfaked path fails instead of silently passing.
class FakeJami extends JamiClient {
  @override
  Future<void> setWindowEdgeSpacing(
    String spacing, {
    required bool reposition,
  }) async {}

  @override
  bool get usesNativeSendJournal => false;
  // Most state fixtures exercise the portable preferences adapter. Android
  // canonical-write integration fixtures opt into the real channel boundary.
  @override
  bool get usesNativeAppSettingsStore => nativeAppSettingsStore;
  bool nativeAppSettingsStore = false;
  Completer<void>? pendingAppSettingsSave;
  Completer<void>? appSettingsSaveStarted;

  @override
  Future<void> saveAppSettingsDocument(String document) async {
    if (!nativeAppSettingsStore) {
      return super.saveAppSettingsDocument(document);
    }
    appSettingsSaveStarted?.complete();
    await pendingAppSettingsSave?.future;
    await (await SharedPreferences.getInstance()).setString(
      'appSettings',
      document,
    );
  }

  final _events = StreamController<JamiEvent>.broadcast(sync: true);
  final calls = <String>[];
  final Map<String, JamiFriend> daemonFriends = {};
  final Map<String, JamiGroup> daemonGroups = {};
  final queuedFriendLists = <JamiFriendList>[];
  final Map<String, List<Map<String, Object?>>> chatHistory = {};
  final Map<String, String> pendingConnectPeers = {};
  int friendsRevision = 1;
  int nextLoadId = 1;
  int nextChatLoadId = 1000;
  int nextDmTopicLoadId = 2000;
  JamiEvent? eventDuringLoadChat;
  bool autoCompleteChat = true;
  bool autoCompleteDmTopics = true;
  final Map<String, List<Map<String, Object?>>> dmTopicHistory = {};
  bool sendChatResult = true;
  String? lastChatBody;
  String? lastChatReplyTo;
  String? lastChatTopicId;
  String nextDmTopicCommitId = 'topic-commit-1';
  bool autoDeliverLeftNotice = true;
  bool throwDmTopicEvent = false;
  String? archivedChatsRoot;
  final List<({String peerId, String conversationId, String body})>
  sentDmTopicEvents = [];
  final sentCallMessages = <String>[];
  bool daemonDown = false;
  Completer<Map<String, dynamic>>? pendingEnsure;
  String? callStateDuringPlace;
  Map<String, dynamic> callStateDataDuringPlace = const {};
  bool callStateBeforeIncoming = false;
  bool incomingDuringPlace = false;
  final List<JamiEvent> extraEventsDuringPlace = [];
  int textureCalls = 0;
  int fileInfoCalls = 0;
  Completer<void>? fileInfoStarted;
  Completer<Map<String, dynamic>>? pendingFileInfo;
  Completer<bool>? pendingAcceptFile;
  JamiEvent? eventDuringLoadFolder;
  int acceptFileCalls = 0;
  int? lastAcceptMaxBytes;
  int pickFileCalls = 0;
  int? lastPickMaxBytes;
  final discardedPickedFiles = <String>[];
  int sendFileCalls = 0;
  bool sendFileResult = true;
  bool throwSendFile = false;
  String? lastSendFilePeer;
  String? lastSendFileConversation;
  String? lastSendFileTopicId;
  bool profileUpdateResult = true;
  String? lastProfileDisplayName;
  String? lastProfileAvatar;
  String? lastProfileFileType;
  int? lastProfileFlag;
  Completer<bool>? pendingStartVideo;
  Completer<bool>? pendingStopVideo;
  Completer<bool>? pendingScreenVideo;
  Completer<List<ScreenSource>>? pendingScreenSources;
  Completer<String>? pendingProbe;
  final probedPeers = <String>[];
  Completer<void>? pendingRefuse;
  Completer<void>? pendingHangUp;
  Completer<int>? pendingTexture;
  bool? placedCameraOn;
  int startVideoCalls = 0;
  bool failAppearOffline = false;
  bool failConnectionProfile = false;
  Completer<void>? pendingAppearOffline;
  Completer<void>? pendingConnectionProfile;
  bool failConnectDecision = false;
  bool failSubscribePresence = false;
  bool ignoreRemoveContact = false;
  bool stopVideoResult = true;
  bool throwAcceptFile = false;
  bool throwCancelFile = false;
  bool cancelFileResult = true;
  Completer<bool>? pendingCancelFile;
  bool throwAudioControl = false;
  bool throwAudioTransmissionMode = false;
  JamiEvent? eventDuringEnsure;
  String? lastPlacedPeer;
  bool? lastPlacedInitialAudioMuted;
  bool? lastAnsweredInitialAudioMuted;
  WindowCaptureProtectionStatus captureProtection =
      WindowCaptureProtectionStatus.exclude;
  bool remoteControlAccessibility = false;
  final captureApplyCalls = <bool>[];
  final presenceMetadataCalls = <({bool shareActivity, String color})>[];
  bool appliedPresenceSharing = false;
  bool failPresenceMetadata = false;
  Completer<void>? pendingPresenceMetadata;
  String initialInviteLink = '';
  ConversationLaunchTarget? initialConversation;
  Completer<bool>? pendingConversationAuthorization;
  int conversationAuthorizations = 0;
  final messagePreviewCalls = <bool>[];
  final messageAppLockCalls = <bool>[];
  bool failMessageNotificationPolicy = false;
  bool backgroundWakeAvailable = true;
  bool backgroundWakeApplyResult = true;
  final backgroundWakeCalls = <({bool enabled, String profile})>[];
  final callRequestPeers = <String>[];
  final dismissedMessageNotifications = <String>[];
  final List<({String peerId, String conversationId, String messageId})>
  displayedMessages = [];
  WindowCaptureProtectionStatus? captureApplyProtectedResult;
  WindowCaptureProtectionStatus? captureApplyVisibleResult;
  Object? captureApplyError;
  Completer<WindowCaptureProtectionStatus>? pendingCaptureApply;
  final composerActivityCalls =
      <
        ({
          String accountId,
          String peerId,
          String conversationId,
          ComposerActivityKind kind,
        })
      >[];
  bool composerActivityResult = true;
  int replayPendingNativeEventsCalls = 0;
  final List<JamiEvent> pendingReplayEvents = [];

  /// Local identity + outgoing call id for the faked endpoint.
  bool accountExists = true;
  bool? lastEnsureCreateIfMissing;
  String accountId = 'acc1';
  String accountJamiId = 'a' * 40;
  String? accountDisplayName;
  String accountAvatarBase64 = '';
  bool accountEnabled = true;
  bool accountAnnounced = false;
  String accountRegistration = 'UNREGISTERED';
  Map<String, dynamic>? restoreResult;
  Map<String, dynamic>? pendingIdentityRestore;
  Map<String, dynamic>? pendingRestoreFinalResult;
  String? finalizedRestoreDocument;
  int restoreFinalizations = 0;
  Map<String, Object?>? lastRestoreArguments;
  String? lastBackupSettingsDocument;
  String? lastBackupPassphrase;
  String outgoingId = 'out1';
  bool addGroupMembersResult = true;
  String? lastGroupConversationId;
  List<String> lastGroupMemberIds = [];
  List<GroupActiveCall> activeGroupCalls = [];
  GroupCallPlacement nextGroupPlacement = const GroupCallPlacement(
    conferenceId: 'syblv1-voice-42',
    callId: 'group-leg-1',
    hosting: true,
  );
  bool failGroupPlacement = false;
  final groupPresencePayloads = <String>[];

  /// Deliver a daemon event to the app, synchronously (as the reducer sees it).
  final receiveAttempts = <(String, String, String), String>{};

  void push(String type, Map<String, dynamic> data) {
    final normalized = <String, dynamic>{'type': type, ...data};
    if (type == 'connectRequest') {
      final conversationId = normalized['conversationId'];
      final fromJamiId = normalized['fromJamiId'];
      if (conversationId is String && fromJamiId is String) {
        pendingConnectPeers[conversationId] = fromJamiId;
      }
    }
    if (const {
      'incomingFile',
      'fileProgress',
      'folderFile',
      'folderSnapshot',
    }.contains(type)) {
      normalized.putIfAbsent('accountId', () => 'acc1');
      normalized.putIfAbsent('peerJamiId', () => peer);
      normalized.putIfAbsent('conversationId', () => peerConversation);
    }
    if (type == 'fileProgress') {
      normalized.putIfAbsent(
        'attemptId',
        () =>
            receiveAttempts[(
              normalized['peerJamiId'] as String,
              normalized['conversationId'] as String,
              normalized['fileId'] as String,
            )] ??
            '',
      );
    }
    _events.add(JamiEvent(type, normalized));
  }

  void pushError(Object error) => _events.addError(error, StackTrace.current);

  @override
  Stream<JamiEvent> events() => _events.stream;

  @override
  Future<void> replayPendingNativeEvents() async {
    replayPendingNativeEventsCalls++;
    for (final event in pendingReplayEvents) {
      push(event.type, Map<String, dynamic>.from(event.data));
    }
  }

  @override
  Future<Map<String, dynamic>> ensureAccount(
    String displayName, {
    String preferredAccountId = '',
    String preferredPeerId = '',
    bool createIfMissing = false,
  }) async {
    lastEnsureCreateIfMissing = createIfMissing;
    calls.add(
      'ensureAccount:$preferredAccountId:$preferredPeerId:$createIfMissing',
    );
    if (daemonDown) throw StateError('daemon down');
    final pending = pendingEnsure;
    if (pending != null) return pending.future;
    if (!accountExists && !createIfMissing) {
      return {'status': 'noAccount'};
    }
    accountExists = true;
    if (preferredPeerId.isNotEmpty) {
      daemonFriends.putIfAbsent(
        preferredPeerId,
        () => JamiFriend(
          peerJamiId: preferredPeerId,
          confirmed: true,
          conversationId: preferredPeerId == peer
              ? peerConversation
              : 'conv-$preferredPeerId',
        ),
      );
    }
    final replay = eventDuringEnsure;
    if (replay != null) push(replay.type, replay.data);
    return {
      'status': 'ok',
      'accountId': accountId,
      'jamiId': accountJamiId,
      'displayName': accountDisplayName ?? displayName,
      'avatarBase64': accountAvatarBase64,
      'enabled': accountEnabled,
      'announced': accountAnnounced,
      'registration': accountRegistration,
    };
  }

  @override
  Future<String> myJamiId() async => '';
  @override
  Future<WindowCaptureProtectionStatus> windowCaptureProtectionStatus() async =>
      captureProtection;

  @override
  Future<WindowCaptureProtectionStatus> presentWindowsCapturePrompt() async =>
      captureProtection;
  @override
  Future<bool> remoteControlAccessibilityEnabled() async =>
      remoteControlAccessibility;
  @override
  Future<bool> requestRemoteControl({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required List<String> capabilities,
    required String identityColor,
    required String androidPacket,
  }) async {
    calls.add('requestRemoteControl:$callId:$peerJamiId:$sourceRevision');
    return true;
  }

  @override
  Future<bool> sendRemoteControlInput({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required List<List<Object>> events,
    required String androidPacket,
  }) async {
    calls.add('inputRemoteControl:$callId:$events');
    return true;
  }

  @override
  Future<WindowCaptureProtectionStatus> applyWindowsCaptureProtection({
    required bool protect,
  }) async {
    captureApplyCalls.add(protect);
    final pending = pendingCaptureApply;
    if (pending != null) {
      final result = await pending.future;
      captureProtection = result;
      return result;
    }
    final error = captureApplyError;
    if (error != null) throw error;
    final result = protect
        ? (captureApplyProtectedResult ?? WindowCaptureProtectionStatus.exclude)
        : (captureApplyVisibleResult ?? WindowCaptureProtectionStatus.none);
    captureProtection = result;
    return result;
  }

  @override
  Future<WindowCaptureProtectionStatus> applyAndroidCaptureProtection({
    required bool protect,
  }) => applyWindowsCaptureProtection(protect: protect);

  /// Native confirms a secure frame for every visible sensitive surface.
  final sensitiveSurfaceReports = <bool>[];
  @override
  Future<bool> setAndroidSensitiveSurface({required bool visible}) async {
    sensitiveSurfaceReports.add(visible);
    return visible;
  }

  @override
  Future<String> getPeerId() async => '';
  @override
  Future<JamiFriendList> listFriends() async => queuedFriendLists.isNotEmpty
      ? queuedFriendLists.removeAt(0)
      : JamiFriendList(
          friendsRevision,
          daemonFriends.values.toList(growable: false),
          daemonGroups.values.toList(growable: false),
        );

  @override
  Future<bool> addGroupMembers(
    String conversationId,
    Iterable<String> memberIds, {
    String? expectedAccountId,
  }) async {
    lastGroupConversationId = conversationId;
    lastGroupMemberIds = memberIds.toList(growable: false);
    return addGroupMembersResult;
  }

  @override
  Future<bool> addFriend(String peerJamiId, {String? expectedAccountId}) async {
    daemonFriends[peerJamiId] = JamiFriend(
      peerJamiId: peerJamiId,
      confirmed: true,
      conversationId: peerJamiId == peer
          ? peerConversation
          : 'conv-$peerJamiId',
    );
    friendsRevision++;
    return true;
  }

  @override
  Future<void> setPresenceSubscriptions(Iterable<String> peerJamiIds) async {
    for (final id in peerJamiIds) {
      calls.add('subscribe:$id');
    }
    if (failSubscribePresence) throw StateError('subscribe failed');
  }

  @override
  Future<void> setForeground(bool fg) async {}
  @override
  Future<void> setPresenceMetadata({
    required bool shareActivity,
    required String color,
  }) async {
    presenceMetadataCalls.add((shareActivity: shareActivity, color: color));
    await pendingPresenceMetadata?.future;
    if (failPresenceMetadata) throw StateError('native metadata unavailable');
    appliedPresenceSharing = shareActivity;
  }

  @override
  Future<String> takeInitialInviteLink() async => initialInviteLink;

  @override
  Future<ConversationLaunchTarget?> takeInitialConversation() async =>
      initialConversation;

  @override
  Future<bool> consumeConversationLaunch(
    ConversationLaunchTarget target,
  ) async {
    conversationAuthorizations++;
    return await pendingConversationAuthorization?.future ?? true;
  }

  @override
  Future<void> setMessageNotificationPreview(
    bool showMessage, {
    required bool appLockEnabled,
  }) async {
    messagePreviewCalls.add(showMessage);
    messageAppLockCalls.add(appLockEnabled);
    if (failMessageNotificationPolicy) {
      throw StateError('notification policy failed');
    }
  }

  @override
  Future<void> dismissMessageNotification(String conversationId) async {
    dismissedMessageNotifications.add(conversationId);
  }

  @override
  Future<bool> backgroundWakeAvailability() async => backgroundWakeAvailable;

  @override
  Future<bool> setReliableBackgroundNotifications({
    required bool enabled,
    required String connectionProfile,
    String? expectedAccountId,
  }) async {
    backgroundWakeCalls.add((enabled: enabled, profile: connectionProfile));
    return backgroundWakeApplyResult;
  }

  @override
  Future<bool> notifyCallRequest(String peerJamiId) async {
    callRequestPeers.add(peerJamiId);
    return true;
  }

  @override
  Future<String> probeReachable(String peerJamiId) async {
    probedPeers.add(peerJamiId);
    return pendingProbe?.future ?? '';
  }

  @override
  Future<bool> sendComposerActivity(
    String accountId,
    String peerJamiId,
    String conversationId,
    ComposerActivityKind kind,
  ) async {
    composerActivityCalls.add((
      accountId: accountId,
      peerId: peerJamiId,
      conversationId: conversationId,
      kind: kind,
    ));
    return composerActivityResult;
  }

  @override
  Future<void> connectivitySweep() async {}
  @override
  Future<int> loadFolder(
    String peerJamiId,
    String conversationId,
    int keepLast,
  ) async {
    final id = nextLoadId++;
    final event = eventDuringLoadFolder;
    eventDuringLoadFolder = null;
    if (event != null) push(event.type, event.data);
    return id;
  }

  @override
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
  }) async {
    final id = nextChatLoadId++;
    calls.add(
      'loadChat:$peerJamiId:$conversationId:$fromMessage:$pageSize:$id',
    );
    final event = eventDuringLoadChat;
    eventDuringLoadChat = null;
    if (event != null) {
      push(event.type, {
        'accountId': 'acc1',
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'loadId': id,
        'requestedCursor': fromMessage,
        'nextCursor': '',
        'hasMore': false,
        'items': const <Object?>[],
        ...event.data,
      });
    } else if (autoCompleteChat) {
      push('chatSnapshot', {
        'accountId': 'acc1',
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'loadId': id,
        'requestedCursor': fromMessage,
        'nextCursor': '',
        'hasMore': false,
        'items': chatHistory[conversationId] ?? const <Object?>[],
      });
    }
    return id;
  }

  @override
  Future<int> loadDmTopicState(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 200,
  }) async {
    final id = nextDmTopicLoadId++;
    calls.add(
      'loadDmTopicState:$peerJamiId:$conversationId:$fromMessage:$pageSize:$id',
    );
    if (autoCompleteDmTopics) {
      push('dmTopicStatePage', {
        'accountId': 'acc1',
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'loadId': id,
        'requestedCursor': fromMessage,
        'nextCursor': '',
        'hasMore': false,
        'items': dmTopicHistory[conversationId] ?? const <Object?>[],
      });
    }
    return id;
  }

  @override
  Future<bool> cancelChatLoad(int loadId) async {
    calls.add('cancelChatLoad:$loadId');
    return true;
  }

  @override
  Future<bool> cancelDmTopicStateLoad(int loadId) async {
    calls.add('cancelDmTopicStateLoad:$loadId');
    return true;
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
    final accepted = await sendChatMessage(
      peerJamiId,
      conversationId,
      body,
      replyTo: replyTo,
      topicId: topicId,
    );
    if (!accepted) return 'failed-before-commit';
    push('sendOperationCompleted', {
      'accountId': accountId,
      'peerJamiId': peerJamiId,
      'conversationId': conversationId,
      'operationId': operationId,
      'status': 'committed',
      'commitId': 'owned-$operationId',
    });
    return 'pending';
  }

  @override
  Future<bool> sendChatMessage(
    String peerJamiId,
    String conversationId,
    String body, {
    String replyTo = '',
    String topicId = '',
  }) async {
    lastChatBody = body;
    lastChatReplyTo = replyTo;
    lastChatTopicId = topicId;
    calls.add('sendChatMessage:$peerJamiId:$conversationId');
    return sendChatResult;
  }

  @override
  Future<String> sendDmTopicEvent(
    String peerJamiId,
    String conversationId,
    String body,
  ) async {
    sentDmTopicEvents.add((
      peerId: peerJamiId,
      conversationId: conversationId,
      body: body,
    ));
    calls.add('sendDmTopicEvent:$peerJamiId');
    if (throwDmTopicEvent) throw StateError('topic event refused');
    // An online peer fetches a removal notice at once unless a test holds it.
    if (autoDeliverLeftNotice &&
        DmTopicEventCodec.decode(body)?.operation == DmTopicOperation.left) {
      push('messageStatus', {
        'accountId': 'acc1',
        'conversationId': conversationId,
        'peerJamiId': peerJamiId,
        'messageId': nextDmTopicCommitId,
        'state': 2,
      });
    }
    return nextDmTopicCommitId;
  }

  @override
  Future<String?> archivedChatsDirectory() async => archivedChatsRoot;

  @override
  Future<bool> setMessageDisplayed(
    String peerJamiId,
    String conversationId,
    String messageId,
  ) async {
    displayedMessages.add((
      peerId: peerJamiId,
      conversationId: conversationId,
      messageId: messageId,
    ));
    return true;
  }

  @override
  Future<void> setAppearOffline(bool on, {String? expectedAccountId}) async {
    calls.add('appearOffline:$on');
    if (failAppearOffline) throw StateError('offline failed');
    await pendingAppearOffline?.future;
  }

  @override
  Future<void> setConnectionProfile(
    String profile, {
    String? expectedAccountId,
    String dhtBootstrap = '',
    String turnServer = '',
    String turnRealm = '',
    String turnUser = '',
    String turnPassword = '',
  }) async {
    calls.add(
      'connectionProfile:$profile:$dhtBootstrap:$turnServer:$turnRealm:$turnUser:$turnPassword',
    );
    if (failConnectionProfile) throw StateError('profile failed');
    await pendingConnectionProfile?.future;
  }

  @override
  Future<void> acceptConnect(String conversationId) async {
    calls.add('acceptConnect:$conversationId');
    if (failConnectDecision) throw StateError('accept failed');
    final from = pendingConnectPeers.remove(conversationId);
    if (from != null && from.isNotEmpty) {
      daemonFriends[from] = JamiFriend(
        peerJamiId: from,
        confirmed: true,
        conversationId: conversationId,
      );
      friendsRevision++;
    }
  }

  @override
  Future<void> declineConnect(String conversationId, String fromJamiId) async {
    calls.add('declineConnect:$conversationId');
    if (failConnectDecision) throw StateError('decline failed');
  }

  @override
  Future<void> removeContact(String uri, {bool block = false}) async {
    if (!ignoreRemoveContact) {
      daemonFriends.remove(uri);
      friendsRevision++;
    }
    calls.add('removeContact:$uri:$block');
  }

  @override
  Future<void> setMicMuted(String callId, bool muted) async {
    calls.add('setMicMuted:$callId:$muted');
    if (throwAudioControl) throw StateError('mic failed');
  }

  @override
  Future<void> setAudioTransmissionMode(
    String callId,
    AudioTransmissionMode mode,
  ) async {
    calls.add('setAudioTransmissionMode:$callId:${mode.name}');
    if (throwAudioTransmissionMode) {
      throw StateError('audio transmission mode failed');
    }
  }

  @override
  Future<void> setAudioMeterEnabled(bool enabled) async {
    calls.add('setAudioMeterEnabled:$enabled');
    if (throwAudioControl) throw StateError('meter failed');
  }

  @override
  Future<void> setSpeaker(bool on) async {
    calls.add('setSpeaker:$on');
    if (throwAudioControl) throw StateError('speaker failed');
  }

  @override
  Future<CallPlacement> placeCall(
    String peerJamiId, {
    bool withVideo = false,
    bool initialAudioMuted = false,
  }) async {
    final id = outgoingId;
    lastPlacedPeer = peerJamiId;
    lastPlacedInitialAudioMuted = initialAudioMuted;
    calls.add('place:$id');
    final earlyState = callStateDuringPlace;
    void pushEarlyState() {
      if (earlyState == null) return;
      push('callState', {
        'callId': id,
        'state': earlyState,
        'fromJamiId': peer,
        ...callStateDataDuringPlace,
      });
    }

    if (callStateBeforeIncoming) pushEarlyState();
    if (incomingDuringPlace) {
      push('incomingCall', {'callId': 'incoming1', 'fromJamiId': peer});
    }
    for (final event in extraEventsDuringPlace) {
      push(event.type, event.data);
    }
    if (!callStateBeforeIncoming) pushEarlyState();
    return CallPlacement(id, cameraOn: placedCameraOn ?? withVideo);
  }

  @override
  Future<List<GroupActiveCall>> listGroupCalls(String conversationId) async {
    calls.add('listGroupCalls:$conversationId');
    return activeGroupCalls;
  }

  @override
  Future<bool> reserveGroupCall(
    String accountId,
    String conversationId,
    String reservationId,
  ) async {
    calls.add('reserveGroupCall:$conversationId:$reservationId');
    return true;
  }

  @override
  Future<GroupCallPlacement> joinGroupCall({
    required String conversationId,
    required String conferenceId,
    String reservationId = '',
    String hostUri = '',
    String hostDevice = '',
    bool initialAudioMuted = false,
  }) async {
    calls.add(
      'joinGroupCall:$conversationId:$conferenceId:$hostUri:$hostDevice',
    );
    if (failGroupPlacement) {
      return const GroupCallPlacement(
        conferenceId: '',
        callId: '',
        hosting: false,
      );
    }
    return GroupCallPlacement(
      conferenceId: conferenceId,
      callId: nextGroupPlacement.callId,
      hosting: hostUri.isEmpty,
    );
  }

  @override
  Future<bool> leaveGroupCall(
    String conferenceId, {
    String reservationId = '',
  }) async {
    calls.add('leaveGroupCall:$conferenceId');
    return true;
  }

  @override
  Future<bool> setGroupMicMuted(String conferenceId, bool muted) async {
    calls.add('setGroupMicMuted:$conferenceId:$muted');
    return true;
  }

  @override
  Future<bool> setGroupDeafened(String conferenceId, bool deafened) async {
    calls.add('setGroupDeafened:$conferenceId:$deafened');
    return true;
  }

  @override
  Future<bool> setGroupConferenceLayout(String conferenceId, int layout) async {
    calls.add('setGroupConferenceLayout:$conferenceId:$layout');
    return true;
  }

  @override
  Future<bool> setGroupActiveStream(
    String conferenceId,
    GroupConferenceStream stream,
    bool active,
  ) async {
    calls.add('setGroupActiveStream:$conferenceId:${stream.key}:$active');
    return true;
  }

  @override
  Future<bool> muteGroupParticipant(
    String conferenceId,
    GroupConferenceStream stream,
    bool muted,
  ) async {
    calls.add('muteGroupParticipant:$conferenceId:${stream.key}:$muted');
    return true;
  }

  @override
  Future<bool> disconnectGroupParticipant(
    String conferenceId,
    GroupConferenceStream stream,
  ) async {
    calls.add('disconnectGroupParticipant:$conferenceId:${stream.key}');
    return true;
  }

  @override
  Future<bool> publishGroupCallPresence(
    String conversationId,
    String payload,
  ) async {
    calls.add('publishGroupCallPresence:$conversationId');
    groupPresencePayloads.add(payload);
    return true;
  }

  @override
  Future<void> answerCall(
    String callId, {
    bool initialAudioMuted = false,
  }) async {
    lastAnsweredInitialAudioMuted = initialAudioMuted;
    calls.add('answer:$callId');
  }

  @override
  Future<void> hangUp(String callId) async {
    calls.add('hangUp:$callId');
    await pendingHangUp?.future;
  }

  @override
  Future<void> refuse(String callId) async {
    calls.add('refuse:$callId');
    await pendingRefuse?.future;
  }

  @override
  Future<int> createVideoTexture(String role) async {
    textureCalls++;
    return pendingTexture?.future ?? textureCalls;
  }

  @override
  Future<void> switchCamera(String callId) async => calls.add('switchCamera');

  @override
  Future<bool> startVideo(String callId) async {
    startVideoCalls++;
    calls.add('startVideo:$callId');
    return pendingStartVideo?.future ?? true;
  }

  @override
  Future<bool> stopVideo(String callId) async {
    calls.add('stopVideo:$callId');
    return pendingStopVideo?.future ?? stopVideoResult;
  }

  @override
  Future<bool> setOutgoingVideoSource(
    String callId,
    OutgoingVideoKind kind, {
    String? sourceId,
  }) async {
    calls.add('source:$callId:${kind.name}:${sourceId ?? ''}');
    return pendingScreenVideo?.future ?? true;
  }

  @override
  Future<List<ScreenSource>> listScreenSources(String callId) async =>
      pendingScreenSources?.future ?? const [];

  @override
  Future<bool> sendCallMessage(
    String callId,
    String jsonPayload, {
    String channel = 'annotation',
  }) async {
    sentCallMessages.add(jsonPayload);
    return true;
  }

  @override
  Future<bool> acceptFile(
    String peerJamiId,
    String conversationId,
    String interactionId,
    String fileId,
    String name, {
    int maxBytes = 0,
    String attemptId = '',
  }) async {
    receiveAttempts[(peerJamiId, conversationId, fileId)] = attemptId;
    acceptFileCalls++;
    lastAcceptMaxBytes = maxBytes;
    if (throwAcceptFile) throw StateError('accept failed');
    return pendingAcceptFile?.future ?? true;
  }

  @override
  Future<String?> pickFile({
    String mimeType = '*/*',
    int maxBytes = JamiClient.maxPickedFileBytes,
  }) async {
    pickFileCalls++;
    lastPickMaxBytes = maxBytes;
    return 'picked.txt';
  }

  @override
  Future<void> discardPickedFile(String path) async {
    discardedPickedFiles.add(path);
  }

  @override
  Future<bool> backupIdentity(
    String passphrase, {
    String settingsDocument = '',
    String? expectedAccountId,
  }) async {
    lastBackupPassphrase = passphrase;
    lastBackupSettingsDocument = settingsDocument;
    return true;
  }

  @override
  Future<Map<String, dynamic>> restoreIdentity(
    String filePath,
    String passphrase, {
    String connectionProfile = 'jami',
    String dhtBootstrap = '',
    String turnServer = '',
    String turnRealm = '',
    String turnUser = '',
    String turnPassword = '',
    bool appearOffline = false,
    String? expectedAccountId,
    String expectedJamiId = '',
  }) async {
    lastRestoreArguments = {
      'filePath': filePath,
      'passphrase': passphrase,
      'connectionProfile': connectionProfile,
      'dhtBootstrap': dhtBootstrap,
      'turnServer': turnServer,
      'turnRealm': turnRealm,
      'turnUser': turnUser,
      'turnPassword': turnPassword,
      'appearOffline': appearOffline,
      'expectedJamiId': expectedJamiId,
    };
    final result =
        restoreResult ??
        <String, dynamic>{
          'status': 'ok',
          'accountId': 'restored-account',
          'jamiId': 'e' * 40,
          'displayName': 'Restored',
          'avatarBase64': '',
          'enabled': !appearOffline,
          'announced': false,
          'registration': 'UNREGISTERED',
        };
    if (result['status'] == 'ok') {
      pendingRestoreFinalResult = result;
      pendingIdentityRestore = {
        ...result,
        'status': 'prepared',
        'restoreToken': 'synthetic-restore-token',
        'enabled': false,
        'announced': false,
      };
      return pendingIdentityRestore!;
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> getPendingIdentityRestore() async =>
      pendingIdentityRestore ?? {'status': 'none'};

  @override
  Future<Map<String, dynamic>> finalizeIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String settingsDocument,
  }) async {
    restoreFinalizations++;
    finalizedRestoreDocument = settingsDocument;
    final result = pendingRestoreFinalResult;
    if (result == null ||
        result['accountId'] != accountId ||
        restoreToken != 'synthetic-restore-token') {
      return {'status': 'error'};
    }
    pendingIdentityRestore = null;
    pendingRestoreFinalResult = null;
    if (result['status'] == 'ok') {
      accountExists = true;
      this.accountId = result['accountId'] is String
          ? result['accountId'] as String
          : accountId;
      accountJamiId = result['jamiId'] is String
          ? result['jamiId'] as String
          : accountJamiId;
      accountDisplayName = result['displayName'] is String
          ? result['displayName'] as String
          : accountDisplayName;
      accountAvatarBase64 = result['avatarBase64'] is String
          ? result['avatarBase64'] as String
          : '';
      accountEnabled = result['enabled'] is bool
          ? result['enabled'] as bool
          : accountEnabled;
      accountAnnounced = result['announced'] is bool
          ? result['announced'] as bool
          : accountAnnounced;
      accountRegistration = result['registration'] is String
          ? result['registration'] as String
          : accountRegistration;
    }
    return result;
  }

  @override
  Future<bool> updateProfile({
    required String displayName,
    required String avatarBase64,
    required String fileType,
    required int flag,
    String? expectedAccountId,
  }) async {
    lastProfileDisplayName = displayName;
    lastProfileAvatar = avatarBase64;
    lastProfileFileType = fileType;
    lastProfileFlag = flag;
    return profileUpdateResult;
  }

  @override
  Future<bool> sendFile(
    String peerJamiId,
    String conversationId,
    String path, {
    String? name,
    String topicId = '',
  }) async {
    sendFileCalls++;
    lastSendFilePeer = peerJamiId;
    lastSendFileConversation = conversationId;
    lastSendFileTopicId = topicId;
    if (throwSendFile) throw StateError('send failed');
    return sendFileResult;
  }

  @override
  Future<bool> cancelFile(
    String peerJamiId,
    String conversationId,
    String fileId, {
    String attemptId = '',
  }) async {
    calls.add('cancelFile:$fileId');
    if (throwCancelFile) throw StateError('cancel failed');
    return pendingCancelFile?.future ?? cancelFileResult;
  }

  @override
  Future<Map<String, dynamic>> fileInfo(
    String peerJamiId,
    String conversationId,
    String fileId,
  ) async {
    fileInfoCalls++;
    if (fileInfoStarted != null && !fileInfoStarted!.isCompleted) {
      fileInfoStarted!.complete();
    }
    return pendingFileInfo?.future ?? <String, dynamic>{};
  }
}

const peer =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; // a well-formed 40-hex Jami ID
const stranger = 'cccccccccccccccccccccccccccccccccccccccc';
const otherFriend = 'dddddddddddddddddddddddddddddddddddddddd';
const peerConversation = 'conv-peer';
const strangerConversation = 'conv-$stranger';

TransferKey _keyFor(String fileId) =>
    (peerId: peer, conversationId: peerConversation, fileId: fileId);

FileXfer? _transferFor(AppState state, String fileId) =>
    state.transfers[_keyFor(fileId)];

FolderFile? _folderFileFor(AppState state, String fileId) =>
    state.folder[_keyFor(fileId)];

Map<String, Object?> _textWire({
  required String ownerPeer,
  required String conversationId,
  required String daemonId,
  required String authorId,
  required String text,
  String? versionId,
  String? operation,
  String topicId = DmTopicWire.mainId,
  bool topicTagged = false,
}) => {
  'accountId': 'acc1',
  'peerId': ownerPeer,
  'conversationId': conversationId,
  'daemonId': daemonId,
  'versionId': versionId ?? daemonId,
  'mimeType': 'text/plain',
  'authorId': authorId,
  'timestampSeconds': 1700000000,
  'body': text,
  'operation': ?operation,
  'topicId': topicId,
  'topicTagged': topicTagged,
};

Map<String, Object?> _dmTopicEventWire({
  required String commitId,
  required String authorId,
  required DmTopicEvent event,
}) => {
  'commitId': commitId,
  'authorId': authorId,
  'mimeType': DmTopicWire.mimeType,
  'topicId': DmTopicWire.mainId,
  'linearizedParent': '',
  'eventBody': DmTopicEventCodec.encode(event),
};

Map<String, Object?> _dmTopicItemWire({
  required String commitId,
  required String authorId,
  required String topicId,
  bool topicTagged = true,
  bool daemonRead = false,
}) => {
  'commitId': commitId,
  'authorId': authorId,
  'mimeType': TimelineWireContract.textMimeType,
  'topicId': topicId,
  'topicTagged': topicTagged,
  'daemonRead': daemonRead,
  'linearizedParent': '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeJami jami;
  late AppState state;
  var booted = false;

  Future<void> boot(
    Map<String, Object> prefs, {
    void Function(FakeJami jami)? configure,
    bool selectAfterBoot = true,
  }) async {
    final selectedGroup = prefs['selectedGroupId'];
    final selectedPeer = prefs['selectedFriendId'] ?? prefs['peerId'];
    SharedPreferences.setMockInitialValues(prefs);
    jami = FakeJami();
    jami.accountExists =
        prefs.containsKey('displayName') || prefs.containsKey('accountId');
    configure?.call(jami);
    state = AppState(jami, await SharedPreferences.getInstance());
    await state.init();
    if (selectAfterBoot) {
      if (selectedGroup is String) {
        await state.selectGroup(selectedGroup);
      } else if (selectedPeer is String) {
        await state.selectFriend(selectedPeer);
      }
    }
    booted = true;
  }

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    if (booted) state.dispose();
    booted = false;
  });

  test(
    'friend colors never change the local default and manual choices stay fixed',
    () async {
      await boot({
        'displayName': 'Me',
        'peerId': peer,
      }, configure: (fake) => fake.accountJamiId = 'f' * 40);
      final initial = state.identityColor;
      void announce(IdentityColor color, int stamp, int foreground) =>
          jami.push('presenceMsg', {
            'fromJamiId': peer,
            'v': 2,
            't': 'ping',
            'fg': foreground,
            'ts': stamp,
            'platform': 'android',
            'activity': '',
            'color': color.storageValue,
          });
      announce(initial, 30, 1);
      final calibrated = state.identityColor;
      expect(calibrated, initial);
      announce(initial, 31, 0);
      expect(state.identityColor, calibrated);
      state.remoteControl.phase = RemoteControlPhase.requesting;
      announce(calibrated, 32, 1);
      expect(state.identityColor, calibrated);
      expect(await state.setIdentityColor(IdentityColor.sky), isFalse);
      state.remoteControl.phase = RemoteControlPhase.idle;
      announce(IdentityColor.blue, 33, 1);
      expect(state.identityColor, initial);
      expect(await state.setIdentityColor(IdentityColor.sky), isTrue);
      announce(IdentityColor.sky, 34, 1);
      expect(state.identityColor, IdentityColor.sky);
      expect(state.appSettings.identityColorManual, isTrue);
      await pumpEventQueue();
      expect(jami.presenceMetadataCalls.last.color, 'sky');
    },
  );

  test('fresh device (no account anywhere) lands on onboarding', () async {
    await boot({});
    expect(state.screen, Screen.onboarding);
    expect(jami.lastEnsureCreateIfMissing, isFalse);
    expect(jami.accountExists, isFalse);
  });

  test('a stale display-name hint cannot create an account at boot', () async {
    await boot({
      'displayName': 'Stale local hint',
    }, configure: (fake) => fake.accountExists = false);

    expect(state.screen, Screen.onboarding);
    expect(state.bootError, isNull);
    expect(jami.lastEnsureCreateIfMissing, isFalse);
    expect(jami.accountExists, isFalse);
  });

  test('invalid persisted connection profiles self-heal to jami', () async {
    await boot({'connectionProfile': 'surprise'});

    expect(state.connectionProfile, 'jami');
    expect(state.prefs.getString('connectionProfile'), 'jami');
  });

  test('unknown peers never fall back to a transport identifier', () async {
    await boot({});
    expect(state.peerDisplayName(peer), 'Your friend');
  });

  test('the local group participant uses the local display name', () async {
    await boot({'displayName': 'Peer'});

    expect(state.peerDisplayName(state.jamiId), 'Peer');
  });

  test('a new direct message has implicit main and no topic row', () async {
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
      },
    );
    await pumpEventQueue();

    expect(state.selectedConversationScope, isNotNull);
    expect(state.selectedDmTopicState, isNotNull);
    expect(state.selectedDmTopicState!.customTopics, isEmpty);
    expect(state.selectedDmTopicId, DmTopicWire.mainId);
    expect(state.dmTopicRowVisible, isFalse);
    expect(
      jami.calls.where((call) => call.startsWith('loadDmTopicState:')),
      hasLength(1),
    );
  });

  test('a linked device rebuilds shared topics from signed history', () async {
    const topicId = '0123456789abcdef0123456789abcdef';
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        fake.dmTopicHistory[peerConversation] = [
          _dmTopicEventWire(
            commitId: 'create-vacation',
            authorId: peer,
            event: const DmTopicEvent.create(
              topicId: topicId,
              revision: 1,
              name: 'vacation',
              order: 0,
            ),
          ),
        ];
      },
    );
    await pumpEventQueue();

    expect(state.dmTopicRowVisible, isTrue);
    expect(
      state.selectedDmTopicState?.visibleTopics(localMemberId: state.jamiId),
      [
        DmTopic.main,
        isA<DmTopic>()
            .having((topic) => topic.id, 'id', topicId)
            .having((topic) => topic.name, 'name', 'vacation'),
      ],
    );
  });

  test(
    'legacy daemon-displayed main stays read after the first topic',
    () async {
      const topicId = '0123456789abcdef0123456789abcdef';
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
          fake.dmTopicHistory[peerConversation] = [
            _dmTopicEventWire(
              commitId: 'create-vacation',
              authorId: peer,
              event: const DmTopicEvent.create(
                topicId: topicId,
                revision: 1,
                name: 'vacation',
                order: 0,
              ),
            ),
            _dmTopicItemWire(
              commitId: 'old-main-message',
              authorId: peer,
              topicId: DmTopicWire.mainId,
              topicTagged: false,
              daemonRead: true,
            ),
          ];
        },
      );
      await pumpEventQueue();

      expect(state.selectedDmTopicUnreadByTopic[DmTopicWire.mainId], 0);
      expect(state.friendActivity(peer).unreadTotal, 0);
    },
  );

  test('an unresolved topic introduction returns after app restart', () async {
    await boot(
      {
        'displayName': 'Me',
        'selectedFriendId': peer,
        'dmTopicIntroductionPendingV1': true,
        'dmTopicIntroductionConversationV1': peerConversation,
      },
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
      },
    );
    await pumpEventQueue();

    expect(state.dmTopicIntroduction, DmTopicIntroduction.suggestion);
    expect(state.prefs.getBool('dmTopicIntroductionUnderstoodV1'), isNull);
  });

  for (final owner in [null, 'another-conversation']) {
    test(
      'topic introduction does not cross conversation ownership: $owner',
      () async {
        await boot(
          {
            'displayName': 'Me',
            'selectedFriendId': peer,
            'dmTopicIntroductionPendingV1': true,
            'dmTopicIntroductionConversationV1': ?owner,
          },
          configure: (fake) {
            fake.daemonFriends[peer] = const JamiFriend(
              peerJamiId: peer,
              confirmed: true,
              conversationId: peerConversation,
            );
          },
        );
        await pumpEventQueue();
        expect(state.dmTopicIntroduction, DmTopicIntroduction.none);
      },
    );
  }

  test('dismissing topic help does not mark it understood', () async {
    await boot(
      {
        'displayName': 'Me',
        'selectedFriendId': peer,
        'dmTopicIntroductionPendingV1': true,
        'dmTopicIntroductionConversationV1': peerConversation,
      },
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
      },
    );
    await pumpEventQueue();
    expect(state.dmTopicIntroduction, DmTopicIntroduction.suggestion);
    state.showDmTopicIntroductionPreview();
    await state.dismissDmTopicIntroduction();
    expect(state.dmTopicIntroduction, DmTopicIntroduction.none);
    expect(state.prefs.getBool('dmTopicIntroductionUnderstoodV1'), isNull);
    expect(state.prefs.getBool('dmTopicIntroductionPendingV1'), isFalse);
    expect(state.prefs.getString('dmTopicIntroductionConversationV1'), isNull);
  });

  test(
    'loading a topic-enabled DM suppresses automatic introduction',
    () async {
      const topicId = '0123456789abcdef0123456789abcdef';
      await boot(
        {
          'displayName': 'Me',
          'selectedFriendId': peer,
          'dmTopicIntroductionPendingV1': true,
        },
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
          fake.dmTopicHistory[peerConversation] = [
            _dmTopicEventWire(
              commitId: 'create-vacation',
              authorId: peer,
              event: const DmTopicEvent.create(
                topicId: topicId,
                revision: 1,
                name: 'vacation',
                order: 0,
              ),
            ),
          ];
        },
      );
      await pumpEventQueue();

      expect(state.dmTopicIntroduction, DmTopicIntroduction.none);
      expect(state.prefs.getBool('dmTopicIntroductionUnderstoodV1'), isTrue);
      expect(state.prefs.getBool('dmTopicIntroductionPendingV1'), isFalse);
    },
  );

  test(
    'settings replay does not change automatic introduction state',
    () async {
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
        },
      );
      await pumpEventQueue();

      state.showDmTopicIntroduction();
      expect(state.dmTopicIntroduction, DmTopicIntroduction.preview);
      await state.finishDmTopicIntroduction();
      expect(state.dmTopicIntroduction, DmTopicIntroduction.none);
      expect(state.prefs.getBool('dmTopicIntroductionUnderstoodV1'), isNull);
      expect(state.prefs.getBool('dmTopicIntroductionPendingV1'), isNull);
    },
  );

  test(
    'topic selection filters text and persists only local navigation',
    () async {
      const topicId = '0123456789abcdef0123456789abcdef';
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
          fake.dmTopicHistory[peerConversation] = [
            _dmTopicEventWire(
              commitId: 'create-vacation',
              authorId: peer,
              event: const DmTopicEvent.create(
                topicId: topicId,
                revision: 1,
                name: 'vacation',
                order: 0,
              ),
            ),
          ];
          fake.chatHistory[peerConversation] = [
            _textWire(
              ownerPeer: peer,
              conversationId: peerConversation,
              daemonId: 'custom-message',
              authorId: peer,
              text: 'custom',
              topicId: topicId,
              topicTagged: true,
            ),
            _textWire(
              ownerPeer: peer,
              conversationId: peerConversation,
              daemonId: 'legacy-message',
              authorId: peer,
              text: 'legacy',
            ),
          ];
        },
      );
      await pumpEventQueue();

      expect(
        state.selectedDmTopicItems.whereType<TimelineTextItem>().map(
          (item) => item.text,
        ),
        ['legacy'],
      );
      expect(await state.selectDmTopic(topicId), isTrue);
      expect(
        state.selectedDmTopicItems.whereType<TimelineTextItem>().map(
          (item) => item.text,
        ),
        ['custom'],
      );
      expect(
        state.prefs.getString('dmTopicLastSelectionsV1'),
        contains(topicId),
      );
      expect(jami.sentDmTopicEvents, isEmpty);

      expect(await state.sendText('in custom'), isTrue);
      await state.sendFile();
      expect(jami.lastChatTopicId, topicId);
      expect(jami.lastSendFileTopicId, topicId);
    },
  );

  test('unknown signed topic is retained but never shown in main', () async {
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        fake.chatHistory[peerConversation] = [
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'quarantined',
            authorId: peer,
            text: 'waiting for topic creation',
            topicId: '0123456789abcdef0123456789abcdef',
            topicTagged: true,
          ),
        ];
      },
    );
    await pumpEventQueue();
    expect(
      state.conversationItems.map((item) => item.daemonId),
      contains('quarantined'),
    );
    expect(state.selectedDmTopicItems, isEmpty);
    state.setConversationVisible(peer, dmTopicId: DmTopicWire.mainId);
    await pumpEventQueue();
    expect(jami.displayedMessages, isEmpty);
  });

  test(
    'restart reconciles exact outgoing operation from signed history',
    () async {
      final operationId = 'b' * 32;
      await boot(
        {
          'displayName': 'Me',
          'selectedFriendId': peer,
          SendJournal.preferenceKey: jsonEncode({
            'v': 1,
            'operations': [
              {
                'operationId': operationId,
                'scope': {
                  'accountId': 'acc1',
                  'peerId': peer,
                  'conversationId': peerConversation,
                  'kind': 'direct',
                },
                'status': 'pending',
                'commitId': null,
                'stage': null,
              },
            ],
          }),
        },
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
          fake.chatHistory[peerConversation] = [
            {
              ..._textWire(
                ownerPeer: peer,
                conversationId: peerConversation,
                daemonId: 'committed-before-restart',
                authorId: fake.accountJamiId,
                text: 'sent',
              ),
              'operationId': operationId,
            },
          ];
        },
      );
      await pumpEventQueue();
      expect(
        state.sendJournal.record(operationId)!.status,
        ComposerSendStatus.committed,
      );
      expect(
        state.sendJournal.record(operationId)!.commitId,
        'committed-before-restart',
      );
      expect(
        jami.calls.where((call) => call.startsWith('sendChatMessage')),
        isEmpty,
      );
    },
  );

  test(
    'create rename and personal archive commit exact topic events',
    () async {
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
        },
      );
      await pumpEventQueue();

      expect(await state.createDmTopic('  vacation  '), isTrue);
      final topicId = state.selectedDmTopicId;
      expect(DmTopicWire.isCustomId(topicId), isTrue);
      expect(state.selectedDmTopicState?.topic(topicId)?.name, 'vacation');
      expect(
        DmTopicEventCodec.decode(jami.sentDmTopicEvents.single.body),
        DmTopicEvent.create(
          topicId: topicId,
          revision: 1,
          name: 'vacation',
          order: 0,
        ),
      );

      jami.nextDmTopicCommitId = 'topic-commit-2';
      expect(await state.renameDmTopic(topicId, 'summer trip'), isTrue);
      expect(state.selectedDmTopicState?.topic(topicId)?.name, 'summer trip');
      expect(
        DmTopicEventCodec.decode(jami.sentDmTopicEvents.last.body),
        DmTopicEvent.rename(topicId: topicId, revision: 1, name: 'summer trip'),
      );

      jami.nextDmTopicCommitId = 'topic-commit-3';
      expect(await state.setDmTopicArchived(topicId, true), isTrue);
      expect(state.selectedDmTopicId, topicId);
      expect(
        state.selectedDmTopicState?.topic(topicId)?.archivedBy,
        contains(state.jamiId),
      );
      expect(
        DmTopicEventCodec.decode(jami.sentDmTopicEvents.last.body),
        DmTopicEvent.archive(topicId: topicId, revision: 1, archived: true),
      );

      expect(await state.createDmTopic('main'), isFalse);
      expect(jami.sentDmTopicEvents, hasLength(3));
    },
  );

  test(
    'composer result switches chats and selects the requested topic',
    () async {
      const other = 'cccccccccccccccccccccccccccccccccccccccc';
      const otherConversation = 'other-conversation';
      const topicId = '0123456789abcdef0123456789abcdef';
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.daemonFriends
            ..[peer] = const JamiFriend(
              peerJamiId: peer,
              confirmed: true,
              conversationId: peerConversation,
              displayName: 'Phone B',
            )
            ..[other] = const JamiFriend(
              peerJamiId: other,
              confirmed: true,
              conversationId: otherConversation,
              displayName: 'Phone A',
            );
          fake.dmTopicHistory[otherConversation] = [
            _dmTopicEventWire(
              commitId: 'create-vacation',
              authorId: other,
              event: const DmTopicEvent.create(
                topicId: topicId,
                revision: 1,
                name: 'vacation',
                order: 0,
              ),
            ),
          ];
        },
      );
      await pumpEventQueue();

      final query = state.resolveComposerQuery('/vacation');
      final result = query.results.single;
      expect(result.showChatIdentity, isTrue);
      expect(result.chatDisplayName, 'Phone A');

      expect(await state.executeComposerResult(result), isTrue);
      expect(state.peerId, other);
      expect(state.selectedDmTopicId, topicId);
    },
  );

  test('composer create action commits and does not send slash text', () async {
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
      },
    );
    await pumpEventQueue();

    const result = ComposerResult(
      kind: ComposerResultKind.createTopic,
      label: 'Create vacation',
      topicName: 'vacation',
      showActionIcon: true,
    );
    expect(await state.executeComposerResult(result), isTrue);
    expect(state.selectedDmTopicState?.customTopics.single.name, 'vacation');
    expect(jami.lastChatBody, isNull);
  });

  test('visible topic reads only its rendered incoming frontier', () async {
    const topicId = '0123456789abcdef0123456789abcdef';
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        fake.dmTopicHistory[peerConversation] = [
          _dmTopicItemWire(
            commitId: 'topic-message',
            authorId: peer,
            topicId: topicId,
          ),
          _dmTopicItemWire(
            commitId: 'main-message',
            authorId: peer,
            topicId: DmTopicWire.mainId,
            topicTagged: false,
          ),
          _dmTopicEventWire(
            commitId: 'create-vacation',
            authorId: peer,
            event: const DmTopicEvent.create(
              topicId: topicId,
              revision: 1,
              name: 'vacation',
              order: 0,
            ),
          ),
        ];
        fake.chatHistory[peerConversation] = [
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'topic-message',
            authorId: peer,
            text: 'topic',
            topicId: topicId,
            topicTagged: true,
          ),
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'main-message',
            authorId: peer,
            text: 'main',
            topicId: DmTopicWire.mainId,
            topicTagged: false,
          ),
        ];
      },
    );
    await pumpEventQueue();

    expect(state.selectedDmTopicUnreadByTopic, {
      DmTopicWire.mainId: 1,
      topicId: 1,
    });
    expect(state.friendActivity(peer).unreadTotal, 2);
    state.setConversationVisible(peer, dmTopicId: DmTopicWire.mainId);
    await pumpEventQueue();

    expect(jami.displayedMessages, [
      (
        peerId: peer,
        conversationId: peerConversation,
        messageId: 'main-message',
      ),
    ]);
    expect(jami.sentDmTopicEvents, hasLength(1));
    expect(
      DmTopicEventCodec.decode(jami.sentDmTopicEvents.single.body),
      const DmTopicEvent.read(
        topicId: DmTopicWire.mainId,
        revision: 1,
        messageId: 'main-message',
      ),
    );
    expect(state.selectedDmTopicUnreadByTopic, {
      DmTopicWire.mainId: 0,
      topicId: 1,
    });
    expect(state.friendActivity(peer).unreadTotal, 1);

    jami.nextDmTopicCommitId = 'topic-read-2';
    expect(await state.selectDmTopic(topicId), isTrue);
    await pumpEventQueue();
    expect(jami.sentDmTopicEvents, hasLength(1));

    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.setConversationVisible(peer, dmTopicId: topicId);
    await pumpEventQueue();
    expect(jami.sentDmTopicEvents, hasLength(1));

    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(jami.sentDmTopicEvents, hasLength(1));

    state.setConversationVisible(peer, dmTopicId: topicId);
    await pumpEventQueue();
    expect(jami.sentDmTopicEvents, hasLength(2));
    expect(state.selectedDmTopicUnreadByTopic[topicId], 0);
    expect(state.friendActivity(peer).unreadTotal, 0);
  });

  test('a restored topic read frontier is not committed again', () async {
    const topicId = '0123456789abcdef0123456789abcdef';
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        fake.dmTopicHistory[peerConversation] = [
          _dmTopicEventWire(
            commitId: 'existing-read',
            authorId: fake.accountJamiId,
            event: const DmTopicEvent.read(
              topicId: topicId,
              revision: 1,
              messageId: 'already-read-message',
            ),
          ),
          _dmTopicItemWire(
            commitId: 'already-read-message',
            authorId: peer,
            topicId: topicId,
          ),
          _dmTopicEventWire(
            commitId: 'create-vacation',
            authorId: peer,
            event: const DmTopicEvent.create(
              topicId: topicId,
              revision: 1,
              name: 'vacation',
              order: 0,
            ),
          ),
        ];
        fake.chatHistory[peerConversation] = [
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'already-read-message',
            authorId: peer,
            text: 'already read',
            topicId: topicId,
            topicTagged: true,
          ),
        ];
      },
    );
    await pumpEventQueue();

    expect(await state.selectDmTopic(topicId), isTrue);
    state.setConversationVisible(peer, dmTopicId: topicId);
    await pumpEventQueue();

    expect(state.selectedDmTopicUnreadByTopic[topicId], 0);
    expect(jami.sentDmTopicEvents, isEmpty);
  });

  test('hidden Windows window cannot read a visible DM topic', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const topicId = '0123456789abcdef0123456789abcdef';
    await boot(
      {'displayName': 'Me', 'selectedFriendId': peer},
      configure: (fake) {
        fake.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        fake.dmTopicHistory[peerConversation] = [
          _dmTopicEventWire(
            commitId: 'create-vacation',
            authorId: peer,
            event: const DmTopicEvent.create(
              topicId: topicId,
              revision: 1,
              name: 'vacation',
              order: 0,
            ),
          ),
        ];
        fake.chatHistory[peerConversation] = [
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'hidden-topic-message',
            authorId: peer,
            text: 'arrived while hidden',
            topicId: topicId,
            topicTagged: true,
          ),
        ];
      },
    );
    await pumpEventQueue();
    expect(await state.selectDmTopic(topicId), isTrue);
    state.didChangeViewFocus(
      const ViewFocusEvent(
        viewId: 0,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    state.setConversationVisible(peer, dmTopicId: topicId);
    await pumpEventQueue();
    expect(jami.sentDmTopicEvents, isEmpty);

    state.didChangeViewFocus(
      const ViewFocusEvent(
        viewId: 0,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await pumpEventQueue();
    expect(jami.sentDmTopicEvents, hasLength(1));
    expect(
      DmTopicEventCodec.decode(jami.sentDmTopicEvents.single.body),
      const DmTopicEvent.read(
        topicId: topicId,
        revision: 1,
        messageId: 'hidden-topic-message',
      ),
    );
  });

  test('a cold message notification opens its exact conversation', () async {
    await boot(
      {'displayName': 'Me'},
      selectAfterBoot: false,
      configure: (jami) {
        jami.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        jami.initialConversation = const ConversationLaunchTarget(
          ownerKey: peer,
          conversationId: peerConversation,
        );
      },
    );

    expect(state.peerId, peer);
    expect(jami.dismissedMessageNotifications, contains(peerConversation));
  });

  test(
    'unknown topic text produces no main unread activity sound or read',
    () async {
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
        },
      );
      state.setConversationVisible(peer);
      final sounds = <SyblSoundEvent>[];
      final subscription = state.soundEvents.listen(sounds.add);
      addTearDown(subscription.cancel);
      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': peer,
        'conversationId': peerConversation,
        'item': _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'quarantined-message',
          authorId: peer,
          text: 'quarantined',
          topicId: '0123456789abcdef0123456789abcdef',
          topicTagged: true,
        ),
      });
      await pumpEventQueue();
      expect(state.selectedDmTopicItems, isEmpty);
      expect(state.friendActivity(peer).unreadTotal, 0);
      expect(state.friendActivity(peer).lastActivityAt, isNull);
      expect(sounds, isEmpty);
      expect(jami.displayedMessages, isEmpty);
    },
  );

  test(
    'notification authorization cannot resume after navigation A-B-A',
    () async {
      await boot(
        {'displayName': 'Me', 'selectedFriendId': peer},
        configure: (fake) {
          fake.accountRegistration = 'REGISTERED';
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
          fake.daemonFriends[otherFriend] = const JamiFriend(
            peerJamiId: otherFriend,
            confirmed: true,
            conversationId: 'other-conversation',
          );
        },
      );
      final authorization = Completer<bool>();
      jami.pendingConversationAuthorization = authorization;
      jami.push('openConversation', {
        'accountId': 'acc1',
        'actionToken': 'a' * 64,
        'ownerKey': peer,
        'conversationId': peerConversation,
        'startCall': true,
      });
      await pumpEventQueue();
      expect(jami.conversationAuthorizations, 1);
      await state.selectFriend(otherFriend);
      await state.selectFriend(peer);
      authorization.complete(true);
      await pumpEventQueue();
      expect(state.peerId, peer);
      expect(jami.lastPlacedPeer, isNull);
    },
  );

  test('a call notification action opens the DM and starts a call', () async {
    await boot(
      {'displayName': 'Me'},
      selectAfterBoot: false,
      configure: (jami) {
        jami.accountRegistration = 'REGISTERED';
        jami.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        jami.initialConversation = const ConversationLaunchTarget(
          ownerKey: peer,
          conversationId: peerConversation,
          startCall: true,
        );
      },
    );

    expect(state.peerId, peer);
    expect(jami.lastPlacedPeer, peer);
  });

  test('notify call request sends no call', () async {
    await boot(
      {'displayName': 'Me'},
      configure: (jami) {
        jami.accountRegistration = 'REGISTERED';
        jami.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
      },
    );

    expect(await state.notifyCallRequest(peer), isTrue);
    expect(jami.callRequestPeers, [peer]);
    expect(jami.lastPlacedPeer, isNull);
  });

  test('a cold message notification opens its exact DM topic', () async {
    const topicId = '0123456789abcdef0123456789abcdef';
    await boot(
      {'displayName': 'Me'},
      selectAfterBoot: false,
      configure: (jami) {
        jami.daemonFriends[peer] = const JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: peerConversation,
        );
        jami.dmTopicHistory[peerConversation] = [
          _dmTopicEventWire(
            commitId: 'create-vacation',
            authorId: peer,
            event: const DmTopicEvent.create(
              topicId: topicId,
              revision: 1,
              name: 'vacation',
              order: 0,
            ),
          ),
        ];
        jami.initialConversation = const ConversationLaunchTarget(
          ownerKey: peer,
          conversationId: peerConversation,
          topicId: topicId,
        );
      },
    );
    await pumpEventQueue();

    expect(state.peerId, peer);
    expect(state.selectedDmTopicId, topicId);
    expect(jami.dismissedMessageNotifications, contains(peerConversation));
  });

  test('message preview setting persists and applies to Android', () async {
    await boot({'displayName': 'Me'});
    expect(jami.messagePreviewCalls, contains(true));
    expect(jami.messageAppLockCalls.last, isFalse);

    expect(await state.setShowMessageInNotification(false), isTrue);

    expect(state.showMessageInNotification, isFalse);
    expect(jami.messagePreviewCalls.last, isFalse);
    expect(jami.messageAppLockCalls.last, isFalse);
  });

  test(
    'background wake applies only to Jami and keeps the saved choice',
    () async {
      await boot({'displayName': 'Me'});

      expect(state.reliableBackgroundNotifications, isFalse);
      expect(state.effectiveReliableBackgroundNotifications, isFalse);
      expect(jami.backgroundWakeCalls.last, (enabled: false, profile: 'jami'));
      expect(await state.setReliableBackgroundNotifications(true), isTrue);
      expect(state.reliableBackgroundNotifications, isTrue);
      expect(state.effectiveReliableBackgroundNotifications, isTrue);
      expect(jami.backgroundWakeCalls.last, (enabled: true, profile: 'jami'));

      await state.setConnectionProfile('lan');

      expect(state.reliableBackgroundNotifications, isTrue);
      expect(state.effectiveReliableBackgroundNotifications, isFalse);
      expect(jami.backgroundWakeCalls.last, (enabled: false, profile: 'lan'));
    },
  );

  test(
    'a failed wake apply keeps the saved choice and reports inactive',
    () async {
      await boot({'displayName': 'Me'});
      expect(await state.setReliableBackgroundNotifications(false), isTrue);
      jami.backgroundWakeApplyResult = false;

      expect(await state.setReliableBackgroundNotifications(true), isFalse);

      expect(state.reliableBackgroundNotifications, isTrue);
      expect(state.effectiveReliableBackgroundNotifications, isFalse);
      expect(state.settingsError, contains('could not be activated'));
    },
  );

  test('restored settings cannot grant installation Google consent', () async {
    await boot({'displayName': 'Me'});
    expect(await state.setReliableBackgroundNotifications(true), isTrue);
    final imported = <String, Object>{
      for (final key in state.prefs.getKeys())
        if (key != 'googleWakeConsent.v1') key: state.prefs.get(key)!,
    };
    state.dispose();
    booted = false;
    await boot(imported);
    expect(state.appSettings.reliableBackgroundNotifications, isTrue);
    expect(state.googleWakeAllowed, isFalse);
    expect(state.reliableBackgroundNotifications, isFalse);
    expect(state.effectiveReliableBackgroundNotifications, isFalse);
    expect(jami.backgroundWakeCalls.last.enabled, isFalse);
  });

  test('withdrawal failure exposes retry without restoring consent', () async {
    await boot({'displayName': 'Me'});
    expect(await state.setReliableBackgroundNotifications(true), isTrue);
    jami.backgroundWakeApplyResult = false;
    expect(await state.setReliableBackgroundNotifications(false), isFalse);
    expect(state.googleWakeAllowed, isFalse);
    expect(state.googleWakeCleanupPending, isTrue);
    expect(state.settingsError, contains('cleanup is unfinished'));
    jami.backgroundWakeApplyResult = true;
    expect(await state.setReliableBackgroundNotifications(false), isTrue);
    expect(state.googleWakeCleanupPending, isFalse);
  });

  test('app lock closes native notification policy before enabling', () async {
    await boot({'displayName': 'Me'});

    await state.setAppLockEnabled(true);

    expect(state.appLockEnabled, isTrue);
    expect(state.prefs.getBool('appLockEnabled.v1'), isTrue);
    expect(jami.messageAppLockCalls.last, isTrue);
  });

  test(
    'app lock is not enabled when native notification policy fails',
    () async {
      await boot({'displayName': 'Me'});
      jami.failMessageNotificationPolicy = true;

      await expectLater(state.setAppLockEnabled(true), throwsStateError);

      expect(state.appLockEnabled, isFalse);
      expect(state.prefs.getBool('appLockEnabled.v1'), isFalse);
    },
  );

  test(
    'composer activity routes to one exact direct scope, coalesces, and retires',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      state.setConversationVisible(peer);

      expect(
        await state.setLocalComposerActivity(ComposerActivityKind.typing),
        isTrue,
      );
      expect(
        await state.setLocalComposerActivity(ComposerActivityKind.typing),
        isTrue,
      );
      expect(jami.composerActivityCalls, [
        (
          accountId: 'acc1',
          peerId: peer,
          conversationId: peerConversation,
          kind: ComposerActivityKind.typing,
        ),
      ]);

      state.composerActivityRepeat = Duration.zero;
      expect(
        await state.setLocalComposerActivity(ComposerActivityKind.typing),
        isTrue,
      );
      expect(
        await state.setLocalComposerActivity(ComposerActivityKind.idle),
        isTrue,
      );
      expect(jami.composerActivityCalls.map((call) => call.kind), [
        ComposerActivityKind.typing,
        ComposerActivityKind.typing,
        ComposerActivityKind.idle,
      ]);
      expect(
        jami.composerActivityCalls.map((call) => call.conversationId),
        everyElement(peerConversation),
      );
    },
  );

  test(
    'remote composer activity rejects self, unknown, malformed, and stale routes',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});

      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': stranger,
        'conversationId': peerConversation,
        'kind': 'typing',
      });
      expect(state.remoteComposerActivity, isNull);

      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': peer,
        'conversationId': 'stale-conversation',
        'kind': 'typing',
      });
      jami.push('composerActivity', {
        'accountId': 'other-account',
        'fromJamiId': peer,
        'conversationId': peerConversation,
        'kind': 'typing',
      });
      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': jami.accountJamiId,
        'conversationId': peerConversation,
        'kind': 'typing',
      });
      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': peer,
        'conversationId': peerConversation,
        'kind': 'recording',
      });
      expect(state.remoteComposerActivity, isNull);

      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': peer,
        'conversationId': peerConversation,
        'kind': 'typing',
      });
      expect(state.remoteComposerActivity, ComposerActivityKind.typing);

      // libjami emits idle after its bounded composing timeout when a stop is
      // lost; Dart handles that timeout signal exactly like an explicit stop.
      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': peer,
        'conversationId': peerConversation,
        'kind': 'idle',
      });
      expect(state.remoteComposerActivity, isNull);
    },
  );

  test('group composer activity is not published or projected', () async {
    const groupConversation = 'composer-group';
    await boot(
      {'displayName': 'Me', 'selectedGroupId': groupConversation},
      configure: (fake) {
        fake.daemonGroups[groupConversation] = const JamiGroup(
          conversationId: groupConversation,
          title: 'Group',
          memberCount: 2,
          canManageMembers: true,
          members: [
            JamiGroupMember(peerJamiId: peer, role: JamiGroupMemberRole.member),
          ],
        );
      },
    );

    expect(
      await state.setLocalComposerActivity(ComposerActivityKind.typing),
      isFalse,
    );
    expect(jami.composerActivityCalls, isEmpty);
    jami.push('composerActivity', {
      'accountId': 'acc1',
      'fromJamiId': peer,
      'conversationId': groupConversation,
      'kind': 'typing',
    });
    expect(state.remoteComposerActivity, isNull);
  });

  test(
    'composer transport failure cannot block durable message send',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      state.setConversationVisible(peer);
      jami.composerActivityResult = false;

      expect(
        await state.setLocalComposerActivity(ComposerActivityKind.typing),
        isFalse,
      );
      jami.composerActivityResult = true;
      expect(
        await state.setLocalComposerActivity(ComposerActivityKind.typing),
        isTrue,
      );
      expect(jami.composerActivityCalls, hasLength(2));
      expect(await state.sendText('message still sends'), isTrue);
      expect(jami.lastChatBody, 'message still sends');
    },
  );

  test('disabling composer activity retires and forgets live hints', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    state.setConversationVisible(peer);

    await state.setLocalComposerActivity(ComposerActivityKind.typing);
    jami.push('composerActivity', {
      'accountId': 'acc1',
      'fromJamiId': peer,
      'conversationId': peerConversation,
      'kind': 'typing',
    });
    expect(state.remoteComposerActivity, ComposerActivityKind.typing);

    expect(await state.setChatActivityIndicatorsEnabled(false), isTrue);
    expect(jami.composerActivityCalls.last.kind, ComposerActivityKind.idle);

    expect(await state.setChatActivityIndicatorsEnabled(true), isTrue);
    expect(state.remoteComposerActivity, isNull);
  });

  test(
    'message arrival, conversation switching, background, and lock clear activity',
    () async {
      await boot(
        {'displayName': 'Me', 'peerId': peer},
        configure: (fake) {
          fake.daemonFriends[otherFriend] = const JamiFriend(
            peerJamiId: otherFriend,
            confirmed: true,
            conversationId: 'conv-other',
          );
        },
      );
      state.setConversationVisible(peer);
      await state.setLocalComposerActivity(ComposerActivityKind.typing);
      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': peer,
        'conversationId': peerConversation,
        'kind': 'typing',
      });
      expect(state.remoteComposerActivity, ComposerActivityKind.typing);

      await state.selectFriend(otherFriend);
      state.setConversationVisible(otherFriend);
      expect(state.remoteComposerActivity, isNull);
      expect(jami.composerActivityCalls.last.kind, ComposerActivityKind.idle);

      await state.selectFriend(peer);
      state.setConversationVisible(peer);
      jami.push('composerActivity', {
        'accountId': 'acc1',
        'fromJamiId': peer,
        'conversationId': peerConversation,
        'kind': 'typing',
      });
      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': peer,
        'conversationId': peerConversation,
        'item': _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'typing-clear-message',
          authorId: peer,
          text: 'sent',
        ),
      });
      expect(state.remoteComposerActivity, isNull);

      await state.setLocalComposerActivity(ComposerActivityKind.typing);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(jami.composerActivityCalls.last.kind, ComposerActivityKind.idle);

      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await state.setLocalComposerActivity(ComposerActivityKind.typing);
      state.setProtectedSurfaceLocked(true);
      expect(jami.composerActivityCalls.last.kind, ComposerActivityKind.idle);
      expect(state.remoteComposerActivity, isNull);
    },
  );

  test('disposing retires the exact active composer scope', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    state.setConversationVisible(peer);
    await state.setLocalComposerActivity(ComposerActivityKind.typing);

    state.dispose();
    booted = false;

    expect(jami.composerActivityCalls.last, (
      accountId: 'acc1',
      peerId: peer,
      conversationId: peerConversation,
      kind: ComposerActivityKind.idle,
    ));
  });

  test(
    'Android remote-control readiness follows boot and service events',
    () async {
      await boot(
        {},
        configure: (fake) => fake.remoteControlAccessibility = true,
      );
      expect(state.remoteControlAccessibilityEnabled, isTrue);

      jami.push('remoteControlAccessibilityState', {'enabled': false});

      expect(state.remoteControlAccessibilityEnabled, isFalse);
    },
  );

  test(
    'onboarding publishes the chosen name without changing the avatar',
    () async {
      await boot({});

      await state.onboard('Mara');

      expect(state.screen, Screen.home);
      expect(state.displayName, 'Mara');
      expect(jami.lastProfileDisplayName, 'Mara');
      expect(jami.lastProfileAvatar, isEmpty);
      expect(jami.lastProfileFileType, isEmpty);
      expect(jami.lastProfileFlag, 0);
      expect(jami.lastEnsureCreateIfMissing, isTrue);
      expect(jami.accountExists, isTrue);
      await pumpEventQueue();
      expect(state.appSettings.identityColorManual, isFalse);
      expect(
        jami.presenceMetadataCalls.last.color,
        state.identityColor.storageValue,
      );
    },
  );

  test(
    'onboarding rejects an oversized display name before creation',
    () async {
      await boot({});
      final ensureCalls = jami.calls
          .where((call) => call.startsWith('ensureAccount:'))
          .length;

      await expectLater(
        state.onboard('x' * (ProfileWireContract.maxDisplayNameUtf8Bytes + 1)),
        throwsArgumentError,
      );

      expect(state.screen, Screen.onboarding);
      expect(jami.accountExists, isFalse);
      expect(
        jami.calls.where((call) => call.startsWith('ensureAccount:')),
        hasLength(ensureCalls),
      );
    },
  );

  test(
    'boot republishes the daemon account name instead of a stale hint',
    () async {
      await boot({
        'displayName': 'Stale local hint',
      }, configure: (fake) => fake.accountDisplayName = 'Mara');

      expect(state.displayName, 'Mara');
      expect(state.prefs.getString('displayName'), 'Mara');
      expect(jami.lastProfileDisplayName, 'Mara');
      expect(jami.lastProfileAvatar, isEmpty);
      expect(jami.lastProfileFileType, isEmpty);
      expect(jami.lastProfileFlag, 0);
    },
  );

  test('friend snapshot is a live read-only view of daemon truth', () async {
    SharedPreferences.setMockInitialValues({});
    jami = FakeJami();
    state = AppState(jami, await SharedPreferences.getInstance());
    booted = true;
    final friendView = state.friends;

    state.seedEmptyRuntimeSnapshotForTesting(
      selectedPeerId: peer,
      friends: const [
        FriendState(
          peerId: peer,
          confirmed: true,
          conversationId: peerConversation,
        ),
      ],
    );

    expect(friendView, contains(peer));
    expect(
      () => friendView[stranger] = const FriendState(
        peerId: stranger,
        confirmed: true,
        conversationId: strangerConversation,
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'group invite waits for the invited member to reach daemon truth',
    () async {
      const conversationId = 'conversation-invite';
      const original = JamiGroup(
        conversationId: conversationId,
        title: 'The Crew',
        memberCount: 2,
        canManageMembers: true,
        localRole: JamiGroupMemberRole.admin,
        members: [
          JamiGroupMember(peerJamiId: peer, role: JamiGroupMemberRole.member),
        ],
      );
      const invited = JamiGroup(
        conversationId: conversationId,
        title: 'The Crew',
        memberCount: 3,
        canManageMembers: true,
        localRole: JamiGroupMemberRole.admin,
        members: [
          JamiGroupMember(peerJamiId: peer, role: JamiGroupMemberRole.member),
          JamiGroupMember(
            peerJamiId: otherFriend,
            role: JamiGroupMemberRole.invited,
          ),
        ],
      );
      await boot(
        {'displayName': 'Me'},
        configure: (fake) {
          fake.daemonFriends[peer] = const JamiFriend(
            peerJamiId: peer,
            confirmed: true,
            conversationId: peerConversation,
          );
          fake.daemonFriends[otherFriend] = const JamiFriend(
            peerJamiId: otherFriend,
            confirmed: true,
            conversationId: 'conv-other',
          );
          fake.daemonGroups[conversationId] = original;
        },
      );
      final friends = jami.daemonFriends.values.toList(growable: false);
      jami.queuedFriendLists.addAll([
        JamiFriendList(jami.friendsRevision, friends, const [original]),
        JamiFriendList(jami.friendsRevision + 1, friends, const [invited]),
      ]);

      expect(
        await state.addGroupMembers(conversationId, const [otherFriend]),
        isTrue,
      );

      expect(jami.lastGroupConversationId, conversationId);
      expect(jami.lastGroupMemberIds, const [otherFriend]);
      expect(state.groups[conversationId]!.invitedMemberIds, {otherFriend});
    },
  );

  test(
    'selected group timeline replaces its author allow-set when membership changes',
    () async {
      const conversationId = 'conversation-membership';
      await boot(
        {'displayName': 'Me', 'selectedGroupId': conversationId},
        configure: (jami) {
          jami.daemonGroups[conversationId] = const JamiGroup(
            conversationId: conversationId,
            title: 'The Crew',
            memberCount: 2,
            canManageMembers: true,
            members: [
              JamiGroupMember(
                peerJamiId: peer,
                role: JamiGroupMemberRole.member,
              ),
            ],
          );
        },
      );
      expect(state.selectedGroupId, conversationId);
      final firstTimeline = state.conversationTimelineForTesting;
      expect(firstTimeline?.allowedRemoteAuthorIds, {peer});

      jami.daemonGroups[conversationId] = const JamiGroup(
        conversationId: conversationId,
        title: 'The Crew',
        memberCount: 2,
        canManageMembers: true,
        members: [
          JamiGroupMember(
            peerJamiId: stranger,
            role: JamiGroupMemberRole.member,
          ),
        ],
      );
      jami.friendsRevision++;
      jami.push('friendsChanged', {'accountId': 'acc1'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final replacement = state.conversationTimelineForTesting;
      expect(replacement, isNot(same(firstTimeline)));
      expect(replacement?.allowedRemoteAuthorIds, {stranger});
    },
  );

  test(
    'friend activity keeps unread counts scoped, deduplicated, and visibility-aware',
    () async {
      await boot(
        {'displayName': 'Me', 'peerId': peer},
        configure: (jami) {
          jami.daemonFriends[otherFriend] = const JamiFriend(
            peerJamiId: otherFriend,
            confirmed: true,
            conversationId: 'conv-other',
          );
        },
      );

      void pushActivity({
        required String daemonId,
        required String authorId,
        String mimeType = 'text/plain',
        int timestampSeconds = 1700000000,
      }) {
        jami.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': otherFriend,
          'conversationId': 'conv-other',
          'item': {
            'accountId': 'acc1',
            'peerId': otherFriend,
            'conversationId': 'conv-other',
            'daemonId': daemonId,
            'versionId': daemonId,
            'mimeType': mimeType,
            'authorId': authorId,
            'timestampSeconds': timestampSeconds,
            'body': mimeType == 'text/plain'
                ? 'hello'
                : {
                    'fileId': 'file',
                    'displayName': 'file.txt',
                    'totalBytes': 1,
                  },
          },
        });
      }

      pushActivity(daemonId: 'incoming-1', authorId: otherFriend);
      pushActivity(daemonId: 'incoming-1', authorId: otherFriend);
      pushActivity(
        daemonId: 'incoming-file',
        authorId: otherFriend,
        mimeType: TimelineWireContract.fileMimeType,
        timestampSeconds: 1700000001,
      );
      pushActivity(
        daemonId: 'outgoing-1',
        authorId: jami.accountJamiId,
        timestampSeconds: 1700000002,
      );

      expect(state.friendActivity(otherFriend).unreadMessages, 1);
      expect(state.friendActivity(otherFriend).unreadFiles, 1);
      expect(state.unreadOutsideConversation(peer), 2);
      expect(
        state.friendActivity(otherFriend).lastActivityAt,
        DateTime.fromMillisecondsSinceEpoch(1700000002 * 1000, isUtc: true),
      );

      state.setConversationVisible(otherFriend);
      expect(state.friendActivity(otherFriend).unreadTotal, 0);
      expect(state.unreadOutsideConversation(peer), 0);

      pushActivity(
        daemonId: 'incoming-visible',
        authorId: otherFriend,
        timestampSeconds: 1700000003,
      );
      expect(state.friendActivity(otherFriend).unreadTotal, 0);

      state.setConversationVisible(null);
      pushActivity(
        daemonId: 'incoming-hidden',
        authorId: otherFriend,
        timestampSeconds: 1700000004,
      );
      expect(state.friendActivity(otherFriend).unreadMessages, 1);
    },
  );

  test(
    'background messages wait for the visible conversation after resume',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      state.setConversationVisible(peer);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(state.visibleConversationPeerId, isNull);

      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': peer,
        'conversationId': peerConversation,
        'item': _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'background-message',
          authorId: peer,
          text: 'arrived while away',
        ),
      });
      await Future<void>.delayed(Duration.zero);
      expect(jami.displayedMessages, isEmpty);

      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(jami.displayedMessages, isEmpty);

      state.setConversationVisible(peer);
      await Future<void>.delayed(Duration.zero);
      expect(jami.displayedMessages, [
        (
          peerId: peer,
          conversationId: peerConversation,
          messageId: 'background-message',
        ),
      ]);
    },
  );

  test(
    'background group messages wait for the visible topic after resume',
    () async {
      const conversationId = 'group-read-receipt';
      const owner = 'group:$conversationId';
      await boot(
        {'displayName': 'Me', 'selectedGroupId': conversationId},
        configure: (fake) {
          fake.daemonGroups[conversationId] = const JamiGroup(
            conversationId: conversationId,
            title: 'The Crew',
            memberCount: 2,
            canManageMembers: true,
            members: [
              JamiGroupMember(
                peerJamiId: peer,
                role: JamiGroupMemberRole.member,
              ),
            ],
          );
        },
      );
      state.setConversationVisible(owner, groupTopicId: 'general');
      expect(state.visibleConversationPeerId, owner);
      expect(state.visibleGroupTopicId, 'general');
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(state.visibleConversationPeerId, isNull);
      expect(state.visibleGroupTopicId, isNull);

      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': owner,
        'conversationId': conversationId,
        'item': _textWire(
          ownerPeer: owner,
          conversationId: conversationId,
          daemonId: 'group-background-message',
          authorId: peer,
          text: GroupTopicCodec.encode('general', 'arrived in the group'),
        ),
      });
      jami.push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': owner,
        'conversationId': conversationId,
        'item': _textWire(
          ownerPeer: owner,
          conversationId: conversationId,
          daemonId: 'hidden-games-message',
          authorId: peer,
          text: GroupTopicCodec.encode('games', 'hidden in games'),
        ),
      });
      await Future<void>.delayed(Duration.zero);
      expect(jami.displayedMessages, isEmpty);
      expect(state.groupHasUnread(conversationId), isTrue);
      expect(state.friendActivity(peer).unreadTotal, 0);

      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(jami.displayedMessages, isEmpty);

      state.setConversationVisible(owner, groupTopicId: 'general');
      await Future<void>.delayed(Duration.zero);
      expect(jami.displayedMessages, [
        (
          peerId: owner,
          conversationId: conversationId,
          messageId: 'group-background-message',
        ),
      ]);

      state.setConversationVisible(owner, groupTopicId: 'games');
      await Future<void>.delayed(Duration.zero);
      expect(state.visibleGroupTopicId, 'games');
      expect(jami.displayedMessages.last, (
        peerId: owner,
        conversationId: conversationId,
        messageId: 'hidden-games-message',
      ));
    },
  );

  test('Android inactive stops visible-topic read receipts', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    state.setConversationVisible(peer);

    state.didChangeAppLifecycleState(AppLifecycleState.inactive);
    jami.push('chatMessage', {
      'accountId': 'acc1',
      'peerJamiId': peer,
      'conversationId': peerConversation,
      'item': _textWire(
        ownerPeer: peer,
        conversationId: peerConversation,
        daemonId: 'inactive-message',
        authorId: peer,
        text: 'arrived while leaving',
      ),
    });
    await Future<void>.delayed(Duration.zero);

    expect(state.visibleConversationPeerId, isNull);
    expect(jami.displayedMessages, isEmpty);

    state.setConversationVisible(peer);
    expect(state.visibleConversationPeerId, isNull);
  });

  test('returning user adopts the account and subscribes the peer', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    expect(state.screen, Screen.home);
    expect(state.jamiId, 'a' * 40);
    expect(jami.calls, contains('subscribe:$peer'));
    expect(state.bootError, isNull);
  });

  test(
    'launch opens people without restoring or inventing a selection',
    () async {
      await boot({
        'displayName': 'Me',
        'selectedFriendId': peer,
        'peerId': peer,
      }, selectAfterBoot: false);
      await pumpEventQueue(times: 3);

      expect(state.friends, contains(peer));
      expect(state.peerId, isNull);
      expect(state.selectedGroupId, isNull);
      expect(state.selectedConversationScope, isNull);
      expect(state.conversationTimelineForTesting, isNull);
      expect(
        jami.calls.where((entry) => entry.startsWith('loadChat:')),
        isEmpty,
      );
      expect(state.prefs.getString('selectedFriendId'), isNull);
    },
  );

  test(
    'returning user requests the persisted account and peer and stores the selected identity',
    () async {
      await boot({
        'displayName': 'Me',
        'accountId': 'previous-account',
        'peerId': peer,
      });
      expect(
        jami.calls,
        contains('ensureAccount:previous-account:$peer:false'),
      );
      expect(state.accountId, 'acc1');
      expect(state.prefs.getString('accountId'), 'acc1');
    },
  );

  test(
    'post-adoption replay preserves a native request and trusted cold-start ring',
    () async {
      await boot(
        {'displayName': 'Me', 'accountId': 'stale-account', 'peerId': peer},
        configure: (jami) {
          jami.pendingReplayEvents.addAll([
            JamiEvent('connectRequest', {
              'accountId': 'acc1',
              'conversationId': 'cold-request',
              'fromJamiId': stranger,
              'isGroup': false,
            }),
            JamiEvent('incomingCall', {
              'accountId': 'acc1',
              'callId': 'cold-call',
              'fromJamiId': peer,
              'withVideo': false,
            }),
          ]);
        },
      );

      expect(jami.replayPendingNativeEventsCalls, 1);
      expect(state.pendingConnect?.convId, 'cold-request');
      expect(state.call?.callId, 'cold-call');
      expect(jami.calls, isNot(contains('refuse:cold-call')));
    },
  );

  test('events explicitly scoped to another account are ignored', () async {
    await boot({'displayName': 'Me'});
    jami.push('registrationState', {
      'accountId': 'other',
      'state': 'REGISTERED',
    });
    jami.push('deviceAnnounced', {'accountId': 'other', 'announced': true});
    jami.push('incomingCall', {
      'accountId': 'other',
      'callId': 'wrong',
      'fromJamiId': peer,
    });
    expect(state.registration, 'UNREGISTERED');
    expect(state.ready, isFalse);
    expect(state.call, isNull);
  });

  test(
    'the persisted account gate rejects a native replay during account adoption',
    () async {
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
        'peerId': peer,
      });
      jami = FakeJami()
        ..eventDuringEnsure = JamiEvent('incomingCall', {
          'type': 'incomingCall',
          'accountId': 'other',
          'callId': 'wrong-account-call',
          'fromJamiId': peer,
        });
      state = AppState(jami, await SharedPreferences.getInstance());
      await state.init();
      expect(state.call, isNull);
      expect(jami.calls, isNot(contains('refuse:wrong-account-call')));
    },
  );

  test(
    'malformed scalar event fields do not terminate later event handling',
    () async {
      await boot({'displayName': 'Me'});
      expect(
        () => jami.push('registrationState', {'state': 7}),
        returnsNormally,
      );
      expect(state.registration, 'UNREGISTERED');
      jami.push('deviceAnnounced', {'accountId': 'acc1', 'announced': true});
      expect(state.ready, isTrue);
    },
  );

  test(
    'daemon-boot failure surfaces bootError instead of stranding the splash; retry recovers',
    () async {
      SharedPreferences.setMockInitialValues({'displayName': 'Me'});
      jami = FakeJami()..daemonDown = true;
      state = AppState(jami, await SharedPreferences.getInstance());
      await state.init(); // must not throw out of init()
      expect(state.bootError, isNotNull);
      expect(state.screen, Screen.loading);

      jami.daemonDown = false;
      await state.retryBoot();
      expect(state.bootError, isNull);
      expect(state.screen, Screen.home);
    },
  );

  test('overlapping boot retries share one native transaction', () async {
    SharedPreferences.setMockInitialValues({'displayName': 'Me'});
    jami = FakeJami()..daemonDown = true;
    state = AppState(jami, await SharedPreferences.getInstance());
    await state.init();
    expect(state.bootError, isNotNull);

    jami
      ..daemonDown = false
      ..pendingEnsure = Completer<Map<String, dynamic>>();
    final callsBefore = jami.calls
        .where((call) => call.startsWith('ensureAccount:'))
        .length;
    final first = state.retryBoot();
    final second = state.retryBoot();
    // Pending-restore recovery is checked before ordinary account adoption.
    await pumpEventQueue();
    expect(
      jami.calls.where((call) => call.startsWith('ensureAccount:')).length,
      callsBefore + 1,
    );

    jami.pendingEnsure!.complete({
      'status': 'ok',
      'accountId': jami.accountId,
      'jamiId': jami.accountJamiId,
      'displayName': 'Me',
      'avatarBase64': '',
      'enabled': true,
      'announced': false,
      'registration': 'UNREGISTERED',
    });
    await Future.wait([first, second]);

    expect(state.bootError, isNull);
    expect(state.screen, Screen.home);
  });

  test('daemon failure without a local name still offers boot retry', () async {
    SharedPreferences.setMockInitialValues({});
    jami = FakeJami()
      ..accountExists = false
      ..daemonDown = true;
    state = AppState(jami, await SharedPreferences.getInstance());
    booted = true;

    await state.init();

    expect(state.screen, Screen.loading);
    expect(state.bootError, isNotNull);
    expect(jami.lastEnsureCreateIfMissing, isFalse);
  });

  test(
    'restore waits for policy and keeps the restored identity offline',
    () async {
      final oldAvatar = _avatarBase64();
      final restoredAvatar = _avatarBase64();
      await boot(
        {
          'accountId': 'old-account',
          'profileAvatarBase64': oldAvatar,
          'connectionProfile': 'strict',
          'strictBootstrap': 'bootstrap.example',
          'strictTurnServer': 'turn.example',
          'strictTurnRealm': 'realm',
          'strictTurnUser': 'user',
          'strictTurnPassword': 'password',
        },
        configure: (fake) {
          fake.accountExists = false;
          fake.restoreResult = {
            'status': 'ok',
            'accountId': 'restored-account',
            'jamiId': 'e' * 40,
            'displayName': 'Restored',
            'avatarBase64': restoredAvatar,
            'enabled': false,
            'announced': false,
            'registration': 'UNREGISTERED',
          };
        },
      );
      jami.pendingAppearOffline = Completer<void>();
      jami.pendingConnectionProfile = Completer<void>();

      final restoring = state.restoreIdentity(
        'secret',
        expectedJamiId: 'e' * 40,
      );
      await pumpEventQueue();

      expect(state.screen, Screen.onboarding);
      // Boot confirmed the old account is absent; restoration must not publish
      // its replacement until the offline policy is acknowledged.
      expect(state.prefs.getString('accountId'), isNull);
      expect(jami.lastPickMaxBytes, JamiClient.maxBackupImportBytes);
      expect(jami.lastRestoreArguments, {
        'filePath': 'picked.txt',
        'passphrase': 'secret',
        'connectionProfile': 'strict',
        'dhtBootstrap': 'bootstrap.example',
        'turnServer': 'turn.example',
        'turnRealm': 'realm',
        'turnUser': 'user',
        'turnPassword': 'password',
        'appearOffline': true,
        'expectedJamiId': 'e' * 40,
      });

      jami.pendingAppearOffline!.complete();
      await pumpEventQueue();
      expect(state.screen, Screen.onboarding);
      jami.pendingConnectionProfile!.complete();

      expect(await restoring, isNull);
      expect(state.screen, Screen.home);
      expect(state.accountId, 'restored-account');
      expect(state.jamiId, 'e' * 40);
      expect(state.displayName, 'Restored');
      expect(state.profileAvatarBase64, restoredAvatar);
      expect(state.appearOffline, isTrue);
      expect(state.registration, 'UNREGISTERED');
      expect(state.settingsError, contains('Identity restored offline'));
      expect(state.prefs.getString('accountId'), 'restored-account');
      expect(state.prefs.getString('profileAvatarBase64'), restoredAvatar);
      expect(
        jami.calls.indexOf('appearOffline:true'),
        lessThan(
          jami.calls.indexWhere(
            (call) => call.startsWith('connectionProfile:strict:'),
          ),
        ),
      );
      expect(jami.lastProfileDisplayName, 'Restored');
      expect(jami.discardedPickedFiles, ['picked.txt']);
    },
  );

  test(
    'restore waits for confirmed media release before opening a backup',
    () async {
      await boot({'displayName': 'Me'});
      final released = Completer<bool>();
      final unregister = MediaRetirement.register(() => released.future);
      addTearDown(unregister);
      final restoring = state.restoreIdentity('secret');
      await pumpEventQueue();
      expect(jami.pickFileCalls, 0);
      expect(jami.lastRestoreArguments, isNull);
      released.complete(true);
      expect(await restoring, isNull);
      expect(jami.pickFileCalls, 1);
      expect(jami.lastRestoreArguments, isNotNull);
    },
  );

  test('restore refuses import when media release is unconfirmed', () async {
    await boot({'displayName': 'Me'});
    final unregister = MediaRetirement.register(() async => false);
    addTearDown(unregister);
    expect(await state.restoreIdentity('secret'), isNotNull);
    expect(jami.pickFileCalls, 0);
    expect(jami.lastRestoreArguments, isNull);
  });

  test(
    'a supplied backup skips the picker and is spent on every exit',
    () async {
      await boot({'displayName': 'Me'});
      // Refused before the attempt starts: the handed-over copy is released.
      state.call = CallSession(
        callId: 'busy-call',
        dir: CallDir.outgoing,
        peerId: 'f' * 40,
        state: 'CURRENT',
      );
      expect(
        await state.restoreIdentity('secret', backupPath: 'staged-a.gz'),
        isNotNull,
      );
      state.call = null;
      expect(jami.discardedPickedFiles, ['staged-a.gz']);

      // Media that will not stop fails inside the attempt; still released.
      final unregister = MediaRetirement.register(() async => false);
      expect(
        await state.restoreIdentity('secret', backupPath: 'staged-b.gz'),
        isNotNull,
      );
      unregister();
      expect(jami.discardedPickedFiles, ['staged-a.gz', 'staged-b.gz']);

      await state.restoreIdentity('secret', backupPath: 'staged-c.gz');
      expect(jami.pickFileCalls, 0);
      expect(jami.lastRestoreArguments, isNotNull);
      expect(jami.discardedPickedFiles, [
        'staged-a.gz',
        'staged-b.gz',
        'staged-c.gz',
      ]);
    },
  );

  test('restore clears an invalid avatar from the previous identity', () async {
    final oldAvatar = _avatarBase64();
    await boot(
      {'accountId': 'old-account', 'profileAvatarBase64': oldAvatar},
      configure: (fake) {
        fake.accountExists = false;
        fake.restoreResult = {
          'status': 'ok',
          'accountId': 'restored-account',
          'jamiId': 'e' * 40,
          'displayName': 'Restored',
          'avatarBase64': 'not base64',
          'enabled': true,
          'announced': false,
          'registration': 'UNREGISTERED',
        };
      },
    );

    expect(await state.restoreIdentity('secret'), isNull);

    expect(state.profileAvatarBase64, isEmpty);
    expect(state.prefs.getString('profileAvatarBase64'), isNull);
  });

  test(
    'backup includes settings and restore applies a valid document',
    () async {
      await boot({'displayName': 'Me'});
      const surface = TopicStripSurfaceSettings(
        coverage: TopicStripSurfaceCoverage.fullWidth,
        strength: 67,
        blur: 11,
        solidReach: 21,
        lowerFade: 44,
        rightFade: 33,
      );
      expect(await state.setTopicStripSurfaceSettings(surface), isTrue);

      expect(await state.backupIdentity('secret'), isTrue);
      final backedUp = const AppSettingsCodec().decode(
        Map<String, Object?>.from(
          jsonDecode(jami.lastBackupSettingsDocument!) as Map,
        ),
      );
      expect(backedUp.settings.topicStripSurfaceSettings, surface);

      final restoredSettings = AppSettings(
        topicStripSurfaceSettings: surface.copyWith(strength: 84),
      );
      jami.restoreResult = {
        'status': 'ok',
        'accountId': 'restored-account',
        'jamiId': 'e' * 40,
        'displayName': 'Restored',
        'avatarBase64': '',
        'enabled': true,
        'announced': false,
        'registration': 'REGISTERED',
        'settingsDocument': jsonEncode(
          const AppSettingsCodec().encode(restoredSettings),
        ),
      };

      expect(await state.restoreIdentity('secret'), isNull);
      expect(state.topicStripSurfaceSettings.strength, 84);
      final stored = jsonDecode(state.prefs.getString('appSettings')!) as Map;
      expect(
        ((stored['appearance'] as Map)['topicStripSurface'] as Map)['strength'],
        84,
      );
    },
  );

  test('backup permits an explicitly confirmed empty passphrase', () async {
    await boot({'displayName': 'Me'});

    expect(await state.backupIdentity(''), isTrue);
    expect(jami.lastBackupPassphrase, isEmpty);
  });

  test(
    'restore permits an empty passphrase for an unprotected backup',
    () async {
      await boot({'displayName': 'Me'});

      expect(await state.restoreIdentity(''), isNull);
      expect(jami.lastRestoreArguments?['passphrase'], isEmpty);
    },
  );

  test('invalid restored settings do not block identity restore', () async {
    await boot({'displayName': 'Me'});
    final before = state.appSettings;
    jami.restoreResult = {
      'status': 'ok',
      'accountId': 'restored-account',
      'jamiId': 'e' * 40,
      'displayName': 'Restored',
      'avatarBase64': '',
      'enabled': true,
      'announced': false,
      'registration': 'REGISTERED',
      'settingsDocument': '{bad json',
    };

    expect(await state.restoreIdentity('secret'), isNull);
    expect(state.screen, Screen.home);
    expect(state.appSettings, before);
  });

  test(
    'failed restore reconciliation retries adoption without re-importing',
    () async {
      await boot(
        {'accountId': 'old-account', 'displayName': 'Old'},
        configure: (fake) {
          fake.accountExists = false;
          fake.failConnectionProfile = true;
        },
      );

      await expectLater(state.restoreIdentity('secret'), throwsStateError);

      expect(state.screen, Screen.loading);
      expect(state.bootError, isNotNull);
      expect(state.prefs.getString('accountId'), isNull);
      expect(jami.pickFileCalls, 1);
      expect(jami.discardedPickedFiles, ['picked.txt']);
      jami.failConnectionProfile = false;
      await state.retryBoot();

      expect(state.bootError, isNull);
      expect(state.screen, Screen.home);
      expect(state.accountId, 'restored-account');
      expect(jami.lastEnsureCreateIfMissing, isFalse);
      expect(jami.pickFileCalls, 1);
    },
  );

  group('setPeer validation (M7.5 c/L10)', () {
    test('rejects malformed ids without persisting or trusting them', () async {
      await boot({'displayName': 'Me'});
      expect(await state.setPeer(''), isFalse);
      expect(await state.setPeer(peer.substring(1)), isFalse); // 39 chars
      expect(await state.setPeer('z' * 40), isFalse); // not hex
      expect(state.peerId, isNull);
      expect(jami.calls.where((c) => c.startsWith('subscribe:')), isEmpty);
    });

    test(
      'accepts a 40-hex id, normalizing case, whitespace and a jami: prefix',
      () async {
        await boot({'displayName': 'Me'});
        expect(await state.setPeer('  Jami:${peer.toUpperCase()} '), isTrue);
        expect(state.peerId, peer);
        expect(jami.calls, contains('subscribe:$peer'));
      },
    );

    test(
      'rejects self and duplicate identities before daemon mutation',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        final revision = jami.friendsRevision;
        final callCount = jami.calls.length;

        expect(
          await state.addFriend('JAMI:${jami.accountJamiId.toUpperCase()}'),
          isFalse,
        );
        expect(await state.addFriend(peer.toUpperCase()), isFalse);

        expect(jami.friendsRevision, revision);
        expect(jami.calls, hasLength(callCount));
        expect(state.friends, hasLength(1));
        expect(state.peerId, peer);
      },
    );
  });

  group('true multi-friend ownership', () {
    test(
      'profile events require the active account and exact trusted conversation',
      () async {
        await boot(
          {'displayName': 'Me', 'peerId': peer},
          configure: (fake) {
            fake.daemonFriends[peer] = const JamiFriend(
              peerJamiId: peer,
              confirmed: true,
              conversationId: peerConversation,
              displayName: 'Initial',
            );
            fake.daemonFriends[stranger] = const JamiFriend(
              peerJamiId: stranger,
              confirmed: false,
              conversationId: strangerConversation,
              displayName: 'Untrusted',
            );
          },
        );

        void profile(
          String title, {
          Object? account = 'acc1',
          String owner = peer,
          String conversation = peerConversation,
          bool includeAccount = true,
          String avatarBase64 = '',
        }) {
          jami.push('friendProfile', {
            if (includeAccount) 'accountId': account,
            'peerJamiId': owner,
            'conversationId': conversation,
            'displayName': title,
            'avatarBase64': avatarBase64,
            'description': 'ignored',
          });
        }

        profile('missing-account', includeAccount: false);
        profile('wrong-account', account: 'other');
        profile('wrong-conversation', conversation: 'not-owned');
        profile(
          'untrusted',
          owner: stranger,
          conversation: strangerConversation,
        );
        profile('x' * (ProfileWireContract.maxDisplayNameUtf8Bytes + 1));
        expect(state.friends[peer]?.displayName, 'Initial');
        expect(state.peerDisplayName(peer), 'Initial');
        expect(state.friends[stranger]?.displayName, 'Untrusted');

        final avatar = _avatarBase64();
        profile('Updated 😀', avatarBase64: avatar);
        expect(state.friends[peer]?.displayName, 'Updated 😀');
        expect(state.peerDisplayName(peer), 'Updated 😀');
        expect(state.friends[peer]?.avatarBase64, avatar);
      },
    );

    test('local profile picture updates only after native success', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      final avatar = _avatarBase64();

      expect(await state.pickProfileImage(), 'picked.txt');
      expect(jami.lastPickMaxBytes, JamiClient.maxProfileImageBytes);
      expect(await state.updateProfileAvatar(avatar), isTrue);
      expect(state.profileAvatarBase64, avatar);
      expect(state.prefs.getString('profileAvatarBase64'), avatar);
      expect(jami.lastProfileAvatar, avatar);
      expect(jami.lastProfileFlag, 1);

      jami.profileUpdateResult = false;
      expect(await state.updateProfileAvatar(null), isFalse);
      expect(state.profileAvatarBase64, avatar);
      expect(state.prefs.getString('profileAvatarBase64'), avatar);
    });

    test('display name changes preserve identity routing', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      final conversationBefore = state.selectedConversationScope;

      expect(await state.updateDisplayName('  New name  '), isTrue);
      expect(state.displayName, 'New name');
      expect(state.prefs.getString('displayName'), 'New name');
      expect(jami.lastProfileDisplayName, 'New name');
      expect(jami.lastProfileAvatar, isEmpty);
      expect(jami.lastProfileFlag, 0);
      expect(state.selectedConversationScope, conversationBefore);

      jami.profileUpdateResult = false;
      expect(await state.updateDisplayName('Rejected'), isFalse);
      expect(state.displayName, 'New name');
      expect(await state.updateDisplayName('   '), isFalse);
    });

    test(
      'adding and selecting friends preserves both and dual-writes the rollback pointer',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});

        expect(await state.addFriend(stranger), isTrue);
        expect(state.friends.keys, containsAll(<String>[peer, stranger]));
        expect(state.peerId, stranger);
        expect(state.prefs.getString('selectedFriendId'), stranger);
        expect(state.prefs.getString('peerId'), stranger);

        await state.selectFriend(peer);
        expect(state.peerId, peer);
        expect(state.friends, hasLength(2));
        expect(state.prefs.getString('selectedFriendId'), peer);
        expect(state.prefs.getString('peerId'), peer);
      },
    );

    test(
      'stress peer selection uses the ordinary trusted-friend path',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        await state.addFriend(stranger);
        await state.selectFriend(peer);

        jami.push('stressCommand', {'command': 'select:$stranger'});
        await pumpEventQueue(times: 3);

        expect(state.peerId, stranger);
        expect(state.prefs.getString('selectedFriendId'), stranger);

        jami.push('stressCommand', {
          'command': 'select:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        });
        await pumpEventQueue(times: 3);
        expect(state.peerId, stranger);
      },
    );

    test('bounded stress chat probes use the ordinary send path', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      await state.selectFriend(peer);

      jami.push('stressCommand', {'command': 'chat:1'});
      jami.push('stressCommand', {'command': 'chat:0'});
      jami.push('stressCommand', {'command': 'chat:10'});
      await pumpEventQueue(times: 5);

      expect(jami.lastChatBody, 'Syb-L reliability probe 1');
      expect(
        jami.calls.where((call) => call.startsWith('sendChatMessage:')).length,
        1,
      );
    });

    test('stress media commands use the ordinary call media paths', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('registrationState', {'state': 'REGISTERED'});
      await state.startCall();
      jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});

      jami.push('stressCommand', {'command': 'camera:on'});
      await pumpEventQueue(times: 4);
      expect(jami.calls, contains('startVideo:out1'));
      expect(state.call?.outgoingVideo.kind, OutgoingVideoKind.camera);

      jami.push('stressCommand', {'command': 'camera:flip'});
      await pumpEventQueue(times: 4);
      expect(jami.calls, contains('switchCamera'));

      jami.push('stressCommand', {'command': 'camera:off'});
      await pumpEventQueue(times: 4);
      expect(jami.calls, contains('stopVideo:out1'));
      expect(state.call?.outgoingVideo.kind, OutgoingVideoKind.off);

      jami.pendingScreenSources = Completer<List<ScreenSource>>()
        ..complete([
          ScreenSource.fromMap({
            'id': 'secondary',
            'label': 'Display 2',
            'primary': false,
            'left': 1920,
            'top': 0,
            'width': 1280,
            'height': 720,
          })!,
          ScreenSource.fromMap({
            'id': 'primary',
            'label': 'Display 1',
            'primary': true,
            'left': 0,
            'top': 0,
            'width': 1920,
            'height': 1080,
          })!,
        ]);
      jami.push('stressCommand', {'command': 'screen:on'});
      await pumpEventQueue(times: 4);
      expect(jami.calls, contains('source:out1:screen:primary'));
      expect(state.call?.outgoingVideo.kind, OutgoingVideoKind.screen);

      jami.push('stressCommand', {'command': 'screen:off'});
      await pumpEventQueue(times: 4);
      expect(state.call?.outgoingVideo.kind, OutgoingVideoKind.off);
    });

    test(
      'stress control uses the ordinary remote-control request path',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await boot({'displayName': 'Me', 'peerId': peer});
        state.call = CallSession(
          callId: 'control-call',
          dir: CallDir.outgoing,
          peerId: peer,
          state: 'CURRENT',
          peerVideo: true,
          peerVideoKind: OutgoingVideoKind.screen,
          remoteActive: true,
          remoteWidth: 1080,
          remoteHeight: 2153,
        );
        state.annotation.syncSources(
          localOwner: state.jamiId,
          peerOwner: peer,
          localRevision: 1,
          localKind: OutgoingVideoKind.off,
          peerKind: OutgoingVideoKind.screen,
        );
        state.annotation.applyInbound(
          '{"v":1,"t":"src","sourceOwner":"$peer",'
          '"sourceRevision":4,"sourceKind":"screen"}',
        );
        state.remoteControl.syncCall(
          live: true,
          foreground: true,
          callId: 'control-call',
          peerId: peer,
          peerScreenActive: true,
          peerSourceRevision: 4,
          localScreenActive: false,
          localSourceRevision: 1,
        );

        jami.push('stressCommand', {'command': 'control'});
        await pumpEventQueue(times: 4);

        expect(
          jami.calls,
          contains('requestRemoteControl:control-call:$peer:4'),
        );

        jami.push('remoteControlControllerState', {
          'callId': 'control-call',
          'peerJamiId': peer,
          'peerDeviceId': 'b' * 40,
          'sourceRevision': 4,
          'controlCapabilities': 117,
          'state': 'active',
        });
        jami.push('stressCommand', {'command': 'control:home'});
        await pumpEventQueue(times: 4);

        expect(
          jami.calls,
          contains('inputRemoteControl:control-call:[[a, home]]'),
        );

        jami.push('stressCommand', {'command': 'control:tap'});
        await pumpEventQueue(times: 4);

        expect(
          jami.calls,
          contains(
            'inputRemoteControl:control-call:[[m, 0.5, 0.5], [d, left]]',
          ),
        );
        expect(
          jami.calls,
          contains('inputRemoteControl:control-call:[[u, left]]'),
        );
      },
    );

    test(
      'an exact-row call targets that friend even when another row is selected',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        await state.addFriend(stranger);
        await state.selectFriend(peer);
        jami.push('registrationState', {'state': 'REGISTERED'});

        await state.startCallTo(stranger);

        expect(jami.lastPlacedPeer, stranger);
        expect(state.call?.peerId, stranger);
        expect(jami.calls, isNot(contains('hangUp:out1')));
      },
    );

    test('removing a different friend preserves the selected row', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      await state.addFriend(stranger);
      await state.addFriend(otherFriend);
      expect(state.peerId, otherFriend);

      await state.removeFriend(peer);

      expect(state.friends.keys, containsAll(<String>[stranger, otherFriend]));
      expect(state.peerId, otherFriend);
      expect(state.prefs.getString('selectedFriendId'), otherFriend);
      expect(state.prefs.getString('peerId'), otherFriend);
    });

    test(
      'unconfirmed daemon removal preserves the friend and owned state',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        jami.push('incomingFile', {
          'peerJamiId': peer,
          'conversationId': peerConversation,
          'fileId': 'still-owned',
          'interactionId': 'offer',
          'name': 'keep.txt',
          'size': 10,
        });
        jami.ignoreRemoveContact = true;

        await state.removeFriend(peer);

        expect(state.friends, contains(peer));
        expect(state.peerId, peer);
        expect(_transferFor(state, 'still-owned'), isNotNull);
      },
    );

    test('equal file ids stay isolated through friend removal', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      await state.addFriend(stranger);
      await state.selectFriend(peer);

      jami.push('incomingFile', {
        'peerJamiId': peer,
        'conversationId': peerConversation,
        'fileId': 'same-file',
        'interactionId': 'peer-offer',
        'name': 'peer.txt',
        'size': 11,
      });
      jami.push('incomingFile', {
        'peerJamiId': stranger,
        'conversationId': strangerConversation,
        'fileId': 'same-file',
        'interactionId': 'friend-offer',
        'name': 'friend.txt',
        'size': 22,
      });

      expect(state.transfers, hasLength(2));
      expect(
        state
            .transfers[(
              peerId: peer,
              conversationId: peerConversation,
              fileId: 'same-file',
            )]
            ?.name,
        'peer.txt',
      );
      expect(
        state
            .transfers[(
              peerId: stranger,
              conversationId: strangerConversation,
              fileId: 'same-file',
            )]
            ?.name,
        'friend.txt',
      );

      await state.removeFriend(stranger);

      expect(state.friends.keys, contains(peer));
      expect(state.friends.keys, isNot(contains(stranger)));
      expect(state.transfers, hasLength(1));
      expect(_transferFor(state, 'same-file')?.name, 'peer.txt');
    });

    test(
      'a folder callback that beats the load reply is correlated and stale ids are rejected',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        await Future<void>.delayed(Duration.zero);
        final loadId = jami.nextLoadId;
        jami.eventDuringLoadFolder = JamiEvent('folderSnapshot', {
          'loadId': loadId,
          'peerJamiId': peer,
          'conversationId': peerConversation,
          'files': [
            {
              'fileId': 'early-snapshot',
              'interactionId': 'commit-1',
              'name': 'early.txt',
              'size': 7,
            },
          ],
        });

        state.loadFolder();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(_folderFileFor(state, 'early-snapshot')?.name, 'early.txt');

        jami.push('folderSnapshot', {
          'loadId': loadId - 1,
          'peerJamiId': peer,
          'conversationId': peerConversation,
          'files': [
            {
              'fileId': 'stale-snapshot',
              'interactionId': 'commit-old',
              'name': 'stale.txt',
              'size': 1,
            },
          ],
        });
        expect(_folderFileFor(state, 'stale-snapshot'), isNull);
        expect(_folderFileFor(state, 'early-snapshot'), isNotNull);
      },
    );

    test(
      'presence evidence and foreground clocks are isolated per friend',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        await state.addFriend(stranger);

        jami.push('presence', {'peerJamiId': peer, 'status': 2});
        jami.push('presence', {'peerJamiId': stranger, 'status': 0});
        expect(state.friends[peer]?.presence, PeerPresence.reachable);
        expect(state.friends[stranger]?.presence, PeerPresence.unreachable);

        jami.push('presenceMsg', {
          'fromJamiId': stranger,
          'v': 1,
          't': 'ping',
          'fg': 1,
          'ts': 50,
          'platform': 'android',
          'activity': '',
        });
        jami.push('presenceMsg', {
          'fromJamiId': stranger,
          'v': 1,
          't': 'pong',
          'fg': 0,
          'ts': 49,
          'platform': 'android',
          'activity': '',
        });

        expect(state.friends[peer]?.presence, PeerPresence.reachable);
        expect(state.friends[stranger]?.presence, PeerPresence.inApp);
        expect(state.friends[stranger]?.peerFgTs, 50);
      },
    );
  });

  group('presence dot trust model (presence v2)', () {
    setUp(() => boot({'displayName': 'Me', 'peerId': peer}));

    test(
      'activity sharing defaults off and controls lifecycle probes',
      () async {
        await pumpEventQueue();
        expect(jami.probedPeers, isEmpty);
        jami.probedPeers.clear();
        expect(jami.presenceMetadataCalls.last.shareActivity, isFalse);
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(jami.probedPeers, isEmpty);
        expect(await state.setShareActivityPresence(true), isTrue);
        expect(jami.presenceMetadataCalls.last.shareActivity, isTrue);
        expect(jami.probedPeers, contains(peer));
        jami.probedPeers.clear();
        expect(await state.setShareActivityPresence(false), isTrue);
        expect(jami.presenceMetadataCalls.last.shareActivity, isFalse);
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(jami.probedPeers, isEmpty);
      },
    );

    test(
      'failed native opt-out never persists a false privacy promise',
      () async {
        await pumpEventQueue();
        expect(await state.setShareActivityPresence(true), isTrue);
        expect(jami.appliedPresenceSharing, isTrue);
        jami.failPresenceMetadata = true;
        expect(await state.setShareActivityPresence(false), isFalse);
        expect(state.shareActivityPresence, isTrue);
        expect(jami.appliedPresenceSharing, isTrue);
        expect(state.settingsError, contains('could not be turned off'));
        jami.probedPeers.clear();
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        state.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(jami.probedPeers, isEmpty);
      },
    );

    test('rapid opt-out cannot release an older opt-in probe', () async {
      await pumpEventQueue();
      final pending = Completer<void>();
      jami.pendingPresenceMetadata = pending;
      final enabling = state.setShareActivityPresence(true);
      await pumpEventQueue();
      expect(jami.presenceMetadataCalls.last.shareActivity, isTrue);
      final disabling = state.setShareActivityPresence(false);
      jami.pendingPresenceMetadata = null;
      pending.complete();
      expect(await enabling, isFalse);
      expect(await disabling, isTrue);
      expect(state.shareActivityPresence, isFalse);
      expect(jami.appliedPresenceSharing, isFalse);
      expect(jami.probedPeers, isEmpty);
    });

    test(
      'DHT status 1 alone is NEVER trusted as online (the proxy-held ~24h stale beacon)',
      () {
        jami.push('presence', {'peerJamiId': peer, 'status': 1});
        expect(state.peerPresence, PeerPresence.unknown);
        expect(state.peerOnline, isFalse);
      },
    );

    test(
      'a live channel (status 2) is evidence; a fresh negative (status 0) is unreachable',
      () {
        jami.push('presence', {'peerJamiId': peer, 'status': 2});
        expect(state.peerOnline, isTrue);
        jami.push('presence', {'peerJamiId': peer, 'status': 0});
        expect(state.peerPresence, PeerPresence.unreachable);
        expect(state.peerOnline, isFalse);
      },
    );

    test("a stranger's presence never moves the dot", () {
      jami.push('presence', {'peerJamiId': stranger, 'status': 2});
      expect(state.peerPresence, PeerPresence.unknown);
    });

    test(
      'ping/pong fg flag picks in-app vs reachable; stale queued redeliveries cannot roll it back',
      () {
        jami.push('presenceMsg', {
          'fromJamiId': peer,
          't': 'ping',
          'fg': 1,
          'ts': 10,
          'platform': 'windows',
          'activity': 'Team Fortress 2',
        });
        expect(state.peerPresence, PeerPresence.inApp);
        expect(state.friends[peer]?.presencePlatform, 'windows');
        expect(state.friends[peer]?.presenceActivity, 'Team Fortress 2');
        // The daemon redelivers QUEUED presence messages on reconnect — an OLDER fg:0 must not dim a newer reading.
        jami.push('presenceMsg', {
          'fromJamiId': peer,
          't': 'pong',
          'fg': 0,
          'ts': 5,
          'platform': 'android',
          'activity': 'stale',
        });
        expect(state.peerPresence, PeerPresence.inApp);
        expect(state.friends[peer]?.presencePlatform, 'windows');
        expect(state.friends[peer]?.presenceActivity, 'Team Fortress 2');
        // A genuinely newer fg:0 does.
        jami.push('presenceMsg', {
          'fromJamiId': peer,
          't': 'ping',
          'fg': 0,
          'ts': 20,
          'platform': 'android',
          'activity': '',
        });
        expect(state.peerPresence, PeerPresence.reachable);
        expect(state.friends[peer]?.presencePlatform, 'android');
        expect(state.friends[peer]?.presenceActivity, isEmpty);
      },
    );

    for (final version in [0, 1, 2, 3, 4]) {
      for (final withColor in [false, true]) {
        test('presence version $version acceptance with color=$withColor', () {
          jami.push('presenceMsg', {
            'fromJamiId': peer,
            'v': version,
            't': 'ping',
            'fg': 1,
            'ts': 30,
            'platform': 'windows',
            if (withColor) 'color': 'sage',
          });
          final accepted = version < 2 || (version < 4 && withColor);
          expect(
            state.peerPresence,
            accepted ? PeerPresence.inApp : PeerPresence.unknown,
          );
        });
      }
    }

    test('version 2 presence projects a validated friend color', () {
      jami.push('presenceMsg', {
        'fromJamiId': peer,
        'v': 2,
        't': 'ping',
        'fg': 1,
        'ts': 30,
        'platform': 'windows',
        'activity': '',
        'color': 'sage',
      });

      expect(state.friends[peer]?.identityColor, IdentityColor.sage);
      expect(state.friendsByIdentityColor[IdentityColor.sage], [
        state.friends[peer],
      ]);
      // An equal-timestamp replay cannot rewrite cosmetic metadata.
      jami.push('presenceMsg', {
        'fromJamiId': peer,
        'v': 2,
        't': 'ping',
        'fg': 1,
        'ts': 30,
        'platform': 'windows',
        'activity': '',
        'color': 'rose',
      });
      expect(state.friends[peer]?.identityColor, IdentityColor.sage);

      jami.push('presenceMsg', {
        'fromJamiId': peer,
        'v': 2,
        't': 'pong',
        'fg': 0,
        'ts': 31,
        'platform': 'android',
        'activity': '',
        'color': 'ultraviolet',
      });
      expect(state.friends[peer]?.identityColor, IdentityColor.sage);
    });

    test('wake capability is cached without promoting presence', () async {
      final handle = 'A' * 43;
      jami.push('wakeCapability', {'fromJamiId': peer, 'handle': handle});
      await pumpEventQueue();

      expect(state.peerPresence, PeerPresence.unknown);
      final cached =
          jsonDecode(state.prefs.getString('wakeCapabilitiesV1')!)
              as Map<String, dynamic>;
      expect(cached[peer], [handle]);

      jami.push('wakeCapability', {'fromJamiId': stranger, 'handle': 'B' * 43});
      await pumpEventQueue();
      final unchanged =
          jsonDecode(state.prefs.getString('wakeCapabilitiesV1')!)
              as Map<String, dynamic>;
      expect(unchanged, isNot(contains(stranger)));
    });

    test(
      'event diagnostics exclude short private payloads and unknown types',
      () async {
        state.clearDebugLog();
        final secret = 'C' * 43;
        final payload = <String, dynamic>{
          'handle': secret,
          'fromJamiId': peer,
          'name': 'Private name',
          'path': '/private/photo',
          'error': 'private failure',
          'filename': 'private.png',
          'body': 'private message',
        };
        for (final category in [
          'wakeCapability',
          'backgroundWakeReady',
          'friendProfile',
          'chatMessage',
          'remoteClipboardResult',
          'unknown-private',
        ]) {
          jami.push(category, payload);
        }
        await pumpEventQueue();
        final copiedLog = state.debugLog.reversed.join('\n');
        expect(copiedLog, contains('· wakeCapability'));
        expect(copiedLog, contains('· backgroundWakeReady'));
        for (final value in [...payload.values, 'unknown-private']) {
          expect(copiedLog, isNot(contains(value)));
        }
      },
    );

    test(
      'friend color cache survives restart and leaves with the friend',
      () async {
        jami.push('presenceMsg', {
          'fromJamiId': peer,
          'v': 2,
          't': 'ping',
          'fg': 1,
          'ts': 30,
          'platform': 'android',
          'activity': '',
          'color': 'teal',
        });
        await Future<void>.delayed(Duration.zero);
        final cached = state.prefs.getString('friendIdentityColor.v1.$peer');
        expect(cached, 'teal');

        state.dispose();
        booted = false;
        await boot({
          'displayName': 'Me',
          'peerId': peer,
          'friendIdentityColor.v1.$peer': cached!,
        });
        expect(state.friends[peer]?.identityColor, IdentityColor.teal);

        await state.removeFriend(peer);
        expect(
          state.prefs.containsKey('friendIdentityColor.v1.$peer'),
          isFalse,
        );
        await state.addFriend(peer);
        expect(state.friends[peer]?.identityColor, isNull);
      },
    );

    test('unknown or permissive versioned presence is ignored', () {
      for (final packet in [
        {'v': 2, 'fg': 1, 'ts': 10, 'platform': 'android'},
        {'v': 1, 'fg': -1, 'ts': 10, 'platform': 'android'},
        {'v': 1, 'fg': 1, 'ts': 0, 'platform': 'android'},
        {'v': 1, 't': 'maybe', 'fg': 1, 'ts': 10, 'platform': 'android'},
        {'v': 0, 't': 'ping', 'fg': -1, 'ts': 0, 'platform': ''},
      ]) {
        jami.push('presenceMsg', {
          'fromJamiId': peer,
          't': packet['t'] ?? 'ping',
          'activity': '',
          ...packet,
        });
      }
      expect(state.peerPresence, PeerPresence.unknown);
    });

    test('an incoming ring is free presence truth', () {
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      expect(state.call, isNotNull);
      expect(state.peerOnline, isTrue);
    });
  });

  test(
    'launch and live invite links stage one explicit-confirmation hint',
    () async {
      final launch = SyblInviteLink.create(
        jamiId: stranger,
        displayName: 'Mara',
      )!;
      await boot(
        {'displayName': 'Me', 'peerId': peer},
        configure: (jami) {
          jami.initialInviteLink = launch.canonicalUri;
        },
      );

      expect(state.pendingInvite, launch);
      jami.push('inviteLink', {'link': 'sybl://remove/$stranger'});
      expect(state.pendingInvite, launch, reason: 'invalid links are inert');
      expect(
        await state.inviteContinuation.discard(
          state.inviteContinuation.pending!,
        ),
        isTrue,
      );
      expect(state.pendingInvite, isNull);

      final live = SyblInviteLink.create(
        jamiId: stranger,
        displayName: 'Phone Mara',
      )!;
      jami.push('inviteLink', {'link': live.canonicalUri});
      expect(state.pendingInvite, live);
    },
  );

  group('call lifecycle reducer', () {
    setUp(() => boot({'displayName': 'Me', 'peerId': peer}));

    test('a failed incoming ring never blames the receiver', () {
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {'callId': 'c1', 'state': 'FAILURE'});
      expect(state.call, isNull);
      expect(state.callEndedNote, isNull);
    });

    test('a normal hangup after a connected call shows no note', () {
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {'callId': 'c1', 'state': 'CURRENT'});
      jami.push('callState', {'callId': 'c1', 'state': 'HUNGUP'});
      expect(state.call, isNull);
      expect(state.callEndedNote, isNull);
    });

    test("a stale callId's terminal state cannot kill the live call", () {
      jami.push('incomingCall', {'callId': 'c2', 'fromJamiId': peer});
      jami.push('callState', {'callId': 'c1', 'state': 'FAILURE'});
      expect(state.call, isNotNull);
    });

    // Refusing a second call is the DAEMON's job (Account.denySecondCall). Hand-refusing here landed ~185 ms
    // before libjami's own glare arbitration and killed both calls — so we keep showing the first call and
    // issue no command at all for the second.
    test(
      'a second incoming call is left to the daemon and does not replace the visible call',
      () {
        jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
        jami.push('incomingCall', {'callId': 'c2', 'fromJamiId': peer});
        expect(state.call?.callId, 'c1');
        expect(jami.calls, isNot(contains('refuse:c2')));
        expect(jami.calls, isNot(contains('hangUp:c2')));
      },
    );

    test(
      'a still-ringing crossed leg is promoted when the displayed pre-CURRENT leg dies',
      () {
        jami.push('incomingCall', {'callId': 'displayed', 'fromJamiId': peer});
        jami.push('incomingCall', {
          'callId': 'hidden',
          'fromJamiId': peer,
          'withVideo': true,
        });

        jami.push('callState', {'callId': 'displayed', 'state': 'OVER'});

        expect(state.call?.callId, 'hidden');
        expect(state.call?.state, 'RINGING');
        expect(state.call?.peerVideo, isTrue);
        expect(state.callEndedNote, isNull);
        expect(jami.calls, isNot(contains('refuse:hidden')));
        expect(jami.calls, isNot(contains('hangUp:hidden')));
      },
    );

    test(
      'a CURRENT winner retires a hidden incoming sibling instead of promoting it after hangup',
      () {
        jami.push('incomingCall', {'callId': 'displayed', 'fromJamiId': peer});
        jami.push('incomingCall', {
          'callId': 'hidden',
          'fromJamiId': peer,
          'withVideo': true,
        });
        expect(
          jami.calls,
          isNot(contains('refuse:hidden')),
        ); // no command before arbitration is complete

        jami.push('callState', {
          'callId': 'displayed',
          'state': 'CURRENT',
          'fromJamiId': peer,
        });
        expect(jami.calls, contains('refuse:hidden'));

        jami.push('callState', {
          'callId': 'displayed',
          'state': 'HUNGUP',
          'fromJamiId': peer,
        });
        expect(state.call, isNull);

        // A native replay and even a late CURRENT from the loser remain tombstoned and cannot resurrect the call.
        jami.push('incomingCall', {
          'callId': 'hidden',
          'fromJamiId': peer,
          'withVideo': true,
        });
        expect(state.call, isNull);
        expect(jami.calls.where((c) => c == 'refuse:hidden').length, 2);
        jami.push('callState', {
          'callId': 'hidden',
          'state': 'CURRENT',
          'fromJamiId': peer,
        });
        expect(state.call, isNull);
        expect(jami.calls, contains('hangUp:hidden'));
        jami.push('callState', {
          'callId': 'hidden',
          'state': 'OVER',
          'fromJamiId': peer,
        });
      },
    );

    test(
      'an incoming ring after CURRENT is refused and cannot surface after the winner ends',
      () {
        jami.push('incomingCall', {'callId': 'current', 'fromJamiId': peer});
        jami.push('callState', {'callId': 'current', 'state': 'CURRENT'});
        jami.push('incomingCall', {
          'callId': 'denied-second',
          'fromJamiId': peer,
        });

        expect(jami.calls, contains('refuse:denied-second'));

        jami.push('callState', {'callId': 'current', 'state': 'HUNGUP'});

        expect(state.call, isNull);
        jami.push('callState', {
          'callId': 'denied-second',
          'state': 'CURRENT',
          'fromJamiId': peer,
        });
        expect(state.call, isNull);
        expect(jami.calls, contains('hangUp:denied-second'));
        jami.push('callState', {
          'callId': 'denied-second',
          'state': 'OVER',
          'fromJamiId': peer,
        });
      },
    );

    test('only the first configured-peer CURRENT is authoritative', () {
      jami.push('incomingCall', {'callId': 'first', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'first',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      jami.push('callState', {
        'callId': 'second',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });

      expect(state.call?.callId, 'first');
      expect(jami.calls, contains('hangUp:second'));
      jami.push('callState', {
        'callId': 'first',
        'state': 'HUNGUP',
        'fromJamiId': peer,
      });
      jami.push('callState', {
        'callId': 'second',
        'state': 'OVER',
        'fromJamiId': peer,
      });
      expect(state.call, isNull);
    });

    test(
      'a configured-peer CURRENT preserves UI preferences and adopts native media truth',
      () {
        jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
        final previous = state.call!;
        previous.micMode = MicrophoneMode.pushToTalk;
        previous.selfTextureId = 41;
        previous.remoteTextureId = 42;
        jami.push('callState', {
          'callId': 'crossed',
          'state': 'CURRENT',
          'fromJamiId': peer,
          'cameraOn': 'true',
          'micMuted': 'true',
          'speakerOn': 'true',
          'peerVideo': 'true',
          'selfActive': 'true',
          'remoteActive': 'true',
        });
        expect(state.call?.callId, 'crossed');
        expect(state.call?.everConnected, isTrue);
        expect(state.call?.micMode, MicrophoneMode.pushToTalk);
        expect(state.call?.micMuted, isTrue);
        expect(state.call?.speakerOn, isTrue);
        expect(state.call?.cameraOn, isTrue);
        expect(state.call?.selfTextureId, 41);
        expect(state.call?.remoteTextureId, 42);
        jami.push('cameraState', {'callId': 'c1', 'cameraOn': false});
        expect(
          state.call?.cameraOn,
          isTrue,
        ); // stale loser cannot change winner media
        jami.push('cameraState', {'callId': 'crossed', 'cameraOn': false});
        expect(state.call?.cameraOn, isFalse);
        jami.push('cameraState', {'callId': 'crossed', 'cameraOn': true});
        expect(state.call?.cameraOn, isTrue);
        // our old leg dying afterwards must not clear the adopted call
        jami.push('callState', {'callId': 'c1', 'state': 'OVER'});
        expect(state.call?.callId, 'crossed');
      },
    );

    test(
      'mute after CURRENT adoption targets the winner and ignores the loser terminal',
      () async {
        jami.push('incomingCall', {'callId': 'old-leg', 'fromJamiId': peer});
        jami.push('callState', {
          'callId': 'winner',
          'state': 'CURRENT',
          'fromJamiId': peer,
          'micMuted': false,
        });
        await pumpEventQueue(times: 5);

        await state.toggleMute();
        expect(jami.calls, contains('setMicMuted:winner:true'));
        jami.push('callState', {
          'callId': 'old-leg',
          'state': 'OVER',
          'fromJamiId': peer,
        });
        expect(state.call?.callId, 'winner');
        expect(state.call?.micMuted, isTrue);

        await state.toggleMute();
        expect(jami.calls, contains('setMicMuted:winner:false'));
      },
    );

    test(
      'terminal-first delivery rebuilds an adopted call from the native snapshot',
      () async {
        jami.push('incomingCall', {'callId': 'old', 'fromJamiId': peer});
        jami.push('callState', {'callId': 'old', 'state': 'OVER'});
        expect(state.call, isNull);

        jami.push('callState', {
          'callId': 'crossed',
          'state': 'CURRENT',
          'fromJamiId': peer,
          'cameraOn': true,
          'micMuted': true,
          'speakerOn': false,
          'peerVideo': true,
          'selfActive': true,
          'remoteActive': true,
        });
        await Future<void>.delayed(Duration.zero);

        expect(state.call?.callId, 'crossed');
        expect(state.call?.micMuted, isTrue);
        expect(state.call?.cameraOn, isTrue);
        expect(state.call?.selfTextureId, isNotNull);
        expect(state.call?.remoteTextureId, isNotNull);
        expect(state.callEndedNote, isNull);
      },
    );

    test(
      'an unmatched CURRENT not bound to the configured peer is ignored',
      () {
        jami.push('incomingCall', {'callId': 'visible', 'fromJamiId': peer});
        jami.push('callState', {
          'callId': 'other',
          'state': 'CURRENT',
          'fromJamiId': stranger,
        });
        jami.push('callState', {'state': 'CURRENT', 'fromJamiId': peer});

        expect(state.call?.callId, 'visible');
      },
    );

    test('a replay of the same pending incoming call is idempotent', () {
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      expect(state.call?.callId, 'c1');
      expect(jami.calls, isNot(contains('refuse:c1')));
    });

    test('Windows string-valued incoming video is shown as video', () {
      jami.push('incomingCall', {
        'callId': 'video-in',
        'fromJamiId': peer,
        'withVideo': 'true',
      });

      expect(state.call?.peerVideo, isTrue);
    });

    test(
      'initial peer camera is drawable and an off event retires that annotation target',
      () {
        jami.push('incomingCall', {
          'callId': 'video-in',
          'fromJamiId': peer,
          'withVideo': true,
        });
        jami.push('callState', {
          'callId': 'video-in',
          'state': 'CURRENT',
          'fromJamiId': peer,
          'peerVideo': true,
        });

        expect(state.call?.peerVideoKind, OutgoingVideoKind.camera);
        expect(state.annotation.canTargetTheirs, isTrue);
        expect(state.annotation.target, AnnotationTarget.theirs);

        jami.push('peerVideo', {
          'callId': 'video-in',
          'on': false,
          // Android used to include its default camera source kind even for an
          // empty offer. `on` is authoritative and must win.
          'sourceKind': 'camera',
        });

        expect(state.call?.peerVideoKind, OutgoingVideoKind.off);
        expect(state.annotation.canTargetTheirs, isFalse);
        expect(state.annotation.target, isNull);
      },
    );

    test(
      'a call from a contact absent from the current daemon snapshot is refused',
      () {
        jami.push('incomingCall', {
          'callId': 'stranger-call',
          'fromJamiId': stranger,
        });
        expect(state.call, isNull);
        expect(jami.calls, contains('refuse:stranger-call'));
      },
    );
  });

  group('outgoing call startup races', () {
    Future<void> bootReady() async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('registrationState', {'state': 'REGISTERED'});
      jami.push('deviceAnnounced', {'accountId': 'acc1', 'announced': true});
    }

    test(
      'CURRENT delivered before placeCall returns is replayed onto the new session',
      () async {
        await bootReady();
        jami.callStateDuringPlace = 'CURRENT';
        await state.startCall(withVideo: true);
        expect(state.call?.state, 'CURRENT');
        expect(state.call?.everConnected, isTrue);
        expect(state.call?.selfTextureId, isNotNull);
        expect(state.call?.remoteTextureId, isNotNull);
        expect(
          jami.textureCalls,
          2,
        ); // one producer per role despite CURRENT racing the MethodChannel reply
      },
    );

    test(
      'terminal state delivered before placeCall returns cannot leave a phantom call',
      () async {
        await bootReady();
        jami.callStateDuringPlace = 'FAILURE';
        await state.startCall(withVideo: true);
        expect(state.call, isNull);
        expect(state.callEndedNote, "Couldn't reach them — try again");
        expect(jami.textureCalls, 0);
      },
    );

    test(
      'a registered account places immediately without waiting for deviceAnnounced',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        jami.push('registrationState', {'state': 'REGISTERED'});

        await state.startCall();

        expect(state.ready, isFalse);
        expect(jami.calls, contains('place:out1'));
        expect(state.call?.callId, 'out1');
      },
    );

    test(
      'an incoming call landing mid-placement leaves both glare legs to the daemon',
      () async {
        await bootReady();
        jami.incomingDuringPlace = true;

        await state.startCall();

        expect(state.call?.callId, 'incoming1');
        expect(jami.calls, contains('place:out1'));
        expect(jami.calls, isNot(contains('hangUp:out1')));
        expect(jami.calls, isNot(contains('refuse:incoming1')));
      },
    );

    test(
      'a phone-style video placement loser is retired only after the incoming leg is CURRENT',
      () async {
        await bootReady();
        jami.incomingDuringPlace = true;

        await state.startCall(withVideo: true);

        expect(state.call?.callId, 'incoming1');
        expect(
          jami.calls,
          isNot(contains('hangUp:out1')),
        ); // preserve libjami arbitration before CURRENT

        jami.push('callState', {
          'callId': 'incoming1',
          'state': 'CURRENT',
          'fromJamiId': peer,
        });
        expect(jami.calls, contains('hangUp:out1'));

        jami.push('callState', {
          'callId': 'incoming1',
          'state': 'HUNGUP',
          'fromJamiId': peer,
        });
        expect(state.call, isNull);
        jami.push('callState', {
          'callId': 'out1',
          'state': 'CURRENT',
          'fromJamiId': peer,
        });
        expect(state.call, isNull);
        expect(jami.calls.where((c) => c == 'hangUp:out1').length, 2);
        jami.push('callState', {
          'callId': 'out1',
          'state': 'OVER',
          'fromJamiId': peer,
        });
      },
    );

    test(
      'a placement loser terminal before reply does not create a post-terminal tombstone',
      () async {
        await bootReady();
        jami.incomingDuringPlace = true;
        jami.extraEventsDuringPlace.addAll([
          JamiEvent('callState', {
            'callId': 'incoming1',
            'state': 'CURRENT',
            'fromJamiId': peer,
          }),
          JamiEvent('callState', {
            'callId': 'out1',
            'state': 'OVER',
            'fromJamiId': peer,
          }),
        ]);

        await state.startCall(withVideo: true);

        expect(state.call?.callId, 'incoming1');
        expect(state.call?.state, 'CURRENT');
        expect(
          jami.calls,
          isNot(contains('hangUp:out1')),
        ); // native already delivered the loser's final terminal
      },
    );

    test(
      'an ended incoming winner still defeats a slow video placement reply',
      () async {
        await bootReady();
        jami.incomingDuringPlace = true;
        jami.extraEventsDuringPlace.addAll([
          JamiEvent('callState', {
            'callId': 'incoming1',
            'state': 'CURRENT',
            'fromJamiId': peer,
          }),
          JamiEvent('callState', {
            'callId': 'incoming1',
            'state': 'HUNGUP',
            'fromJamiId': peer,
          }),
          JamiEvent('callState', {
            'callId': 'out1',
            'state': 'CURRENT',
            'fromJamiId': peer,
          }),
        ]);

        await state.startCall(withVideo: true);

        expect(state.call, isNull);
        expect(jami.calls, contains('hangUp:out1'));
        jami.push('callState', {
          'callId': 'out1',
          'state': 'OVER',
          'fromJamiId': peer,
        });
      },
    );

    test(
      'CURRENT during a crossed placement adopts our native winner without hanging it up',
      () async {
        await bootReady();
        jami.incomingDuringPlace = true;
        jami.callStateDuringPlace = 'CURRENT';
        jami.callStateBeforeIncoming = true;
        jami.callStateDataDuringPlace = {
          'cameraOn': 'true',
          'micMuted': 'false',
          'speakerOn': 'false',
          'peerVideo': 'true',
          'selfActive': 'true',
          'remoteActive': 'true',
        };

        await state.startCall(withVideo: true);

        expect(state.call?.callId, 'out1');
        expect(state.call?.cameraOn, isTrue);
        expect(jami.calls, isNot(contains('hangUp:out1')));
      },
    );

    test(
      'an audio-only native fallback clears camera state and skips textures',
      () async {
        await bootReady();
        jami.placedCameraOn = false;

        await state.startCall(withVideo: true);

        expect(state.call?.cameraOn, isFalse);
        expect(state.call?.selfTextureId, isNull);
        expect(state.call?.remoteTextureId, isNull);
        expect(jami.textureCalls, 0);
      },
    );

    test(
      'an early buffered cameraState(false) beats the intent-first placement result',
      () async {
        // Intent-first: placeCall replies cameraOn=true (intent accepted) while capture is still
        // asynchronous. A capture failure reported before the reply must not be dropped by the
        // early-event buffer, and textures must follow the session truth, not the placement result.
        await bootReady();
        jami.extraEventsDuringPlace.add(
          JamiEvent('cameraState', {'callId': 'out1', 'cameraOn': false}),
        );

        await state.startCall(withVideo: true);

        expect(state.call?.callId, 'out1');
        expect(state.call?.cameraOn, isFalse);
        expect(state.call?.selfTextureId, isNull);
        expect(jami.textureCalls, 0);
      },
    );

    test(
      'a stale camera-enable completion cannot overwrite a newer native camera-off',
      () async {
        await bootReady();
        await state.startCall();
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        jami.pendingStartVideo = Completer<bool>();

        final enabling = state.toggleCamera();
        await Future<void>.delayed(Duration.zero);
        // Native reconciled this attempt off (capture failure) while startVideo's reply was in flight.
        jami.push('cameraState', {'callId': 'out1', 'cameraOn': false});
        jami.pendingStartVideo!.complete(true);
        await enabling;

        expect(state.call?.cameraOn, isFalse);
        expect(state.call?.cameraChanging, isFalse);
        expect(jami.textureCalls, 0);
      },
    );

    test(
      'a same-value native snapshot invalidates a pending camera-enable completion',
      () async {
        await bootReady();
        await state.startCall();
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        jami.pendingStartVideo = Completer<bool>();

        final enabling = state.toggleCamera();
        await Future<void>.delayed(Duration.zero);
        expect(state.call?.cameraOn, isFalse);

        // This false matches the current mirror, but its presence in a native snapshot is still newer truth.
        jami.push('callState', {
          'callId': 'out1',
          'state': 'CURRENT',
          'cameraOn': false,
        });
        jami.pendingStartVideo!.complete(true);
        await enabling;

        expect(state.call?.cameraOn, isFalse);
        expect(state.call?.cameraChanging, isFalse);
        expect(jami.textureCalls, 0);
      },
    );

    test(
      'a same-value native snapshot invalidates a rejected camera-stop rollback',
      () async {
        await bootReady();
        await state.startCall(withVideo: true);
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        jami.pendingStopVideo = Completer<bool>();

        final stopping = state.toggleCamera();
        await Future<void>.delayed(Duration.zero);
        expect(state.call?.cameraOn, isFalse); // optimistic local Off

        // Native confirms the same Off while stopVideo is pending; its later false return is now stale.
        jami.push('callState', {
          'callId': 'out1',
          'state': 'CURRENT',
          'cameraOn': false,
        });
        jami.pendingStopVideo!.complete(false);
        await stopping;

        expect(state.call?.cameraOn, isFalse);
        expect(state.call?.cameraChanging, isFalse);
      },
    );

    test(
      'camera-off during pending texture creation does not install stale textures',
      () async {
        await bootReady();
        await state.startCall();
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        jami.pendingTexture = Completer<int>();

        final enabling = state.toggleCamera();
        await Future<void>.delayed(Duration.zero);
        expect(state.call?.cameraOn, isTrue);
        expect(
          jami.textureCalls,
          1,
        ); // self texture allocation is awaiting native

        jami.push('cameraState', {'callId': 'out1', 'cameraOn': false});
        jami.pendingTexture!.complete(7);
        await enabling;

        expect(state.call?.cameraOn, isFalse);
        expect(state.call?.selfTextureId, isNull);
        expect(state.call?.remoteTextureId, isNull);
        expect(
          jami.textureCalls,
          1,
        ); // the stale self completion must not launch remote allocation
      },
    );

    test(
      'a capture-failure downgrade keeps the call alive and a post-terminal report is inert',
      () async {
        await bootReady();
        await state.startCall(withVideo: true);
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        expect(state.call?.cameraOn, isTrue);

        jami.push('cameraState', {'callId': 'out1', 'cameraOn': false});
        expect(
          state.call?.state,
          'CURRENT',
        ); // audio call survives the camera downgrade
        expect(state.call?.cameraOn, isFalse);

        jami.push('callState', {'callId': 'out1', 'state': 'HUNGUP'});
        expect(state.call, isNull);
        jami.push('cameraState', {
          'callId': 'out1',
          'cameraOn': true,
        }); // stale truth for a dead call
        expect(state.call, isNull);
      },
    );

    test(
      'camera enable is single-flight and a late result cannot affect a replacement call',
      () async {
        await bootReady();
        await state.startCall();
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        jami.pendingStartVideo = Completer<bool>();

        final first = state.toggleCamera();
        await Future<void>.delayed(Duration.zero);
        await state.toggleCamera();
        expect(jami.startVideoCalls, 1);
        expect(state.call?.cameraChanging, isTrue);

        jami.push('callState', {'callId': 'out1', 'state': 'OVER'});
        jami.push('incomingCall', {'callId': 'incoming2', 'fromJamiId': peer});
        jami.push('callState', {'callId': 'incoming2', 'state': 'CURRENT'});
        jami.pendingStartVideo!.complete(true);
        await first;

        expect(state.call?.callId, 'incoming2');
        expect(state.call?.cameraOn, isFalse);
        expect(jami.calls, contains('startVideo:out1'));
        expect(jami.textureCalls, 0);
      },
    );

    test(
      'flip is refused mid-camera-transition and works once it settles',
      () async {
        await bootReady();
        await state.startCall();
        jami.push('callState', {'callId': 'out1', 'state': 'CURRENT'});
        jami.pendingTexture = Completer<int>();

        final enabling = state.toggleCamera();
        await Future<void>.delayed(Duration.zero);
        // The window the UI used to guard: native said yes, so cameraOn reads true while textures are still awaiting.
        expect(state.call?.cameraOn, isTrue);
        expect(state.call?.cameraChanging, isTrue);

        await state.switchCamera();
        expect(jami.calls, isNot(contains('switchCamera')));

        jami.pendingTexture!.complete(7);
        await enabling;
        expect(state.call?.cameraChanging, isFalse);

        await state.switchCamera();
        expect(jami.calls, contains('switchCamera'));
      },
    );

    test(
      'an already-live outgoing camera can be stopped while the call is ringing',
      () async {
        await bootReady();
        await state.startCall(withVideo: true);
        expect(state.call?.connected, isFalse);
        expect(state.call?.cameraOn, isTrue);
        await state.toggleCamera();
        expect(jami.calls, contains('stopVideo:out1'));
        expect(state.call?.cameraOn, isFalse);
      },
    );

    test(
      'a rejected native camera stop rolls the optimistic control back on',
      () async {
        await bootReady();
        await state.startCall(withVideo: true);
        jami.stopVideoResult = false;
        await state.toggleCamera();
        expect(state.call?.cameraOn, isTrue);
        expect(state.call?.cameraChanging, isFalse);
      },
    );

    for (final action in ['Accept', 'Decline']) {
      testWidgets('stale $action button cannot act on a replacement call', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = null;
        await bootReady();
        jami.push('incomingCall', {'callId': 'old', 'fromJamiId': peer});
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: IncomingScreen(state: state),
          ),
        );
        final callback = tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == action,
              ),
            )
            .onPressed!;
        jami.push('callState', {'callId': 'old', 'state': 'OVER'});
        jami.push('incomingCall', {
          'callId': 'replacement',
          'fromJamiId': peer,
        });
        jami.calls.clear();
        // Deliberately do not pump: this is the button the user still sees.
        callback();
        expect(
          jami.calls.where(
            (entry) =>
                entry.startsWith('answer:') || entry.startsWith('refuse:'),
          ),
          isEmpty,
        );
        expect(state.call?.callId, 'replacement');
        await tester.pumpWidget(const SizedBox());
        if (action == 'Accept') {
          await state.answer(state.call!);
          expect(jami.calls, contains('answer:replacement'));
        } else {
          await state.decline(state.call!);
          expect(jami.calls, contains('refuse:replacement'));
        }
      });
    }

    test(
      'a late decline completion cannot clear a replacement incoming call',
      () async {
        await bootReady();
        jami.push('incomingCall', {'callId': 'old', 'fromJamiId': peer});
        jami.pendingRefuse = Completer<void>();
        final declining = state.decline(state.call!);
        await Future<void>.delayed(Duration.zero);
        jami.push('callState', {'callId': 'old', 'state': 'OVER'});
        jami.push('incomingCall', {
          'callId': 'replacement',
          'fromJamiId': peer,
        });
        jami.pendingRefuse!.complete();
        await declining;
        expect(state.call?.callId, 'replacement');
      },
    );

    test(
      'a late hang-up completion cannot reset replacement-call annotations',
      () async {
        await bootReady();
        jami.push('incomingCall', {'callId': 'old', 'fromJamiId': peer});
        state.annotation.syncSources(
          localOwner: state.jamiId,
          peerOwner: peer,
          localRevision: 1,
          localKind: OutgoingVideoKind.screen,
          peerKind: OutgoingVideoKind.off,
        );
        state.annotation.setEnabled(true);
        jami.pendingHangUp = Completer<void>();
        final hangingUp = state.hangUp();
        await Future<void>.delayed(Duration.zero);
        expect(state.annotation.enabled, isFalse);
        jami.push('callState', {'callId': 'old', 'state': 'OVER'});
        jami.push('incomingCall', {
          'callId': 'replacement',
          'fromJamiId': peer,
        });
        state.annotation.syncSources(
          localOwner: state.jamiId,
          peerOwner: peer,
          localRevision: 2,
          localKind: OutgoingVideoKind.screen,
          peerKind: OutgoingVideoKind.off,
        );
        state.annotation.setEnabled(true);
        jami.pendingHangUp!.complete();
        await hangingUp;
        expect(state.call?.callId, 'replacement');
        expect(state.annotation.enabled, isTrue);
      },
    );
  });

  group('failed commands keep user-visible state retryable', () {
    test('appear-offline rolls back when the platform channel fails', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('presence', {'peerJamiId': peer, 'status': 2});
      jami.failAppearOffline = true;
      await state.setAppearOffline(true);
      expect(state.appearOffline, isFalse);
      expect(state.peerPresence, PeerPresence.reachable);
      expect(state.prefs.getBool('appearOffline'), isFalse);
    });

    test(
      'connection profile rolls back when the platform channel fails',
      () async {
        await boot({'displayName': 'Me'});
        jami.failConnectionProfile = true;
        await state.setConnectionProfile('lan');
        expect(state.connectionProfile, 'jami');
        expect(state.prefs.getString('connectionProfile'), 'jami');
      },
    );

    test(
      'a probe completing after appear-offline cannot arm a stale verdict',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        await state.setShareActivityPresence(true);
        jami.pendingProbe = Completer<String>();
        final probing = state.refreshPresence();
        await Future<void>.delayed(Duration.zero);
        await state.setAppearOffline(true);
        jami.pendingProbe!.complete('late-probe');
        await probing;
        jami.push('registrationState', {
          'accountId': 'acc1',
          'state': 'REGISTERED',
        });
        jami.push('deviceAnnounced', {'accountId': 'acc1', 'announced': true});
        jami.push('presence', {
          'accountId': 'acc1',
          'peerJamiId': peer,
          'status': 2,
        });
        jami.push('messageStatus', {'messageId': 'late-probe', 'state': 4});
        expect(state.peerPresence, PeerPresence.unknown);
        expect(state.ready, isFalse);
        expect(state.registration, 'UNREGISTERED');
      },
    );

    test('failed audio controls roll their optimistic state back', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'audio-call', 'fromJamiId': peer});
      jami.push('callState', {'callId': 'audio-call', 'state': 'CURRENT'});
      jami.throwAudioControl = true;
      await state.toggleMute();
      await state.toggleSpeaker();
      expect(state.call?.micMuted, isFalse);
      expect(state.call?.speakerOn, isFalse);
    });

    test(
      'mute and PTT commands stay scoped and the conversation mode persists',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        jami.push('incomingCall', {'callId': 'audio-call', 'fromJamiId': peer});
        jami.push('callState', {
          'callId': 'audio-call',
          'state': 'CURRENT',
          'fromJamiId': peer,
        });
        await pumpEventQueue(times: 5);

        await state.toggleMute();
        await state.toggleMute();
        await state.toggleMute();
        await state.setMicMode(MicrophoneMode.pushToTalk);
        await state.pttHold(true);
        await state.pttHold(false);

        expect(jami.calls.where((c) => c.startsWith('setMicMuted:')).toList(), [
          'setMicMuted:audio-call:true',
          'setMicMuted:audio-call:false',
          'setMicMuted:audio-call:true',
          'setMicMuted:audio-call:false',
          'setMicMuted:audio-call:true',
          'setMicMuted:audio-call:true',
          'setMicMuted:audio-call:false',
          'setMicMuted:audio-call:true',
        ]);

        jami.push('callState', {
          'callId': 'audio-call',
          'state': 'HUNGUP',
          'fromJamiId': peer,
        });
        jami.push('incomingCall', {'callId': 'next-call', 'fromJamiId': peer});
        jami.push('callState', {
          'callId': 'next-call',
          'state': 'CURRENT',
          'fromJamiId': peer,
          'micMuted': false,
        });
        await Future<void>.delayed(Duration.zero);
        expect(state.call?.micMode, MicrophoneMode.pushToTalk);
        expect(state.call?.micMuted, isTrue);
        expect(jami.calls, contains('setMicMuted:next-call:true'));
        await state.pttHold(true);
        expect(jami.calls, contains('setMicMuted:next-call:false'));
      },
    );

    test(
      'a failed trust decision restores the request card for retry',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        jami.failConnectDecision = true;
        jami.push('connectRequest', {
          'conversationId': 'conv1',
          'fromJamiId': stranger,
        });
        await state.allowConnect();
        expect(state.pendingConnect?.convId, 'conv1');
        expect(state.handlingConnect, isFalse);
      },
    );

    test(
      'a failed ignore decision also restores the request card for retry',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        jami.failConnectDecision = true;
        jami.push('connectRequest', {
          'conversationId': 'conv2',
          'fromJamiId': stranger,
        });
        await state.ignoreConnect();
        expect(state.pendingConnect?.convId, 'conv2');
        expect(state.handlingConnect, isFalse);
      },
    );

    test('a trusted friend group invitation still requires consent', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('connectRequest', {
        'conversationId': 'conv3',
        'fromJamiId': peer,
        'isGroup': true,
      });
      await Future<void>.delayed(Duration.zero);

      expect(state.pendingConnect?.convId, 'conv3');
      expect(state.pendingConnect?.fromJamiId, peer);
      expect(state.pendingConnect?.isGroup, isTrue);
      expect(jami.calls, isNot(contains('acceptConnect:conv3')));

      await state.allowConnect();
      expect(state.pendingConnect, isNull);
      expect(jami.calls, contains('acceptConnect:conv3'));
    });

    test(
      'post-accept peer setup failure does not resurrect the consumed request',
      () async {
        await boot({'displayName': 'Me'});
        jami.failSubscribePresence = true;
        jami.push('connectRequest', {
          'conversationId': 'conv4',
          'fromJamiId': stranger,
        });

        await state.allowConnect();

        expect(jami.calls, contains('acceptConnect:conv4'));
        expect(jami.calls, contains('subscribe:$stranger'));
        expect(state.pendingConnect, isNull);
        expect(state.peerId, stranger);
        expect(state.handlingConnect, isFalse);
      },
    );

    test('friend request names are bounded, unverified hints', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('connectRequest', {
        'conversationId': 'conv-hint',
        'fromJamiId': stranger,
        'name': '\u202eMa\u0007ra\u2066  ',
      });
      jami.push('connectRequest', {
        'conversationId': 'conv-long',
        'fromJamiId': otherFriend,
        'name': 'x' * 10000,
      });
      jami.push('connectRequest', {
        'conversationId': 'conv-group',
        'fromJamiId': peer,
        'isGroup': true,
        'name': 'Group title',
      });
      await Future<void>.delayed(Duration.zero);

      expect(state.nameHint(stranger), 'Mara');
      expect(state.nameHint(otherFriend), isNull);
      expect(state.nameHint(peer), isNull);
      expect(friendNameHint(' \u200f\u0000 '), isNull);
      expect(friendNameHint('bad${String.fromCharCode(0xd800)}'), isNull);
      expect(friendNameHint(42), isNull);
      expect(friendNameHint('é' * 100)?.runes.length, 64);
    });

    test(
      'an outgoing hint labels the contact until its profile arrives',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        expect(await state.addFriend(stranger, nameHint: 'Mara'), isTrue);
        expect(await state.addFriend(otherFriend), isTrue);
        expect(friendLabel(state.friends[stranger]!), 'Mara');
        expect(state.friends[stranger]!.displayName, isEmpty);
        expect(friendLabel(state.friends[otherFriend]!), 'Friend · dddd');

        jami.daemonFriends[stranger] = const JamiFriend(
          peerJamiId: stranger,
          confirmed: true,
          conversationId: strangerConversation,
          displayName: 'Real Mara',
        );
        jami.friendsRevision++;
        jami.push('friendsChanged', {});
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(friendLabel(state.friends[stranger]!), 'Real Mara');
        expect(state.nameHint(stranger), isNull);
      },
    );

    test(
      'an outgoing hint survives a restart until the profile arrives',
      () async {
        await boot({'displayName': 'Me', 'peerId': peer});
        expect(await state.addFriend(stranger, nameHint: 'Mara'), isTrue);
        final prefs = await SharedPreferences.getInstance();
        final saved = <String, Object>{
          for (final key in prefs.getKeys()) key: prefs.get(key)!,
        };
        final daemon = Map.of(jami.daemonFriends);
        state.dispose();
        booted = false;

        await boot(
          saved,
          configure: (jami) => jami.daemonFriends.addAll(daemon),
        );
        expect(friendLabel(state.friends[stranger]!), 'Mara');

        jami.daemonFriends[stranger] = const JamiFriend(
          peerJamiId: stranger,
          confirmed: true,
          conversationId: strangerConversation,
          displayName: 'Real Mara',
        );
        jami.friendsRevision++;
        jami.push('friendsChanged', {});
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(friendLabel(state.friends[stranger]!), 'Real Mara');
        expect(
          (await SharedPreferences.getInstance()).getKeys().where(
            (key) => key.startsWith('friendNameHint.'),
          ),
          isEmpty,
        );
      },
    );
  });

  test(
    'late and overlapping fileInfo polls cannot resurrect a canceled transfer',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.fileInfoStarted = Completer<void>();
      jami.pendingFileInfo = Completer<Map<String, dynamic>>();
      jami.push('incomingFile', {
        'fileId': 'file1',
        'interactionId': 'interaction1',
        'name': 'photo.jpg',
        'size': 10,
      });
      final transfer = _transferFor(state, 'file1')!;
      await state.acceptFile(transfer);
      await jami.fileInfoStarted!.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(jami.fileInfoCalls, 1);

      await state.declineFile(transfer);
      jami.pendingFileInfo!.complete({
        'transferred': 10,
        'total': 10,
        'path': 'photo.jpg',
      });
      await Future<void>.delayed(Duration.zero);
      expect(transfer.status, XferStatus.canceled);
      jami.push('fileProgress', {'fileId': 'file1', 'status': 'canceled'});
      expect(transfer.status, XferStatus.canceled);
      expect(jami.calls, contains('cancelFile:file1'));
    },
  );

  test(
    'a native accept exception leaves the transfer retryable instead of ongoing forever',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.throwAcceptFile = true;
      jami.push('incomingFile', {
        'fileId': 'failed-file',
        'interactionId': 'interaction',
        'name': 'photo.jpg',
        'size': 10,
      });
      final transfer = _transferFor(state, 'failed-file')!;
      await state.acceptFile(transfer);
      expect(transfer.status, XferStatus.error);
    },
  );

  test(
    'anonymous early progress cannot create a generic incoming offer or false saved row',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});

      // Windows can receive these callbacks before the swarm message containing displayName and author.
      jami.push('fileProgress', {
        'fileId': 'early-file',
        'interactionId': 'interaction',
        'name': '',
        'outgoing': false,
        'status': 'waiting',
        'transferred': 0,
        'total': 712,
      });
      jami.push('fileProgress', {
        'fileId': 'early-file',
        'interactionId': 'interaction',
        'name': '',
        'outgoing': false,
        'status': 'finished',
        'transferred': 712,
        'total': 712,
        'path': 'Downloads/file',
      });

      expect(_transferFor(state, 'early-file'), isNull);
      expect(_folderFileFor(state, 'early-file'), isNull);

      jami.push('incomingFile', {
        'fileId': 'early-file',
        'interactionId': 'interaction',
        'name': 'sybl-usb-probe.txt',
        'size': 712,
      });

      expect(_transferFor(state, 'early-file')?.name, 'sybl-usb-probe.txt');
      expect(_transferFor(state, 'early-file')?.status, XferStatus.offered);
    },
  );

  test(
    'incoming accepts pass the configured byte cap to the native preflight',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      expect(await state.setMaxIncomingFileBytes(123456), isTrue);
      jami.push('incomingFile', {
        'fileId': 'bounded-file',
        'interactionId': 'interaction',
        'name': 'photo.jpg',
        'size': 10,
      });

      await state.acceptFile(_transferFor(state, 'bounded-file')!);

      expect(jami.acceptFileCalls, 1);
      expect(jami.lastAcceptMaxBytes, 123456);
    },
  );

  test(
    'desktop does not expose or invoke the unsupported speaker route control',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'audio-call', 'fromJamiId': peer});
      jami.push('callState', {'callId': 'audio-call', 'state': 'CURRENT'});
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await state.toggleSpeaker();

      expect(state.speakerControlAvailable, isFalse);
      expect(state.call?.speakerOn, isFalse);
      expect(jami.calls.where((c) => c.startsWith('setSpeaker:')), isEmpty);
    },
  );

  test(
    'dark mode blocks new send, accept, and folder-download operations',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingFile', {
        'fileId': 'offered-dark',
        'interactionId': 'offer',
        'name': 'offer.txt',
        'size': 10,
      });
      jami.push('folderFile', {
        'fileId': 'folder-dark',
        'interactionId': 'history',
        'name': 'history.txt',
        'size': 10,
        'downloaded': false,
      });
      await state.setAppearOffline(true);

      await state.sendFile();
      await state.acceptFile(_transferFor(state, 'offered-dark')!);
      await state.downloadFolderFile(_folderFileFor(state, 'folder-dark')!);

      expect(jami.pickFileCalls, 0);
      expect(jami.sendFileCalls, 0);
      expect(jami.acceptFileCalls, 0);
      expect(_transferFor(state, 'offered-dark')?.status, XferStatus.offered);
    },
  );

  test(
    'group file send reuses the exact selected conversation owner',
    () async {
      SharedPreferences.setMockInitialValues({});
      jami = FakeJami();
      state = AppState(jami, await SharedPreferences.getInstance())
        ..accountId = 'acc1'
        ..jamiId = 'a' * 40;
      booted = true;
      const groupConversation = 'conv-group-files';
      state.seedEmptyRuntimeSnapshotForTesting(
        friends: const [],
        selectedFixtureGroupId: groupConversation,
        groups: const [
          GroupState(
            conversationId: groupConversation,
            title: 'The Crew',
            memberCount: 2,
            canManageMembers: true,
            memberIds: [peer],
            activeMemberIds: {peer},
            invitedMemberIds: {},
          ),
        ],
      );

      await state.sendFile();

      expect(jami.pickFileCalls, 1);
      expect(jami.sendFileCalls, 1);
      expect(jami.lastSendFilePeer, 'group:$groupConversation');
      expect(jami.lastSendFileConversation, groupConversation);
      expect(jami.discardedPickedFiles, isEmpty);
    },
  );

  test('group voice owns the call slot until leave', () async {
    SharedPreferences.setMockInitialValues({});
    jami = FakeJami();
    jami.accountRegistration = 'REGISTERED';
    state = AppState(jami, await SharedPreferences.getInstance());
    await state.init();
    booted = true;
    final layout = GroupLayout.defaults.addRoom('Voice', GroupRoomKind.voice);
    final voice = layout.rooms.firstWhere(
      (room) => room.kind == GroupRoomKind.voice,
    );
    final group = GroupState(
      conversationId: 'b' * 40,
      title: 'The Crew',
      description: GroupLayoutCodec.encode(layout),
      memberCount: 2,
      canManageMembers: true,
      memberIds: [peer],
      activeMemberIds: {peer},
      invitedMemberIds: const {},
    );
    state.seedEmptyRuntimeSnapshotForTesting(
      friends: const [
        FriendState(
          peerId: peer,
          confirmed: true,
          conversationId: peerConversation,
        ),
      ],
      selectedPeerId: peer,
      groups: [group],
    );

    await state.joinGroupVoice(group, voice);
    expect(state.groupCall?.phase, GroupCallPhase.joining);
    jami.push('groupCallLegState', {
      'reservationId': state.groupCall!.reservationId,
      'conferenceId': state.groupCall!.conferenceId,
      'callId': state.groupCall!.callId,
      'state': 'CURRENT',
    });
    await Future<void>.delayed(Duration.zero);
    await state.startCallTo(peer);
    await state.setGroupMicMuted(true);

    expect(state.groupCall?.phase, GroupCallPhase.connected);
    expect(state.groupCall?.micMuted, isTrue);
    expect(jami.calls.where((value) => value.startsWith('place:')), isEmpty);
    expect(
      jami.calls,
      contains('setGroupMicMuted:${state.groupCall!.conferenceId}:true'),
    );

    final conferenceId = state.groupCall!.conferenceId;
    await state.leaveGroupVoice();
    expect(state.groupCall, isNull);
    expect(jami.calls, contains('leaveGroupCall:$conferenceId'));
  });

  test('group mute and deafen sounds stay local to the acting user', () async {
    SharedPreferences.setMockInitialValues({});
    jami = FakeJami()..accountRegistration = 'REGISTERED';
    state = AppState(jami, await SharedPreferences.getInstance());
    await state.init();
    booted = true;
    state.groupCall = GroupCallSession(
      conversationId: 'b' * 40,
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      sessionId: 'session42',
      phase: GroupCallPhase.connected,
    );
    final events = <SyblSoundEvent>[];
    final subscription = state.soundEvents.listen(events.add);
    addTearDown(subscription.cancel);

    await state.setGroupMicMuted(true);
    await state.setGroupMicMuted(false);
    await state.setGroupDeafened(true);
    await state.setGroupDeafened(false);

    expect(events, [
      SyblSoundEvent.micMute,
      SyblSoundEvent.micUnmute,
      SyblSoundEvent.deafen,
      SyblSoundEvent.undeafen,
    ]);
  });

  test('direct call sounds follow the visible call lifecycle', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    jami.push('registrationState', {'state': 'REGISTERED'});
    final events = <SyblSoundEvent>[];
    final subscription = state.soundEvents.listen(events.add);
    addTearDown(subscription.cancel);

    await state.startCall();
    jami.push('callState', {
      'callId': 'out1',
      'state': 'CURRENT',
      'fromJamiId': peer,
    });
    jami.push('callState', {
      'callId': 'out1',
      'state': 'HUNGUP',
      'fromJamiId': peer,
    });

    expect(events, [
      SyblSoundEvent.outgoingRing,
      SyblSoundEvent.stopRinging,
      SyblSoundEvent.callConnected,
      SyblSoundEvent.callEnded,
    ]);
  });

  test('direct call media sounds only follow accepted local changes', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    jami.push('incomingCall', {'callId': 'media-call', 'fromJamiId': peer});
    jami.push('callState', {
      'callId': 'media-call',
      'state': 'CURRENT',
      'fromJamiId': peer,
    });
    await pumpEventQueue(times: 5);
    final events = <SyblSoundEvent>[];
    final subscription = state.soundEvents.listen(events.add);
    addTearDown(subscription.cancel);

    await state.toggleMute();
    await state.toggleMute();
    await state.toggleCamera();
    await state.toggleCamera();
    await state.setOutgoingVideoSource(OutgoingVideoKind.screen);
    await state.setOutgoingVideoSource(OutgoingVideoKind.off);

    expect(events, [
      SyblSoundEvent.micMute,
      SyblSoundEvent.micUnmute,
      SyblSoundEvent.cameraOn,
      SyblSoundEvent.cameraOff,
      SyblSoundEvent.screenShareOn,
      SyblSoundEvent.screenShareOff,
    ]);
  });

  test(
    'group recovery leaves the failed conference before replacement placement',
    () async {
      SharedPreferences.setMockInitialValues({});
      jami = FakeJami()..accountRegistration = 'REGISTERED';
      state = AppState(jami, await SharedPreferences.getInstance());
      await state.init();
      booted = true;
      final layout = GroupLayout.defaults.addRoom('Voice', GroupRoomKind.voice);
      final voice = layout.rooms.firstWhere(
        (room) => room.kind == GroupRoomKind.voice,
      );
      final group = GroupState(
        conversationId: 'b' * 40,
        title: 'The Crew',
        description: GroupLayoutCodec.encode(layout),
        memberCount: 2,
        canManageMembers: true,
        memberIds: [peer],
        activeMemberIds: {peer},
        invitedMemberIds: const {},
      );
      state.seedEmptyRuntimeSnapshotForTesting(
        friends: const [],
        selectedFixtureGroupId: group.conversationId,
        groups: [group],
      );

      jami.daemonGroups[group.conversationId] = JamiGroup(
        conversationId: group.conversationId,
        title: group.title,
        description: group.description,
        memberCount: 2,
        canManageMembers: true,
        members: const [
          JamiGroupMember(peerJamiId: peer, role: JamiGroupMemberRole.member),
        ],
      );
      await state.joinGroupVoice(group, voice);
      final failedConferenceId = state.groupCall!.conferenceId;
      jami.failGroupPlacement = true;
      jami.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': failedConferenceId,
        'callId': state.groupCall!.callId,
        'state': 'FAILURE',
      });
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      final leaveIndex = jami.calls.indexOf(
        'leaveGroupCall:$failedConferenceId',
      );
      final replacementIndex = jami.calls.lastIndexWhere(
        (call) => call.startsWith('joinGroupCall:'),
      );
      expect(leaveIndex, greaterThanOrEqualTo(0));
      expect(
        replacementIndex,
        greaterThan(leaveIndex),
        reason:
            '${state.groupCall?.phase} ${state.groupCall?.error} ${jami.calls}',
      );
      expect(jsonDecode(jami.groupPresencePayloads.last)['j'], isFalse);
    },
  );

  test(
    'group video uses the active Jami conference and mixer texture',
    () async {
      SharedPreferences.setMockInitialValues({});
      jami = FakeJami();
      jami.accountRegistration = 'REGISTERED';
      state = AppState(jami, await SharedPreferences.getInstance());
      await state.init();
      booted = true;
      final layout = GroupLayout.defaults.addRoom('Voice', GroupRoomKind.voice);
      final voice = layout.rooms.firstWhere(
        (room) => room.kind == GroupRoomKind.voice,
      );
      final group = GroupState(
        conversationId: 'b' * 40,
        title: 'The Crew',
        description: GroupLayoutCodec.encode(layout),
        memberCount: 2,
        canManageMembers: true,
        memberIds: [peer],
        activeMemberIds: {peer},
        invitedMemberIds: const {},
      );
      state.seedEmptyRuntimeSnapshotForTesting(
        friends: const [],
        selectedFixtureGroupId: group.conversationId,
        groups: [group],
      );

      await state.joinGroupVoice(group, voice);
      final conferenceId = state.groupCall!.conferenceId;
      jami.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': conferenceId,
        'callId': state.groupCall!.callId,
        'state': 'CURRENT',
      });
      await Future<void>.delayed(Duration.zero);
      final cameraStarted = Completer<bool>();
      jami.pendingStartVideo = cameraStarted;
      final cameraTransition = state.toggleGroupCamera();
      expect(state.groupCall?.sourceChanging, isTrue);
      expect(state.groupCall?.sourceChangeKind, OutgoingVideoKind.camera);
      cameraStarted.complete(true);
      await cameraTransition;
      expect(state.groupCall?.sourceChangeKind, isNull);
      jami.push('groupConferenceInfo', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': conferenceId,
        'participants': [
          {
            'uri': peer,
            'device': 'd' * 64,
            'sinkId': 'peer-video_0',
            'w': '1280',
            'h': '720',
            'videoMuted': 'false',
            'voiceActivity': 'true',
            'active': 'true',
          },
        ],
      });
      jami.push('video', {
        'callId': conferenceId,
        'role': 'remote',
        'active': true,
        'width': 1280,
        'height': 720,
      });
      await Future<void>.delayed(Duration.zero);
      final stream = state.groupCall!.conference.streams.single;
      expect(state.jamiId, isNot(stream.accountId));
      await state.setGroupFocus(stream);
      await state.muteGroupParticipant(stream, true);
      await state.disconnectGroupParticipant(stream);

      expect(jami.calls, contains('startVideo:$conferenceId'));
      expect(state.groupCall?.video, isTrue);
      expect(state.groupCall?.conference.streams.single.accountId, peer);
      expect(state.groupCall?.videoActive, isTrue);
      expect(state.groupCall?.videoTextureId, isNotNull);
      expect(state.groupCall?.focusedStreamKey, stream.key);
      expect(jami.calls, contains('setGroupConferenceLayout:$conferenceId:1'));
      expect(
        jami.calls,
        contains('muteGroupParticipant:$conferenceId:${stream.key}:true'),
      );
      expect(
        jami.calls,
        contains('disconnectGroupParticipant:$conferenceId:${stream.key}'),
      );

      const canonicalId = 'syblv1-voice-9001';
      jami.push('groupCallsChanged', {
        'conversationId': group.conversationId,
        'calls': [
          {
            'conferenceId': canonicalId,
            'hostUri': peer,
            'hostDevice': 'e' * 64,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      jami.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': canonicalId,
        'callId': state.groupCall!.callId,
        'state': 'CURRENT',
      });
      await Future<void>.delayed(Duration.zero);

      expect(state.groupCall?.conferenceId, canonicalId);
      expect(
        jami.calls,
        contains('startVideo:$canonicalId'),
        reason: 'host convergence must restore the active camera source',
      );

      await state.toggleGroupCamera();
      await state.toggleGroupScreenShare(sourceId: 'screen:primary');
      const nextCanonicalId = 'syblv1-voice-9002';
      jami.push('groupCallsChanged', {
        'conversationId': group.conversationId,
        'calls': [
          {
            'conferenceId': nextCanonicalId,
            'hostUri': peer,
            'hostDevice': 'f' * 64,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      jami.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': nextCanonicalId,
        'callId': state.groupCall!.callId,
        'state': 'CURRENT',
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        jami.calls,
        contains('source:$nextCanonicalId:screen:screen:primary'),
        reason: 'host convergence must restore the selected screen source',
      );
    },
  );

  test('failed file handoff discards the app-private picker copy', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    jami.sendFileResult = false;

    await state.sendFile();

    expect(jami.sendFileCalls, 1);
    expect(jami.discardedPickedFiles, ['picked.txt']);
  });

  test(
    'full byte progress waits for the terminal file completion event',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.pendingFileInfo = Completer<Map<String, dynamic>>()
        ..complete({'transferred': 10, 'total': 10, 'path': 'saved/photo.jpg'});
      jami.push('incomingFile', {
        'fileId': 'file2',
        'interactionId': 'interaction2',
        'name': 'photo.jpg',
        'size': 10,
      });

      final transfer = _transferFor(state, 'file2')!;
      jami.fileInfoStarted = Completer<void>();
      await state.acceptFile(transfer);
      await jami.fileInfoStarted!.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);

      expect(transfer.status, XferStatus.ongoing);
      expect(_folderFileFor(state, 'file2')?.downloaded, isNot(isTrue));
      jami.push('fileProgress', {
        'fileId': 'file2',
        'status': 'finished',
        'path': 'saved/photo.jpg',
      });
      expect(transfer.status, XferStatus.finished);
      expect(_folderFileFor(state, 'file2')?.downloaded, isTrue);
      expect(_folderFileFor(state, 'file2')?.path, 'saved/photo.jpg');
    },
  );

  test(
    'a same-file double tap starts one native download and cancellation wins its late result',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.pendingAcceptFile = Completer<bool>();
      jami.push('folderFile', {
        'fileId': 'file3',
        'interactionId': 'interaction3',
        'name': 'photo.jpg',
        'size': 10,
        'downloaded': false,
      });
      final folderFile = _folderFileFor(state, 'file3')!;

      final first = state.downloadFolderFile(folderFile);
      await Future<void>.delayed(Duration.zero);
      await state.downloadFolderFile(folderFile);
      expect(jami.acceptFileCalls, 1);

      final transfer = _transferFor(state, 'file3')!;
      await state.declineFile(transfer);
      jami.pendingAcceptFile!.complete(true);
      await first;

      expect(transfer.status, XferStatus.canceled);
      jami.push('fileProgress', {'fileId': 'file3', 'status': 'canceled'});
      expect(transfer.status, XferStatus.canceled);
      expect(jami.calls, contains('cancelFile:file3'));
    },
  );

  test('deviceAnnounced flips ready', () async {
    await boot({'displayName': 'Me', 'peerId': peer});
    expect(state.ready, isFalse);
    jami.push('deviceAnnounced', {'accountId': 'acc1', 'announced': true});
    expect(state.ready, isTrue);
  });

  test(
    'event stream errors are logged without canceling the subscription',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.pushError(StateError('bad event envelope'));
      expect(state.debugLog.first, contains('event failed'));
      expect(state.debugLog.first, isNot(contains('bad event envelope')));

      jami.push('deviceAnnounced', {'accountId': 'acc1', 'announced': true});
      expect(state.ready, isTrue);
    },
  );

  test(
    'newer native outgoing source revision wins over stale native truth',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'c1',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      jami.push('outgoingVideoSource', {
        'callId': 'c1',
        'outgoingVideoKind': 'screen',
        'outgoingVideoRevision': 5,
        'outgoingVideoWidth': 1920,
        'outgoingVideoHeight': 1080,
      });
      jami.push('outgoingVideoSource', {
        'callId': 'c1',
        'outgoingVideoKind': 'off',
        'outgoingVideoRevision': 4,
      });
      expect(state.call?.sharingScreen, isTrue);
      expect(state.call?.outgoingVideo.revision, 5);
    },
  );

  test(
    'native control revision republishes the current screen authority',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'c1',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      jami.push('outgoingVideoSource', {
        'callId': 'c1',
        'outgoingVideoKind': 'screen',
        'outgoingVideoRevision': 5,
        'remoteControlSourceRevision': 0,
      });
      jami.push('outgoingVideoSource', {
        'callId': 'c1',
        'outgoingVideoKind': 'screen',
        'outgoingVideoRevision': 5,
        'remoteControlSourceRevision': 9,
      });
      await Future<void>.delayed(Duration.zero);

      final sources = jami.sentCallMessages
          .map((message) => jsonDecode(message) as Map<String, dynamic>)
          .where((message) => message['t'] == 'src')
          .toList();
      expect(
        sources.map((message) => message['sourceRevision']),
        containsAllInOrder([0, 9]),
      );
    },
  );

  test(
    'call replacement owns source while an older transition completes',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'c1',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      final pending = Completer<bool>();
      jami.pendingScreenVideo = pending;
      final transition = state.setOutgoingVideoSource(
        OutgoingVideoKind.screen,
        sourceId: '0',
      );
      jami.push('callState', {
        'callId': 'c1',
        'state': 'OVER',
        'fromJamiId': peer,
      });
      jami.push('callState', {
        'callId': 'c2',
        'state': 'CURRENT',
        'fromJamiId': peer,
        'outgoingVideoKind': 'screen',
        'outgoingVideoRevision': 9,
      });
      pending.complete(true);
      await transition;
      expect(state.call?.callId, 'c2');
      expect(state.call?.sharingScreen, isTrue);
      expect(state.call?.sourceChanging, isFalse);
    },
  );

  test(
    'cancelled screen transition clears busy state and keeps source off',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'c1',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      jami.pendingScreenVideo = Completer<bool>()..complete(false);
      await state.setOutgoingVideoSource(
        OutgoingVideoKind.screen,
        sourceId: '0',
      );
      expect(state.call?.outgoingVideo.kind, OutgoingVideoKind.off);
      expect(state.call?.sourceChanging, isFalse);
    },
  );

  test(
    'screen inventory completion cannot escape onto a replacement call',
    () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      jami.push('incomingCall', {'callId': 'c1', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'c1',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      final pending = Completer<List<ScreenSource>>();
      jami.pendingScreenSources = pending;
      final inventory = state.listScreenSources(expectedCallId: 'c1');

      jami.push('callState', {
        'callId': 'c1',
        'state': 'OVER',
        'fromJamiId': peer,
      });
      jami.push('callState', {
        'callId': 'c2',
        'state': 'CURRENT',
        'fromJamiId': peer,
      });
      pending.complete([
        ScreenSource.fromMap({
          'id': r'\\.\DISPLAY1|0,0,1920,1080',
          'label': 'Display 1',
          'primary': true,
          'width': 1920,
          'height': 1080,
        })!,
      ]);

      expect(await inventory, isEmpty);
      await state.toggleScreenShare(
        expectedCallId: 'c1',
        sourceId: r'\\.\DISPLAY1|0,0,1920,1080',
      );
      expect(jami.calls.where((entry) => entry.startsWith('source:')), isEmpty);
    },
  );

  group('M11 production state integration', () {
    test('rejects an over-count native chat snapshot atomically', () async {
      await boot(
        {'displayName': 'Me', 'peerId': peer},
        configure: (fake) {
          fake.eventDuringLoadChat = JamiEvent('chatSnapshot', {
            'items': List<Map<String, Object?>>.generate(
              TimelineWireContract.maxSnapshotItems + 1,
              (_) => const {},
            ),
          });
        },
      );
      await pumpEventQueue(times: 5);

      expect(state.conversationItems, isEmpty);
      expect(state.chatLoadError.toString(), contains('item-count contract'));
    });

    test('disposing retires a pending native chat load', () async {
      await boot({
        'displayName': 'Me',
        'peerId': peer,
      }, configure: (fake) => fake.autoCompleteChat = false);
      await pumpEventQueue(times: 5);

      expect(
        jami.calls.where((entry) => entry.startsWith('loadChat:')),
        hasLength(1),
      );
      state.dispose();
      await pumpEventQueue(times: 3);

      expect(jami.calls, contains('cancelChatLoad:1000'));
    });

    test('refresh retires its prior pending native chat load', () async {
      await boot({
        'displayName': 'Me',
        'peerId': peer,
      }, configure: (fake) => fake.autoCompleteChat = false);
      await pumpEventQueue(times: 5);

      final refresh = state.refreshChat();
      await pumpEventQueue(times: 5);

      expect(jami.calls, contains('cancelChatLoad:1000'));
      expect(
        jami.calls.where((entry) => entry.startsWith('loadChat:')),
        hasLength(2),
      );
      jami.push('chatSnapshot', {
        'accountId': 'acc1',
        'peerJamiId': peer,
        'conversationId': peerConversation,
        'loadId': 1001,
        'requestedCursor': '',
        'nextCursor': '',
        'hasMore': false,
        'items': const <Object?>[],
      });
      await refresh;
      expect(state.chatLoadError, isNull);
    });

    test(
      'buffers a Windows JSON snapshot that beats the loadChat reply',
      () async {
        final item = _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'm1',
          authorId: peer,
          text: 'hello',
        );
        await boot(
          {'displayName': 'Me', 'peerId': peer},
          configure: (fake) {
            fake.eventDuringLoadChat = JamiEvent('chatSnapshot', {
              'items': null,
              'itemsJson': jsonEncode([item]),
            });
          },
        );
        await pumpEventQueue(times: 5);

        expect(state.chatLoading, isFalse);
        expect(state.chatLoadError, isNull);
        expect(state.conversationItems, hasLength(1));
        expect(
          (state.conversationItems.single as TimelineTextItem).text,
          'hello',
        );
        expect(
          jami.calls.where((entry) => entry.startsWith('loadChat:')),
          hasLength(1),
        );
      },
    );

    test(
      'selected timeline owns live merge, send, refresh, and retirement',
      () async {
        await boot(
          {'displayName': 'Me', 'peerId': peer},
          configure: (fake) {
            fake.daemonFriends[otherFriend] = const JamiFriend(
              peerJamiId: otherFriend,
              confirmed: true,
              conversationId: strangerConversation,
            );
          },
        );
        await pumpEventQueue(times: 5);

        jami.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': otherFriend,
          'conversationId': strangerConversation,
          'item': _textWire(
            ownerPeer: otherFriend,
            conversationId: strangerConversation,
            daemonId: 'wrong-owner',
            authorId: otherFriend,
            text: 'not selected',
          ),
        });
        expect(state.conversationItems, isEmpty);

        final selectedWire = _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'live-1',
          authorId: peer,
          text: 'selected',
        );
        jami.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': peer,
          'conversationId': peerConversation,
          'item': selectedWire,
        });
        expect(
          (state.conversationItems.single as TimelineTextItem).text,
          'selected',
        );

        expect(await state.sendText('  '), isFalse);
        jami.chatHistory[peerConversation] = [
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'outbound-commit',
            authorId: jami.accountJamiId,
            text: 'outbound',
          ),
          selectedWire,
        ];
        expect(await state.sendText('outbound', replyTo: 'live-1'), isTrue);
        expect(jami.lastChatBody, 'outbound');
        expect(jami.lastChatReplyTo, 'live-1');
        expect(
          state.conversationItems,
          hasLength(2),
          reason:
              'a durable send reconciles the authoritative commit instead of inserting optimistically',
        );
        expect(state.conversationItems.last.daemonId, 'outbound-commit');

        jami.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': peer,
          'conversationId': peerConversation,
          'item': {
            'accountId': 'acc1',
            'peerId': peer,
            'conversationId': peerConversation,
            'daemonId': 'file-commit',
            'versionId': 'file-commit',
            'mimeType': 'application/data-transfer+json',
            'authorId': peer,
            'timestampSeconds': 1700000001,
            'body': {
              'fileId': 'timeline-file',
              'displayName': 'photo.jpg',
              'totalBytes': 123,
              'sha3': 'abc',
              'downloaded': false,
            },
          },
        });
        final timelineFile = state.conversationItems
            .whereType<TimelineFileItem>()
            .single;
        expect(await state.downloadTimelineFile(timelineFile), isTrue);
        expect(jami.acceptFileCalls, 1);
        expect(_transferFor(state, 'timeline-file')?.name, 'photo.jpg');
        expect(
          state.folder,
          isEmpty,
          reason: 'the timeline adapter does not manufacture folder rows',
        );

        final beforeRefresh = jami.calls
            .where((entry) => entry.startsWith('loadChat:'))
            .length;
        for (var i = 0; i < 2; i++) {
          jami.push('chatRefreshRequired', {
            'accountId': 'acc1',
            'peerJamiId': peer,
            'conversationId': peerConversation,
          });
        }
        await pumpEventQueue(times: 5);
        expect(
          jami.calls.where((entry) => entry.startsWith('loadChat:')).length,
          beforeRefresh + 1,
        );

        await state.selectFriend(otherFriend);
        await pumpEventQueue(times: 5);
        expect(state.selectedConversationScope?.peerId, otherFriend);
        expect(state.conversationItems, isEmpty);
        expect(await state.downloadTimelineFile(timelineFile), isFalse);
        jami.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': peer,
          'conversationId': peerConversation,
          'item': _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'stale-live',
            authorId: peer,
            text: 'stale',
          ),
        });
        expect(state.conversationItems, isEmpty);
        await state.selectFriend(peer);
        expect(
          state.conversationItems.map((item) => item.daemonId),
          contains('stale-live'),
          reason: 'a live conversation remains owned while another DM is open',
        );
      },
    );

    test(
      'switching friends and rebuilding state reloads durable daemon history',
      () async {
        const otherConversation = 'conv-other-durable';
        final peerItem = _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'peer-history',
          authorId: peer,
          text: 'still here',
        );
        final otherItem = _textWire(
          ownerPeer: otherFriend,
          conversationId: otherConversation,
          daemonId: 'other-history',
          authorId: otherFriend,
          text: 'other thread',
        );
        await boot(
          {'displayName': 'Me', 'peerId': peer},
          configure: (fake) {
            fake.daemonFriends[otherFriend] = const JamiFriend(
              peerJamiId: otherFriend,
              confirmed: true,
              conversationId: otherConversation,
            );
            fake.chatHistory[peerConversation] = [peerItem];
            fake.chatHistory[otherConversation] = [otherItem];
          },
        );
        await pumpEventQueue(times: 5);
        expect(state.conversationItems.single.daemonId, 'peer-history');

        await state.selectFriend(otherFriend);
        await pumpEventQueue(times: 5);
        expect(state.conversationItems.single.daemonId, 'other-history');

        await state.selectFriend(peer);
        await pumpEventQueue(times: 5);
        expect(state.conversationItems.single.daemonId, 'peer-history');

        final preferences = state.prefs;
        state.dispose();
        state = AppState(jami, preferences);
        await state.init();
        expect(state.selectedConversationScope, isNull);

        await state.selectFriend(peer);
        await pumpEventQueue(times: 5);
        expect(state.conversationItems.single.daemonId, 'peer-history');
      },
    );

    test(
      'refresh-required coalescing follows the latest selected conversation',
      () async {
        const otherConversation = 'conv-other';
        await boot(
          {'displayName': 'Me', 'peerId': peer},
          configure: (fake) {
            fake.daemonFriends[otherFriend] = const JamiFriend(
              peerJamiId: otherFriend,
              confirmed: true,
              conversationId: otherConversation,
            );
          },
        );
        await pumpEventQueue(times: 5);

        jami.push('chatRefreshRequired', {
          'accountId': 'acc1',
          'peerJamiId': peer,
          'conversationId': peerConversation,
        });
        final selecting = state.selectFriend(otherFriend);
        jami.push('chatRefreshRequired', {
          'accountId': 'acc1',
          'peerJamiId': otherFriend,
          'conversationId': otherConversation,
        });
        await selecting;
        await pumpEventQueue(times: 5);

        expect(
          jami.calls
              .where(
                (entry) => entry.startsWith(
                  'loadChat:$otherFriend:$otherConversation:',
                ),
              )
              .length,
          2,
          reason:
              'selection starts one load and the latest queued refresh starts a second',
        );
      },
    );

    test('sync completion reconciles every cached conversation', () async {
      const otherConversation = 'conv-other-sync';
      await boot(
        {'displayName': 'Me', 'peerId': peer},
        configure: (fake) {
          fake.daemonFriends[otherFriend] = const JamiFriend(
            peerJamiId: otherFriend,
            confirmed: true,
            conversationId: otherConversation,
          );
        },
      );
      await pumpEventQueue(times: 5);
      await state.selectFriend(otherFriend);
      await pumpEventQueue(times: 5);

      jami.chatHistory[peerConversation] = [
        _textWire(
          ownerPeer: peer,
          conversationId: peerConversation,
          daemonId: 'peer-after-sync',
          authorId: peer,
          text: '2',
        ),
      ];
      jami.chatHistory[otherConversation] = [
        _textWire(
          ownerPeer: otherFriend,
          conversationId: otherConversation,
          daemonId: 'other-after-sync',
          authorId: otherFriend,
          text: '3',
        ),
      ];
      final beforePeer = jami.calls
          .where((call) => call.startsWith('loadChat:$peer:$peerConversation:'))
          .length;
      final beforeOther = jami.calls
          .where(
            (call) =>
                call.startsWith('loadChat:$otherFriend:$otherConversation:'),
          )
          .length;

      jami.push('conversationSyncFinished', {'accountId': 'acc1'});
      jami.push('conversationSyncFinished', {'accountId': 'acc1'});
      await pumpEventQueue(times: 5);

      expect(
        jami.calls
            .where(
              (call) => call.startsWith('loadChat:$peer:$peerConversation:'),
            )
            .length,
        beforePeer + 1,
      );
      expect(
        jami.calls
            .where(
              (call) =>
                  call.startsWith('loadChat:$otherFriend:$otherConversation:'),
            )
            .length,
        beforeOther + 1,
      );
      expect(state.conversationItems.single.daemonId, 'other-after-sync');
      await state.selectFriend(peer);
      expect(state.conversationItems.single.daemonId, 'peer-after-sync');
    });

    test('a burst of sync completions has a bounded refresh cost', () async {
      await boot({'displayName': 'Me', 'peerId': peer});
      await state.selectFriend(peer);
      await pumpEventQueue(times: 5);
      int loads() => jami.calls
          .where((call) => call.startsWith('loadChat:$peer:$peerConversation:'))
          .length;
      final before = loads();

      for (var i = 0; i < 100; i++) {
        jami.push('conversationSyncFinished', {'accountId': 'acc1'});
      }
      await pumpEventQueue(times: 5);
      expect(loads(), before + 1);

      await Future<void>.delayed(const Duration(milliseconds: 2100));
      await pumpEventQueue(times: 5);
      expect(loads(), before + 2);
    });

    test('update restart waits for a pending app settings save', () async {
      await boot({'displayName': 'Me'});
      expect(state.canRestartForUpdate, isTrue);
      jami
        ..nativeAppSettingsStore = true
        ..appSettingsSaveStarted = Completer<void>()
        ..pendingAppSettingsSave = Completer<void>();

      final save = state.setChatMotionEnabled(false);
      await jami.appSettingsSaveStarted!.future;
      expect(state.settingsBusy, isTrue);
      expect(state.canRestartForUpdate, isFalse);
      expect(state.reserveUpdateRestart(), isFalse);
      expect(state.updateRestartPending, isFalse);
      await pumpEventQueue();
      expect(state.canRestartForUpdate, isFalse);

      jami.pendingAppSettingsSave!.complete();
      expect(await save, isTrue);
      expect(state.chatMotionEnabled, isFalse);
      expect(state.settingsBusy, isFalse);
      expect(state.canRestartForUpdate, isTrue);
      expect(state.reserveUpdateRestart(), isTrue);
      expect(state.updateRestartStillSafe, isTrue);
      state.cancelUpdateRestart();
    });

    test('pending settings save invalidates update restart safety', () async {
      await boot({'displayName': 'Me'});
      expect(state.reserveUpdateRestart(), isTrue);
      expect(state.updateRestartStillSafe, isTrue);
      jami
        ..nativeAppSettingsStore = true
        ..appSettingsSaveStarted = Completer<void>()
        ..pendingAppSettingsSave = Completer<void>();

      final save = state.setChatMotionEnabled(false);
      await jami.appSettingsSaveStarted!.future;
      expect(state.settingsBusy, isTrue);
      expect(state.updateRestartPending, isTrue);
      expect(state.updateRestartStillSafe, isFalse);
      state.cancelUpdateRestart();
      expect(state.canRestartForUpdate, isFalse);

      jami.pendingAppSettingsSave!.complete();
      expect(await save, isTrue);
      expect(state.settingsBusy, isFalse);
      expect(state.canRestartForUpdate, isTrue);
    });

    test(
      'loads and rewrites one SharedPreferences settings document',
      () async {
        final encoded = jsonEncode({
          'schemaVersion': 2,
          'microphone': {
            'globalDefault': 'open',
            'conversationOverrides': [
              {
                'accountId': 'acc1',
                'peerId': peer,
                'conversationId': peerConversation,
                'mode': 'voiceActivated',
              },
            ],
          },
        });
        await boot({
          'displayName': 'Me',
          'peerId': peer,
          'appSettings': encoded,
        });

        expect(
          state.microphoneModeForFriend(peer),
          const EffectiveMicrophoneMode(
            mode: MicrophoneMode.open,
            source: MicrophoneModeSource.conversationOverride,
          ),
        );
        expect(
          await state.setGlobalMicrophoneMode(MicrophoneMode.pushToTalk),
          isTrue,
        );
        await state.setAppLockEnabled(true);
        expect(await state.setFolderHistoryLimit(321), isTrue);
        expect(await state.setMaxIncomingFileBytes(0), isTrue);
        expect(await state.setAppearancePreset(AppearancePreset.cozy), isTrue);
        expect(await state.setIdentityColor(IdentityColor.sky), isTrue);
        const surface = TopicStripSurfaceSettings(
          coverage: TopicStripSurfaceCoverage.off,
          strength: 60,
          blur: 9,
          solidReach: 17,
          lowerFade: 33,
          rightFade: 28,
        );
        expect(await state.setTopicStripSurfaceSettings(surface), isTrue);
        expect(await state.setShareActivityPresence(true), isTrue);
        expect(
          await state.setUnreadBadgePlacement(UnreadBadgePlacement.trailing),
          isTrue,
        );
        expect(await state.setFolderHistoryLimit(0), isFalse);
        final stored = jsonDecode(state.prefs.getString('appSettings')!) as Map;
        expect(stored['schemaVersion'], AppSettings.currentSchemaVersion);
        expect((stored['microphone'] as Map)['globalDefault'], 'pushToTalk');
        expect((stored['appLock'] as Map)['enabled'], isTrue);
        expect((stored['files'] as Map)['folderHistoryLimit'], 321);
        expect((stored['files'] as Map)['maxIncomingFileBytes'], 0);
        expect((stored['appearance'] as Map)['preset'], 'cozy');
        expect((stored['profile'] as Map)['identityColor'], 'sky');
        expect(
          ((stored['appearance'] as Map)['topicStripSurface']
              as Map)['coverage'],
          'off',
        );
        expect((stored['presence'] as Map)['shareActiveApp'], isTrue);
        expect(
          (stored['notifications'] as Map)['unreadBadgePlacement'],
          'trailing',
        );
        expect(state.appLockEnabled, isTrue);
        expect(state.prefs.getBool('appLockEnabled.v1'), isTrue);
        expect(state.folderKeepLast, 321);
        expect(state.maxIncomingFileBytes, 0);
        expect(state.appearancePreset, AppearancePreset.cozy);
        expect(state.identityColor, IdentityColor.sky);
        expect(state.topicStripSurfaceSettings, surface);
        expect(state.shareActivityPresence, isTrue);
        expect(state.unreadBadgePlacement, UnreadBadgePlacement.trailing);
        expect(
          jami.presenceMetadataCalls,
          containsAllInOrder([
            (
              shareActivity: false,
              color: IdentityColor.automaticFor(
                jami.accountJamiId,
              ).storageValue,
            ),
            (shareActivity: false, color: 'sky'),
            (shareActivity: true, color: 'sky'),
          ]),
        );
        expect(state.prefs.containsKey('microphoneMode'), isFalse);
      },
    );

    test(
      'a corrupt settings document is surfaced and never auto-overwritten',
      () async {
        const corrupt = '{not json';
        await boot({
          'displayName': 'Me',
          'peerId': peer,
          'appSettings': corrupt,
        });

        expect(state.settingsError, isNotNull);
        expect(state.settingsWritable, isFalse);
        expect(state.appSettings, AppSettings().withAppLockEnabled(true));
        expect(state.appLockEnabled, isTrue);
        expect(state.prefs.getBool('appLockEnabled.v1'), isTrue);
        expect(state.prefs.getString('appSettings'), corrupt);
        expect(
          await state.setGlobalMicrophoneMode(MicrophoneMode.pushToTalk),
          isFalse,
        );
        expect(state.prefs.getString('appSettings'), corrupt);
        expect(state.screen, Screen.home);
      },
    );

    test(
      'a corrupt settings document cannot disable the independent lock latch',
      () async {
        const corrupt = '{not json';
        await boot({
          'displayName': 'Me',
          'peerId': peer,
          'appSettings': corrupt,
          'appLockEnabled.v1': true,
        });

        expect(state.appLockEnabled, isTrue);
        expect(state.settingsWritable, isFalse);
        await state.setAppLockEnabled(false);
        expect(state.appLockEnabled, isFalse);
        expect(state.prefs.getBool('appLockEnabled.v1'), isFalse);
        expect(state.prefs.getString('appSettings'), corrupt);
      },
    );

    test(
      'future settings stay untouched and defaults remain writable without a document',
      () async {
        final future = jsonEncode({
          'schemaVersion': AppSettings.currentSchemaVersion + 1,
          'futureField': {'keep': true},
        });
        await boot({
          'displayName': 'Me',
          'peerId': peer,
          'appSettings': future,
        });

        expect(state.settingsWritable, isFalse);
        expect(state.appLockEnabled, isTrue);
        expect(state.prefs.getBool('appLockEnabled.v1'), isTrue);
        expect(
          await state.setAppearancePreset(AppearancePreset.midnight),
          isFalse,
        );
        expect(state.prefs.getString('appSettings'), future);

        state.dispose();
        SharedPreferences.setMockInitialValues({
          'displayName': 'Me',
          'peerId': peer,
        });
        jami = FakeJami();
        state = AppState(jami, await SharedPreferences.getInstance());
        await state.init();

        expect(state.settingsWritable, isTrue);
        expect(
          await state.setGlobalMicrophoneMode(MicrophoneMode.pushToTalk),
          isTrue,
        );
        expect(state.prefs.getString('appSettings'), isNotNull);
      },
    );

    for (final mode in [MicrophoneMode.pushToTalk]) {
      test(
        'persisted ${mode.name} dials and answers with audio muted before CURRENT',
        () async {
          await boot({
            'displayName': 'Me',
            'peerId': peer,
            'appSettings': jsonEncode({
              'schemaVersion': 2,
              'microphone': {
                'globalDefault': mode.storageValue,
                'conversationOverrides': <Object?>[],
              },
            }),
          });
          jami.push('registrationState', {'state': 'REGISTERED'});

          await state.startCall();

          expect(jami.lastPlacedInitialAudioMuted, isTrue);
          expect(state.call?.micMuted, isTrue);
          expect(state.call?.manuallyMuted, isFalse);
          expect(
            jami.calls,
            isNot(contains('setMicMuted:out1:false')),
            reason: 'no CURRENT event has armed the persisted microphone mode',
          );

          jami.push('callState', {
            'callId': 'out1',
            'state': 'HUNGUP',
            'fromJamiId': peer,
          });
          jami.push('incomingCall', {
            'callId': 'incoming-muted',
            'fromJamiId': peer,
          });
          expect(state.call?.micMuted, isTrue);
          expect(state.call?.manuallyMuted, isFalse);

          await state.answer(state.call!);

          expect(jami.lastAnsweredInitialAudioMuted, isTrue);
          expect(
            jami.calls,
            isNot(contains('setMicMuted:incoming-muted:false')),
            reason: 'answering alone must not open audio before CURRENT',
          );
        },
      );
    }

    test('legacy voice activation settings normalize to open mic', () async {
      final encoded = jsonEncode({
        'schemaVersion': 2,
        'microphone': {
          'globalDefault': 'open',
          'conversationOverrides': [
            {
              'accountId': 'acc1',
              'peerId': peer,
              'conversationId': peerConversation,
              'mode': 'voiceActivated',
            },
          ],
        },
      });
      await boot({'displayName': 'Me', 'peerId': peer, 'appSettings': encoded});
      jami.push('incomingCall', {'callId': 'voice-call', 'fromJamiId': peer});
      jami.push('callState', {
        'callId': 'voice-call',
        'state': 'CURRENT',
        'fromJamiId': peer,
        'micMuted': false,
      });
      await pumpEventQueue(times: 5);

      expect(state.call?.micMode, MicrophoneMode.open);
      expect(state.call?.micMuted, isFalse);
      expect(jami.calls, contains('setMicMuted:voice-call:true'));
      expect(jami.calls, contains('setAudioTransmissionMode:voice-call:open'));
      expect(jami.calls, contains('setMicMuted:voice-call:false'));

      jami.push('localVoiceActivity', {'callId': 'voice-call', 'active': true});
      await pumpEventQueue(times: 3);
      expect(state.call?.localVoiceActive, isFalse);
      expect(state.voiceMeterLevel, 0);

      jami.push('audioMeter', {'level': 0.45});
      expect(state.voiceMeterLevel, closeTo(0.45, 0.001));

      jami.push('callState', {
        'callId': 'voice-call',
        'state': 'HUNGUP',
        'fromJamiId': peer,
      });
      await pumpEventQueue(times: 5);
      expect(state.call, isNull);
      expect(state.voiceMeterLevel, 0);
      expect(jami.calls, contains('setAudioMeterEnabled:false'));
    });

    test(
      'an audio transmission configuration failure leaves the call muted',
      () async {
        await boot({
          'displayName': 'Me',
          'peerId': peer,
          'appSettings': jsonEncode({
            'schemaVersion': 2,
            'microphone': {
              'globalDefault': 'open',
              'conversationOverrides': <Object?>[],
            },
          }),
        });
        jami.throwAudioTransmissionMode = true;
        jami.push('incomingCall', {
          'callId': 'unsafe-voice-call',
          'fromJamiId': peer,
        });
        jami.push('callState', {
          'callId': 'unsafe-voice-call',
          'state': 'CURRENT',
          'fromJamiId': peer,
          'micMuted': false,
        });
        await pumpEventQueue(times: 10);

        expect(state.microphoneError, isNotNull);
        expect(state.call?.micMuted, isTrue);
        expect(state.call?.microphonePolicyApplied, isFalse);
        expect(jami.calls, isNot(contains('hangUp:unsafe-voice-call')));
      },
    );

    test('failure of the protective mute ends the call fail-closed', () async {
      await boot({
        'displayName': 'Me',
        'peerId': peer,
        'appSettings': jsonEncode({
          'schemaVersion': 2,
          'microphone': {
            'globalDefault': 'open',
            'conversationOverrides': <Object?>[],
          },
        }),
      });
      jami.throwAudioControl = true;
      jami.push('incomingCall', {
        'callId': 'unmutable-voice-call',
        'fromJamiId': peer,
      });
      jami.push('callState', {
        'callId': 'unmutable-voice-call',
        'state': 'CURRENT',
        'fromJamiId': peer,
        'micMuted': false,
      });
      await pumpEventQueue(times: 10);

      expect(state.microphoneError, isNotNull);
      expect(jami.calls, contains('hangUp:unmutable-voice-call'));
    });
  });
  group('native messageStatus delivery events', () {
    const otherConversation = 'conv-other-status';
    const groupConversation = 'conv-status-group';

    TimelineDeliveryState stateOf(String daemonId) => state.conversationItems
        .singleWhere((item) => item.daemonId == daemonId)
        .deliveryState;

    Future<void> status(
      String messageId,
      int wire, {
      String account = 'acc1',
      String conversation = peerConversation,
      String member = peer,
    }) async {
      jami.push('messageStatus', {
        'accountId': account,
        'conversationId': conversation,
        'messageId': messageId,
        'state': wire,
        'peerJamiId': member,
      });
      await pumpEventQueue(times: 3);
    }

    Future<void> bootWithOutgoing() => boot(
      {'displayName': 'Me', 'peerId': peer},
      configure: (fake) {
        fake.daemonFriends[otherFriend] = const JamiFriend(
          peerJamiId: otherFriend,
          confirmed: true,
          conversationId: otherConversation,
        );
        fake.chatHistory[peerConversation] = [
          _textWire(
            ownerPeer: peer,
            conversationId: peerConversation,
            daemonId: 'out-1',
            authorId: fake.accountJamiId,
            text: 'hi',
          ),
        ];
        fake.chatHistory[otherConversation] = [
          _textWire(
            ownerPeer: otherFriend,
            conversationId: otherConversation,
            daemonId: 'out-1',
            authorId: fake.accountJamiId,
            text: 'hi other',
          ),
        ];
      },
    );

    test(
      'raises the outgoing state monotonically and never lowers it',
      () async {
        await bootWithOutgoing();
        await pumpEventQueue(times: 5);
        expect(stateOf('out-1'), TimelineDeliveryState.sent);

        await status('out-1', 2);
        expect(stateOf('out-1'), TimelineDeliveryState.delivered);
        await status('out-1', 3);
        expect(stateOf('out-1'), TimelineDeliveryState.read);
        await status('out-1', 2);
        expect(stateOf('out-1'), TimelineDeliveryState.read);
        await status('out-1', 1);
        expect(stateOf('out-1'), TimelineDeliveryState.read);
      },
    );

    test('an event for another account changes nothing', () async {
      await bootWithOutgoing();
      await pumpEventQueue(times: 5);

      await status('out-1', 3, account: 'acc-other');

      expect(stateOf('out-1'), TimelineDeliveryState.sent);
    });

    test('an event for another conversation changes only that one', () async {
      await bootWithOutgoing();
      await pumpEventQueue(times: 5);
      await state.selectFriend(otherFriend);
      await pumpEventQueue(times: 5);
      await state.selectFriend(peer);
      await pumpEventQueue(times: 5);

      await status('out-1', 3, conversation: otherConversation);

      expect(stateOf('out-1'), TimelineDeliveryState.sent);
      await state.selectFriend(otherFriend);
      await pumpEventQueue(times: 5);
      expect(stateOf('out-1'), TimelineDeliveryState.read);
    });

    test('an unknown message id changes nothing and inserts nothing', () async {
      await bootWithOutgoing();
      await pumpEventQueue(times: 5);

      await status('ghost', 3);

      expect(state.conversationItems.map((item) => item.daemonId), ['out-1']);
      expect(stateOf('out-1'), TimelineDeliveryState.sent);
    });

    test(
      'a group read adds the reading member and ignores the author',
      () async {
        await boot(
          {'displayName': 'Me', 'selectedGroupId': groupConversation},
          configure: (fake) {
            fake.daemonGroups[groupConversation] = const JamiGroup(
              conversationId: groupConversation,
              title: 'The Crew',
              memberCount: 2,
              canManageMembers: true,
              members: [
                JamiGroupMember(
                  peerJamiId: peer,
                  role: JamiGroupMemberRole.member,
                ),
              ],
            );
            fake.chatHistory[groupConversation] = [
              _textWire(
                ownerPeer: 'group:$groupConversation',
                conversationId: groupConversation,
                daemonId: 'group-out',
                authorId: fake.accountJamiId,
                text: 'hello crew',
              ),
            ];
          },
        );
        await pumpEventQueue(times: 5);
        expect(state.conversationItems.single.readByMemberIds, isEmpty);

        await status(
          'group-out',
          3,
          conversation: groupConversation,
          member: jami.accountJamiId,
        );
        expect(state.conversationItems.single.readByMemberIds, isEmpty);
        expect(stateOf('group-out'), TimelineDeliveryState.read);

        await status(
          'group-out',
          3,
          conversation: groupConversation,
          member: peer,
        );
        expect(state.conversationItems.single.readByMemberIds, {peer});
      },
    );
  });

  test(
    'a just-accepted conversation still cloning shows preparation, then loads',
    () async {
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'peerId': peer,
      });
      final jami = _UnclonedJami()..accountExists = true;
      jami.daemonFriends[peer] = const JamiFriend(
        peerJamiId: peer,
        confirmed: true,
        conversationId: peerConversation,
      );
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      await state.selectFriend(peer);
      await pumpEventQueue(times: 10);
      // libjami answers 0 while the swarm clones: preparing, not failed.
      expect(state.chatPreparing, isTrue);

      jami.cloned = true;
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      await pumpEventQueue(times: 20);
      expect(state.chatLoadError, isNull);
      expect(state.chatPreparing, isFalse);
      expect(jami.unclonedLoads, greaterThanOrEqualTo(1));
    },
  );
}

class _UnclonedJami extends FakeJami {
  bool cloned = false;
  int unclonedLoads = 0;

  @override
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
  }) async {
    if (!cloned) {
      unclonedLoads++;
      return 0;
    }
    return super.loadChat(
      peerJamiId,
      conversationId,
      fromMessage: fromMessage,
      pageSize: pageSize,
    );
  }
}
