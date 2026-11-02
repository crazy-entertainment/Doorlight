import '../core/media_retirement.dart';
import '../core/diagnostic_label.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' show Random, min;
import 'dart:io'
    show Platform, Directory, FileSystemEntity, FileSystemEntityType;
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'; // ChangeNotifier + WidgetsBindingObserver (app foreground → presence probe)
import 'package:shared_preferences/shared_preferences.dart';
import '../core/invite_link.dart';
import '../core/jami.dart';
import '../core/sound_effects.dart';
import '../core/sticker_assets.dart';
import '../core/jami_identity.dart';
import '../core/wake_relay.dart';
import 'annotation.dart';
import 'app_lock_persistence.dart';
import 'app_settings.dart';
import 'background_wake_policy.dart';
import 'conversation_scope.dart';
import 'conversation_search.dart';
import 'device_pairing.dart';
import 'search_message_selection.dart';
import 'gif_library_store.dart';
import 'chat_archive.dart';
import 'conversation_timeline.dart';
import 'composer_commands.dart';
import 'composer_draft.dart';
import 'composer_media.dart';
import 'gif_validation.dart';
import 'starter_gifs.dart';
import 'hologram_live.dart';
import 'live_message_effects.dart';
import 'sticker_manifest.dart';
import 'voice_recorder.dart';
import 'voice_validation.dart';
import 'dm_topics.dart';
import 'file_transfer.dart';
import 'group_topics.dart';
import 'group_calls.dart';
import 'identity_color.dart';
import 'microphone_policy.dart';
import 'nearby.dart';
import 'message_reactions.dart';
import 'outgoing_video.dart';
import 'overlay_settings.dart';
import 'presence_coordinator.dart';
import 'presence_color_cache.dart';
import 'pending_invite.dart';
import 'remote_control.dart';
import 'rich_content.dart';
import 'send_journal.dart';
import 'surface_protection.dart';
import 'wake_capabilities.dart';
import 'widget_chat_session.dart';

export 'presence_coordinator.dart' show PeerPresence;
export 'app_settings.dart'
    show
        AppearancePreset,
        GroupHeaderPlacement,
        MessageReceiptStyle,
        MessageReceiptVisibility,
        MessageTimestampStyle,
        MicrophoneMode,
        MobileGroupNavigation,
        TopicStripSurfaceCoverage,
        TopicStripSurfaceSettings,
        UnreadBadgePlacement;
export 'file_transfer.dart'
    show FileXfer, FolderFile, TransferKey, TransferOwner, XferStatus;
export 'group_calls.dart'
    show
        GroupCallPhase,
        GroupCallSession,
        GroupConferenceSnapshot,
        GroupConferenceStream,
        GroupRoomParticipant;
export 'identity_color.dart' show IdentityColor;

enum Screen { loading, onboarding, home }

enum CallDir { incoming, outgoing }

enum FriendRemovalStatus { removed, notRemoved, incomplete, stale }

typedef FriendRemovalResult = ({
  String peerId,
  FriendRemovalStatus status,
  String? warning,
});

/// A persisted promise to remove one friend after the "removed you" notice is
/// delivered, or at [deadlineMs] at the latest. It survives a restart.
final class _PendingFriendRemoval {
  _PendingFriendRemoval({
    required this.accountId,
    required this.peerId,
    required this.conversationId,
    required this.deadlineMs,
    this.noticeCommitId,
  });

  final String accountId;
  final String peerId;
  final String conversationId;
  final int deadlineMs;
  String? noticeCommitId;
  Completer<void>? delivered;
  bool confirming = false;
  final Set<String> earlyDelivered = {};

  Map<String, Object> toJson() => {
    'accountId': accountId,
    'peerId': peerId,
    'conversationId': conversationId,
    'deadlineMs': deadlineMs,
    'noticeCommitId': ?noticeCommitId,
  };

  static _PendingFriendRemoval? fromJson(Object? value) {
    if (value is! Map) return null;
    final account = value['accountId'];
    final peer = value['peerId'];
    final conversation = value['conversationId'];
    final deadline = value['deadlineMs'];
    final notice = value['noticeCommitId'];
    if (account is! String ||
        account.isEmpty ||
        peer is! String ||
        peer.isEmpty ||
        conversation is! String ||
        deadline is! int ||
        (notice != null && (notice is! String || notice.length > 128))) {
      return null;
    }
    return _PendingFriendRemoval(
      accountId: account,
      peerId: peer,
      conversationId: conversation,
      deadlineMs: deadline,
      noticeCommitId: notice as String?,
    );
  }
}

enum DmTopicIntroduction { none, suggestion, preview }

/// Per-process Windows capture-consent decision. The decision itself is
/// never persisted; permanence lives only in the separate
/// `windowsCaptureProtectionEnabled` preference, which the gate's explicit
/// "Show always" action and the Settings switch write.
enum WindowsCaptureConsent { pending, protect, showThisSession }

/// A friend request's peer-claimed name (incoming vCard FN or the invite/Nearby
/// name we added them under). Untrusted and display-only: malformed or
/// oversized values are rejected, controls/bidi overrides stripped, and the
/// result capped like a Nearby name. Never stored as the profile name.
String? friendNameHint(Object? value) {
  final decoded = ProfileWireContract.decodeDisplayName(value);
  if (decoded == null) return null;
  final clean = NearbyProtocol.sanitizeName(decoded);
  return clean.isEmpty ? null : clean;
}

String _friendIdentityColorKey(String peerId) =>
    'friendIdentityColor.v1.$peerId';

/// The name this user chose when sending a request (Nearby or invite). It is
/// kept until the peer's profile arrives so a restart does not turn a pending
/// person into "Friend · 1a2b". Peers' own request names are not stored.
const _friendNameHintPrefix = 'friendNameHint.v1.';

class FriendState {
  final String peerId;
  final bool confirmed;
  final String conversationId;
  final String displayName;

  /// Unverified request name shown only while [displayName] is empty.
  final String nameHint;
  final String avatarBase64;
  final PeerPresence presence;
  final int peerFgTs;
  final String presencePlatform;
  final String presenceActivity;
  final IdentityColor? identityColor;

  const FriendState({
    required this.peerId,
    required this.confirmed,
    required this.conversationId,
    this.displayName = '',
    this.nameHint = '',
    this.avatarBase64 = '',
    this.presence = PeerPresence.unknown,
    this.peerFgTs = 0,
    this.presencePlatform = '',
    this.presenceActivity = '',
    this.identityColor,
  });

  FriendState copyWith({
    bool? confirmed,
    String? conversationId,
    String? displayName,
    String? avatarBase64,
    PeerPresence? presence,
    int? peerFgTs,
    String? presencePlatform,
    String? presenceActivity,
    IdentityColor? identityColor,
  }) => FriendState(
    peerId: peerId,
    confirmed: confirmed ?? this.confirmed,
    conversationId: conversationId ?? this.conversationId,
    displayName: displayName ?? this.displayName,
    nameHint: nameHint,
    avatarBase64: avatarBase64 ?? this.avatarBase64,
    presence: presence ?? this.presence,
    peerFgTs: peerFgTs ?? this.peerFgTs,
    presencePlatform: presencePlatform ?? this.presencePlatform,
    presenceActivity: presenceActivity ?? this.presenceActivity,
    identityColor: identityColor ?? this.identityColor,
  );
}

class GroupState {
  const GroupState({
    required this.conversationId,
    required this.title,
    this.description = '',
    required this.memberCount,
    required this.canManageMembers,
    this.localRole = JamiGroupMemberRole.member,
    this.memberRoles = const {},
    this.memberDisplayNames = const {},
    this.memberAvatars = const {},
    required this.memberIds,
    required this.activeMemberIds,
    required this.invitedMemberIds,
  });

  final String conversationId;
  final String title;
  final String description;
  final int memberCount;
  final bool canManageMembers;
  final JamiGroupMemberRole localRole;
  final Map<String, JamiGroupMemberRole> memberRoles;
  final Map<String, String> memberDisplayNames;
  final Map<String, String> memberAvatars;
  final List<String> memberIds;
  final Set<String> activeMemberIds;
  final Set<String> invitedMemberIds;

  String get ownerKey => 'group:$conversationId';
  String get displayTitle => title.trim().isEmpty ? 'Untitled group' : title;
  GroupLayout get layout => GroupLayoutCodec.decode(description);
}

class FriendActivity {
  const FriendActivity({
    this.lastActivityAt,
    this.unreadMessages = 0,
    this.unreadFiles = 0,
  });

  final DateTime? lastActivityAt;
  final int unreadMessages;
  final int unreadFiles;

  int get unreadTotal => unreadMessages + unreadFiles;

  FriendActivity copyWith({
    DateTime? lastActivityAt,
    int? unreadMessages,
    int? unreadFiles,
  }) => FriendActivity(
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    unreadMessages: unreadMessages ?? this.unreadMessages,
    unreadFiles: unreadFiles ?? this.unreadFiles,
  );
}

class CallSession {
  final String callId;
  final CallDir dir;
  final String peerId;
  String state;
  bool micMuted;
  bool speakerOn;
  MicrophoneMode micMode;
  bool manuallyMuted;
  int manualMuteRevision = 0;
  bool pushToTalkPressed;
  bool microphoneBootstrapMuted;
  bool microphonePolicyApplied;
  bool? acknowledgedMicrophoneMuted;
  int microphoneCommandsInFlight = 0;
  bool microphoneTeardownPending = false;
  bool localVoiceActive;
  String? nativeAccountRevision;
  String? remoteVoiceStreamId;
  double? remoteVoiceLevel;
  DateTime? remoteVoiceMeterAt;
  Timer? remoteVoiceExpiry;

  int? selfTextureId;
  int? remoteTextureId;
  OutgoingVideoSource outgoingVideo;
  bool sourceChanging;
  bool selfActive;
  bool remoteActive;
  bool peerVideo;
  bool selfFront;
  int selfWidth;
  int selfHeight;
  int remoteWidth;
  int remoteHeight;
  OutgoingVideoKind peerVideoKind;
  bool everConnected;

  CallSession({
    required this.callId,
    required this.dir,
    required this.peerId,
    this.state = '',
    this.micMuted = false,
    this.speakerOn = false,
    this.micMode = MicrophoneMode.open,
    this.manuallyMuted = false,
    this.pushToTalkPressed = false,
    this.microphoneBootstrapMuted = false,
    this.microphonePolicyApplied = false,
    this.localVoiceActive = false,
    this.selfTextureId,
    this.remoteTextureId,
    bool cameraOn = false,
    OutgoingVideoSource? outgoingVideo,
    this.sourceChanging = false,
    this.selfActive = false,
    this.remoteActive = false,
    this.peerVideo = false,
    this.selfFront = true,
    this.selfWidth = 0,
    this.selfHeight = 0,
    this.remoteWidth = 0,
    this.remoteHeight = 0,
    this.peerVideoKind = OutgoingVideoKind.off,
    this.everConnected = false,
  }) : acknowledgedMicrophoneMuted = micMuted,
       outgoingVideo =
           outgoingVideo ??
           (cameraOn
               ? const OutgoingVideoSource(kind: OutgoingVideoKind.camera)
               : const OutgoingVideoSource.off());

  bool get connected => state == 'CURRENT';

  void clearRemoteVoiceSample() {
    remoteVoiceExpiry?.cancel();
    remoteVoiceExpiry = null;
    remoteVoiceLevel = null;
    remoteVoiceMeterAt = null;
  }

  void clearRemoteVoiceActivity() {
    clearRemoteVoiceSample();
    remoteVoiceStreamId = null;
  }

  bool get cameraOn => outgoingVideo.isCamera;
  set cameraOn(bool value) {
    outgoingVideo = OutgoingVideoSource(
      kind: value ? OutgoingVideoKind.camera : OutgoingVideoKind.off,
      revision: outgoingVideo.revision,
    );
  }

  bool get sharingScreen => outgoingVideo.isScreen;
  bool get cameraChanging => sourceChanging;
  set cameraChanging(bool value) => sourceChanging = value;
  int get cameraRevision => outgoingVideo.revision;
  set cameraRevision(int value) =>
      outgoingVideo = outgoingVideo.copyWith(revision: value);

  bool get hasVideo => outgoingVideo.active || peerVideo || remoteActive;
}

const _terminal = ['HUNGUP', 'OVER', 'FAILURE', 'BUSY', 'PEER_BUSY'];
const _composerActivityRepeat = Duration(seconds: 2);

int _asInt(dynamic v, [int fallback = 0]) =>
    v is int ? v : int.tryParse('${v ?? ''}') ?? fallback;
String _asString(dynamic v, [String fallback = '']) =>
    v is String ? v : fallback;
String? _nativeAccountRevision(JamiEvent event) {
  final value = event.data['accountRevision'];
  return isWidgetNativeRevision(value) ? value as String : null;
}

bool _asBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is String) {
    if (v == 'true') return true;
    if (v == 'false') return false;
  }
  return fallback;
}

List<GroupActiveCall> _groupCallsFromEvent(Map<String, dynamic> data) {
  Object? raw = data['calls'];
  if (raw == null && data['callsJson'] is String) {
    try {
      raw = jsonDecode(data['callsJson'] as String);
    } on Object {
      return const [];
    }
  }
  if (raw is! List) return const [];
  final result = <GroupActiveCall>[];
  for (final value in raw) {
    if (value is! Map) continue;
    final map = <String, dynamic>{
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final conferenceId = _asString(map['conferenceId'], _asString(map['id']));
    final hostUri = _asString(map['hostUri'], _asString(map['uri']));
    final hostDevice = _asString(map['hostDevice'], _asString(map['device']));
    if (GroupConferenceAddress.tryParse(conferenceId) == null ||
        hostUri.isEmpty ||
        hostDevice.isEmpty) {
      continue;
    }
    result.add(
      GroupActiveCall(
        conferenceId: conferenceId,
        hostUri: hostUri,
        hostDevice: hostDevice,
      ),
    );
  }
  return result;
}

GroupConferenceSnapshot _groupConferenceFromEvent(Map<String, dynamic> data) {
  Object? raw = data['participants'];
  if (raw == null && data['participantsJson'] is String) {
    try {
      final encoded = data['participantsJson'] as String;
      if (encoded.length > GroupConferenceSnapshot.maxEncodedLength) {
        return const GroupConferenceSnapshot([]);
      }
      raw = jsonDecode(encoded);
    } on Object {
      return const GroupConferenceSnapshot([]);
    }
  }
  return GroupConferenceSnapshot.fromWire(raw is List ? raw : const []);
}

String _canonicalConnectionProfile(Object? value) => switch (value) {
  'lan' => 'lan',
  'strict' => 'strict',
  _ => 'jami',
};

String _boundedRegistration(Object? value, [String fallback = 'UNREGISTERED']) {
  if (value is! String || value.isEmpty || value.length > 64) {
    return fallback;
  }
  for (final unit in value.codeUnits) {
    if (!((unit >= 0x41 && unit <= 0x5a) ||
        (unit >= 0x30 && unit <= 0x39) ||
        unit == 0x5f)) {
      return fallback;
    }
  }
  return value;
}

MicrophoneMode _supportedMicrophoneMode(MicrophoneMode mode) =>
    mode == MicrophoneMode.voiceActivated ? MicrophoneMode.open : mode;

/// An honest note for an outgoing call that never connected. Transport or peer failure can surface as
/// PEER_BUSY just like a fast FAILURE, so both read the same: the selected network path did not form.
/// Client-side redial is not used; see docs/ARCHITECTURE.md. null = a normal hangup → no message.
String? _failNote(String state) {
  switch (state) {
    case 'FAILURE':
    case 'BUSY':
    case 'PEER_BUSY':
      return "Couldn't reach them — try again";
    default:
      return null;
  }
}

final class _SharedPreferencesAppSettingsDocumentStore
    implements AppSettingsDocumentStore {
  const _SharedPreferencesAppSettingsDocumentStore(
    this.preferences,
    this.jami,
    this.onCacheRefreshFailure,
    this.onNativePolicyAvailability,
  );

  static const documentKey = 'appSettings';

  final SharedPreferences preferences;
  final JamiClient jami;
  final void Function(Object) onCacheRefreshFailure;
  final void Function(bool) onNativePolicyAvailability;

  @override
  Future<Map<String, Object?>?> readDocument() async {
    // A failed legacy save may have published only an optimistic cache value.
    await preferences.reload();
    final encoded = preferences.getString(documentKey);
    if (encoded == null) return null;
    if (jami.usesNativeAppSettingsStore) {
      if (utf8.encode(encoded).length > JamiClient.maxSettingsDocumentBytes) {
        throw const FormatException(
          'app settings document exceeds the native limit',
        );
      }
      // Native settings use the same strict JSON grammar, duplicate-key
      // rejection and depth-20 boundary as the remote-control validator.
      RemoteControlJsonValidator(encoded).validate();
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('app settings document must be an object');
    }
    if (jami.usesNativeAppSettingsStore &&
        decoded['schemaVersion'] is int &&
        (decoded['schemaVersion'] as int) >= 2) {
      final microphone = decoded['microphone'];
      final overrides = microphone is Map
          ? microphone['conversationOverrides']
          : null;
      if (overrides is List) {
        for (final entry in overrides) {
          // Missing kind is the supported legacy inference. An explicit
          // invalid kind is rejected by Android's notification policy parser.
          if (entry is Map &&
              entry.containsKey('kind') &&
              !const {'direct', 'group'}.contains(entry['kind'])) {
            throw const FormatException('invalid microphone scope kind');
          }
        }
      }
    }
    return {
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  @override
  Future<void> writeDocument(Map<String, Object?> document) async {
    if (jami.usesNativeAppSettingsStore) {
      onNativePolicyAvailability(false);
      await jami.saveAppSettingsDocument(jsonEncode(document));
      onNativePolicyAvailability(true);
      try {
        await preferences.reload();
      } catch (error) {
        // Native has committed the canonical document. A cache error cannot
        // turn that success into a rollback to a different microphone policy.
        onCacheRefreshFailure(error);
      }
      return;
    }
    try {
      if (!await preferences.setString(documentKey, jsonEncode(document))) {
        throw StateError('SharedPreferences rejected the app settings write');
      }
    } catch (_) {
      // Keep the original failure. A later read must still reread storage.
      try {
        await preferences.reload();
      } catch (_) {}
      rethrow;
    }
  }
}

final class _SharedPreferencesAppLockLatchStore implements AppLockLatchStore {
  const _SharedPreferencesAppLockLatchStore(this.preferences);

  static const key = 'appLockEnabled.v1';

  final SharedPreferences preferences;

  @override
  bool contains() => preferences.containsKey(key);

  @override
  Object? read() => preferences.get(key);

  @override
  Future<bool> write(bool enabled) => preferences.setBool(key, enabled);
}

final class _PendingTimelineLoad {
  _PendingTimelineLoad({
    required this.request,
    required this.completer,
    required this.timeout,
  });

  final TimelineLoadRequest request;
  final Completer<TimelineHistoryPage> completer;
  final Timer timeout;
}

/// Correlates libjami's asynchronous `SwarmLoaded` callback to the exact Dart
/// request that started it. A callback may beat the MethodChannel reply, so a
/// small bounded early-event buffer is part of the adapter rather than UI
/// state.
final class _JamiConversationTimelineRepository
    implements ConversationTimelineRepository {
  _JamiConversationTimelineRepository(this.jami);

  static const _loadTimeout = Duration(seconds: 30);
  static const _maxEarlySnapshots = 32;
  static const _maxCompletedIds = 128;

  final JamiClient jami;
  final Map<int, _PendingTimelineLoad> _pending = {};
  final Map<int, JamiEvent> _earlySnapshots = {};
  final Set<int> _completedIds = {};
  bool _disposed = false;

  @override
  Future<TimelineLoadHandle> startLoad(TimelineLoadRequest request) async {
    if (_disposed) throw StateError('timeline repository is disposed');
    final loadId = await jami.loadChat(
      request.scope.peerId,
      request.scope.conversationId,
      fromMessage: request.beforeCursor ?? '',
      pageSize: request.limit,
    );
    if (_disposed) {
      await _cancelNativeLoad(loadId);
      throw StateError('timeline repository is disposed');
    }
    if (loadId == 0) throw const TimelineNotReadyException();
    if (loadId < 0 ||
        _pending.containsKey(loadId) ||
        _completedIds.contains(loadId)) {
      await _cancelNativeLoad(loadId);
      throw const TimelineProtocolException(
        'daemon returned an invalid or reused chat load id',
      );
    }

    final completer = Completer<TimelineHistoryPage>();
    // A retired controller may stop awaiting its handle. Keep a local error
    // consumer so timeout/disposal never becomes an unhandled async error.
    unawaited(() async {
      try {
        await completer.future;
      } catch (_) {
        // The controller that still owns this request observes the same error.
      }
    }());
    late final Timer timeout;
    timeout = Timer(_loadTimeout, () {
      final pending = _pending[loadId];
      if (pending == null || pending.completer != completer) return;
      _pending.remove(loadId);
      _rememberCompleted(loadId);
      unawaited(_cancelNativeLoad(loadId));
      completer.completeError(
        TimeoutException('chat history load $loadId timed out', _loadTimeout),
      );
    });
    _pending[loadId] = _PendingTimelineLoad(
      request: request,
      completer: completer,
      timeout: timeout,
    );

    final early = _earlySnapshots.remove(loadId);
    if (early != null) _complete(loadId, early);
    return TimelineLoadHandle(
      daemonLoadId: '$loadId',
      completion: completer.future,
    );
  }

  @override
  Future<void> cancelLoad(String daemonLoadId) async {
    final loadId = int.tryParse(daemonLoadId);
    if (loadId == null || loadId <= 0 || _completedIds.contains(loadId)) {
      return;
    }
    final pending = _pending.remove(loadId);
    pending?.timeout.cancel();
    _earlySnapshots.remove(loadId);
    _rememberCompleted(loadId);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(
        StateError('chat history load $loadId was retired'),
      );
    }
    await _cancelNativeLoad(loadId);
  }

  void handleSnapshot(JamiEvent event) {
    if (_disposed) return;
    final loadId = _asInt(event.data['loadId'], -1);
    if (loadId <= 0 || _completedIds.contains(loadId)) return;
    if (_pending.containsKey(loadId)) {
      _complete(loadId, event);
      return;
    }
    _earlySnapshots.putIfAbsent(loadId, () => event);
    while (_earlySnapshots.length > _maxEarlySnapshots) {
      _earlySnapshots.remove(_earlySnapshots.keys.first);
    }
  }

  void _complete(int loadId, JamiEvent event) {
    final pending = _pending.remove(loadId);
    if (pending == null) return;
    pending.timeout.cancel();
    _rememberCompleted(loadId);
    try {
      pending.completer.complete(
        _pageFromEvent(loadId, pending.request, event),
      );
    } catch (error, stackTrace) {
      pending.completer.completeError(error, stackTrace);
    }
  }

  TimelineHistoryPage _pageFromEvent(
    int loadId,
    TimelineLoadRequest request,
    JamiEvent event,
  ) {
    final data = event.data;
    final scope = ConversationScope(
      accountId: _asString(data['accountId']),
      peerId: _asString(data['peerJamiId']),
      conversationId: _asString(data['conversationId']),
    );
    Object? rawItems = data['items'];
    if (rawItems == null && data['itemsJson'] is String) {
      final encoded = data['itemsJson'] as String;
      if (encoded.length > TimelineWireContract.maxSnapshotEncodedBytes ||
          utf8.encode(encoded).length >
              TimelineWireContract.maxSnapshotEncodedBytes) {
        throw const TimelineProtocolException(
          'chat snapshot exceeds the encoded-size contract',
        );
      }
      try {
        rawItems = jsonDecode(encoded);
      } catch (error) {
        throw TimelineProtocolException(
          'chat snapshot itemsJson is invalid: $error',
        );
      }
    }
    if (rawItems is! List) {
      throw const TimelineProtocolException(
        'chat snapshot items must be a list',
      );
    }
    if (rawItems.length > TimelineWireContract.maxSnapshotItems) {
      throw const TimelineProtocolException(
        'chat snapshot exceeds the item-count contract',
      );
    }
    final items = <Map<String, Object?>>[];
    for (final rawItem in rawItems) {
      if (rawItem is! Map) {
        throw const TimelineProtocolException(
          'chat snapshot item must be an object',
        );
      }
      items.add({
        for (final entry in rawItem.entries)
          if (entry.key is String) entry.key as String: entry.value,
      });
    }
    String? cursor(Object? value) {
      final text = _asString(value);
      return text.isEmpty ? null : text;
    }

    return TimelineHistoryPage(
      scope: scope,
      generation: request.generation,
      requestId: request.requestId,
      daemonLoadId: '$loadId',
      requestedCursor: cursor(data['requestedCursor']),
      nextCursor: cursor(data['nextCursor']),
      hasMore: _asBool(data['hasMore']),
      items: items,
    );
  }

  void _rememberCompleted(int loadId) {
    _completedIds.add(loadId);
    while (_completedIds.length > _maxCompletedIds) {
      _completedIds.remove(_completedIds.first);
    }
  }

  Future<void> _cancelNativeLoad(int loadId) async {
    if (loadId <= 0) return;
    try {
      await jami.cancelChatLoad(loadId);
    } catch (error) {
      debugPrint('[timeline] cancelChatLoad failed');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _pending.entries) {
      final pending = entry.value;
      pending.timeout.cancel();
      unawaited(_cancelNativeLoad(entry.key));
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('timeline repository disposed'),
        );
      }
    }
    _pending.clear();
    _earlySnapshots.clear();
    _completedIds.clear();
  }
}

enum DmTopicHistoryStatus { loading, ready, failed, tooLarge }

final class _DmTopicStateScan {
  _DmTopicStateScan({required this.scope, this.attempt = 0});

  final ConversationScope scope;
  final int attempt;
  final List<Map<String, Object?>> newestFirst = [];
  final Set<String> cursors = {''};
  int retainedBytes = 0;
  String requestedCursor = '';
  bool requestPending = false;
  bool failed = false;
  Timer? timer;
}

/// One conversation action can advance its own selection, but cannot adopt a
/// selection made by a different action while it waits.
final class ConversationAction {
  ConversationAction._(this._owner, this._isCurrent);
  Object _owner;
  final bool Function()? _isCurrent;
}

/// Owns identity, the daemon-backed friend snapshot, UI selection, calls,
/// file transfers and settings. [PresenceCoordinator] schedules peer liveness;
/// listeners rebuild the UI when state changes.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  // A topic projection is exact only after the complete ordered history fits
  // this budget. An over-budget scan keeps the last complete projection.
  static const _maxDmTopicScanRecords = 20000;
  static const _maxDmTopicScanBytes = 32 * 1024 * 1024;
  static const _maxDmTopicLiveRecords = 64;
  static const _maxDmTopicLiveBytes = 512 * 1024;
  static const _dmTopicSelectionsKey = 'dmTopicLastSelectionsV1';
  static const _groupTopicSelectionsKey = 'groupTopicLastSelectionsV1';
  static const _dmTopicIntroductionUnderstoodKey =
      'dmTopicIntroductionUnderstoodV1';
  static const _dmTopicIntroductionPendingKey = 'dmTopicIntroductionPendingV1';
  static const _dmTopicIntroductionConversationKey =
      'dmTopicIntroductionConversationV1';
  static const _wakeCapabilitiesKey = 'wakeCapabilitiesV1';
  static const _widgetChatCaptureConsentKey = 'widgetChatCaptureConsent.v1';

  final JamiClient jami;
  final SharedPreferences prefs;
  late final OverlaySettings overlaySettings = OverlaySettings(
    PreferencesOverlayStore(prefs),
  );
  late final _presenceColorCache = PresenceColorCache(
    write: (peer, color) async {
      if (!_disposed && _friends.containsKey(peer)) {
        await prefs.setString(
          _friendIdentityColorKey(peer),
          color.storageValue,
        );
      }
    },
    remove: (peer) async {
      await prefs.remove(_friendIdentityColorKey(peer));
    },
    onError: (error, stack) {
      debugPrint('Friend color cache write failed');
    },
  );
  final StreamController<SyblSoundEvent> _soundEvents =
      StreamController<SyblSoundEvent>.broadcast(sync: true);
  Stream<SyblSoundEvent> get soundEvents => _soundEvents.stream;

  void _playSound(SyblSoundEvent event) {
    if (!_disposed) _soundEvents.add(event);
  }

  NearbyController? _nearby;
  StreamSubscription<String>? _nearbySonar;
  StreamSubscription<SonarEvent>? _nearbyCombat;
  bool _nearbyAllowed = false;

  /// Doorlight's own local-network discovery, or null when this host has no
  /// transport (tests, unsupported platforms).
  NearbyController? get nearby => _nearby;

  /// Production hosts attach the multicast transport once. Nothing is bound
  /// until [_syncNearby] finds the app foreground, unlocked and online.
  void attachNearby(NearbyTransport transport) {
    if (_disposed || _nearby != null) return;
    final controller = NearbyController(transport: transport);
    _nearby = controller;
    _nearbySonar = controller.sonarReceived.listen(
      (_) => _playSound(SyblSoundEvent.sonarReceived),
    );
    _nearbyCombat = controller.combat.listen(_playCombat);
    addListener(_syncNearby);
    _syncNearby();
  }

  // Listening is passive but still binds a socket, so it follows the same
  // privacy gates as presence: only the visible, unlocked, online home screen.
  void _syncNearby() {
    final controller = _nearby;
    if (controller == null || _disposed) return;
    final id = jamiId;
    controller
      ..ownName = displayName
      ..ownId = id;
    final allowed =
        screen == Screen.home &&
        accountId != null &&
        id.isNotEmpty &&
        _foreground &&
        !_protectedSurfaceLocked &&
        !captureGateVisible &&
        !appearOffline &&
        !_restoringIdentity;
    // start/stop are serialized, so queueing on every change of the decision
    // (not of the current status) keeps the last decision authoritative even
    // while a previous start is still binding. A failed bind retries on the
    // next allow, e.g. after the app returns to the foreground.
    if (allowed == _nearbyAllowed) return;
    _nearbyAllowed = allowed;
    unawaited(allowed ? controller.start() : controller.stop());
  }

  void _playCombat(SonarEvent event) {
    if (_nearby?.destroyed == true &&
        event.cue != SonarCue.destroyed &&
        event.cue != SonarCue.incomingEnded &&
        event.cue != SonarCue.ambienceOff &&
        event.cue != SonarCue.missileGone) {
      return;
    }
    switch (event.cue) {
      case SonarCue.charge:
        _playSound(
          event.step % 10 == 0
              ? SyblSoundEvent.sonarTargetLock
              : SyblSoundEvent.sonarTargetTick,
        );
      case SonarCue.launched:
        _playSound(SyblSoundEvent.sonarMissileShot);
        _playSound(SyblSoundEvent.sonarMissileEnRoute);
      case SonarCue.impact:
        _playSound(SyblSoundEvent.stopMissileEnRoute);
        _playSound(SyblSoundEvent.sonarHit);
      case SonarCue.missileGone:
        _playSound(SyblSoundEvent.stopMissileEnRoute);
      case SonarCue.sunk:
        _playSound(SyblSoundEvent.sonarEnemySunk);
      case SonarCue.incoming:
      case SonarCue.incomingClose:
        _syncIncomingSound();
      case SonarCue.targetLost:
        if (!event.inbound) _playSound(SyblSoundEvent.stopMissileEnRoute);
        if (event.inbound) _syncIncomingSound();
        _playSound(SyblSoundEvent.sonarMissileTargetLost);
      case SonarCue.collision:
        _playSound(SyblSoundEvent.stopMissileEnRoute);
        _syncIncomingSound();
        _playSound(SyblSoundEvent.sonarMissileHitEachOther);
      case SonarCue.shutdown:
        _playSound(SyblSoundEvent.sonarOff);
      case SonarCue.hit:
        _syncIncomingSound();
        _playSound(SyblSoundEvent.sonarIncomingMissileHit);
        if (event.low) _playSound(SyblSoundEvent.sonarWarningLowHealth);
      case SonarCue.destroyed:
        _playSound(SyblSoundEvent.stopCharge);
        _playSound(SyblSoundEvent.stopMissileEnRoute);
        _playSound(SyblSoundEvent.stopIncomingWarning);
        _playSound(SyblSoundEvent.stopAmbience);
        _playSound(SyblSoundEvent.sonarIncomingMissileKill);
      case SonarCue.ambienceOn:
        _playSound(SyblSoundEvent.sonarAmbience);
      case SonarCue.ambienceOff:
        _playSound(SyblSoundEvent.stopAmbience);
      case SonarCue.rearmed:
        break;
      case SonarCue.incomingEnded:
        _syncIncomingSound();
    }
  }

  void _syncIncomingSound() {
    final nearby = _nearby;
    _playSound(
      nearby == null || nearby.incoming == 0
          ? SyblSoundEvent.stopIncomingWarning
          : nearby.incomingClose
          ? SyblSoundEvent.sonarIncomingMissileClose
          : SyblSoundEvent.sonarIncomingMissile,
    );
  }

  /// Reveals this device nearby for one window. Plays the sonar only when an
  /// announcement is actually going out.
  bool revealNearby() {
    final controller = _nearby;
    if (controller == null) return false;
    _syncNearby();
    final revealed = controller.goVisible();
    if (revealed) _playSound(SyblSoundEvent.sonarSend);
    return revealed;
  }

  void chargeNearbyReveal(bool held) =>
      _playSound(held ? SyblSoundEvent.sonarCharge : SyblSoundEvent.stopCharge);

  /// Every tap while visible sounds and ripples locally; only the LAN
  /// announcement is rate-limited by [NearbyController.pulse].
  bool pulseNearby() {
    final nearby = _nearby;
    if (nearby == null || !nearby.visible) return false;
    nearby.pulse();
    _playSound(SyblSoundEvent.sonarPulse);
    return true;
  }

  AppState(this.jami, this.prefs) {
    _widgetChatCaptureGranted =
        prefs.getBool(_widgetChatCaptureConsentKey) ?? false;
    inviteContinuation = PendingInviteStore(
      source: prefs.get(PendingInviteStore.preferenceKey),
      persist: (source) => source == null
          ? prefs.remove(PendingInviteStore.preferenceKey)
          : prefs.setString(PendingInviteStore.preferenceKey, source),
    )..addListener(_onInviteContinuationChanged);
    unawaited(_loadHologramManifest());
    sendJournal = SendJournal(
      source: prefs.getString(SendJournal.preferenceKey),
      load: jami.usesNativeSendJournal ? jami.loadSendJournal : null,
      persist: jami.usesNativeSendJournal
          ? jami.saveSendJournal
          : (source) => prefs.setString(SendJournal.preferenceKey, source),
    );
    _wakeCapabilities = WakeCapabilities.decode(
      prefs.getString(_wakeCapabilitiesKey),
    );
    _loadDmTopicSelections();
    _loadGroupTopicSelections();
    _loadPendingRemovals();
    _dmTopicIntroductionUnderstood =
        prefs.getBool(_dmTopicIntroductionUnderstoodKey) ?? false;
    _dmTopicIntroductionConversationId = prefs.getString(
      _dmTopicIntroductionConversationKey,
    );
    // An old pending flag has no owner and must not follow an arbitrary friend.
    _dmTopicIntroductionPending =
        (prefs.getBool(_dmTopicIntroductionPendingKey) ?? false) &&
        (_dmTopicIntroductionConversationId?.isNotEmpty ?? false);
    _fileTransfers = FileTransferController(
      jami: jami,
      accountId: () => accountId ?? '',
      ownsConversation: (peer, conversation) {
        final friend = _friends[peer];
        if (friend != null &&
            friend.confirmed &&
            friend.conversationId == conversation) {
          return true;
        }
        final group = _groups[conversation];
        return group != null &&
            group.ownerKey == peer &&
            group.conversationId == conversation;
      },
      isOffline: () => appearOffline,
      maxIncomingFileBytes: () => maxIncomingFileBytes,
      onCompletedTransfer: _onCompletedTransfer,
      onOutgoingStarted: _wakeConversationOwner,
      log: dlog,
    );
    _fileTransfers.addListener(_onFileTransfersChanged);
    remoteControl = RemoteControlController(
      JamiRemoteControlTransport(jami),
      identityColor: () => identityColor.storageValue,
      requestAllowed: () => !settingsBusy,
    );
    remoteControl.addListener(_onRemoteControlChanged);
    _settingsRepository = VersionedAppSettingsRepository(
      _SharedPreferencesAppSettingsDocumentStore(prefs, jami, (error) {
        _appendSettingsError(
          'Settings were saved, but their local cache could not be refreshed.',
        );
        dlog('settings cache refresh failed: $error');
      }, _setMicrophoneSettingsKnown),
    );
    _appLockLatchRepository = AppLockLatchRepository(
      _SharedPreferencesAppLockLatchStore(prefs),
    );
    _timelineRepository = _JamiConversationTimelineRepository(jami);
    _presence = PresenceCoordinator(
      jami.probeReachable,
      jami.connectivitySweep,
      (peer) => _friends[peer]?.presence,
      (peer) => _friendPresenceEvidence(peer),
      (peer) => _setFriendPresence(peer, PeerPresence.unreachable),
      dlog,
    );
    // M8: annotation draw events ride the in-call side channel, but ONLY while the call is live (CURRENT) — the
    // daemon queues/drops in-call messages sent before then, so gate on a connected call here (don't buffer).
    annotation.sender = (json) {
      final c = call;
      if (c == null || !c.connected) return;
      _runInBackground(
        jami.sendCallMessage(c.callId, jsonEncode(json)),
        'sendCallMessage',
      );
    };
    annotation.addListener(_onAnnotationChanged);
    annotation.repaint.addListener(_scheduleAnnotationOverlay);
  }

  late final RemoteControlController remoteControl;
  bool remoteControlAccessibilityEnabled = false;
  late final FileTransferController _fileTransfers;
  late final WakeCapabilities _wakeCapabilities;
  final WakeRelay _wakeRelay = WakeRelay();
  final DmTopicIntroductionTracker _dmTopicIntroductionTracker =
      DmTopicIntroductionTracker();
  bool _dmTopicIntroductionUnderstood = false;
  bool _dmTopicIntroductionPending = false;
  bool _manualDmTopicIntroduction = false;
  String? _dmTopicIntroductionConversationId;
  DmTopicIntroduction _dmTopicIntroduction = DmTopicIntroduction.none;
  DmTopicIntroduction get dmTopicIntroduction => _dmTopicIntroduction;
  Timer? _annotationOverlayTimer;
  bool _annotationOverlayMayBeActive = false;

  void _onAnnotationChanged() {
    // A peer source announcement completes the exact revision binding used by
    // remote control. Reconcile it immediately; previously only media events
    // called _syncRemoteControl, so a valid late `src` announcement updated the
    // annotation controller but never made the Control action requestable.
    _syncRemoteControl();
    _scheduleAnnotationOverlay();
  }

  void _scheduleAnnotationOverlay() {
    if ((!Platform.isAndroid && !Platform.isWindows) || _disposed) return;
    final current = annotation.ownedScreenOverlaySnapshot(call?.callId ?? '');
    final currentActive = current['active'] == true;
    if (!currentActive &&
        !_annotationOverlayMayBeActive &&
        _annotationOverlayTimer == null) {
      return;
    }
    if (currentActive) _annotationOverlayMayBeActive = true;
    _annotationOverlayTimer ??= Timer(const Duration(milliseconds: 32), () {
      _annotationOverlayTimer = null;
      if (_disposed) return;
      final snapshot = annotation.ownedScreenOverlaySnapshot(
        call?.callId ?? '',
      );
      _annotationOverlayMayBeActive = snapshot['active'] == true;
      _runInBackground(
        jami.setAnnotationOverlay(snapshot),
        'setAnnotationOverlay',
      );
    });
  }

  void _onRemoteControlChanged() {
    // Draw and remote-control input share the same pointer surface. Keep the
    // modes mutually exclusive even when native grant state changes between
    // Flutter frames.
    if ((remoteControl.phase == RemoteControlPhase.requesting ||
            remoteControl.isControlling) &&
        annotation.enabled) {
      annotation.setEnabled(false);
    }
    notifyListeners();
  }

  void _onFileTransfersChanged() {
    _refreshDmTopicIntroduction();
    notifyListeners();
  }

  void _onCompletedTransfer(FileXfer transfer) {
    if (_dmTopicIntroductionUnderstood ||
        _groups.containsKey(transfer.conversationId)) {
      return;
    }
    final friend = _friends[transfer.peerId];
    final scope = _scopeForPeer(transfer.peerId);
    if (friend == null ||
        friend.conversationId != transfer.conversationId ||
        (_dmTopicStates[scope]?.customTopics.isNotEmpty ?? false) ||
        !_dmTopicIntroductionTracker.recordCompleted((
          peerId: transfer.peerId,
          conversationId: transfer.conversationId,
        ))) {
      return;
    }
    _dmTopicIntroductionPending = true;
    _dmTopicIntroductionConversationId = transfer.conversationId;
    _runInBackground(
      Future.wait([
        prefs.setString(
          _dmTopicIntroductionConversationKey,
          transfer.conversationId,
        ),
        prefs.setBool(_dmTopicIntroductionPendingKey, true),
      ]),
      'saveDmTopicIntroductionPending',
    );
    _refreshDmTopicIntroduction();
  }

  bool get _dmTopicTransferControlsIdle {
    final friend = selectedFriend;
    if (friend == null) return false;
    return !_fileTransfers.transfers.values.any(
      (transfer) =>
          transfer.peerId == friend.peerId &&
          transfer.conversationId == friend.conversationId &&
          !transfer.done,
    );
  }

  void _refreshDmTopicIntroduction() {
    if (_manualDmTopicIntroduction) {
      _dmTopicIntroduction = DmTopicIntroduction.preview;
      return;
    }
    final friend = selectedFriend;
    final eligible =
        friend != null &&
        _dmTopicIntroductionConversationId == friend.conversationId &&
        !(selectedDmTopicState?.customTopics.isNotEmpty ?? false) &&
        _dmTopicTransferControlsIdle;
    _dmTopicIntroduction =
        !_dmTopicIntroductionUnderstood &&
            _dmTopicIntroductionPending &&
            eligible
        ? DmTopicIntroduction.suggestion
        : DmTopicIntroduction.none;
  }

  void showDmTopicIntroduction() {
    _manualDmTopicIntroduction = true;
    _refreshDmTopicIntroduction();
    notifyListeners();
  }

  void showDmTopicIntroductionPreview() {
    _dmTopicIntroduction = DmTopicIntroduction.preview;
    notifyListeners();
  }

  Future<void> dismissDmTopicIntroduction() async {
    if (_manualDmTopicIntroduction) {
      _manualDmTopicIntroduction = false;
      _refreshDmTopicIntroduction();
      notifyListeners();
      return;
    }
    _dmTopicIntroductionPending = false;
    _dmTopicIntroductionConversationId = null;
    _dmTopicIntroduction = DmTopicIntroduction.none;
    notifyListeners();
    await Future.wait([
      prefs.setBool(_dmTopicIntroductionPendingKey, false),
      prefs.remove(_dmTopicIntroductionConversationKey),
    ]);
  }

  Future<void> finishDmTopicIntroduction() async {
    if (_manualDmTopicIntroduction) {
      _manualDmTopicIntroduction = false;
      _refreshDmTopicIntroduction();
      notifyListeners();
      return;
    }
    await _markDmTopicIntroductionUnderstood();
  }

  Future<void> _markDmTopicIntroductionUnderstood() async {
    if (_dmTopicIntroductionUnderstood && !_dmTopicIntroductionPending) {
      return;
    }
    _dmTopicIntroductionUnderstood = true;
    _dmTopicIntroductionPending = false;
    _dmTopicIntroductionConversationId = null;
    _manualDmTopicIntroduction = false;
    _dmTopicIntroduction = DmTopicIntroduction.none;
    await Future.wait([
      prefs.setBool(_dmTopicIntroductionUnderstoodKey, true),
      prefs.setBool(_dmTopicIntroductionPendingKey, false),
      prefs.remove(_dmTopicIntroductionConversationKey),
    ]);
    notifyListeners();
  }

  Screen screen = Screen.loading;

  /// Fatal boot failure surfaced on the splash (null = booting/booted fine). Retry via [retryBoot].
  String? bootError;
  String? bootErrorDetails;
  bool pendingIdentityRecovery = false;
  String? _identityRecoveryReason;
  String get identityRecoveryTitle => switch (_identityRecoveryReason) {
    'journalUnreadable' => 'The restore recovery record could not be read.',
    'ownershipUnclear' =>
      'The unfinished restore could not be identified safely.',
    'rollbackPending' => 'Removing the unfinished restore was interrupted.',
    _ => 'An unfinished restore needs attention.',
  };
  String get identityRecoveryGuidance => switch (_identityRecoveryReason) {
    'journalUnreadable' =>
      'Your local data has been kept. Retry to check the protected recovery record.',
    'ownershipUnclear' =>
      'Your local data has been kept. Retry to verify which import needs recovery.',
    'rollbackPending' =>
      'Retry cleanup to finish removing the incomplete import. Your backup file stays unchanged.',
    _ when canDiscardIdentityRestore =>
      'Try again to finish restoring, or remove the unfinished import and choose your backup again.',
    _ =>
      'Your profile stays closed until the restore can be verified. Try again to check recovery.',
  };
  String get identityRecoveryRetryLabel =>
      _identityRecoveryReason == 'rollbackPending'
      ? 'Retry cleanup'
      : 'Try again';
  bool discardingIdentityRestore = false;
  (String, String, String?)? _discardableIdentityRestore;
  Object? get identityRestoreRecoveryOwner =>
      _discardableIdentityRestore == null
      ? null
      : (accountId, _accountRevision, _discardableIdentityRestore);
  bool get canDiscardIdentityRestore =>
      pendingIdentityRecovery && _discardableIdentityRestore != null;

  Future<bool> discardIdentityRestore(Object? confirmedOwner) async {
    final pending = _discardableIdentityRestore;
    if (!canDiscardIdentityRestore ||
        identityRestoreRecoveryOwner != confirmedOwner ||
        discardingIdentityRestore ||
        _initializationInFlight != null ||
        _bootInFlight != null ||
        _restoringIdentity ||
        devicePairingPending ||
        backingUp ||
        settingsBusy ||
        _profileMutationBusy ||
        _captureBusy ||
        call != null ||
        groupCall != null ||
        screen != Screen.loading ||
        _protectedSurfaceLocked ||
        captureGateVisible) {
      return false;
    }
    final owner = (accountId, _accountRevision);
    discardingIdentityRestore = true;
    _restoringIdentity = true;
    notifyListeners();
    var discarded = false;
    try {
      discarded = await jami.discardIdentityRestore(
        accountId: pending!.$1,
        restoreToken: pending.$2,
        expectedAccountId: pending.$3 ?? owner.$1,
      );
      if (_disposed ||
          owner != (accountId, _accountRevision) ||
          pending != _discardableIdentityRestore) {
        return false;
      }
      if (!discarded) {
        bootError = 'The unfinished restore could not be removed. Try again.';
        return false;
      }
      pendingIdentityRecovery = false;
      _discardableIdentityRestore = null;
      _startupPrepared = false;
      _reloadPreferencesBeforeStartup = true;
    } catch (_) {
      discarded = false;
      if (!_disposed && owner == (accountId, _accountRevision)) {
        bootError = 'The unfinished restore could not be removed. Try again.';
      }
    } finally {
      discardingIdentityRestore = false;
      _restoringIdentity = devicePairingPending;
      if (!_disposed) notifyListeners();
    }
    if (discarded && !_disposed) await retryBoot();
    return discarded;
  }

  String _bootStep = 'Preparing app settings';
  bool profileProtectionUnavailable = false;

  String _describeBootFailure(Object error) {
    // Native messages can contain identity paths or account data.
    final reason = switch (error) {
      PlatformException(code: 'native_startup_failed') =>
        'The native calling and messaging engine is unavailable.\nCode: native_startup_failed',
      PlatformException(code: 'archive_protection_failed') =>
        'The saved identity archive could not be verified with this device’s protection key.\nCode: archive_protection_failed',
      PlatformException(code: 'relaunch_required') =>
        'The engine requires a fresh application process.\nCode: relaunch_required',
      MissingPluginException() => 'The native engine bridge did not respond.',
      StateError(message: 'The pending identity restore needs recovery') =>
        identityRecoveryGuidance,
      StateError(message: 'Identity restore is in progress') =>
        'An identity restore is still in progress.',
      TypeError() => 'Startup received data in an unexpected format.',
      _ =>
        'Startup could not complete this step. No more specific cause was reported to this screen.',
    };
    return 'Step: $_bootStep\n$reason';
  }

  Future<void>? _bootInFlight;
  Future<void>? _initializationInFlight;
  bool _startupPrepared = false;
  bool _reloadPreferencesBeforeStartup = false;
  bool _runtimeAttached = false;
  int _conversationSelectionRevision = 0;
  int _accountRevision = 0;
  final composerDrafts = ComposerDraftStore();
  late final gifLibrary = GifLibraryStore(() async {
    final path = await jami.gifLibraryDirectory();
    return path == null ? null : Directory(path);
  });
  late final chatArchive = ChatArchiveStore(() async {
    final path = await jami.archivedChatsDirectory();
    return path == null ? null : Directory(path);
  });
  final Stopwatch _hologramClock = Stopwatch()..start();
  final Random _hologramRandom = Random.secure();
  StickerManifest? _hologramManifest;
  Timer? _hologramTimer;
  Object? _hologramPrivacyOwner;
  HologramPresentation? _soundedHologram;
  Object? _hologramSurface;
  int _hologramNativeGeneration = 0,
      _hologramNativeUntil = 0,
      _hologramProbes = 0;
  String _hologramNativeSurface = 'unavailable';
  (String, String)? _hologramNativePeer;
  Timer? _hologramNativeHeartbeat;

  final _liveMessageEffects = LiveMessageEffects();
  late final HologramLive _holograms = HologramLive(
    now: () => _hologramClock.elapsedMilliseconds,
    randomNonce: () => List.generate(
      16,
      (_) => _hologramRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
    eligible: _hologramEligible,
    assetEligible: (asset) =>
        _hologramManifest?.byId(asset)?.hologramEligible == true,
    send: (peer, packet) {
      final account = accountId;
      if (account == null || appearOffline || _restoringIdentity || _disposed) {
        return;
      }
      _runInBackground(
        jami.sendHologramControl(account, peer, packet.encode()),
        'hologram control',
      );
    },
    show: (presentation) {
      _hologramSurface = null;
      _hologramNativeHeartbeat?.cancel();
      _hologramTimer?.cancel();
      _hologramTimer = Timer(const Duration(milliseconds: 3350), () {
        _holograms.cancelPresentation();
        _hologramNativeHeartbeat?.cancel();
        if (_isWindowsPlatform) {
          _runInBackground(
            jami.cancelHologram(_hologramNativeGeneration),
            'cancel hologram',
          );
        }
        notifyListeners();
      });
      if (_isWindowsPlatform) {
        _runInBackground(
          _presentNativeHologram(presentation),
          'present hologram',
        );
      }
      notifyListeners();
    },
  );

  Future<void> _loadHologramManifest() async {
    try {
      final manifest = await bundledStickerManifest;
      if (!_disposed) _hologramManifest = manifest;
    } catch (_) {
      /* Missing assets fail closed. */
    }
  }

  bool get _hologramPrivacyAllowed =>
      !_disposed &&
      accountId != null &&
      screen == Screen.home &&
      !_restoringIdentity &&
      !_protectedSurfaceLocked &&
      !appearOffline &&
      !captureGateVisible &&
      !_captureBusy &&
      settingsWritable &&
      (!_isWindowsPlatform ||
          (_windowCaptureProtection !=
                  WindowCaptureProtectionStatus.unavailable &&
              (_windowCaptureProtection.isProtected ||
                  _captureConsent == WindowsCaptureConsent.showThisSession ||
                  !appSettings.windowsCaptureProtectionEnabled))) &&
      appSettings.showMessageInNotification &&
      !appSettings.friendPreferencesReviewRequired;

  bool _hologramEligible(String peer, String conversation) {
    final friend = _friends[peer];
    final nativeCurrent =
        _hologramNativePeer == (peer, conversation) &&
        _hologramClock.elapsedMilliseconds < _hologramNativeUntil;
    final hidden =
        _isWindowsPlatform &&
        nativeCurrent &&
        _hologramNativeSurface == 'hidden';
    return _hologramPrivacyAllowed &&
        friendHologramsAllowed(peer) &&
        friend?.confirmed == true &&
        friend?.conversationId == conversation &&
        (_isWindowsPlatform
            ? nativeCurrent &&
                  (hidden ||
                      (_foreground && _hologramNativeSurface == 'visible'))
            : _foreground) &&
        (hidden || _visibleConversationPeerId != peer);
  }

  Future<bool> _probeHologramSurface(String peer, String conversation) async {
    if (!_isWindowsPlatform) return true;
    if (_hologramProbes >= 4 || !_hologramPrivacyAllowed) return false;
    final generation = _hologramNativeGeneration;
    final account = accountId!;
    _hologramProbes++;
    try {
      final surface = await jami.hologramPresentationState(
        account,
        peer,
        conversation,
        generation,
      );
      if (_disposed ||
          generation != _hologramNativeGeneration ||
          account != accountId) {
        return false;
      }
      if (_holograms.active != null && surface != _hologramNativeSurface) {
        _holograms.cancelPresentation();
        _hologramNativeHeartbeat?.cancel();
        _playSound(SyblSoundEvent.stopHologram);
        _runInBackground(jami.cancelHologram(generation), 'cancel hologram');
        notifyListeners();
      }
      _hologramNativeSurface = surface;
      _hologramNativePeer = (peer, conversation);
      _hologramNativeUntil = _hologramClock.elapsedMilliseconds + 400;
      return surface == 'visible' || surface == 'hidden';
    } catch (_) {
      return false;
    } finally {
      _hologramProbes--;
    }
  }

  Future<void> _receiveHologramControl(
    String peer,
    HologramPacket packet,
  ) async {
    _refreshHologramPrivacy();
    if (packet.type != 'ready' && _holograms.active != null) return;
    final generation = _hologramNativeGeneration;
    if (packet.type == 'ready' ||
        !_isWindowsPlatform ||
        await _probeHologramSurface(peer, packet.conversation)) {
      if (!_disposed && generation == _hologramNativeGeneration) {
        _holograms.receive(peer, packet);
      }
    }
  }

  Future<void> _observeHologramCommit(
    ConversationScope scope,
    TimelineStickerItem item,
  ) async {
    _refreshHologramPrivacy();
    if (_holograms.active != null) return;
    final generation = _hologramNativeGeneration;
    if ((_isWindowsPlatform &&
            !await _probeHologramSurface(
              item.authorId,
              scope.conversationId,
            )) ||
        _disposed ||
        generation != _hologramNativeGeneration) {
      return;
    }
    _holograms.liveCommit(
      author: item.authorId,
      conversation: scope.conversationId,
      operation: item.operationId ?? '',
      commit: item.daemonId,
      asset: item.sticker!.assetId,
      hologram: true,
    );
  }

  Future<void> _presentNativeHologram(HologramPresentation value) async {
    final generation = _hologramNativeGeneration;
    final account = accountId;
    if (account == null || !_holograms.isCurrent(value)) return;
    _hologramNativeHeartbeat?.cancel();
    _hologramNativeHeartbeat = Timer.periodic(
      const Duration(milliseconds: 100),
      (timer) {
        if (!_holograms.isCurrent(value)) {
          timer.cancel();
          _runInBackground(jami.cancelHologram(generation), 'cancel hologram');
        } else {
          _runInBackground(
            _probeHologramSurface(value.peer, value.conversation),
            'hologram privacy',
          );
        }
      },
    );
    if (_hologramNativeSurface != 'hidden') return;
    var shown = false;
    try {
      shown = await jami.showHologram(
        account,
        value.peer,
        value.conversation,
        value.asset,
        generation,
        !appSettings.chatMotionEnabled,
      );
    } catch (_) {
      /* Unsupported/failed native privacy is quiet. */
    }
    if (!shown || !_holograms.isCurrent(value)) {
      _hologramNativeHeartbeat?.cancel();
      _runInBackground(jami.cancelHologram(generation), 'cancel hologram');
      if (identical(_holograms.active, value)) _holograms.cancelPresentation();
    }
  }

  HologramPresentation? get hologramPresentation {
    final value = _holograms.active;
    return value != null &&
            _holograms.isCurrent(value) &&
            (!_isWindowsPlatform || _hologramNativeSurface == 'visible')
        ? value
        : null;
  }

  /// Called by the visible decoration on its first fade-in frame, never by a
  /// history event or the durable commit itself.
  bool claimHologramSurface(HologramPresentation value, Object surface) {
    if (!identical(hologramPresentation, value) || _hologramSurface != null) {
      return false;
    }
    _hologramSurface = surface;
    return true;
  }

  void cancelHologramSurface(HologramPresentation value, Object surface) {
    if (_disposed ||
        !identical(_hologramSurface, surface) ||
        !identical(_holograms.active, value)) {
      return;
    }
    _holograms.cancelPresentation();
    _hologramSurface = null;
    _playSound(SyblSoundEvent.stopHologram);
    notifyListeners();
  }

  void hologramFadeStarted(HologramPresentation value) {
    if (identical(hologramPresentation, value) &&
        !identical(_soundedHologram, value)) {
      _soundedHologram = value;
      _playSound(SyblSoundEvent.hologram);
    }
  }

  void _refreshHologramPrivacy() {
    _devicePairing?.reconcile();
    final historical = _historyTimelineHit;
    if (historical != null &&
        (_historySearchOwner == null ||
            _historyTimelineAccount != (accountId, _accountRevision) ||
            !_acceptHistorySearchHit(historical))) {
      _retireHistoryTimeline();
    }
    if ((_historySearch?.hasSession == true ||
            _searchMessageSelection?.hasSession == true) &&
        _historySearchOwner == null) {
      retireHistorySearch();
    }
    final owner = (
      accountId,
      _accountRevision,
      screen,
      settingsWritable,
      _restoringIdentity,
      _protectedSurfaceLocked,
      appearOffline,
      captureGateVisible,
      _captureBusy,
      _windowCaptureProtection,
      _captureConsent,
      appSettings.windowsCaptureProtectionEnabled,
      appSettings.showMessageInNotification,
      appSettings.hologramPresentationEnabled,
      appSettings.friendPreferences,
      appSettings.friendPreferencesReviewRequired,
      _foreground,
      _visibleConversationPeerId,
      _friends.values
          .map((f) => '${f.peerId}:${f.confirmed}:${f.conversationId}')
          .join('|'),
    );
    if (_hologramPrivacyOwner != owner) {
      _hologramPrivacyOwner = owner;
      _hologramNativeGeneration++;
      _hologramNativeUntil = 0;
      _hologramNativeSurface = 'unavailable';
      _hologramNativeHeartbeat?.cancel();
      if (_isWindowsPlatform) {
        _runInBackground(
          jami.setHologramPrivacy(
            accountId ?? '',
            _hologramNativeGeneration,
            _hologramPrivacyAllowed,
          ),
          'hologram privacy',
        );
      }
      _holograms.invalidate();
      if (_soundedHologram != null) _playSound(SyblSoundEvent.stopHologram);
      _hologramTimer?.cancel();
      _soundedHologram = null;
      _hologramSurface = null;
    }
  }

  String? _accountId;
  ConversationSearch? _historySearch;
  SearchMessageSelection? _searchMessageSelection;
  int _searchPrivacyRevision = 0;

  HistorySearchOwner? get _historySearchOwner {
    final account = accountId;
    if (_disposed ||
        account == null ||
        account.isEmpty ||
        _restoringIdentity ||
        !_foreground ||
        _protectedSurfaceLocked ||
        captureGateVisible ||
        _captureBusy ||
        screen != Screen.home) {
      return null;
    }
    return (
      accountId: account,
      lifetime: (_accountRevision, _searchPrivacyRevision),
    );
  }

  HistorySearchOwner? get historySearchOwner => _historySearchOwner;
  List<ConversationScope> get historySearchScopes => List.unmodifiable(
    _historySearchScopes().take(HistorySearchWire.maximumScopes),
  );

  Iterable<ConversationScope> _historySearchScopes() sync* {
    final owner = _historySearchOwner;
    if (owner == null) return;
    for (final friend in _friends.values) {
      if (friend.confirmed && HistorySearchWire.commit(friend.conversationId)) {
        yield ConversationScope(
          accountId: owner.accountId,
          peerId: friend.peerId,
          conversationId: friend.conversationId,
        );
      }
    }
    for (final group in _groups.values) {
      if (group.activeMemberIds.contains(jamiId) &&
          HistorySearchWire.commit(group.conversationId)) {
        yield ConversationScope(
          accountId: owner.accountId,
          peerId: group.ownerKey,
          conversationId: group.conversationId,
          kind: ConversationKind.group,
        );
      }
    }
  }

  bool _acceptHistorySearchHit(HistorySearchHit hit) {
    if (!_historySearchScopes().contains(hit.scope)) return false;
    if (hit.scope.isGroup) {
      return _groups[hit.scope.conversationId]?.layout.rooms.any(
            (room) =>
                room.id == hit.channelId && room.kind == GroupRoomKind.text,
          ) ==
          true;
    }
    if (hit.authorId != jamiId && hit.authorId != hit.scope.peerId) {
      return false;
    }
    if (hit.channelId == DmTopicWire.mainId) return true;
    final topic = _dmTopicStates[hit.scope]?.topic(hit.channelId);
    return _loadedDmTopicScopes.contains(hit.scope) &&
        topic != null &&
        !topic.archivedBy.contains(jamiId);
  }

  ConversationSearch get historySearch => _historySearch ??= ConversationSearch(
    owner: () => _historySearchOwner,
    scopes: _historySearchScopes,
    accepts: _acceptHistorySearchHit,
    search: jami.searchHistory,
    retireWorker: (owner) {
      // Native retirement drops private input/results but keeps the scan slot
      // occupied until its terminal callback. Never log platform error details.
      unawaited(
        jami.retireHistorySearch(owner.accountId).catchError((Object _) {}),
      );
    },
  );

  SearchMessageSelection get searchMessageSelection =>
      _searchMessageSelection ??= SearchMessageSelection(
        owner: () => _historySearchOwner,
        accepts: _acceptHistorySearchHit,
        load: (hit) => jami.loadSearchMessage(
          hit,
          localAuthorId: jamiId,
          allowedRemoteAuthorIds: hit.scope.isGroup
              ? _groups[hit.scope.conversationId]?.activeMemberIds.toSet()
              : {hit.scope.peerId},
        ),
        retireWorker: (owner) {
          unawaited(
            jami.retireHistorySearch(owner.accountId).catchError((Object _) {}),
          );
        },
      );

  /// Navigation uses only a validated address, never a search snippet as a
  /// message. The result viewer owns the separate fresh folded snapshot.
  HistorySearchHit? _historyTimelineHit;
  (String?, int)? _historyTimelineAccount;
  ConversationTimelineController? _historyTimelineController;
  ConversationTimelineItem? _historyTimelineSnapshot;
  int _historyTimelineGeneration = 0;
  bool _historyTimelineWorkerActive = false;
  bool historyTimelineBusy = false;
  bool historyTimelineReadSuppressed = false;
  int historyTimelineLoadedItems = 0;
  bool historyTimelineUnavailable = false;

  /// Search navigation never claims that unseen newer messages were read.
  /// Suppression ends only with an explicit return to the ordinary latest view.
  String? get historyTimelineMessageId {
    final hit = _historyTimelineHit;
    final snapshot = _historyTimelineSnapshot;
    if (hit == null ||
        snapshot == null ||
        historyTimelineBusy ||
        _historySearchOwner == null ||
        !_acceptHistorySearchHit(hit) ||
        _historyTimelineAccount != (accountId, _accountRevision) ||
        selectedConversationScope != hit.scope) {
      return null;
    }
    final current = _conversationTimeline?.items
        .where((item) => item.daemonId == hit.messageId)
        .firstOrNull;
    return SearchMessageSnapshot.sameContent(snapshot, current)
        ? hit.messageId
        : null;
  }

  int get historyTimelineGeneration => _historyTimelineGeneration;

  void _retireHistoryTimeline({bool releaseReadSuppression = false}) {
    final controller = _historyTimelineController;
    final account = _historyTimelineHit?.scope.accountId;
    final busy = historyTimelineBusy;
    _historyTimelineGeneration++;
    _historyTimelineHit = null;
    _historyTimelineAccount = null;
    _historyTimelineController = null;
    _historyTimelineSnapshot = null;
    historyTimelineBusy = false;
    historyTimelineLoadedItems = 0;
    historyTimelineUnavailable = false;
    if (busy) {
      controller?.cancelPendingLoad();
      if (account != null) {
        _runInBackground(
          jami.retireHistorySearch(account),
          'retireHistoryNavigation',
        );
      }
    }
    if (releaseReadSuppression) historyTimelineReadSuppressed = false;
  }

  void returnToLatestHistory() {
    if (_historySearchOwner == null) return;
    _retireHistoryTimeline(releaseReadSuppression: true);
    final peer = selectedConversationScope?.peerId;
    if (peer != null) markConversationRead(peer);
    _markLatestIncomingDisplayed();
    notifyListeners();
  }

  Future<bool> openHistorySearchConversation(
    HistorySearchHit hit, {
    required ConversationAction action,
    VoidCallback? onConversationOpened,
  }) async {
    if (_historyTimelineWorkerActive ||
        _historySearchOwner == null ||
        !ownsConversationAction(action) ||
        !_acceptHistorySearchHit(hit)) {
      return false;
    }
    _retireHistoryTimeline();
    _historyTimelineHit = hit;
    _historyTimelineAccount = (accountId, _accountRevision);
    final generation = _historyTimelineGeneration;
    historyTimelineReadSuppressed = true;
    historyTimelineBusy = true;
    _historyTimelineWorkerActive = true;
    bool current() =>
        !_disposed &&
        generation == _historyTimelineGeneration &&
        _historyTimelineAccount == (accountId, _accountRevision) &&
        _historySearchOwner != null &&
        ownsConversationAction(action) &&
        _acceptHistorySearchHit(hit);
    Future<SearchMessageSnapshot> snapshot() => jami.loadSearchMessage(
      hit,
      localAuthorId: jamiId,
      allowedRemoteAuthorIds: hit.scope.isGroup
          ? _groups[hit.scope.conversationId]?.activeMemberIds
          : {hit.scope.peerId},
    );
    notifyListeners();
    try {
      // Re-read after the detail dialog closed; its old snapshot is not authority.
      if ((await snapshot()).item == null || !current()) return false;
      if (hit.scope.isGroup) {
        await selectGroup(
          hit.scope.conversationId,
          action: action,
          fromHistorySearch: true,
        );
        if (!current()) return false;
        if (!await selectGroupTopic(
              hit.scope.conversationId,
              hit.channelId,
              action: action,
              fromHistorySearch: true,
            ) ||
            !current()) {
          return false;
        }
      } else {
        await selectFriend(
          hit.scope.peerId,
          action: action,
          fromHistorySearch: true,
        );
        if (!current()) return false;
        if (selectedDmTopicState?.topic(hit.channelId) != null) {
          if (!await selectDmTopic(
                hit.channelId,
                action: action,
                fromHistorySearch: true,
              ) ||
              !current()) {
            return false;
          }
        } else if (hit.channelId != DmTopicWire.mainId) {
          return false;
        }
      }
      if (!current() || selectedConversationScope != hit.scope) return false;
      onConversationOpened?.call();
      if (!current()) return false;
      final timeline = _conversationTimeline;
      if (timeline == null || timeline.scope != hit.scope) return false;
      _historyTimelineController = timeline;
      if (!await timeline.loadThrough(
            hit.messageId,
            isCurrent: current,
            onProgress: (count) {
              if (!current()) return;
              historyTimelineLoadedItems = count;
              notifyListeners();
            },
          ) ||
          !current()) {
        return false;
      }
      // Revalidate deletion, content version and membership after pagination.
      final fresh = (await snapshot()).item;
      if (!current() || fresh == null) return false;
      final item = timeline.items
          .where((item) => item.daemonId == hit.messageId)
          .firstOrNull;
      if (!SearchMessageSnapshot.sameContent(fresh, item)) return false;
      _historyTimelineSnapshot = fresh;
      return true;
    } on Object {
      return false;
    } finally {
      _historyTimelineWorkerActive = false;
      if (!_disposed && generation == _historyTimelineGeneration) {
        historyTimelineBusy = false;
        historyTimelineUnavailable = _historyTimelineSnapshot == null;
        notifyListeners();
      }
    }
  }

  void retireHistorySearch() {
    final search = _historySearch;
    final selection = _searchMessageSelection;
    if (search?.hasSession != true && selection?.hasSession != true) return;
    _searchPrivacyRevision++;
    search?.retire();
    selection?.retire();
  }

  String? get accountId => _accountId;
  set accountId(String? value) {
    if (_accountId != value) {
      _retireWidgetChatSession();
      _retireHistoryTimeline();
      retireHistorySearch();
      _conversationSelectionRevision++;
      _accountRevision++;
      _friendRemovalOperations.clear();
      _liveMessageEffects.clear();
      _retireDmTopicRuntime();
    }
    _accountId = value;
    _refreshHologramPrivacy();
    _syncRemoteControl();
  }

  String jamiId = '';
  String displayName = '';
  String profileAvatarBase64 = '';
  bool changingDisplayName = false;
  bool changingProfileAvatar = false;
  bool get _profileMutationBusy => changingDisplayName || changingProfileAvatar;
  bool get _canEditProfile =>
      !_disposed &&
      _startupPrepared &&
      accountId != null &&
      !_restoringIdentity &&
      !_adoptingAccount &&
      !_profileMutationBusy;
  bool get _identityMutationBusy =>
      settingsBusy ||
      _profileMutationBusy ||
      _changingAppearOffline ||
      _changingConnectionProfile;

  bool _updateRestartPending = false;
  bool _widgetUpdateBusy = false;
  bool get widgetUpdateBusy => _widgetUpdateBusy;

  /// Updated only by the authenticated desktop overlay bridge; grants no authority.
  void setWidgetUpdateBusy(bool busy) {
    if (_widgetUpdateBusy == busy || _disposed) return;
    _widgetUpdateBusy = busy;
    notifyListeners();
  }

  bool get updateRestartPending => _updateRestartPending;
  bool get canRestartForUpdate => !_updateRestartPending && _updateRestartIdle;
  bool get updateRestartStillSafe =>
      _updateRestartPending && _updateRestartIdle;

  bool reserveUpdateRestart() {
    if (!canRestartForUpdate) return false;
    _updateRestartPending = true;
    notifyListeners();
    return true;
  }

  void cancelUpdateRestart() {
    if (!_updateRestartPending) return;
    _updateRestartPending = false;
    notifyListeners();
  }

  bool get _updateRestartIdle =>
      !_disposed &&
      screen == Screen.home &&
      !captureGateVisible &&
      !_restoringIdentity &&
      !_identityMutationBusy &&
      !backingUp &&
      !resettingDoorlight &&
      !devicePairingPending &&
      !overlaySettings.busy &&
      !_widgetUpdateBusy &&
      !_widgetSendBusy &&
      !_widgetChatConsentPending &&
      !_widgetSendResults.values.any(
        (result) => const {
          ComposerSendStatus.pending,
          ComposerSendStatus.unknown,
        }.contains(result.status),
      ) &&
      !_captureBusy &&
      _initializationInFlight == null &&
      _bootInFlight == null &&
      call == null &&
      groupCall == null &&
      _groupJoinOperation == null &&
      !placing &&
      _pendingIncomingCalls.isEmpty &&
      _unresolvedOutgoingCallIds.isEmpty &&
      !sendingFile &&
      !transfers.values.any((transfer) => !transfer.done) &&
      !composerDrafts.hasUnfinishedDrafts;
  String registration = 'UNREGISTERED';
  bool get registered => registration == 'REGISTERED';
  WindowCaptureProtectionStatus _windowCaptureProtection =
      WindowCaptureProtectionStatus.unavailable;
  WindowCaptureProtectionStatus get windowCaptureProtection =>
      _windowCaptureProtection;

  // ---- Windows capture-consent gate ----
  // Three independent truths must never be collapsed:
  //   1. persisted desired preference  -> appSettings.windowsCaptureProtectionEnabled
  //   2. per-session decision          -> _captureConsent (never persisted)
  //   3. actual native applied state   -> _windowCaptureProtection (only this
  //      may drive applied-status copy)
  //
  // Native reports best-effort activity from supported capture-product logs.
  // It does not identify the captured source or cover every capture tool.
  // The detector may only decide when to ask.
  // Applied window affinity remains the privacy boundary and the prompt itself
  // stays data-free.
  WindowsCaptureConsent _captureConsent = WindowsCaptureConsent.pending;
  WindowsCaptureConsent get captureConsent => _captureConsent;
  bool _captureGateResolved = false;
  bool _capturePreferenceKnown = false;
  bool _captureBusy = false;
  String? _captureGateError;
  String? _captureSettingsNote;
  bool _captureActivityActive = false;
  bool _capturePromptedForActiveActivity = false;
  bool get captureActivityActive =>
      _isWindowsPlatform && _captureActivityActive;
  int _capturePromptGeneration = 0;
  int get capturePromptGeneration => _capturePromptGeneration;

  bool get _isWindowsPlatform =>
      defaultTargetPlatform == TargetPlatform.windows;
  bool get _isAndroidPlatform =>
      defaultTargetPlatform == TargetPlatform.android;

  /// True while the outermost neutral consent surface must replace all real
  /// application content. Only Windows ever gates.
  bool get captureGateVisible => _isWindowsPlatform && !_captureGateResolved;

  /// True once the persisted preference has resolved and the gate may offer
  /// its explicit session/durable choices.
  bool get captureGateReady => _capturePreferenceKnown;

  /// True while a native apply or preference persistence is in flight.
  /// Transitions are single-flight: every capture action refuses to start
  /// while one is running, so a late completion can only belong to the one
  /// transaction that owns the latch.
  bool get captureBusy => _captureBusy;
  String? get captureGateError => _captureGateError;

  /// Settings-row failure note (apply or save); cleared on the next
  /// transition. Never a claim about the applied state — that is
  /// [windowCaptureProtection] alone.
  String? get captureSettingsNote => _captureSettingsNote;
  bool get windowsCaptureProtectionEnabled =>
      appSettings.windowsCaptureProtectionEnabled;
  bool get androidCaptureProtectionEnabled =>
      _isAndroidPlatform && _windowCaptureProtection.isProtected;

  /// Android scopes capture protection to sensitive surfaces only once native
  /// confirms it is armed. Native launches with the whole window secure, so an
  /// unknown status never relaxes anything: Dart simply never lifts it.
  late final SensitiveSurfaceProtection surfaceProtection =
      SensitiveSurfaceProtection(
        apply: (visible) => jami.setAndroidSensitiveSurface(visible: visible),
        armed: () => androidCaptureProtectionEnabled,
        // Three frames: the last sensitive frame is replaced and rasterized
        // before the window may become capturable.
        settle: () async {
          for (var frame = 0; frame < 3; frame++) {
            await WidgetsBinding.instance.endOfFrame;
          }
        },
      );

  Future<void> setAndroidCaptureProtectionEnabled(bool enabled) async {
    if (!_isAndroidPlatform || _captureBusy) return;
    if (enabled == androidCaptureProtectionEnabled) return;
    _captureBusy = true;
    _captureSettingsNote = null;
    notifyListeners();
    try {
      final status = await jami.applyAndroidCaptureProtection(protect: enabled);
      _windowCaptureProtection = status;
      if ((enabled && !status.isProtected) ||
          (!enabled && status != WindowCaptureProtectionStatus.none)) {
        _captureSettingsNote = 'The privacy setting could not be applied.';
      }
    } catch (error) {
      dlog('Android capture protection change failed: $error');
      _captureSettingsNote = 'The privacy setting could not be changed.';
    } finally {
      _captureBusy = false;
      surfaceProtection.refresh();
      notifyListeners();
    }
  }

  /// Boot resolution. The native window starts at WDA_NONE while the outermost
  /// data-free surface renders. A protected preference must establish native
  /// affinity before the real application surface can replace it. The prompt
  /// opens later, only after a best-effort capture-start event.
  Future<void> _resolveCaptureConsentAtBoot() async {
    if (!_isWindowsPlatform) {
      _setCaptureGateResolved(true);
      _capturePreferenceKnown = true;
      return;
    }
    if (!appSettings.windowsCaptureProtectionEnabled) {
      _captureBusy = true;
      notifyListeners();
      try {
        _windowCaptureProtection = await jami.applyWindowsCaptureProtection(
          protect: false,
        );
      } catch (error) {
        dlog('capture apply(none, boot) failed: $error');
      } finally {
        _captureBusy = false;
      }
      _setCaptureGateResolved(true);
      _capturePreferenceKnown = true;
      notifyListeners();
      return;
    }
    _captureBusy = true;
    notifyListeners();
    try {
      _windowCaptureProtection = await jami.applyWindowsCaptureProtection(
        protect: true,
      );
      if (_windowCaptureProtection.isProtected) {
        _captureConsent = WindowsCaptureConsent.protect;
        _setCaptureGateResolved(true);
      } else {
        _captureGateError =
            'Screen-capture protection could not be applied on this device.';
      }
    } catch (error) {
      dlog('capture apply(protect, boot) failed: $error');
      _captureGateError =
          'Screen-capture protection could not be applied on this device.';
    } finally {
      _captureBusy = false;
      _capturePreferenceKnown = true;
    }
    _maybeOpenCaptureGateForActivity();
    notifyListeners();
  }

  /// Appear in capture for this process session only. The persisted preference
  /// stays enabled, so the next launch restores protection.
  Future<void> captureConsentShowThisSession() async {
    if (!captureGateVisible || _captureBusy || !_capturePreferenceKnown) {
      return;
    }
    _captureBusy = true;
    _captureGateError = null;
    notifyListeners();
    try {
      final status = await jami.applyWindowsCaptureProtection(protect: false);
      _windowCaptureProtection = status;
      if (status == WindowCaptureProtectionStatus.none) {
        _captureConsent = WindowsCaptureConsent.showThisSession;
        _setCaptureGateResolved(true);
      } else {
        _captureGateError = 'The window state could not be confirmed.';
      }
    } catch (error) {
      dlog('capture apply(show) failed: $error');
      _captureGateError = 'The window state could not be changed.';
    } finally {
      _captureBusy = false;
      notifyListeners();
    }
  }

  /// Appear in capture and persist that durable choice. Native must first
  /// confirm WDA_NONE. A save failure still honors the explicit session
  /// reveal but leaves the preference enabled for the next launch.
  Future<void> captureConsentShowAlways() async {
    if (!captureGateVisible ||
        _captureBusy ||
        settingsBusy ||
        !_capturePreferenceKnown) {
      return;
    }
    _captureBusy = true;
    _captureGateError = null;
    notifyListeners();
    try {
      final status = await jami.applyWindowsCaptureProtection(protect: false);
      _windowCaptureProtection = status;
      if (status != WindowCaptureProtectionStatus.none) {
        _captureGateError = 'The window state could not be confirmed.';
        return;
      }
      _captureConsent = WindowsCaptureConsent.showThisSession;
      _setCaptureGateResolved(true);
      final saved = await _saveAppSettings(
        appSettings.withWindowsCaptureProtectionEnabled(false),
        captureOwner: true,
      );
      if (!saved) {
        _captureSettingsNote =
            'The always-show choice could not be saved. Doorlight stays visible '
            'for this session. Protection returns at the next launch.';
      }
    } catch (error) {
      dlog('capture apply(show always) failed: $error');
      _captureGateError = 'The window state could not be changed.';
    } finally {
      _captureBusy = false;
      notifyListeners();
    }
  }

  /// Keep the app hidden from capture. This fails closed: real content is not
  /// rendered until native reports exclusion or the documented monitor
  /// fallback.
  Future<void> captureConsentHide() async {
    if (!captureGateVisible || _captureBusy || !_capturePreferenceKnown) {
      return;
    }
    _captureBusy = true;
    _captureGateError = null;
    notifyListeners();
    try {
      final status = await jami.applyWindowsCaptureProtection(protect: true);
      _windowCaptureProtection = status;
      if (status.isProtected) {
        _captureConsent = WindowsCaptureConsent.protect;
        _setCaptureGateResolved(true);
      } else {
        _captureGateError =
            'Screen-capture protection could not be applied on this device.';
      }
    } catch (error) {
      dlog('capture apply(hide) failed: $error');
      _captureGateError =
          'Screen-capture protection could not be applied on this device.';
    } finally {
      _captureBusy = false;
      notifyListeners();
    }
  }

  /// Settings transition. Enable persists TRUE, covers private content, and
  /// applies protection. The choices stay open only on failure or OBS activity.
  /// Disable (the UI confirms the exposure first) establishes WDA_NONE, then
  /// persists FALSE; a save failure leaves this session visible — the user
  /// explicitly confirmed it — but desired stays TRUE, so the next process
  /// launch restores protection.
  Future<void> setWindowsCaptureProtectionEnabled(bool enabled) async {
    // settingsBusy matters as much as _captureBusy: the disable path applies
    // WDA_NONE and only then persists, so starting it while another settings
    // write holds the single-write latch would expose the window and lose the
    // preference change.
    if (!_isWindowsPlatform || _captureBusy || settingsBusy) return;
    if (enabled == appSettings.windowsCaptureProtectionEnabled) return;
    _captureBusy = true;
    _captureSettingsNote = null;
    notifyListeners();
    try {
      if (enabled) {
        final saved = await _saveAppSettings(
          appSettings.withWindowsCaptureProtectionEnabled(true),
          captureOwner: true,
        );
        if (!saved) {
          _captureSettingsNote =
              'The preference could not be saved. Nothing changed.';
          return;
        }
        _openWindowsCaptureConsentGate();
        notifyListeners();
        WindowCaptureProtectionStatus status;
        try {
          status = await jami.applyWindowsCaptureProtection(protect: true);
        } catch (error) {
          dlog('capture apply(enable) failed: $error');
          _openWindowsCaptureConsentGate();
          _captureGateError =
              'Screen-capture protection could not be applied on this device.';
          return;
        }
        _windowCaptureProtection = status;
        if (!status.isProtected) {
          _openWindowsCaptureConsentGate();
          _captureGateError =
              'Screen-capture protection could not be applied on this device.';
          return;
        }
        _captureConsent = WindowsCaptureConsent.protect;
        _setCaptureGateResolved(true);
      } else {
        WindowCaptureProtectionStatus status;
        try {
          status = await jami.applyWindowsCaptureProtection(protect: false);
        } catch (error) {
          dlog('capture apply(disable) failed: $error');
          _captureSettingsNote =
              'The window state could not be changed. Nothing changed.';
          return;
        }
        _windowCaptureProtection = status;
        if (status != WindowCaptureProtectionStatus.none) {
          // The requested transition did not happen. Persisting FALSE here
          // would skip the consent gate on every future launch on the
          // strength of a change that was never established.
          _captureSettingsNote =
              'The window state could not be changed. Nothing changed.';
          return;
        }
        final saved = await _saveAppSettings(
          appSettings.withWindowsCaptureProtectionEnabled(false),
          captureOwner: true,
        );
        if (!saved) {
          _captureSettingsNote =
              'The choice could not be saved. Doorlight stays visible for this '
              'session. Protection returns at the next launch.';
        }
      }
    } finally {
      _captureBusy = false;
      _maybeOpenCaptureGateForActivity();
      notifyListeners();
    }
  }

  /// Restore capture protection after a session-only Show. This does not open
  /// the detected-capture prompt because OBS may no longer be active.
  Future<void> restoreWindowsCaptureProtection() async {
    if (!_isWindowsPlatform || _captureBusy || settingsBusy) return;
    if (!appSettings.windowsCaptureProtectionEnabled ||
        _windowCaptureProtection.isProtected) {
      return;
    }
    _captureBusy = true;
    _captureSettingsNote = null;
    _openWindowsCaptureConsentGate();
    notifyListeners();
    try {
      final status = await jami.applyWindowsCaptureProtection(protect: true);
      _windowCaptureProtection = status;
      if (status.isProtected) {
        _captureConsent = WindowsCaptureConsent.protect;
        _setCaptureGateResolved(true);
        _capturePromptedForActiveActivity = _captureActivityActive;
      } else {
        _captureGateError =
            'Screen-capture protection could not be applied on this device.';
      }
    } catch (error) {
      dlog('capture apply(restore) failed: $error');
      _captureGateError =
          'Screen-capture protection could not be applied on this device.';
    } finally {
      _captureBusy = false;
      _maybeOpenCaptureGateForActivity();
      notifyListeners();
    }
  }

  void _openWindowsCaptureConsentGate() {
    _capturePromptGeneration++;
    _captureConsent = WindowsCaptureConsent.pending;
    _setCaptureGateResolved(false);
    _captureGateError = null;
  }

  void _setCaptureGateResolved(bool resolved) {
    if (_captureGateResolved == resolved) return;
    _captureGateResolved = resolved;
    if (captureGateVisible) {
      setConversationVisible(null);
      _clearRemoteComposerActivities();
    }
    // The prompt removes the call controls. Retire Dart input and request
    // native host teardown before the widget tree can hide those controls.
    _syncRemoteControl();
  }

  void _handleWindowsCaptureActivity(bool active) {
    if (!_isWindowsPlatform || _captureActivityActive == active) return;
    _captureActivityActive = active;
    if (!active) {
      _capturePromptedForActiveActivity = false;
      if (captureGateVisible &&
          !_captureBusy &&
          _captureGateError == null &&
          _captureConsent == WindowsCaptureConsent.pending) {
        if (_windowCaptureProtection.isProtected) {
          _captureConsent = WindowsCaptureConsent.protect;
          _setCaptureGateResolved(true);
        } else {
          unawaited(captureConsentHide());
        }
      }
      return;
    }
    _maybeOpenCaptureGateForActivity();
  }

  void _maybeOpenCaptureGateForActivity() {
    if (!_captureActivityActive ||
        _capturePromptedForActiveActivity ||
        !_capturePreferenceKnown ||
        _captureBusy ||
        !appSettings.windowsCaptureProtectionEnabled ||
        !_windowCaptureProtection.isProtected ||
        !_captureGateResolved ||
        _captureConsent == WindowsCaptureConsent.showThisSession) {
      return;
    }
    _capturePromptedForActiveActivity = true;
    _openWindowsCaptureConsentGate();
  }

  /// Called by the data-free gate after its frame has been submitted. The native
  /// presentation barrier keeps old private pixels excluded until fresh frames
  /// reach the compositor. Closing this gate still requires protection or consent.
  Future<bool> presentWindowsCapturePrompt(int generation) async {
    if (!_isWindowsPlatform ||
        !captureGateVisible ||
        !_capturePreferenceKnown ||
        generation != _capturePromptGeneration ||
        !_captureActivityActive ||
        _captureBusy ||
        _windowCaptureProtection == WindowCaptureProtectionStatus.none) {
      return false;
    }
    _captureBusy = true;
    notifyListeners();
    try {
      _windowCaptureProtection = await jami.presentWindowsCapturePrompt();
      if (!_windowCaptureProtection.isProtected &&
          _windowCaptureProtection != WindowCaptureProtectionStatus.none) {
        _captureGateError = 'The capture prompt could not be displayed safely.';
      }
    } catch (error) {
      dlog('capture prompt presentation unavailable: $error');
    } finally {
      _captureBusy = false;
      if (!_disposed) {
        if (!_captureActivityActive && captureGateVisible) {
          await captureConsentHide();
        }
        notifyListeners();
      }
    }
    return true;
  }

  /// Test seam for the gate/settings surfaces; production resolution runs
  /// only through [_resolveCaptureConsentAtBoot] and explicit actions.
  /// [settingsDocumentWritable] exists because the capture switch is gated on
  /// settings writability, which init() normally resolves.
  @visibleForTesting
  void seedCaptureStateForTesting({
    WindowsCaptureConsent consent = WindowsCaptureConsent.pending,
    bool preferenceKnown = true,
    bool resolved = false,
    bool busy = false,
    String? gateError,
    WindowCaptureProtectionStatus? applied,
    bool? settingsDocumentWritable,
    bool activityActive = false,
  }) {
    _captureConsent = consent;
    _capturePreferenceKnown = preferenceKnown;
    _captureGateResolved = resolved;
    _captureBusy = busy;
    _captureGateError = gateError;
    _captureActivityActive = activityActive;
    if (applied != null) _windowCaptureProtection = applied;
    if (settingsDocumentWritable != null) {
      _settingsDocumentWritable = settingsDocumentWritable;
    }
    notifyListeners();
  }

  bool ready =
      false; // account is announced on the DHT (deviceAnnounced) — safe to place the first call
  bool placing =
      false; // an outgoing call is being placed (incl. the brief cold-start warmup wait)

  String? _peerId;
  String? get peerId => _peerId;
  set peerId(String? value) {
    if (_peerId != value) _conversationSelectionRevision++;
    _peerId = value;
  }

  final Map<String, FriendState> _friends = {};
  late final Map<String, FriendState> _friendsView = UnmodifiableMapView(
    _friends,
  );

  /// A live, read-only view of the libjami-backed relationship snapshot.
  ///
  /// [FriendState] is immutable; relationship membership and replacement are
  /// owned exclusively by this state boundary.
  Map<String, FriendState> get friends => _friendsView;

  Map<IdentityColor, List<FriendState>> get friendsByIdentityColor {
    final result = <IdentityColor, List<FriendState>>{};
    for (final friend in _friends.values.where((friend) => friend.confirmed)) {
      final color = friend.identityColor;
      if (color != null) (result[color] ??= []).add(friend);
    }
    for (final list in result.values) {
      list.sort((a, b) => a.displayName.compareTo(b.displayName));
    }
    return result;
  }

  String? _selectedGroupId;
  String? get selectedGroupId => _selectedGroupId;
  set selectedGroupId(String? value) {
    if (_selectedGroupId != value) _conversationSelectionRevision++;
    _selectedGroupId = value;
  }

  /// An action opened in an earlier visit cannot own a later visit to this chat.
  Object get conversationActionOwner => (
    accountId,
    _accountRevision,
    selectedConversationScope,
    selectedDmTopicId,
    _conversationSelectionRevision,
  );

  ConversationAction captureConversationAction({bool Function()? isCurrent}) =>
      ConversationAction._(conversationActionOwner, isCurrent);

  bool ownsConversationAction(ConversationAction action) =>
      !_disposed &&
      action._owner == conversationActionOwner &&
      (action._isCurrent?.call() ?? true);

  Future<void> _selectionPersistence = Future<void>.value();

  Future<bool> _persistConversationSelection(Object owner) {
    final group = selectedGroupId;
    final peer = group == null ? peerId : null;
    bool ownsSelection() => !_disposed && owner == conversationActionOwner;
    final writes = <Future<bool> Function()>[
      () => group == null
          ? prefs.remove('selectedGroupId')
          : prefs.setString('selectedGroupId', group),
      () => peer == null
          ? prefs.remove('selectedFriendId')
          : prefs.setString('selectedFriendId', peer),
      // Keep the legacy account-adoption hint when no direct chat is selected.
      if (peer != null) () => prefs.setString('peerId', peer),
    ];
    // A platform write already in flight cannot be cancelled. Serialize its
    // successor so an old write cannot finish after the latest owner's save.
    final result = _selectionPersistence.then((_) async {
      for (final write in writes) {
        if (!ownsSelection()) return false;
        if (!await write()) {
          throw StateError('Could not save conversation selection.');
        }
      }
      return ownsSelection();
    });
    // The caller still receives its error; later selection jobs can retry.
    _selectionPersistence = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  final Map<String, GroupState> _groups = {};
  late final Map<String, GroupState> _groupsView = UnmodifiableMapView(_groups);
  Map<String, GroupState> get groups => _groupsView;
  GroupState? get selectedGroup =>
      selectedGroupId == null ? null : _groups[selectedGroupId];

  final Map<String, FriendActivity> _friendActivity = {};
  final Set<(ConversationScope, String)> _seenConversationActivity = {};
  final Map<ConversationScope, ComposerActivityKind> _remoteComposerActivities =
      {};
  @visibleForTesting
  Duration composerActivityRepeat = _composerActivityRepeat;
  ComposerActivityKind _localComposerActivity = ComposerActivityKind.idle;
  ConversationScope? _localComposerActivityScope;
  DateTime? _lastComposerActivitySentAt;
  String? _visibleConversationPeerId;
  String? _visibleGroupTopicId;
  String? _visibleDmTopicId;
  final Map<ConversationScope, DmTopicState> _dmTopicStates = {};
  final Map<ConversationScope, String> _selectedDmTopicIds = {};
  final Map<ConversationScope, String> _persistedDmTopicSelections = {};
  final Map<String, String> _selectedGroupTopicIds = {};
  final Map<ConversationScope, int> _dmTopicNextPositions = {};
  final Map<ConversationScope, LinkedHashMap<String, Map<String, Object?>>>
  _dmTopicLiveRecords = {};
  final Map<ConversationScope, int> _dmTopicLiveBytes = {};
  final Set<ConversationScope> _dmTopicLiveOverflow = {};
  final Map<ConversationScope, _DmTopicStateScan> _dmTopicScans = {};
  final Map<ConversationScope, DmTopicHistoryStatus> _dmTopicHistoryFailures =
      {};
  final Map<ConversationScope, Timer> _dmTopicRetryCooldowns = {};
  final Map<ConversationScope, Timer> _dmTopicOverflowRecovery = {};
  final Queue<ConversationScope> _dmTopicScanQueue = Queue();
  ConversationScope? _activeDmTopicScanScope;
  final Set<ConversationScope> _loadedDmTopicScopes = {};
  Timer? _dmTopicRescanCooldown;
  bool _dmTopicRescanRequested = false;
  final Map<int, _DmTopicStateScan> _dmTopicLoads = {};
  final Map<int, JamiEvent> _earlyDmTopicPages = {};

  /// The in-flight DM-topic mutation per conversation; completes when done.
  final Map<ConversationScope, Completer<void>> _dmTopicMutations = {};
  late final PendingInviteStore inviteContinuation;
  ConversationLaunchTarget? _pendingConversationLaunch;

  SyblInviteLink? get pendingInvite => inviteContinuation.pending?.invite;

  bool get canPresentInvite =>
      !_disposed &&
      !_restoringIdentity &&
      !_protectedSurfaceLocked &&
      !captureGateVisible &&
      screen == Screen.home;

  void _onInviteContinuationChanged() {
    if (!_disposed) notifyListeners();
  }

  void _stageInvite(Object? value) {
    inviteContinuation.stage(value);
  }

  FriendActivity friendActivity(String peerId) {
    final activity = _friendActivity[peerId] ?? const FriendActivity();
    final scope = _scopeForPeer(peerId);
    final state = scope == null ? null : _dmTopicStates[scope];
    if (state == null ||
        !_loadedDmTopicScopes.contains(scope) ||
        state.customTopics.isEmpty) {
      return activity;
    }
    final unread = state.unreadByTopic(localMemberId: jamiId);
    final total = unread.entries.fold(0, (sum, entry) {
      final topic = state.topic(entry.key);
      return topic?.archivedBy.contains(jamiId) ?? false
          ? sum
          : sum + entry.value;
    });
    return FriendActivity(
      lastActivityAt: activity.lastActivityAt,
      unreadMessages: total,
    );
  }

  // Live observations are a lower bound, not an exact count over partial history.
  bool groupHasUnread(String conversationId) {
    final owner = _groups[conversationId]?.ownerKey;
    return owner != null && (_friendActivity[owner]?.unreadTotal ?? 0) > 0;
  }

  int unreadOutsideConversation(String peerId) => _friends.keys
      .where((id) => id != peerId)
      .fold(0, (total, id) => total + friendActivity(id).unreadTotal);

  String? get visibleConversationPeerId => _visibleConversationPeerId;
  String? get visibleGroupTopicId => _visibleGroupTopicId;
  String? get visibleDmTopicId => _visibleDmTopicId;

  DmTopicHistoryStatus? get selectedDmTopicHistoryStatus {
    final scope = selectedConversationScope;
    if (scope == null || scope.isGroup) return null;
    return _dmTopicHistoryFailures[scope] ??
        (_dmTopicScans.containsKey(scope)
            ? DmTopicHistoryStatus.loading
            : _loadedDmTopicScopes.contains(scope)
            ? DmTopicHistoryStatus.ready
            : DmTopicHistoryStatus.loading);
  }

  bool get canRetryDmTopicHistory {
    final scope = selectedConversationScope;
    return scope != null &&
        _dmTopicHistoryFailures.containsKey(scope) &&
        !(_dmTopicRetryCooldowns[scope]?.isActive ?? false) &&
        !_dmTopicScans.containsKey(scope);
  }

  bool retryDmTopicHistory({
    required ConversationScope scope,
    required Object owner,
  }) {
    if (_disposed ||
        selectedConversationScope != scope ||
        conversationActionOwner != owner ||
        !canRetryDmTopicHistory) {
      return false;
    }
    _startDmTopicScan(scope);
    notifyListeners();
    return true;
  }

  DmTopicState? get selectedDmTopicState {
    final scope = selectedConversationScope;
    return scope == null ||
            scope.isGroup ||
            !_loadedDmTopicScopes.contains(scope)
        ? null
        : _dmTopicStates[scope];
  }

  String get selectedDmTopicId {
    final scope = selectedConversationScope;
    if (scope == null || scope.isGroup) return DmTopicWire.mainId;
    final state = _loadedDmTopicScopes.contains(scope)
        ? _dmTopicStates[scope]
        : null;
    final selected = _selectedDmTopicIds[scope] ?? DmTopicWire.mainId;
    return state?.topic(selected) == null ? DmTopicWire.mainId : selected;
  }

  bool get dmTopicRowVisible =>
      selectedDmTopicState?.customTopics.isNotEmpty ?? false;

  Map<String, int> get selectedDmTopicUnreadByTopic =>
      selectedDmTopicState?.unreadByTopic(localMemberId: jamiId) ?? const {};

  String selectedGroupTopicId(GroupState group) {
    final saved = _selectedGroupTopicIds[group.conversationId];
    final room = saved == null ? null : group.layout.room(saved);
    return room?.kind == GroupRoomKind.text
        ? room!.id
        : group.layout.initialTextRoom.id;
  }

  Future<bool> selectGroupTopic(
    String conversationId,
    String topicId, {
    ConversationAction? action,
    bool fromHistorySearch = false,
  }) async {
    if (action != null && !ownsConversationAction(action)) return false;
    if (!fromHistorySearch) {
      _retireHistoryTimeline(releaseReadSuppression: true);
    }
    final group = _groups[conversationId];
    final room = group?.layout.room(topicId);
    if (group == null || room?.kind != GroupRoomKind.text) return false;
    if (selectedGroupTopicId(group) != topicId) {
      _conversationSelectionRevision++;
    }
    _selectedGroupTopicIds[conversationId] = topicId;
    action?._owner = conversationActionOwner;
    await _saveGroupTopicSelections();
    notifyListeners();
    return true;
  }

  ComposerQueryResult resolveComposerQuery(
    String input, {
    String? groupTopicId,
  }) {
    final group = selectedGroup;
    final friend = selectedFriend;
    final ownerKey = group?.ownerKey ?? friend?.peerId ?? '';
    final conversationId =
        group?.conversationId ?? friend?.conversationId ?? '';
    final activeTopicId = group == null
        ? selectedDmTopicId
        : groupTopicId ?? selectedGroupTopicId(group);
    return ComposerQuery.resolve(
      input,
      ComposerQueryContext(
        currentOwnerKey: ownerKey,
        currentConversationId: conversationId,
        activeTopicId: activeTopicId,
        canCreateTopic: friend != null,
        canRenameTopic: friend != null && activeTopicId != DmTopicWire.mainId,
      ),
      composerChatCatalog,
    );
  }

  List<ComposerChatTarget> get composerChatCatalog => List.unmodifiable([
    for (final friend in _friends.values)
      if (friend.confirmed && friend.conversationId.isNotEmpty)
        _composerFriendTarget(friend),
    for (final group in _groups.values) _composerGroupTarget(group),
  ]);

  ComposerChatTarget _composerFriendTarget(FriendState friend) {
    final scope = _scopeForPeer(friend.peerId);
    final state = scope != null && _loadedDmTopicScopes.contains(scope)
        ? _dmTopicStates[scope]
        : null;
    final selected = scope == null
        ? DmTopicWire.mainId
        : _selectedDmTopicIds[scope] ?? DmTopicWire.mainId;
    return ComposerChatTarget(
      ownerKey: friend.peerId,
      conversationId: friend.conversationId,
      displayName: friend.displayName.trim().isEmpty
          ? peerDisplayName(friend.peerId)
          : friend.displayName.trim(),
      avatarBase64: friend.avatarBase64,
      defaultTopicId: DmTopicWire.mainId,
      lastTopicId: state?.topic(selected) == null
          ? DmTopicWire.mainId
          : selected,
      topics: [
        const ComposerTopicTarget(
          id: DmTopicWire.mainId,
          name: DmTopicWire.mainId,
          isDefault: true,
        ),
        for (final topic
            in state?.visibleTopics(localMemberId: jamiId) ?? const <DmTopic>[])
          if (topic.id != DmTopicWire.mainId)
            ComposerTopicTarget(id: topic.id, name: topic.name),
      ],
    );
  }

  ComposerChatTarget _composerGroupTarget(GroupState group) {
    final rooms = group.layout.rooms
        .where((room) => room.kind == GroupRoomKind.text)
        .toList(growable: false);
    final defaultId = group.layout.initialTextRoom.id;
    return ComposerChatTarget(
      ownerKey: group.ownerKey,
      conversationId: group.conversationId,
      displayName: group.displayTitle,
      defaultTopicId: defaultId,
      lastTopicId: selectedGroupTopicId(group),
      isGroup: true,
      topics: [
        for (final room in rooms)
          ComposerTopicTarget(
            id: room.id,
            name: room.name,
            isDefault: room.id == defaultId,
          ),
      ],
    );
  }

  Future<bool> executeComposerResult(
    ComposerResult result, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!ownsConversationAction(action)) return false;
    switch (result.kind) {
      case ComposerResultKind.gravity:
        return false;
      case ComposerResultKind.createTopic:
        final name = result.topicName;
        return name != null && await createDmTopic(name, action: action);
      case ComposerResultKind.renameTopic:
        final name = result.topicName;
        return name != null && await renameDmTopic(result.topicId, name);
      case ComposerResultKind.switchTopic:
      case ComposerResultKind.openChat:
        if (result.ownerKey.startsWith('group:')) {
          final group = _groups[result.conversationId];
          if (group == null) return false;
          final room = group.layout.room(result.topicId);
          final topicId = room?.kind == GroupRoomKind.text
              ? room!.id
              : group.layout.initialTextRoom.id;
          await selectGroup(group.conversationId, action: action);
          if (!ownsConversationAction(action)) return false;
          return selectGroupTopic(
            group.conversationId,
            topicId,
            action: action,
          );
        }
        final friend = _friends[result.ownerKey];
        if (friend == null || friend.conversationId != result.conversationId) {
          return false;
        }
        await selectFriend(friend.peerId, action: action);
        if (!ownsConversationAction(action)) return false;
        final state = selectedDmTopicState;
        final topicId = state?.topic(result.topicId) == null
            ? DmTopicWire.mainId
            : result.topicId;
        return selectDmTopic(topicId, action: action);
    }
  }

  List<ConversationTimelineItem> get selectedDmTopicItems {
    final scope = selectedConversationScope;
    final state = selectedDmTopicState;
    if (scope == null || scope.isGroup) {
      return conversationItems;
    }
    if (state == null) {
      return List.unmodifiable(
        conversationItems.where((item) => item.topicId == DmTopicWire.mainId),
      );
    }
    final selected = selectedDmTopicId;
    final items = _conversationTimeline?.allItems ?? conversationItems;
    return List.unmodifiable(
      items.where((item) {
        if (item is TimelineDmTopicEventItem) {
          final event = DmTopicEventCodec.decode(item.eventBody);
          if (event?.operation == DmTopicOperation.left) {
            // Only the peer's own notice means "removed you".
            return selected == DmTopicWire.mainId &&
                item.authorId == scope.peerId;
          }
          return event?.operation == DmTopicOperation.archive &&
              event?.topicId == selected;
        }
        final topicId = state.topic(item.topicId)?.id;
        return topicId == selected;
      }),
    );
  }

  Future<bool> selectDmTopic(
    String topicId, {
    ConversationAction? action,
    bool fromHistorySearch = false,
  }) async {
    if (action != null && !ownsConversationAction(action)) return false;
    if (!fromHistorySearch) {
      _retireHistoryTimeline(releaseReadSuppression: true);
    }
    final scope = selectedConversationScope;
    final state = selectedDmTopicState;
    if (scope == null || scope.isGroup || state?.topic(topicId) == null) {
      return false;
    }
    if (_selectedDmTopicIds[scope] == topicId) return true;
    _conversationSelectionRevision++;
    _selectedDmTopicIds[scope] = topicId;
    _persistedDmTopicSelections[scope] = topicId;
    action?._owner = conversationActionOwner;
    await _saveDmTopicSelections();
    _markLatestIncomingDisplayed();
    notifyListeners();
    return true;
  }

  Future<bool> createDmTopic(String name, {ConversationAction? action}) async {
    action ??= captureConversationAction();
    if (!ownsConversationAction(action)) return false;
    final scope = selectedConversationScope;
    final state = selectedDmTopicState;
    final normalized = GroupLayoutCodec.normalizeName(name);
    if (scope == null ||
        scope.isGroup ||
        state == null ||
        normalized == null ||
        normalized.toLowerCase() == DmTopicWire.mainId ||
        state.nextTopicOrder < 0) {
      return false;
    }
    String topicId;
    do {
      topicId = newDmTopicId();
    } while (state.topic(topicId) != null);
    final event = DmTopicEvent.create(
      topicId: topicId,
      revision: 1,
      name: normalized,
      order: state.nextTopicOrder,
    );
    if (!await _commitDmTopicEvent(scope, event)) return false;
    if (!ownsConversationAction(action)) return true;
    final selected = await selectDmTopic(topicId, action: action);
    if (selected) await _markDmTopicIntroductionUnderstood();
    return selected;
  }

  Future<bool> renameDmTopic(String topicId, String name) async {
    final scope = selectedConversationScope;
    final state = selectedDmTopicState;
    final normalized = GroupLayoutCodec.normalizeName(name);
    if (scope == null ||
        scope.isGroup ||
        state?.topic(topicId) == null ||
        topicId == DmTopicWire.mainId ||
        normalized == null ||
        normalized.toLowerCase() == DmTopicWire.mainId) {
      return false;
    }
    final revision = state!.nextRevision(
      DmTopicOperation.rename,
      topicId,
      authorId: jamiId,
    );
    if (revision <= 0) return false;
    return _commitDmTopicEvent(
      scope,
      DmTopicEvent.rename(
        topicId: topicId,
        revision: revision,
        name: normalized,
      ),
    );
  }

  Future<bool> setDmTopicArchived(String topicId, bool archived) async {
    final scope = selectedConversationScope;
    final state = selectedDmTopicState;
    final topic = state?.topic(topicId);
    if (scope == null ||
        scope.isGroup ||
        topic == null ||
        topicId == DmTopicWire.mainId ||
        topic.archivedBy.contains(jamiId) == archived) {
      return false;
    }
    final revision = state!.nextRevision(
      DmTopicOperation.archive,
      topicId,
      authorId: jamiId,
    );
    if (revision <= 0) return false;
    return _commitDmTopicEvent(
      scope,
      DmTopicEvent.archive(
        topicId: topicId,
        revision: revision,
        archived: archived,
      ),
    );
  }

  Future<bool> _commitDmTopicEvent(
    ConversationScope scope,
    DmTopicEvent event,
  ) async => await _commitDmTopicEventId(scope, event) != null;

  /// The committed event's daemon commit ID, or null when not committed.
  Future<String?> _commitDmTopicEventId(
    ConversationScope scope,
    DmTopicEvent event,
  ) async {
    if (_disposed ||
        appearOffline ||
        _scopeForPeer(scope.peerId) != scope ||
        _dmTopicMutations.containsKey(scope)) {
      return null;
    }
    final done = _dmTopicMutations[scope] = Completer<void>();
    final authorId = jamiId;
    try {
      final body = DmTopicEventCodec.encode(event);
      final commitId = await jami.sendDmTopicEvent(
        scope.peerId,
        scope.conversationId,
        body,
      );
      if (_disposed ||
          _scopeForPeer(scope.peerId) != scope ||
          jamiId != authorId ||
          commitId.isEmpty ||
          commitId.length > 128) {
        return null;
      }
      _mergeLiveDmTopicRecord(scope, {
        'daemonId': commitId,
        'authorId': authorId,
        'mimeType': DmTopicWire.mimeType,
        'topicId': DmTopicWire.mainId,
        'topicTagged': false,
        'body': body,
      });
      await _conversationTimelines[scope]?.refresh();
      return commitId;
    } catch (error) {
      dlog('sendDmTopicEvent(${scope.peerId}) failed: $error');
      return null;
    } finally {
      if (identical(_dmTopicMutations[scope], done)) {
        _dmTopicMutations.remove(scope);
      }
      if (!done.isCompleted) done.complete();
      notifyListeners();
    }
  }

  bool _ownsConversationPeer(String? id) =>
      id != null &&
      (_friends.containsKey(id) ||
          _groups.values.any((group) => group.ownerKey == id));

  /// The selected direct contact's short-lived composer hint. Group activity
  /// is deliberately unsupported until there is a native member broadcast.
  ComposerActivityKind? get remoteComposerActivity {
    if (!chatActivityIndicatorsEnabled || selectedGroupId != null) return null;
    final scope = selectedConversationScope;
    return scope == null ? null : _remoteComposerActivities[scope];
  }

  void setConversationVisible(
    String? id, {
    String? groupTopicId,
    String? dmTopicId,
  }) {
    var next = _foreground && !captureGateVisible && _ownsConversationPeer(id)
        ? id
        : null;
    String? nextGroupTopicId;
    String? nextDmTopicId;
    if (next != null) {
      final group = _groups.values
          .where((candidate) => candidate.ownerKey == next)
          .firstOrNull;
      if (group != null) {
        final room = group.layout.room(groupTopicId ?? '');
        if (room?.kind != GroupRoomKind.text) {
          next = null;
        } else {
          nextGroupTopicId = room!.id;
        }
      } else {
        final scope = _scopeForPeer(next);
        final state = scope == null ? null : _dmTopicStates[scope];
        if (state?.customTopics.isNotEmpty ?? false) {
          final requested = dmTopicId ?? _selectedDmTopicIds[scope];
          if (requested == null || state!.topic(requested) == null) {
            next = null;
          } else {
            nextDmTopicId = requested;
          }
        }
      }
    }
    if (_visibleConversationPeerId == next &&
        _visibleGroupTopicId == nextGroupTopicId &&
        _visibleDmTopicId == nextDmTopicId) {
      return;
    }
    if (next == null) _retireLocalComposerActivity();
    _visibleConversationPeerId = next;
    _visibleGroupTopicId = nextGroupTopicId;
    _visibleDmTopicId = nextDmTopicId;
    _refreshHologramPrivacy();
    if (next != null) {
      if (nextDmTopicId == null) markConversationRead(next);
      _markLatestIncomingDisplayed();
    }
  }

  /// Publish local direct-message activity through libjami's transient,
  /// conversation-scoped composing protocol. `idle` retires the last scope.
  Future<bool> setLocalComposerActivity(ComposerActivityKind kind) async {
    final selected = selectedConversationScope;
    final direct = selected != null && !selected.isGroup ? selected : null;
    final target = kind == ComposerActivityKind.idle
        ? (_localComposerActivityScope ?? direct)
        : direct;
    if (target == null ||
        (kind != ComposerActivityKind.idle &&
            (!chatActivityIndicatorsEnabled ||
                _visibleConversationPeerId != target.peerId ||
                !_foreground ||
                _protectedSurfaceLocked))) {
      return false;
    }
    final now = DateTime.now();
    if (kind != ComposerActivityKind.idle &&
        _localComposerActivityScope == target &&
        _localComposerActivity == kind &&
        _lastComposerActivitySentAt != null &&
        now.difference(_lastComposerActivitySentAt!) < composerActivityRepeat) {
      return true;
    }
    if (kind == ComposerActivityKind.idle &&
        _localComposerActivity == ComposerActivityKind.idle) {
      return true;
    }
    _localComposerActivityScope = kind == ComposerActivityKind.idle
        ? null
        : target;
    _localComposerActivity = kind;
    _lastComposerActivitySentAt = now;
    try {
      final sent = await jami.sendComposerActivity(
        target.accountId,
        target.peerId,
        target.conversationId,
        kind,
      );
      if (!sent &&
          kind != ComposerActivityKind.idle &&
          _localComposerActivityScope == target &&
          _localComposerActivity == kind) {
        _lastComposerActivitySentAt = null;
      }
      return sent;
    } catch (error) {
      if (kind != ComposerActivityKind.idle &&
          _localComposerActivityScope == target &&
          _localComposerActivity == kind) {
        _lastComposerActivitySentAt = null;
      }
      dlog('sendComposerActivity failed: $error');
      return false;
    }
  }

  void _retireLocalComposerActivity() {
    final target = _localComposerActivityScope;
    if (target == null || _localComposerActivity == ComposerActivityKind.idle) {
      _localComposerActivityScope = null;
      _localComposerActivity = ComposerActivityKind.idle;
      return;
    }
    _localComposerActivityScope = null;
    _localComposerActivity = ComposerActivityKind.idle;
    _lastComposerActivitySentAt = DateTime.now();
    _runInBackground(
      jami.sendComposerActivity(
        target.accountId,
        target.peerId,
        target.conversationId,
        ComposerActivityKind.idle,
      ),
      'sendComposerActivity(idle)',
    );
  }

  void _handleRemoteComposerActivity(JamiEvent event) {
    final eventAccount = _asString(event.data['accountId']);
    final sender = _asString(event.data['fromJamiId']);
    final conversationId = _asString(event.data['conversationId']);
    final kind = ComposerActivityKind.fromWire(event.data['kind']);
    final scope = _scopeForPeer(sender);
    if (scope == null ||
        eventAccount != scope.accountId ||
        conversationId != scope.conversationId ||
        sender == jamiId ||
        kind == null) {
      return;
    }
    if (kind == ComposerActivityKind.idle) {
      if (_remoteComposerActivities.remove(scope) != null) notifyListeners();
      return;
    }
    _remoteComposerActivities[scope] = kind;
    notifyListeners();
  }

  void _clearRemoteComposerActivities() {
    if (_remoteComposerActivities.isEmpty) return;
    _remoteComposerActivities.clear();
    notifyListeners();
  }

  void markConversationRead(String id) {
    if (historyTimelineReadSuppressed) return;
    final scope = _scopeForPeer(id);
    if (scope != null &&
        (_dmTopicStates[scope]?.customTopics.isNotEmpty ?? false)) {
      return;
    }
    final current = _friendActivity[id];
    if (current == null || current.unreadTotal == 0) return;
    _friendActivity[id] = current.copyWith(unreadMessages: 0, unreadFiles: 0);
    notifyListeners();
  }

  int _friendsRevision = 0;
  (String?, int)? _friendsAccountOwner;
  final Set<String> _uncertainControlPeers = {};
  ({(String?, int) account, String peerId, String message})?
  _controlTrustWarning;

  String? get remoteControlTrustWarning {
    final warning = _controlTrustWarning;
    return warning?.account == (accountId, _accountRevision) &&
            warning?.peerId == call?.peerId
        ? warning?.message
        : null;
  }

  FriendState? get selectedFriend =>
      peerId == null || isRemovalPending(peerId!) ? null : _friends[peerId];

  /// Daemon-backed friends minus those this device is removing. A
  /// presentation filter only: [_friends] stays daemon truth.
  Iterable<FriendState> get visibleFriends =>
      friends.values.where((friend) => !isRemovalPending(friend.peerId));

  /// The friend's newest record in this exact 1:1 conversation is a valid
  /// peer-authored `left` event: they removed you.
  bool peerLeft(String peerId) {
    final scope = _scopeForPeer(peerId);
    return scope != null &&
        _loadedDmTopicScopes.contains(scope) &&
        (_dmTopicStates[scope]?.hasLeft(peerId) ?? false);
  }

  /// A removal of this friend is running (its notice window or daemon
  /// confirmation). A refused removal shows the friend again for a retry.
  bool isRemovalPending(String peerId) =>
      _removalRuns.containsKey((accountId, peerId)) &&
      _removalMarker(peerId) != null;

  bool _directPeerClosed(String peerId) {
    final scope = _scopeForPeer(peerId);
    // Losing projection readiness cannot grant authority that its last exact
    // state denied. Only completed reconstruction or scope retirement reopens it.
    return isRemovalPending(peerId) ||
        peerLeft(peerId) ||
        (scope != null && (_dmTopicStates[scope]?.hasLeft(peerId) ?? false));
  }

  void _syncDirectPeerGates() {
    _syncPresenceRuntime();
    _syncRemoteControl();
  }

  /// Friend-facing surfaces never expose the transport identifier. The full
  /// ID is available only from that friend's explicit options.
  String peerDisplayName(String id) {
    if (id == jamiId) {
      final localName = displayName.trim();
      return localName.isEmpty ? 'You' : localName;
    }
    final name = _friends[id]?.displayName.trim() ?? '';
    if (name.isNotEmpty) return name;
    return 'Your friend';
  }

  late final VersionedAppSettingsRepository _settingsRepository;
  late final AppLockLatchRepository _appLockLatchRepository;
  late final _JamiConversationTimelineRepository _timelineRepository;
  AppSettings appSettings = AppSettings();
  String? settingsError;
  bool _settingsDocumentWritable = false;
  bool _microphoneSettingsKnown = false;
  bool _restoringIdentity = false;
  bool _adoptingAccount = false;
  static const resetDoorlightMarker = 'resetDoorlight.pending.v1';
  bool resettingDoorlight = false;
  bool resetDoorlightRestartRequired = false;
  String? resetDoorlightError;
  bool get resetDoorlightPending => prefs.containsKey(resetDoorlightMarker);
  // Closing does not end the process on either platform (Android keeps the
  // daemon worker alive, Windows hides to the tray), so the splash ends it.
  static String get _resetCompleteMessage => Platform.isWindows
      ? 'Doorlight has been reset. Quit it, then open it again.'
      : 'Doorlight has been reset. Restart it to continue.';
  static String get relaunchLabel =>
      Platform.isWindows ? 'Quit Doorlight' : 'Restart Doorlight';

  /// The native engine can never boot in this process (reset completed, or
  /// libjami init/start failed); only a new process recovers.
  bool get relaunchRequired =>
      resetDoorlightRestartRequired || _engineRelaunchRequired;
  bool _engineRelaunchRequired = false;
  Future<void> relaunchRetired() => jami.relaunchRetired();

  /// The persisted exact account establishes consent across an interrupted
  /// reset. Never adopt/create an identity while that marker remains.
  Future<bool> resetDoorlight() async {
    if (resettingDoorlight || resetDoorlightRestartRequired) return false;
    if ((_restoringIdentity && !resetDoorlightPending) ||
        backingUp ||
        settingsBusy ||
        overlaySettings.busy ||
        _captureBusy ||
        _initializationInFlight != null ||
        _bootInFlight != null ||
        devicePairingPending ||
        call != null ||
        groupCall != null ||
        _groupJoinOperation != null ||
        placing ||
        _changingAppearOffline ||
        changingDisplayName ||
        changingProfileAvatar ||
        _changingConnectionProfile) {
      resetDoorlightError =
          'Finish the current call or operation before resetting.';
      notifyListeners();
      return false;
    }
    final pending = prefs.get(resetDoorlightMarker);
    final target = pending ?? accountId;
    if (target is! String ||
        target.isEmpty ||
        (accountId != null && accountId != target)) {
      resetDoorlightError = 'The identity to reset could not be verified.';
      notifyListeners();
      return false;
    }
    resettingDoorlight = true;
    _restoringIdentity = true;
    resetDoorlightError = null;
    retireHistorySearch();
    _refreshHologramPrivacy();
    notifyListeners();
    try {
      if (!await MediaRetirement.stopAll()) {
        throw StateError('Media playback could not be stopped.');
      }
      if (!await prefs.setString(resetDoorlightMarker, target)) {
        throw StateError('Reset confirmation could not be saved.');
      }
      screen = Screen.loading;
      bootError = 'Resetting Doorlight…';
      bootErrorDetails = null;
      notifyListeners();
      if (!await jami.resetDoorlight(target)) {
        throw StateError('The local identity removal was not confirmed.');
      }
      if (!await chatArchive.deleteAccount(target)) {
        throw StateError('Archived chats could not be removed.');
      }
      // Keep the consent/recovery barrier until all local preference removal
      // succeeds. Never use clear(): it would erase the marker first.
      await prefs.reload();
      for (final key
          in prefs
              .getKeys()
              .where((key) => key != resetDoorlightMarker)
              .toList()) {
        if (!await prefs.remove(key)) {
          throw StateError('Local preferences could not be removed.');
        }
      }
      if (!await prefs.remove(resetDoorlightMarker)) {
        throw StateError('Reset completion could not be saved.');
      }
      accountId = null;
      jamiId = '';
      displayName = '';
      profileAvatarBase64 = '';
      ready = false;
      resetDoorlightRestartRequired = true;
      bootError = _resetCompleteMessage;
      return true;
    } catch (_) {
      resetDoorlightError = resetDoorlightPending
          ? 'Reset was interrupted. Finish resetting Doorlight before using it.'
          : 'Doorlight could not be reset. Please try again.';
      if (resetDoorlightPending) {
        screen = Screen.loading;
        bootError = resetDoorlightError;
      }
      return false;
    } finally {
      resettingDoorlight = false;
      _restoringIdentity =
          resetDoorlightPending || resetDoorlightRestartRequired;
      notifyListeners();
    }
  }

  bool _restoreSettingsNoticePending = false;
  bool takeRestoreSettingsNotice() {
    final pending = _restoreSettingsNoticePending;
    _restoreSettingsNoticePending = false;
    return pending;
  }

  void Function()? _pendingMicrophoneModeCommit;
  bool get _microphonePolicyUnavailable =>
      _restoringIdentity ||
      appSettings.microphoneReviewRequired ||
      (jami.usesNativeAppSettingsStore && !_microphoneSettingsKnown);
  int _settingsWritesInFlight = 0;
  bool get settingsBusy => _settingsWritesInFlight > 0 || _adoptingAccount;
  bool get settingsWritable => _settingsDocumentWritable;
  IdentityColor get identityColor =>
      appSettings.identityColorManual || jamiId.isEmpty
      ? appSettings.identityColor
      : IdentityColor.automaticFor(jamiId);

  bool get canSetIdentityColor =>
      settingsControlsEnabled &&
      remoteControl.phase != RemoteControlPhase.requesting &&
      !remoteControl.isControlling &&
      !remoteControl.hostActive;

  bool get canChangeOnlineStatus =>
      !_restoringIdentity && !settingsBusy && !_changingAppearOffline;
  bool get canChangeConnectionProfile =>
      !_restoringIdentity && !settingsBusy && !_changingConnectionProfile;

  bool get appLockWritable =>
      !settingsBusy && !_captureBusy && !_restoringIdentity;
  bool get settingsControlsEnabled =>
      _settingsDocumentWritable &&
      !settingsBusy &&
      !_captureBusy &&
      !_restoringIdentity;

  ConversationTimelineController? _conversationTimeline;
  bool _applyingReactionMetadata = false;
  // ponytail: This intentionally retains only conversations opened during the
  // current account session. If very large friend lists make that material,
  // replace it with an LRU without changing the controller ownership model.
  final Map<ConversationScope, ConversationTimelineController>
  _conversationTimelines = {};
  bool _widgetChatCaptureGranted = false;
  bool _widgetChatConsentPending = false;
  int _widgetChatConsentSerial = 0;
  int? _widgetChatConsentRequest;
  int _widgetChatGeneration = 0;
  int _widgetFriendsRevision = -1;
  final Map<String, WidgetChatConversation> _widgetChatConversations = {};
  final Map<ConversationScope, String> _widgetDraftKeys = {};
  // Non-authorizing local draft binding survives desktop restart. Every command
  // still requires the independently generated current session token.
  String _widgetDraftKey(ConversationScope scope) =>
      _widgetDraftKeys.putIfAbsent(
        scope,
        () => sha256
            .convert(
              utf8.encode(
                jsonEncode(['doorlight-widget-draft-v1', jamiId, scope.toMap()]),
              ),
            )
            .toString(),
      );
  final Map<ConversationScope, SendJournalRecord> _widgetSendResults = {};
  (String?, int)? _widgetDraftAccountOwner;
  String? _widgetSelectedChatToken;
  ConversationTimelineController? _widgetChatTimeline;
  int _widgetChatTimelineGeneration = 0;
  bool _widgetTimelineRefreshQueued = false;
  ConversationScope? _queuedWidgetTimelineRefreshScope;
  int? _queuedWidgetTimelineRefreshGeneration;
  String? _widgetOlderWindowAnchorId;
  final Map<String, WidgetVoiceTarget> _widgetVoiceTargets = {};
  final Map<String, WidgetVoiceTarget> _widgetDirectCallTargets = {};
  final Map<String, WidgetVoiceTarget> _widgetGroupCallTargets = {};
  final Map<String, WidgetVoiceTarget> _widgetGroupRoomTargets = {};
  String? _widgetActiveVoiceToken;
  String? _widgetActiveVoiceIdentity;
  final Map<({ConversationScope scope, String? topicId}), String>
  _displayedMessageIds = {};
  ConversationTimelineController? get conversationTimeline =>
      _conversationTimeline;
  List<ConversationTimelineItem> get conversationItems =>
      _conversationTimeline?.items ?? const [];
  bool get chatLoading => _conversationTimeline?.isLoading ?? false;
  bool get chatHasMore => _conversationTimeline?.hasMore ?? false;
  Object? get chatLoadError => _conversationTimeline?.lastError;

  bool get _widgetChatBaseAllowed =>
      !_disposed &&
      _startupPrepared &&
      screen == Screen.home &&
      accountId?.isNotEmpty == true &&
      jamiId.isNotEmpty &&
      !_protectedSurfaceLocked &&
      !captureGateVisible &&
      !_captureBusy &&
      !_restoringIdentity &&
      !pendingIdentityRecovery &&
      !appearOffline;

  bool get _widgetChatAllowed =>
      _widgetChatBaseAllowed && _widgetChatCaptureGranted;

  bool get _widgetChatConsentCanBeSkipped =>
      _isWindowsPlatform && !appSettings.windowsCaptureProtectionEnabled;

  int? get widgetChatConsentRequest =>
      _widgetChatConsentPending &&
          _widgetChatBaseAllowed &&
          _foreground &&
          !_widgetChatCaptureGranted
      ? _widgetChatConsentRequest
      : null;

  /// Called only by the app's foreground consent host. The widget can request
  /// this prompt, but cannot grant its own capture-visible content permission.
  Future<bool> grantWidgetChatConsent(int request) async {
    if (request != _widgetChatConsentRequest ||
        !_widgetChatConsentPending ||
        !_widgetChatBaseAllowed ||
        !_foreground ||
        _widgetChatCaptureGranted) {
      return false;
    }
    final accountOwner = (accountId, _accountRevision);
    final selectionGeneration = _widgetChatGeneration;
    bool current() =>
        !_disposed &&
        request == _widgetChatConsentRequest &&
        _widgetChatConsentPending &&
        !_widgetChatCaptureGranted &&
        _widgetChatBaseAllowed &&
        accountOwner == (accountId, _accountRevision) &&
        selectionGeneration == _widgetChatGeneration;
    try {
      if (!await prefs.setBool(_widgetChatCaptureConsentKey, true) ||
          !current()) {
        return false;
      }
    } catch (_) {
      return false;
    }
    _widgetChatCaptureGranted = true;
    _widgetChatConsentPending = false;
    _widgetChatConsentRequest = null;
    _widgetChatGeneration++;
    _widgetReconcileConversations();
    notifyListeners();
    return true;
  }

  Future<bool> _grantWidgetChatShowFromEnable() async {
    if (!_widgetChatBaseAllowed ||
        !_widgetChatConsentCanBeSkipped ||
        _widgetChatCaptureGranted) {
      return false;
    }
    final accountOwner = (accountId, _accountRevision);
    final selectionGeneration = _widgetChatGeneration;
    bool current() =>
        !_disposed &&
        !_widgetChatCaptureGranted &&
        _widgetChatBaseAllowed &&
        _widgetChatConsentCanBeSkipped &&
        accountOwner == (accountId, _accountRevision) &&
        selectionGeneration == _widgetChatGeneration;
    try {
      if (!await prefs.setBool(_widgetChatCaptureConsentKey, true) ||
          !current()) {
        return false;
      }
    } catch (_) {
      return false;
    }
    _widgetChatCaptureGranted = true;
    _widgetChatConsentPending = false;
    _widgetChatConsentRequest = null;
    _widgetChatGeneration++;
    _widgetReconcileConversations();
    notifyListeners();
    return true;
  }

  void dismissWidgetChatConsent(int request) {
    if (request != _widgetChatConsentRequest) return;
    _widgetChatConsentPending = false;
    _widgetChatConsentRequest = null;
    notifyListeners();
  }

  /// Revokes the installation-local Show choice and drops all currently
  /// rendered chat. Exposed for a future app-owned privacy control.
  Future<bool> revokeWidgetChatConsent() async {
    try {
      if (!await prefs.remove(_widgetChatCaptureConsentKey)) return false;
    } catch (_) {
      return false;
    }
    _widgetChatCaptureGranted = false;
    _widgetChatConsentPending = false;
    _widgetChatConsentRequest = null;
    _retireWidgetChatSession();
    notifyListeners();
    return true;
  }

  List<WidgetChatConversation> _currentWidgetConversations() {
    final result = <WidgetChatConversation>[];
    final account = accountId;
    if (account == null || account.isEmpty) return result;
    for (final friend in _friends.values) {
      if (!friend.confirmed ||
          isRemovalPending(friend.peerId) ||
          _directPeerClosed(friend.peerId) ||
          friend.conversationId.isEmpty) {
        continue;
      }
      final scope = _scopeForPeer(friend.peerId);
      if (scope == null || scope.accountId != account) continue;
      result.add(
        WidgetChatConversation(
          token: '',
          scope: scope,
          label: peerDisplayName(friend.peerId),
          kind: 'direct',
        ),
      );
    }
    for (final group in _groups.values) {
      if (!group.activeMemberIds.contains(jamiId) ||
          group.conversationId.isEmpty ||
          group.layout.room('general')?.kind != GroupRoomKind.text) {
        continue;
      }
      final scope = _scopeForGroup(group.conversationId);
      if (scope == null || scope.accountId != account) continue;
      result.add(
        WidgetChatConversation(
          token: '',
          scope: scope,
          label: group.displayTitle,
          kind: 'group',
        ),
      );
    }
    result.sort(
      (left, right) =>
          left.label.toLowerCase().compareTo(right.label.toLowerCase()),
    );
    return result;
  }

  void _widgetReconcileConversations() {
    final owner = (accountId, _accountRevision);
    if (_widgetDraftAccountOwner != owner) {
      _widgetDraftAccountOwner = owner;
      _widgetDraftKeys.clear();
      _widgetSendResults.clear();
    }
    if (!_widgetChatAllowed) {
      _widgetChatConversations.clear();
      _widgetSelectedChatToken = null;
      _retireWidgetTimeline();
      _widgetChatGeneration++;
      return;
    }
    final current = _currentWidgetConversations();
    if (_widgetFriendsRevision != _friendsRevision) {
      _widgetFriendsRevision = _friendsRevision;
      _widgetChatConversations.clear();
      _widgetSelectedChatToken = null;
      _retireWidgetTimeline();
      _widgetChatGeneration++;
    }
    final byScope = {for (final item in current) item.scope: item};
    _widgetDraftKeys.removeWhere((scope, _) => !byScope.containsKey(scope));
    _widgetSendResults.removeWhere((scope, _) => !byScope.containsKey(scope));
    final retained = <String, WidgetChatConversation>{};
    for (final entry in _widgetChatConversations.entries) {
      final latest = byScope[entry.value.scope];
      if (latest == null) continue;
      retained[entry.key] = WidgetChatConversation(
        token: entry.key,
        scope: latest.scope,
        label: latest.label,
        kind: latest.kind,
        draftKey: _widgetDraftKey(latest.scope),
      );
    }
    for (final item in current) {
      if (retained.values.any((existing) => existing.scope == item.scope)) {
        continue;
      }
      final token = createWidgetToken();
      retained[token] = WidgetChatConversation(
        token: token,
        scope: item.scope,
        label: item.label,
        kind: item.kind,
        draftKey: _widgetDraftKey(item.scope),
      );
    }
    final selected = _widgetSelectedChatToken;
    if (selected != null && !retained.containsKey(selected)) {
      _widgetSelectedChatToken = null;
      _retireWidgetTimeline();
      _widgetChatGeneration++;
    }
    _widgetChatConversations
      ..clear()
      ..addAll(retained);
  }

  bool _widgetOwnsScope(ConversationScope scope) {
    if (!_widgetChatAllowed || scope.accountId != accountId) return false;
    if (!scope.isGroup) {
      final friend = _friends[scope.peerId];
      return friend != null &&
          friend.confirmed &&
          !isRemovalPending(scope.peerId) &&
          !_directPeerClosed(scope.peerId) &&
          _scopeForPeer(scope.peerId) == scope;
    }
    final group = _groups[scope.conversationId];
    return group != null &&
        group.ownerKey == scope.peerId &&
        group.activeMemberIds.contains(jamiId) &&
        _scopeForGroup(scope.conversationId) == scope;
  }

  bool _widgetOwnsChatScope(ConversationScope scope) =>
      _widgetOwnsScope(scope) &&
      (!scope.isGroup ||
          _groups[scope.conversationId]?.layout.room('general')?.kind ==
              GroupRoomKind.text);

  ConversationTimelineController? _widgetTimelineForScope(
    ConversationScope scope,
  ) {
    if (!_widgetChatAllowed || !_widgetOwnsChatScope(scope)) return null;
    final token = _widgetSelectedChatToken;
    final timeline = _widgetChatTimeline;
    if (token == null ||
        timeline == null ||
        timeline.scope != scope ||
        _widgetChatConversations[token]?.scope != scope) {
      return null;
    }
    return timeline;
  }

  /// Returns the app-owned timeline and, only when the current visible widget
  /// owns this exact scope, its separate projection controller as well.
  Iterable<ConversationTimelineController> _timelinesForScope(
    ConversationScope scope,
  ) sync* {
    final appTimeline = _conversationTimelines[scope];
    if (appTimeline != null) yield appTimeline;
    final widgetTimeline = _widgetTimelineForScope(scope);
    if (widgetTimeline != null && !identical(widgetTimeline, appTimeline)) {
      yield widgetTimeline;
    }
  }

  Set<ConversationScope> _timelineScopesForConversation(
    String ownerAccount,
    String conversationId,
  ) {
    final scopes = <ConversationScope>{
      for (final scope in _conversationTimelines.keys)
        if (scope.accountId == ownerAccount &&
            scope.conversationId == conversationId)
          scope,
    };
    final widgetScope = _widgetChatTimeline?.scope;
    if (widgetScope != null &&
        widgetScope.accountId == ownerAccount &&
        widgetScope.conversationId == conversationId) {
      scopes.add(widgetScope);
    }
    return scopes;
  }

  void _scheduleWidgetTimelineRefresh(ConversationScope scope) {
    final timeline = _widgetTimelineForScope(scope);
    if (timeline == null) return;
    _queuedWidgetTimelineRefreshScope = scope;
    _queuedWidgetTimelineRefreshGeneration = _widgetChatTimelineGeneration;
    if (_widgetTimelineRefreshQueued) return;
    _widgetTimelineRefreshQueued = true;
    scheduleMicrotask(() {
      _widgetTimelineRefreshQueued = false;
      final requestedScope = _queuedWidgetTimelineRefreshScope;
      final generation = _queuedWidgetTimelineRefreshGeneration;
      _queuedWidgetTimelineRefreshScope = null;
      _queuedWidgetTimelineRefreshGeneration = null;
      if (_disposed ||
          requestedScope == null ||
          generation != _widgetChatTimelineGeneration) {
        return;
      }
      final current = _widgetTimelineForScope(requestedScope);
      if (current == null) return;
      _runInBackground(current.refresh(), 'refreshWidgetChat(required)');
    });
  }

  ConversationTimelineController _createWidgetTimeline(
    ConversationScope scope,
  ) => ConversationTimelineController(
    scope: scope,
    localAuthorId: jamiId,
    repository: _timelineRepository,
    allowedRemoteAuthorIds: scope.isGroup
        ? (_groups[scope.conversationId]?.activeMemberIds ?? const <String>{})
              .where((id) => id != jamiId)
              .toSet()
        : {scope.peerId},
  );

  void _retireWidgetTimeline() {
    final current = _widgetChatTimeline;
    if (current != null) {
      current.removeListener(_onWidgetTimelineChanged);
      current.dispose();
    }
    _widgetChatTimeline = null;
    _widgetChatTimelineGeneration++;
    _widgetOlderWindowAnchorId = null;
  }

  List<ConversationTimelineItem> _widgetVisibleTimelineItems(
    ConversationTimelineController timeline,
  ) => timeline.items
      .where((item) {
        if (item is! TimelineTextItem || item.topicId != DmTopicWire.mainId) {
          return false;
        }
        return !item.scope.isGroup ||
            (item.roomId ?? GroupTopicCodec.decode(item.text).topicId) ==
                'general';
      })
      .toList(growable: false);

  (int, int) _widgetHistoryWindow(List<ConversationTimelineItem> items) {
    var end = items.length;
    final anchor = _widgetOlderWindowAnchorId;
    if (anchor != null) {
      final anchorIndex = items.indexWhere((item) => item.daemonId == anchor);
      if (anchorIndex >= 0) end = anchorIndex;
    }
    final start = end > 48 ? end - 48 : 0;
    return (start, end);
  }

  void _onWidgetTimelineChanged() {
    if (!_disposed) notifyListeners();
  }

  void _retireWidgetChatSession() {
    _widgetChatGeneration++;
    _widgetChatConversations.clear();
    _widgetSelectedChatToken = null;
    _retireWidgetTimeline();
    _widgetVoiceTargets.clear();
    _widgetDirectCallTargets.clear();
    _widgetGroupCallTargets.clear();
    _widgetGroupRoomTargets.clear();
    _widgetActiveVoiceToken = null;
    _widgetActiveVoiceIdentity = null;
  }

  Map<String, Object?> get widgetOverlaySnapshot {
    final String status;
    if (!_startupPrepared ||
        screen != Screen.home ||
        accountId?.isNotEmpty != true ||
        jamiId.isEmpty ||
        appearOffline) {
      status = 'disconnected';
    } else if (_protectedSurfaceLocked ||
        captureGateVisible ||
        _captureBusy ||
        _restoringIdentity ||
        pendingIdentityRecovery) {
      status = 'locked';
    } else if (!_widgetChatCaptureGranted) {
      status = 'consent';
    } else {
      status = 'ready';
    }
    if (status != 'ready' &&
        (_widgetChatTimeline != null ||
            _widgetChatConversations.isNotEmpty ||
            _widgetVoiceTargets.isNotEmpty)) {
      _retireWidgetChatSession();
    }
    if (status == 'ready') _widgetReconcileConversations();
    final entry = _widgetSelectedChatToken == null
        ? null
        : _widgetChatConversations[_widgetSelectedChatToken];
    final timeline = _widgetChatTimeline;
    final currentSelection =
        entry != null &&
        timeline != null &&
        timeline.scope == entry.scope &&
        _widgetOwnsChatScope(entry.scope);
    final items = currentSelection
        ? _widgetVisibleTimelineItems(timeline)
        : const <ConversationTimelineItem>[];
    final (windowStart, windowEnd) = _widgetHistoryWindow(items);
    final previewItems = items.sublist(windowStart, windowEnd);
    final conversations = status == 'ready'
        ? _widgetChatConversations.values
              .take(48)
              .map((item) {
                final value = item.toMap();
                value['label'] = _widgetPreviewText(item.label, 128);
                return value;
              })
              .toList(growable: false)
        : const <Map<String, Object?>>[];
    return {
      'chat': {
        'status': status,
        'uiPending': _widgetChatConsentPending && status == 'consent',
        'token': currentSelection ? entry.token : '',
        'draftKey': currentSelection ? entry.draftKey : '',
        if (currentSelection)
          if (_widgetSendResults[entry.scope] case final result?)
            'submission': {
              'operationId': result.operationId,
              'status': result.status.name,
              if (result.commitId != null) 'commitId': result.commitId,
            },
        'conversations': conversations,
        'selected': currentSelection ? entry.token : null,
        'messages': [
          for (final item in previewItems) _widgetTimelineMessage(item),
        ],
        'canSend':
            currentSelection &&
            !_widgetSendBusy &&
            !const {
              ComposerSendStatus.pending,
              ComposerSendStatus.unknown,
            }.contains(_widgetSendResults[entry.scope]?.status) &&
            !appearOffline &&
            !_directPeerClosed(entry.scope.peerId),
        'hasOlder': currentSelection && (windowStart > 0 || timeline.hasMore),
        'loading': currentSelection && timeline.isLoading,
        'error': currentSelection && timeline.lastError != null,
      },
      'voice': _widgetVoiceSnapshot(status),
    };
  }

  bool _widgetSendBusy = false;

  String _widgetPreviewText(String value, int maxBytes) {
    if (utf8.encode(value).length <= maxBytes) return value;
    final out = StringBuffer();
    var bytes = 0;
    for (final rune in value.runes) {
      final size = rune <= 0x7f
          ? 1
          : rune <= 0x7ff
          ? 2
          : rune <= 0xffff
          ? 3
          : 4;
      if (bytes + size > maxBytes - 3) break;
      out.writeCharCode(rune);
      bytes += size;
    }
    return '$out…';
  }

  Map<String, Object?> _widgetTimelineMessage(ConversationTimelineItem item) {
    final textItem = item as TimelineTextItem;
    final groupBody = item.scope.isGroup
        ? GroupTopicCodec.decode(textItem.text).body
        : textItem.text;
    final group = item.scope.isGroup
        ? _groups[item.scope.conversationId]
        : null;
    final author = item.authorId == jamiId
        ? (displayName.trim().isEmpty ? 'You' : displayName.trim())
        : (group?.memberDisplayNames[item.authorId]?.trim().isNotEmpty == true
              ? group!.memberDisplayNames[item.authorId]!.trim()
              : peerDisplayName(item.authorId));
    return {
      'id': _widgetPreviewText(item.daemonId, 96),
      'author': _widgetPreviewText(author, 96),
      'text': _widgetPreviewText(groupBody, 512),
      'own': item.direction == TimelineDirection.outgoing,
      'status': item.deliveryState.name,
    };
  }

  Future<Map<String, Object?>> handleWidgetOverlayCommand(
    String command,
    Map<String, dynamic> args,
  ) async {
    switch (command) {
      case 'chat.enable':
        if (!_widgetChatBaseAllowed) throw StateError('locked');
        if (!_widgetChatCaptureGranted) {
          if (_widgetChatConsentCanBeSkipped) {
            if (!await _grantWidgetChatShowFromEnable()) {
              throw StateError('save_failed');
            }
            return {'ok': true, 'pendingConsent': false};
          }
          if (!_widgetChatConsentPending) {
            _widgetChatConsentPending = true;
            _widgetChatConsentRequest = ++_widgetChatConsentSerial;
          }
          notifyListeners();
          return {'ok': true, 'pendingConsent': true};
        }
        return {'ok': true, 'pendingConsent': false};
      case 'chat.close':
        retireWidgetOverlaySession();
        return {'ok': true};
      case 'chat.select':
        return _selectWidgetConversation(args['token'], args['conversation']);
      case 'chat.latest':
        return _selectWidgetConversation(args['token'], args['conversation']);
      case 'chat.history':
      case 'chat.older':
        return _loadOlderWidgetChat(args['token'], args['conversation']);
      case 'chat.send':
        return _sendWidgetChat(args);
      case 'voice.mute':
        return _widgetMute(args['token'], args['muted']);
      case 'voice.deafen':
        return _widgetDeafen(args['token'], args['deafened']);
      case 'voice.leave':
        return _widgetLeaveVoice(args['token']);
      case 'voice.answer':
        return _widgetAnswer(args['token']);
      case 'voice.decline':
        return _widgetDecline(args['token']);
      case 'voice.start':
        return _widgetStartVoice(args['token']);
      case 'voice.join':
        return _widgetJoinVoice(args['token']);
      default:
        throw StateError('invalid');
    }
  }

  Future<Map<String, Object?>> _selectWidgetConversation(
    Object? rawToken,
    Object? rawConversation,
  ) async {
    _requireWidgetReady();
    if (rawToken is! String) throw StateError('invalid');
    _widgetReconcileConversations();
    final entry = _widgetChatConversations[rawToken];
    if (entry == null ||
        rawConversation != rawToken ||
        !_widgetOwnsChatScope(entry.scope)) {
      throw StateError('stale');
    }
    final generation = ++_widgetChatGeneration;
    _retireWidgetTimeline();
    final timeline = _createWidgetTimeline(entry.scope);
    _widgetChatTimeline = timeline;
    _widgetSelectedChatToken = rawToken;
    _widgetChatTimelineGeneration = generation;
    timeline.addListener(_onWidgetTimelineChanged);
    notifyListeners();
    await timeline.refresh();
    if (!_widgetSelectionCurrent(rawToken, entry.scope, generation, timeline)) {
      throw StateError('stale');
    }
    return {'ok': true};
  }

  Future<Map<String, Object?>> _loadOlderWidgetChat(
    Object? rawToken,
    Object? rawConversation,
  ) async {
    final (token, scope, generation, timeline) = _requireWidgetSelection(
      rawToken,
    );
    if (rawConversation != token) throw StateError('stale');
    final beforeItems = _widgetVisibleTimelineItems(timeline);
    final (beforeStart, _) = _widgetHistoryWindow(beforeItems);
    final anchorId = beforeItems.isEmpty
        ? null
        : beforeItems[beforeStart].daemonId;
    if (timeline.hasMore) await timeline.loadMore();
    if (!_widgetSelectionCurrent(token, scope, generation, timeline)) {
      throw StateError('stale');
    }
    if (anchorId != null) _widgetOlderWindowAnchorId = anchorId;
    notifyListeners();
    return {'ok': true};
  }

  (String, ConversationScope, int, ConversationTimelineController)
  _requireWidgetSelection(Object? rawToken) {
    _requireWidgetReady();
    if (rawToken is! String || rawToken != _widgetSelectedChatToken) {
      throw StateError('stale');
    }
    final entry = _widgetChatConversations[rawToken];
    final timeline = _widgetChatTimeline;
    if (entry == null ||
        timeline == null ||
        !_widgetOwnsChatScope(entry.scope)) {
      throw StateError('stale');
    }
    return (rawToken, entry.scope, _widgetChatTimelineGeneration, timeline);
  }

  bool _widgetSelectionCurrent(
    String token,
    ConversationScope scope,
    int generation,
    ConversationTimelineController timeline,
  ) =>
      _widgetChatAllowed &&
      generation == _widgetChatTimelineGeneration &&
      token == _widgetSelectedChatToken &&
      identical(timeline, _widgetChatTimeline) &&
      _widgetChatConversations[token]?.scope == scope &&
      _widgetOwnsChatScope(scope);

  void _requireWidgetReady() {
    if (!_widgetChatBaseAllowed) throw StateError('locked');
    if (!_widgetChatCaptureGranted) throw StateError('consent_required');
  }

  /// Retire the widget-specific view after the native companion disconnects.
  /// The installation-level capture choice remains in place.
  void retireWidgetOverlaySession() {
    _widgetChatConsentPending = false;
    _widgetChatConsentRequest = null;
    _retireWidgetChatSession();
    if (!_disposed) notifyListeners();
  }

  Future<Map<String, Object?>> _sendWidgetChat(
    Map<String, dynamic> args,
  ) async {
    final (token, scope, generation, timeline) = _requireWidgetSelection(
      args['token'],
    );
    if (args['conversation'] != token) throw StateError('stale');
    final text = args['text'];
    if (text is! String ||
        text.trim().isEmpty ||
        text.length > TimelineWireContract.maxTextCodeUnits ||
        sendingChatMessage ||
        _widgetSendBusy ||
        const {
          ComposerSendStatus.pending,
          ComposerSendStatus.unknown,
        }.contains(_widgetSendResults[scope]?.status) ||
        appearOffline ||
        (!scope.isGroup && _directPeerClosed(scope.peerId))) {
      throw StateError('refused');
    }
    final operation =
        args['operationId'] is String &&
            RichContentWire.validOperation(args['operationId'])
        ? args['operationId'] as String
        : _newWidgetOperationId();
    if (sendJournal.record(operation) != null) throw StateError('duplicate');
    _widgetSendBusy = true;
    sendingChatMessage = true;
    notifyListeners();
    final record = SendJournalRecord(
      operationId: operation,
      scope: scope,
      status: ComposerSendStatus.pending,
    );
    try {
      if (!await sendJournal.prepare(record)) {
        throw StateError('journal_failed');
      }
      if (!_widgetSelectionCurrent(token, scope, generation, timeline) ||
          appearOffline ||
          (!scope.isGroup && _directPeerClosed(scope.peerId))) {
        await sendJournal.complete(
          operation,
          scope,
          ComposerSendStatus.failedBeforeCommit,
        );
        await sendJournal.acknowledge(operation);
        throw StateError('stale');
      }
    } catch (_) {
      _widgetSendBusy = false;
      sendingChatMessage = false;
      if (!_disposed) notifyListeners();
      return {
        'ok': false,
        'operationId': operation,
        'status': ComposerSendStatus.failedBeforeCommit.name,
      };
    }
    _widgetSendResults[scope] = record;
    _runInBackground(
      _completeWidgetChat(
        record,
        text,
        token,
        generation,
        timeline,
        _accountRevision,
      ),
      'widget send',
    );
    return {'ok': true, 'operationId': operation, 'status': 'pending'};
  }

  Future<void> _completeWidgetChat(
    SendJournalRecord record,
    String text,
    String token,
    int generation,
    ConversationTimelineController timeline,
    int accountRevision,
  ) async {
    final operation = record.operationId;
    final scope = record.scope;
    try {
      String admission;
      try {
        admission = await jami
            .sendOwnedMessage(
              accountId: scope.accountId,
              peerJamiId: scope.peerId,
              conversationId: scope.conversationId,
              mimeType: TimelineWireContract.textMimeType,
              body: scope.isGroup
                  ? GroupTopicCodec.encode('general', text)
                  : text,
              operationId: operation,
              roomId: scope.isGroup ? 'general' : '',
            )
            .timeout(const Duration(seconds: 30), onTimeout: () => 'unknown');
      } catch (_) {
        admission = 'unknown';
      }
      if (admission != 'pending') {
        await sendJournal.complete(
          operation,
          scope,
          admission == 'failed-before-commit'
              ? ComposerSendStatus.failedBeforeCommit
              : ComposerSendStatus.unknown,
        );
      }
      final result =
          await sendJournal.wait(operation) ??
          (_widgetSendResults[scope]?.operationId == operation
              ? _widgetSendResults[scope]
              : null) ??
          record.withOutcome(ComposerSendStatus.unknown, null);
      if (scope.accountId == accountId && accountRevision == _accountRevision) {
        _widgetSendResults[scope] = result;
      }
      if (result.status == ComposerSendStatus.committed ||
          result.status == ComposerSendStatus.failedBeforeCommit) {
        await sendJournal.acknowledge(operation);
      }
      if (!_disposed) notifyListeners();
      if (result.status == ComposerSendStatus.committed &&
          _widgetSelectionCurrent(token, scope, generation, timeline)) {
        _runInBackground(timeline.refresh(), 'widget committed history');
      }
    } finally {
      _widgetSendBusy = false;
      sendingChatMessage = false;
      if (!_disposed) notifyListeners();
    }
  }

  String _newWidgetOperationId() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  WidgetVoiceTarget _widgetTarget(
    Map<String, WidgetVoiceTarget> targets, {
    required String kind,
    required String identity,
    ConversationScope? scope,
    String? roomId,
  }) {
    for (final target in targets.values) {
      if (target.accountRevision == _accountRevision &&
          target.kind == kind &&
          target.identity == identity &&
          target.scope == scope &&
          target.roomId == roomId) {
        return target;
      }
    }
    final target = WidgetVoiceTarget(
      token: createWidgetToken(),
      kind: kind,
      accountRevision: _accountRevision,
      identity: identity,
      scope: scope,
      roomId: roomId,
    );
    targets[target.token] = target;
    return target;
  }

  bool? _remoteVoiceSpeaking(CallSession session) {
    return widgetRemoteSpeakingAt(
      level: session.remoteVoiceLevel,
      sampledAt: session.remoteVoiceMeterAt,
      now: DateTime.now(),
    );
  }

  Map<String, Object?> _widgetVoiceSnapshot(String chatStatus) {
    if (chatStatus != 'ready' || !_widgetChatAllowed) {
      _widgetVoiceTargets.clear();
      _widgetDirectCallTargets.clear();
      _widgetGroupCallTargets.clear();
      _widgetGroupRoomTargets.clear();
      _widgetActiveVoiceToken = null;
      _widgetActiveVoiceIdentity = null;
      return {
        'status': chatStatus,
        'token': '',
        'kind': 'none',
        'phase': 'idle',
        'participants': const <Map<String, Object?>>[],
        'offers': const <Map<String, Object?>>[],
        'muted': null,
        'canMute': false,
        'deafened': null,
        'canDeafen': false,
        'canLeave': false,
      };
    }

    final keepDirect = <String, WidgetVoiceTarget>{};
    final keepGroup = <String, WidgetVoiceTarget>{};
    final keepRooms = <String, WidgetVoiceTarget>{};
    final direct = call;
    final directFriend = direct == null ? null : _friends[direct.peerId];
    if (direct != null &&
        directFriend?.confirmed == true &&
        !_directPeerClosed(direct.peerId)) {
      final target = _widgetTarget(
        _widgetDirectCallTargets,
        kind: 'direct-call',
        identity: direct.callId,
        scope: _scopeForPeer(direct.peerId),
      );
      keepDirect[target.token] = target;
    }
    final group = groupCall;
    if (group != null && _groups[group.conversationId] != null) {
      final scope = _scopeForGroup(group.conversationId);
      if (scope != null) {
        final target = _widgetTarget(
          _widgetGroupCallTargets,
          kind: 'group-call',
          identity: group.conferenceId,
          scope: scope,
          roomId: group.roomId,
        );
        keepGroup[target.token] = target;
      }
    }
    for (final state in _groups.values) {
      if (!state.activeMemberIds.contains(jamiId)) continue;
      final scope = _scopeForGroup(state.conversationId);
      if (scope == null) continue;
      for (final room in state.layout.rooms.where(
        (room) => room.kind == GroupRoomKind.voice,
      )) {
        final target = _widgetTarget(
          _widgetGroupRoomTargets,
          kind: 'group-room',
          identity: '${scope.conversationId}/${room.id}',
          scope: scope,
          roomId: room.id,
        );
        keepRooms[target.token] = target;
      }
    }
    _widgetDirectCallTargets
      ..clear()
      ..addAll(keepDirect);
    _widgetGroupCallTargets
      ..clear()
      ..addAll(keepGroup);
    _widgetGroupRoomTargets
      ..clear()
      ..addAll(keepRooms);
    _widgetVoiceTargets
      ..clear()
      ..addAll(keepDirect)
      ..addAll(keepGroup)
      ..addAll(keepRooms);

    final active = direct != null && keepDirect.isNotEmpty
        ? _widgetDirectCallTargets.values.first
        : group != null && keepGroup.isNotEmpty
        ? _widgetGroupCallTargets.values.first
        : null;
    final voiceIdentity = active == null
        ? null
        : '${active.kind}/${active.identity}/${active.accountRevision}';
    if (voiceIdentity != _widgetActiveVoiceIdentity) {
      _widgetActiveVoiceIdentity = voiceIdentity;
      _widgetActiveVoiceToken = active?.token;
    }

    if (direct != null && keepDirect.isNotEmpty) {
      final peerName = peerDisplayName(direct.peerId);
      return {
        'status': 'ready',
        'token': _widgetActiveVoiceToken ?? '',
        'kind': 'direct',
        'phase': direct.state.toLowerCase(),
        'participants': [
          {
            'id': 'local',
            'name': displayName.trim().isEmpty ? 'You' : displayName.trim(),
            'muted': direct.micMuted,
            'speaking': direct.localVoiceActive,
          },
          {
            'id': 'remote',
            'name': peerName,
            'muted': null,
            'speaking': _remoteVoiceSpeaking(direct),
          },
        ],
        'offers': _widgetVoiceOffers(),
        'muted': direct.micMuted,
        'canMute': direct.connected && !direct.microphoneTeardownPending,
        'canAnswer':
            direct.dir == CallDir.incoming &&
            !direct.everConnected &&
            !_terminal.contains(direct.state),
        'canDecline':
            direct.dir == CallDir.incoming &&
            !direct.everConnected &&
            !_terminal.contains(direct.state),
        'deafened': null,
        'canDeafen': false,
        'canLeave': true,
      };
    }
    if (group != null && keepGroup.isNotEmpty) {
      final state = _groups[group.conversationId];
      final members = groupVoiceParticipants(
        group.conversationId,
        group.roomId,
      );
      return {
        'status': 'ready',
        'token': _widgetActiveVoiceToken ?? '',
        'kind': 'group',
        'phase': group.phase.name,
        'participants': [
          for (final member in members)
            {
              'id': member.accountId == jamiId ? 'local' : member.accountId,
              'name': member.accountId == jamiId
                  ? (displayName.trim().isEmpty ? 'You' : displayName.trim())
                  : (state?.memberDisplayNames[member.accountId]
                                ?.trim()
                                .isNotEmpty ==
                            true
                        ? state!.memberDisplayNames[member.accountId]!.trim()
                        : 'Group member'),
              'muted': member.muted,
              'speaking': member.speaking,
            },
        ],
        'offers': _widgetVoiceOffers(),
        'muted': group.micMuted,
        'canMute': group.connected,
        'deafened': group.deafened,
        'canDeafen': group.connected,
        'canLeave': true,
      };
    }
    _widgetActiveVoiceIdentity = null;
    _widgetActiveVoiceToken = null;
    return {
      'status': 'ready',
      'token': '',
      'kind': 'none',
      'phase': 'idle',
      'participants': const <Map<String, Object?>>[],
      'offers': _widgetVoiceOffers(),
      'muted': null,
      'canMute': false,
      'deafened': null,
      'canDeafen': false,
      'canLeave': false,
    };
  }

  List<Map<String, Object?>> _widgetVoiceOffers() => [
    for (final target in _widgetGroupRoomTargets.values)
      {
        'id': target.token,
        'kind': 'group',
        'label':
            _groups[target.scope?.conversationId]?.layout
                .room(target.roomId ?? '')
                ?.name ??
            'Voice chat',
      },
  ];

  WidgetVoiceTarget _requireWidgetVoiceTarget(Object? rawToken) {
    _requireWidgetReady();
    if (rawToken is! String) throw StateError('invalid');
    _widgetVoiceSnapshot('ready');
    final target = _widgetVoiceTargets[rawToken];
    if (target == null ||
        target.accountRevision != _accountRevision ||
        (target.scope != null && !_widgetOwnsScope(target.scope!))) {
      throw StateError('stale');
    }
    return target;
  }

  Future<Map<String, Object?>> _widgetMute(
    Object? rawToken,
    Object? muted,
  ) async {
    if (muted is! bool) throw StateError('invalid');
    final target = _requireWidgetVoiceTarget(rawToken);
    if (target.kind == 'direct-call') {
      final session = call;
      if (session == null ||
          session.callId != target.identity ||
          !session.connected) {
        throw StateError('stale');
      }
      if (session.manuallyMuted != muted) {
        final owner = _microphoneAccountOwner;
        session.manualMuteRevision++;
        session.manuallyMuted = muted;
        notifyListeners();
        await _applyMicrophoneProjection(session);
        if (!_widgetChatAllowed ||
            owner != _microphoneAccountOwner ||
            !identical(call, session) ||
            session.manuallyMuted != muted) {
          throw StateError('stale');
        }
      }
      return {'ok': session.micMuted == muted, 'muted': session.micMuted};
    }
    if (target.kind == 'group-call') {
      final session = groupCall;
      if (session == null || session.conferenceId != target.identity) {
        throw StateError('stale');
      }
      await setGroupMicMuted(muted);
      if (!_widgetChatAllowed || !identical(groupCall, session)) {
        throw StateError('stale');
      }
      return {'ok': session.micMuted == muted, 'muted': session.micMuted};
    }
    throw StateError('refused');
  }

  Future<Map<String, Object?>> _widgetDeafen(
    Object? rawToken,
    Object? deafened,
  ) async {
    if (deafened is! bool) throw StateError('invalid');
    final target = _requireWidgetVoiceTarget(rawToken);
    if (target.kind != 'group-call') throw StateError('refused');
    final session = groupCall;
    if (session == null || session.conferenceId != target.identity) {
      throw StateError('stale');
    }
    await setGroupDeafened(deafened);
    if (!_widgetChatAllowed || !identical(groupCall, session)) {
      throw StateError('stale');
    }
    return {'ok': session.deafened == deafened, 'deafened': session.deafened};
  }

  Future<Map<String, Object?>> _widgetLeaveVoice(Object? rawToken) async {
    final target = _requireWidgetVoiceTarget(rawToken);
    if (target.kind == 'direct-call') {
      final session = call;
      if (session == null || session.callId != target.identity) {
        throw StateError('stale');
      }
      await hangUp();
      return {'ok': true, 'requested': true};
    }
    if (target.kind == 'group-call') {
      final session = groupCall;
      if (session == null || session.conferenceId != target.identity) {
        throw StateError('stale');
      }
      await leaveGroupVoice();
      return {'ok': true, 'requested': true};
    }
    throw StateError('refused');
  }

  Future<Map<String, Object?>> _widgetAnswer(Object? rawToken) async {
    final target = _requireWidgetVoiceTarget(rawToken);
    final session = call;
    if (target.kind != 'direct-call' ||
        session == null ||
        session.callId != target.identity ||
        session.dir != CallDir.incoming ||
        _directPeerClosed(session.peerId)) {
      throw StateError('stale');
    }
    await answer(session);
    if (!_widgetChatAllowed || !identical(call, session)) {
      throw StateError('stale');
    }
    return {'ok': true, 'phase': session.state.toLowerCase()};
  }

  Future<Map<String, Object?>> _widgetDecline(Object? rawToken) async {
    final target = _requireWidgetVoiceTarget(rawToken);
    final session = call;
    if (target.kind != 'direct-call' ||
        session == null ||
        session.callId != target.identity ||
        session.dir != CallDir.incoming) {
      throw StateError('stale');
    }
    await decline(session);
    return {'ok': call?.callId != session.callId, 'requested': true};
  }

  Future<Map<String, Object?>> _widgetStartVoice(Object? rawToken) async {
    _requireWidgetReady();
    if (rawToken is! String) throw StateError('invalid');
    _widgetReconcileConversations();
    final scope = _widgetChatConversations[rawToken]?.scope;
    if (scope == null || !_widgetOwnsScope(scope)) {
      throw StateError('refused');
    }
    if (scope.isGroup) throw StateError('use_group_voice_join');
    _runInBackground(startCallTo(scope.peerId), 'widget start voice');
    return {
      'ok': call?.peerId == scope.peerId || placing,
      'phase': call?.state.toLowerCase() ?? 'placing',
    };
  }

  Future<Map<String, Object?>> _widgetJoinVoice(Object? rawToken) async {
    final target = _requireWidgetVoiceTarget(rawToken);
    if (target.kind != 'group-room' || target.scope == null) {
      throw StateError('refused');
    }
    final group = _groups[target.scope!.conversationId];
    final room = group?.layout.room(target.roomId ?? '');
    if (group == null || room == null || room.kind != GroupRoomKind.voice) {
      throw StateError('stale');
    }
    _runInBackground(joinGroupVoice(group, room), 'widget join voice');
    return {
      'ok':
          _groupJoinOperation != null ||
          groupCall?.conversationId == group.conversationId &&
              groupCall?.roomId == room.id,
      'requested': true,
      'phase': groupCall?.phase.name ?? 'joining',
    };
  }

  /// The selected conversation exists but is still arriving from the peer,
  /// typically for a couple of seconds right after a friend request is
  /// accepted. Shown as preparation, retried automatically.
  bool get chatPreparing {
    final timeline = _conversationTimeline;
    if (timeline == null || !identical(timeline, _notReadyTimeline)) {
      return false;
    }
    // Sticky across retries: a retry clears the error while it loads, and
    // the panel must not flicker between "preparing" and "loading".
    return (timeline.lastError is TimelineNotReadyException ||
            timeline.isLoading) &&
        _notReadyRetries < _maxNotReadyRetries;
  }

  static const int _maxNotReadyRetries = 30;
  static const Duration _notReadyRetryDelay = Duration(seconds: 2);
  int _notReadyRetries = 0;
  Timer? _notReadyRetry;
  ConversationTimelineController? _notReadyTimeline;

  void _scheduleNotReadyRetry() {
    final timeline = _conversationTimeline;
    if (timeline != null &&
        identical(timeline, _notReadyTimeline) &&
        !timeline.isLoading &&
        timeline.lastError == null) {
      _notReadyTimeline = null; // it loaded
    }
    if (timeline == null ||
        timeline.lastError is! TimelineNotReadyException ||
        _notReadyRetry != null) {
      return;
    }
    if (!identical(timeline, _notReadyTimeline)) {
      _notReadyTimeline = timeline;
      _notReadyRetries = 0;
    }
    if (_notReadyRetries >= _maxNotReadyRetries) return;
    _notReadyRetry = Timer(_notReadyRetryDelay, () {
      _notReadyRetry = null;
      if (_disposed ||
          !identical(_conversationTimeline, timeline) ||
          timeline.lastError is! TimelineNotReadyException) {
        return;
      }
      _notReadyRetries++;
      _runInBackground(timeline.refresh(), 'loadChat(not ready, retry)');
    });
  }

  int get chatRejectedItemCount =>
      _conversationTimeline?.rejectedItemCount ?? 0;

  @visibleForTesting
  ConversationTimelineController? get conversationTimelineForTesting =>
      _conversationTimeline;
  bool sendingChatMessage = false;
  final Set<(ConversationScope, String)> _reactionSends = {};
  late final SendJournal sendJournal;
  final Set<String> _reconcilingSendIds = {};
  final Set<String> _repairingSeeds = {};
  String? chatError;
  bool _timelineRefreshQueued = false;
  ConversationScope? _queuedTimelineRefreshScope;
  bool _syncedTimelinesRefreshQueued = false;
  bool _syncedTimelinesRefreshAgain = false;
  Timer? _syncedTimelinesRefreshCooldown;
  int _syncedTimelinesRefreshEpoch = 0;

  /// The peer dot (presence v2). Green/dim ONLY on END-TO-END evidence: a pong (or any authenticated
  /// x-sybl-presence message from the peer), a live P2P channel (presence status 2), or an incoming call.
  /// NEVER from the DHT beacon alone (proxy-held ~24 h stale — status 1 only triggers a verify) and NEVER
  /// from the daemon's SENT ack (a LOCAL socket write that "succeeds" into a zombie channel — the audited
  /// false-green bug). Each friend's [FriendState.peerFgTs] guards stale queued redeliveries
  /// (peer-clock monotonic — same-clock comparison, device skew can't bite).
  PeerPresence peerPresence = PeerPresence.unknown;
  bool get peerOnline =>
      peerPresence == PeerPresence.reachable ||
      peerPresence == PeerPresence.inApp;

  /// M7: "appear offline" — when true the account is DISABLED daemon-side (`Account.enable`, persisted in the
  /// account config). In steady state it boots dark; this separate pref mirrors/re-asserts the choice, so a
  /// pref/native-config divergence can briefly queue peer work before re-disable. While dark you are unreachable AND blind (no Jami
  /// connected-but-invisible state); the founder owns the feel.
  bool appearOffline = false;
  bool _changingAppearOffline = false;
  bool _appearOfflineCacheNeedsReload = false;
  bool _appearOfflineNeedsReconciliation = false;
  String? _appearOfflinePersistenceWarning;
  bool get changingAppearOffline => _changingAppearOffline;

  /// M7: connection profile — 'lan' | 'jami' | 'strict'. Selects which servers (if any) help us reach the peer.
  /// Invalid persisted labels canonicalize to 'jami'; every account adoption reapplies the selected policy before
  /// the home screen can expose account-backed UI.
  String connectionProfile = 'jami';
  bool _changingConnectionProfile = false;
  bool _connectionProfileCacheNeedsReload = false;
  bool _connectionProfileNeedsReconciliation = false;
  String? _connectionProfilePersistenceWarning;
  bool get changingConnectionProfile => _changingConnectionProfile;
  bool _backgroundWakeAvailable = false;
  bool _backgroundWakeApplied = false;
  bool googleWakeCleanupPending = false;
  (String?, int)? _backgroundWakeAppliedOwner;
  int _backgroundWakeApplyRevision = 0;
  int _backgroundWakePreferenceRevision = 0;

  /// Strict-mode host fields (self-hosted dhtnode + optional coTURN). Current code only reads preseeded preferences;
  /// it has no writer/UI. A blank bootstrap is replaced natively with unreachable 192.0.2.1 and fails closed.
  String strictBootstrap = '';
  String strictTurnServer = '';
  String strictTurnRealm = 'ring';
  String strictTurnUser = '';
  String strictTurnPassword = '';

  /// Pending inbound friend and group requests. Jami consumes a trusted contact's 1:1 request before this callback,
  /// so every request that reaches Syb-L still needs an explicit decision. Requests queue here one card at a
  /// time — [pendingConnect] is the head. (The native replay-on-attach can re-emit SEVERAL still-pending requests;
  /// a single-slot field silently dropped all but the last, so they're queued and surfaced in turn as each is
  /// allowed/ignored. Realistically rare for a 2-sibling app, but no request is lost now.)
  final List<({String convId, String fromJamiId, bool isGroup})>
  _pendingConnects = [];
  static const int _maxPendingConnects = 64;

  /// Unverified request names by peer, process-local only (never persisted). A
  /// real profile name always wins; the hint is dropped once one arrives.
  final Map<String, String> _nameHints = {};
  static const int _maxNameHints = 64;
  void _rememberNameHint(String peerId, String? hint) {
    if (hint == null) return;
    _nameHints.remove(peerId);
    _nameHints[peerId] = hint;
    if (_nameHints.length > _maxNameHints) {
      _nameHints.remove(_nameHints.keys.first);
    }
  }

  /// The unverified request name for [peerId], or null.
  String? nameHint(String peerId) => _nameHints[peerId];
  ({String convId, String fromJamiId, bool isGroup})? get pendingConnect =>
      _pendingConnects.isEmpty ? null : _pendingConnects.first;

  /// M7.5 (d, review-fold) — convIds the user has already allowed/ignored. The native replay-on-attach
  /// (SetEventSink re-emits the still-pending native map) can re-surface a request AFTER we've dequeued it but
  /// BEFORE the native side erases it — and the queue-membership dedup gives zero protection in exactly that
  /// window. This makes the Dart side idempotent regardless of native erase timing (covers both platforms; the
  /// Android worker-thread erase is wide). Bounded; convIds are per-request so a genuinely new request still gates.
  final Set<String> _handledConnects = {};
  void _markConnectHandled(String cid) {
    _handledConnects.add(cid);
    if (_handledConnects.length > 64) {
      _handledConnects.remove(_handledConnects.first);
    }
  }

  /// True while an allow/ignore is in flight — debounces a double-tap that would otherwise dequeue+decide the NEXT
  /// queued stranger (a trust regression). Mirrors the [backingUp] guard.
  bool _handlingConnect = false;
  bool get handlingConnect => _handlingConnect;
  bool get speakerControlAvailable =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Desktop picks an output device instead of toggling speaker/earpiece.
  bool get outputPickerAvailable =>
      defaultTargetPlatform == TargetPlatform.windows;

  Future<List<String>> audioOutputs() async {
    if (!outputPickerAvailable) return const [];
    try {
      return await jami.audioOutputs();
    } catch (error) {
      dlog('audioOutputs failed: $error');
      return const [];
    }
  }

  Future<void> selectAudioOutput(int index) async {
    if (!outputPickerAvailable || index < 0) return;
    try {
      await jami.setAudioOutput(index);
    } catch (error) {
      dlog('setAudioOutput($index) failed: $error');
    }
  }

  Future<List<String>> audioInputs() async {
    if (!outputPickerAvailable) return const [];
    try {
      return await jami.audioInputs();
    } catch (error) {
      dlog('audioInputs failed: $error');
      return const [];
    }
  }

  Future<void> selectAudioInput(int index) async {
    if (!outputPickerAvailable || index < 0) return;
    try {
      await jami.setAudioInput(index);
    } catch (error) {
      dlog('setAudioInput($index) failed: $error');
    }
  }

  /// DEBUG (diagnostics): a rolling log of every daemon event + the connection actions we drive — so the Diagnostics
  /// screen can show "what it's trying" (registration transitions, presence, call/connection attempts). Newest first,
  /// capped. Purely in-memory; not persisted. `· ` = an inbound event, `→ ` = an action we initiated.
  final List<String> debugLog = [];
  void dlog(String line) {
    final n = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    // Milliseconds: call glare is decided inside a single second on both endpoints, so second resolution cannot
    // order the two traces against each other.
    final stamp =
        '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${n.millisecond.toString().padLeft(3, '0')}';
    debugLog.insert(0, '$stamp  ${diagnosticLabel(line)}');
    if (debugLog.length > 300) debugLog.removeRange(300, debugLog.length);
  }

  void _onEventError(Object error, StackTrace stackTrace) {
    dlog('event stream error: $error');
    remoteControl.hostChannelFailed();
    notifyListeners();
  }

  /// Consume failures from fire-and-forget work instead of leaking a global async error.
  void _runInBackground<T>(Future<T> future, String operation) {
    unawaited(() async {
      try {
        await future;
      } catch (e) {
        dlog('$operation failed: $e');
      }
    }());
  }

  void clearDebugLog() {
    debugLog.clear();
    notifyListeners();
  }

  CallSession? call;
  GroupCallSession? groupCall;
  final GroupCallPresenceBook _groupCallPresence = GroupCallPresenceBook();
  final Stopwatch _groupCallClock = Stopwatch()..start();
  Future<int>? _groupVideoTextureFuture;
  Timer? _groupCallPresenceTimer;
  Timer? _groupCallExpiryTimer;
  Timer? _groupCallRecoveryTimer;
  int _groupCallPresenceSequence = 0;

  void _ensureGroupCallExpiryTimer() {
    _groupCallExpiryTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      final changed = _groupCallPresence.prune(
        nowMs: _groupCallClock.elapsedMilliseconds,
      );
      if (_groupCallPresence.isEmpty) {
        _groupCallExpiryTimer?.cancel();
        _groupCallExpiryTimer = null;
      }
      if (changed) notifyListeners();
    });
  }

  List<GroupRoomParticipant> groupVoiceParticipants(
    String conversationId,
    String roomId,
  ) {
    final remote = _groupCallPresence.participants(
      conversationId,
      roomId,
      nowMs: _groupCallClock.elapsedMilliseconds,
    );
    final local = groupCall;
    if (local == null ||
        local.conversationId != conversationId ||
        local.roomId != roomId ||
        jamiId.isEmpty) {
      return remote;
    }
    return [
      ...remote.where((participant) => participant.accountId != jamiId),
      GroupRoomParticipant(
        accountId: jamiId,
        muted: local.micMuted,
        deafened: local.deafened,
        video: local.video,
        screenShare: local.screenShare,
        speaking: local.speaking,
      ),
    ];
  }

  static const MicrophonePolicy _inactiveMicrophonePolicy = MicrophonePolicy(
    effectiveMode: EffectiveMicrophoneMode(
      mode: MicrophoneMode.open,
      source: MicrophoneModeSource.globalDefault,
    ),
    sessionActive: false,
    privacySuspended: false,
    manuallyMuted: false,
    pushToTalkPressed: false,
  );

  int _microphoneGeneration = 0;
  (String?, int) get _microphoneAccountOwner => (accountId, _accountRevision);
  bool _microphoneControlsFocused = true;
  Future<void> _microphoneCommandTail = Future.value();

  /// High-frequency audio-layer level for the small local mic indicator.
  /// This notifier deliberately avoids rebuilding the entire app at meter
  /// cadence.
  final ValueNotifier<double> voiceMeter = ValueNotifier(0);
  double get voiceMeterLevel => voiceMeter.value;
  bool _audioMeterEnabled = false;
  MicrophoneDecision microphoneDecision = _inactiveMicrophonePolicy.evaluate();
  String? microphoneError;

  /// Same-peer rings hidden behind the one-call UI while the visible leg is still pre-CURRENT. No command is sent
  /// before a winner exists. A terminal on the visible leg promotes the oldest still-live ring; a CURRENT winner
  /// retires every sibling instead so an old glare leg cannot ring again after the connected call ends.
  final Map<String, ({String peerId, bool withVideo})> _pendingIncomingCalls =
      {};

  /// Outgoing ids returned by native after a same-peer incoming ring took the one visible slot mid-placement. They
  /// are deliberately left alone until libjami selects a CURRENT winner, then every non-winner is hung up. Android
  /// placement is intent-first (no pre-dial camera wait), so the ring-predates-outgoing-call window is now only
  /// permission-dialog/dispatch wide — this stays as the defensive cover for whatever still slips through it.
  final Set<String> _unresolvedOutgoingCallIds = {};

  /// Candidates already retired after a CURRENT winner, kept until their terminal callback. A late CURRENT for a
  /// loser must be ended again and ignored—not adopted after the winner has returned the UI to Home.
  final Map<String, CallDir> _retiredGlareCallIds = {};

  /// The first admitted trusted-friend leg that reached CURRENT. This is separate from [call]: the visible session can be
  /// replaced while glare is being resolved, but a second CURRENT must never replace the established winner.
  /// Cleared only by that winner's terminal callback (or peer/app teardown).
  String? _establishedCallId;

  /// Terminal call IDs observed while a native placement reply is outstanding. A terminal callback can beat that
  /// reply even when an incoming winner already occupies [call], so the ordinary early-event buffer is insufficient.
  final Set<String> _terminalCallIdsDuringPlacement = {};

  /// First CURRENT observed while an outgoing placement reply is outstanding. It survives that winner's terminal
  /// event until the reply arrives, so a slow camera placement cannot become a fresh call after its winner ended.
  String? _winnerCallIdDuringPlacement;

  /// Set when a call ends badly (failed/busy); the UI shows it once then clears it. Null = nothing to show.
  String? callEndedNote;
  StreamSubscription<JamiEvent>? _sub;

  /// Native call callbacks can beat the `placeCall` MethodChannel reply. Buffer them until the outgoing session
  /// exists so a fast CURRENT/FAILURE cannot be discarded and leave a phantom CONNECTING call.
  final List<JamiEvent> _earlyOutgoingCallEvents = [];
  // cameraState is buffered too: intent-first placement can fail capture (and report camera-off)
  // before the placeCall reply installs the session — dropping it would leave a false cameraOn.
  static const _earlyOutgoingCallEventTypes = {
    'callState',
    'cameraFacing',
    'video',
    'peerVideo',
    'cameraState',
    'outgoingVideoSource',
  };
  Future<int>? _selfTextureFuture;
  Future<int>? _remoteTextureFuture;
  bool _disposed = false;
  int _peerGeneration = 0;
  final Map<String, Object> _friendRemovalOperations = {};
  bool _settingPeer = false;

  // ---- file transfer (M5) ----

  bool get canCaptureComposerPhoto =>
      Platform.isAndroid &&
      call == null &&
      groupCall == null &&
      _groupJoinOperation == null &&
      !placing &&
      !appearOffline;

  bool get canRecordComposerVoice =>
      (Platform.isAndroid || Platform.isWindows) &&
      call == null &&
      groupCall == null &&
      _groupJoinOperation == null &&
      !placing &&
      !appearOffline &&
      !_disposed;

  bool get canPlayMessageMedia =>
      !_disposed &&
      _foreground &&
      accountId != null &&
      !_restoringIdentity &&
      !_protectedSurfaceLocked &&
      !captureGateVisible &&
      !_captureBusy &&
      settingsWritable &&
      call == null &&
      groupCall == null &&
      _groupJoinOperation == null &&
      !placing;

  /// Revalidate native completion on every play/resume. A cached path or byte
  /// count never authorizes decoding a received voice/GIF file.
  Future<bool> validateTimelineMedia(TimelineFileItem item, String path) async {
    final owner = conversationActionOwner;
    bool current() =>
        canPlayMessageMedia &&
        conversationActionOwner == owner &&
        selectedConversationScope == item.scope &&
        _conversationTimeline?.items.any((candidate) => candidate == item) ==
            true;
    final media = item.media;
    if (!current() || media == null) return false;
    try {
      Future<Map<String, dynamic>> receipt() => jami.fileInfo(
        item.scope.peerId,
        item.scope.conversationId,
        item.fileId,
      );
      bool matches(Map<String, dynamic> value) =>
          value['completed'] == true &&
          value['path'] == path &&
          value['total'] == item.totalBytes;
      if (!matches(await receipt()) || !current()) return false;
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final verified = media is VoiceMediaContent
          ? await validateComposerVoice(path, item.totalBytes ?? -1)
          : await validateComposerGif(path, item.totalBytes ?? -1);
      if (!current() || verified?.mediaMetadata != media.encode()) return false;
      return matches(await receipt()) && current();
    } catch (_) {
      return false;
    }
  }

  Future<bool> validateCompletedAudio(
    String peer,
    String conversation,
    String fileId,
    String path,
  ) async {
    final owner = conversationActionOwner;
    final scope = selectedConversationScope;
    bool current() =>
        canPlayMessageMedia &&
        conversationActionOwner == owner &&
        selectedConversationScope == scope;
    if (!current() ||
        scope == null ||
        scope.peerId != peer ||
        scope.conversationId != conversation) {
      return false;
    }
    try {
      final info = await jami.fileInfo(peer, conversation, fileId);
      return current() &&
          info['completed'] == true &&
          info['path'] == path &&
          await FileSystemEntity.type(path, followLinks: false) ==
              FileSystemEntityType.file &&
          current();
    } catch (_) {
      return false;
    }
  }

  Future<GifLibraryResult> saveReceivedGif(
    TimelineFileItem item,
    String path,
  ) async {
    final owner = conversationActionOwner;
    bool current() =>
        canPlayMessageMedia &&
        conversationActionOwner == owner &&
        selectedConversationScope == item.scope &&
        _conversationTimeline?.items.any((candidate) => candidate == item) ==
            true;
    final media = item.media;
    if (!current() ||
        item.direction != TimelineDirection.incoming ||
        !item.mayContainGif) {
      return GifLibraryResult.invalid;
    }
    Future<bool> completed() async {
      final receipt = await jami.fileInfo(
        item.scope.peerId,
        item.scope.conversationId,
        item.fileId,
      );
      return current() &&
          receipt['completed'] == true &&
          receipt['path'] == path &&
          receipt['total'] == item.totalBytes;
    }

    try {
      if (!await completed()) return GifLibraryResult.invalid;
      // import reads a bounded independent copy, never renames/deletes a seed.
      // Recheck native completion after decoding and before index publication.
      return await gifLibrary.import(
        path,
        bundledHashes: (await bundledStarterGifs)
            .map((entry) => entry.hash)
            .toSet(),
        isCurrent: current,
        authorize: (entry) async =>
            current() &&
            entry.bytes == item.totalBytes &&
            (media == null || entry.media.encode() == media.encode()) &&
            await completed(),
      );
    } catch (_) {
      return GifLibraryResult.unavailable;
    }
  }

  VoiceRecorder createComposerRecorder(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    VoiceCaptureDevice? device,
  }) {
    final owner = conversationActionOwner;
    final scope = draft.key.scope;
    return VoiceRecorder(
      device: device ?? PlatformVoiceCapture(),
      isCurrent: () =>
          canRecordComposerVoice &&
          conversationActionOwner == owner &&
          selectedConversationScope == scope &&
          draft.owns(operation),
      prepare: () => jami.prepareVoiceRecording(
        accountId: scope.accountId,
        peerJamiId: scope.peerId,
        conversationId: scope.conversationId,
      ),
      renew: jami.renewVoiceRecording,
      discard: jami.discardPickedFile,
    );
  }

  Future<ComposerPreparationResult> prepareComposerVoice(
    ComposerDraftSession draft,
    ComposerOperation operation,
    VoiceRecorder recorder,
  ) {
    final owner = conversationActionOwner;
    return ComposerMediaPreparer(discard: jami.discardPickedFile).prepare(
      draft: draft,
      operation: operation,
      isCurrent: () =>
          !_disposed &&
          !appearOffline &&
          conversationActionOwner == owner &&
          selectedConversationScope == draft.key.scope,
      produce: recorder.stop,
      kind: ComposerMediaKind.voice,
      maxBytes: ValidatedVoice.maximumBytes,
      validate: validateComposerVoice,
    );
  }

  Future<ComposerPreparationResult> prepareComposerPhoto(
    ComposerDraftSession draft,
    ComposerOperation operation,
  ) {
    final owner = conversationActionOwner;
    return ComposerMediaPreparer(discard: jami.discardPickedFile).prepare(
      draft: draft,
      operation: operation,
      isCurrent: () =>
          !_disposed &&
          canCaptureComposerPhoto &&
          conversationActionOwner == owner &&
          selectedConversationScope == draft.key.scope,
      produce: () => jami.captureComposerPhoto(draft.key.scope.accountId),
      kind: ComposerMediaKind.photo,
      maxBytes: 4 * 1024 * 1024,
    );
  }

  Future<ComposerPreparationResult> prepareComposerFile(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    bool gif = false,
    String? libraryHash,
    StarterGif? starterGif,
  }) async {
    final owner = conversationActionOwner;
    String? usedHash;
    final result = await ComposerMediaPreparer(discard: jami.discardPickedFile)
        .prepare(
          draft: draft,
          operation: operation,
          isCurrent: () =>
              !_disposed &&
              conversationActionOwner == owner &&
              selectedConversationScope == draft.key.scope,
          produce: () => starterGif != null
              ? jami.stageStarterGif(starterGif.id)
              : libraryHash != null
              ? jami.stageGifLibraryEntry(libraryHash)
              : jami.pickFile(
                  mimeType: gif ? 'image/gif' : '*/*',
                  maxBytes: gif
                      ? ValidatedGif.maximumBytes
                      : JamiClient.maxPickedFileBytes,
                ),
          maxBytes: gif
              ? ValidatedGif.maximumBytes
              : JamiClient.maxPickedFileBytes,
          validate: gif
              ? (path, size) async {
                  final stage = await validateComposerGif(
                    path,
                    size,
                    expectedHash: starterGif?.hash,
                  );
                  if (stage == null ||
                      _disposed ||
                      conversationActionOwner != owner ||
                      !draft.owns(operation)) {
                    return null;
                  }
                  if (starterGif != null) {
                    usedHash = starterGif.hash;
                    return stage;
                  }
                  if (libraryHash != null) {
                    usedHash = libraryHash;
                    return await gifLibrary.matchesCopy(libraryHash, path)
                        ? stage
                        : null;
                  }
                  usedHash = stage.contentHash;
                  final imported = await gifLibrary.import(
                    path,
                    bundledHashes: (await bundledStarterGifs)
                        .map((entry) => entry.hash)
                        .toSet(),
                    isCurrent: () =>
                        !_disposed &&
                        conversationActionOwner == owner &&
                        draft.owns(operation),
                  );
                  return imported == GifLibraryResult.saved ||
                          imported == GifLibraryResult.alreadyBundled
                      ? stage
                      : null;
                }
              : null,
        );
    if (result == ComposerPreparationResult.staged &&
        usedHash != null &&
        conversationActionOwner == owner &&
        selectedConversationScope == draft.key.scope) {
      await gifLibrary.recordUsed(usedHash!);
    }
    return result;
  }

  Future<SendJournalRecord?> sendComposerFile(
    ComposerDraftSession draft,
    ComposerOperation operation, {
    bool asHologram = false,
  }) async {
    final scope = selectedConversationScope;
    final owner = conversationActionOwner;
    final stage = operation.stage;
    if (scope == null ||
        scope != draft.key.scope ||
        (!scope.isGroup && _directPeerClosed(scope.peerId)) ||
        !draft.owns(operation) ||
        operation.kind != ComposerOperationKind.sendMedia ||
        stage == null ||
        !identical(draft.media, stage) ||
        (stage.kind != ComposerMediaKind.file &&
            stage.kind != ComposerMediaKind.photo &&
            stage.kind != ComposerMediaKind.sticker &&
            stage.kind != ComposerMediaKind.gif &&
            stage.kind != ComposerMediaKind.voice) ||
        sendingChatMessage ||
        appearOffline) {
      return null;
    }
    if (_dmTopicSelectionPending(scope) ||
        (!scope.isGroup &&
            !_loadedDmTopicScopes.contains(scope) &&
            draft.key.topic != DmTopicWire.mainId)) {
      _reportDmTopicPending();
      return null;
    }
    final topic = scope.isGroup ? '' : draft.key.topic;
    final room = scope.isGroup ? draft.key.topic : '';
    if (stage.kind == ComposerMediaKind.sticker) {
      if (!RichContentWire.validAsset(stage.assetId)) return null;
      if (asHologram &&
          (scope.isGroup ||
              _hologramManifest?.byId(stage.assetId!)?.hologramEligible !=
                  true)) {
        return null;
      }
      return sendOwnedContent(
        StickerContent(
          stage.assetId!,
          asHologram
              ? StickerPresentation.hologram
              : StickerPresentation.inline,
        ).encode(),
        mimeType: RichContentWire.stickerMime,
        operationId: operation.id,
        roomId: room,
      );
    }
    if (stage.path == null) return null;
    if (stage.kind == ComposerMediaKind.gif &&
        (FileMediaContent.parse(stage.mediaMetadata) is! GifMediaContent ||
            stage.encodedBytes > ValidatedGif.maximumBytes)) {
      return null;
    }
    sendingChatMessage = true;
    chatError = null;
    notifyListeners();
    try {
      if (stage.kind == ComposerMediaKind.voice) {
        ComposerMediaStage? verified;
        try {
          if (await FileSystemEntity.type(stage.path!, followLinks: false) ==
              FileSystemEntityType.file) {
            verified = await validateComposerVoice(
              stage.path!,
              stage.encodedBytes,
            );
          }
        } catch (_) {
          // Invalid or replaced private stages never enter native publication.
        }
        if (verified == null || verified.mediaMetadata != stage.mediaMetadata) {
          chatError =
              'This voice recording is no longer valid. Record it again.';
          return null;
        }
      }
      if (_disposed ||
          appearOffline ||
          conversationActionOwner != owner ||
          !draft.owns(operation) ||
          !identical(draft.media, stage)) {
        return null;
      }
      if (!await sendJournal.prepare(
        SendJournalRecord(
          operationId: operation.id,
          scope: scope,
          status: ComposerSendStatus.pending,
          stageReference: operation.id,
        ),
      )) {
        return null;
      }
      if (_disposed ||
          appearOffline ||
          conversationActionOwner != owner ||
          !draft.owns(operation)) {
        await sendJournal.complete(
          operation.id,
          scope,
          ComposerSendStatus.failedBeforeCommit,
        );
        return sendJournal.record(operation.id);
      }
      String admission;
      try {
        admission = await jami.sendOwnedFile(
          accountId: scope.accountId,
          peerJamiId: scope.peerId,
          conversationId: scope.conversationId,
          path: stage.path!,
          name: stage.label,
          operationId: operation.id,
          topicId: topic,
          roomId: room,
          media: stage.mediaMetadata ?? '',
        );
      } catch (_) {
        admission = 'unknown';
      }
      if (admission != 'pending') {
        await sendJournal.complete(
          operation.id,
          scope,
          admission == 'failed-before-commit'
              ? ComposerSendStatus.failedBeforeCommit
              : ComposerSendStatus.unknown,
        );
      }
      final result = await sendJournal.wait(operation.id);
      if (result?.status == ComposerSendStatus.committed) {
        _wakeConversationOwner((
          peerId: scope.peerId,
          conversationId: scope.conversationId,
        ));
        await _conversationTimelines[scope]?.refresh();
      } else if (conversationActionOwner == owner) {
        chatError = result?.status == ComposerSendStatus.failedBeforeCommit
            ? 'The file was not committed. You can try again.'
            : 'The file send outcome is not yet known. Keep this draft; do not resend it.';
      }
      return result;
    } finally {
      sendingChatMessage = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Active + recent transfers, keyed by their full daemon owner tuple. A bare fileId is not globally unique
  /// across friends or swarms; using it alone lets one friend's callbacks mutate another friend's row.
  Map<TransferKey, FileXfer> get transfers => _fileTransfers.transfers;
  bool get sendingFile => _fileTransfers.sendingFile;

  // ---- file-keeping (M6) ----
  /// Persistent shared-folder views keyed by full daemon owner tuple. Each friend has one canonical 1:1
  /// conversation selected by the native routing snapshot; changing the selected row changes only what the UI
  /// renders, not who owns already-loaded entries.
  Map<TransferKey, FolderFile> get folder => _fileTransfers.folder;

  /// Creates the initial runtime snapshot for isolated widget tests.
  ///
  /// Production relationship state always comes from libjami through
  /// [_refreshFriendsFromDaemon], and production folder state always comes
  /// from correlated native events. This one-shot fixture boundary preserves
  /// those ownership invariants without exposing mutable collection setters.
  @visibleForTesting
  void seedEmptyRuntimeSnapshotForTesting({
    required Iterable<FriendState> friends,
    String? selectedPeerId,
    Iterable<GroupState> groups = const <GroupState>[],
    String? selectedFixtureGroupId,
    Iterable<FolderFile> folderEntries = const <FolderFile>[],
  }) {
    if (_friends.isNotEmpty ||
        _groups.isNotEmpty ||
        peerId != null ||
        selectedGroupId != null ||
        transfers.isNotEmpty ||
        folder.isNotEmpty) {
      throw StateError('runtime fixture state must start empty');
    }

    final stagedFriends = <String, FriendState>{};
    for (final friend in friends) {
      if (friend.peerId.isEmpty ||
          (friend.confirmed && friend.conversationId.isEmpty)) {
        throw ArgumentError.value(friend, 'friends', 'invalid friend owner');
      }
      if (stagedFriends.containsKey(friend.peerId)) {
        throw ArgumentError.value(friend, 'friends', 'duplicate peer id');
      }
      stagedFriends[friend.peerId] = friend;
    }
    final stagedGroups = <String, GroupState>{};
    for (final group in groups) {
      if (group.conversationId.isEmpty ||
          stagedGroups.containsKey(group.conversationId)) {
        throw ArgumentError.value(group, 'groups', 'invalid group owner');
      }
      stagedGroups[group.conversationId] = group;
    }
    if ((selectedPeerId == null) == (selectedFixtureGroupId == null)) {
      throw ArgumentError(
        'exactly one fixture friend or group must be selected',
      );
    }
    if (selectedPeerId != null && !stagedFriends.containsKey(selectedPeerId)) {
      throw ArgumentError.value(
        selectedPeerId,
        'selectedPeerId',
        'must identify a fixture friend',
      );
    }
    if (selectedFixtureGroupId != null &&
        !stagedGroups.containsKey(selectedFixtureGroupId)) {
      throw ArgumentError.value(
        selectedFixtureGroupId,
        'selectedFixtureGroupId',
        'must identify a fixture group',
      );
    }

    final stagedFolder = folderEntries.toList(growable: false);
    for (final entry in stagedFolder) {
      final direct = stagedFriends[entry.peerId];
      final group = stagedGroups[entry.conversationId];
      final isOwnedDirect =
          direct != null &&
          direct.confirmed &&
          direct.conversationId == entry.conversationId;
      final isOwnedGroup =
          group != null &&
          group.ownerKey == entry.peerId &&
          group.conversationId == entry.conversationId;
      if (!isOwnedDirect && !isOwnedGroup) {
        throw ArgumentError.value(
          entry,
          'folderEntries',
          'must belong to an owned fixture conversation',
        );
      }
    }

    _friends.addAll(stagedFriends);
    _friendsAccountOwner = (accountId, _accountRevision);
    _groups.addAll(stagedGroups);
    peerId = selectedPeerId;
    selectedGroupId = selectedFixtureGroupId;
    peerPresence = selectedPeerId == null
        ? PeerPresence.unknown
        : stagedFriends[selectedPeerId]!.presence;
    _fileTransfers.reconcileOwners(<TransferOwner>[
      ...stagedFriends.values
          .where((friend) => friend.confirmed)
          .map(
            (friend) =>
                (peerId: friend.peerId, conversationId: friend.conversationId),
          ),
      ...stagedGroups.values.map(
        (group) =>
            (peerId: group.ownerKey, conversationId: group.conversationId),
      ),
    ]);
    _reconcileDmTopicScopes();
    // This method is itself the app-level @visibleForTesting boundary; the
    // controller hook stays hidden from every production call path.
    // ignore: invalid_use_of_visible_for_testing_member
    _fileTransfers.seedEmptyFolderProjectionForTesting(stagedFolder);
    notifyListeners();
  }

  /// RETENTION KNOB (M6): how many of the most-recent swarm COMMITS to scan when rebuilding the folder — an upper
  /// bound on file history surfaced by that rebuild, not a cap on later live
  /// in-memory entries. `loadConversation` counts swarm commits of every type,
  /// so this is a scan-depth control rather than an exact file count.
  /// Non-destructive "keep last N": it bounds the VIEW over the git-backed
  /// swarm; it does NOT delete swarm data or evict file bytes. The bounded
  /// value comes from the one versioned [AppSettings] document.
  int get folderKeepLast => appSettings.folderHistoryLimit;

  /// SECURITY KNOB (M7.5 f / audit L1): the largest incoming file we'll accept. An unbounded transfer can fill the
  /// disk (a buggy or malicious peer), so we reject on accept (the declared size) AND abort mid-transfer (the actual
  /// bytes, in case a peer under-declares). 0 = no cap. The bounded value comes from [AppSettings]; only incoming
  /// transfers are capped — our own outgoing files are never limited.
  int get maxIncomingFileBytes => appSettings.maxIncomingFileBytes;

  // ---- annotation / draw overlay (M8 — remote-help v1) ----
  /// The live "draw over the video" overlay + its in-call draw protocol. Strokes travel over the in-call side
  /// channel (ephemeral, P2P) and are call-scoped — [AnnotationController.reset] drops them when the call ends.
  final AnnotationController annotation = AnnotationController();

  Future<void> init() {
    final current = _initializationInFlight;
    if (current != null) return current;
    late final Future<void> attempt;
    attempt = _initializeGuarded().whenComplete(() {
      if (identical(_initializationInFlight, attempt)) {
        _initializationInFlight = null;
      }
    });
    _initializationInFlight = attempt;
    return attempt;
  }

  Future<void> _initializeGuarded() async {
    try {
      if (_disposed) return;
      bootErrorDetails = null;
      _bootStep = 'Preparing app settings';
      if (resetDoorlightPending || resetDoorlightRestartRequired) {
        screen = Screen.loading;
        bootError = resetDoorlightRestartRequired
            ? _resetCompleteMessage
            : 'Reset was interrupted. Finish resetting Doorlight before using it.';
        notifyListeners();
        return;
      }
      bootError = null;
      notifyListeners();
      if (!_startupPrepared) {
        if (_reloadPreferencesBeforeStartup) {
          await prefs.reload();
          _reloadPreferencesBeforeStartup = false;
        }
        await _prepareStartup();
        if (_disposed) return;
        _startupPrepared = true;
      }
      await _bootGuarded();
      if (!_disposed && accountId != null) {
        _bootStep = 'Applying background availability settings';
        await _applyBackgroundWakePreference();
      }
    } catch (error) {
      if (_disposed) return;
      dlog('startup preparation failed: $error');
      bootError = "Couldn't prepare app settings. Please try again.";
      bootErrorDetails = _describeBootFailure(error);
      screen = Screen.loading;
      notifyListeners();
    }
  }

  Future<void> _prepareStartup() async {
    await sendJournal.initialized;
    if (_disposed) return;
    // Install the persisted account gate before EventChannel attaches. Native can synchronously replay the account
    // it selected during daemon boot; when ensureAccount is about to switch to a different persisted identity,
    // that replay must not transiently create calls/presence for the wrong account.
    accountId = prefs.getString('accountId');
    if (!_runtimeAttached) {
      WidgetsBinding.instance.addObserver(this);
      _sub = jami.events().listen(
        _onEvent,
        onError: _onEventError,
        onDone: remoteControl.hostChannelFailed,
      );
      _runtimeAttached = true;
      unawaited(remoteControl.initializeHostAuthority());
    }
    try {
      _stageInvite(await jami.takeInitialInviteLink());
    } catch (_) {
      dlog('Could not read the launch invitation.');
    }
    if (_disposed) return;
    try {
      final launch = await jami.takeInitialConversation();
      if (launch != null) _pendingConversationLaunch = launch;
    } catch (error) {
      dlog('takeInitialConversation failed: $error');
    }
    if (_disposed) return;
    displayName =
        ProfileWireContract.decodeDisplayName(
          prefs.getString('displayName'),
        )?.trim() ??
        '';
    profileAvatarBase64 =
        ProfileWireContract.decodeAvatar(
          prefs.getString('profileAvatarBase64'),
        ) ??
        '';
    // A launch always opens on the people list. The legacy peer pointer stays
    // in preferences only as an account-adoption hint; it is not UI selection.
    selectedGroupId = null;
    peerId = null;
    await _persistConversationSelection(conversationActionOwner);
    if (_disposed) return;
    appearOffline = prefs.getBool('appearOffline') ?? false;
    final storedConnectionProfile = prefs.getString('connectionProfile');
    connectionProfile = _canonicalConnectionProfile(storedConnectionProfile);
    if (storedConnectionProfile != null &&
        storedConnectionProfile != connectionProfile) {
      await prefs.setString('connectionProfile', connectionProfile);
    }
    if (_disposed) return;
    strictBootstrap = prefs.getString('strictBootstrap') ?? '';
    strictTurnServer = prefs.getString('strictTurnServer') ?? '';
    strictTurnRealm = prefs.getString('strictTurnRealm') ?? 'ring';
    strictTurnUser = prefs.getString('strictTurnUser') ?? '';
    strictTurnPassword = prefs.getString('strictTurnPassword') ?? '';
    try {
      _windowCaptureProtection = await jami.windowCaptureProtectionStatus();
    } catch (error) {
      _windowCaptureProtection = WindowCaptureProtectionStatus.unavailable;
      dlog('window capture protection query failed: $error');
    }
    if (_disposed) return;
    // Lift the launch-time protection unless a sensitive surface is up.
    surfaceProtection.refresh();
    try {
      remoteControlAccessibilityEnabled = await jami
          .remoteControlAccessibilityEnabled();
    } catch (error) {
      dlog('remote control accessibility query failed: $error');
    }
    if (_disposed) return;
    final settingsDocumentPresent = prefs.containsKey(
      _SharedPreferencesAppSettingsDocumentStore.documentKey,
    );
    final appLockLatch = _appLockLatchRepository.read();
    var settingsDocumentLoaded = false;
    try {
      Object? migrationWriteFailure;
      appSettings = await _settingsRepository.load(
        onMigrationWriteFailure: (error) => migrationWriteFailure = error,
      );
      settingsDocumentLoaded = true;
      _microphoneSettingsKnown =
          settingsDocumentPresent && migrationWriteFailure == null;
      _settingsDocumentWritable = true;
      settingsError = migrationWriteFailure == null
          ? null
          : 'App settings were loaded, but their format update could not be saved.';
      if (migrationWriteFailure != null) {
        dlog('settings migration write failed: $migrationWriteFailure');
      }
    } catch (error) {
      // A corrupt or future-version document must not brick account boot and
      // must not be silently overwritten with defaults.
      _settingsDocumentWritable = false;
      _microphoneSettingsKnown = false;
      settingsError = 'Could not load app settings: $error';
      dlog('settings load failed: $error');
    }
    if (_disposed) return;
    final resolvedAppLock = resolveAppLockAtBoot(
      latch: appLockLatch,
      settingsDocumentPresent: settingsDocumentPresent,
      settingsDocumentLoaded: settingsDocumentLoaded,
      legacySettingsEnabled: appSettings.appLockEnabled,
    );
    appSettings = appSettings.withAppLockEnabled(resolvedAppLock);
    try {
      _backgroundWakeAvailable = await jami.backgroundWakeAvailability();
    } catch (error) {
      _backgroundWakeAvailable = false;
      dlog('background wake availability failed: $error');
    }
    if (_disposed) return;
    _runInBackground(
      jami.setMessageNotificationPreview(
        appSettings.showMessageInNotification,
        appLockEnabled: resolvedAppLock,
      ),
      'setMessageNotificationPreview(boot)',
    );
    if (appLockLatch == AppLockLatchStatus.corrupt) {
      _appendSettingsError(
        'The app-lock policy was unreadable, so Doorlight stayed locked.',
      );
    }
    if (appLockLatch == AppLockLatchStatus.absent ||
        appLockLatch == AppLockLatchStatus.corrupt) {
      try {
        await _appLockLatchRepository.save(resolvedAppLock);
      } catch (error) {
        _appendSettingsError('The app-lock policy could not be made durable.');
        dlog('app-lock latch migration failed: $error');
      }
    }
    // Settings (or their conservative defaults after a load failure) are
    // resolved above. Windows either confirms the durable visibility opt-out
    // or applies protection before the real surface. A later OBS output event
    // may replace that surface with the data-free consent prompt.
    if (_disposed) return;
    await _resolveCaptureConsentAtBoot();
  }

  void _appendSettingsError(String message) {
    final prior = settingsError;
    settingsError = prior == null || prior.isEmpty
        ? message
        : '$prior $message';
  }

  /// Run [_boot] with the failure made visible: a daemon-boot error (e.g. `ensureAccount` coming back null over
  /// the bridge and failing the Map cast) used to kill init() as an uncaught async error — a splash stranded
  /// forever with no trace. Now it lands in [bootError] and the splash offers a retry.
  Future<void> _bootGuarded() {
    final current = _bootInFlight;
    if (current != null) return current;
    late final Future<void> attempt;
    attempt = _runBootGuarded().whenComplete(() {
      if (identical(_bootInFlight, attempt)) _bootInFlight = null;
    });
    _bootInFlight = attempt;
    return attempt;
  }

  Future<void> _runBootGuarded() async {
    try {
      bootError = null;
      bootErrorDetails = null;
      profileProtectionUnavailable = false;
      notifyListeners();
      await _boot();
    } catch (e) {
      dlog('boot failed: $e');
      profileProtectionUnavailable =
          e is PlatformException && e.code == 'archive_protection_failed';
      bootError = profileProtectionUnavailable
          ? "Couldn't open the saved profile."
          : pendingIdentityRecovery
          ? identityRecoveryTitle
          : "Couldn't start the engine.";
      bootErrorDetails = _describeBootFailure(e);
      // A fresh UI in a retired process: no in-process retry can succeed.
      if (e is PlatformException && e.code == 'relaunch_required') {
        screen = Screen.loading;
        if (e.details == 'reset') {
          resetDoorlightRestartRequired = true;
          _restoringIdentity = true;
          bootError = _resetCompleteMessage;
        } else {
          _engineRelaunchRequired = true;
          bootError = Platform.isWindows
              ? "Couldn't start the engine. Quit Doorlight, then open it again."
              : "Couldn't start the engine. Restart Doorlight to try again.";
        }
      }
    }
    notifyListeners();
  }

  /// Retry a failed boot (the splash's "try again").
  Future<void> retryBoot() => init();

  Future<void> _boot() async {
    _bootStep = 'Opening the saved profile';
    if (_restoringIdentity) throw StateError('Identity restore is in progress');
    if (_identityMutationBusy) {
      throw StateError('An app settings operation is in progress');
    }
    pendingIdentityRecovery = false;
    _identityRecoveryReason = null;
    _discardableIdentityRestore = null;
    final owner = (accountId, _accountRevision);
    retireHistorySearch();
    _restoringIdentity = true;
    _refreshHologramPrivacy();
    try {
      final pending = await jami.getPendingIdentityRestore();
      if (_disposed || owner != (accountId, _accountRevision)) return;
      final status = pending['status'];
      if (status == 'archiveProtectionUnavailable') {
        throw PlatformException(code: 'archive_protection_failed');
      }
      if (status == 'engineUnavailable') {
        throw PlatformException(
          code:
              pending['relaunchRequired'] == true ||
                  pending['recoveryReason'] == 'restartRequired'
              ? 'relaunch_required'
              : 'native_startup_failed',
        );
      }
      if (status == 'recoveryRequired' ||
          (status == 'prepared' && pending['devicePairing'] != true)) {
        pendingIdentityRecovery = true;
        _identityRecoveryReason = status == 'prepared'
            ? 'preparationFailed'
            : switch (pending['recoveryReason']) {
                'journalUnreadable' => 'journalUnreadable',
                'ownershipUnclear' => 'ownershipUnclear',
                'importIncomplete' => 'importIncomplete',
                'rollbackPending' => 'rollbackPending',
                'preparationFailed' => 'preparationFailed',
                _ => null,
              };
        if (pending['restartRequired'] == true) _engineRelaunchRequired = true;
        final target = pending['accountId'];
        final token = pending['restoreToken'];
        if (pending['canDiscard'] == true &&
            !relaunchRequired &&
            target is String &&
            target.isNotEmpty &&
            token is String &&
            token.isNotEmpty &&
            pending['devicePairing'] != true) {
          _discardableIdentityRestore = (
            target,
            token,
            pending['recoveryOwnerAccountId'] is String
                ? pending['recoveryOwnerAccountId'] as String
                : null,
          );
        }
      }
      if ((status == 'pairing' || pending['devicePairing'] == true) &&
          devicePairing.restoreFromJournal(pending)) {
        screen = Screen.onboarding;
        return;
      } else if (status == 'prepared') {
        _bootStep = 'Finishing the prepared identity restore';
        await _finishPreparedIdentityRestore(pending, owner: owner);
        pendingIdentityRecovery = false;
        _identityRecoveryReason = null;
        _discardableIdentityRestore = null;
      } else if (status != 'none') {
        throw StateError(
          pendingIdentityRecovery
              ? 'The pending identity restore needs recovery'
              : 'The native startup response was not recognized',
        );
      }
    } finally {
      _restoringIdentity = devicePairingPending;
      if (!_disposed) {
        _runInBackground(
          _applySettingsToActiveCall(),
          'microphone after restore check',
        );
      }
    }
    // One atomic daemon operation distinguishes an existing account from an
    // account-less install. Boot can adopt, but only onboarding may create.
    _bootStep = 'Opening your profile and applying its settings';
    if (await _adoptAccount(displayName.isNotEmpty ? displayName : 'Me')) {
      screen = Screen.home;
      _bootStep = 'Loading your friends';
      await _refreshFriendsFromDaemon();
      _resumePendingRemovals();
      _runInBackground(refreshArchivedChats(), 'refreshArchivedChats(boot)');
      final launch = _pendingConversationLaunch;
      _pendingConversationLaunch = null;
      if (launch != null) {
        _bootStep = 'Opening the requested conversation';
        await _openConversationLaunch(launch);
      }
      // presence v2: assert our fg stamp before the first ping/pong can carry it (the native default is
      // foreground=true, so this is a boot-order formality — but cheap and explicit).
      _runInBackground(jami.setForeground(true), 'setForeground(boot)');
      _runInBackground(_applyPresenceMetadata(), 'setPresenceMetadata(boot)');
      if (_friends.isNotEmpty) {
        _runInBackground(
          jami.setPresenceSubscriptions(_friends.keys),
          'setPresenceSubscriptions(boot)',
        );
        // Cold start shows unknown-until-proven: the daemon will replay a cached/proxy-held "available" for a
        // peer that's been gone for hours (its announcement is proxy-held ~24 h), so actively verify NOW instead
        // of trusting the echo. The dot moves only on the pong / a live channel / a verdict timeout.
        _runInBackground(_presence.refreshAll(), 'refreshPresence(boot)');
        loadFolder(); // rebuild the persistent shared folder from the swarm history (survives restart)
      } else {
        // No selected-friend pointer, but the daemon account exists — e.g. a wipe→restore cleared prefs while the
        // imported account kept its contacts. Recover every friend from daemon truth and select a stable fallback.
        _runInBackground(_hydratePeerFromDaemon(), 'hydratePeer(boot)');
      }
    } else {
      screen = Screen.onboarding;
    }
  }

  /// Toggle "appear offline" (go dark / re-announce). The daemon persists `Account.enable`; the separate preference
  /// mirrors the desired UI state and is reconciled at boot.
  Future<void> setAppearOffline(bool on) async {
    if (!canChangeOnlineStatus ||
        (on == appearOffline && !_appearOfflineNeedsReconciliation)) {
      return;
    }
    final owner = (accountId, _accountRevision);
    final previous = appearOffline;
    final previousReady = ready;
    final friendsRevision = _friendsRevision;
    final projectedPresence =
        <String, ({FriendState previous, FriendState projected})>{};
    bool ownsChange() => !_disposed && owner == (accountId, _accountRevision);
    void saveWarning(String message) {
      _appearOfflinePersistenceWarning = message;
      settingsError = message;
    }

    _changingAppearOffline = true;
    try {
      // Rejected legacy writes pollute the cache; none may authorize going online.
      if (_appearOfflineCacheNeedsReload) {
        try {
          await prefs.reload();
        } catch (_) {
          if (ownsChange()) {
            saveWarning(
              'Could not read your saved online status. Restart Doorlight before trying again.',
            );
          }
          return;
        }
        if (!ownsChange()) return;
        _appearOfflineCacheNeedsReload = false;
      }
      bool saved;
      try {
        saved = await prefs.setBool('appearOffline', on);
      } catch (_) {
        saved = false;
      }
      if (!saved) {
        _appearOfflineCacheNeedsReload = true;
        if (!ownsChange()) return;
        try {
          await prefs.reload();
          if (!ownsChange()) return;
          _appearOfflineCacheNeedsReload = false;
        } catch (_) {
          if (!ownsChange()) return;
        }
        saveWarning(
          _appearOfflineCacheNeedsReload
              ? 'Could not save or reread your online status. Restart Doorlight before trying again.'
              : 'Could not save your online status. Your connection has not changed.',
        );
        return;
      }
      if (!ownsChange()) return;
      if (settingsError == _appearOfflinePersistenceWarning) {
        settingsError = null;
      }
      _appearOfflinePersistenceWarning = null;
      appearOffline = on;
      _syncNearby();
      dlog('→ setAppearOffline($on)');
      if (on) {
        // Going dark blinds every friend. Drop all dots to honest unknown instead of freezing stale readings.
        for (final entry in _friends.entries.toList(growable: false)) {
          final projected = entry.value.copyWith(
            presence: PeerPresence.unknown,
          );
          projectedPresence[entry.key] = (
            previous: entry.value,
            projected: projected,
          );
          _friends[entry.key] = projected;
        }
        peerPresence = PeerPresence.unknown;
        ready = false;
      }
      _syncPresenceRuntime();
      notifyListeners();
      if (on) await _applyBackgroundWakePreference();
      if (!ownsChange()) return;
      await jami.setAppearOffline(on, expectedAccountId: owner.$1);
      if (!ownsChange()) return;
      if (!on) await _applyBackgroundWakePreference();
      if (!ownsChange()) return;
      if (!on && _friends.isNotEmpty) {
        _runInBackground(
          jami.setPresenceSubscriptions(_friends.keys),
          'setPresenceSubscriptions(visible)',
        );
        _runInBackground(_presence.refreshAll(), 'refreshPresence(visible)');
      }
      _appearOfflineNeedsReconciliation = false;
    } catch (e) {
      if (!ownsChange()) return;
      _appearOfflineNeedsReconciliation = true;
      appearOffline = previous;
      // Undo only this attempt's presence projection. A newer friend snapshot,
      // removal, or presence update owns its own state and must stay intact.
      for (final entry in projectedPresence.entries) {
        if (identical(_friends[entry.key], entry.value.projected)) {
          _friends[entry.key] = entry.value.projected.copyWith(
            presence: entry.value.previous.presence,
          );
        }
      }
      peerPresence = selectedFriend?.presence ?? PeerPresence.unknown;
      if (_friendsRevision == friendsRevision) ready = previousReady;
      _syncRemoteControl();
      bool rolledBack;
      try {
        rolledBack = await prefs.setBool('appearOffline', previous);
      } catch (_) {
        rolledBack = false;
      }
      if (!rolledBack) _appearOfflineCacheNeedsReload = true;
      if (!ownsChange()) return;
      if (!rolledBack) {
        try {
          await prefs.reload();
          if (!ownsChange()) return;
          _appearOfflineCacheNeedsReload = false;
        } catch (_) {
          if (!ownsChange()) return;
        }
      }
      saveWarning(
        rolledBack
            ? 'Could not change your online status. Restart Doorlight to reconcile your connection.'
            : 'Could not change or restore your saved online status. Restart Doorlight before relying on your connection.',
      );
      _syncPresenceRuntime();
      dlog('setAppearOffline($on) failed: $e');
      notifyListeners();
    } finally {
      _changingAppearOffline = false;
      notifyListeners();
    }
  }

  // ---- presence v2: ping/pong end-to-end verification + the fg-aware dot (audit revamp, 2026-07-02) ----
  //
  // Serverless presence has no honest push for "gone": the DHT DeviceAnnouncement is proxy-held ~24 h, and the
  // daemon's SENT ack is a LOCAL socket write that "succeeds" into a zombie channel (unclean peer death leaves
  // one — dhtnet has no keepalive). So the probe is now a PING the peer's NATIVE bridge auto-PONGs: only the
  // pong (or a live status-2 channel event / an incoming ring) is liveness. An opted-in peer's fg flag
  // picks in-app (green) vs reachable (dim); without consent, the native bridge emits fg=0.
  //
  // Cadence: with activity sharing enabled, while the peer reads IN-APP and we're foreground, a sweep re-pings every [sweepEvery] — an unclean
  // exit (swipe-kill) shows within ~sweep+pongWindow. A pong-timeout also fires ONE rate-limited daemon beacon
  // (connectivitySweep) to put the zombie socket down so daemon state heals. Dim/grey get NO cadence: a
  // backgrounded phone gets zero traffic (battery courtesy — their resume announces itself), and pings to a
  // dead peer would rot in the daemon's no-cancel persistent retry queue (20 retries, survives restarts).
  bool _foreground =
      true; // resumed/inactive = visible enough to care; hidden/paused = don't probe
  bool _viewFocused = true;
  bool _protectedSurfaceLocked = false;
  late final PresenceCoordinator _presence;
  bool _presenceSharingSuppressed = false;
  Future<void> _presenceMetadataTail = Future<void>.value();
  Future<void> _activitySharingTransitionTail = Future<void>.value();
  int _activitySharingRevision = 0;
  Duration get sweepEvery => _presence.sweepEvery;
  set sweepEvery(Duration value) => _presence.sweepEvery = value;

  void _syncPresenceRuntime() {
    _presence.sync(
      peers: _friends.keys.where((id) => !_directPeerClosed(id)),
      foreground:
          _foreground &&
          appSettings.shareActivityPresence &&
          !_presenceSharingSuppressed,
      dark: appearOffline,
      callActive: call != null,
    );
  }

  void _setFriendPresence(String id, PeerPresence presence) {
    final friend = _friends[id];
    if (friend == null) return;
    if (friend.presence == presence) return;
    final next = friend.copyWith(presence: presence);
    _friends[id] = next;
    if (id == peerId) {
      peerPresence = next.presence;
    }
    notifyListeners();
    _syncPresenceRuntime();
  }

  void _friendPresenceEvidence(
    String id, {
    int? fg,
    int? ts,
    String platform = '',
    String activity = '',
    IdentityColor? identityColor,
  }) {
    final friend = _friends[id];
    if (friend == null) return;
    _presence.recordEvidence(id);
    var next = friend.presence == PeerPresence.inApp
        ? PeerPresence.inApp
        : PeerPresence.reachable;
    var nextTs = friend.peerFgTs;
    var nextPlatform = friend.presencePlatform;
    var nextActivity = friend.presenceActivity;
    var nextIdentityColor = friend.identityColor;
    if (fg != null && ts != null && (fg == 0 || fg == 1) && ts > nextTs) {
      nextTs = ts;
      next = fg == 1 ? PeerPresence.inApp : PeerPresence.reachable;
      nextPlatform = platform;
      nextActivity = activity;
      if (identityColor != null && identityColor != friend.identityColor) {
        nextIdentityColor = identityColor;
        _presenceColorCache.update(id, identityColor);
      }
    }
    _friends[id] = friend.copyWith(
      presence: next,
      peerFgTs: nextTs,
      presencePlatform: nextPlatform,
      presenceActivity: nextActivity,
      identityColor: nextIdentityColor,
    );
    if (id == peerId) {
      peerPresence = next;
    }
    notifyListeners();
    _syncPresenceRuntime();
  }

  /// Transport-verified evidence arrived (a ping/pong from the peer, a status-2 channel, an incoming ring).
  /// [fg]/[ts] come from a presence message; evidence without them keeps the current in-app/reachable reading.
  void _presenceEvidence({int? fg, int? ts}) {
    final selected = peerId;
    if (selected != null) _friendPresenceEvidence(selected, fg: fg, ts: ts);
  }

  Future<void> refreshPresence() async {
    if (!appSettings.shareActivityPresence || _presenceSharingSuppressed) {
      return;
    }
    final p = peerId;
    if (p != null) await _presence.refresh(p);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _microphoneControlsFocused = state == AppLifecycleState.resumed;
    if (!_microphoneControlsFocused) _releaseHeldMicrophones();
    // An unfocused desktop window can stay visible. On mobile, `inactive` is
    // already part of leaving the app and must not produce read receipts.
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final fg =
        state == AppLifecycleState.resumed ||
        (!mobile && state == AppLifecycleState.inactive);
    if (!fg) _devicePairing?.retire();
    if (fg != _foreground) {
      _foreground = fg;
      _syncNearby();
      _refreshHologramPrivacy();
      if (!fg) {
        if (mobile) _retireWidgetChatSession();
        retireHistorySearch();
        _releaseHeldMicrophones();
        // A stored selection is not proof that its conversation is on screen.
        // The visible pane must report itself again after resume.
        _visibleConversationPeerId = null;
        _visibleGroupTopicId = null;
        _visibleDmTopicId = null;
        _retireLocalComposerActivity();
        _clearRemoteComposerActivities();
      }
      _syncRemoteControl();
      // Stamp the native side FIRST so the auto-pong (and any ping we fire next) carries the new fg.
      _runInBackground(jami.setForeground(fg), 'setForeground($fg)');
      if (fg) {
        _runInBackground(
          _refreshRemoteControlAccessibilityStatus(),
          'remoteControlAccessibilityStatus(resume)',
        );
        _syncPresenceRuntime();
        _runInBackground(_presence.refreshAll(), 'refreshPresence(resume)');
      } else {
        _syncPresenceRuntime();
        if (appSettings.shareActivityPresence && !_presenceSharingSuppressed) {
          _runInBackground(
            _presence.announceBackground(),
            'probeReachable(background)',
          );
        }
      }
      notifyListeners();
      return;
    }
    // No foreground change (e.g. desktop inactive→resumed): refresh every non-green friend independently.
    if (state == AppLifecycleState.resumed) {
      _runInBackground(
        _refreshRemoteControlAccessibilityStatus(),
        'remoteControlAccessibilityStatus(resume)',
      );
      if (appSettings.shareActivityPresence && !_presenceSharingSuppressed) {
        for (final friend in _friends.values) {
          if (friend.presence != PeerPresence.inApp) {
            _presence.hint(friend.peerId);
          }
        }
      }
    }
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    final focused = event.state == ViewFocusState.focused;
    if (_viewFocused == focused) return;
    _viewFocused = focused;
    _devicePairing?.reconcile();
    if (focused) _markLatestIncomingDisplayed();
    notifyListeners();
  }

  /// Switch the connection profile ('lan' | 'jami' | 'strict'). Re-registers the account under the new config (the
  /// daemon does the re-register; no menu bounce). Persisted; the daemon also persists the underlying account config.
  Future<void> setConnectionProfile(String profile) async {
    if (!canChangeConnectionProfile ||
        (profile == connectionProfile &&
            !_connectionProfileNeedsReconciliation)) {
      return;
    }
    if (profile != 'lan' && profile != 'jami' && profile != 'strict') return;
    final owner = (accountId, _accountRevision);
    bool ownsChange() => !_disposed && owner == (accountId, _accountRevision);
    final previous = connectionProfile;
    void saveWarning(String message) {
      _connectionProfilePersistenceWarning = message;
      settingsError = message;
    }

    _changingConnectionProfile = true;
    try {
      // The legacy adapter changes its cache even when persistence fails.
      // A failed save must never authorize native network or wake changes.
      if (_connectionProfileCacheNeedsReload) {
        try {
          await prefs.reload();
        } catch (_) {
          if (ownsChange()) {
            saveWarning(
              'Could not read your saved connection profile. Restart Doorlight before trying again.',
            );
          }
          return;
        }
        if (!ownsChange()) return;
        _connectionProfileCacheNeedsReload = false;
      }
      bool saved;
      try {
        saved = await prefs.setString('connectionProfile', profile);
      } catch (_) {
        saved = false;
      }
      if (!saved) {
        _connectionProfileCacheNeedsReload = true;
        if (!ownsChange()) return;
        try {
          await prefs.reload();
          if (!ownsChange()) return;
          _connectionProfileCacheNeedsReload = false;
        } catch (_) {
          if (!ownsChange()) return;
        }
        saveWarning(
          _connectionProfileCacheNeedsReload
              ? 'Could not save or reread your connection profile. Restart Doorlight before trying again.'
              : 'Could not save your connection profile. Your connection profile has not changed.',
        );
        return;
      }
      if (!ownsChange()) return;
      if (settingsError == _connectionProfilePersistenceWarning) {
        settingsError = null;
      }
      _connectionProfilePersistenceWarning = null;
      connectionProfile = profile;
      dlog('→ setConnectionProfile($profile) — re-registering');
      notifyListeners();
      if (previous == 'jami' && profile != 'jami') {
        await _applyBackgroundWakePreference(profileOverride: profile);
      }
      if (!ownsChange()) return;
      await jami.setConnectionProfile(
        profile,
        expectedAccountId: owner.$1,
        dhtBootstrap: strictBootstrap,
        turnServer: strictTurnServer,
        turnRealm: strictTurnRealm,
        turnUser: strictTurnUser,
        turnPassword: strictTurnPassword,
      );
      if (!ownsChange()) return;
      if (profile == 'jami') await _applyBackgroundWakePreference();
      if (!ownsChange()) return;
      _connectionProfileNeedsReconciliation = false;
    } catch (e) {
      if (!ownsChange()) return;
      _connectionProfileNeedsReconciliation = true;
      connectionProfile = previous;
      bool rolledBack;
      try {
        rolledBack = await prefs.setString('connectionProfile', previous);
      } catch (_) {
        rolledBack = false;
      }
      if (!rolledBack) _connectionProfileCacheNeedsReload = true;
      if (!ownsChange()) return;
      if (!rolledBack) {
        try {
          await prefs.reload();
          if (!ownsChange()) return;
          _connectionProfileCacheNeedsReload = false;
        } catch (_) {
          if (!ownsChange()) return;
        }
      }
      saveWarning(
        rolledBack
            ? 'Could not change your connection profile. Restart Doorlight to reconcile your connection.'
            : 'Could not change or restore your saved connection profile. Restart Doorlight before relying on your connection.',
      );
      await _applyBackgroundWakePreference();
      if (!ownsChange()) return;
      dlog('setConnectionProfile($profile) failed: $e');
      notifyListeners();
    } finally {
      _changingConnectionProfile = false;
      notifyListeners();
    }
  }

  bool get _networkPolicyUncertain =>
      _appearOfflineCacheNeedsReload ||
      _connectionProfileCacheNeedsReload ||
      _appearOfflineNeedsReconciliation ||
      _connectionProfileNeedsReconciliation;

  Future<bool> _networkPolicyReadyForIdentityChange() async {
    final owner = (accountId, _accountRevision);
    bool ownsRead() => !_disposed && owner == (accountId, _accountRevision);
    if (!ownsRead() ||
        _appearOfflineNeedsReconciliation ||
        _connectionProfileNeedsReconciliation) {
      return false;
    }
    if (!_appearOfflineCacheNeedsReload &&
        !_connectionProfileCacheNeedsReload) {
      return true;
    }
    try {
      await prefs.reload();
      if (!ownsRead()) return false;
      if ((prefs.getBool('appearOffline') ?? false) != appearOffline ||
          _canonicalConnectionProfile(prefs.getString('connectionProfile')) !=
              connectionProfile) {
        return false;
      }
      _appearOfflineCacheNeedsReload = false;
      _connectionProfileCacheNeedsReload = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _adoptAccount(
    String name, {
    bool createIfMissing = false,
  }) async {
    if (_identityMutationBusy) {
      throw StateError('A network settings operation is in progress');
    }
    _adoptingAccount = true;
    final owner = (accountId, _accountRevision);
    try {
      if (!await _networkPolicyReadyForIdentityChange() ||
          _disposed ||
          owner != (accountId, _accountRevision)) {
        throw StateError('Restart Doorlight to reconcile your connection.');
      }
      return await _adoptAccountWhileOwned(
        name,
        createIfMissing: createIfMissing,
      );
    } finally {
      _adoptingAccount = false;
    }
  }

  Future<bool> _adoptAccountWhileOwned(
    String name, {
    required bool createIfMissing,
  }) async {
    final safeName = ProfileWireContract.decodeDisplayName(name.trim());
    if (safeName == null || safeName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Invalid display name');
    }
    final preferred = prefs.getString('accountId') ?? '';
    final r = await jami.ensureAccount(
      safeName,
      preferredAccountId: preferred,
      preferredPeerId: prefs.getString('peerId') ?? '',
      createIfMissing: createIfMissing,
    );
    if (_asString(r['status']) == 'noAccount') {
      // Native has confirmed absence; a retained preference is only a hint.
      accountId = null;
      peerId = null;
      jamiId = '';
      for (final key in ['accountId', 'peerId']) {
        if (!await prefs.remove(key)) {
          throw StateError('Missing account selection could not be cleared');
        }
      }
      return false;
    }
    await _installAccountResult(r, fallbackDisplayName: safeName);
    for (final record in sendJournal.repairable.toList()) {
      if (record.scope.accountId == accountId) {
        _runInBackground(_repairCommittedSeed(record), 'repairRetainedSeed');
      }
    }
    return true;
  }

  Future<void> _installAccountResult(
    Map<String, dynamic> r, {
    required String fallbackDisplayName,
  }) async {
    final status = _asString(r['status']);
    if (status != 'ok') {
      throw StateError('Native account operation failed: $status');
    }
    final selected = _asString(r['accountId']);
    final selectedJamiId = JamiIdentity.fingerprint(_asString(r['jamiId']));
    if (selected.isEmpty || selectedJamiId == null) {
      throw StateError('Native account result was incomplete');
    }
    final fallback = ProfileWireContract.decodeDisplayName(
      fallbackDisplayName,
    )?.trim();
    final nativeName = ProfileWireContract.decodeDisplayName(
      r['displayName'],
    )?.trim();
    if (r.containsKey('displayName') && nativeName == null) {
      throw StateError('Native account display name was invalid');
    }
    final nextDisplayName = nativeName?.isNotEmpty == true
        ? nativeName!
        : fallback;
    if (nextDisplayName == null || nextDisplayName.isEmpty) {
      throw StateError('Native account display name was incomplete');
    }

    final previousAccountId = accountId;
    final enabled = r['enabled'];
    if (enabled is! bool) {
      throw StateError('Native account enabled state was incomplete');
    }
    final nextAvatar = r.containsKey('avatarBase64')
        ? ProfileWireContract.decodeAvatar(r['avatarBase64']) ?? ''
        : previousAccountId == selected
        ? profileAvatarBase64
        : '';
    final nextReady = r['announced'] == true;
    final nextRegistration = _boundedRegistration(r['registration']);

    if (previousAccountId != selected) {
      if (previousAccountId != null) _retireSelectedTimeline();
      _retireDmTopicRuntime();
      _pendingConnects.clear();
      _handledConnects.clear();
      _nameHints.clear();
    }
    accountId = selected;
    final owner = (accountId, _accountRevision);
    void requireOwner() {
      if (_disposed || owner != (accountId, _accountRevision)) {
        throw StateError('Account changed during adoption');
      }
    }

    jamiId = selectedJamiId;
    displayName = nextDisplayName;
    profileAvatarBase64 = nextAvatar;
    ready = nextReady;
    registration = nextRegistration;
    // Reconcile the two non-atomic stores conservatively: native-dark wins,
    // while a persisted local dark choice is re-applied before Home.
    if (!enabled && !appearOffline) {
      appearOffline = true;
    }
    if (appearOffline) {
      ready = false;
      registration = 'UNREGISTERED';
    }
    annotation.bind(
      jamiId,
    ); // tag our annotation stroke ids so a keyframe merge never confuses the two sides
    await jami.setAppearOffline(appearOffline, expectedAccountId: selected);
    requireOwner();
    await jami.setConnectionProfile(
      connectionProfile,
      expectedAccountId: selected,
      dhtBootstrap: strictBootstrap,
      turnServer: strictTurnServer,
      turnRealm: strictTurnRealm,
      turnUser: strictTurnUser,
      turnPassword: strictTurnPassword,
    );
    requireOwner();
    final published = await jami.updateProfile(
      displayName: nextDisplayName,
      avatarBase64: '',
      fileType: '',
      flag: 0,
      expectedAccountId: selected,
    );
    requireOwner();
    if (!published) {
      throw StateError('Native profile publication was rejected');
    }
    await prefs.setString('accountId', selected);
    requireOwner();
    await prefs.setString('displayName', nextDisplayName);
    requireOwner();
    await prefs.setBool('appearOffline', appearOffline);
    requireOwner();
    if (profileAvatarBase64.isEmpty) {
      await prefs.remove('profileAvatarBase64');
    } else {
      await prefs.setString('profileAvatarBase64', profileAvatarBase64);
    }
    requireOwner();
    _runInBackground(_applyPresenceMetadata(), 'setPresenceMetadata(adopt)');
  }

  Future<void> onboard(String name) async {
    if (_identityMutationBusy || _networkPolicyUncertain) {
      throw StateError('A settings operation is in progress');
    }
    if (_restoringIdentity) throw StateError('Identity restore is in progress');
    // Explicit account setup establishes a canonical policy even when it is
    // the default. Ordinary boot never treats hidden read failure as absence.
    if (!await _saveAppSettings(appSettings)) {
      throw StateError('Could not save the initial microphone policy');
    }
    if (!await _adoptAccount(name, createIfMissing: true)) {
      throw StateError('Native account creation was rejected');
    }
    screen = Screen.home;
    notifyListeners();
  }

  Future<String?> pickProfileImage() => jami.pickFile(
    mimeType: 'image/*',
    maxBytes: JamiClient.maxProfileImageBytes,
  );

  Future<void> discardPickedFile(String path) => jami.discardPickedFile(path);

  Future<bool> updateDisplayName(String value) async {
    final next = value.trim();
    if (!_canEditProfile ||
        next.isEmpty ||
        ProfileWireContract.decodeDisplayName(next) == null) {
      return false;
    }
    if (next == displayName) return true;
    final owner = (accountId, _accountRevision);
    bool ownsChange() => !_disposed && owner == (accountId, _accountRevision);
    changingDisplayName = true;
    notifyListeners();
    try {
      final updated = await jami.updateProfile(
        displayName: next,
        avatarBase64: '',
        fileType: '',
        flag: 0,
        expectedAccountId: owner.$1,
      );
      if (!updated || !ownsChange()) return false;
      displayName = next;
      await prefs.setString('displayName', next);
      return ownsChange();
    } catch (error) {
      dlog('updateDisplayName failed: $error');
      return false;
    } finally {
      changingDisplayName = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> updateProfileAvatar(String? avatarBase64) async {
    if (!_canEditProfile) {
      return false;
    }
    final next = avatarBase64 ?? '';
    if (ProfileWireContract.decodeAvatar(next) == null) return false;
    final owner = (accountId, _accountRevision);
    bool ownsChange() => !_disposed && owner == (accountId, _accountRevision);
    changingProfileAvatar = true;
    notifyListeners();
    try {
      final updated = await jami.updateProfile(
        displayName: displayName,
        avatarBase64: next,
        fileType: next.isEmpty ? '' : 'JPEG',
        flag: next.isEmpty ? 2 : 1,
        expectedAccountId: owner.$1,
      );
      if (!updated || !ownsChange()) return false;
      profileAvatarBase64 = next;
      if (next.isEmpty) {
        await prefs.remove('profileAvatarBase64');
      } else {
        await prefs.setString('profileAvatarBase64', next);
      }
      return ownsChange();
    } catch (error) {
      dlog('updateProfileAvatar failed: $error');
      return false;
    } finally {
      changingProfileAvatar = false;
      if (!_disposed) notifyListeners();
    }
  }

  // ---- identity backup / restore (M7.5 a) ----

  /// True while a backup export is in flight (debounce the button).
  bool backingUp = false;
  String? backupFailureNotice;

  /// Back up the identity to a file protected by [passphrase] when non-empty.
  Future<bool> backupIdentity(String passphrase) async {
    if (backingUp || _restoringIdentity || accountId == null) {
      return false;
    }
    final owner = (accountId, _accountRevision);
    backingUp = true;
    backupFailureNotice = null;
    dlog('→ backupIdentity');
    notifyListeners();
    try {
      final settingsDocument = jsonEncode(
        const AppSettingsCodec().encode(appSettings),
      );
      final saved = await jami.backupIdentity(
        passphrase,
        settingsDocument: settingsDocument,
        expectedAccountId: owner.$1,
      );
      return !_disposed && owner == (accountId, _accountRevision) && saved;
    } catch (e) {
      if (e is PlatformException &&
          e.code == 'backup_destination_cleanup_failed') {
        backupFailureNotice =
            'Backup failed. Delete the file at your chosen destination; it may contain your identity.';
      }
      dlog('backupIdentity failed');
      return false;
    } finally {
      backingUp = false;
      notifyListeners();
    }
  }

  DevicePairingController? _devicePairing;
  bool get devicePairingPending => _devicePairing?.hasVisit == true;
  bool get _pairingForeground =>
      _pairingVisible && _viewFocused && _microphoneControlsFocused;
  bool get canUseDeviceLinkRendezvous => _pairingForeground && !appearOffline;
  bool get _pairingVisible =>
      !_disposed &&
      _foreground &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          (_viewFocused && _microphoneControlsFocused)) &&
      !_protectedSurfaceLocked &&
      !captureGateVisible;
  DevicePairingController
  get devicePairing => _devicePairing ??= DevicePairingController(
    client: jami,
    currentOwner: () => linkedDeviceOwner,
    foreground: () => _pairingForeground,
    visible: () => _pairingVisible,
    preparePrivacy: (target, owns) async {
      if (!owns() || !_settingsDocumentWritable) {
        throw StateError('Device link retired');
      }
      // Linked archives never import another installation's microphone intent.
      final local = appSettings.forRestoredAccount(
        sourceAccountId: null,
        accountId: target,
      );
      if (!await _saveAppSettings(local, restoreOwner: true) || !owns()) {
        throw StateError('Local device-link policy was not saved');
      }
      return jsonEncode(const AppSettingsCodec().encode(local));
    },
    activateIdentity: (prepared, owns) async {
      if (!owns()) throw StateError('Device link retired');
      await _finishPreparedIdentityRestore(
        prepared,
        owner: (accountId, _accountRevision),
        pairingCurrent: owns,
      );
      if (_disposed || accountId != prepared['accountId']) {
        throw StateError('Device-link adoption changed');
      }
      screen = Screen.home;
      _runInBackground(_hydratePeerFromDaemon(), 'hydratePeer(deviceLink)');
    },
    guardChanged: (active) {
      _restoringIdentity = active;
      if (!_disposed) {
        _refreshHologramPrivacy();
        notifyListeners();
      }
    },
  )..addListener(notifyListeners);

  String? devicePairingStartError;

  Future<bool> beginDevicePairing({
    required bool destination,
    String uri = '',
    bool Function()? stillCurrent,
  }) async {
    devicePairingStartError = null;
    if (!_pairingForeground || stillCurrent?.call() == false) {
      devicePairingStartError = 'Bring Doorlight into focus and try again.';
      return false;
    }
    if (!_settingsDocumentWritable) {
      devicePairingStartError =
          'App settings could not be loaded. Restart Doorlight before linking.';
      return false;
    }
    if (destination ? accountId != null : accountId == null) {
      devicePairingStartError = destination
          ? 'This device already has an identity.'
          : 'Create or restore your identity before linking another device.';
      return false;
    }
    if (_restoringIdentity ||
        devicePairingPending ||
        _identityMutationBusy ||
        _captureBusy ||
        backingUp ||
        call != null ||
        groupCall != null) {
      devicePairingStartError =
          'Finish the current call or operation, then try again.';
      return false;
    }
    final owner = linkedDeviceOwner;
    _restoringIdentity = true;
    retireHistorySearch();
    _refreshHologramPrivacy();
    notifyListeners();
    try {
      if (!await _networkPolicyReadyForIdentityChange() ||
          owner != linkedDeviceOwner) {
        devicePairingStartError =
            'Restart Doorlight to reconcile your connection.';
        return false;
      }
      if (!await MediaRetirement.stopAll()) {
        devicePairingStartError =
            'Media playback could not be stopped. Restart Doorlight before linking.';
        return false;
      }
      if (owner != linkedDeviceOwner ||
          !_pairingForeground ||
          stillCurrent?.call() == false) {
        devicePairingStartError =
            'Doorlight lost focus or the identity changed. Try again.';
        return false;
      }
      if (!await _saveAppSettings(appSettings, restoreOwner: true) ||
          owner != linkedDeviceOwner ||
          !_pairingForeground ||
          stillCurrent?.call() == false ||
          call != null ||
          groupCall != null) {
        devicePairingStartError =
            settingsError ?? 'Linking was interrupted. Try again.';
        return false;
      }
      return await devicePairing.begin(
        destination: destination,
        uri: uri,
        appearOffline: appearOffline,
        network: {
          'connectionProfile': connectionProfile,
          'dhtBootstrap': strictBootstrap,
          'turnServer': strictTurnServer,
          'turnRealm': strictTurnRealm,
          'turnUser': strictTurnUser,
          'turnPassword': strictTurnPassword,
        },
      );
    } finally {
      if (!devicePairingPending) _restoringIdentity = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Daemon-owned devices authenticated under this same Jami identity.
  Future<List<JamiKnownDevice>> listKnownDevices() => jami.listKnownDevices();

  /// Revoke an exact other device. Native revalidates membership, rejects this
  /// device, and supplies the installation-held archive credential.
  (String?, int) get linkedDeviceOwner =>
      (_disposed ? null : accountId, _accountRevision);

  Future<JamiDeviceRevocationStatus> revokeKnownDevice(
    String deviceId, {
    required (String?, int) owner,
  }) async {
    if (owner.$1 == null || owner != linkedDeviceOwner) {
      return JamiDeviceRevocationStatus.accountChanged;
    }
    final status = await jami.revokeKnownDevice(deviceId, accountId: owner.$1!);
    return owner == linkedDeviceOwner
        ? status
        : JamiDeviceRevocationStatus.accountChanged;
  }

  /// Picks a backup archive before its password is known. The caller passes
  /// the staged copy to one [restoreIdentity] attempt, which spends it, or
  /// releases it unused with [discardIdentityBackup].
  Future<String?> pickIdentityBackup() async {
    if (_restoringIdentity ||
        backingUp ||
        settingsBusy ||
        _captureBusy ||
        _changingAppearOffline ||
        _changingConnectionProfile) {
      return null;
    }
    final path = await jami.pickFile(maxBytes: JamiClient.maxBackupImportBytes);
    return path == null || path.isEmpty ? null : path;
  }

  Future<void> discardIdentityBackup(String path) async {
    try {
      await jami.discardPickedFile(path);
    } catch (error) {
      dlog('discard restore picker copy failed: $error');
    }
  }

  Future<String?> restoreIdentity(
    String passphrase, {
    String? backupPath,
    String? expectedJamiId,
  }) async {
    // A supplied backup is handed over with this call: every exit spends it.
    Future<String?> refuse(String message) async {
      if (backupPath != null) await discardIdentityBackup(backupPath);
      return message;
    }

    final expectedFingerprint = expectedJamiId == null
        ? null
        : JamiIdentity.fingerprint(expectedJamiId);
    if (expectedJamiId != null && expectedFingerprint == null) {
      return refuse('Enter the Friend ID you saved before this backup.');
    }

    if (_restoringIdentity ||
        backingUp ||
        _identityMutationBusy ||
        _captureBusy) {
      return refuse('Wait for the current settings operation to finish.');
    }
    if (call != null || groupCall != null) {
      return refuse('End the call before restoring an identity.');
    }
    final owner = (accountId, _accountRevision);
    bool ownsRestore() => !_disposed && owner == (accountId, _accountRevision);
    String? path = backupPath;
    var reconcileStartup = false;
    retireHistorySearch();
    _restoringIdentity = true;
    _refreshHologramPrivacy();
    notifyListeners();
    try {
      if (!await _networkPolicyReadyForIdentityChange() || !ownsRestore()) {
        return 'Restart Doorlight to reconcile your connection.';
      }
      if (!await MediaRetirement.stopAll()) {
        return 'Could not stop media playback. Please try again.';
      }
      if (!ownsRestore()) return null;
      path =
          backupPath ??
          await jami.pickFile(maxBytes: JamiClient.maxBackupImportBytes);
      if (!ownsRestore() || path == null || path.isEmpty) return null;
      final prepared = await jami.restoreIdentity(
        path,
        passphrase,
        expectedJamiId: expectedFingerprint ?? '',
        connectionProfile: connectionProfile,
        dhtBootstrap: strictBootstrap,
        turnServer: strictTurnServer,
        turnRealm: strictTurnRealm,
        turnUser: strictTurnUser,
        turnPassword: strictTurnPassword,
        // The native import gate cannot recover the original online choice
        // from legacy archives. Registration needs an explicit choice later.
        appearOffline: true,
        expectedAccountId: owner.$1,
      );
      if (!ownsRestore()) return null;
      if (prepared['status'] != 'prepared') {
        screen = Screen.loading;
        reconcileStartup = true;
        return "Couldn't prepare the identity restore.";
      }
      if (expectedFingerprint != null &&
          JamiIdentity.fingerprint(_asString(prepared['jamiId'])) !=
              expectedFingerprint) {
        screen = Screen.loading;
        reconcileStartup = true;
        return "The backup belongs to a different Friend ID.";
      }
      await _finishPreparedIdentityRestore(prepared, owner: owner);
      if (_disposed) return null;
      screen = Screen.home;
      notifyListeners();
      _runInBackground(_hydratePeerFromDaemon(), 'hydratePeer(restore)');
      return null;
    } catch (error) {
      if (ownsRestore()) {
        reconcileStartup = true;
        screen = Screen.loading;
        bootError = "Couldn't finish restoring the identity. Please try again.";
        notifyListeners();
      }
      rethrow;
    } finally {
      // Native hosts consume the staged copy on every attempt; a supplied
      // backup is spent too, so a retry picks the file again.
      if (path != null && path.isNotEmpty) {
        await discardIdentityBackup(path);
      }
      _restoringIdentity = false;
      if (!_disposed) {
        _runInBackground(
          _applySettingsToActiveCall(),
          'microphone after restore',
        );
      }
      if (reconcileStartup && !_disposed) await retryBoot();
      notifyListeners();
    }
  }

  Future<void> _finishPreparedIdentityRestore(
    Map<String, dynamic> prepared, {
    required (String?, int) owner,
    bool Function()? pairingCurrent,
  }) async {
    void requireOwner() {
      if (_disposed ||
          owner != (accountId, _accountRevision) ||
          pairingCurrent?.call() == false) {
        throw StateError('Account changed during restore');
      }
    }

    requireOwner();
    final restoredAccount = _asString(prepared['accountId']);
    final token = _asString(prepared['restoreToken']);
    final jid = JamiIdentity.fingerprint(_asString(prepared['jamiId']));
    if (prepared['status'] != 'prepared' ||
        restoredAccount.isEmpty ||
        token.isEmpty ||
        jid == null ||
        prepared['enabled'] != false) {
      throw StateError('Prepared identity restore was incomplete');
    }
    if (_profileMutationBusy || !await _networkPolicyReadyForIdentityChange()) {
      throw StateError('Restart Doorlight to reconcile your connection.');
    }
    requireOwner();
    if (!_settingsDocumentWritable) {
      throw StateError('Local privacy settings could not be loaded');
    }
    var restored = appSettings;
    String? warning;
    final value = prepared['settingsDocument'];
    if (prepared['devicePairing'] == true) {
      if (pairingCurrent == null ||
          prepared['settingsAlreadyNormalized'] != true ||
          value != jsonEncode(const AppSettingsCodec().encode(appSettings))) {
        throw StateError('Local device-link policy changed before activation');
      }
    } else if (value is String && value.isNotEmpty) {
      try {
        if (utf8.encode(value).length > JamiClient.maxSettingsDocumentBytes) {
          throw const FormatException(
            'backup settings exceed the native limit',
          );
        }
        RemoteControlJsonValidator(value).validate();
        final decoded = jsonDecode(value);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('backup settings must be an object');
        }
        final metadata = decoded['syblBackup'];
        final sourceOwner =
            prepared['settingsAlreadyNormalized'] == true &&
                prepared['backupSourceAccountId'] == restoredAccount
            ? restoredAccount
            : metadata is Map &&
                  metadata['version'] == 1 &&
                  metadata['version'] is int &&
                  metadata['sourceAccountId'] is String &&
                  metadata['sourceAccountId'] ==
                      prepared['backupSourceAccountId']
            ? metadata['sourceAccountId'] as String
            : null;
        restored = const AppSettingsCodec()
            .decode(decoded)
            .settings
            .forRestoredAccount(
              sourceAccountId: sourceOwner,
              accountId: restoredAccount,
            )
            .withAppLockEnabled(appSettings.appLockEnabled);
      } catch (error) {
        // Only a successfully loaded local policy can be the fallback. The
        // writable check above prevents corrupt local state becoming defaults.
        warning =
            'The backup settings could not be read. Local settings were kept.';
        dlog('backup settings not applied: $error');
      }
    } else if (value != null && value != '') {
      warning =
          'The backup settings could not be read. Local settings were kept.';
    }
    if (jami.usesNativeAppSettingsStore) {
      // The exact native restore transaction owns both commits. A separate
      // unscoped write could race a replacement account before finalization.
      _microphoneSettingsKnown = false;
      appSettings = restored;
      notifyListeners();
    } else {
      if (!await _saveAppSettings(restored, restoreOwner: true)) {
        throw StateError('Restored privacy settings could not be saved');
      }
      requireOwner();
      await jami.setMessageNotificationPreview(
        restored.showMessageInNotification,
        appLockEnabled: restored.appLockEnabled,
      );
    }
    requireOwner();
    final finalized = await jami.finalizeIdentityRestore(
      accountId: restoredAccount,
      restoreToken: token,
      settingsDocument: jsonEncode(const AppSettingsCodec().encode(restored)),
    );
    requireOwner();
    if (finalized['status'] != 'ok' ||
        finalized['accountId'] != restoredAccount ||
        JamiIdentity.fingerprint(_asString(finalized['jamiId'])) != jid) {
      throw StateError('Native privacy finalization was rejected');
    }
    if (jami.usesNativeAppSettingsStore) {
      _microphoneSettingsKnown = true;
      try {
        await prefs.reload();
      } catch (error) {
        warning =
            'Restored settings were saved, but their cache could not be refreshed.';
        dlog('restore settings cache refresh failed: $error');
      }
      requireOwner();
    }
    if (prepared['devicePairing'] != true && finalized['enabled'] == false) {
      const offlineNotice =
          'Identity restored offline. Choose Online in your account menu when you are ready.';
      warning = warning == null ? offlineNotice : '$warning $offlineNotice';
    }
    if (warning != null) _appendSettingsError(warning);
    final installing = _installAccountResult(
      finalized,
      fallbackDisplayName: displayName.isNotEmpty ? displayName : 'Me',
    );
    final installationOwner = (accountId, _accountRevision);
    try {
      await installing;
      _restoreSettingsNoticePending =
          warning != null || restored.microphoneReviewRequired;
    } catch (error) {
      if (!_disposed && installationOwner == (accountId, _accountRevision)) {
        screen = Screen.loading;
        bootError = "Couldn't finish restoring the identity. Please try again.";
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Refreshes friends and groups from the daemon's relationship snapshot.
  /// Preferences retain only UI selection and presentation hints.
  Future<void> _refreshFriendsFromDaemon() async {
    final owner = (accountId, _accountRevision);
    final snapshot = await jami.listFriends();
    if (_disposed || owner != (accountId, _accountRevision)) return;
    if (_friendsAccountOwner == owner && snapshot.revision < _friendsRevision) {
      return;
    }
    _friendsRevision = snapshot.revision;
    final next = <String, FriendState>{};
    for (final item in snapshot.friends) {
      final previous = _friends[item.peerJamiId];
      final displayName =
          ProfileWireContract.decodeDisplayName(item.displayName) ?? '';
      final hintKey = '$_friendNameHintPrefix${item.peerJamiId}';
      if (displayName.isNotEmpty) {
        _nameHints.remove(item.peerJamiId);
        // A stored request name is only needed until the profile arrives.
        if (prefs.containsKey(hintKey)) {
          _runInBackground(prefs.remove(hintKey), 'dropFriendNameHint');
        }
      } else if (!_nameHints.containsKey(item.peerJamiId)) {
        _rememberNameHint(item.peerJamiId, friendNameHint(prefs.get(hintKey)));
      }
      final cachedIdentityColor =
          _presenceColorCache.isRetiring(item.peerJamiId)
          ? null
          : IdentityColor.tryParse(
              prefs.get(_friendIdentityColorKey(item.peerJamiId)),
            );
      next[item.peerJamiId] = FriendState(
        peerId: item.peerJamiId,
        confirmed: item.confirmed,
        conversationId: item.conversationId,
        displayName: displayName,
        nameHint: _nameHints[item.peerJamiId] ?? '',
        avatarBase64: ProfileWireContract.decodeAvatar(item.avatarBase64) ?? '',
        presence: previous?.presence ?? PeerPresence.unknown,
        peerFgTs: previous?.peerFgTs ?? 0,
        presencePlatform: previous?.presencePlatform ?? '',
        presenceActivity: previous?.presenceActivity ?? '',
        identityColor: previous?.identityColor ?? cachedIdentityColor,
      );
    }
    final removedIds = _friends.keys
        .where((id) => !next.containsKey(id))
        .toList();
    for (final id in removedIds) {
      final hintKey = '$_friendNameHintPrefix$id';
      if (prefs.containsKey(hintKey)) {
        _runInBackground(prefs.remove(hintKey), 'dropFriendNameHint');
      }
    }
    final nextGroups = <String, GroupState>{};
    for (final item in snapshot.groups) {
      final active = <String>{};
      final invited = <String>{};
      for (final member in item.members) {
        switch (member.role) {
          case JamiGroupMemberRole.admin:
          case JamiGroupMemberRole.member:
            active.add(member.peerJamiId);
            break;
          case JamiGroupMemberRole.invited:
            invited.add(member.peerJamiId);
            break;
          case JamiGroupMemberRole.unknown:
            break;
        }
      }
      nextGroups[item.conversationId] = GroupState(
        conversationId: item.conversationId,
        title: item.title,
        description: item.description,
        memberCount: item.memberCount,
        canManageMembers: item.canManageMembers,
        localRole: item.localRole,
        memberRoles: Map.unmodifiable({
          for (final member in item.members) member.peerJamiId: member.role,
        }),
        memberDisplayNames: Map.unmodifiable({
          for (final member in item.members)
            if (member.displayName.isNotEmpty)
              member.peerJamiId: member.displayName,
        }),
        memberAvatars: Map.unmodifiable({
          for (final member in item.members)
            if (member.avatarBase64.isNotEmpty)
              member.peerJamiId: member.avatarBase64,
        }),
        memberIds: List.unmodifiable(
          item.members.map((member) => member.peerJamiId),
        ),
        activeMemberIds: Set.unmodifiable(active),
        invitedMemberIds: Set.unmodifiable(invited),
      );
    }
    final searchAuthorityChanged =
        _friends.length != next.length ||
        _friends.entries.any((entry) {
          final replacement = next[entry.key];
          return replacement == null ||
              replacement.confirmed != entry.value.confirmed ||
              replacement.conversationId != entry.value.conversationId;
        }) ||
        _groups.length != nextGroups.length ||
        _groups.entries.any((entry) {
          final replacement = nextGroups[entry.key];
          return replacement == null ||
              replacement.localRole != entry.value.localRole ||
              replacement.description != entry.value.description ||
              !setEquals(
                replacement.activeMemberIds,
                entry.value.activeMemberIds,
              );
        });
    if (searchAuthorityChanged) retireHistorySearch();
    _friends
      ..clear()
      ..addAll(next);
    _groups
      ..clear()
      ..addAll(nextGroups);
    _friendsAccountOwner = owner;
    bool ownsSnapshot() =>
        !_disposed &&
        owner == (accountId, _accountRevision) &&
        _friendsAccountOwner == owner &&
        _friendsRevision == snapshot.revision;
    _uncertainControlPeers.clear();
    // Trust changes retire consent and queued control synchronously. Local
    // preference cleanup cannot delay this authority boundary.
    _syncRemoteControl();
    for (final removedId in removedIds) {
      await _presenceColorCache.forget(removedId);
      if (!ownsSnapshot()) return;
    }
    final authorizedWakePeers = <String>{
      ...next.keys,
      for (final group in nextGroups.values) ...group.activeMemberIds,
    };
    if (_wakeCapabilities.trim(authorizedWakePeers)) {
      await prefs.setString(_wakeCapabilitiesKey, _wakeCapabilities.encode());
      if (!ownsSnapshot()) return;
    }
    final groupSelectionCount = _selectedGroupTopicIds.length;
    _selectedGroupTopicIds.removeWhere(
      (conversationId, _) => !nextGroups.containsKey(conversationId),
    );
    if (_selectedGroupTopicIds.length != groupSelectionCount) {
      _runInBackground(_saveGroupTopicSelections(), 'trimGroupTopicSelections');
    }
    final activityOwners = {
      ...next.keys,
      for (final group in nextGroups.values) group.ownerKey,
    };
    _friendActivity.removeWhere((id, _) => !activityOwners.contains(id));
    _seenConversationActivity.removeWhere(
      (entry) => !activityOwners.contains(entry.$1.peerId),
    );
    _remoteComposerActivities.removeWhere(
      (scope, _) => _scopeForPeer(scope.peerId) != scope,
    );
    final localComposerScope = _localComposerActivityScope;
    if (localComposerScope != null &&
        _scopeForPeer(localComposerScope.peerId) != localComposerScope) {
      _localComposerActivityScope = null;
      _localComposerActivity = ComposerActivityKind.idle;
    }
    if (!_ownsConversationPeer(_visibleConversationPeerId)) {
      _visibleConversationPeerId = null;
      _visibleGroupTopicId = null;
      _visibleDmTopicId = null;
    } else if (_visibleGroupTopicId != null) {
      final group = _groups.values
          .where(
            (candidate) => candidate.ownerKey == _visibleConversationPeerId,
          )
          .firstOrNull;
      if (group?.layout.room(_visibleGroupTopicId!)?.kind !=
          GroupRoomKind.text) {
        _visibleConversationPeerId = null;
        _visibleGroupTopicId = null;
        _visibleDmTopicId = null;
      }
    }
    _fileTransfers.reconcileOwners(<TransferOwner>[
      ..._friends.values
          .where((friend) => friend.confirmed)
          .map(
            (friend) =>
                (peerId: friend.peerId, conversationId: friend.conversationId),
          ),
      ..._groups.values.map(
        (group) =>
            (peerId: group.ownerKey, conversationId: group.conversationId),
      ),
    ]);
    _reconcileDmTopicScopes();
    if (selectedGroupId != null && !_groups.containsKey(selectedGroupId)) {
      selectedGroupId = null;
    }
    if (selectedGroupId != null) {
      peerId = null;
    } else if (peerId != null && !_friends.containsKey(peerId)) {
      peerId = null;
    }
    final selected = selectedFriend;
    peerPresence = selected?.presence ?? PeerPresence.unknown;
    _syncPresenceRuntime();
    _syncSelectedTimeline();
    _refreshDmTopicIntroduction();
    final selectionOwner = conversationActionOwner;
    if (!await _persistConversationSelection(selectionOwner) ||
        !ownsSnapshot() ||
        selectionOwner != conversationActionOwner) {
      return;
    }
    // Relationship truth has already been adopted from libjami. A transient subscription failure must not
    // roll that durable state back (or resurrect an already-accepted trust request); presence will retry on
    // the next native snapshot/boot event.
    try {
      await jami.setPresenceSubscriptions(_friends.keys);
    } catch (error) {
      dlog('setPresenceSubscriptions(refresh) failed: $error');
    }
    if (!ownsSnapshot() || selectionOwner != conversationActionOwner) return;
    // Native attaches before account/friend adoption and therefore cannot safely replay account-scoped requests or
    // rings from onListen. Ask only after both gates are installed; native keeps the underlying records authoritative.
    await jami.replayPendingNativeEvents();
  }

  ConversationScope? _scopeForPeer(String id) {
    final account = accountId;
    final friend = _friends[id];
    if (account == null ||
        account.isEmpty ||
        friend == null ||
        !friend.confirmed ||
        friend.conversationId.isEmpty) {
      return null;
    }
    return ConversationScope(
      accountId: account,
      peerId: id,
      conversationId: friend.conversationId,
    );
  }

  ConversationScope? _scopeForGroup(String id) {
    final account = accountId;
    final group = _groups[id];
    if (account == null || account.isEmpty || group == null) return null;
    return ConversationScope(
      accountId: account,
      peerId: group.ownerKey,
      conversationId: group.conversationId,
      kind: ConversationKind.group,
    );
  }

  void _reconcileDmTopicScopes() {
    final activeAccount = accountId;
    if (activeAccount == null || activeAccount.isEmpty || jamiId.isEmpty) {
      return;
    }
    final scopes = <ConversationScope>{
      for (final friend in _friends.values)
        if (friend.confirmed && friend.conversationId.isNotEmpty)
          ConversationScope(
            accountId: activeAccount,
            peerId: friend.peerId,
            conversationId: friend.conversationId,
          ),
    };
    final stale = _dmTopicStates.keys
        .where((scope) => !scopes.contains(scope))
        .toSet();
    for (final scope in stale) {
      _dmTopicStates.remove(scope);
      _dmTopicHistoryFailures.remove(scope);
      _selectedDmTopicIds.remove(scope);
      _persistedDmTopicSelections.remove(scope);
      _dmTopicNextPositions.remove(scope);
      _dmTopicLiveRecords.remove(scope);
      _dmTopicLiveBytes.remove(scope);
      _dmTopicLiveOverflow.remove(scope);
      _dmTopicScans.remove(scope)?.timer?.cancel();
      _dmTopicRetryCooldowns.remove(scope)?.cancel();
      _dmTopicOverflowRecovery.remove(scope)?.cancel();
      _dmTopicScanQueue.remove(scope);
      if (_activeDmTopicScanScope == scope) _activeDmTopicScanScope = null;
      _loadedDmTopicScopes.remove(scope);
    }
    _dmTopicLoads.removeWhere((loadId, scan) {
      if (!stale.contains(scan.scope)) return false;
      _runInBackground(
        jami.cancelDmTopicStateLoad(loadId),
        'cancelDmTopicState',
      );
      return true;
    });
    _pumpDmTopicScans();
    for (final scope in scopes) {
      _dmTopicStates.putIfAbsent(
        scope,
        () => DmTopicState.initial({jamiId, scope.peerId}),
      );
      _selectedDmTopicIds.putIfAbsent(
        scope,
        () => _persistedDmTopicSelections[scope] ?? DmTopicWire.mainId,
      );
      if (!_loadedDmTopicScopes.contains(scope) &&
          !_dmTopicScans.containsKey(scope)) {
        _startDmTopicScan(scope);
      }
    }
    if (stale.isNotEmpty) {
      _runInBackground(_saveDmTopicSelections(), 'trimDmTopicSelections');
    }
  }

  void _loadDmTopicSelections() {
    final encoded = prefs.getString(_dmTopicSelectionsKey);
    if (encoded == null || encoded.length > 256 * 1024) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List || decoded.length > 5000) return;
      for (final value in decoded) {
        if (value is! Map) continue;
        final scope = ConversationScope.tryParse(value['scope']);
        final topicId = value['topicId'];
        if (scope != null &&
            !scope.isGroup &&
            topicId is String &&
            (topicId == DmTopicWire.mainId ||
                DmTopicWire.isCustomId(topicId))) {
          _persistedDmTopicSelections[scope] = topicId;
        }
      }
    } catch (_) {
      // A local navigation cache is optional. Durable topic state remains in
      // the signed conversation history.
    }
  }

  Future<void> _saveDmTopicSelections() async {
    final entries = _persistedDmTopicSelections.entries.toList()
      ..sort((left, right) {
        final account = left.key.accountId.compareTo(right.key.accountId);
        if (account != 0) return account;
        final peer = left.key.peerId.compareTo(right.key.peerId);
        return peer != 0
            ? peer
            : left.key.conversationId.compareTo(right.key.conversationId);
      });
    await prefs.setString(
      _dmTopicSelectionsKey,
      jsonEncode([
        for (final entry in entries)
          {'scope': entry.key.toMap(), 'topicId': entry.value},
      ]),
    );
  }

  void _loadGroupTopicSelections() {
    final encoded = prefs.getString(_groupTopicSelectionsKey);
    if (encoded == null || encoded.length > 256 * 1024) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map || decoded.length > 5000) return;
      for (final entry in decoded.entries) {
        if (entry.key is String &&
            entry.key.toString().length <= 1024 &&
            entry.value is String &&
            entry.value.toString().length <= 64) {
          _selectedGroupTopicIds[entry.key.toString()] = entry.value.toString();
        }
      }
    } catch (_) {
      // This value is only a local navigation cache.
    }
  }

  Future<void> _saveGroupTopicSelections() => prefs.setString(
    _groupTopicSelectionsKey,
    jsonEncode(
      Map.fromEntries(
        _selectedGroupTopicIds.entries.toList()
          ..sort((left, right) => left.key.compareTo(right.key)),
      ),
    ),
  );

  void _startDmTopicScan(ConversationScope scope, {int attempt = 0}) {
    if (_dmTopicRetryCooldowns[scope]?.isActive ?? false) return;
    _dmTopicRetryCooldowns.remove(scope);
    _dmTopicOverflowRecovery.remove(scope)?.cancel();
    final previous = _dmTopicScans[scope];
    // A sync is invalidation, not authority to repeatedly cancel a progressing
    // scan. Keep its cursor and bounded retries owned until it finishes.
    if (previous != null && !previous.failed) return;
    if (previous != null) {
      previous.timer?.cancel();
      _dmTopicLoads.removeWhere((loadId, scan) {
        if (!identical(scan, previous)) return false;
        _runInBackground(
          jami.cancelDmTopicStateLoad(loadId),
          'cancelDmTopicState',
        );
        return true;
      });
    }
    _dmTopicLiveRecords.remove(scope);
    _dmTopicLiveBytes.remove(scope);
    _dmTopicLiveOverflow.remove(scope);
    final scan = _DmTopicStateScan(scope: scope, attempt: attempt);
    _dmTopicHistoryFailures.remove(scope);
    _dmTopicScans[scope] = scan;
    if (!_dmTopicScanQueue.contains(scope)) _dmTopicScanQueue.add(scope);
    _pumpDmTopicScans();
  }

  void _pumpDmTopicScans() {
    if (_disposed || _activeDmTopicScanScope != null) return;
    while (_dmTopicScanQueue.isNotEmpty) {
      final scope = _dmTopicScanQueue.removeFirst();
      final scan = _dmTopicScans[scope];
      if (scan == null || scan.failed) continue;
      _activeDmTopicScanScope = scope;
      _runInBackground(_requestDmTopicPage(scan, ''), 'loadDmTopicState');
      return;
    }
  }

  void _releaseDmTopicScan(_DmTopicStateScan scan) {
    if (_activeDmTopicScanScope == scan.scope) {
      _activeDmTopicScanScope = null;
    }
    _pumpDmTopicScans();
  }

  void _recoverDmTopicLiveOverflow(
    ConversationScope scope, {
    required bool interruptedScan,
  }) {
    if (_dmTopicOverflowRecovery[scope]?.isActive ?? false) return;
    // A single delayed scan can recover a burst without letting each new
    // commit restart history. An interrupted scan first observes its cooldown.
    _dmTopicOverflowRecovery[scope] = Timer(
      interruptedScan
          ? const Duration(minutes: 5, seconds: 1)
          : const Duration(seconds: 30),
      () {
        _dmTopicOverflowRecovery.remove(scope);
        if (!_disposed &&
            _scopeForPeer(scope.peerId) == scope &&
            _dmTopicLiveOverflow.contains(scope)) {
          _startDmTopicScan(scope);
        }
      },
    );
  }

  void _retireDmTopicRuntime() {
    ++_syncedTimelinesRefreshEpoch;
    _syncedTimelinesRefreshCooldown?.cancel();
    _syncedTimelinesRefreshCooldown = null;
    _syncedTimelinesRefreshQueued = false;
    _syncedTimelinesRefreshAgain = false;
    _dmTopicRescanCooldown?.cancel();
    _dmTopicRescanCooldown = null;
    _dmTopicRescanRequested = false;
    for (final loadId in _dmTopicLoads.keys.toList(growable: false)) {
      _runInBackground(
        jami.cancelDmTopicStateLoad(loadId),
        'cancelDmTopicState',
      );
    }
    for (final scan in _dmTopicScans.values) {
      scan.timer?.cancel();
    }
    _dmTopicStates.clear();
    _dmTopicHistoryFailures.clear();
    _selectedDmTopicIds.clear();
    _dmTopicNextPositions.clear();
    _dmTopicLiveRecords.clear();
    _dmTopicLiveBytes.clear();
    _dmTopicLiveOverflow.clear();
    _dmTopicScans.clear();
    for (final timer in _dmTopicRetryCooldowns.values) {
      timer.cancel();
    }
    _dmTopicRetryCooldowns.clear();
    for (final timer in _dmTopicOverflowRecovery.values) {
      timer.cancel();
    }
    _dmTopicOverflowRecovery.clear();
    _dmTopicScanQueue.clear();
    _activeDmTopicScanScope = null;
    _loadedDmTopicScopes.clear();
    _dmTopicLoads.clear();
    _earlyDmTopicPages.clear();
    for (final done in _dmTopicMutations.values) {
      if (!done.isCompleted) done.complete();
    }
    _dmTopicMutations.clear();
    _visibleDmTopicId = null;
  }

  void _rescanDmTopics() {
    if (_dmTopicRescanCooldown != null) {
      _dmTopicRescanRequested = true;
      return;
    }
    _dmTopicRescanRequested = false;
    _dmTopicRescanCooldown = Timer(const Duration(seconds: 30), () {
      _dmTopicRescanCooldown = null;
      if (!_disposed && _dmTopicRescanRequested) _rescanDmTopics();
    });
    for (final scope in _dmTopicStates.keys.toList(growable: false)) {
      _startDmTopicScan(scope);
    }
  }

  void _failDmTopicScan(
    _DmTopicStateScan scan, {
    bool retryable = true,
    bool tooLarge = false,
  }) {
    if (_disposed ||
        scan.failed ||
        !identical(_dmTopicScans[scan.scope], scan)) {
      return;
    }
    scan.timer?.cancel();
    scan.newestFirst.clear();
    scan.retainedBytes = 0;
    _earlyDmTopicPages.clear();
    scan.requestPending = false;
    scan.failed = true;
    _dmTopicLoads.removeWhere((loadId, owner) {
      if (!identical(owner, scan)) return false;
      _earlyDmTopicPages.remove(loadId);
      _runInBackground(
        jami.cancelDmTopicStateLoad(loadId),
        'cancelDmTopicState',
      );
      return true;
    });
    // Keep the last complete projection. Two bounded retries cannot create
    // a hot loop; later friend reconciliation or a sync can start a new scan.
    if (retryable && scan.attempt < 2) {
      scan.timer = Timer(Duration(seconds: 1 << scan.attempt), () {
        if (!_disposed && identical(_dmTopicScans[scan.scope], scan)) {
          _startDmTopicScan(scan.scope, attempt: scan.attempt + 1);
        }
      });
    } else {
      _dmTopicHistoryFailures[scan.scope] = tooLarge
          ? DmTopicHistoryStatus.tooLarge
          : DmTopicHistoryStatus.failed;
      _dmTopicScans.remove(scan.scope);
      _dmTopicScanQueue.remove(scan.scope);
      _dmTopicRetryCooldowns[scan.scope]?.cancel();
      _dmTopicRetryCooldowns[scan.scope] = Timer(
        retryable ? const Duration(seconds: 30) : const Duration(minutes: 5),
        () {
          _dmTopicRetryCooldowns.remove(scan.scope);
          if (!_disposed) notifyListeners();
        },
      );
    }
    _releaseDmTopicScan(scan);
    notifyListeners();
  }

  Future<void> _requestDmTopicPage(
    _DmTopicStateScan scan,
    String cursor,
  ) async {
    if (_disposed ||
        !identical(_dmTopicScans[scan.scope], scan) ||
        scan.requestPending ||
        scan.failed) {
      return;
    }
    scan
      ..requestedCursor = cursor
      ..requestPending = true;
    // Includes the native request reply and the later correlated page.
    scan.timer?.cancel();
    scan.timer = Timer(
      const Duration(seconds: 30),
      () => _failDmTopicScan(scan),
    );
    int loadId;
    try {
      loadId = await jami.loadDmTopicState(
        scan.scope.peerId,
        scan.scope.conversationId,
        fromMessage: cursor,
        pageSize: DmTopicWire.maxStatePageItems,
      );
    } catch (error) {
      if (identical(_dmTopicScans[scan.scope], scan)) {
        dlog('loadDmTopicState(${scan.scope.peerId}) failed: $error');
        _failDmTopicScan(scan);
      }
      return;
    } finally {
      scan.requestPending = false;
    }
    if (_disposed ||
        scan.failed ||
        !identical(_dmTopicScans[scan.scope], scan) ||
        !scan.timer!.isActive) {
      if (loadId > 0) {
        _runInBackground(
          jami.cancelDmTopicStateLoad(loadId),
          'cancelLateDmTopicState',
        );
      }
      return;
    }
    if (loadId <= 0) {
      _failDmTopicScan(scan);
      return;
    }
    _dmTopicLoads[loadId] = scan;
    final early = _earlyDmTopicPages.remove(loadId);
    if (early != null) _handleDmTopicStatePage(early);
  }

  void _handleDmTopicStatePage(JamiEvent event) {
    final loadId = _asInt(event.data['loadId']);
    final scan = _dmTopicLoads.remove(loadId);
    if (scan == null) {
      final active = _activeDmTopicScanScope;
      final candidate = active == null ? null : _dmTopicScans[active];
      final earlyItems = candidate?.requestPending == true
          ? _dmTopicPageItems(event.data)
          : null;
      if (loadId > 0 &&
          candidate != null &&
          candidate.requestPending &&
          _asString(event.data['accountId']) == candidate.scope.accountId &&
          _asString(event.data['peerJamiId']) == candidate.scope.peerId &&
          _asString(event.data['conversationId']) ==
              candidate.scope.conversationId &&
          earlyItems != null) {
        _earlyDmTopicPages.clear();
        _earlyDmTopicPages[loadId] = JamiEvent('dmTopicStatePage', {
          'loadId': loadId,
          'accountId': candidate.scope.accountId,
          'peerJamiId': candidate.scope.peerId,
          'conversationId': candidate.scope.conversationId,
          'requestedCursor': _asString(event.data['requestedCursor']),
          'nextCursor': _asString(event.data['nextCursor']),
          'hasMore': event.data['hasMore'],
          'items': earlyItems,
        });
      }
      return;
    }
    if (_disposed ||
        scan.failed ||
        !identical(_dmTopicScans[scan.scope], scan)) {
      return;
    }
    final account = _asString(event.data['accountId']);
    final peer = _asString(event.data['peerJamiId']);
    final conversation = _asString(event.data['conversationId']);
    final requested = _asString(event.data['requestedCursor']);
    final nextCursor = _asString(event.data['nextCursor']);
    final hasMore = _strictBoolValue(event.data['hasMore']);
    final items = _dmTopicPageItems(event.data);
    if (account != scan.scope.accountId ||
        peer != scan.scope.peerId ||
        conversation != scan.scope.conversationId ||
        requested != scan.requestedCursor ||
        hasMore == null ||
        items == null ||
        (hasMore &&
            (nextCursor.isEmpty || scan.cursors.contains(nextCursor))) ||
        (!hasMore && nextCursor.isNotEmpty)) {
      dlog('dmTopicStatePage($loadId) failed correlation or bounds');
      _runInBackground(
        jami.cancelDmTopicStateLoad(loadId),
        'cancelInvalidDmTopicState',
      );
      _failDmTopicScan(scan);
      return;
    }
    scan.timer?.cancel();
    final pageBytes = utf8.encode(jsonEncode(items)).length;
    if (scan.newestFirst.length + items.length > _maxDmTopicScanRecords ||
        scan.retainedBytes + pageBytes > _maxDmTopicScanBytes) {
      dlog('dmTopicStatePage($loadId) exceeded complete-history budget');
      _failDmTopicScan(scan, retryable: false, tooLarge: true);
      return;
    }
    scan.retainedBytes += pageBytes;
    scan.newestFirst.addAll(items);
    if (hasMore) {
      scan.cursors.add(nextCursor);
      _runInBackground(
        _requestDmTopicPage(scan, nextCursor),
        'loadDmTopicState(next)',
      );
      return;
    }
    _commitDmTopicScan(scan);
  }

  List<Map<String, Object?>>? _dmTopicPageItems(Map<String, dynamic> data) {
    Object? raw = data['items'];
    if (raw == null && data['itemsJson'] is String) {
      final encoded = data['itemsJson'] as String;
      if (encoded.length > TimelineWireContract.maxSnapshotEncodedBytes) {
        return null;
      }
      try {
        raw = jsonDecode(encoded);
      } catch (_) {
        return null;
      }
    }
    if (raw is! List || raw.length > DmTopicWire.maxStatePageItems) {
      return null;
    }
    // Android sends a List directly; impose the same page byte ceiling as the
    // Windows JSON channel before retaining any of its maps.
    try {
      if (utf8.encode(jsonEncode(raw)).length >
          TimelineWireContract.maxSnapshotEncodedBytes) {
        return null;
      }
    } catch (_) {
      return null;
    }
    final result = <Map<String, Object?>>[];
    for (final value in raw) {
      if (value is! Map) return null;
      final item = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) return null;
        item[entry.key as String] = entry.value;
      }
      result.add(Map.unmodifiable(item));
    }
    return result;
  }

  void _commitDmTopicScan(_DmTopicStateScan scan) {
    if (!identical(_dmTopicScans[scan.scope], scan)) return;
    if (_dmTopicLiveOverflow.contains(scan.scope) ||
        scan.newestFirst.length +
                (_dmTopicLiveRecords[scan.scope]?.length ?? 0) >
            _maxDmTopicScanRecords ||
        scan.retainedBytes + (_dmTopicLiveBytes[scan.scope] ?? 0) >
            _maxDmTopicScanBytes) {
      _failDmTopicScan(
        scan,
        retryable: false,
        tooLarge: !_dmTopicLiveOverflow.contains(scan.scope),
      );
      return;
    }
    scan.timer?.cancel();
    final records = <DmTopicRecord>[];
    var position = 0;
    for (final raw in scan.newestFirst.reversed) {
      final parsed = _dmTopicRecord(raw, ++position);
      if (parsed == null) continue;
      records.add(parsed);
    }
    final liveRecords = _dmTopicLiveRecords[scan.scope];
    if (liveRecords != null) {
      for (final raw in liveRecords.values) {
        final parsed = _dmTopicRecord(raw, ++position);
        if (parsed == null) continue;
        records.add(parsed);
      }
    }
    final state = DmTopicReducer.reduceAll(
      DmTopicState.initial({jamiId, scan.scope.peerId}),
      records,
    );
    final previouslyLeft =
        _dmTopicStates[scan.scope]?.hasLeft(scan.scope.peerId) ?? false;
    _dmTopicStates[scan.scope] = state;
    _dmTopicHistoryFailures.remove(scan.scope);
    _dmTopicNextPositions[scan.scope] = position;
    _dmTopicScans.remove(scan.scope);
    _dmTopicLiveRecords.remove(scan.scope);
    _dmTopicLiveBytes.remove(scan.scope);
    _dmTopicLiveOverflow.remove(scan.scope);
    _loadedDmTopicScopes.add(scan.scope);
    _releaseDmTopicScan(scan);
    if (state.customTopics.isNotEmpty) {
      _runInBackground(
        _markDmTopicIntroductionUnderstood(),
        'understandDmTopicsFromHistory',
      );
    }
    if (previouslyLeft != state.hasLeft(scan.scope.peerId)) {
      _syncDirectPeerGates();
    }
    final selected = _selectedDmTopicIds[scan.scope];
    if (selected != null && state.topic(selected) == null) {
      _selectedDmTopicIds[scan.scope] = DmTopicWire.mainId;
      _persistedDmTopicSelections[scan.scope] = DmTopicWire.mainId;
      _runInBackground(_saveDmTopicSelections(), 'saveDmTopicSelection');
    }
    notifyListeners();
  }

  DmTopicRecord? _dmTopicRecord(Map<String, Object?> raw, int position) {
    final commitId = _asString(raw['commitId'] ?? raw['daemonId']);
    final authorId = _asString(raw['authorId']);
    final mimeType = _asString(raw['mimeType']);
    if (commitId.isEmpty || authorId.isEmpty) return null;
    if (mimeType == DmTopicWire.mimeType) {
      final body = _asString(raw['eventBody'] ?? raw['body']);
      final event = DmTopicEventCodec.decode(body);
      return event == null
          ? null
          : DmTopicEventEnvelope(
              commitId: commitId,
              authorId: authorId,
              position: position,
              event: event,
            );
    }
    if (mimeType != TimelineWireContract.textMimeType &&
        mimeType != TimelineWireContract.fileMimeType) {
      return null;
    }
    final topicId = _asString(raw['topicId']);
    final tagged = _strictBoolValue(raw['topicTagged']);
    if (tagged == null ||
        (tagged &&
            topicId != DmTopicWire.mainId &&
            !DmTopicWire.isCustomId(topicId))) {
      return null;
    }
    return DmTopicItemEnvelope(
      commitId: commitId,
      authorId: authorId,
      position: position,
      topicId: tagged ? topicId : null,
      daemonRead: !tagged && (_strictBoolValue(raw['daemonRead']) ?? false),
    );
  }

  void _mergeLiveDmTopicRecord(
    ConversationScope scope,
    Map<String, Object?> raw,
  ) {
    if (scope.isGroup || _scopeForPeer(scope.peerId) != scope) return;
    final commitId = _asString(raw['daemonId']);
    if (commitId.isEmpty) return;
    // The timeline owns message bodies. Topic staging needs only metadata.
    final compact = <String, Object?>{
      'commitId': commitId,
      'authorId': raw['authorId'],
      'mimeType': raw['mimeType'],
      'topicId': raw['topicId'],
      'topicTagged': raw['topicTagged'],
      'daemonRead': raw['daemonRead'],
      if (raw['mimeType'] == DmTopicWire.mimeType)
        'eventBody': raw['eventBody'] ?? raw['body'],
    };
    int byteCount;
    try {
      byteCount = utf8.encode(jsonEncode(compact)).length;
    } catch (_) {
      return;
    }
    if (byteCount > 8192 || _dmTopicLiveOverflow.contains(scope)) return;
    final loaded = _loadedDmTopicScopes.contains(scope);
    final current = _dmTopicStates[scope];
    if (loaded &&
        current != null &&
        current.recordCount >= _maxDmTopicScanRecords) {
      _dmTopicHistoryFailures[scope] = DmTopicHistoryStatus.tooLarge;
      _dmTopicRetryCooldowns[scope]?.cancel();
      _dmTopicRetryCooldowns[scope] = Timer(const Duration(minutes: 5), () {
        _dmTopicRetryCooldowns.remove(scope);
        if (!_disposed) notifyListeners();
      });
      _dmTopicLiveOverflow.add(scope);
      _loadedDmTopicScopes.remove(scope);
      notifyListeners();
      return;
    }
    final live = _dmTopicLiveRecords.putIfAbsent(
      scope,
      LinkedHashMap<String, Map<String, Object?>>.new,
    );
    if (!live.containsKey(commitId) &&
        (live.length >= _maxDmTopicLiveRecords ||
            (_dmTopicLiveBytes[scope] ?? 0) + byteCount >
                _maxDmTopicLiveBytes)) {
      _dmTopicLiveOverflow.add(scope);
      _loadedDmTopicScopes.remove(scope);
      final scan = _dmTopicScans[scope];
      if (scan != null) _failDmTopicScan(scan, retryable: false);
      _recoverDmTopicLiveOverflow(scope, interruptedScan: scan != null);
      notifyListeners();
      return;
    }
    if (live.containsKey(commitId)) return;
    live[commitId] = Map.unmodifiable(compact);
    _dmTopicLiveBytes[scope] = (_dmTopicLiveBytes[scope] ?? 0) + byteCount;
    if (!loaded) return;
    final nextPosition = (_dmTopicNextPositions[scope] ?? 0) + 1;
    final parsed = _dmTopicRecord(live[commitId]!, nextPosition);
    if (parsed == null) return;
    final state = _dmTopicStates.putIfAbsent(
      scope,
      () => DmTopicState.initial({jamiId, scope.peerId}),
    );
    final next = DmTopicReducer.reduce(state, parsed);
    _dmTopicNextPositions[scope] = nextPosition;
    if (!identical(next, state)) {
      _dmTopicStates[scope] = next;
      if (next.hasLeft(scope.peerId) != state.hasLeft(scope.peerId)) {
        _syncDirectPeerGates();
      }
      notifyListeners();
    }
  }

  ConversationScope? get selectedConversationScope {
    final group = selectedGroupId;
    if (group != null) return _scopeForGroup(group);
    final selected = peerId;
    return selected == null ? null : _scopeForPeer(selected);
  }

  void _syncSelectedTimeline() {
    final scope = selectedConversationScope;
    final current = _conversationTimeline;
    final allowedRemoteAuthors = scope == null
        ? const <String>{}
        : scope.isGroup
        ? (_groups[scope.conversationId]?.activeMemberIds ?? const <String>{})
        : <String>{scope.peerId};
    if (scope != null &&
        current?.scope == scope &&
        setEquals(current!.allowedRemoteAuthorIds, allowedRemoteAuthors)) {
      return;
    }
    _detachSelectedTimeline();
    if (scope == null || jamiId.isEmpty || _disposed) return;
    var next = _conversationTimelines[scope];
    if (next != null &&
        !setEquals(next.allowedRemoteAuthorIds, allowedRemoteAuthors)) {
      _conversationTimelines.remove(scope);
      next.dispose();
      next = null;
    }
    final created = next == null;
    next ??= ConversationTimelineController(
      scope: scope,
      localAuthorId: jamiId,
      repository: _timelineRepository,
      allowedRemoteAuthorIds: allowedRemoteAuthors,
    );
    _conversationTimelines[scope] = next;
    _conversationTimeline = next;
    next.addListener(_onTimelineChanged);
    if (created) {
      _runInBackground(next.refresh(), 'loadChat(${scope.peerId})');
    }
  }

  void _detachSelectedTimeline() {
    final previous = _conversationTimeline;
    if (previous != null) {
      previous.removeListener(_onTimelineChanged);
      _conversationTimeline = null;
    }
    chatError = null;
  }

  void _retireSelectedTimeline() {
    _detachSelectedTimeline();
    for (final timeline in _conversationTimelines.values) {
      timeline.dispose();
    }
    _conversationTimelines.clear();
    _displayedMessageIds.clear();
  }

  Future<void> _repairCommittedSeed(SendJournalRecord record) async {
    final commit = record.commitId;
    if (record.stageReference == null ||
        commit == null ||
        record.status != ComposerSendStatus.committed ||
        record.scope.accountId != accountId ||
        !_repairingSeeds.add(record.operationId)) {
      return;
    }
    try {
      if (await jami.acknowledgeFileSeed(
        accountId: record.scope.accountId,
        conversationId: record.scope.conversationId,
        operationId: record.operationId,
        commitId: commit,
      )) {
        await sendJournal.acknowledgeSeed(
          record.operationId,
          record.scope,
          commit,
        );
      }
    } finally {
      _repairingSeeds.remove(record.operationId);
    }
  }

  void _onTimelineChanged() {
    _scheduleNotReadyRetry();
    if (_applyingReactionMetadata) {
      notifyListeners();
      return;
    }
    final timeline = _conversationTimeline;
    final items = timeline?.items ?? const <ConversationTimelineItem>[];
    for (final item in items) {
      final id = item.operationId;
      if (id == null || item.direction != TimelineDirection.outgoing) continue;
      final record = sendJournal.record(id);
      if (record == null ||
          record.scope != item.scope ||
          (record.status == ComposerSendStatus.committed &&
              record.stageReference == null) ||
          !_reconcilingSendIds.add(id)) {
        continue;
      }
      // A signed outgoing commit is positive evidence even after restart.
      // Missing items in this bounded page never imply pre-commit failure.
      _runInBackground(() async {
        try {
          final changed = await sendJournal.complete(
            id,
            item.scope,
            ComposerSendStatus.committed,
            commitId: item.daemonId,
          );
          if (changed) {
            composerDrafts.reconcile(
              id,
              ComposerSendStatus.committed,
              commitId: item.daemonId,
            );
            if (!_disposed) notifyListeners();
          }
          final confirmed = sendJournal.record(id);
          if (confirmed?.commitId == item.daemonId) {
            await _repairCommittedSeed(confirmed!);
          }
        } finally {
          _reconcilingSendIds.remove(id);
        }
      }(), 'reconcileSendFromHistory');
    }
    final lastActivity = items.where(_messageEffectsEligible).lastOrNull;
    if (!historyTimelineReadSuppressed &&
        timeline != null &&
        lastActivity != null) {
      _touchFriendActivity(
        timeline.scope.peerId,
        lastActivity.createdAt,
        incoming: false,
        file: false,
        countUnread: false,
      );
    }
    _markLatestIncomingDisplayed();
    notifyListeners();
  }

  void _markLatestIncomingDisplayed() {
    if (historyTimelineReadSuppressed ||
        _protectedSurfaceLocked ||
        captureGateVisible) {
      return;
    }
    final timeline = _conversationTimeline;
    // A conversation left on screen while the app is backgrounded is not
    // being read — marking it displayed is what made every sender see
    // "read" instantly (the WhatsApp-semantics bug).
    if (timeline == null ||
        !_foreground ||
        (defaultTargetPlatform == TargetPlatform.windows && !_viewFocused) ||
        _visibleConversationPeerId != timeline.scope.peerId) {
      return;
    }
    // No read receipt may follow a removal notice or answer a peer who left.
    if (!timeline.scope.isGroup && _directPeerClosed(timeline.scope.peerId)) {
      return;
    }
    if (!timeline.scope.isGroup) {
      if (!_loadedDmTopicScopes.contains(timeline.scope)) return;
      final state = _dmTopicStates[timeline.scope];
      if (state?.customTopics.isNotEmpty ?? false) {
        _markLatestIncomingDmTopicRead(timeline, state!);
        return;
      }
    }
    final topicId = timeline.scope.isGroup ? _visibleGroupTopicId : null;
    if (timeline.scope.isGroup && topicId == null) return;
    final incoming = timeline.items
        .where(
          (item) =>
              item.direction == TimelineDirection.incoming &&
              (timeline.scope.isGroup || item.topicId == DmTopicWire.mainId) &&
              (!timeline.scope.isGroup ||
                  (item is TimelineTextItem
                      ? GroupTopicCodec.decode(item.text).topicId == topicId
                      : (item.roomId ?? 'general') == topicId)),
        )
        .lastOrNull;
    final displayedKey = (scope: timeline.scope, topicId: topicId);
    if (incoming == null ||
        _displayedMessageIds[displayedKey] == incoming.daemonId) {
      return;
    }
    _displayedMessageIds[displayedKey] = incoming.daemonId;
    _runInBackground(
      jami.setMessageDisplayed(
        timeline.scope.peerId,
        timeline.scope.conversationId,
        incoming.daemonId,
      ),
      'setMessageDisplayed(${timeline.scope.peerId})',
    );
  }

  void _markLatestIncomingDmTopicRead(
    ConversationTimelineController timeline,
    DmTopicState state,
  ) {
    final topicId = _visibleDmTopicId;
    if (topicId == null ||
        topicId != selectedDmTopicId ||
        state.topic(topicId) == null) {
      return;
    }
    final incoming = timeline.items
        .where(
          (item) =>
              item.direction == TimelineDirection.incoming &&
              state.topic(item.topicId)?.id == topicId,
        )
        .lastOrNull;
    final displayedKey = (scope: timeline.scope, topicId: topicId);
    if (incoming == null ||
        state.effectiveRead(incoming.daemonId, readerId: jamiId) ||
        _displayedMessageIds[displayedKey] == incoming.daemonId) {
      return;
    }
    final revision = state.nextRevision(
      DmTopicOperation.read,
      topicId,
      authorId: jamiId,
    );
    if (revision <= 0) return;
    if (!incoming.topicTagged) {
      _runInBackground(
        jami.setMessageDisplayed(
          timeline.scope.peerId,
          timeline.scope.conversationId,
          incoming.daemonId,
        ),
        'setMessageDisplayed(${timeline.scope.peerId})',
      );
    }
    _displayedMessageIds[displayedKey] = incoming.daemonId;
    _runInBackground(() async {
      final committed = await _commitDmTopicEvent(
        timeline.scope,
        DmTopicEvent.read(
          topicId: topicId,
          revision: revision,
          messageId: incoming.daemonId,
        ),
      );
      if (!committed &&
          _displayedMessageIds[displayedKey] == incoming.daemonId) {
        _displayedMessageIds.remove(displayedKey);
      }
    }(), 'sendDmTopicRead(${timeline.scope.peerId})');
  }

  void _touchFriendActivity(
    String peer,
    DateTime at, {
    required bool incoming,
    required bool file,
    required bool countUnread,
  }) {
    if (!_friends.containsKey(peer) &&
        !_groups.values.any((group) => group.ownerKey == peer)) {
      return;
    }
    final previous = _friendActivity[peer] ?? const FriendActivity();
    final previousAt = previous.lastActivityAt;
    final latest = previousAt == null || at.isAfter(previousAt)
        ? at
        : previousAt;
    final unread =
        incoming &&
        countUnread &&
        (historyTimelineReadSuppressed || _visibleConversationPeerId != peer);
    _friendActivity[peer] = FriendActivity(
      lastActivityAt: latest,
      unreadMessages: previous.unreadMessages + (unread && !file ? 1 : 0),
      unreadFiles: previous.unreadFiles + (unread && file ? 1 : 0),
    );
  }

  TimelineParseResult? _admittedChatEvent(JamiEvent event) {
    final scope = _chatEventScope(event);
    final item = _chatEventItem(event);
    if (scope == null ||
        item == null ||
        scope.accountId != accountId ||
        (scope.isGroup
            ? _scopeForGroup(scope.conversationId) != scope
            : _scopeForPeer(scope.peerId) != scope)) {
      return null;
    }
    return const TimelineItemParser().parse(
      expectedScope: scope,
      localAuthorId: jamiId,
      allowedRemoteAuthorIds: scope.isGroup
          ? _groups[scope.conversationId]?.activeMemberIds
          : {scope.peerId},
      value: item,
    );
  }

  void _recordFriendActivity(JamiEvent event) {
    if (event.type != 'chatMessage') return;
    final admitted = _admittedChatEvent(event)?.item;
    if (admitted == null ||
        admitted.versionId != admitted.daemonId ||
        !_messageEffectsEligible(admitted)) {
      return;
    }
    final scope = _chatEventScope(event);
    final item = _chatEventItem(event);
    if (scope == null ||
        item == null ||
        (scope.isGroup
            ? _scopeForGroup(scope.conversationId) != scope
            : _scopeForPeer(scope.peerId) != scope) ||
        item['operation'] == 'edit' ||
        item['deleted'] == true) {
      return;
    }
    final daemonId = _asString(item['daemonId']);
    if (daemonId.isEmpty) return;
    if (_seenConversationActivity.length >= 32768 ||
        !_seenConversationActivity.add((scope, daemonId))) {
      return;
    }
    final seconds = _asInt(item['timestampSeconds'], -1);
    if (seconds < 0) return;
    final author = _asString(item['authorId']);
    final mime = _asString(item['mimeType']);
    _touchFriendActivity(
      scope.peerId,
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
      incoming: scope.isGroup ? author != jamiId : author == scope.peerId,
      file: mime == TimelineWireContract.fileMimeType,
      countUnread: true,
    );
    notifyListeners();
  }

  // History may retain unknown-topic content for later canonical reconciliation,
  // but it must not produce notification, activity, unread, or hologram effects.
  bool _messageEffectsEligible(ConversationTimelineItem item) {
    if (item is TimelineDmTopicEventItem) return false;
    final scope = item.scope;
    if (scope.isGroup) {
      final group = _groups[scope.conversationId];
      final room =
          item.roomId ??
          (item is TimelineTextItem
              ? GroupTopicCodec.decode(item.text).topicId
              : 'general');
      return group != null &&
          group.layout.rooms.any(
            (candidate) =>
                candidate.id == room && candidate.kind == GroupRoomKind.text,
          );
    }
    if (item.topicId == DmTopicWire.mainId) return true;
    if (!_loadedDmTopicScopes.contains(scope)) return false;
    final topic = _dmTopicStates[scope]?.topic(item.topicId);
    return topic != null && !topic.archivedBy.contains(jamiId);
  }

  ConversationScope? _chatEventScope(JamiEvent event) {
    final account = _asString(event.data['accountId']);
    final peer = _asString(event.data['peerJamiId']);
    final conversation = _asString(event.data['conversationId']);
    if (account.isEmpty || peer.isEmpty || conversation.isEmpty) return null;
    return ConversationScope(
      accountId: account,
      peerId: peer,
      conversationId: conversation,
      kind: _groups.containsKey(conversation)
          ? ConversationKind.group
          : ConversationKind.direct,
    );
  }

  Map<String, Object?>? _chatEventItem(JamiEvent event) {
    Object? raw = event.data['item'];
    if (raw == null && event.data['itemJson'] is String) {
      try {
        raw = jsonDecode(event.data['itemJson'] as String);
      } catch (_) {
        return null;
      }
    }
    if (raw is! Map) return null;
    return {
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  void _scheduleTimelineRefresh(ConversationScope scope) {
    // Coalesce to the latest selected owner rather than merely suppressing a
    // second callback. Without retaining that owner, an A callback followed by
    // an immediate A→B selection and B callback would run A's stale microtask,
    // drop it, and silently lose B's required refresh.
    _queuedTimelineRefreshScope = scope;
    if (_timelineRefreshQueued) return;
    _timelineRefreshQueued = true;
    scheduleMicrotask(() {
      _timelineRefreshQueued = false;
      final requestedScope = _queuedTimelineRefreshScope;
      _queuedTimelineRefreshScope = null;
      final timeline = _conversationTimeline;
      if (_disposed ||
          requestedScope == null ||
          timeline == null ||
          timeline.scope != requestedScope) {
        return;
      }
      _runInBackground(timeline.refresh(), 'refreshChat(required)');
    });
  }

  void _scheduleSyncedTimelinesRefresh() {
    if (_syncedTimelinesRefreshQueued) {
      _syncedTimelinesRefreshAgain = true;
      return;
    }
    _syncedTimelinesRefreshQueued = true;
    final epoch = _syncedTimelinesRefreshEpoch;
    final activeAccount = accountId;
    scheduleMicrotask(() {
      _runInBackground(() async {
        try {
          // Bound native refresh concurrency across app-opened conversations
          // and the separate, currently visible widget projection.
          final scopes = <ConversationScope>{
            for (final scope in _conversationTimelines.keys)
              if (scope.accountId == activeAccount) scope,
          };
          final widgetScope = _widgetChatTimeline?.scope;
          if (widgetScope != null &&
              widgetScope.accountId == activeAccount &&
              _widgetTimelineForScope(widgetScope) != null) {
            scopes.add(widgetScope);
          }
          for (final scope in scopes) {
            if (_disposed ||
                activeAccount == null ||
                epoch != _syncedTimelinesRefreshEpoch) {
              return;
            }
            final timelines = _timelinesForScope(scope).toList(growable: false);
            for (final timeline in timelines) {
              if (epoch != _syncedTimelinesRefreshEpoch ||
                  (!identical(_conversationTimelines[scope], timeline) &&
                      !identical(_widgetTimelineForScope(scope), timeline))) {
                continue;
              }
              await timeline.refresh();
            }
          }
        } finally {
          if (!_disposed && epoch == _syncedTimelinesRefreshEpoch) {
            _syncedTimelinesRefreshCooldown = Timer(
              const Duration(seconds: 2),
              () {
                _syncedTimelinesRefreshCooldown = null;
                _syncedTimelinesRefreshQueued = false;
                final again = _syncedTimelinesRefreshAgain;
                _syncedTimelinesRefreshAgain = false;
                if (again) _scheduleSyncedTimelinesRefresh();
              },
            );
          }
        }
      }(), 'refreshChat(synchronized)');
    });
  }

  Future<void> refreshChat() async {
    final timeline = _conversationTimeline;
    if (timeline != null) await timeline.refresh();
  }

  Future<void> loadOlderChat() async {
    final timeline = _conversationTimeline;
    if (timeline != null) await timeline.loadMore();
  }

  Future<bool> sendText(String body, {String replyTo = ''}) async {
    final result = await sendOwnedContent(body, replyTo: replyTo);
    if (result != null &&
        (result.status == ComposerSendStatus.committed ||
            result.status == ComposerSendStatus.failedBeforeCommit)) {
      await sendJournal.acknowledge(result.operationId);
    }
    return result?.status == ComposerSendStatus.committed;
  }

  String _replyChannel(ConversationTimelineItem item) => item.scope.isGroup
      ? item.roomId ??
            (item is TimelineTextItem
                ? GroupTopicCodec.decode(item.text).topicId
                : 'general')
      : item.topicId;

  ConversationTimelineItem? replyTargetById(String daemonId) {
    final scope = selectedConversationScope;
    if (_disposed ||
        _restoringIdentity ||
        _protectedSurfaceLocked ||
        captureGateVisible ||
        _captureBusy ||
        screen != Screen.home ||
        scope == null ||
        scope.accountId != accountId ||
        daemonId.isEmpty) {
      return null;
    }
    final group = selectedGroup;
    final channel = scope.isGroup && group != null
        ? selectedGroupTopicId(group)
        : selectedDmTopicId;
    return conversationItems
        .where(
          (item) =>
              item.scope == scope &&
              item.daemonId == daemonId &&
              _replyChannel(item) == channel &&
              _messageEffectsEligible(item),
        )
        .firstOrNull;
  }

  ConversationTimelineItem? replyTargetFor(ConversationTimelineItem reply) {
    if (reply.scope != selectedConversationScope ||
        !_messageEffectsEligible(reply)) {
      return null;
    }
    final target = replyTargetById(reply.replyTo);
    return target != null && _replyChannel(target) == _replyChannel(reply)
        ? target
        : null;
  }

  bool beginReply(ConversationTimelineItem target, {required Object owner}) {
    if (owner != conversationActionOwner) return false;
    final current = replyTargetById(target.daemonId);
    if (current == null ||
        current.scope != target.scope ||
        current.versionId != target.versionId) {
      return false;
    }
    final selected = composerDrafts.selectReply(
      ComposerDraftKey(current.scope, _replyChannel(current)),
      current.daemonId,
    );
    if (selected) notifyListeners();
    return selected;
  }

  bool reactionBusy(ConversationTimelineItem target) =>
      _reactionSends.contains((target.scope, target.daemonId)) ||
      sendJournal.reactionUnresolved(target.scope, target.daemonId);

  Future<bool> toggleReaction(
    ConversationTimelineItem target,
    String emoji, {
    required Object owner,
  }) async {
    ConversationTimelineItem? currentTarget() {
      if (conversationActionOwner != owner ||
          appearOffline ||
          (!target.scope.isGroup && _directPeerClosed(target.scope.peerId))) {
        return null;
      }
      final current = replyTargetById(target.daemonId);
      return current != null &&
              current.scope == target.scope &&
              current.versionId == target.versionId &&
              current.reactions.complete
          ? current
          : null;
    }

    final current = currentTarget();
    final author = JamiIdentity.fingerprint(jamiId);
    if (current == null ||
        author == null ||
        !ReactionWire.identity(author) ||
        !ReactionWire.identity(target.daemonId) ||
        !ReactionWire.palette.contains(emoji) ||
        reactionBusy(target)) {
      return false;
    }
    final removals = current.reactions.removalCommitIds(author, emoji)!;
    final key = (target.scope, target.daemonId);
    _reactionSends.add(key);
    chatError = null;
    notifyListeners();
    try {
      // Duplicate own reactions are separate signed commits. Remove each exact
      // commit, stopping on uncertainty instead of repeating the whole action.
      for (final removed in removals.isEmpty ? [''] : removals) {
        final before = currentTarget();
        if (before == null) return false;
        if (removed.isNotEmpty &&
            !before.reactions.entries.any(
              (entry) =>
                  entry.commitId == removed &&
                  entry.authorId == author &&
                  entry.emoji == emoji,
            )) {
          continue; // A native signal already removed it.
        }
        final channel = _replyChannel(before);
        final temporary = ComposerDraftSession(
          ComposerDraftKey(target.scope, channel),
        )..activate(owner);
        final operation = temporary
            .begin(ComposerOperationKind.sendText, owner)!
            .id;
        if (!await sendJournal.prepare(
          SendJournalRecord(
            operationId: operation,
            scope: target.scope,
            status: ComposerSendStatus.pending,
            reactionTarget: target.daemonId,
          ),
        )) {
          if (conversationActionOwner == owner) {
            chatError =
                'The reaction could not be saved. Nothing new was sent.';
          }
          return false;
        }
        final after = currentTarget();
        final removalStillOwned = removed.isEmpty
            ? !(after?.reactions.entries.any(
                    (entry) => entry.authorId == author && entry.emoji == emoji,
                  ) ??
                  false)
            : (after?.reactions.entries.any(
                    (entry) =>
                        entry.commitId == removed &&
                        entry.authorId == author &&
                        entry.emoji == emoji,
                  ) ??
                  false);
        if (after == null || !removalStillOwned) {
          await sendJournal.complete(
            operation,
            target.scope,
            ComposerSendStatus.failedBeforeCommit,
          );
          await sendJournal.acknowledge(operation);
          return false;
        }
        String admission;
        try {
          admission = await jami.sendOwnedReaction(
            accountId: target.scope.accountId,
            peerJamiId: target.scope.peerId,
            conversationId: target.scope.conversationId,
            messageId: target.daemonId,
            operationId: operation,
            emoji: removed.isEmpty ? emoji : '',
            removedId: removed,
            topicId: target.scope.isGroup ? '' : channel,
            roomId: target.scope.isGroup ? channel : '',
          );
        } catch (_) {
          admission = 'unknown';
        }
        if (admission != 'pending') {
          await sendJournal.complete(
            operation,
            target.scope,
            admission == 'failed-before-commit'
                ? ComposerSendStatus.failedBeforeCommit
                : ComposerSendStatus.unknown,
          );
        }
        final result = await sendJournal.wait(operation);
        if (result?.status != ComposerSendStatus.committed) {
          final failed =
              result?.status == ComposerSendStatus.failedBeforeCommit;
          if (failed) await sendJournal.acknowledge(operation);
          if (conversationActionOwner == owner) {
            chatError = failed
                ? 'The reaction was not sent. You can try again.'
                : 'The reaction outcome is not yet known. Do not send it again.';
          }
          return false;
        }
        if (!_disposed && conversationActionOwner == owner) {
          await _conversationTimelines[target.scope]?.refresh();
        }
        await sendJournal.acknowledge(operation);
      }
      return true;
    } finally {
      _reactionSends.remove(key);
      if (!_disposed) notifyListeners();
    }
  }

  Future<SendJournalRecord?> sendOwnedContent(
    String body, {
    String replyTo = '',
    String? operationId,
    String mimeType = TimelineWireContract.textMimeType,
    String roomId = '',
  }) async {
    final scope = selectedConversationScope;
    final owner = conversationActionOwner;
    if (_dmTopicSelectionPending(scope)) {
      _reportDmTopicPending();
      return null;
    }
    bool replyIsCurrent() {
      if (replyTo.isEmpty) return true;
      final target = replyTargetById(replyTo);
      if (target == null || target.scope != scope) return false;
      if (scope!.isGroup) {
        final channel = roomId.isNotEmpty
            ? roomId
            : mimeType == TimelineWireContract.textMimeType
            ? GroupTopicCodec.decode(body).topicId
            : 'general';
        return _replyChannel(target) == channel;
      }
      return target.topicId == selectedDmTopicId;
    }

    final topicId =
        scope != null &&
            !scope.isGroup &&
            _loadedDmTopicScopes.contains(scope) &&
            (_dmTopicStates[scope]?.customTopics.isNotEmpty ?? false)
        ? selectedDmTopicId
        : '';
    if (sendingChatMessage ||
        appearOffline ||
        scope == null ||
        (!scope.isGroup && _directPeerClosed(scope.peerId)) ||
        _conversationTimeline?.scope != scope ||
        body.trim().isEmpty ||
        body.length > TimelineWireContract.maxTextCodeUnits ||
        replyTo.length > 1024 ||
        !replyIsCurrent() ||
        (mimeType != TimelineWireContract.textMimeType &&
            mimeType != RichContentWire.stickerMime) ||
        (mimeType == RichContentWire.stickerMime &&
            StickerContent.parse(body) == null)) {
      return null;
    }
    final hologram =
        mimeType == RichContentWire.stickerMime &&
        StickerContent.parse(body)?.presentation ==
            StickerPresentation.hologram;
    if (hologram &&
        (scope.isGroup ||
            _hologramManifest
                    ?.byId(StickerContent.parse(body)!.assetId)
                    ?.hologramEligible !=
                true)) {
      return null;
    }
    final temporary = ComposerDraftSession(ComposerDraftKey(scope, topicId))
      ..activate(owner);
    final id =
        operationId ??
        temporary.begin(ComposerOperationKind.sendText, owner)!.id;
    sendingChatMessage = true;
    chatError = null;
    notifyListeners();
    try {
      if (hologram) {
        _refreshHologramPrivacy();
        _holograms.begin(id, scope.conversationId, [scope.peerId]);
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        _holograms.freeze(id);
      }
      final record = SendJournalRecord(
        operationId: id,
        scope: scope,
        status: ComposerSendStatus.pending,
      );
      if (!await sendJournal.prepare(record)) {
        chatError =
            'The send journal could not be saved or has unresolved operations. Nothing new was sent.';
        return null;
      }
      if (_disposed ||
          appearOffline ||
          conversationActionOwner != owner ||
          !replyIsCurrent()) {
        await sendJournal.complete(
          id,
          scope,
          ComposerSendStatus.failedBeforeCommit,
        );
        return sendJournal.record(id);
      }
      String admission;
      try {
        admission = await jami.sendOwnedMessage(
          accountId: scope.accountId,
          peerJamiId: scope.peerId,
          conversationId: scope.conversationId,
          mimeType: mimeType,
          body: body,
          operationId: id,
          replyTo: replyTo,
          topicId: topicId,
          roomId: roomId,
        );
      } catch (_) {
        admission = 'unknown';
      }
      if (admission != 'pending') {
        await sendJournal.complete(
          id,
          scope,
          admission == 'failed-before-commit'
              ? ComposerSendStatus.failedBeforeCommit
              : ComposerSendStatus.unknown,
        );
      }
      final result = await sendJournal.wait(id);
      if (hologram &&
          result?.status == ComposerSendStatus.committed &&
          result?.commitId != null) {
        _holograms.committed(id, result!.commitId!);
      } else if (hologram) {
        _holograms.abandon(id);
      }
      if (result?.status == ComposerSendStatus.committed) {
        _wakeConversationOwner((
          peerId: scope.peerId,
          conversationId: scope.conversationId,
        ));
        await _conversationTimelines[scope]?.refresh();
      } else if (conversationActionOwner == owner) {
        chatError = result?.status == ComposerSendStatus.failedBeforeCommit
            ? 'The message was not committed. You can try again.'
            : 'The send outcome is not yet known. Keep this draft; do not resend it.';
      }
      return result;
    } finally {
      if (hologram) _holograms.abandon(id);
      sendingChatMessage = false;
      if (!_disposed) notifyListeners();
    }
  }

  EffectiveMicrophoneMode microphoneModeForFriend(String id) {
    final scope = _scopeForPeer(id);
    final effective = scope == null
        ? EffectiveMicrophoneMode(
            mode: appSettings.globalMicrophoneMode,
            source: MicrophoneModeSource.globalDefault,
          )
        : appSettings.microphoneModeFor(scope);
    return EffectiveMicrophoneMode(
      mode: _supportedMicrophoneMode(effective.mode),
      source: effective.source,
    );
  }

  EffectiveMicrophoneMode microphoneModeForGroup(String conversationId) {
    final scope = _scopeForGroup(conversationId);
    final effective = scope == null
        ? EffectiveMicrophoneMode(
            mode: appSettings.globalMicrophoneMode,
            source: MicrophoneModeSource.globalDefault,
          )
        : appSettings.microphoneModeFor(scope);
    return EffectiveMicrophoneMode(
      mode: _supportedMicrophoneMode(effective.mode),
      source: effective.source,
    );
  }

  Future<bool> setGlobalMicrophoneMode(MicrophoneMode mode) => _saveAppSettings(
    appSettings
        .withGlobalMicrophoneMode(_supportedMicrophoneMode(mode))
        .withMicrophoneReviewRequired(false),
  );

  bool get appLockEnabled => appSettings.appLockEnabled;
  AppearancePreset get appearancePreset => appSettings.appearancePreset;

  Future<bool> setAmbientVibe(AmbientVibe vibe) =>
      _saveAppSettings(appSettings.withAmbientVibe(vibe));

  bool get appearanceBridgeReady =>
      !_disposed && _startupPrepared && _settingsDocumentWritable;
  bool get appearanceBridgeWritable =>
      appearanceBridgeReady &&
      settingsControlsEnabled &&
      !_protectedSurfaceLocked &&
      !captureGateVisible;
  Object get appearanceBridgeOwner => (
    _accountRevision,
    _conversationSelectionRevision,
    _searchPrivacyRevision,
  );

  Future<bool> setWidgetAppearance({
    AppearancePreset? theme,
    AmbientVibe? vibe,
    int? opacity,
    int? intensity,
    bool? animations,
  }) {
    if (!appearanceBridgeWritable) return Future.value(false);
    var next = appSettings;
    if (theme != null) next = next.withAppearancePreset(theme);
    if (vibe != null) next = next.withAmbientVibe(vibe);
    if (opacity != null) next = next.withVibeOpacity(opacity);
    if (intensity != null) next = next.withVibeIntensity(intensity);
    if (animations != null) next = next.withChatMotionEnabled(animations);
    return _saveAppSettings(next);
  }

  Future<bool> setVibeIntensity(int intensity) =>
      _saveAppSettings(appSettings.withVibeIntensity(intensity));

  Future<bool> setVibeOpacity(int opacity) =>
      _saveAppSettings(appSettings.withVibeOpacity(opacity));

  Future<bool> setRememberDefaultWindowPosition(bool remember) =>
      _saveAppSettings(appSettings.withRememberDefaultWindowPosition(remember));

  Future<bool> setWindowEdgeSpacing(WindowEdgeSpacing spacing) =>
      _saveAppSettings(appSettings.withWindowEdgeSpacing(spacing));

  Future<bool> setWindowOpenAnimation(WindowCloseAnimation animation) =>
      _saveAppSettings(appSettings.withWindowOpenAnimation(animation));

  Future<bool> setWindowMinimizeAnimation(WindowCloseAnimation animation) =>
      _saveAppSettings(appSettings.withWindowMinimizeAnimation(animation));

  Future<bool> setWindowCloseAnimation(WindowCloseAnimation animation) =>
      _saveAppSettings(appSettings.withWindowCloseAnimation(animation));

  Future<bool> setWindowOpenDurationMs(int duration) =>
      _saveAppSettings(appSettings.withWindowOpenDurationMs(duration));

  Future<bool> setWindowMinimizeDurationMs(int duration) =>
      _saveAppSettings(appSettings.withWindowMinimizeDurationMs(duration));

  Future<bool> setWindowCloseDurationMs(int duration) =>
      _saveAppSettings(appSettings.withWindowCloseDurationMs(duration));
  bool get shareActivityPresence => appSettings.shareActivityPresence;
  UnreadBadgePlacement get unreadBadgePlacement =>
      appSettings.unreadBadgePlacement;
  bool get showMessageInNotification => appSettings.showMessageInNotification;
  bool get reliableBackgroundNotifications =>
      googleWakeAllowed && appSettings.reliableBackgroundNotifications;
  bool get backgroundWakeAvailable => _backgroundWakeAvailable;
  Object? get googleConsentOwner =>
      settingsControlsEnabled &&
          _foreground &&
          !_protectedSurfaceLocked &&
          !captureGateVisible
      ? (_accountRevision, _searchPrivacyRevision)
      : null;
  bool get googleWakeAvailable =>
      defaultTargetPlatform == TargetPlatform.android
      ? backgroundWakeAvailable
      : WakeRelayConfig.validBaseUrl(WakeRelayConfig.baseUrl);
  bool? _googleWakeAllowed;
  bool? _googleWakeChoiceMade;
  bool? _googleNearbyAllowed;
  int _googleNearbyRevision = 0;
  bool get googleWakeChoiceMade =>
      _googleWakeChoiceMade ??= prefs.containsKey('googleWakeConsent.v1');
  bool get googleWakeAllowed =>
      _googleWakeAllowed ??= prefs.getBool('googleWakeConsent.v1') == true;
  bool get googleNearbyAllowed =>
      _googleNearbyAllowed ??= prefs.getBool('googleNearbyConsent.v1') == true;

  Future<bool> setGoogleNearbyAllowed(bool enabled) async {
    if (!settingsControlsEnabled) return false;
    final revision = ++_googleNearbyRevision;
    // Snapshot before SharedPreferences optimistically changes its cache.
    _googleNearbyAllowed = googleNearbyAllowed && enabled;
    nearby?.endVisible();
    try {
      if (!await prefs.setBool('googleNearbyConsent.v1', enabled)) {
        throw StateError('Google Nearby choice was not saved');
      }
      if (_disposed || revision != _googleNearbyRevision) return false;
      _googleNearbyAllowed = enabled;
      if (defaultTargetPlatform == TargetPlatform.android) {
        final applied = await const MethodChannel(
          'syb.l/nearby_radio',
        ).invokeMethod<bool>('setGoogleAllowed', {'enabled': enabled});
        if (applied != true) throw StateError('Nearby choice was not applied');
      }
      settingsError = null;
      notifyListeners();
      return true;
    } catch (_) {
      if (_disposed || revision != _googleNearbyRevision) return false;
      _googleNearbyAllowed = false;
      // Removal also means off; retry durable revocation after a failed write.
      final revoked = await _removeGoogleConsent('googleNearbyConsent.v1');
      if (_disposed || revision != _googleNearbyRevision) return false;
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await const MethodChannel(
            'syb.l/nearby_radio',
          ).invokeMethod<bool>('setGoogleAllowed', {'enabled': false});
        } catch (_) {}
      }
      settingsError = revoked
          ? 'Could not apply your Nearby choice. Google Nearby is off. Please try again.'
          : 'Google Nearby is off for now. Could not save the choice; retry before restarting.';
      notifyListeners();
      return false;
    }
  }

  Future<bool> _removeGoogleConsent(String key) async {
    try {
      return await prefs.remove(key);
    } catch (_) {
      return false;
    }
  }

  bool get effectiveReliableBackgroundNotifications =>
      _backgroundWakeApplied &&
      _backgroundWakeAppliedOwner == (accountId, _accountRevision) &&
      BackgroundWakePolicy.effective(
        requested:
            googleWakeAllowed && appSettings.reliableBackgroundNotifications,
        platform: defaultTargetPlatform,
        connectionProfile: connectionProfile,
        firebaseAvailable: _backgroundWakeAvailable,
      );
  GroupHeaderPlacement get groupHeaderPlacement =>
      appSettings.groupHeaderPlacement;
  MobileGroupNavigation get mobileGroupNavigation =>
      appSettings.mobileGroupNavigation;
  bool get chatMotionEnabled => appSettings.chatMotionEnabled;
  bool get chatActivityIndicatorsEnabled =>
      appSettings.chatActivityIndicatorsEnabled;
  MessageTimestampStyle get messageTimestampStyle =>
      appSettings.messageTimestampStyle;
  MessageReceiptStyle get messageReceiptStyle =>
      appSettings.messageReceiptStyle;
  MessageReceiptVisibility get messageReceiptVisibility =>
      appSettings.messageReceiptVisibility;
  bool get repeatMessageAuthorAfterPause =>
      appSettings.repeatMessageAuthorAfterPause;
  TopicStripSurfaceSettings get topicStripSurfaceSettings =>
      appSettings.topicStripSurfaceSettings;

  /// Persistence callback for `AppLockController`.
  ///
  /// The dedicated latch is authoritative. Enabling commits it before the
  /// legacy settings mirror; disabling writes the mirror first and the latch
  /// last. Every crash point therefore preserves the more restrictive state.
  Future<void> setAppLockEnabled(bool enabled) async {
    if (!_startupPrepared) {
      throw StateError('App settings are still being prepared');
    }
    if (_adoptingAccount) {
      throw StateError('Identity adoption is in progress');
    }
    if (_restoringIdentity) {
      throw StateError('Identity restore is in progress');
    }
    if (_captureBusy) {
      throw StateError('a capture-protection transition is in flight');
    }
    if (_settingsWritesInFlight != 0) {
      throw StateError('an app settings write is in flight');
    }
    if (enabled == appSettings.appLockEnabled) return;
    _settingsWritesInFlight = 1;
    final next = appSettings.withAppLockEnabled(enabled);
    notifyListeners();
    try {
      if (enabled) {
        // Close the native notification boundary before making app lock
        // durable; a crash at any later point can only leave it stricter.
        await jami.setMessageNotificationPreview(
          appSettings.showMessageInNotification,
          appLockEnabled: true,
        );
        await _appLockLatchRepository.save(true);
        appSettings = next;
        if (_settingsDocumentWritable) {
          try {
            await _settingsRepository.save(next);
          } catch (error) {
            _appendSettingsError(
              'App lock is enabled, but its legacy settings mirror could not be updated.',
            );
            dlog('app-lock settings mirror failed: $error');
          }
        }
      } else {
        if (_settingsDocumentWritable) {
          await _settingsRepository.save(next);
        }
        await _appLockLatchRepository.save(false);
        appSettings = next;
        try {
          await jami.setMessageNotificationPreview(
            appSettings.showMessageInNotification,
            appLockEnabled: false,
          );
        } catch (error) {
          // App lock is already durably disabled; retaining generic native
          // notifications is safe and boot will retry the policy sync.
          _appendSettingsError(
            'App lock was disabled, but notifications remain restricted until the native policy can be applied.',
          );
          dlog('app-lock notification policy reset failed: $error');
        }
      }
    } catch (error) {
      settingsError = 'Could not save the app-lock policy.';
      dlog('app-lock save failed: $error');
      rethrow;
    } finally {
      _settingsWritesInFlight = 0;
      notifyListeners();
    }
  }

  Future<bool> setFolderHistoryLimit(int value) {
    if (!AppSettings.isValidFolderHistoryLimit(value)) {
      return Future.value(false);
    }
    return _saveAppSettings(appSettings.withFolderHistoryLimit(value));
  }

  Future<bool> setMaxIncomingFileBytes(int value) {
    if (!AppSettings.isValidMaxIncomingFileBytes(value)) {
      return Future.value(false);
    }
    return _saveAppSettings(appSettings.withMaxIncomingFileBytes(value));
  }

  Future<bool> setAppearancePreset(AppearancePreset preset) =>
      _saveAppSettings(appSettings.withAppearancePreset(preset));

  Future<bool> setUnreadBadgePlacement(UnreadBadgePlacement placement) =>
      _saveAppSettings(appSettings.withUnreadBadgePlacement(placement));

  Future<bool> setShowMessageInNotification(bool enabled) async {
    final saved = await _saveAppSettings(
      appSettings.withShowMessageInNotification(enabled),
    );
    if (!saved) return false;
    try {
      await jami.setMessageNotificationPreview(
        enabled,
        appLockEnabled: appSettings.appLockEnabled,
      );
      return true;
    } catch (error) {
      settingsError =
          'The notification preference was saved, but could not be applied yet.';
      dlog('setMessageNotificationPreview($enabled) failed: $error');
      notifyListeners();
      return false;
    }
  }

  Future<bool> setHologramPresentationEnabled(bool enabled) =>
      _saveAppSettings(appSettings.withHologramPresentationEnabled(enabled));

  FriendPreferenceScope? _friendPreferenceScope(String peer) {
    final owner = accountId;
    if (owner == null) return null;
    try {
      return FriendPreferenceScope(accountId: owner, peerId: peer);
    } on ArgumentError {
      return null;
    }
  }

  bool get canManageFriendPreferences =>
      !_disposed &&
      accountId != null &&
      screen == Screen.home &&
      !_restoringIdentity &&
      !_protectedSurfaceLocked &&
      !captureGateVisible &&
      !_captureBusy;

  FriendPreferences friendPreferencesFor(String peer) {
    final scope = _friendPreferenceScope(peer);
    return appSettings.friendPreferences[scope] ?? const FriendPreferences();
  }

  bool friendHologramsAllowed(String peer) {
    final scope = _friendPreferenceScope(peer);
    return scope != null && appSettings.allowsFriendHolograms(scope);
  }

  bool messageAlertsAllowed(ConversationScope scope) {
    if (!settingsWritable ||
        !appSettings.messageAlertsEnabled ||
        appSettings.friendPreferencesReviewRequired ||
        scope.accountId != accountId) {
      return false;
    }
    if (scope.isGroup) return true;
    final friendScope = _friendPreferenceScope(scope.peerId);
    return friendScope != null &&
        appSettings.allowsFriendMessageAlerts(friendScope);
  }

  Future<bool> setFriendPreferences(String peer, FriendPreferences value) {
    final scope = _friendPreferenceScope(peer);
    if (scope == null || _friends[scope.peerId]?.confirmed != true) {
      return Future.value(false);
    }
    return _saveAppSettings(appSettings.withFriendPreferences(scope, value));
  }

  Future<bool> setMessageAlertsEnabled(bool enabled) =>
      _saveAppSettings(appSettings.withMessageAlertsEnabled(enabled));

  Future<bool> resetUnreviewedFriendPreferences() {
    if (!appSettings.friendPreferencesReviewRequired) {
      return Future.value(false);
    }
    return _saveAppSettings(appSettings.resetUnreviewedFriendPreferences());
  }

  Future<bool> setReliableBackgroundNotifications(bool enabled) async {
    if (!settingsControlsEnabled) return false;
    final owner = (accountId, _accountRevision);
    final revision = ++_backgroundWakePreferenceRevision;
    bool ownsPreference() =>
        !_disposed &&
        owner == (accountId, _accountRevision) &&
        revision == _backgroundWakePreferenceRevision;
    _googleWakeChoiceMade = googleWakeChoiceMade;
    _googleWakeAllowed = googleWakeAllowed && enabled;
    // Consent belongs to this installation, never to an imported identity backup.
    try {
      if (!await prefs.setBool('googleWakeConsent.v1', enabled)) {
        throw StateError('Google wake choice was not saved');
      }
    } catch (_) {
      if (!ownsPreference()) return false;
      _googleWakeAllowed = false;
      final revoked = await _removeGoogleConsent('googleWakeConsent.v1');
      if (!ownsPreference()) return false;
      if (revoked) _googleWakeChoiceMade = false;
      await _applyBackgroundWakePreference();
      if (!ownsPreference()) return false;
      settingsError = revoked
          ? 'Could not save your Google choice. Google wake is off. Please try again.'
          : 'Google wake is off for now. Could not save the choice; retry before restarting.';
      notifyListeners();
      return false;
    }
    if (!ownsPreference()) return false;
    _googleWakeAllowed = enabled;
    _googleWakeChoiceMade = true;
    final saved = await _saveAppSettings(
      appSettings.withReliableBackgroundNotifications(enabled),
    );
    if (!ownsPreference()) return false;
    if (!saved) {
      // A failed settings mirror must not leave a withdrawn native opt-in active.
      if (!enabled) await _applyBackgroundWakePreference();
      return false;
    }
    final pending = _applyBackgroundWakePreference();
    final applyRevision = _backgroundWakeApplyRevision;
    final applied = await pending;
    if (!ownsPreference() || applyRevision != _backgroundWakeApplyRevision) {
      return false;
    }
    if (!applied) {
      settingsError = enabled
          ? 'The background notification preference was saved, but could not be activated yet.'
          : 'Google wake is off, but cleanup is unfinished. Check your connection and retry cleanup.';
      notifyListeners();
    }
    return applied;
  }

  Future<bool> _applyBackgroundWakePreference({String? profileOverride}) async {
    final owner = (accountId, _accountRevision);
    final revision = ++_backgroundWakeApplyRevision;
    bool ownsApply() =>
        !_disposed &&
        owner == (accountId, _accountRevision) &&
        revision == _backgroundWakeApplyRevision;
    final profile = profileOverride ?? connectionProfile;
    final requested = BackgroundWakePolicy.effective(
      requested:
          googleWakeAllowed &&
          appSettings.reliableBackgroundNotifications &&
          !appearOffline,
      platform: defaultTargetPlatform,
      connectionProfile: profile,
      firebaseAvailable: _backgroundWakeAvailable,
    );
    try {
      final applied = await jami.setReliableBackgroundNotifications(
        enabled: requested,
        connectionProfile: profile,
        expectedAccountId: owner.$1,
      );
      if (!ownsApply()) return false;
      _backgroundWakeApplied = requested && applied;
      googleWakeCleanupPending = !requested && !applied;
      _backgroundWakeAppliedOwner = owner;
      notifyListeners();
      return applied;
    } catch (error) {
      if (!ownsApply()) return false;
      _backgroundWakeApplied = false;
      googleWakeCleanupPending = !requested;
      dlog('setReliableBackgroundNotifications($requested) failed: $error');
      notifyListeners();
      return false;
    }
  }

  Iterable<String> _wakeRecipients(TransferOwner owner) {
    if (!owner.peerId.startsWith('group:')) return [owner.peerId];
    return _groups[owner.conversationId]?.activeMemberIds ?? const <String>[];
  }

  void _wakeConversationOwner(TransferOwner owner) =>
      _wakePeers(_wakeRecipients(owner));

  void _wakePeers(Iterable<String> peers) {
    if (!reliableBackgroundNotifications ||
        appearOffline ||
        connectionProfile != 'jami') {
      return;
    }
    final handles = _wakeCapabilities.handlesFor(peers);
    if (handles.isEmpty) return;
    _runInBackground(_wakeRelay.wake(handles), 'wake peers');
  }

  Future<bool> setGroupHeaderPlacement(GroupHeaderPlacement placement) =>
      _saveAppSettings(appSettings.withGroupHeaderPlacement(placement));

  Future<bool> setMobileGroupNavigation(MobileGroupNavigation navigation) =>
      _saveAppSettings(appSettings.withMobileGroupNavigation(navigation));

  Future<bool> setChatMotionEnabled(bool enabled) =>
      _saveAppSettings(appSettings.withChatMotionEnabled(enabled));

  Future<bool> setMessageTimestampStyle(MessageTimestampStyle style) =>
      _saveAppSettings(appSettings.withMessageTimestampStyle(style));

  Future<bool> setMessageReceiptStyle(MessageReceiptStyle style) =>
      _saveAppSettings(appSettings.withMessageReceiptStyle(style));

  Future<bool> setMessageReceiptVisibility(
    MessageReceiptVisibility visibility,
  ) => _saveAppSettings(appSettings.withMessageReceiptVisibility(visibility));

  Future<bool> setRepeatMessageAuthorAfterPause(bool enabled) =>
      _saveAppSettings(appSettings.withRepeatMessageAuthorAfterPause(enabled));

  Future<bool> setTopicStripSurfaceSettings(
    TopicStripSurfaceSettings settings,
  ) => _saveAppSettings(appSettings.withTopicStripSurfaceSettings(settings));

  Future<bool> resetTopicStripSurfaceSettings() =>
      setTopicStripSurfaceSettings(const TopicStripSurfaceSettings());

  Future<bool> setChatActivityIndicatorsEnabled(bool enabled) async {
    final saved = await _saveAppSettings(
      appSettings.withChatActivityIndicatorsEnabled(enabled),
    );
    if (!saved || enabled) return saved;
    _retireLocalComposerActivity();
    _clearRemoteComposerActivities();
    return true;
  }

  Future<bool> setShareActivityPresence(bool enabled) {
    final revision = ++_activitySharingRevision;
    _presenceSharingSuppressed = true;
    _syncPresenceRuntime();
    final operation = _activitySharingTransitionTail.then(
      (_) => _setShareActivityPresence(enabled, revision),
    );
    _activitySharingTransitionTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<bool> _setShareActivityPresence(bool enabled, int revision) async {
    if (revision != _activitySharingRevision) return false;
    if (!enabled) {
      try {
        // Retire the native auto-pong disclosure before waiting for storage.
        await _applyPresenceMetadata(shareActivity: false);
      } catch (error) {
        settingsError =
            'Activity sharing could not be turned off. Please try again.';
        dlog('setPresenceMetadata(false) failed: $error');
        notifyListeners();
        return false;
      }
    }
    if (revision != _activitySharingRevision) return false;
    final saved = await _saveAppSettings(
      appSettings.withShareActivityPresence(enabled),
    );
    if (!saved) return false;
    if (revision != _activitySharingRevision) return false;
    try {
      if (enabled) await _applyPresenceMetadata(shareActivity: true);
      if (revision != _activitySharingRevision) return false;
      _presenceSharingSuppressed = false;
      _syncPresenceRuntime();
      if (enabled && _friends.isNotEmpty) await _presence.refreshAll();
      return true;
    } catch (error) {
      settingsError =
          'The activity-sharing preference was saved, but could not be applied yet.';
      dlog('setPresenceMetadata($enabled) failed: $error');
      notifyListeners();
      return false;
    }
  }

  Future<bool> setIdentityColor(IdentityColor color) async {
    if (!canSetIdentityColor) return false;
    final saved = await _saveAppSettings(appSettings.withIdentityColor(color));
    if (!saved) {
      notifyListeners();
      return false;
    }
    try {
      await _applyPresenceMetadata();
      if (_friends.isNotEmpty) await _presence.refreshAll();
      return true;
    } catch (error) {
      settingsError =
          'The identity color was saved, but could not be shared yet.';
      dlog('setIdentityColor(${color.storageValue}) failed: $error');
      notifyListeners();
      return false;
    }
  }

  Future<void> _applyPresenceMetadata({bool? shareActivity}) {
    final enabled =
        shareActivity ??
        (appSettings.shareActivityPresence && !_presenceSharingSuppressed);
    final color = identityColor.storageValue;
    // Boot, color changes, and opt-out can overlap. Keep the native flag in
    // request order so an older opt-in cannot finish after a later opt-out.
    final owner = linkedDeviceOwner;
    final operation = _presenceMetadataTail.then((_) async {
      if (_disposed || owner != linkedDeviceOwner) return;
      await jami.setPresenceMetadata(shareActivity: enabled, color: color);
    });
    _presenceMetadataTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<bool> setFriendMicrophoneMode(String id, MicrophoneMode? mode) async {
    final scope = _scopeForPeer(id);
    if (scope == null) return false;
    return _saveAppSettings(
      appSettings.withConversationMicrophoneMode(
        scope,
        mode == null ? null : _supportedMicrophoneMode(mode),
      ),
    );
  }

  Future<bool> setGroupMicrophoneMode(
    String conversationId,
    MicrophoneMode mode,
  ) async {
    final scope = _scopeForGroup(conversationId);
    if (scope == null) return false;
    final normalized = _supportedMicrophoneMode(mode);
    return _saveAppSettings(
      appSettings.withConversationMicrophoneMode(scope, normalized),
    );
  }

  Future<bool> _saveAppSettings(
    AppSettings next, {
    bool captureOwner = false,
    bool restoreOwner = false,
  }) async {
    if (_adoptingAccount) return false;
    if (!_startupPrepared && !captureOwner && !restoreOwner) return false;
    if (_restoringIdentity && !restoreOwner) return false;
    if (!_settingsDocumentWritable) {
      settingsError ??=
          'App settings are read-only because the saved document could not be loaded.';
      notifyListeners();
      return false;
    }
    if (_settingsWritesInFlight != 0 || (_captureBusy && !captureOwner)) {
      return false;
    }
    final previous = appSettings;
    _settingsWritesInFlight = 1;
    settingsError = null;
    appSettings = next;
    final accountOwner = _microphoneAccountOwner;
    final direct = call;
    final directRevision = direct?.manualMuteRevision;
    final directModeChanged =
        direct != null &&
        direct.micMode != microphoneModeForFriend(direct.peerId).mode;
    final group = groupCall;
    final groupConference = group?.conferenceId;
    final groupRevision = group?.manualMuteRevision;
    final groupModeChanged =
        group != null &&
        group.micMode != microphoneModeForGroup(group.conversationId).mode;
    _pendingMicrophoneModeCommit = () {
      if (_disposed || _microphoneAccountOwner != accountOwner) return;
      if (directModeChanged &&
          identical(call, direct) &&
          direct.manualMuteRevision == directRevision) {
        direct.manuallyMuted = false;
      }
      if (groupModeChanged &&
          identical(groupCall, group) &&
          group.conferenceId == groupConference &&
          group.manualMuteRevision == groupRevision) {
        group.manuallyMuted = false;
      }
    };
    notifyListeners();
    try {
      await _settingsRepository.save(next);
      _commitSavedMicrophoneMode();
      await _applySettingsToActiveCall();
      if (next.folderHistoryLimit != previous.folderHistoryLimit &&
          selectedConversationScope != null) {
        loadFolder();
      }
      return true;
    } catch (error) {
      appSettings = previous;
      settingsError = 'Could not save app settings.';
      dlog('settings save failed: $error');
      return false;
    } finally {
      _pendingMicrophoneModeCommit = null;
      _settingsWritesInFlight = 0;
      notifyListeners();
    }
  }

  /// Retries briefly while an imported identity's contacts become available.
  /// An account with no contacts stops after the bounded retry window.
  Future<void> _hydratePeerFromDaemon() async {
    final generation = _peerGeneration;
    for (var i = 0; i < 8; i++) {
      if (_disposed || generation != _peerGeneration) return;
      await _refreshFriendsFromDaemon();
      if (_disposed || generation != _peerGeneration) return;
      if (_friends.isNotEmpty) {
        loadFolder();
        notifyListeners();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Add a friend by their 40-hex Jami ID. The state boundary rejects malformed,
  /// self, and already-trusted identities before any daemon/network mutation;
  /// UI validation is only presentation, never the authority boundary.
  ///
  /// [nameHint] is the invite/Nearby name shown when adding; it labels the
  /// pending contact until their real profile arrives.
  Future<bool> addFriend(String hex, {String? nameHint}) async {
    final owner = linkedDeviceOwner;
    final clean = JamiIdentity.fingerprint(hex);
    if (owner.$1 == null ||
        _restoringIdentity ||
        _protectedSurfaceLocked ||
        clean == null ||
        clean == jamiId ||
        _friends.containsKey(clean)) {
      return false;
    }
    if (_settingPeer) return false;
    _settingPeer = true;
    try {
      final hint = friendNameHint(nameHint);
      _rememberNameHint(clean, hint);
      if (!await jami.addFriend(clean, expectedAccountId: owner.$1) ||
          owner != linkedDeviceOwner) {
        return false;
      }
      if (hint != null) {
        _runInBackground(
          prefs.setString('$_friendNameHintPrefix$clean', hint),
          'saveFriendNameHint',
        );
      }
      await _refreshFriendsFromDaemon();
      if (owner != linkedDeviceOwner || _protectedSurfaceLocked) return false;
      await selectFriend(clean);
      if (owner != linkedDeviceOwner) return false;
      _presence.cancelProbe(clean);
      _syncPresenceRuntime();
      _runInBackground(_presence.refresh(clean), 'refreshPresence(setPeer)');
      notifyListeners();
      return true;
    } finally {
      _settingPeer = false;
    }
  }

  Future<bool> setPeer(String hex) => addFriend(hex);

  Future<void> _openConversationLaunch(ConversationLaunchTarget launch) async {
    if (screen != Screen.home) {
      _pendingConversationLaunch = launch;
      return;
    }
    if (launch.accountId != null && launch.accountId != accountId) return;
    final action = captureConversationAction();
    if (!await jami.consumeConversationLaunch(launch) ||
        !ownsConversationAction(action)) {
      return;
    }
    if (launch.ownerKey == 'group:${launch.conversationId}') {
      if (!_groups.containsKey(launch.conversationId)) {
        await _refreshFriendsFromDaemon();
      }
      if (!ownsConversationAction(action)) return;
      await selectGroup(launch.conversationId, action: action);
      if (!ownsConversationAction(action)) return;
      final group = _groups[launch.conversationId];
      final topic = launch.topicId;
      if (group != null && topic != null) {
        await selectGroupTopic(group.conversationId, topic, action: action);
      }
      return;
    }
    final peer = JamiIdentity.fingerprint(launch.ownerKey);
    if (peer == null) return;
    if (_friends[peer]?.conversationId != launch.conversationId) {
      await _refreshFriendsFromDaemon();
    }
    if (!ownsConversationAction(action)) return;
    if (_friends[peer]?.conversationId == launch.conversationId) {
      await selectFriend(peer, action: action);
      if (!ownsConversationAction(action)) return;
      final topic = launch.topicId;
      if (topic != null) await selectDmTopic(topic, action: action);
      if (launch.startCall && ownsConversationAction(action)) {
        await startCallTo(peer);
      }
    }
  }

  Future<void> selectFriend(
    String id, {
    ConversationAction? action,
    bool fromHistorySearch = false,
  }) async {
    if (action != null && !ownsConversationAction(action)) return;
    final selected = _friends[id];
    if (selected == null) return;
    if (!fromHistorySearch) {
      _retireHistoryTimeline(releaseReadSuppression: true);
    }
    markConversationRead(id);
    if (!fromHistorySearch && selected.conversationId.isNotEmpty) {
      _runInBackground(
        jami.dismissMessageNotification(selected.conversationId),
        'dismissMessageNotification(friend)',
      );
    }
    if (peerId == id && selectedGroupId == null) return;
    _retireLocalComposerActivity();
    selectedGroupId = null;
    peerId = id;
    action?._owner = conversationActionOwner;
    peerPresence = selected.presence;
    _syncSelectedTimeline();
    final selectionOwner = conversationActionOwner;
    if (!await _persistConversationSelection(selectionOwner) ||
        _disposed ||
        selectionOwner != conversationActionOwner) {
      return;
    }
    loadFolder();
    _refreshDmTopicIntroduction();
    notifyListeners();
  }

  Future<void> selectGroup(
    String conversationId, {
    ConversationAction? action,
    bool fromHistorySearch = false,
  }) async {
    if (action != null && !ownsConversationAction(action)) return;
    if (!fromHistorySearch) {
      _retireHistoryTimeline(releaseReadSuppression: true);
    }
    if (!_groups.containsKey(conversationId)) return;
    if (!fromHistorySearch) {
      _runInBackground(
        jami.dismissMessageNotification(conversationId),
        'dismissMessageNotification(group)',
      );
    }
    if (selectedGroupId == conversationId && peerId == null) return;
    _retireLocalComposerActivity();
    selectedGroupId = conversationId;
    peerId = null;
    action?._owner = conversationActionOwner;
    peerPresence = PeerPresence.unknown;
    _syncSelectedTimeline();
    final selectionOwner = conversationActionOwner;
    if (!await _persistConversationSelection(selectionOwner) ||
        _disposed ||
        selectionOwner != conversationActionOwner) {
      return;
    }
    loadFolder();
    _refreshDmTopicIntroduction();
    notifyListeners();
  }

  bool _ownsGroupMutation(ConversationAction action) =>
      accountId?.isNotEmpty == true &&
      !_restoringIdentity &&
      ownsConversationAction(action);

  Future<bool> createGroup(
    String title,
    Iterable<String> memberIds, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!_ownsGroupMutation(action)) return false;
    final members = memberIds.toSet();
    final conversationId = await jami.createGroup(
      title,
      members,
      expectedAccountId: accountId,
    );
    if (conversationId.isEmpty || !_ownsGroupMutation(action)) return false;
    _wakePeers(members);
    await _refreshFriendsFromDaemon();
    if (!_ownsGroupMutation(action)) return false;
    if (!_groups.containsKey(conversationId)) {
      // ConversationReady/member callbacks may publish daemon truth a beat
      // later. Keep the accepted command successful; the refresh will surface it.
      return true;
    }
    await selectGroup(conversationId, action: action);
    return _ownsGroupMutation(action);
  }

  Future<bool> addGroupMembers(
    String conversationId,
    Iterable<String> memberIds, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!_ownsGroupMutation(action)) return false;
    final requested = memberIds.toSet();
    if (requested.isEmpty ||
        !await jami.addGroupMembers(
          conversationId,
          requested,
          expectedAccountId: accountId,
        ) ||
        !_ownsGroupMutation(action)) {
      return false;
    }
    _wakePeers(requested);
    for (var attempt = 0; attempt < 8; attempt++) {
      await _refreshFriendsFromDaemon();
      if (!_ownsGroupMutation(action)) return false;
      final live = _groups[conversationId];
      if (live != null && requested.every(live.memberIds.contains)) return true;
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!_ownsGroupMutation(action)) return false;
      }
    }
    return false;
  }

  Future<bool> removeGroupMember(
    String conversationId,
    String memberId, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!_ownsGroupMutation(action)) return false;
    final accepted = await jami.removeGroupMember(
      conversationId,
      memberId,
      expectedAccountId: accountId,
    );
    if (!accepted || !_ownsGroupMutation(action)) return false;
    await _refreshFriendsFromDaemon();
    return _ownsGroupMutation(action);
  }

  Future<bool> renameGroup(
    String conversationId,
    String title, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!_ownsGroupMutation(action)) return false;
    final accepted = await jami.renameGroup(
      conversationId,
      title,
      expectedAccountId: accountId,
    );
    if (!accepted || !_ownsGroupMutation(action)) return false;
    await _refreshFriendsFromDaemon();
    return _ownsGroupMutation(action);
  }

  Future<bool> updateGroupLayout(
    String conversationId,
    GroupLayout layout, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!_ownsGroupMutation(action)) return false;
    final description = GroupLayoutCodec.encode(layout);
    final accepted = await jami.updateGroupLayout(
      conversationId,
      description,
      expectedAccountId: accountId,
    );
    if (!accepted || !_ownsGroupMutation(action)) return false;
    await _refreshFriendsFromDaemon();
    return _ownsGroupMutation(action);
  }

  Future<bool> leaveGroup(
    String conversationId, {
    ConversationAction? action,
  }) async {
    action ??= captureConversationAction();
    if (!_ownsGroupMutation(action)) return false;
    final accepted = await jami.leaveGroup(
      conversationId,
      expectedAccountId: accountId,
    );
    if (!accepted || !_ownsGroupMutation(action)) return false;
    if (selectedGroupId == conversationId) {
      selectedGroupId = null;
      action._owner = conversationActionOwner;
      if (!await _persistConversationSelection(action._owner) ||
          !_ownsGroupMutation(action)) {
        return false;
      }
    }
    await _refreshFriendsFromDaemon();
    if (!_ownsGroupMutation(action)) return false;
    loadFolder();
    return true;
  }

  /// Accepts the first pending request. A direct requester becomes the selected
  /// friend when no friend is currently selected.
  Future<void> allowConnect() async {
    if (_handlingConnect || _pendingConnects.isEmpty) return;
    await allowConnectFrom(_pendingConnects.first.convId);
  }

  /// The pending 1:1 request this peer sent you, if any.
  ({String convId, String fromJamiId, bool isGroup})? incomingRequestFrom(
    String peerId,
  ) => _pendingConnects
      .where((request) => !request.isGroup && request.fromJamiId == peerId)
      .firstOrNull;

  /// Accept exactly one pending request; others stay queued in order.
  Future<void> allowConnectFrom(String convId) async {
    final index = _pendingConnects.indexWhere(
      (request) => request.convId == convId,
    );
    if (_handlingConnect || index < 0) return;
    final pc = _pendingConnects.removeAt(index);
    try {
      _handlingConnect =
          true; // inside try so the finally always resets it, even if notifyListeners throws
      _markConnectHandled(
        pc.convId,
      ); // a native replay of this convId must not re-surface it
      notifyListeners();
      try {
        await jami.acceptConnect(pc.convId);
      } catch (e) {
        _handledConnects.remove(pc.convId);
        _pendingConnects.insert(
          index.clamp(0, _pendingConnects.length).toInt(),
          pc,
        );
        dlog('acceptConnect(${pc.convId}) failed: $e');
        return;
      }
      await _refreshFriendsFromDaemon();
      if (!pc.isGroup &&
          (peerId == null || peerId!.isEmpty) &&
          pc.fromJamiId.isNotEmpty) {
        try {
          await selectFriend(pc.fromJamiId);
        } catch (e) {
          // The native request is already accepted. Do not resurrect an invalid card for a post-accept setup error.
          dlog(
            'setPeer(${pc.fromJamiId}) after acceptConnect(${pc.convId}) failed: $e',
          );
        }
      }
    } finally {
      _handlingConnect = false;
      notifyListeners();
    }
  }

  /// Declines the first pending request, restoring its queue position on failure.
  Future<void> ignoreConnect() async {
    if (_handlingConnect || _pendingConnects.isEmpty) return;
    final pc = _pendingConnects.removeAt(0);
    try {
      _handlingConnect =
          true; // inside try so the finally always resets it, even if notifyListeners throws
      _markConnectHandled(pc.convId);
      notifyListeners();
      await jami.declineConnect(pc.convId, pc.fromJamiId);
    } catch (e) {
      _handledConnects.remove(pc.convId);
      _pendingConnects.insert(0, pc);
      dlog('declineConnect(${pc.convId}) failed: $e');
    } finally {
      _handlingConnect = false;
      notifyListeners();
    }
  }

  static const _pendingRemovalsKey = 'doorlight.pendingFriendRemovals.v1';
  static const _maxPendingRemovals = 64;

  /// How long a removal waits for its "removed you" notice to be delivered.
  @visibleForTesting
  Duration friendRemovalNoticeWindow = const Duration(seconds: 30);
  final List<_PendingFriendRemoval> _removalMarkers = [];
  final Map<(String?, String), Future<FriendRemovalResult>> _removalRuns = {};

  _PendingFriendRemoval? _removalMarker(String peerId) {
    final account = accountId;
    if (account == null || account.isEmpty) return null;
    for (final marker in _removalMarkers) {
      if (marker.accountId == account && marker.peerId == peerId) {
        return marker;
      }
    }
    return null;
  }

  void _loadPendingRemovals() {
    final encoded = prefs.getString(_pendingRemovalsKey);
    if (encoded == null || encoded.length > 64 * 1024) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return;
      for (final value in decoded.take(_maxPendingRemovals)) {
        final marker = _PendingFriendRemoval.fromJson(value);
        if (marker != null &&
            !_removalMarkers.any(
              (other) =>
                  other.accountId == marker.accountId &&
                  other.peerId == marker.peerId,
            )) {
          _removalMarkers.add(marker);
        }
      }
    } catch (_) {
      // A corrupt marker list cannot name a friend to remove.
    }
  }

  Future<bool> _savePendingRemovals() async {
    while (_removalMarkers.length > _maxPendingRemovals) {
      _removalMarkers.removeAt(0);
    }
    try {
      return await prefs.setString(
        _pendingRemovalsKey,
        jsonEncode([for (final marker in _removalMarkers) marker.toJson()]),
      );
    } catch (error) {
      dlog('savePendingRemovals failed: $error');
      return false;
    }
  }

  /// Finish removals that a previous run promised but did not complete.
  void _resumePendingRemovals() {
    final account = accountId;
    var dropped = false;
    for (final marker in _removalMarkers.toList(growable: false)) {
      if (marker.accountId != account ||
          _removalRuns.containsKey((marker.accountId, marker.peerId))) {
        continue;
      }
      if (!_removalMatchesFriend(marker)) {
        // The friendship changed since the marker was written: not ours.
        _removalMarkers.remove(marker);
        dropped = true;
        continue;
      }
      _runInBackground(
        _runPendingRemoval(marker, sendNotice: false),
        'resumeFriendRemoval',
      );
    }
    if (dropped) _runInBackground(_savePendingRemovals(), 'dropFriendRemoval');
  }

  /// The marker still describes this account's current friendship. A friend
  /// already gone from daemon truth matches: the removal is simply done.
  bool _removalMatchesFriend(_PendingFriendRemoval marker) {
    final friend = _friends[marker.peerId];
    return marker.accountId == accountId &&
        (friend == null || friend.conversationId == marker.conversationId);
  }

  void _noteRemovalNoticeStatus(
    String account,
    String conversation,
    String messageId,
    String peer,
    int wireState,
  ) {
    // SENT (2) or DISPLAYED (3) from that peer. SENDING (1) is local only.
    if (wireState < 2 || wireState > 3 || messageId.isEmpty) return;
    for (final marker in _removalMarkers) {
      final delivered = marker.delivered;
      if (delivered == null ||
          delivered.isCompleted ||
          marker.accountId != account ||
          marker.conversationId != conversation ||
          marker.peerId != peer) {
        continue;
      }
      if (marker.noticeCommitId == messageId) {
        delivered.complete();
      } else if (marker.noticeCommitId == null &&
          marker.earlyDelivered.length < 32) {
        marker.earlyDelivered.add(messageId);
      }
    }
  }

  /// Remove one friend. A plain removal first tells them in your 1:1
  /// conversation, then removes once that notice is delivered or after
  /// [friendRemovalNoticeWindow]. Blocking sends nothing.
  Future<FriendRemovalResult> removeFriend(String p, {bool block = false}) {
    if (block) return _confirmRemoval(p, block: true);
    final running = _removalRuns[(accountId, p)];
    if (running != null) {
      final marker = _removalMarker(p);
      // Past its notice window a repeat is a fresh daemon attempt, which
      // retires the older one as stale, as before notices existed.
      return marker != null && marker.confirming
          ? _finishRemoval(marker)
          : running;
    }
    final account = accountId;
    final friend = _friends[p];
    if (p.isEmpty || friend == null || account == null || account.isEmpty) {
      return _confirmRemoval(p);
    }
    return _runPendingRemoval(
      _PendingFriendRemoval(
        accountId: account,
        peerId: p,
        conversationId: friend.conversationId,
        deadlineMs: DateTime.now()
            .add(friendRemovalNoticeWindow)
            .millisecondsSinceEpoch,
      ),
      sendNotice: true,
    );
  }

  Future<FriendRemovalResult> _runPendingRemoval(
    _PendingFriendRemoval marker, {
    required bool sendNotice,
  }) {
    final key = (marker.accountId, marker.peerId);
    final run = _removeAfterNotice(marker, sendNotice: sendNotice);
    _removalRuns[key] = run;
    run.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(
      () {
        if (!identical(_removalRuns[key], run)) return;
        _removalRuns.remove(key);
        // Reopen what the running removal closed when it did not remove.
        if (_disposed) return;
        _syncDirectPeerGates();
        notifyListeners();
      },
    );
    return run;
  }

  Future<FriendRemovalResult> _removeAfterNotice(
    _PendingFriendRemoval marker, {
    required bool sendNotice,
  }) async {
    final p = marker.peerId;
    final owner = (accountId, _accountRevision);
    _removalMarkers.removeWhere(
      (other) =>
          !identical(other, marker) &&
          other.accountId == marker.accountId &&
          other.peerId == p,
    );
    if (!_removalMarkers.contains(marker)) _removalMarkers.add(marker);
    final delivered = Completer<void>();
    marker.delivered = delivered;
    // The window runs from the click: the native send may itself block. A
    // persisted deadline never extends it (the clock may have moved back).
    final remaining = min(
      marker.deadlineMs - DateTime.now().millisecondsSinceEpoch,
      friendRemovalNoticeWindow.inMilliseconds,
    );
    final deadline = Timer(
      Duration(milliseconds: remaining < 0 ? 0 : remaining),
      () {
        if (!delivered.isCompleted) delivered.complete();
      },
    );
    bool ownsRun() =>
        !_disposed &&
        owner == (accountId, _accountRevision) &&
        _removalMarkers.contains(marker) &&
        identical(marker.delivered, delivered) &&
        _removalMatchesFriend(marker);
    try {
      await _savePendingRemovals();
      if (!ownsRun()) {
        return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
      }
      _syncDirectPeerGates();
      final ringing = call;
      if (ringing != null &&
          ringing.peerId == p &&
          ringing.dir == CallDir.incoming &&
          !ringing.connected) {
        _runInBackground(decline(ringing), 'declineRemovedRing');
      }
      // A ring from them queued behind another call must not surface later.
      final queued = [
        for (final entry in _pendingIncomingCalls.entries)
          if (entry.value.peerId == p) entry.key,
      ];
      for (final callId in queued) {
        _pendingIncomingCalls.remove(callId);
        _runInBackground(jami.refuse(callId), 'refuseQueuedRemovedRing');
      }
      notifyListeners();
      final scope = _scopeForPeer(p);
      if (!sendNotice) {
        // A resumed removal never re-sends; it waits out the original window.
      } else if (appearOffline ||
          scope == null ||
          scope.accountId != marker.accountId ||
          scope.conversationId != marker.conversationId) {
        if (!delivered.isCompleted) delivered.complete();
      } else {
        _runInBackground(
          _sendRemovalNotice(scope, marker, delivered),
          'sendRemovalNotice',
        );
      }
      await delivered.future;
      if (!ownsRun()) {
        return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
      }
      marker.confirming = true;
      return _finishRemoval(marker);
    } finally {
      deadline.cancel();
      if (!delivered.isCompleted) delivered.complete();
      if (identical(marker.delivered, delivered)) marker.delivered = null;
    }
  }

  Future<FriendRemovalResult> _finishRemoval(
    _PendingFriendRemoval marker,
  ) async {
    final p = marker.peerId;
    if (_disposed || accountId != marker.accountId) {
      return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
    }
    if (!_removalMatchesFriend(marker)) {
      // Re-added under another conversation: this marker removes nothing.
      await _clearRemovalMarker(marker);
      _syncDirectPeerGates();
      notifyListeners();
      return (
        peerId: p,
        status: FriendRemovalStatus.notRemoved,
        warning: 'The friend was not removed. Please try again.',
      );
    }
    if (!_friends.containsKey(p)) {
      // Daemon truth already lost the friend (for example a linked device).
      await _clearRemovalMarker(marker);
      return (peerId: p, status: FriendRemovalStatus.removed, warning: null);
    }
    final result = await _confirmRemoval(p);
    // The marker only finishes an interrupted removal; a refused one is
    // shown as refused and never retried silently on the next start.
    if (result.status == FriendRemovalStatus.removed ||
        result.status == FriendRemovalStatus.notRemoved) {
      await _clearRemovalMarker(marker);
    }
    _syncDirectPeerGates();
    notifyListeners();
    return result;
  }

  Future<void> _sendRemovalNotice(
    ConversationScope scope,
    _PendingFriendRemoval marker,
    Completer<void> delivered,
  ) async {
    // Another topic change in this conversation is not a refusal: wait for
    // it (still bounded by the removal window), then send.
    for (
      var busy = _dmTopicMutations[scope];
      busy != null && !delivered.isCompleted;
      busy = _dmTopicMutations[scope]
    ) {
      await Future.any([busy.future, delivered.future]);
    }
    if (delivered.isCompleted) return;
    final commitId = await _commitDmTopicEventId(
      scope,
      const DmTopicEvent.left(),
    );
    if (delivered.isCompleted) return;
    if (commitId == null) {
      // Refused or failed (for example an older daemon): remove now.
      delivered.complete();
      return;
    }
    marker.noticeCommitId = commitId;
    if (marker.earlyDelivered.contains(commitId)) delivered.complete();
    await _savePendingRemovals();
  }

  Future<void> _clearRemovalMarker(_PendingFriendRemoval marker) async {
    _removalMarkers.remove(marker);
    await _savePendingRemovals();
  }

  /// Remove (or block) one exact friend. Daemon confirmation is authoritative; only then are that owner's local
  /// presence, file, folder, and selection state retired. Other friends remain untouched.
  Future<FriendRemovalResult> _confirmRemoval(
    String p, {
    bool block = false,
  }) async {
    if (p.isEmpty || !_friends.containsKey(p)) {
      return (
        peerId: p,
        status: FriendRemovalStatus.notRemoved,
        warning: 'The friend is no longer available.',
      );
    }
    final owner = (accountId, _accountRevision);
    ++_peerGeneration;
    final operation = Object();
    _friendRemovalOperations[p] = operation;
    try {
      var completed = false;
      try {
        await jami.removeContact(p, block: block);
        completed = true;
      } catch (e) {
        dlog('removePeer(block=$block) failed: $e');
      }
      bool ownsRemoval() =>
          !_disposed &&
          owner == (accountId, _accountRevision) &&
          identical(_friendRemovalOperations[p], operation);
      if (!ownsRemoval()) {
        return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
      }
      try {
        // Native can remove the friend before grant cleanup reports failure.
        // A failed overall request is not evidence that the friend still exists.
        await _refreshFriendsFromDaemon();
      } catch (error) {
        if (ownsRemoval()) {
          _uncertainControlPeers.add(p);
          _syncRemoteControl();
          if (call?.peerId == p) {
            _controlTrustWarning = (
              account: owner,
              peerId: p,
              message:
                  'Friend removal and remote-control cleanup could not be confirmed.',
            );
          }
          notifyListeners();
        }
        dlog('removeFriend reconciliation failed: $error');
        return (
          peerId: p,
          status: ownsRemoval()
              ? FriendRemovalStatus.incomplete
              : FriendRemovalStatus.stale,
          warning: ownsRemoval()
              ? 'Friend removal and remote-control cleanup could not be confirmed.'
              : null,
        );
      }
      if (!ownsRemoval()) {
        return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
      }
      if (_friends.containsKey(p)) {
        dlog('removePeer(block=$block) was not confirmed by daemon truth');
        notifyListeners();
        return (
          peerId: p,
          status: FriendRemovalStatus.notRemoved,
          warning: 'The friend was not removed. Please try again.',
        );
      }
      final selected = selectedFriend;
      peerPresence = selected?.presence ?? PeerPresence.unknown;
      _presence.forget(p);
      _syncPresenceRuntime();
      _fileTransfers.retirePeer(p);
      _friendActivity.remove(p);
      _seenConversationActivity.removeWhere((entry) => entry.$1.peerId == p);
      if (_visibleConversationPeerId == p) {
        _visibleConversationPeerId = null;
        _visibleGroupTopicId = null;
        _visibleDmTopicId = null;
      }
      if (peerId != null) loadFolder();
      dlog('→ removePeer(block=$block)');
      final warning = completed
          ? null
          : 'Friend removed. Remote-control cleanup could not be confirmed.';
      if (warning != null && call?.peerId == p) {
        _controlTrustWarning = (account: owner, peerId: p, message: warning);
      }
      notifyListeners();
      return (
        peerId: p,
        status: completed
            ? FriendRemovalStatus.removed
            : FriendRemovalStatus.incomplete,
        warning: warning,
      );
    } finally {
      if (identical(_friendRemovalOperations[p], operation)) {
        _friendRemovalOperations.remove(p);
      }
    }
  }

  Future<void> startCall({bool withVideo = false}) =>
      startCallTo(peerId, withVideo: withVideo);

  Object? _groupJoinOperation;

  Future<void> joinGroupVoice(GroupState group, GroupRoom room) async {
    if (room.kind != GroupRoomKind.voice ||
        call != null ||
        placing ||
        _groupJoinOperation != null ||
        !registered ||
        appearOffline ||
        _restoringIdentity ||
        _disposed ||
        _groups[group.conversationId]?.layout.room(room.id)?.kind !=
            GroupRoomKind.voice) {
      return;
    }
    final operation = Object();
    final account = _microphoneAccountOwner;
    _groupJoinOperation = operation;
    bool current() =>
        !_disposed &&
        !_restoringIdentity &&
        !appearOffline &&
        _microphoneAccountOwner == account &&
        identical(_groupJoinOperation, operation) &&
        call == null &&
        !placing &&
        _groups[group.conversationId]?.layout.room(room.id)?.kind ==
            GroupRoomKind.voice;
    GroupCallSession? session;
    try {
      if (groupCall case final previous?) {
        if (previous.conversationId == group.conversationId &&
            previous.roomId == room.id &&
            previous.phase != GroupCallPhase.failed) {
          return;
        }
        await leaveGroupVoice();
        if (!current() || groupCall != null) return;
      }
      final initialAddress = GroupConferenceAddress.create(roomId: room.id);
      final microphoneMode = microphoneModeForGroup(group.conversationId).mode;
      final reserved = GroupCallSession(
        conversationId: group.conversationId,
        roomId: room.id,
        conferenceId: initialAddress.conferenceId,
        sessionId: initialAddress.conferenceId.split('-').last.padLeft(8, '0'),
        micMuted:
            _microphonePolicyUnavailable ||
            microphoneMode != MicrophoneMode.open,
        micMode: microphoneMode,
      );
      reserved.reservationId = initialAddress.conferenceId;
      session = reserved;
      groupCall = reserved;
      callEndedNote = null;
      notifyListeners();
      final admitted = await jami.reserveGroupCall(
        account.$1 ?? '',
        group.conversationId,
        reserved.reservationId,
      );
      if (!current() ||
          !identical(groupCall, reserved) ||
          reserved.phase != GroupCallPhase.joining ||
          !admitted) {
        await _cancelGroupPreflight(reserved);
        if (!admitted) callEndedNote = 'The media slot could not be reserved';
        return;
      }
      final active = await jami.listGroupCalls(group.conversationId);
      if (!current() ||
          !identical(groupCall, reserved) ||
          reserved.phase != GroupCallPhase.joining) {
        await _cancelGroupPreflight(reserved);
        return;
      }
      final target = GroupConferenceAddress.chooseCanonical(
        active,
        roomId: room.id,
      );
      final address = target == null
          ? initialAddress
          : GroupConferenceAddress.tryParse(target.conferenceId)!;
      reserved.conferenceId = address.conferenceId;
      reserved.nativePlacementIssued = true;
      final placement = await jami.joinGroupCall(
        conversationId: group.conversationId,
        conferenceId: address.conferenceId,
        reservationId: reserved.reservationId,
        hostUri: target?.hostUri ?? '',
        hostDevice: target?.hostDevice ?? '',
        initialAudioMuted: reserved.micMuted,
      );
      if (!current() ||
          !identical(groupCall, reserved) ||
          reserved.phase == GroupCallPhase.leaving) {
        if (placement.succeeded) {
          await jami.leaveGroupCall(
            placement.conferenceId,
            reservationId: reserved.reservationId,
          );
        }
        return;
      }
      if (!placement.succeeded) {
        _scheduleGroupCallRecovery();
        return;
      }
      if (placement.conferenceId != reserved.conferenceId ||
          (reserved.callId.isNotEmpty && reserved.callId != placement.callId)) {
        reserved.error = 'Voice connection ownership could not be confirmed';
        await leaveGroupVoice();
        return;
      }
      reserved.callId = placement.callId;
      reserved.hosting = placement.hosting;
      // Placement is admission only. CURRENT or the exact local conference
      // creation establishes the connection, including callbacks before reply.
      if (reserved.connected) await _completeGroupConnection(reserved);
      notifyListeners();
    } catch (_) {
      if (session != null && identical(groupCall, session)) {
        if (!session.nativePlacementIssued) {
          await _cancelGroupPreflight(session);
        } else {
          session.error = 'Voice connection could not be established';
          _scheduleGroupCallRecovery();
        }
      }
    } finally {
      if (identical(_groupJoinOperation, operation)) _groupJoinOperation = null;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _cancelGroupPreflight(GroupCallSession session) async {
    if (session.nativePlacementIssued) return;
    final reservation = session.reservationId;
    var detached = false;
    try {
      detached = await jami.leaveGroupCall(
        reservation,
        reservationId: reservation,
      );
    } catch (_) {}
    if (!identical(groupCall, session) ||
        session.reservationId != reservation) {
      return;
    }
    if (detached) {
      groupCall = null;
    } else {
      session.phase = GroupCallPhase.leaving;
      session.error = 'Disconnect could not be confirmed. Retry Leave.';
    }
  }

  Future<void> _completeGroupConnection(GroupCallSession session) async {
    if (!identical(groupCall, session) ||
        !session.connected ||
        session.connectionAnnounced) {
      return;
    }
    final account = _microphoneAccountOwner;
    final reservation = session.reservationId;
    bool owns() =>
        !_disposed &&
        _microphoneAccountOwner == account &&
        identical(groupCall, session) &&
        session.reservationId == reservation &&
        session.connected;
    session.connectionAnnounced = true;
    session.recoveryAttempts = 0;
    session.error = null;
    await _projectGroupMicrophone(session);
    if (!owns()) return;
    await _projectGroupDeafened(session);
    if (!owns()) return;
    final group = _groups[session.conversationId];
    if (group != null) _wakePeers(group.activeMemberIds);
    _startGroupCallPresence();
    await _publishGroupCallPresence();
    if (!owns()) return;
    if (session.mediaRestorePending) await _restoreGroupVideoSource(session);
    if (!owns()) return;
    _playSound(SyblSoundEvent.callConnected);
    notifyListeners();
  }

  Future<void> retryGroupVoice() async {
    final current = groupCall;
    if (current == null || current.phase != GroupCallPhase.failed) return;
    final group = _groups[current.conversationId];
    final room = group?.layout.room(current.roomId);
    await leaveGroupVoice();
    if (groupCall == null && group != null && room != null) {
      await joinGroupVoice(group, room);
    }
  }

  Future<void> leaveGroupVoice() async {
    final current = groupCall;
    if (current == null) return;
    final reservation = current.reservationId;
    final conference = current.conferenceId;
    final account = _microphoneAccountOwner;
    current.phase = GroupCallPhase.leaving;
    current.pushToTalkPressed = false;
    _groupCallPresenceTimer?.cancel();
    _groupCallPresenceTimer = null;
    _groupCallRecoveryTimer?.cancel();
    _groupCallRecoveryTimer = null;
    notifyListeners();
    try {
      await _publishGroupCallPresence(joined: false);
    } catch (_) {}
    var detached = false;
    try {
      detached = await jami.leaveGroupCall(
        conference,
        reservationId: reservation,
      );
    } catch (_) {}
    if (identical(groupCall, current) &&
        current.reservationId == reservation &&
        _microphoneAccountOwner == account) {
      if (detached) {
        groupCall = null;
        _playSound(SyblSoundEvent.callEnded);
      } else {
        current.error = 'Disconnect could not be confirmed. Retry Leave.';
      }
    }
    notifyListeners();
  }

  MicrophoneDecision _evaluateGroupMicrophone(GroupCallSession session) =>
      MicrophonePolicy(
        effectiveMode: EffectiveMicrophoneMode(
          mode: session.micMode,
          source: microphoneModeForGroup(session.conversationId).source,
        ),
        sessionActive: session.connected,
        privacySuspended: _microphonePolicyUnavailable || session.deafened,
        manuallyMuted: session.manuallyMuted,
        pushToTalkPressed: session.pushToTalkPressed,
      ).evaluate();

  bool _ownsGroupMicrophone(
    GroupCallSession session,
    String conference,
    (String?, int) account,
  ) =>
      !_disposed &&
      _microphoneAccountOwner == account &&
      identical(groupCall, session) &&
      session.conferenceId == conference &&
      session.connected;

  Future<void> _endUnsafeGroupMicrophone(
    GroupCallSession session,
    String conference,
    (String?, int) account,
  ) async {
    if (!_ownsGroupMicrophone(session, conference, account)) return;
    session.phase = GroupCallPhase.leaving;
    session.pushToTalkPressed = false;
    session.error =
        'Could not mute the microphone. Ending the voice connection.';
    _groupCallPresenceTimer?.cancel();
    _groupCallRecoveryTimer?.cancel();
    notifyListeners();
    var ended = false;
    try {
      ended = await jami.leaveGroupCall(
        conference,
        reservationId: session.reservationId,
      );
    } catch (error) {
      dlog('leaveGroupCall(microphone failure): $error');
    }
    if (_disposed ||
        _microphoneAccountOwner != account ||
        !identical(groupCall, session) ||
        session.conferenceId != conference) {
      return;
    }
    if (ended) {
      groupCall = null;
    } else {
      // Keep the media slot and unknown state until teardown is confirmed.
      session.error =
          'Microphone state is unknown. The voice connection could not be ended.';
    }
    notifyListeners();
  }

  Future<void> _projectGroupMicrophone(GroupCallSession session) {
    final conference = session.conferenceId;
    final account = _microphoneAccountOwner;
    return _enqueueMicrophoneCommand(() async {
      if (!_ownsGroupMicrophone(session, conference, account)) return;
      final muted = _evaluateGroupMicrophone(session).mustMute;
      if (session.acknowledgedMicrophoneMuted == muted) return;
      var accepted = false;
      try {
        accepted = await jami.setGroupMicMuted(conference, muted);
      } catch (error) {
        dlog('setGroupMicMuted($muted): $error');
      }
      if (!_ownsGroupMicrophone(session, conference, account)) return;
      session.acknowledgedMicrophoneMuted = accepted ? muted : null;
      if (!accepted) {
        // A failed unmute is also unknown. Close it before reporting a safe state.
        if (!muted) {
          try {
            accepted = await jami.setGroupMicMuted(conference, true);
          } catch (error) {
            dlog('protect group microphone: $error');
          }
          if (!_ownsGroupMicrophone(session, conference, account)) return;
          session.acknowledgedMicrophoneMuted = accepted ? true : null;
        }
        if (!accepted) {
          await _endUnsafeGroupMicrophone(session, conference, account);
          return;
        }
        session.error =
            'Could not apply the microphone policy. The microphone stayed muted.';
      } else {
        session.error = null;
      }
      session.micMuted = session.acknowledgedMicrophoneMuted == true;
      notifyListeners();
      await _publishGroupCallPresence();
    });
  }

  Future<void> setGroupMicMuted(bool muted) async {
    final session = groupCall;
    if (session == null || !session.connected) return;
    final conference = session.conferenceId;
    final account = _microphoneAccountOwner;
    final previous = session.micMuted;
    session.manualMuteRevision++;
    session.manuallyMuted = muted;
    notifyListeners();
    await _projectGroupMicrophone(session);
    if (_ownsGroupMicrophone(session, conference, account) &&
        session.manuallyMuted == muted &&
        session.micMuted != previous) {
      _playSound(
        session.micMuted ? SyblSoundEvent.micMute : SyblSoundEvent.micUnmute,
      );
    }
  }

  Future<void> groupPushToTalk(bool down) async {
    if (down && (!_microphoneControlsFocused || _protectedSurfaceLocked)) {
      return;
    }
    final current = groupCall;
    if (current == null ||
        !current.connected ||
        current.micMode != MicrophoneMode.pushToTalk ||
        current.pushToTalkPressed == down) {
      return;
    }
    current.pushToTalkPressed = down;
    notifyListeners();
    await _projectGroupMicrophone(current);
  }

  Future<void> setGroupDeafened(bool deafened) async {
    final current = groupCall;
    if (current == null ||
        !current.connected ||
        (current.deafened == deafened &&
            current.acknowledgedDeafened == deafened)) {
      return;
    }
    final conference = current.conferenceId;
    final account = _microphoneAccountOwner;
    current.deafened = deafened;
    current.pushToTalkPressed = false;
    notifyListeners();
    await _projectGroupMicrophone(current);
    if (!_ownsGroupMicrophone(current, conference, account)) return;
    await _projectGroupDeafened(current, playSound: true);
    if (_ownsGroupMicrophone(current, conference, account)) {
      await _projectGroupMicrophone(current);
      await _publishGroupCallPresence();
    }
  }

  Future<void> _projectGroupDeafened(
    GroupCallSession session, {
    bool playSound = false,
  }) {
    final conference = session.conferenceId;
    final account = _microphoneAccountOwner;
    return _enqueueMicrophoneCommand(() async {
      if (!_ownsGroupMicrophone(session, conference, account)) return;
      final requested = session.deafened;
      if (session.acknowledgedDeafened == requested) return;
      var applied = false;
      try {
        applied = await jami.setGroupDeafened(conference, requested);
      } catch (error) {
        dlog('setGroupDeafened: $error');
      }
      if (!_ownsGroupMicrophone(session, conference, account)) return;
      session.acknowledgedDeafened = applied ? requested : null;
      if (!applied) {
        session.error = 'Could not change voice playback.';
      } else if (session.deafened == requested) {
        session.error = null;
        if (playSound) {
          _playSound(
            requested ? SyblSoundEvent.deafen : SyblSoundEvent.undeafen,
          );
        }
      }
      notifyListeners();
    });
  }

  Future<void> toggleGroupSpeaker() async {
    final current = groupCall;
    if (current == null || !current.connected || !speakerControlAvailable) {
      return;
    }
    final previous = current.speakerOn;
    current.speakerOn = !previous;
    notifyListeners();
    try {
      await jami.setSpeaker(current.speakerOn);
    } catch (error) {
      if (identical(groupCall, current)) {
        current.speakerOn = previous;
        notifyListeners();
      }
      dlog('setGroupSpeaker failed: $error');
    }
  }

  Future<void> toggleGroupCamera() async {
    final current = groupCall;
    if (current == null || !current.connected || current.sourceChanging) return;
    await _setGroupVideoSource(
      current.video ? OutgoingVideoKind.off : OutgoingVideoKind.camera,
    );
  }

  Future<void> toggleGroupScreenShare({String? sourceId}) async {
    final current = groupCall;
    if (current == null || !current.connected || current.sourceChanging) return;
    await _setGroupVideoSource(
      current.screenShare ? OutgoingVideoKind.off : OutgoingVideoKind.screen,
      sourceId: sourceId,
    );
  }

  Future<List<ScreenSource>> listGroupScreenSources() async {
    final current = groupCall;
    if (current == null || !current.connected) return const [];
    final result = await jami.listScreenSources(current.conferenceId);
    return identical(groupCall, current) && current.connected
        ? result
        : const [];
  }

  Future<void> switchGroupCamera() async {
    final current = groupCall;
    if (current == null ||
        !current.connected ||
        !current.video ||
        current.sourceChanging) {
      return;
    }
    await jami.switchCamera(current.conferenceId);
  }

  Future<void> setGroupFocus(GroupConferenceStream? stream) async {
    final current = groupCall;
    if (current == null || !current.connected) return;
    if (stream == null) {
      if (await jami.setGroupConferenceLayout(current.conferenceId, 0) &&
          identical(groupCall, current)) {
        current.focusedStreamKey = null;
        notifyListeners();
      }
      return;
    }
    if (!current.conference.streams.any((item) => item.key == stream.key)) {
      return;
    }
    final active = await jami.setGroupActiveStream(
      current.conferenceId,
      stream,
      true,
    );
    if (!active || !identical(groupCall, current)) return;
    if (await jami.setGroupConferenceLayout(current.conferenceId, 1) &&
        identical(groupCall, current)) {
      current.focusedStreamKey = stream.key;
      notifyListeners();
    }
  }

  Future<void> muteGroupParticipant(
    GroupConferenceStream stream,
    bool muted,
  ) async {
    final current = groupCall;
    final group = current == null ? null : _groups[current.conversationId];
    if (current == null ||
        !current.connected ||
        (group?.canManageMembers ?? current.hosting) != true ||
        stream.accountId == jamiId ||
        !current.conference.streams.any((item) => item.key == stream.key)) {
      return;
    }
    await jami.muteGroupParticipant(current.conferenceId, stream, muted);
  }

  Future<void> disconnectGroupParticipant(GroupConferenceStream stream) async {
    final current = groupCall;
    final group = current == null ? null : _groups[current.conversationId];
    if (current == null ||
        !current.connected ||
        (group?.canManageMembers ?? current.hosting) != true ||
        stream.accountId == jamiId ||
        !current.conference.streams.any((item) => item.key == stream.key)) {
      return;
    }
    await jami.disconnectGroupParticipant(current.conferenceId, stream);
  }

  Future<void> _setGroupVideoSource(
    OutgoingVideoKind kind, {
    String? sourceId,
  }) async {
    final current = groupCall;
    if (current == null || !current.connected || current.sourceChanging) return;
    final before = current.video
        ? OutgoingVideoKind.camera
        : current.screenShare
        ? OutgoingVideoKind.screen
        : OutgoingVideoKind.off;
    current.sourceChangeKind = kind == OutgoingVideoKind.off ? before : kind;
    current.sourceChanging = true;
    notifyListeners();
    try {
      final accepted = switch (kind) {
        OutgoingVideoKind.camera => await jami.startVideo(current.conferenceId),
        OutgoingVideoKind.screen => await jami.setOutgoingVideoSource(
          current.conferenceId,
          kind,
          sourceId: sourceId,
        ),
        OutgoingVideoKind.off => await jami.stopVideo(current.conferenceId),
      };
      if (!identical(groupCall, current) || !accepted) return;
      current.video = kind == OutgoingVideoKind.camera;
      current.screenShare = kind == OutgoingVideoKind.screen;
      current.screenSourceId = kind == OutgoingVideoKind.screen
          ? sourceId
          : null;
      _playVideoSourceSound(before, kind);
      await _publishGroupCallPresence();
    } catch (error) {
      dlog('setGroupVideoSource($kind) failed: $error');
    } finally {
      if (identical(groupCall, current)) {
        current.sourceChanging = false;
        current.sourceChangeKind = null;
        notifyListeners();
      }
    }
  }

  Future<void> _restoreGroupVideoSource(GroupCallSession current) async {
    if (!identical(groupCall, current) ||
        !current.mediaRestorePending ||
        current.mediaRestoreInFlight) {
      return;
    }
    final conferenceId = current.conferenceId;
    final restoreCamera = current.video;
    final restoreScreen = current.screenShare;
    if (!restoreCamera && !restoreScreen) {
      current.mediaRestorePending = false;
      return;
    }
    current.mediaRestoreInFlight = true;
    current.sourceChangeKind = restoreCamera
        ? OutgoingVideoKind.camera
        : OutgoingVideoKind.screen;
    current.sourceChanging = true;
    notifyListeners();
    var accepted = false;
    try {
      accepted = restoreCamera
          ? await jami.startVideo(conferenceId)
          : await jami.setOutgoingVideoSource(
              conferenceId,
              OutgoingVideoKind.screen,
              sourceId: current.screenSourceId,
            );
    } catch (error) {
      dlog('restoreGroupVideoSource failed: $error');
    } finally {
      if (identical(groupCall, current)) {
        current.mediaRestoreInFlight = false;
        current.sourceChanging = false;
        current.sourceChangeKind = null;
        if (current.conferenceId == conferenceId) {
          current.mediaRestorePending = false;
          if (!accepted) {
            current.video = false;
            current.screenShare = false;
            current.screenSourceId = null;
          }
          await _publishGroupCallPresence();
        }
        notifyListeners();
      }
    }
  }

  void _ensureGroupVideoTexture(GroupCallSession current) {
    if (current.videoTextureId != null || _groupVideoTextureFuture != null) {
      return;
    }
    final pending = jami.createVideoTexture('remote');
    _groupVideoTextureFuture = pending;
    _runInBackground(() async {
      try {
        final textureId = await pending;
        if (identical(groupCall, current) && textureId >= 0) {
          current.videoTextureId = textureId;
          notifyListeners();
        }
      } finally {
        if (identical(_groupVideoTextureFuture, pending)) {
          _groupVideoTextureFuture = null;
        }
      }
    }(), 'createGroupVideoTexture');
  }

  void _startGroupCallPresence() {
    _groupCallPresenceTimer?.cancel();
    _groupCallPresenceTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _runInBackground(_publishGroupCallPresence(), 'publishGroupCallPresence');
      notifyListeners();
    });
  }

  Future<void> _publishGroupCallPresence({bool joined = true}) async {
    final current = groupCall;
    if (current == null || jamiId.isEmpty) return;
    final value = GroupCallPresence(
      conversationId: current.conversationId,
      roomId: current.roomId,
      conferenceId: current.conferenceId,
      accountId: jamiId,
      sessionId: current.sessionId,
      sequence: _groupCallPresenceSequence++ & 0x7fffffff,
      joined: joined,
      muted: current.micMuted,
      deafened: current.deafened,
      video: current.video,
      screenShare: current.screenShare,
      speaking: current.speaking,
    );
    await jami.publishGroupCallPresence(current.conversationId, value.encode());
  }

  void _scheduleGroupCallRecovery() {
    final current = groupCall;
    if (current == null || current.phase == GroupCallPhase.leaving) return;
    current.pushToTalkPressed = false;
    current.failedConferenceIds.add(current.conferenceId);
    if (current.recoveryAttempts >= GroupCallRecovery.maxAttempts) {
      current.phase = GroupCallPhase.failed;
      current.error = 'Voice connection ended';
      notifyListeners();
      return;
    }
    current.phase = GroupCallPhase.recovering;
    final delay = GroupCallRecovery.delayMs(jamiId, current.recoveryAttempts);
    current.retryAtMs = _groupCallClock.elapsedMilliseconds + delay;
    _groupCallRecoveryTimer?.cancel();
    _groupCallRecoveryTimer = Timer(Duration(milliseconds: delay), () {
      _runInBackground(_recoverGroupVoice(current), 'recoverGroupVoice');
    });
    notifyListeners();
  }

  Future<bool> _detachGroupForReplacement(GroupCallSession current) async {
    if (!identical(groupCall, current) ||
        current.phase == GroupCallPhase.leaving) {
      return false;
    }
    final account = _microphoneAccountOwner;
    final reservation = current.reservationId;
    final conference = current.conferenceId;
    current.phase = GroupCallPhase.recovering;
    current.pushToTalkPressed = false;
    current.connectionAnnounced = false;
    _groupCallPresenceTimer?.cancel();
    try {
      await _publishGroupCallPresence(joined: false);
    } catch (_) {}
    var detached = false;
    try {
      detached = await jami.leaveGroupCall(
        conference,
        reservationId: reservation,
      );
    } catch (_) {}
    if (!identical(groupCall, current) ||
        _microphoneAccountOwner != account ||
        current.reservationId != reservation ||
        current.phase == GroupCallPhase.leaving) {
      return false;
    }
    if (!detached) {
      current.phase = GroupCallPhase.leaving;
      current.error = 'Disconnect could not be confirmed. Retry Leave.';
      notifyListeners();
      return false;
    }
    current.callId = '';
    return true;
  }

  Future<bool> _reserveGroupReplacement(GroupCallSession current) async {
    if (!identical(groupCall, current) ||
        current.phase != GroupCallPhase.recovering) {
      return false;
    }
    _groupCallRecoveryTimer?.cancel();
    _groupCallRecoveryTimer = null;
    final account = _microphoneAccountOwner;
    current.reservationId = GroupConferenceAddress.create(
      roomId: current.roomId,
    ).conferenceId;
    current.conferenceId = current.reservationId;
    current.nativePlacementIssued = false;
    final admitted = await jami.reserveGroupCall(
      account.$1 ?? '',
      current.conversationId,
      current.reservationId,
    );
    if (!identical(groupCall, current) ||
        _microphoneAccountOwner != account ||
        current.phase != GroupCallPhase.recovering ||
        !admitted) {
      await _cancelGroupPreflight(current);
      return false;
    }
    return true;
  }

  Future<void> _recoverGroupVoice(GroupCallSession current) async {
    if (current.replacementInProgress) return;
    current.replacementInProgress = true;
    try {
      final account = _microphoneAccountOwner;
      if (!await _detachGroupForReplacement(current)) return;
      if (!await _reserveGroupReplacement(current)) return;
      try {
        final active = await jami.listGroupCalls(current.conversationId);
        if (!identical(groupCall, current) ||
            _microphoneAccountOwner != account ||
            current.phase != GroupCallPhase.recovering ||
            appearOffline ||
            _restoringIdentity ||
            !_groups.containsKey(current.conversationId)) {
          await _cancelGroupPreflight(current);
          return;
        }
        final target = GroupConferenceAddress.chooseCanonical(
          active,
          roomId: current.roomId,
          excludedConferenceIds: current.failedConferenceIds,
        );
        await _placeGroupReplacement(current, target);
      } catch (_) {
        if (identical(groupCall, current)) {
          current.error = 'Voice recovery could not be completed';
          current.phase = GroupCallPhase.failed;
          notifyListeners();
        }
      }
    } finally {
      current.replacementInProgress = false;
    }
  }

  Future<void> _placeGroupReplacement(
    GroupCallSession current,
    GroupActiveCall? target,
  ) async {
    final account = _microphoneAccountOwner;
    final reservation = current.reservationId;
    if (!identical(groupCall, current) ||
        current.phase != GroupCallPhase.recovering) {
      return;
    }
    final address = target == null
        ? GroupConferenceAddress.create(roomId: current.roomId)
        : GroupConferenceAddress.tryParse(target.conferenceId)!;
    current.recoveryAttempts += 1;
    current.conferenceId = address.conferenceId;
    current.callId = '';
    current.connectionAnnounced = false;
    current.micMuted =
        _microphonePolicyUnavailable ||
        current.manuallyMuted ||
        current.deafened ||
        current.micMode != MicrophoneMode.open;
    current.acknowledgedMicrophoneMuted = null;
    current.acknowledgedDeafened = false;
    current.mediaRestorePending = current.video || current.screenShare;
    current.nativePlacementIssued = true;
    final placement = await jami.joinGroupCall(
      conversationId: current.conversationId,
      conferenceId: address.conferenceId,
      reservationId: reservation,
      hostUri: target?.hostUri ?? '',
      hostDevice: target?.hostDevice ?? '',
      initialAudioMuted: current.micMuted,
    );
    if (!identical(groupCall, current) ||
        _microphoneAccountOwner != account ||
        current.reservationId != reservation ||
        current.phase == GroupCallPhase.leaving) {
      if (placement.succeeded) {
        await jami.leaveGroupCall(
          placement.conferenceId,
          reservationId: reservation,
        );
      }
      return;
    }
    if (!placement.succeeded) {
      _scheduleGroupCallRecovery();
      return;
    }
    if (placement.conferenceId != current.conferenceId ||
        (current.callId.isNotEmpty && current.callId != placement.callId)) {
      await leaveGroupVoice();
      return;
    }
    current.callId = placement.callId;
    current.hosting = placement.hosting;
    if (current.connected) await _completeGroupConnection(current);
    notifyListeners();
  }

  Future<void> _joinCanonicalGroupCall(GroupActiveCall target) async {
    final current = groupCall;
    if (current == null ||
        !current.connected ||
        current.replacementInProgress ||
        current.conferenceId == target.conferenceId ||
        current.failedConferenceIds.contains(target.conferenceId)) {
      return;
    }
    current.replacementInProgress = true;
    try {
      if (!await _detachGroupForReplacement(current)) return;
      if (!await _reserveGroupReplacement(current)) return;
      try {
        await _placeGroupReplacement(current, target);
      } catch (_) {
        if (identical(groupCall, current)) {
          current.phase = GroupCallPhase.failed;
          current.error = 'Voice connection could not be established';
          notifyListeners();
        }
      }
    } finally {
      current.replacementInProgress = false;
    }
  }

  Future<void> startCallTo(String? p, {bool withVideo = false}) async {
    // Gate on appearOffline locally too: the daemon's UNREGISTERED round-trip lags the toggle, so without this a
    // call could be placed in the window right after going dark — a presence leak in the exact moment you want out.
    if (p == null ||
        p.isEmpty ||
        !_friends.containsKey(p) ||
        _directPeerClosed(p) ||
        call != null ||
        groupCall != null ||
        _groupJoinOperation != null ||
        !registered ||
        placing ||
        appearOffline) {
      return;
    }
    placing = true;
    final initialAudioMuted =
        _microphonePolicyUnavailable ||
        microphoneModeForFriend(p).mode != MicrophoneMode.open;
    _earlyOutgoingCallEvents.clear();
    _terminalCallIdsDuringPlacement.clear();
    _winnerCallIdDuringPlacement = null;
    dlog('→ placeCall video=$withVideo (profile=$connectionProfile)');
    notifyListeners();
    try {
      // REGISTERED is the local call-readiness gate. Do not wait for deviceAnnounced here: libjami owns routing
      // and transport readiness, while an app timer adds call setup latency and can turn a simultaneous placement
      // into an incoming-only call before our native outgoing leg exists for glare arbitration.
      final placement = await jami.placeCall(
        p,
        withVideo: withVideo,
        initialAudioMuted: initialAudioMuted,
      );
      final callId = placement.callId;
      if (callId.isEmpty) return;
      _wakePeers([p]);
      final placementWinner = _winnerCallIdDuringPlacement;
      if (placementWinner != null && placementWinner != callId) {
        if (_terminalCallIdsDuringPlacement.contains(callId)) {
          dlog('placement $callId already ended after winner $placementWinner');
          return;
        }
        _retiredGlareCallIds[callId] = CallDir.outgoing;
        _runInBackground(
          jami.hangUp(callId),
          'hangUp(late placement after CURRENT winner)',
        );
        dlog(
          'glare: placement $callId lost to CURRENT $placementWinner before its reply',
        );
        return;
      }
      // A same-peer ring can land while placeCall is inside libjami. That is glare, and neither Dart leg may be
      // ended before the daemon's identity/media arbitration runs. A different/connected call still makes this
      // just-placed leg unwanted.
      if (call != null || !_friends.containsKey(p)) {
        if (_terminalCallIdsDuringPlacement.contains(callId)) {
          dlog('placement $callId already reached terminal before its reply');
          return;
        }
        final visible = call;
        if (visible?.callId == callId) {
          return; // an early CURRENT already adopted our returned outgoing leg
        }
        final unresolvedSamePeer =
            visible != null && visible.peerId == p && !visible.everConnected;
        if (!unresolvedSamePeer) {
          _retiredGlareCallIds[callId] = CallDir.outgoing;
          _runInBackground(
            jami.hangUp(callId),
            'hangUp(placement no longer wanted)',
          );
        } else {
          _unresolvedOutgoingCallIds.add(callId);
          dlog(
            'glare: leaving placed leg $callId untouched until a CURRENT winner against ${visible.callId}',
          );
          // A decisive callback can beat placeCall's reply and was buffered before this outgoing id could be
          // tracked. Replay CURRENT so it can win, and terminal so the just-added unresolved id cannot be stranded.
          for (final e in List<JamiEvent>.of(_earlyOutgoingCallEvents)) {
            if (e.type == 'callState' &&
                _asString(e.data['callId']) == callId &&
                (_asString(e.data['state']) == 'CURRENT' ||
                    _terminal.contains(_asString(e.data['state'])))) {
              _onEvent(e);
            }
          }
        }
        return;
      }
      final c = CallSession(
        callId: callId,
        dir: CallDir.outgoing,
        peerId: p,
        state: 'CONNECTING',
        outgoingVideo: placement.outgoingVideo,
      );
      _seedCallMicrophone(c);
      // Install the session before texture awaits, then reduce callbacks that beat the placeCall reply.
      call = c;
      _playSound(SyblSoundEvent.outgoingRing);
      _syncPresenceRuntime();
      _replayEarlyOutgoingCallEvents(c);
      if (!identical(call, c)) {
        return; // an early terminal callback already ended it
      }
      // Decide textures from the SESSION, not the placement result: replay may have delivered a
      // newer camera truth (e.g. a buffered cameraState(false) after an early capture failure).
      if (c.cameraOn) {
        final textureRevision = c.cameraRevision;
        await _createSelfTexture(c);
        if (!identical(call, c) ||
            !c.cameraOn ||
            c.cameraRevision != textureRevision) {
          return;
        }
        await _createRemoteTexture(c);
        if (!identical(call, c) ||
            !c.cameraOn ||
            c.cameraRevision != textureRevision) {
          return;
        }
      }
    } finally {
      placing = false;
      _earlyOutgoingCallEvents.clear();
      _terminalCallIdsDuringPlacement.clear();
      _winnerCallIdDuringPlacement = null;
      notifyListeners();
    }
  }

  Future<bool> notifyCallRequest(String? peer) async {
    if (peer == null ||
        !_friends.containsKey(peer) ||
        _directPeerClosed(peer) ||
        !registered ||
        appearOffline) {
      return false;
    }
    try {
      final sent = await jami.notifyCallRequest(peer);
      if (sent) _wakePeers([peer]);
      return sent;
    } catch (error) {
      dlog('notifyCallRequest failed: $error');
      return false;
    }
  }

  void _replayEarlyOutgoingCallEvents(CallSession c) {
    final pending = List<JamiEvent>.of(_earlyOutgoingCallEvents);
    _earlyOutgoingCallEvents.clear();
    for (final e in pending) {
      if ((e.type == 'callState' ||
              e.type == 'peerVideo' ||
              e.type == 'cameraState' ||
              e.type == 'outgoingVideoSource') &&
          e.data['callId'] != c.callId) {
        continue;
      }
      _onEvent(e);
      if (!identical(call, c)) break;
    }
  }

  Future<void> answer(CallSession c) async {
    if (!identical(call, c) ||
        c.dir != CallDir.incoming ||
        c.everConnected ||
        c.connected ||
        _terminal.contains(c.state)) {
      return;
    }
    // A ring that arrived before the peer left or before Remove was clicked
    // stays visible only so it can be declined.
    if (_directPeerClosed(c.peerId)) return;
    try {
      await jami.answerCall(
        c.callId,
        initialAudioMuted: _microphonePolicyUnavailable || c.micMuted,
      );
    } catch (e) {
      dlog('answerCall(${c.callId}) failed: $e');
    }
  }

  Future<void> decline(CallSession c) async {
    if (!identical(call, c) ||
        c.dir != CallDir.incoming ||
        c.everConnected ||
        c.connected ||
        _terminal.contains(c.state)) {
      return;
    }
    try {
      await jami.refuse(c.callId);
    } catch (e) {
      dlog('refuse(${c.callId}) failed: $e');
      return;
    }
    if (!identical(call, c)) return;
    _runInBackground(_retireMicrophoneRuntime(), 'retireMicrophone(decline)');
    call = _takePendingIncomingCall();
    _playSound(SyblSoundEvent.stopRinging);
    _playSound(
      call == null ? SyblSoundEvent.callEnded : SyblSoundEvent.incomingRing,
    );
    if (call != null) callEndedNote = null;
    annotation.reset();
    _syncRemoteControl();
    _syncPresenceRuntime();
    notifyListeners();
  }

  Future<void> hangUp() async {
    final c = call;
    if (c == null) return;
    // the terminal callState event clears `call`; drop the draw overlay NOW (P3-A5) so annotation state never
    // outlives the user's hang-up even if that terminal event is lost on a stuck call. Reset before awaiting so a
    // late native completion cannot wipe annotations created by a replacement call.
    annotation.reset();
    _syncRemoteControl();
    _runInBackground(_retireMicrophoneRuntime(), 'retireMicrophone(hangUp)');
    try {
      await jami.hangUp(c.callId);
    } catch (e) {
      dlog('hangUp(${c.callId}) failed: $e');
      if (identical(call, c) && c.connected) {
        _runInBackground(
          _configureMicrophoneRuntime(c),
          'restoreMicrophone(hangUp failed)',
        );
      }
    }
  }

  EffectiveMicrophoneMode _effectiveMicrophoneMode(CallSession session) {
    final scope = _scopeForPeer(session.peerId);
    final source = scope == null
        ? MicrophoneModeSource.globalDefault
        : appSettings.microphoneModeFor(scope).source;
    return EffectiveMicrophoneMode(mode: session.micMode, source: source);
  }

  void _seedCallMicrophone(CallSession session) {
    final effective = microphoneModeForFriend(session.peerId);
    session.micMode = effective.mode;
    session.manuallyMuted = false;
    session.pushToTalkPressed = false;
    // PTT bootstraps the daemon media offer muted. Legacy voice-activated
    // preferences are normalized to open before they can reach a CallSession.
    // This is transient policy state, never a user-authored manual mute.
    session.microphoneBootstrapMuted =
        _microphonePolicyUnavailable || effective.mode != MicrophoneMode.open;
    session.micMuted = session.microphoneBootstrapMuted;
    session.microphonePolicyApplied = false;
    session.localVoiceActive = false;
  }

  MicrophoneDecision _evaluateMicrophone(CallSession session) =>
      MicrophonePolicy(
        effectiveMode: _effectiveMicrophoneMode(session),
        sessionActive: session.connected,
        privacySuspended: _microphonePolicyUnavailable,
        manuallyMuted: session.manuallyMuted,
        pushToTalkPressed: session.pushToTalkPressed,
      ).evaluate();

  Future<void> _enqueueMicrophoneCommand(Future<void> Function() command) {
    final operation = _microphoneCommandTail.then((_) => command());
    _microphoneCommandTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  bool _ownsMicrophoneGeneration(CallSession session, int generation) =>
      !_disposed &&
      identical(call, session) &&
      session.connected &&
      !session.microphoneTeardownPending &&
      generation == _microphoneGeneration;

  Future<bool> _applyMicrophoneProjection(CallSession session) async {
    if (!identical(call, session) || !session.connected) return false;
    if (!session.microphonePolicyApplied) {
      await _configureMicrophoneRuntime(session);
      return identical(call, session) && session.microphonePolicyApplied;
    }
    final generation = _microphoneGeneration;
    final account = _microphoneAccountOwner;
    session.microphoneCommandsInFlight++;
    try {
      await _enqueueMicrophoneCommand(() async {
        if (_microphoneAccountOwner != account ||
            !_ownsMicrophoneGeneration(session, generation)) {
          return;
        }
        final decision = _evaluateMicrophone(session);
        microphoneDecision = decision;
        final muted = decision.mustMute;
        if (session.acknowledgedMicrophoneMuted == muted) return;
        try {
          await jami.setMicMuted(session.callId, muted);
          if (_microphoneAccountOwner != account ||
              !_ownsMicrophoneGeneration(session, generation)) {
            return;
          }
          session.acknowledgedMicrophoneMuted = muted;
          session.micMuted = muted;
          session.localVoiceActive = session.localVoiceActive && !muted;
          if (muted) voiceMeter.value = 0;
          microphoneError = null;
        } catch (error) {
          if (_microphoneAccountOwner != account ||
              !_ownsMicrophoneGeneration(session, generation)) {
            return;
          }
          session.acknowledgedMicrophoneMuted = null;
          session.microphonePolicyApplied = false;
          microphoneError = 'Could not apply the microphone policy.';
          var protected = false;
          if (!muted) {
            try {
              await jami.setMicMuted(session.callId, true);
              protected = true;
            } catch (failure) {
              dlog('protect microphone failed: $failure');
            }
          }
          if (_microphoneAccountOwner != account ||
              !_ownsMicrophoneGeneration(session, generation)) {
            return;
          }
          session.acknowledgedMicrophoneMuted = protected ? true : null;
          if (protected) session.micMuted = true;
          if (!protected) {
            session.pushToTalkPressed = false;
            session.microphoneTeardownPending = true;
            try {
              await jami.hangUp(session.callId);
            } catch (failure) {
              dlog('hangUp(microphone failure): $failure');
            }
          }
          dlog('setMicMuted($muted) failed: $error');
        }
        if (!_disposed && identical(call, session)) notifyListeners();
      });
    } finally {
      session.microphoneCommandsInFlight--;
    }
    return identical(call, session) && session.microphonePolicyApplied;
  }

  Future<void> _retireMicrophoneRuntime({bool clearError = true}) async {
    ++_microphoneGeneration;
    final session = call;
    if (session != null) {
      session.localVoiceActive = false;
      session.microphonePolicyApplied = false;
    }
    voiceMeter.value = 0;
    if (_audioMeterEnabled) {
      _audioMeterEnabled = false;
      try {
        await jami.setAudioMeterEnabled(false);
      } catch (error) {
        dlog('setAudioMeterEnabled(false) failed: $error');
      }
    }
    microphoneDecision = _inactiveMicrophonePolicy.evaluate();
    if (clearError) microphoneError = null;
  }

  Future<void> _configureMicrophoneRuntime(CallSession session) async {
    final retirement = _retireMicrophoneRuntime();
    final generation = _microphoneGeneration;
    final account = _microphoneAccountOwner;
    await retirement;
    if (_microphoneAccountOwner != account ||
        !_ownsMicrophoneGeneration(session, generation)) {
      return;
    }
    final decision = _evaluateMicrophone(session);
    var requestedMuted = decision.mustMute;
    final transmissionMode = session.micMode == MicrophoneMode.voiceActivated
        ? AudioTransmissionMode.voiceActivated
        : AudioTransmissionMode.open;
    microphoneDecision = decision;
    session.microphonePolicyApplied = false;
    session.localVoiceActive = false;
    voiceMeter.value = 0;
    notifyListeners();

    var issued = false;
    var safetyMuted = false;
    var modeApplied = false;
    var unmuteIssued = false;
    session.microphoneCommandsInFlight++;
    try {
      await _enqueueMicrophoneCommand(() async {
        if (_microphoneAccountOwner != account ||
            !_ownsMicrophoneGeneration(session, generation)) {
          return;
        }
        issued = true;

        // Reconfiguration is transactional from the user's privacy
        // perspective: explicitly close the sender first, then select the
        // daemon gate, and only then restore the requested explicit-mute
        // projection. A failed voice gate can therefore never degrade to open.
        await jami.setMicMuted(session.callId, true);
        safetyMuted = true;
        if (_microphoneAccountOwner != account ||
            !_ownsMicrophoneGeneration(session, generation)) {
          return;
        }
        session.acknowledgedMicrophoneMuted = true;
        session.micMuted = true;
        session.localVoiceActive = false;
        voiceMeter.value = 0;
        notifyListeners();

        await jami.setAudioTransmissionMode(session.callId, transmissionMode);
        modeApplied = true;
        if (_microphoneAccountOwner != account ||
            !_ownsMicrophoneGeneration(session, generation)) {
          return;
        }

        requestedMuted = _evaluateMicrophone(session).mustMute;

        if (!requestedMuted) {
          unmuteIssued = true;
          await jami.setMicMuted(session.callId, false);
        }
      });
      if (_microphoneAccountOwner == account &&
          _ownsMicrophoneGeneration(session, generation) &&
          issued &&
          safetyMuted &&
          modeApplied) {
        session.micMuted = requestedMuted;
        session.acknowledgedMicrophoneMuted = requestedMuted;
        session.microphoneBootstrapMuted = false;
        session.microphonePolicyApplied = true;
        microphoneError = null;
        if (!_audioMeterEnabled) {
          try {
            await jami.setAudioMeterEnabled(true);
            _audioMeterEnabled = true;
          } catch (error) {
            dlog('setAudioMeterEnabled(true) failed: $error');
          }
        }
        notifyListeners();
      }
    } catch (error) {
      if (_microphoneAccountOwner == account &&
          _ownsMicrophoneGeneration(session, generation)) {
        if (unmuteIssued) {
          safetyMuted = false;
          try {
            await jami.setMicMuted(session.callId, true);
            safetyMuted = true;
          } catch (failure) {
            dlog('protect configured microphone: $failure');
          }
          if (_microphoneAccountOwner != account ||
              !_ownsMicrophoneGeneration(session, generation)) {
            return;
          }
        }
        // Invalidate any explicit-mute projection queued behind this failed
        // transaction. It must not reopen a sender whose daemon gate failed.
        ++_microphoneGeneration;
        session.acknowledgedMicrophoneMuted = safetyMuted ? true : null;
        session.micMuted = safetyMuted;
        session.localVoiceActive = false;
        session.microphonePolicyApplied = false;
        voiceMeter.value = 0;
        microphoneError = safetyMuted
            ? 'Could not configure the microphone. The microphone stayed muted.'
            : 'Microphone state is unknown. Ending the call.';
        notifyListeners();
        if (!safetyMuted) {
          session.microphoneTeardownPending = true;
          session.pushToTalkPressed = false;
          // Even the protective explicit mute failed, so no media-level
          // no-transmit guarantee remains.
          _runInBackground(
            jami.hangUp(session.callId),
            'hangUp(microphone configuration failure)',
          );
        }
      }
      dlog('setAudioTransmissionMode(${transmissionMode.name}) failed: $error');
    } finally {
      session.microphoneCommandsInFlight--;
    }
  }

  Future<void> _applySettingsToActiveCall() async {
    final group = groupCall;
    if (group != null) {
      final mode = microphoneModeForGroup(group.conversationId).mode;
      if (group.micMode != mode) {
        group.micMode = mode;
        group.pushToTalkPressed = false;
      }
      await _projectGroupMicrophone(group);
    }
    final session = call;
    if (session == null) return;
    final nextMode = microphoneModeForFriend(session.peerId).mode;
    if (session.micMode == nextMode && session.microphonePolicyApplied) {
      await _applyMicrophoneProjection(session);
      return;
    }
    final modeChanged = session.micMode != nextMode;
    session.micMode = nextMode;
    if (modeChanged) {
      session.pushToTalkPressed = false;
    }
    session.microphonePolicyApplied = false;
    if (!session.connected) {
      session.microphoneBootstrapMuted =
          _microphonePolicyUnavailable || nextMode != MicrophoneMode.open;
      session.micMuted = session.microphoneBootstrapMuted;
      session.localVoiceActive = false;
      voiceMeter.value = 0;
      notifyListeners();
      return;
    }
    await _configureMicrophoneRuntime(session);
  }

  void _commitSavedMicrophoneMode() {
    final commit = _pendingMicrophoneModeCommit;
    _pendingMicrophoneModeCommit = null;
    commit?.call();
  }

  void _setMicrophoneSettingsKnown(bool known) {
    // Commit the captured mode action once, at durability. Later manual
    // controls and controls used while the cache reloads retain ownership.
    if (known) _commitSavedMicrophoneMode();
    if (_microphoneSettingsKnown == known) return;
    _microphoneSettingsKnown = known;
    if (known) {
      // A successful save can change the effective mode. Install that mode
      // before reopening a sender, even while the preferences cache reloads.
      _runInBackground(
        _applySettingsToActiveCall(),
        'apply authoritative microphone settings',
      );
      return;
    }
    final direct = call;
    if (direct != null) {
      if (direct.connected) {
        _runInBackground(
          _applyMicrophoneProjection(direct),
          'microphone settings authority',
        );
      } else {
        direct.microphoneBootstrapMuted =
            _microphonePolicyUnavailable ||
            direct.micMode != MicrophoneMode.open;
        direct.micMuted = direct.microphoneBootstrapMuted;
      }
    }
    final group = groupCall;
    if (group != null && group.connected) {
      _runInBackground(
        _projectGroupMicrophone(group),
        'group microphone settings authority',
      );
    }
  }

  void _releaseHeldMicrophones() {
    final direct = call;
    if (direct != null && direct.pushToTalkPressed) {
      direct.pushToTalkPressed = false;
      _runInBackground(
        _applyMicrophoneProjection(direct),
        'release microphone on lifecycle loss',
      );
    }
    final group = groupCall;
    if (group != null && group.pushToTalkPressed) {
      group.pushToTalkPressed = false;
      _runInBackground(
        _projectGroupMicrophone(group),
        'release group microphone on lifecycle loss',
      );
    }
  }

  void _handleLocalVoiceActivity(JamiEvent event) {
    final session = call;
    if (session == null ||
        !session.connected ||
        _asString(event.data['callId']) != session.callId ||
        session.micMode != MicrophoneMode.voiceActivated ||
        !_ownsMicrophoneGeneration(session, _microphoneGeneration)) {
      return;
    }
    final active = _asBool(event.data['active']) && !session.micMuted;
    if (session.localVoiceActive == active) return;
    session.localVoiceActive = active;
    if (!_audioMeterEnabled) voiceMeter.value = active ? 1 : 0;
    notifyListeners();
  }

  void _handleAudioMeter(JamiEvent event) {
    final session = call;
    if (session == null || !session.connected || session.micMuted) {
      if (voiceMeter.value != 0) voiceMeter.value = 0;
      return;
    }
    final raw = event.data['level'];
    final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (parsed == null || !parsed.isFinite) return;
    final level = parsed.clamp(0.0, 1.0);
    if ((voiceMeter.value - level).abs() >= .01) voiceMeter.value = level;
  }

  void _handleRemoteAudioMeter(JamiEvent event) {
    final session = call;
    final revision = _nativeAccountRevision(event);
    final eventAccount = _asString(event.data['accountId']);
    final callId = _asString(event.data['callId']);
    final streamId = _asString(event.data['streamId']);
    final level = double.tryParse(_asString(event.data['level']));
    if (session == null ||
        !session.connected ||
        revision == null ||
        !isTrustedWidgetRemoteAudioMeter(
          expectedAccountId: accountId ?? '',
          eventAccountId: eventAccount,
          expectedCallId: session.callId,
          eventCallId: callId,
          expectedNativeRevision: session.nativeAccountRevision,
          eventNativeRevision: revision,
          eventStreamId: streamId,
          level: level,
        )) {
      return;
    }
    if (level == null) return;
    final boundStream = session.remoteVoiceStreamId;
    if (boundStream != null && boundStream != streamId) return;

    final previousSpeaking = _remoteVoiceSpeaking(session);
    session.remoteVoiceStreamId ??= streamId;
    session.remoteVoiceLevel = level;
    final sampledAt = DateTime.now();
    session.remoteVoiceMeterAt = sampledAt;
    session.remoteVoiceExpiry?.cancel();
    session.remoteVoiceExpiry = Timer(const Duration(seconds: 1), () {
      if (_disposed ||
          !identical(call, session) ||
          !session.connected ||
          session.nativeAccountRevision != revision ||
          session.remoteVoiceStreamId != streamId ||
          session.remoteVoiceMeterAt != sampledAt) {
        return;
      }
      session.clearRemoteVoiceSample();
      notifyListeners();
    });
    if (previousSpeaking != (level >= .02)) notifyListeners();
  }

  Future<void> toggleMute() async {
    final session = call;
    if (session == null || !session.connected) return;
    final wasMuted = session.micMuted;
    session.manualMuteRevision++;
    session.manuallyMuted = !session.manuallyMuted;
    notifyListeners();
    await _applyMicrophoneProjection(session);
    if (identical(call, session) && session.micMuted != wasMuted) {
      _playSound(
        session.micMuted ? SyblSoundEvent.micMute : SyblSoundEvent.micUnmute,
      );
    }
  }

  Future<void> setMicMode(MicrophoneMode mode) async {
    final session = call;
    if (session == null) return;
    await setFriendMicrophoneMode(session.peerId, mode);
  }

  Future<void> pttHold(bool down) async {
    if (down && (!_microphoneControlsFocused || _protectedSurfaceLocked)) {
      return;
    }
    final session = call;
    if (session == null ||
        !session.connected ||
        session.microphoneTeardownPending ||
        session.micMode != MicrophoneMode.pushToTalk ||
        session.pushToTalkPressed == down) {
      return;
    }
    session.pushToTalkPressed = down;
    notifyListeners();
    await _applyMicrophoneProjection(session);
  }

  Future<void> toggleSpeaker() async {
    final c = call;
    if (c == null || !speakerControlAvailable) return;
    final previous = c.speakerOn;
    final requested = !previous;
    c.speakerOn = requested;
    notifyListeners();
    try {
      await jami.setSpeaker(requested);
    } catch (e) {
      if (identical(call, c) && c.speakerOn == requested) {
        c.speakerOn = previous;
        notifyListeners();
      }
      dlog('setSpeaker($requested) failed: $e');
    }
  }

  // ---- video (M2) ----

  void _syncAnnotationSources(CallSession c, {bool peerSourceChanged = false}) {
    annotation.syncSources(
      localOwner: jamiId,
      peerOwner: c.peerId,
      localRevision: c.outgoingVideo.effectiveControlRevision,
      localKind: c.outgoingVideo.kind,
      peerKind: c.peerVideoKind,
      peerSourceChanged: peerSourceChanged,
    );
    if (c.remoteActive) annotation.ensurePeerSourceDiscovery();
    _syncRemoteControl();
  }

  bool get peerSharedScreenReady {
    final c = call;
    final revision = annotation.peerSourceRevision;
    return c?.connected == true &&
        c!.remoteActive &&
        c.remoteWidth > 0 &&
        c.remoteHeight > 0 &&
        annotation.peerSourceOwner == c.peerId &&
        annotation.peerSourceKind == OutgoingVideoKind.screen &&
        revision != null &&
        revision > 0;
  }

  void _syncRemoteControl() {
    final c = call;
    remoteControl.syncCall(
      live:
          c?.connected == true &&
          _friendsAccountOwner == (accountId, _accountRevision) &&
          _friends[c!.peerId]?.confirmed == true &&
          !_uncertainControlPeers.contains(c.peerId) &&
          !_directPeerClosed(c.peerId),
      foreground:
          _foreground && !_protectedSurfaceLocked && !captureGateVisible,
      hostAvailable: !_protectedSurfaceLocked && !captureGateVisible,
      callId: c?.callId ?? '',
      peerId: c?.peerId ?? '',
      peerScreenActive: peerSharedScreenReady,
      peerSourceRevision: annotation.peerSourceOwner == c?.peerId
          ? annotation.peerSourceRevision
          : null,
      localScreenActive: c?.sharingScreen == true,
      localSourceRevision: c?.outgoingVideo.effectiveControlRevision ?? 0,
    );
  }

  String get remoteControlTargetPlatform {
    final capabilities = remoteControl.grantedCapabilities;
    if (capabilities.contains(RemoteControlCapability.back) ||
        capabilities.contains(RemoteControlCapability.home) ||
        capabilities.contains(RemoteControlCapability.recents)) {
      return 'android';
    }
    if (capabilities.contains(RemoteControlCapability.keyboard) ||
        capabilities.contains(RemoteControlCapability.clipboard)) {
      return 'windows';
    }
    return annotation.peerPlatform;
  }

  /// App-lock visibility is a separate authority boundary from OS lifecycle.
  /// A manual lock leaves the window foregrounded, so explicitly retire any
  /// controller, pending consent, or hosted control session.
  void setProtectedSurfaceLocked(bool locked) {
    if (_protectedSurfaceLocked == locked) return;
    _protectedSurfaceLocked = locked;
    if (locked) _retireWidgetChatSession();
    _syncNearby();
    _refreshHologramPrivacy();
    if (locked) {
      retireHistorySearch();
      // An action opened before locking cannot regain ownership on unlock.
      _conversationSelectionRevision++;
      _releaseHeldMicrophones();
      _retireLocalComposerActivity();
      _clearRemoteComposerActivities();
    }
    _syncRemoteControl();
  }

  CallInteractionMode get callInteractionMode {
    if (remoteControl.isControlling) return CallInteractionMode.control;
    if (remoteControl.phase == RemoteControlPhase.requesting) {
      return CallInteractionMode.requestingControl;
    }
    if (annotation.enabled) return CallInteractionMode.draw;
    return CallInteractionMode.point;
  }

  /// Selects which live source is presented for pointing/drawing.
  ///
  /// Changing away from the controlled screen explicitly retires the remote
  /// control role first; one pointer stream can never address two authorities.
  void selectAnnotationTarget(AnnotationTarget target) {
    if (remoteControl.controllerBinding != null) {
      unawaited(remoteControl.stopControlling(reason: 'interaction-mode'));
    }
    annotation.setTarget(target);
  }

  void setAnnotationEnabled(bool enabled) {
    if (enabled && remoteControl.controllerBinding != null) {
      // stopControlling retires local input synchronously before awaiting the
      // best-effort end packet.
      unawaited(remoteControl.stopControlling(reason: 'interaction-mode'));
    }
    annotation.setEnabled(enabled);
  }

  Future<bool> requestRemoteControl() {
    annotation.setEnabled(false);
    if (annotation.canTargetTheirs) {
      annotation.setTarget(AnnotationTarget.theirs);
      _syncRemoteControl();
    }
    return remoteControl.requestControl();
  }

  Future<void> stopRemoteControl() => remoteControl.stopControlling();

  Future<bool> allowRemoteControl(
    RemoteControlHostRequest expectedRequest, {
    bool persistDevice = false,
  }) async {
    final owner = (accountId, _accountRevision);
    final originalCall = call;
    try {
      await _refreshFriendsFromDaemon();
    } catch (error) {
      if (!_disposed &&
          owner == (accountId, _accountRevision) &&
          identical(call, originalCall) &&
          originalCall?.peerId == expectedRequest.binding.peerId) {
        _controlTrustWarning = (
          account: owner,
          peerId: expectedRequest.binding.peerId,
          message:
              'Friend trust could not be confirmed. Control was not allowed.',
        );
        notifyListeners();
      }
      return false;
    }
    if (_disposed ||
        owner != (accountId, _accountRevision) ||
        !identical(call, originalCall)) {
      return false;
    }
    _syncRemoteControl();
    return remoteControl.allowHost(
      expectedRequest: expectedRequest,
      persistDevice: persistDevice,
    );
  }

  Future<bool> denyRemoteControl(RemoteControlHostRequest expectedRequest) =>
      remoteControl.denyHost(expectedRequest);

  Future<bool> stopHostedRemoteControl() => remoteControl.stopHost();

  Future<bool> openAndroidRemoteControlSettings() =>
      jami.openRemoteControlAccessibilitySettings();

  Future<void> _refreshRemoteControlAccessibilityStatus() async {
    final enabled = await jami.remoteControlAccessibilityEnabled();
    if (_disposed || enabled == remoteControlAccessibilityEnabled) return;
    remoteControlAccessibilityEnabled = enabled;
    notifyListeners();
  }

  Future<bool> setRemoteCoControl(bool enabled) =>
      remoteControl.setCoControl(enabled);

  Future<bool> sendRemoteClipboard() {
    final account = _accountId;
    return remoteControl.sendClipboardFromReader(
      () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      stillCurrent: () => !_disposed && _accountId == account,
    );
  }

  Future<bool> acceptRemoteClipboard(RemoteClipboardRequest expectedRequest) =>
      remoteControl.acceptClipboard(
        (text) => Clipboard.setData(ClipboardData(text: text)),
        expectedRequest: expectedRequest,
      );

  Future<bool> rejectRemoteClipboard(RemoteClipboardRequest expectedRequest) =>
      remoteControl.rejectClipboard(expectedRequest: expectedRequest);

  void remotePointerMove(double x, double y) => remoteControl.move(x, y);

  void remotePointerButton(RemoteMouseButton button, {required bool down}) =>
      remoteControl.button(button, down: down);

  void remotePointerClick([
    RemoteMouseButton button = RemoteMouseButton.left,
  ]) => remoteControl.click(button);

  void remotePointerWheel(int delta) => remoteControl.wheel(delta);

  void remoteKey(int virtualKey, {required bool down}) =>
      remoteControl.key(virtualKey, down: down);

  void remoteText(String text) => remoteControl.text(text);

  Future<void> toggleCamera() async {
    final c = call;
    if (c == null || c.cameraChanging || (!c.connected && !c.cameraOn)) return;
    await setOutgoingVideoSource(
      c.cameraOn ? OutgoingVideoKind.off : OutgoingVideoKind.camera,
    );
  }

  Future<void> toggleScreenShare({
    required String expectedCallId,
    String? sourceId,
  }) async {
    final c = call;
    if (c == null ||
        c.callId != expectedCallId ||
        !c.connected ||
        c.sourceChanging) {
      return;
    }
    await setOutgoingVideoSource(
      c.sharingScreen ? OutgoingVideoKind.off : OutgoingVideoKind.screen,
      sourceId: sourceId,
    );
  }

  Future<List<ScreenSource>> listScreenSources({
    required String expectedCallId,
  }) async {
    final c = call;
    if (c == null || c.callId != expectedCallId || !c.connected) {
      return const [];
    }
    try {
      final sources = await jami.listScreenSources(expectedCallId);
      final current = call;
      return identical(current, c) &&
              current?.callId == expectedCallId &&
              current?.connected == true
          ? sources
          : const [];
    } catch (e) {
      dlog('listScreenSources failed: $e');
      return const [];
    }
  }

  Future<void> setOutgoingVideoSource(
    OutgoingVideoKind kind, {
    String? sourceId,
  }) async {
    final c = call;
    if (c == null ||
        c.sourceChanging ||
        (!c.connected && kind != OutgoingVideoKind.off)) {
      return;
    }
    final before = c.outgoingVideo;
    final revision = before.revision;
    c.sourceChanging = true;
    if (kind == OutgoingVideoKind.off) {
      c.outgoingVideo = const OutgoingVideoSource.off().copyWith(
        revision: revision,
      );
    }
    notifyListeners();
    try {
      final ok = switch (kind) {
        OutgoingVideoKind.camera => await jami.startVideo(c.callId),
        OutgoingVideoKind.off => await jami.stopVideo(c.callId),
        OutgoingVideoKind.screen => await jami.setOutgoingVideoSource(
          c.callId,
          kind,
          sourceId: sourceId,
        ),
      };
      if (!identical(call, c)) return;
      if (!ok) {
        if (c.outgoingVideo.revision == revision) {
          c.outgoingVideo = before;
          notifyListeners();
        }
        return;
      }
      if (c.outgoingVideo.revision == revision) {
        c.outgoingVideo = OutgoingVideoSource(
          kind: kind,
          uri: kind == OutgoingVideoKind.off ? '' : before.uri,
          revision: revision,
        );
        _syncAnnotationSources(c);
        _playVideoSourceSound(before.kind, kind);
        notifyListeners();
      }
      if (!c.outgoingVideo.active || c.outgoingVideo.revision != revision) {
        return;
      }
      if (kind != OutgoingVideoKind.off) {
        await _createSelfTexture(c);
        if (!identical(call, c) || c.outgoingVideo.revision != revision) {
          return;
        }
        await _createRemoteTexture(c);
      }
    } catch (e) {
      if (identical(call, c) && c.outgoingVideo.revision == revision) {
        c.outgoingVideo = before;
        notifyListeners();
      }
      dlog('setOutgoingVideoSource($kind) failed: $e');
    } finally {
      if (identical(call, c)) {
        c.sourceChanging = false;
        notifyListeners();
      }
    }
  }

  void _playVideoSourceSound(
    OutgoingVideoKind before,
    OutgoingVideoKind after,
  ) {
    if (before == after) return;
    if (before == OutgoingVideoKind.camera) {
      _playSound(SyblSoundEvent.cameraOff);
    } else if (before == OutgoingVideoKind.screen) {
      _playSound(SyblSoundEvent.screenShareOff);
    }
    if (after == OutgoingVideoKind.camera) {
      _playSound(SyblSoundEvent.cameraOn);
    } else if (after == OutgoingVideoKind.screen) {
      _playSound(SyblSoundEvent.screenShareOn);
    }
  }

  Future<void> switchCamera() async {
    final c = call;
    // Same self-guard as toggleCamera: both camera entry points gate here, so no call site can bypass it.
    if (c == null || !c.outgoingVideo.isCamera || c.sourceChanging) return;
    await jami.switchCamera(c.callId);
  }

  Future<void> _runStressMediaCommand(String command) async {
    final c = call;
    if (c == null || !c.connected || c.sourceChanging) return;
    switch (command) {
      case 'camera:on':
        if (!c.cameraOn) await setOutgoingVideoSource(OutgoingVideoKind.camera);
        return;
      case 'camera:off':
        if (c.cameraOn) await setOutgoingVideoSource(OutgoingVideoKind.off);
        return;
      case 'camera:flip':
        await switchCamera();
        return;
      case 'screen:on':
        if (c.sharingScreen) return;
        final sources = await listScreenSources(expectedCallId: c.callId);
        if (!identical(call, c)) return;
        final sourceId = sources.isEmpty
            ? null
            : sources
                  .firstWhere(
                    (source) => source.primary,
                    orElse: () => sources.first,
                  )
                  .id;
        await setOutgoingVideoSource(
          OutgoingVideoKind.screen,
          sourceId: sourceId,
        );
        return;
      case 'screen:off':
        if (c.sharingScreen) {
          await setOutgoingVideoSource(OutgoingVideoKind.off);
        }
        return;
    }
  }

  Future<void> _runStressGroupCommand(String command) async {
    if (command == 'group:leave') {
      await leaveGroupVoice();
      return;
    }
    if (command == 'group:camera') {
      await toggleGroupCamera();
      return;
    }
    if (command == 'group:screen:on') {
      final sources = await listGroupScreenSources();
      if (groupCall?.connected != true || groupCall?.screenShare == true) {
        return;
      }
      final sourceId = sources.isEmpty
          ? null
          : sources
                .firstWhere(
                  (source) => source.primary,
                  orElse: () => sources.first,
                )
                .id;
      await toggleGroupScreenShare(sourceId: sourceId);
      return;
    }
    if (command == 'group:screen:off') {
      if (groupCall?.screenShare == true) await toggleGroupScreenShare();
      return;
    }
    if (groupCall != null) return;
    for (final group in _groups.values) {
      for (final room in group.layout.rooms) {
        if (room.kind == GroupRoomKind.voice) {
          await joinGroupVoice(group, room);
          return;
        }
      }
    }
  }

  // ---- file transfer (M5) ----

  /// Pick a file with the OS dialog and send it to the selected direct or
  /// group conversation. The daemon-assigned file ID arrives through the
  /// outgoing commit/progress projection and immediately owns the shared row.
  Future<void> sendFile() {
    final scope = selectedConversationScope;
    if (scope != null && !scope.isGroup && _directPeerClosed(scope.peerId)) {
      return Future.value();
    }
    if (_dmTopicSelectionPending(scope)) {
      _reportDmTopicPending();
      return Future.value();
    }
    final topicId =
        scope != null &&
            !scope.isGroup &&
            _loadedDmTopicScopes.contains(scope) &&
            (_dmTopicStates[scope]?.customTopics.isNotEmpty ?? false)
        ? selectedDmTopicId
        : '';
    return _fileTransfers.sendFile(
      scope == null
          ? null
          : (peerId: scope.peerId, conversationId: scope.conversationId),
      topicId: topicId,
    );
  }

  bool _dmTopicSelectionPending(ConversationScope? scope) =>
      scope != null &&
      !scope.isGroup &&
      !_loadedDmTopicScopes.contains(scope) &&
      (_selectedDmTopicIds[scope] ?? DmTopicWire.mainId) != DmTopicWire.mainId;

  void _reportDmTopicPending() {
    chatError = switch (selectedDmTopicHistoryStatus) {
      DmTopicHistoryStatus.tooLarge =>
        'Topic history is too large to load safely. Sending to this topic is unavailable.',
      DmTopicHistoryStatus.failed =>
        'Topic history could not load. Retry before sending to this topic.',
      _ => 'Topic history is still loading. Wait before sending.',
    };
    notifyListeners();
  }

  Future<void> acceptFile(FileXfer transfer) =>
      _fileTransfers.acceptFile(transfer);

  Future<void> declineFile(FileXfer transfer) =>
      _fileTransfers.declineFile(transfer);

  Future<bool> openReceivedFile(String? path) async {
    if (path == null || path.trim().isEmpty) return false;
    try {
      return await jami.openReceivedFile(path);
    } catch (error) {
      dlog('openReceivedFile failed: $error');
      return false;
    }
  }

  // ---- file-keeping (M6) ----

  /// (Re)build the selected friend's persistent shared folder from conversation history. Native correlates the
  /// daemon callback with a load id; Dart also generations requests so a slow older load cannot replace a newer
  /// snapshot. A very fast callback may beat the MethodChannel reply, so it is buffered only while that exact
  /// owner scope has a request in flight and replayed after the returned id is known.
  void loadFolder() {
    final friend = selectedFriend;
    _fileTransfers.loadFolder(
      friend == null
          ? null
          : (peerId: friend.peerId, conversationId: friend.conversationId),
      keepLast: folderKeepLast,
    );
  }

  /// Download a folder file whose content isn't on disk yet — reuses the M5 download path (live progress row).
  Future<void> downloadFolderFile(FolderFile file) async {
    final account = accountId;
    if (account == null || account.isEmpty) return;
    await _downloadConversationFile(
      scope: ConversationScope(
        accountId: account,
        peerId: file.peerId,
        conversationId: file.conversationId,
      ),
      fileId: file.fileId,
      interactionId: file.interactionId,
      name: file.name,
      size: file.size,
      downloaded: file.downloaded,
      operation: 'downloadFolderFile',
      topicId: file.topicId,
      topicTagged: file.topicTagged,
      roomId: file.roomId,
    );
  }

  /// Download one file card from the exact selected timeline. The UI passes
  /// the normalized daemon item; AppState validates that it is still the
  /// controller-owned version and reuses the existing transfer path.
  Future<bool> downloadTimelineFile(TimelineFileItem item) async {
    final scope = selectedConversationScope;
    final timeline = _conversationTimeline;
    if (scope == null || timeline == null || item.scope != scope) return false;
    final owned = timeline.items
        .where((candidate) => candidate.daemonId == item.daemonId)
        .firstOrNull;
    if (owned is! TimelineFileItem || owned != item) return false;
    return _downloadConversationFile(
      scope: scope,
      fileId: item.fileId,
      interactionId: item.daemonId,
      name: item.displayName,
      size: item.totalBytes ?? -1,
      downloaded: item.downloaded,
      operation: 'downloadTimelineFile',
      topicId: item.topicId,
      topicTagged: item.topicTagged,
      roomId: item.roomId ?? '',
    );
  }

  Future<bool> _downloadConversationFile({
    required ConversationScope scope,
    required String fileId,
    required String interactionId,
    required String name,
    required int size,
    required bool downloaded,
    required String operation,
    required String topicId,
    required bool topicTagged,
    required String roomId,
  }) => _fileTransfers.downloadFile(
    owner: (peerId: scope.peerId, conversationId: scope.conversationId),
    fileId: fileId,
    interactionId: interactionId,
    name: name,
    size: size,
    downloaded: downloaded,
    operation: operation,
    topicId: topicId,
    topicTagged: topicTagged,
    roomId: roomId,
  );

  Future<void> removePeer({bool block = false}) async {
    final selected = peerId;
    if (selected != null) await _confirmRemoval(selected, block: block);
  }

  final Set<String> _archivingChats = {};
  bool archivingChat(String peerId) => _archivingChats.contains(peerId);
  List<ArchivedChatEntry> _archivedChats = const [];

  /// Read-only snapshots of chats whose friend removed you, newest first.
  List<ArchivedChatEntry> get archivedChats => _archivedChats;

  Future<void> refreshArchivedChats() async {
    final account = accountId;
    if (account == null || account.isEmpty) return;
    final entries = await chatArchive.list(account);
    if (_disposed || entries == null || accountId != account) return;
    _archivedChats = List.unmodifiable(entries);
    notifyListeners();
  }

  Future<bool> deleteArchivedChat(String id) async {
    final account = accountId;
    if (account == null || account.isEmpty) return false;
    final deleted = await chatArchive.delete(account, id);
    await refreshArchivedChats();
    return deleted;
  }

  /// Delete a chat whose friend removed you: trust goes, history is not kept.
  Future<FriendRemovalResult> deleteLeftChat(String p) {
    if (!peerLeft(p)) {
      return Future.value((
        peerId: p,
        status: FriendRemovalStatus.notRemoved,
        warning: 'This chat is still active.',
      ));
    }
    return _confirmRemoval(p);
  }

  /// Keep a read-only copy, then drop trust. Removal happens only after a
  /// complete snapshot is written; otherwise the friend stays as it was.
  Future<FriendRemovalResult> archiveLeftChat(String p) async {
    final scope = _scopeForPeer(p);
    if (scope == null || !peerLeft(p) || !_archivingChats.add(p)) {
      return (
        peerId: p,
        status: FriendRemovalStatus.notRemoved,
        warning: 'This chat cannot be archived now.',
      );
    }
    notifyListeners();
    try {
      final snapshot = await _snapshotChat(scope);
      if (_disposed || _scopeForPeer(p) != scope) {
        return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
      }
      if (snapshot == null) {
        return (
          peerId: p,
          status: FriendRemovalStatus.notRemoved,
          warning:
              'The whole chat could not be read, so it was not archived. Nothing was removed.',
        );
      }
      final written = await chatArchive.write(scope.accountId, p, snapshot);
      if (written != ChatArchiveWriteResult.saved) {
        return (
          peerId: p,
          status: FriendRemovalStatus.notRemoved,
          warning: switch (written) {
            ChatArchiveWriteResult.tooLarge =>
              'This chat is too large to archive. Nothing was removed.',
            ChatArchiveWriteResult.full =>
              'Archive is full. Delete an archived chat first. Nothing was removed.',
            _ => 'The archive could not be saved. Nothing was removed.',
          },
        );
      }
      await refreshArchivedChats();
      if (_disposed || _scopeForPeer(p) != scope) {
        return (peerId: p, status: FriendRemovalStatus.stale, warning: null);
      }
      return await _confirmRemoval(p);
    } finally {
      _archivingChats.remove(p);
      if (!_disposed) notifyListeners();
    }
  }

  /// Every daemon page of one exact conversation, or null if incomplete.
  Future<ArchivedChat?> _snapshotChat(ConversationScope scope) async {
    final controller = ConversationTimelineController(
      scope: scope,
      localAuthorId: jamiId,
      repository: _timelineRepository,
      pageSize: 200,
      allowedRemoteAuthorIds: {scope.peerId},
    );
    try {
      await controller.refresh();
      var pages = 1;
      while (controller.lastError == null && controller.hasMore) {
        if (controller.items.length > ChatArchiveStore.maximumItems ||
            ++pages > ChatArchiveStore.maximumItems ~/ 200 + 2) {
          return null;
        }
        await controller.loadMore();
      }
      if (controller.lastError != null ||
          controller.hasMore ||
          controller.isLoading ||
          controller.items.length > ChatArchiveStore.maximumItems) {
        return null;
      }
      final items = <ArchivedChatItem>[];
      for (final item in controller.items) {
        final mine = item.authorId == jamiId;
        switch (item) {
          case TimelineTextItem(:final text):
            items.add(
              ArchivedChatItem(
                mine: mine,
                at: item.createdAt,
                topic: item.topicId,
                text: text,
              ),
            );
          case TimelineStickerItem(:final sticker?):
            items.add(
              ArchivedChatItem(
                mine: mine,
                at: item.createdAt,
                topic: item.topicId,
                stickerId: sticker.assetId,
              ),
            );
          case TimelineFileItem():
            items.add(
              ArchivedChatItem(
                mine: mine,
                at: item.createdAt,
                topic: item.topicId,
                fileName: item.displayName,
                fileSize: item.totalBytes,
                fileDownloaded: item.downloaded,
              ),
            );
          default:
            break;
        }
      }
      return ArchivedChat(
        peerLabel: peerDisplayName(scope.peerId),
        archivedAt: DateTime.now().toUtc(),
        topics: {
          for (final topic
              in _dmTopicStates[scope]?.customTopics ?? const <DmTopic>[])
            topic.id: topic.name,
        },
        items: items,
      );
    } catch (error) {
      dlog('archive snapshot failed: $error');
      return null;
    } finally {
      controller.dispose();
    }
  }

  /// The peer is (about to be) sending video → make sure the remote tile exists so the cached bind can attach.
  Future<int?> _createRemoteTexture(CallSession c) async {
    if (c.remoteTextureId != null) return c.remoteTextureId;
    final cameraRevision = c.cameraRevision;
    final existing = _remoteTextureFuture;
    if (existing != null) {
      final id = await existing;
      if (!_mayInstallRemoteTexture(c, cameraRevision)) {
        return null;
      }
      c.remoteTextureId = id;
      notifyListeners();
      return id;
    }
    final pending = jami.createVideoTexture('remote');
    _remoteTextureFuture = pending;
    try {
      final id = await pending;
      if (!_mayInstallRemoteTexture(c, cameraRevision)) {
        return null;
      }
      c.remoteTextureId = id;
      notifyListeners();
      return id;
    } finally {
      // Native textures are role-cached for the engine lifetime. A stale completion is cleaned up by dropping its
      // session association and this single-flight future; a later valid session reuses the persistent texture.
      if (identical(_remoteTextureFuture, pending)) _remoteTextureFuture = null;
    }
  }

  bool _mayInstallRemoteTexture(CallSession c, int cameraRevision) =>
      identical(call, c) &&
      (c.peerVideo ||
          c.remoteActive ||
          (c.outgoingVideo.active && c.cameraRevision == cameraRevision));

  void _ensureRemoteTexture(CallSession c) {
    _runInBackground(_createRemoteTexture(c), 'createRemoteTexture');
  }

  Future<int?> _createSelfTexture(CallSession c) async {
    if (c.selfTextureId != null) return c.selfTextureId;
    final cameraRevision = c.cameraRevision;
    final existing = _selfTextureFuture;
    if (existing != null) {
      final id = await existing;
      if (!_mayInstallSelfTexture(c, cameraRevision)) {
        return null;
      }
      c.selfTextureId = id;
      notifyListeners();
      return id;
    }
    final pending = jami.createVideoTexture('self');
    _selfTextureFuture = pending;
    try {
      final id = await pending;
      if (!_mayInstallSelfTexture(c, cameraRevision)) {
        return null;
      }
      c.selfTextureId = id;
      notifyListeners();
      return id;
    } finally {
      // See the remote path above: native owns the persistent role texture; stale Dart work must not install it
      // into a call that no longer wants local video.
      if (identical(_selfTextureFuture, pending)) _selfTextureFuture = null;
    }
  }

  bool _mayInstallSelfTexture(CallSession c, int cameraRevision) =>
      identical(call, c) &&
      c.outgoingVideo.active &&
      c.cameraRevision == cameraRevision;

  void _adoptNativeOutgoingVideo(CallSession c, Map<String, dynamic> data) {
    final fallback =
        data.containsKey('outgoingVideoRevision') ||
            data.containsKey('sourceRevision') ||
            data.containsKey('sourceEpoch')
        ? c.outgoingVideo
        : c.outgoingVideo.copyWith(revision: c.outgoingVideo.revision + 1);
    final adopted = OutgoingVideoSource.fromMap(data, fallback: fallback);
    if (adopted.revision < c.outgoingVideo.revision) return;
    final changed =
        adopted.kind != c.outgoingVideo.kind ||
        adopted.uri != c.outgoingVideo.uri ||
        adopted.revision != c.outgoingVideo.revision ||
        adopted.effectiveControlRevision !=
            c.outgoingVideo.effectiveControlRevision;
    c.outgoingVideo = adopted;
    if (changed) _syncAnnotationSources(c);
  }

  void _applyNativeCallSnapshot(CallSession c, JamiEvent e) {
    final d = e.data;
    final previousPeerKind = c.peerVideoKind;
    if (d.containsKey('outgoingVideoKind') ||
        d.containsKey('sourceKind') ||
        d.containsKey('cameraOn')) {
      _adoptNativeOutgoingVideo(c, d);
    }
    if (d.containsKey('micMuted') && c.microphoneCommandsInFlight == 0) {
      c.micMuted = _asBool(d['micMuted'], c.micMuted);
      c.acknowledgedMicrophoneMuted = c.micMuted;
      if (c.micMode == MicrophoneMode.open &&
          !c.microphonePolicyApplied &&
          !c.microphoneBootstrapMuted) {
        // Open mode has no policy mute of its own, so native mute truth is a
        // manual mute that must survive call adoption/reconciliation.
        c.manuallyMuted = c.micMuted;
      }
    }
    if (d.containsKey('speakerOn')) {
      c.speakerOn = _asBool(d['speakerOn'], c.speakerOn);
    }
    if (d.containsKey('peerVideo')) {
      c.peerVideo = _asBool(d['peerVideo'], c.peerVideo);
      if (!c.peerVideo) {
        c.peerVideoKind = OutgoingVideoKind.off;
      } else if (c.peerVideoKind == OutgoingVideoKind.off) {
        // An initial video offer has no separate source-kind event. Screen
        // sharing is a mid-call transition, so the honest initial default is
        // camera until a peerVideo event says otherwise.
        c.peerVideoKind = OutgoingVideoKind.camera;
      }
    }
    if (d.containsKey('selfActive')) {
      c.selfActive = _asBool(d['selfActive'], c.selfActive);
    }
    if (d.containsKey('remoteActive')) {
      c.remoteActive = _asBool(d['remoteActive'], c.remoteActive);
    }
    if ((c.outgoingVideo.active || c.selfActive) && c.selfTextureId == null) {
      _runInBackground(
        _createSelfTexture(c),
        'createSelfTexture(adopted call)',
      );
    }
    if (c.outgoingVideo.active || c.peerVideo || c.remoteActive) {
      _ensureRemoteTexture(c);
    }
    if (previousPeerKind != c.peerVideoKind) {
      _syncAnnotationSources(c, peerSourceChanged: true);
    }
  }

  CallSession? _takePendingIncomingCall() {
    if (_pendingIncomingCalls.isEmpty) return null;
    final callId = _pendingIncomingCalls.keys.first;
    final pending = _pendingIncomingCalls.remove(callId)!;
    final promoted = CallSession(
      callId: callId,
      dir: CallDir.incoming,
      peerId: pending.peerId,
      state: 'RINGING',
      peerVideo: pending.withVideo,
    );
    _seedCallMicrophone(promoted);
    return promoted;
  }

  /// Once an admitted leg is CURRENT, glare arbitration is over. Retire every other candidate now—not on
  /// the earlier incomingCall event, where a refuse can race libjami's own accept+hangup decision and kill both
  /// legs. Native performs the same cleanup for background/frozen Dart; these call-scoped commands also close the
  /// MethodChannel race and make the reducer safe if native terminal delivery is delayed.
  void _retireGlareSiblings(String winnerCallId, CallSession? visible) {
    final incoming = <String>{..._pendingIncomingCalls.keys};
    final outgoing = <String>{..._unresolvedOutgoingCallIds};
    _pendingIncomingCalls.clear();
    _unresolvedOutgoingCallIds.clear();

    if (visible != null && visible.callId != winnerCallId) {
      (visible.dir == CallDir.incoming ? incoming : outgoing).add(
        visible.callId,
      );
    }
    incoming.remove(winnerCallId);
    outgoing.remove(winnerCallId);

    for (final id in incoming) {
      _retiredGlareCallIds[id] = CallDir.incoming;
      _runInBackground(jami.refuse(id), 'refuse(post-CURRENT glare sibling)');
    }
    for (final id in outgoing) {
      _retiredGlareCallIds[id] = CallDir.outgoing;
      _runInBackground(jami.hangUp(id), 'hangUp(post-CURRENT glare sibling)');
    }
    if (incoming.isNotEmpty || outgoing.isNotEmpty) {
      dlog(
        'glare: winner $winnerCallId; retired incoming=${incoming.join(',')} outgoing=${outgoing.join(',')}',
      );
    }
  }

  /// Only known event categories enter diagnostics. Payload length is not a
  /// privacy boundary: short strings can be names, IDs or bearer capabilities.
  void _recordEvent(JamiEvent e) {
    const categories = {
      'registrationState',
      'deviceAnnounced',
      'friendsChanged',
      'friendProfile',
      'connectRequest',
      'incomingCall',
      'callState',
      'cameraState',
      'cameraFacing',
      'outgoingVideoSource',
      'peerVideo',
      'captureActivity',
      'groupCallsChanged',
      'groupCallLegState',
      'groupConferenceChanged',
      'groupConferenceCreated',
      'groupConferenceRemoved',
      'groupNeedsHost',
      'remoteControlAccessibilityState',
      'remoteControlControllerState',
      'remoteControlHostAuthority',
      'remoteControlRequest',
      'remoteControlState',
      'remoteControlTrustRetired',
      'wakeCapability',
      'backgroundWakeReady',
      'wakeAuthorizationShrank',
      'chatRefreshRequired',
      'conversationSyncFinished',
    };
    if (categories.contains(e.type)) dlog('· ${e.type}');
  }

  void _onEvent(JamiEvent e) {
    if (resettingDoorlight ||
        resetDoorlightPending ||
        resetDoorlightRestartRequired) {
      return;
    }
    if (e.type == 'fileSeedReady') {
      final operation = _asString(e.data['operationId']);
      final commit = _asString(e.data['commitId']);
      final record = sendJournal.record(operation);
      if (record != null &&
          commit.isNotEmpty &&
          record.scope.accountId == _asString(e.data['accountId']) &&
          record.scope.peerId == _asString(e.data['peerJamiId']) &&
          record.scope.conversationId == _asString(e.data['conversationId']) &&
          _asString(e.data['fileId']).isNotEmpty) {
        _runInBackground(() async {
          await sendJournal.complete(
            operation,
            record.scope,
            ComposerSendStatus.committed,
            commitId: commit,
          );
          final confirmed = sendJournal.record(operation);
          if (confirmed?.commitId != commit) return;
          composerDrafts.reconcile(
            operation,
            ComposerSendStatus.committed,
            commitId: commit,
          );
          await _repairCommittedSeed(confirmed!);
          if (!_disposed) notifyListeners();
        }(), 'reconcileFileSeed');
      }
      return;
    }
    if (e.type == 'sendOperationCompleted') {
      final operation = _asString(e.data['operationId']);
      final record = sendJournal.record(operation);
      if (record != null &&
          record.scope.accountId == _asString(e.data['accountId']) &&
          record.scope.peerId == _asString(e.data['peerJamiId']) &&
          record.scope.conversationId == _asString(e.data['conversationId'])) {
        _runInBackground(() async {
          final changed = await sendJournal.complete(
            operation,
            record.scope,
            e.data['status'] == 'committed'
                ? ComposerSendStatus.committed
                : ComposerSendStatus.unknown,
            commitId: e.data['status'] == 'committed'
                ? _asString(e.data['commitId'])
                : null,
          );
          if (changed) {
            final outcome = sendJournal.record(operation);
            if (outcome == null) return;
            composerDrafts.reconcile(
              operation,
              outcome.status,
              commitId: outcome.commitId,
            );
            if (record.scope.accountId == accountId &&
                _widgetDraftAccountOwner == (accountId, _accountRevision) &&
                _widgetSendResults[record.scope]?.operationId == operation) {
              _widgetSendResults[record.scope] = outcome;
              if (outcome.status == ComposerSendStatus.committed ||
                  outcome.status == ComposerSendStatus.failedBeforeCommit) {
                await sendJournal.acknowledge(operation);
              }
            }
            if (!_disposed) notifyListeners();
          }
        }(), 'reconcileSendOutcome');
      }
      return; // Never activity, notification, presence or a read.
    }
    if (accountId != null &&
        e.data.containsKey('accountId') &&
        _asString(e.data['accountId']) != accountId) {
      return;
    }
    if (const {
      'groupConferenceCreated',
      'groupConferenceRemoved',
      'groupConferenceInfo',
      'groupCallLegState',
    }.contains(e.type)) {
      final current = groupCall;
      if (current == null ||
          _asString(e.data['reservationId']) != current.reservationId) {
        return;
      }
    }
    _recordEvent(e);
    _recordFriendActivity(e);
    if (_fileTransfers.handleEvent(e)) return;
    final eventId = _asString(e.data['callId']);
    if (placing &&
        e.type == 'callState' &&
        eventId.isNotEmpty &&
        _terminal.contains(_asString(e.data['state']))) {
      _terminalCallIdsDuringPlacement.add(eventId);
    }
    if (placing &&
        e.type == 'callState' &&
        eventId.isNotEmpty &&
        _asString(e.data['state']) == 'CURRENT') {
      // Native has already filtered call-state events to trusted/admitted friends. Latch before the early-event buffer:
      // CURRENT can precede IncomingCall and the placement reply on separate daemon callbacks.
      _winnerCallIdDuringPlacement ??= eventId;
    }
    final isRetiredCallEvent =
        e.type == 'callState' && _retiredGlareCallIds.containsKey(eventId);
    if (placing &&
        call == null &&
        _earlyOutgoingCallEventTypes.contains(e.type) &&
        !isRetiredCallEvent) {
      _earlyOutgoingCallEvents.add(e);
      return;
    }
    switch (e.type) {
      case 'captureActivity':
        final active = e.data['active'];
        if (!const {'obsLog', 'captureProductLog'}.contains(e.data['source']) ||
            active is! bool) {
          return;
        }
        _handleWindowsCaptureActivity(active);
        notifyListeners();
        return;
      case 'wakeCapability':
        final sender = JamiIdentity.fingerprint(
          _asString(e.data['fromJamiId']),
        );
        final handle = _asString(e.data['handle']);
        final authorized =
            sender != null &&
            (_friends.containsKey(sender) ||
                _groups.values.any(
                  (group) => group.activeMemberIds.contains(sender),
                ));
        if (authorized && _wakeCapabilities.record(sender, handle)) {
          _runInBackground(
            prefs.setString(_wakeCapabilitiesKey, _wakeCapabilities.encode()),
            'save wake capability',
          );
        }
        return;
      case 'wakeAuthorizationShrank':
        _runInBackground(
          jami.rotateBackgroundWakeCapability(expectedAccountId: accountId),
          'rotate wake capability',
        );
        return;
      case 'groupCallPresence':
        final sender = JamiIdentity.fingerprint(
          _asString(e.data['fromJamiId']),
        );
        final payload = _asString(e.data['payload']);
        if (sender == null || payload.isEmpty) return;
        for (final group in _groups.values) {
          if (!group.activeMemberIds.contains(sender)) continue;
          final voiceRooms = group.layout.rooms
              .where((room) => room.kind == GroupRoomKind.voice)
              .map((room) => room.id)
              .toSet();
          final value = GroupCallPresence.decode(
            payload,
            senderAccountId: sender,
            conversationId: group.conversationId,
            voiceRoomIds: voiceRooms,
          );
          final now = _groupCallClock.elapsedMilliseconds;
          final wasJoined =
              value != null &&
              _groupCallPresence.isJoined(
                sender,
                group.conversationId,
                value.roomId,
                nowMs: now,
              );
          if (value != null && _groupCallPresence.accept(value, now)) {
            final current = groupCall;
            final isJoined = _groupCallPresence.isJoined(
              sender,
              group.conversationId,
              value.roomId,
              nowMs: now,
            );
            if (sender != jamiId &&
                current?.conversationId == group.conversationId &&
                current?.roomId == value.roomId &&
                wasJoined != isJoined) {
              _playSound(
                isJoined ? SyblSoundEvent.userJoin : SyblSoundEvent.userLeft,
              );
            }
            _ensureGroupCallExpiryTimer();
            notifyListeners();
            return;
          }
        }
        return;
      case 'groupCallsChanged':
        final conversationId = _asString(e.data['conversationId']);
        final active = _groupCallsFromEvent(e.data);
        final current = groupCall;
        if (current != null && current.conversationId == conversationId) {
          final canonical = GroupConferenceAddress.chooseCanonical(
            active,
            roomId: current.roomId,
            excludedConferenceIds: current.failedConferenceIds,
          );
          if (current.connected &&
              canonical != null &&
              canonical.conferenceId != current.conferenceId) {
            _runInBackground(
              _joinCanonicalGroupCall(canonical),
              'joinCanonicalGroupCall',
            );
          }
        }
        notifyListeners();
        return;
      case 'groupNeedsHost':
        if (groupCall?.conversationId == _asString(e.data['conversationId'])) {
          _scheduleGroupCallRecovery();
        }
        return;
      case 'groupConferenceChanged':
        return;
      case 'groupConferenceCreated':
        final current = groupCall;
        if (current == null ||
            current.phase == GroupCallPhase.leaving ||
            current.conferenceId != _asString(e.data['conferenceId']) ||
            current.conversationId != _asString(e.data['conversationId'])) {
          return;
        }
        current.hosting = true;
        current.phase = GroupCallPhase.connected;
        _runInBackground(_completeGroupConnection(current), 'group connected');
        return;
      case 'groupCallLegState':
        final current = groupCall;
        final leg = _asString(e.data['callId']);
        if (current == null ||
            leg.isEmpty ||
            current.conferenceId != _asString(e.data['conferenceId']) ||
            (current.callId.isNotEmpty && current.callId != leg)) {
          return;
        }
        final state = _asString(e.data['state']);
        if (state == 'CURRENT' && current.phase != GroupCallPhase.leaving) {
          current.phase = GroupCallPhase.connected;
          current.callId = leg;
          _runInBackground(
            _completeGroupConnection(current),
            'group connected',
          );
          notifyListeners();
        } else if (_terminal.contains(state)) {
          if (current.phase == GroupCallPhase.leaving) {
            groupCall = null;
            notifyListeners();
          } else {
            _scheduleGroupCallRecovery();
          }
        }
        return;
      case 'groupConferenceRemoved':
        final current = groupCall;
        if (current?.conferenceId == _asString(e.data['conferenceId'])) {
          if (current!.phase == GroupCallPhase.leaving) {
            groupCall = null;
            notifyListeners();
          } else {
            _scheduleGroupCallRecovery();
          }
        }
        return;
      case 'groupConferenceInfo':
        final current = groupCall;
        if (current == null ||
            current.conferenceId != _asString(e.data['conferenceId'])) {
          return;
        }
        current.conference = _groupConferenceFromEvent(e.data);
        if (current.mediaRestorePending) {
          _runInBackground(
            _restoreGroupVideoSource(current),
            'restoreGroupVideoSource(host)',
          );
        }
        notifyListeners();
        return;
      case 'dmTopicStatePage':
        _handleDmTopicStatePage(e);
        return;
      case 'chatSnapshot':
        _timelineRepository.handleSnapshot(e);
        return;
      case 'hologramControl':
        if (_asString(e.data['accountId']) != accountId) return;
        final packet = HologramPacket.parse(_asString(e.data['payload']));
        if (packet != null) {
          _refreshHologramPrivacy();
          _runInBackground(
            _receiveHologramControl(_asString(e.data['fromJamiId']), packet),
            'hologram control',
          );
        }
        return;
      case 'chatReaction':
        final scope = _chatEventScope(e);
        final item = _chatEventItem(e);
        if (scope == null || scope.accountId != accountId || item == null) {
          return;
        }
        // No new-message effects, composer activity, unread, or read receipts.
        _applyingReactionMetadata = true;
        try {
          for (final timeline in _timelinesForScope(scope)) {
            timeline.mergeReaction(item);
          }
        } finally {
          _applyingReactionMetadata = false;
        }
        return;
      case 'chatMessage':
        final scope = _chatEventScope(e);
        final item = _chatEventItem(e);
        final admission = _admittedChatEvent(e);
        if (scope == null || item == null || admission?.isAccepted != true) {
          return;
        }
        final admitted = admission!.item;
        final fresh =
            admitted != null &&
            admitted.versionId == admitted.daemonId &&
            _messageEffectsEligible(admitted) &&
            item['operation'] != 'edit' &&
            item['deleted'] != true &&
            _liveMessageEffects.admit(scope, admitted.daemonId);
        final sticker = admitted is TimelineStickerItem
            ? admitted.sticker
            : null;
        final hologram = sticker?.presentation == StickerPresentation.hologram;
        if (fresh && admitted.direction == TimelineDirection.incoming) {
          if (hologram && !scope.isGroup) {
            _refreshHologramPrivacy();
            _runInBackground(
              _observeHologramCommit(scope, admitted as TimelineStickerItem),
              'hologram commit',
            );
          } else if (!hologram &&
              admitted is! TimelineDmTopicEventItem &&
              messageAlertsAllowed(scope)) {
            _playSound(SyblSoundEvent.notification);
          }
        }
        _mergeLiveDmTopicRecord(scope, item);
        if (!scope.isGroup && _asString(item['authorId']) == scope.peerId) {
          if (_remoteComposerActivities.remove(scope) != null) {
            notifyListeners();
          }
        }
        for (final timeline in _timelinesForScope(scope)) {
          timeline.mergeLive(item);
        }
        return;
      case 'chatRefreshRequired':
        final scope = _chatEventScope(e);
        if (scope == null) return;
        for (final timeline in _timelinesForScope(scope)) {
          if (identical(timeline, _widgetChatTimeline)) {
            _scheduleWidgetTimelineRefresh(scope);
          } else if (identical(timeline, _conversationTimeline)) {
            _scheduleTimelineRefresh(scope);
          } else {
            _runInBackground(timeline.refresh(), 'refreshChat(background)');
          }
        }
        return;
      case 'conversationSyncFinished':
        _scheduleSyncedTimelinesRefresh();
        _rescanDmTopics();
        return;
      case 'composerActivity':
        _handleRemoteComposerActivity(e);
        return;
      case 'localVoiceActivity':
        _handleLocalVoiceActivity(e);
        return;
      case 'audioMeter':
        _handleAudioMeter(e);
        return;
      case 'remoteAudioMeter':
        _handleRemoteAudioMeter(e);
        return;
      case 'stressCommand':
        // Diagnostic-only automation. Windows requires SYBL_STRESS_CONTROL=1 plus an allow-listed local
        // WM_COPYDATA command; Android requires the DUMP-protected diagnostic
        // receiver and the opt-in SybLStress log tag.
        // Both drive the same AppState methods as the visible controls without taking over the user's cursor.
        final command = _asString(e.data['command']);
        dlog('→ stressCommand($command)');
        if (command.length == 47 && command.startsWith('select:')) {
          final stressPeer = JamiIdentity.fingerprint(command.substring(7));
          if (stressPeer != null) {
            _runInBackground(selectFriend(stressPeer), 'stress select friend');
          }
          return;
        }
        if (command.length == 6 && command.startsWith('chat:')) {
          final ordinal = int.tryParse(command.substring(5));
          if (ordinal != null && ordinal >= 1 && ordinal <= 9) {
            _runInBackground(
              sendText('Syb-L reliability probe $ordinal'),
              'stress chat probe $ordinal',
            );
          }
          return;
        }
        switch (command) {
          case 'voice':
            _runInBackground(startCall(), 'stress voice');
            break;
          case 'video':
            _runInBackground(startCall(withVideo: true), 'stress video');
            break;
          case 'answer':
            final ringing = call;
            if (ringing != null) {
              _runInBackground(answer(ringing), 'stress answer');
            }
            break;
          case 'hangup':
            _runInBackground(hangUp(), 'stress hangup');
            break;
          case 'camera:on':
          case 'camera:off':
          case 'camera:flip':
          case 'screen:on':
          case 'screen:off':
            _runInBackground(
              _runStressMediaCommand(command),
              'stress media $command',
            );
            break;
          case 'control':
            _runInBackground(requestRemoteControl(), 'stress remote control');
            break;
          case 'control:home':
            remoteControl.action(RemoteGlobalAction.home);
            break;
          case 'control:move':
            remoteControl.move(.5, .5);
            break;
          case 'control:tap':
            remoteControl.move(.5, .5);
            remoteControl.click();
            break;
          case 'group:join':
          case 'group:camera':
          case 'group:leave':
          case 'group:screen:on':
          case 'group:screen:off':
            _runInBackground(
              _runStressGroupCommand(command),
              'stress $command',
            );
            break;
          case 'profile:lan':
            _runInBackground(setConnectionProfile('lan'), 'stress profile LAN');
            break;
          case 'profile:jami':
            _runInBackground(
              setConnectionProfile('jami'),
              'stress profile jami',
            );
            break;
          case 'ping':
            break;
        }
        return;
      case 'openConversation':
        final launch = ConversationLaunchTarget.tryParse(e.data);
        if (launch != null) {
          _runInBackground(
            _openConversationLaunch(launch),
            'open notification conversation',
          );
        }
        return;
      case 'registrationState':
        registration = appearOffline
            ? 'UNREGISTERED'
            : _boundedRegistration(e.data['state'], registration);
        break;
      case 'friendProfile':
        // A profile is presentation metadata, never relationship truth. Only
        // an authenticated event for the active account and the exact
        // libjami-owned friend/conversation tuple may update the in-memory
        // projection.
        final activeAccount = accountId;
        if (activeAccount == null ||
            activeAccount.isEmpty ||
            !e.data.containsKey('accountId') ||
            _asString(e.data['accountId']) != activeAccount) {
          return;
        }
        final profilePeer = _asString(e.data['peerJamiId']);
        final friend = _friends[profilePeer];
        if (friend == null ||
            !friend.confirmed ||
            friend.conversationId.isEmpty ||
            _asString(e.data['conversationId']) != friend.conversationId) {
          return;
        }
        final title = ProfileWireContract.decodeDisplayName(
          e.data['displayName'],
        );
        final avatar = e.data.containsKey('avatarBase64')
            ? ProfileWireContract.decodeAvatar(e.data['avatarBase64'])
            : friend.avatarBase64;
        if (title == null || avatar == null) return;
        if (title.isNotEmpty) _nameHints.remove(profilePeer);
        _friends[profilePeer] = friend.copyWith(
          displayName: title,
          avatarBase64: avatar,
        );
        break;
      case 'friendsChanged':
        _runInBackground(
          _refreshFriendsFromDaemon().then((_) {
            // ConversationReady can be the moment libjami publishes a previously empty canonical conversation.
            // Folder loading must originate here so Dart knows the returned load ID; a native fire-and-forget load
            // would emit an intentionally uncorrelated snapshot that this state machine must drop.
            loadFolder();
            notifyListeners();
          }),
          'refreshFriends(event)',
        );
        return;
      case 'remoteControlTrustRetired':
        final eventAccount = e.data['accountId'];
        final eventPeer = e.data['peerJamiId'];
        final grantsRemoved = e.data['grantsRemoved'];
        final releaseComplete = e.data['releaseComplete'];
        if (eventAccount is! String ||
            eventAccount.isEmpty ||
            eventAccount != accountId ||
            eventPeer is! String ||
            JamiIdentity.fingerprint(eventPeer) != eventPeer ||
            grantsRemoved is! bool ||
            releaseComplete is! bool ||
            (!_friends.containsKey(eventPeer) && call?.peerId != eventPeer)) {
          return;
        }
        final owner = (accountId, _accountRevision);
        final originalCall = call;
        _runInBackground(() async {
          try {
            // This event has no consent generation. Reconcile current trust;
            // identity-bound native host/controller events retire exact grants.
            await _refreshFriendsFromDaemon();
          } catch (error) {
            dlog('refresh trust after native retirement failed: $error');
          }
          if (_disposed ||
              owner != (accountId, _accountRevision) ||
              !identical(call, originalCall)) {
            return;
          }
          if ((!grantsRemoved || !releaseComplete) &&
              call?.peerId == eventPeer) {
            _controlTrustWarning = (
              account: owner,
              peerId: eventPeer,
              message: !releaseComplete
                  ? 'A previous remote-control release could not be confirmed.'
                  : 'Saved remote-control access could not be removed.',
            );
            notifyListeners();
          }
        }(), 'reconcile native trust retirement');
        return;
      case 'presence':
        if (appearOffline) break;
        // Daemon tri-state (0=DISCONNECTED, 1=AVAILABLE, 2=CONNECTED). 2 = a live authenticated P2P channel to
        // the peer right now → evidence (any pending probe verdict is moot). 0 = a fresh negative (announcement
        // expired / last channel closed with nothing on the DHT) → unreachable. 1 = only "a DHT announcement
        // record exists" — proxy-held for ~24 h after the peer dies and replayed on every (re)subscribe, so
        // NEVER trusted as online; it triggers a probe (also how a live 2→1 channel-drop gets re-verified
        // within seconds, while the app is watching). The dot doesn't move on 1 until a verdict lands.
        final presencePeer = _asString(e.data['peerJamiId']);
        if (!_friends.containsKey(presencePeer)) break;
        final pst = _asInt(e.data['status']);
        if (pst >= 2) {
          _friendPresenceEvidence(presencePeer);
        } else if (pst == 0) {
          _setFriendPresence(presencePeer, PeerPresence.unreachable);
        } else {
          // Each friend owns an independent hint cooldown and probe. A 2→1 channel idle-close cannot make one
          // row suppress verification of another.
          _presence.hint(presencePeer);
        }
        break;
      case 'presenceMsg':
        // An authenticated x-sybl-presence message from the peer — a ping (their probe/announce;
        // our native side already ponged it) or a pong (the answer to ours). Either is END-TO-END liveness
        // (their daemon AND native bridge just spoke), and the fg flag picks in-app vs reachable.
        final presenceSender = _asString(e.data['fromJamiId']);
        if (appearOffline || !_friends.containsKey(presenceSender)) break;
        final version = _asInt(e.data['v']);
        final type = _asString(e.data['t']);
        final foreground = _asInt(e.data['fg'], -1);
        final timestamp = _asInt(e.data['ts'], -1);
        final platform = PresenceWireContract.decodePlatform(
          e.data['platform'],
        );
        final activity = PresenceWireContract.decodeActivity(
          e.data['activity'],
        );
        final colorValue = PresenceWireContract.decodeIdentityColor(
          e.data['color'],
        );
        final identityColor = IdentityColor.tryParse(colorValue);
        final validEnvelope =
            (type == 'ping' || type == 'pong') &&
            (foreground == 0 || foreground == 1) &&
            timestamp > 0 &&
            platform.isNotEmpty;
        final current =
            (version == 3 || version == 2) &&
            validEnvelope &&
            identityColor != null;
        final strict = version == 1 && validEnvelope;
        final legacy = version == 0 && validEnvelope;
        if (!current && !strict && !legacy) break;
        _friendPresenceEvidence(
          presenceSender,
          fg: foreground,
          ts: timestamp,
          platform: platform,
          activity: activity,
          identityColor: identityColor,
        );
        break;
      case 'inviteLink':
        _stageInvite(e.data['link']);
        break;
      case 'messageStatus':
        final statusConversation = _asString(e.data['conversationId']);
        if (statusConversation.isNotEmpty) {
          final statusAccount = _asString(e.data['accountId']);
          final messageId = _asString(e.data['messageId']);
          final wireState = _asInt(e.data['state']);
          final statusPeer = _asString(e.data['peerJamiId']);
          _noteRemovalNoticeStatus(
            statusAccount,
            statusConversation,
            messageId,
            statusPeer,
            wireState,
          );
          for (final scope in _timelineScopesForConversation(
            statusAccount,
            statusConversation,
          )) {
            for (final timeline in _timelinesForScope(scope)) {
              timeline.updateDelivery(
                messageId,
                wireState,
                memberId: statusPeer,
              );
            }
          }
          return;
        }
        // Delivery status of our presence ping. FAILURE (4) = the daemon's terminal give-up → unreachable.
        // DISPLAYED (3) = a true peer-side ack (rare for account messages — the pong usually lands first).
        // SENT (2) is DELIBERATELY ignored: it's a LOCAL socket-write success (daemon message_engine.cpp)
        // that "succeeds" into a zombie channel — trusting it was the audited false-green bug.
        if (appearOffline) return;
        final statusPeer = _asString(e.data['peerJamiId']);
        final mid = _asString(e.data['messageId']);
        _presence.handleMessageStatus(statusPeer, mid, _asInt(e.data['state']));
        return; // handled + notified via the helpers above; skip the trailing global notify
      case 'connectRequest':
        // Jami auto-clones trusted one-to-one requests before this callback. A request that still reaches us is
        // either a new friend or a group invitation, including one sent by an existing friend: always ask.
        final cid = GroupWireContract.decodeConversationId(
          e.data['conversationId'],
        );
        final from = JamiIdentity.fingerprint(_asString(e.data['fromJamiId']));
        if (cid == null || from == null) break;
        if (_handledConnects.contains(cid)) {
          break; // already allowed/ignored — ignore a native replay (no ghost card)
        }
        final isGroup = _asBool(e.data['isGroup']);
        if (!isGroup) _rememberNameHint(from, friendNameHint(e.data['name']));
        if (_pendingConnects.length < _maxPendingConnects &&
            !_pendingConnects.any((p) => p.convId == cid)) {
          _pendingConnects.add((
            convId: cid,
            fromJamiId: from,
            isGroup: isGroup,
          )); // dedup: replay-on-attach can re-emit the same one
        }
        break;
      case 'incomingCall':
        final incomingId = _asString(e.data['callId']);
        if (incomingId.isEmpty) break;
        if (groupCall != null) {
          _runInBackground(
            jami.refuse(incomingId),
            'refuse(direct call while in group voice)',
          );
          break;
        }
        final retiredDirection = _retiredGlareCallIds[incomingId];
        if (retiredDirection != null) {
          final end = retiredDirection == CallDir.incoming
              ? jami.refuse(incomingId)
              : jami.hangUp(incomingId);
          _runInBackground(end, 'end(replayed retired glare sibling)');
          break;
        }
        final incomingPeer = _asString(e.data['fromJamiId']);
        if (appearOffline ||
            !_friends.containsKey(incomingPeer) ||
            _directPeerClosed(incomingPeer)) {
          _runInBackground(
            jami.refuse(incomingId),
            'refuse(disabled/untrusted peer)',
          );
          break;
        }
        final established =
            _establishedCallId ??
            (placing ? _winnerCallIdDuringPlacement : null);
        if (established != null) {
          if (established != incomingId) {
            // Unlike simultaneous pre-CURRENT glare, a new ring after CURRENT is safe to refuse immediately. Keep a
            // tombstone until terminal so a racing CURRENT cannot replace the established call or resurrect later.
            _retiredGlareCallIds[incomingId] = CallDir.incoming;
            _runInBackground(
              jami.refuse(incomingId),
              'refuse(post-CURRENT incoming sibling)',
            );
            _presenceEvidence();
          }
          break;
        }
        // The product renders exactly ONE call, but refusing a second one is the DAEMON's job, not ours
        // (`Account.denySecondCall`, manager.cpp) — and hand-refusing here is what broke simultaneous calls:
        // our refuse landed ~185 ms before the daemon's own arbitration, so `Manager::acceptCall` early-returned
        // on the leg it was about to answer while its unconditional `hangupCall` still killed ours, and both
        // calls died. We issue no command yet. If a pre-CURRENT leg is already visible, retain this ring only long
        // enough to surface it if the displayed leg dies; a CURRENT winner triggers retrospective sibling cleanup.
        final visible = call;
        final withVideo = _asBool(e.data['withVideo']);
        if (visible == null) {
          final incoming = CallSession(
            callId: incomingId,
            dir: CallDir.incoming,
            peerId: incomingPeer,
            state: 'RINGING',
            peerVideo: withVideo,
          );
          _seedCallMicrophone(incoming);
          call = incoming;
          _playSound(SyblSoundEvent.incomingRing);
        } else if (visible.callId != incomingId && !visible.everConnected) {
          _pendingIncomingCalls[incomingId] = (
            peerId: incomingPeer,
            withVideo: withVideo,
          );
        }
        // A ringing peer is transport-verified alive — free presence truth (they may ring before a probe lands).
        // Also supersedes any pending probe verdict (mirrors the status-2 branch): without the cancel, the ring
        // itself keeps the daemon busy, the probe's window can lapse mid-ring, and the dot would flip grey
        // seconds after the peer provably rang us. (Also parks the sweep — refreshPresence skips in-call.)
        _friendPresenceEvidence(incomingPeer);
        _syncPresenceRuntime();
        break;
      case 'callState':
        final c = call;
        final eventCallId = _asString(e.data['callId']);
        final eventState = _asString(e.data['state']);
        final retiredDirection = _retiredGlareCallIds[eventCallId];
        if (retiredDirection != null) {
          _pendingIncomingCalls.remove(eventCallId);
          _unresolvedOutgoingCallIds.remove(eventCallId);
          if (_terminal.contains(eventState)) {
            _retiredGlareCallIds.remove(eventCallId);
          } else if (eventState == 'CURRENT') {
            // A ringing incoming loser is refused initially, but once it races to CURRENT only hangUp is valid.
            _runInBackground(
              jami.hangUp(eventCallId),
              'hangUp(late-CURRENT retired glare sibling)',
            );
          }
          break;
        }
        if (_terminal.contains(eventState) && eventCallId.isNotEmpty) {
          _pendingIncomingCalls.remove(eventCallId);
          _unresolvedOutgoingCallIds.remove(eventCallId);
          if (_establishedCallId == eventCallId) _establishedCallId = null;
        }
        final eventPeer = _asString(e.data['fromJamiId']);
        final configuredPeerCurrent =
            eventState == 'CURRENT' &&
            eventCallId.isNotEmpty &&
            (_friends.containsKey(eventPeer) ||
                (c?.callId == eventCallId && _friends.containsKey(c?.peerId)));
        if (configuredPeerCurrent) {
          final established =
              _establishedCallId ??
              (placing ? _winnerCallIdDuringPlacement : null);
          if (established != null && established != eventCallId) {
            // Native also serializes winner selection; Dart keeps the first
            // admitted CURRENT authoritative. At CURRENT, hangUp is valid
            // regardless of the call's original direction.
            final wasOutgoing = _unresolvedOutgoingCallIds.remove(eventCallId);
            _pendingIncomingCalls.remove(eventCallId);
            _retiredGlareCallIds[eventCallId] = wasOutgoing
                ? CallDir.outgoing
                : CallDir.incoming;
            _runInBackground(
              jami.hangUp(eventCallId),
              'hangUp(second CURRENT glare loser)',
            );
            dlog(
              'glare: ignored second CURRENT $eventCallId; established winner is $established',
            );
            break;
          }
          _establishedCallId ??= eventCallId;
          _retireGlareSiblings(eventCallId, c);
        }
        // On glare the daemon can answer the crossed incoming leg itself. Native binds every state to its daemon-
        // reported peer and snapshots actual media/control state; only that admitted leg may replace the UI.
        if (eventState == 'CURRENT' &&
            eventCallId.isNotEmpty &&
            _friends.containsKey(eventPeer) &&
            (c == null || c.callId != eventCallId)) {
          final preserveMicrophoneControls = c != null && c.peerId == eventPeer;
          final adopted = CallSession(
            callId: eventCallId,
            dir: CallDir.incoming,
            peerId: eventPeer,
            state: 'CURRENT',
            micMuted: preserveMicrophoneControls ? c.micMuted : false,
            speakerOn: c?.speakerOn ?? false,
            micMode: preserveMicrophoneControls
                ? c.micMode
                : MicrophoneMode.open,
            manuallyMuted: preserveMicrophoneControls && c.manuallyMuted,
            pushToTalkPressed: false,
            microphoneBootstrapMuted:
                preserveMicrophoneControls && c.microphoneBootstrapMuted,
            selfTextureId: c?.selfTextureId,
            remoteTextureId: c?.remoteTextureId,
            outgoingVideo: c?.outgoingVideo ?? const OutgoingVideoSource.off(),
            sourceChanging: false,
            selfActive: c?.selfActive ?? false,
            remoteActive: c?.remoteActive ?? false,
            peerVideo: c?.peerVideo ?? false,
            selfFront: c?.selfFront ?? true,
            selfWidth: c?.selfWidth ?? 0,
            selfHeight: c?.selfHeight ?? 0,
            remoteWidth: c?.remoteWidth ?? 0,
            remoteHeight: c?.remoteHeight ?? 0,
            peerVideoKind: c?.peerVideoKind ?? OutgoingVideoKind.off,
            everConnected: true,
          );
          adopted.nativeAccountRevision = _nativeAccountRevision(e);
          if (!preserveMicrophoneControls) {
            _seedCallMicrophone(adopted);
          }
          call = adopted;
          _playSound(SyblSoundEvent.stopRinging);
          _playSound(SyblSoundEvent.callConnected);
          callEndedNote = null;
          annotation.reset();
          _applyNativeCallSnapshot(adopted, e);
          _syncAnnotationSources(adopted);
          _syncPresenceRuntime();
          _runInBackground(
            _configureMicrophoneRuntime(adopted),
            'configureMicrophone(adopted)',
          );
          break;
        }
        if (c != null && c.callId == e.data['callId']) {
          c.state = eventState.isEmpty ? c.state : eventState;
          if (c.state == 'CURRENT') {
            final nativeRevision = _nativeAccountRevision(e);
            if (nativeRevision != null &&
                c.nativeAccountRevision != nativeRevision) {
              c.clearRemoteVoiceActivity();
              c.nativeAccountRevision = nativeRevision;
            }
            final becameCurrent = !c.everConnected;
            c.everConnected = true;
            if (becameCurrent) {
              _playSound(SyblSoundEvent.stopRinging);
              _playSound(SyblSoundEvent.callConnected);
            }
            _applyNativeCallSnapshot(c, e);
            _syncAnnotationSources(c);
            _runInBackground(
              becameCurrent || !c.microphonePolicyApplied
                  ? _configureMicrophoneRuntime(c)
                  : _applyMicrophoneProjection(c),
              becameCurrent || !c.microphonePolicyApplied
                  ? 'configureMicrophone(CURRENT)'
                  : 'reconcileMicrophone(CURRENT)',
            );
          }
          if (_terminal.contains(c.state)) {
            // An honest note only when an outgoing call never connected (cold-start / unreachable peer).
            // A call that HAD connected ending = a normal hangup → no message. ??= so the first terminal
            // (e.g. FAILURE/PEER_BUSY) wins over a trailing OVER.
            final promoted = _takePendingIncomingCall();
            c.clearRemoteVoiceActivity();
            _runInBackground(
              _retireMicrophoneRuntime(),
              'retireMicrophone(call ended)',
            );
            if (promoted == null) {
              callEndedNote ??= c.everConnected || c.dir == CallDir.incoming
                  ? null
                  : _failNote(c.state);
              call = null;
              if (!c.everConnected) _playSound(SyblSoundEvent.stopRinging);
              _playSound(SyblSoundEvent.callEnded);
            } else {
              call = promoted;
              callEndedNote = null;
              _playSound(SyblSoundEvent.incomingRing);
            }
            annotation
                .reset(); // drop the call-scoped draw overlay (nothing is ever persisted)
            // The dot was parked while in-call (refreshPresence + the sweep skip during calls) — re-verify now
            // so the home screen resumes with truth (e.g. the peer hung up because they're closing for the
            // night). Presence runtime restarts that friend's in-app cadence if the verdict lands green.
            _syncPresenceRuntime();
            if (promoted == null) {
              _runInBackground(
                _presence.refresh(c.peerId),
                'refreshPresence(call ended)',
              );
            }
          }
        }
        break;
      case 'deviceAnnounced':
        // The Windows bridge starts with map<string,string> but its channel adapter converts allow-listed Boolean
        // keys; Dart still accepts both typed and string values to tolerate schema drift and older bridges.
        ready =
            !appearOffline &&
            (e.data['announced'] == true || e.data['announced'] == 'true');
        break;
      case 'cameraFacing':
        // Native tells us which way our camera faces so the self-view PiP mirrors only the front camera.
        final c = call;
        if (c != null &&
            (_asString(e.data['callId']).isEmpty ||
                _asString(e.data['callId']) == c.callId)) {
          c.selfFront = _asBool(e.data['front'], c.selfFront);
        }
        break;
      case 'cameraState':
      case 'outgoingVideoSource':
        final group = groupCall;
        if (group != null &&
            group.conferenceId == _asString(e.data['callId'])) {
          final kind = OutgoingVideoKind.parse(
            e.data['outgoingVideoKind'] ??
                (_asBool(e.data['cameraOn']) ? 'camera' : 'off'),
          );
          group.video = kind == OutgoingVideoKind.camera;
          group.screenShare = kind == OutgoingVideoKind.screen;
          group.sourceChanging = false;
          _runInBackground(
            _publishGroupCallPresence(),
            'publishGroupCallPresence(video)',
          );
          break;
        }
        final c = call;
        if (c != null && c.callId == _asString(e.data['callId'])) {
          _adoptNativeOutgoingVideo(c, e.data);
          if (c.outgoingVideo.active) {
            if (c.selfTextureId == null) {
              _runInBackground(
                _createSelfTexture(c),
                'createSelfTexture(source state)',
              );
            }
            _ensureRemoteTexture(c);
          }
        }
        break;
      case 'video':
        // a decoded sink started/stopped: role = self | remote
        final group = groupCall;
        if (group != null &&
            group.conferenceId == _asString(e.data['callId']) &&
            e.data['role'] == 'remote') {
          group.videoActive = _asBool(e.data['active']);
          group.videoWidth = _asInt(e.data['width'], group.videoWidth);
          group.videoHeight = _asInt(e.data['height'], group.videoHeight);
          if (group.videoActive) _ensureGroupVideoTexture(group);
          break;
        }
        final c = call;
        if (c != null &&
            (_asString(e.data['callId']).isEmpty ||
                _asString(e.data['callId']) == c.callId)) {
          final active = _asBool(e.data['active']);
          if (e.data['role'] == 'self') {
            c.selfActive = active;
            c.selfWidth = _asInt(e.data['width'], c.selfWidth);
            c.selfHeight = _asInt(e.data['height'], c.selfHeight);
          } else {
            c.remoteActive = active;
            c.remoteWidth = _asInt(e.data['width'], c.remoteWidth);
            c.remoteHeight = _asInt(e.data['height'], c.remoteHeight);
            if (active) {
              _ensureRemoteTexture(c);
              annotation.ensurePeerSourceDiscovery();
            }
            _syncRemoteControl();
          }
        }
        break;
      case 'peerVideo':
        final c = call;
        if (c != null && c.callId == e.data['callId']) {
          final previousKind = c.peerVideoKind;
          c.peerVideo = _asBool(e.data['on'], c.peerVideo);
          c.peerVideoKind = c.peerVideo
              ? OutgoingVideoKind.parse(
                  e.data['sourceKind'] ?? OutgoingVideoKind.camera.name,
                )
              : OutgoingVideoKind.off;
          if (previousKind != c.peerVideoKind) {
            _syncAnnotationSources(c, peerSourceChanged: true);
          }
          if (c.peerVideo) _ensureRemoteTexture(c);
        }
        break;
      case 'remoteControlControllerState':
        remoteControl.applyNativeControllerState(e.data);
        return;
      case 'remoteControlRequest':
        remoteControl.applyNativeHostRequest(e.data);
        return;
      case 'remoteControlState':
        remoteControl.applyNativeHostState(e.data);
        return;
      case 'remoteControlHostAuthority':
        remoteControl.applyNativeHostAuthority(e.data);
        return;
      case 'remoteControlAccessibilityState':
        remoteControlAccessibilityEnabled = _asBool(e.data['enabled']);
        notifyListeners();
        return;
      case 'remoteClipboardRequest':
        remoteControl.applyNativeClipboardRequest(e.data, forController: false);
        return;
      case 'remoteClipboardControllerRequest':
        remoteControl.applyNativeClipboardRequest(e.data, forController: true);
        return;
      case 'remoteClipboardControllerResult':
        remoteControl.applyNativeClipboardResult(e.data, fromHost: false);
        return;
      case 'remoteClipboardHostResult':
        remoteControl.applyNativeClipboardResult(e.data, fromHost: true);
        return;
      case 'remoteClipboardResult':
        remoteControl.applyNativeClipboardApplyResult(e.data);
        return;
      case 'callMessage':
        // M8: an in-call side-channel message from the peer — the annotation draw protocol (custom-MIME JSON,
        // ephemeral). Gate on the ACTIVE call's id (a late message from a just-ended call must not draw on a new
        // one), on the daemon-supplied sender matching THAT call's peer (P3-A1 — fail-closed: a connected call
        // always has a non-empty peerId, so drop rather than accept-any if it's empty), and on the call being
        // CONNECTED (P3-A4 — mirrors the sender gate; the daemon's subcall buffering already prevents pre-CURRENT
        // delivery). NOTE: the call transport is cert-authenticated + contact-gated, but on an INCOMING call the
        // daemon's `from` is the SIP From-header id, not cert-derived (daemon sipvoiplink.cpp:245 / jamiaccount.cpp:412
        // — cert==from is enforced only on the out-of-call DHT path at :3942). That is sufficient only for the
        // harmless annotation channel. Control additionally requires the daemon-patched certificate-derived
        // account and device identities and drops the packet if either binding is absent or does not match the
        // admitted call peer (docs/ARCHITECTURE.md, remote control and receiver authority). Then apply via the
        // controller's own repaint path and RETURN — skip the trailing global notifyListeners so a peer drawing
        // at ~25 Hz doesn't rebuild the whole call screen (the overlay repaints itself).
        final c = call;
        final from = _asString(e.data['fromJamiId']);
        final channel = _asString(e.data['channel'], 'annotation');
        if (c != null &&
            c.connected &&
            c.peerId.isNotEmpty &&
            c.callId == _asString(e.data['callId']) &&
            from == c.peerId) {
          if (channel == 'control') {
            final authenticated = _asString(
              e.data['authenticatedPeerAccountId'],
            );
            final device = _asString(e.data['authenticatedPeerDeviceId']);
            if (authenticated == c.peerId && device.isNotEmpty) {
              remoteControl.applyControlleePacket(
                callId: c.callId,
                peerId: authenticated,
                peerDeviceId: device,
                payload: _asString(e.data['payload']),
              );
            }
          } else if (channel == 'annotation') {
            annotation.applyInbound(_asString(e.data['payload']));
            _syncRemoteControl();
          }
        }
        return;
    }
    _syncRemoteControl();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _retireWidgetChatSession();
    call?.clearRemoteVoiceActivity();
    retireHistorySearch();
    surfaceProtection.dispose();
    removeListener(_syncNearby);
    _notReadyRetry?.cancel();
    unawaited(_nearbySonar?.cancel());
    unawaited(_nearbyCombat?.cancel());
    _nearby?.dispose();
    _devicePairing?.removeListener(notifyListeners);
    _devicePairing?.dispose();
    _historySearch?.dispose();
    _searchMessageSelection?.dispose();
    _runInBackground(_retireMicrophoneRuntime(), 'retireMicrophone(dispose)');
    inviteContinuation.dispose();
    _retireHistoryTimeline();
    _retireSelectedTimeline();
    _retireDmTopicRuntime();
    _timelineRepository.dispose();
    _disposed = true;
    _presenceColorCache.dispose();
    _friendRemovalOperations.clear();
    WidgetsBinding.instance.removeObserver(this);
    _presence.dispose();
    _sub?.cancel();
    _retireLocalComposerActivity();
    _remoteComposerActivities.clear();
    _fileTransfers.removeListener(_onFileTransfersChanged);
    _fileTransfers.dispose();
    _earlyOutgoingCallEvents.clear();
    _terminalCallIdsDuringPlacement.clear();
    _winnerCallIdDuringPlacement = null;
    _pendingIncomingCalls.clear();
    _unresolvedOutgoingCallIds.clear();
    _retiredGlareCallIds.clear();
    _establishedCallId = null;
    _groupCallPresenceTimer?.cancel();
    _groupCallExpiryTimer?.cancel();
    _groupCallRecoveryTimer?.cancel();
    _groupCallPresenceTimer = null;
    _groupCallExpiryTimer = null;
    _groupCallRecoveryTimer = null;
    remoteControl.removeListener(_onRemoteControlChanged);
    remoteControl.dispose();
    voiceMeter.dispose();
    _hologramNativeHeartbeat?.cancel();
    if (_isWindowsPlatform) {
      _runInBackground(
        jami.setHologramPrivacy('', ++_hologramNativeGeneration, false),
        'hologram shutdown',
      );
    }
    _hologramTimer?.cancel();
    _holograms.invalidate();
    _annotationOverlayTimer?.cancel();
    _annotationOverlayTimer = null;
    _annotationOverlayMayBeActive = false;
    annotation.removeListener(_onAnnotationChanged);
    annotation.repaint.removeListener(_scheduleAnnotationOverlay);
    if (Platform.isAndroid || Platform.isWindows) {
      _runInBackground(
        jami.setAnnotationOverlay(const <String, Object?>{'active': false}),
        'setAnnotationOverlay(dispose)',
      );
    }
    annotation.dispose();
    unawaited(_soundEvents.close());
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      _refreshHologramPrivacy();
      super.notifyListeners();
    }
  }
}

bool? _strictBoolValue(Object? value) => switch (value) {
  true || 'true' => true,
  false || 'false' => false,
  _ => null,
};

enum CallInteractionMode { point, draw, requestingControl, control }
