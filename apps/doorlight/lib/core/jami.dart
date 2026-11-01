import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'image_bounds.dart';
import '../state/outgoing_video.dart';
import '../state/group_calls.dart';
import '../state/conversation_scope.dart';
import '../state/conversation_search.dart';
import '../state/search_message_selection.dart';
import 'jami_identity.dart';
import 'wake_relay.dart';

/// A single typed event coming up from the daemon. The canonical list of types is the switch in
/// `AppState._onEvent` — don't enumerate it here, it drifts.
class JamiEvent {
  final String type;
  final Map<String, dynamic> data;
  JamiEvent(this.type, this.data);
}

/// Applied Windows host authority. Missing or malformed data is unknown, never
/// proof that native input has stopped.
final class RemoteControlHostAuthority {
  const RemoteControlHostAuthority({
    required this.channelEpoch,
    required this.surfaceRevision,
    required this.hostGeneration,
    required this.revokedThrough,
    required this.blocked,
    required this.releaseComplete,
    required this.state,
  });

  final int channelEpoch;
  final int surfaceRevision;
  final int hostGeneration;
  final int revokedThrough;
  final bool blocked;
  final bool releaseComplete;
  final String state;

  bool get revoked => state == 'inactive' && releaseComplete;

  static RemoteControlHostAuthority? tryParse(Object? value) {
    if (value is! Map) return null;
    final epoch = value['channelEpoch'];
    final revision = value['surfaceRevision'];
    final generation = value['hostGeneration'];
    final retired = value['revokedThrough'];
    final blocked = value['blocked'];
    final released = value['releaseComplete'];
    final state = value['state'];
    if (epoch is! int ||
        epoch <= 0 ||
        revision is! int ||
        revision < 0 ||
        generation is! int ||
        generation < 0 ||
        retired is! int ||
        retired < 0 ||
        blocked is! bool ||
        released is! bool ||
        !const {'inactive', 'active', 'revoking'}.contains(state)) {
      return null;
    }
    return RemoteControlHostAuthority(
      channelEpoch: epoch,
      surfaceRevision: revision,
      hostGeneration: generation,
      revokedThrough: retired,
      blocked: blocked,
      releaseComplete: released,
      state: state as String,
    );
  }
}

final class ConversationLaunchTarget {
  const ConversationLaunchTarget({
    required this.ownerKey,
    required this.conversationId,
    this.topicId,
    this.startCall = false,
    this.accountId,
    this.actionToken,
  });

  final String ownerKey;
  final String conversationId;
  final String? topicId;
  final bool startCall;
  final String? accountId;
  final String? actionToken;

  static ConversationLaunchTarget? tryParse(Object? value) {
    final map = _stringKeyedMap(value);
    final owner = map['ownerKey'];
    final conversation = map['conversationId'];
    final topic = map['topicId'];
    final startCall = map['startCall'];
    final account = map['accountId'];
    final token = map['actionToken'];
    if (owner is! String ||
        conversation is! String ||
        conversation.isEmpty ||
        conversation.length > 1024 ||
        (topic != null &&
            (topic is! String ||
                topic.isEmpty ||
                topic.length > 64 ||
                topic.runes.any((unit) => unit < 0x21 || unit > 0x7e))) ||
        (startCall != null && startCall is! bool) ||
        (account != null &&
            (account is! String || account.isEmpty || account.length > 128)) ||
        (token != null &&
            (token is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(token))) ||
        ((token == null) != (account == null))) {
      return null;
    }
    final direct = JamiIdentity.fingerprint(owner);
    if (direct == null && owner != 'group:$conversation') return null;
    return ConversationLaunchTarget(
      ownerKey: direct ?? owner,
      conversationId: conversation,
      topicId: topic as String?,
      startCall: startCall == true,
      accountId: account as String?,
      actionToken: token as String?,
    );
  }
}

/// Ephemeral direct-message composer activity. It is projected from
/// libjami's conversation-scoped composing protocol and never enters history.
enum ComposerActivityKind {
  typing,
  idle;

  static ComposerActivityKind? fromWire(Object? value) => switch (value) {
    'typing' => typing,
    'idle' => idle,
    _ => null,
  };
}

/// Modes understood by libjami's call-scoped audio sender.
///
/// Push-to-talk deliberately maps to [open]: its press/release behavior uses
/// libjami's independent explicit media-mute control, while voice activation is
/// enforced inside the daemon after its existing WebRTC/Speex processing.
enum AudioTransmissionMode { open, voiceActivated }

/// Effective protection applied to Doorlight's own top-level window.
///
/// `monitor` is intentionally distinct from exclusion: Windows'
/// `WDA_MONITOR` fallback obscures some capture paths but cannot honestly be
/// described as absent from every screenshot or screen-sharing implementation.
/// `none` is the intentional WDA_NONE state (the window is capturable);
/// `unavailable` means protection could not be established or confirmed.
/// An unknown wire value maps conservatively to `unavailable` — never to a
/// protected state.
enum WindowCaptureProtectionStatus {
  none,
  exclude,
  monitor,
  unavailable;

  static WindowCaptureProtectionStatus fromWire(Object? value) =>
      switch (value) {
        'none' => WindowCaptureProtectionStatus.none,
        'exclude' => WindowCaptureProtectionStatus.exclude,
        'monitor' => WindowCaptureProtectionStatus.monitor,
        _ => WindowCaptureProtectionStatus.unavailable,
      };

  /// True only for the states that honestly count as applied protection.
  bool get isProtected =>
      this == WindowCaptureProtectionStatus.exclude ||
      this == WindowCaptureProtectionStatus.monitor;
}

/// The native outcome of placing a call. [cameraOn] describes the video INTENT actually offered in the INVITE —
/// not merely what Dart requested (native places audio-only after permission denial, no device, or an unconfirmed
/// daemon default), and not yet live capture: Camera2 opens asynchronously on the daemon's StartCapture, and a
/// later capture failure reconciles through the `cameraState` event.
class CallPlacement {
  final String callId;
  final OutgoingVideoSource outgoingVideo;
  const CallPlacement(
    this.callId, {
    bool cameraOn = false,
    OutgoingVideoSource? outgoingVideo,
  }) : outgoingVideo =
           outgoingVideo ??
           (cameraOn
               ? const OutgoingVideoSource(kind: OutgoingVideoKind.camera)
               : const OutgoingVideoSource.off());

  bool get cameraOn => outgoingVideo.isCamera;
}

class JamiFriend {
  final String peerJamiId;
  final bool confirmed;
  final String conversationId;
  final String displayName;
  final String avatarBase64;
  const JamiFriend({
    required this.peerJamiId,
    required this.confirmed,
    required this.conversationId,
    this.displayName = '',
    this.avatarBase64 = '',
  });
}

class JamiFriendList {
  final int revision;
  final List<JamiFriend> friends;
  final List<JamiGroup> groups;
  const JamiFriendList(this.revision, this.friends, [this.groups = const []]);
}

enum JamiGroupMemberRole { admin, member, invited, unknown }

class JamiGroupMember {
  final String peerJamiId;
  final JamiGroupMemberRole role;
  final String displayName;
  final String avatarBase64;
  const JamiGroupMember({
    required this.peerJamiId,
    required this.role,
    this.displayName = '',
    this.avatarBase64 = '',
  });
}

class JamiGroup {
  final String conversationId;
  final String title;
  final String description;
  final int memberCount;
  final bool canManageMembers;
  final JamiGroupMemberRole localRole;
  final List<JamiGroupMember> members;
  const JamiGroup({
    required this.conversationId,
    required this.title,
    this.description = '',
    required this.memberCount,
    required this.canManageMembers,
    this.localRole = JamiGroupMemberRole.member,
    required this.members,
  });
}

abstract final class GroupWireContract {
  static const int maxGroups = 128;
  static const int maxMembers = 64;
  static const int maxConversationIdUtf8Bytes = 256;
  static const int maxDescriptionUtf8Bytes = 8192;
  static final RegExp _peerId = RegExp(r'^[0-9a-f]{40}$');

  static String? decodeConversationId(Object? value) {
    if (value is! String || value.isEmpty) return null;
    if (value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return utf8.encode(value).length <= maxConversationIdUtf8Bytes
        ? value
        : null;
  }

  static String decodeDescription(Object? value) {
    if (value is! String ||
        utf8.encode(value).length > maxDescriptionUtf8Bytes ||
        value.runes.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return '';
    }
    return value;
  }

  static String? decodePeerId(Object? value) =>
      value is String && _peerId.hasMatch(value) ? value : null;
}

class JamiKnownDevice {
  const JamiKnownDevice({
    required this.id,
    required this.name,
    required this.current,
  });

  final String id;
  final String name;
  final bool current;
}

/// Final native outcome for one exact account/device request. Only [revoked]
/// confirms revocation; timeout and unavailable can still complete later.
enum JamiDeviceRevocationStatus {
  revoked,
  credentials,
  network,
  timeout,
  pending,
  refused,
  accountChanged,
  unavailable;

  static JamiDeviceRevocationStatus fromWire(Object? value) => switch (value) {
    'revoked' => revoked,
    'credentials' => credentials,
    'network' => network,
    'timeout' => timeout,
    'pending' => pending,
    'refused' => refused,
    'account-changed' => accountChanged,
    _ => unavailable,
  };
}

/// Bounded projection of daemon-owned same-identity devices.
///
/// Device IDs are certificate fingerprints, not user-entered labels. Native
/// applies the same contract before crossing the channel; Dart repeats it so a
/// malformed rolling-version response cannot build an unbounded settings UI or
/// become a revocation target.
abstract final class KnownDeviceWireContract {
  static const int maxDevices = 64;
  static const int maxNameUtf8Bytes = 128;
  static final RegExp _deviceId = RegExp(r'^[0-9a-f]{40,128}$');

  static String? decodeId(Object? value) {
    if (value is! String || !_deviceId.hasMatch(value)) return null;
    return value;
  }

  static String decodeName(Object? value) {
    if (value is! String || value.isEmpty) return '';
    var bytes = 0;
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit < 0x20 || unit == 0x7f) return '';
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) return '';
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) return '';
        bytes += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return '';
      } else if (unit <= 0x7f) {
        bytes += 1;
      } else if (unit <= 0x7ff) {
        bytes += 2;
      } else {
        bytes += 3;
      }
      if (bytes > maxNameUtf8Bytes) return '';
    }
    return value.trim();
  }
}

/// Cross-platform wire contract for the Jami account-profile fields the
/// current UI consumes for direct identities.
///
/// Rejecting an oversized or malformed value, rather than truncating it, keeps
/// Unicode grapheme clusters intact. The native bridges enforce the same
/// 256-byte limit before crossing the platform channel; this second check
/// keeps tests, rolling-version events, and future bridge implementations
/// fail-closed.
abstract final class ProfileWireContract {
  static const int maxDisplayNameUtf8Bytes = 256;
  static const int maxAvatarBytes = 256 * 1024;
  static const int maxAvatarBase64Chars = 350 * 1024;
  static const int maxAvatarDimension = 4096;
  static const int maxAvatarPixels = 4 * 1024 * 1024;

  static String? decodeDisplayName(Object? value) {
    if (value is! String) return null;
    var bytes = 0;
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) return null;
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) return null;
        bytes += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return null;
      } else if (unit <= 0x7f) {
        bytes += 1;
      } else if (unit <= 0x7ff) {
        bytes += 2;
      } else {
        bytes += 3;
      }
      if (bytes > maxDisplayNameUtf8Bytes) return null;
    }
    return value;
  }

  static String? decodeAvatar(Object? value) {
    if (value is! String || value.length > maxAvatarBase64Chars) return null;
    if (value.isEmpty) return '';
    try {
      final bytes = base64Decode(value);
      return isBoundedAvatarBytes(bytes) ? value : null;
    } catch (_) {
      return null;
    }
  }

  static bool isBoundedAvatarBytes(
    Uint8List bytes, {
    int maxEncodedBytes = maxAvatarBytes,
  }) {
    if (bytes.isEmpty || bytes.length > maxEncodedBytes) return false;
    return boundedRasterDecoder(
          bytes,
          maxEncodedBytes: maxEncodedBytes,
          maxDimension: maxAvatarDimension,
          maxPixels: maxAvatarPixels,
        ) !=
        null;
  }
}

/// Bounded optional metadata carried by Syb-L's native presence ping/pong.
///
/// The platform is a small vocabulary used only to phrase the status. Activity
/// is already privacy-filtered natively (friendly application name only), but
/// Dart validates the channel boundary again so injected or rolling-version
/// events cannot place unbounded/control text in the friend list.
abstract final class PresenceWireContract {
  static const int maxActivityUtf8Bytes = 96;
  static const Set<String> identityColors = {
    'amber',
    'coral',
    'rose',
    'violet',
    'sky',
    'teal',
    'sage',
    'lime',
    'red',
    'orange',
    'yellow',
    'green',
    'emerald',
    'mint',
    'cyan',
    'ice',
    'azure',
    'blue',
    'cobalt',
    'navy',
    'indigo',
    'magenta',
    'slate',
    'ivory',
  };

  static String decodeIdentityColor(Object? value) =>
      value is String && identityColors.contains(value) ? value : '';

  static String decodePlatform(Object? value) => switch (value) {
    'android' => 'android',
    'windows' => 'windows',
    _ => '',
  };

  static String decodeActivity(Object? value) {
    if (value is! String || value.isEmpty) return '';
    var bytes = 0;
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit < 0x20 || unit == 0x7f || unit == 0x22 || unit == 0x5c) {
        return '';
      }
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) return '';
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) return '';
        bytes += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return '';
      } else if (unit <= 0x7f) {
        bytes += 1;
      } else if (unit <= 0x7ff) {
        bytes += 2;
      } else {
        bytes += 3;
      }
      if (bytes > maxActivityUtf8Bytes) return '';
    }
    return value.trim();
  }
}

/// Keep only string-keyed entries from an untyped platform map. Native bridges normally return a
/// `Map<String, Object?>`, but malformed plugin output must degrade to an empty/partial result rather than throw.
Map<String, dynamic> _stringKeyedMap(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

Future<void> _requireTrue(
  MethodChannel channel,
  String method,
  Map<String, Object?> arguments,
) async {
  if (await channel.invokeMethod<bool>(method, arguments) != true) {
    throw StateError('$method was rejected');
  }
}

/// Dart facade over the production native bridges: MethodChannel `syb.l/core` carries commands to Kotlin on
/// Android or C++ on Windows; EventChannel `syb.l/events` carries their normalized daemon events back to Dart.
class JamiClient {
  static const int maxSettingsDocumentBytes = 64 * 1024;
  static const int maxPickedFileBytes = 2 * 1024 * 1024 * 1024;
  static const int maxBackupImportBytes = 16 * 1024 * 1024;
  static const int maxProfileImageBytes = 12 * 1024 * 1024;

  static const MethodChannel _core = MethodChannel('syb.l/core');
  static const EventChannel _events = EventChannel('syb.l/events');

  bool get usesNativeAppSettingsStore =>
      defaultTargetPlatform == TargetPlatform.android;

  bool get usesNativeSendJournal =>
      defaultTargetPlatform == TargetPlatform.windows;
  Future<String?> loadSendJournal() =>
      _core.invokeMethod<String>('loadSendJournal');
  Future<bool> saveSendJournal(String source) async =>
      await _core.invokeMethod<bool>('saveSendJournal', {'source': source}) ==
      true;

  Future<void> saveAppSettingsDocument(String document) =>
      _requireTrue(_core, 'saveAppSettingsDocument', {'document': document});

  Stream<JamiEvent> events() => _events.receiveBroadcastStream().map((e) {
    // One malformed platform event must not terminate the stream that drives calls, presence, and transfers.
    if (e is! Map) return JamiEvent('unknown', const <String, dynamic>{});
    final m = <String, dynamic>{};
    for (final entry in e.entries) {
      if (entry.key is String) m[entry.key as String] = entry.value;
    }
    return JamiEvent(m['type'] is String ? m['type'] as String : 'unknown', m);
  });

  Future<Map<String, dynamic>> ensureAccount(
    String displayName, {
    String preferredAccountId = '',
    String preferredPeerId = '',
    bool createIfMissing = false,
  }) async {
    final r = await _core.invokeMethod('ensureAccount', {
      'displayName': displayName,
      'preferredAccountId': preferredAccountId,
      'preferredPeerId': preferredPeerId,
      'createIfMissing': createIfMissing,
    });
    return _stringKeyedMap(r);
  }

  Future<String> myJamiId() async =>
      (await _core.invokeMethod<String>('myJamiId')) ?? '';

  Future<void> replayPendingNativeEvents() =>
      _requireTrue(_core, 'replayPendingNativeEvents', const {});

  /// Delegates a custom title-bar action to the native Windows owner window.
  Future<void> windowCommand(String command) =>
      _core.invokeMethod('windowCommand', {'command': command});

  Future<void> setWindowEdgeSpacing(
    String spacing, {
    required bool reposition,
  }) => _core.invokeMethod('setWindowEdgeSpacing', {
    'spacing': spacing,
    'reposition': reposition,
  });

  /// Synchronizes the native frame with the app's appearance preset.
  Future<void> setWindowAppearance({required bool disaccord}) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    await _core.invokeMethod<void>('setWindowAppearance', {
      'disaccord': disaccord,
    });
  }

  Future<Map<String, dynamic>?> windowPresentationState() =>
      _core.invokeMapMethod<String, dynamic>('windowPresentationState');

  Future<WindowCaptureProtectionStatus> presentWindowsCapturePrompt() async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return WindowCaptureProtectionStatus.unavailable;
    }
    return WindowCaptureProtectionStatus.fromWire(
      await _core.invokeMethod<String>('presentWindowCapturePrompt'),
    );
  }

  Future<WindowCaptureProtectionStatus> windowCaptureProtectionStatus() async {
    // Each native host reports applied truth; the setting is not inferred from
    // Dart intent.
    if (defaultTargetPlatform == TargetPlatform.android) {
      final value = await _core.invokeMethod<String>(
        'androidCaptureProtectionStatus',
      );
      return WindowCaptureProtectionStatus.fromWire(value);
    }
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return WindowCaptureProtectionStatus.unavailable;
    }
    final value = await _core.invokeMethod<String>(
      'windowCaptureProtectionStatus',
    );
    return WindowCaptureProtectionStatus.fromWire(value);
  }

  Future<WindowCaptureProtectionStatus> applyAndroidCaptureProtection({
    required bool protect,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return windowCaptureProtectionStatus();
    }
    final value = await _core.invokeMethod<String>(
      'setAndroidCaptureProtection',
      {'enabled': protect},
    );
    return WindowCaptureProtectionStatus.fromWire(value);
  }

  /// Android-only: reports whether a sensitive surface is visible. Returns
  /// true only once native has committed a frame with the window secure.
  Future<bool> setAndroidSensitiveSurface({required bool visible}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final value = await _core.invokeMethod<bool>('setAndroidSensitiveSurface', {
      'visible': visible,
    });
    return value == true;
  }

  /// Windows-only runtime capture-affinity change. `protect: true` requests
  /// WDA_EXCLUDEFROMCAPTURE with the WDA_MONITOR fallback; `protect: false`
  /// applies WDA_NONE. The returned value is the ACTUAL post-operation state
  /// confirmed by native code, never an echo of the request. On non-Windows
  /// platforms there is nothing to change; the unconditional status is
  /// returned instead.
  Future<WindowCaptureProtectionStatus> applyWindowsCaptureProtection({
    required bool protect,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return windowCaptureProtectionStatus();
    }
    final value = await _core.invokeMethod<String>(
      'applyWindowCaptureProtection',
      {'protect': protect},
    );
    return WindowCaptureProtectionStatus.fromWire(value);
  }

  /// The peer's 40-hex Jami ID from the daemon's contact list — the durable relationship pointer ("" if the
  /// account has no contact yet). The daemon keeps its contacts across a wipe→restore (they ride the account
  /// archive), so this re-hydrates daemon-owned friends when the local selection cache is gone.
  /// Legacy selected-friend recovery. This is a pure read and never changes native routing. New code uses
  /// [listFriends]; the method remains for rolling compatibility with older artifacts.
  Future<String> getPeerId() async =>
      (await _core.invokeMethod<String>('getPeerId')) ?? '';

  Future<JamiFriendList> listFriends() async {
    final result = _stringKeyedMap(await _core.invokeMethod('listFriends'));
    final rawFriends = result['friends'];
    final friends = <JamiFriend>[];
    if (rawFriends is List) {
      for (final raw in rawFriends) {
        final value = _stringKeyedMap(raw);
        final peer = value['peerJamiId'];
        if (peer is! String || peer.isEmpty) continue;
        friends.add(
          JamiFriend(
            peerJamiId: peer,
            confirmed: value['confirmed'] == true,
            conversationId: value['conversationId'] is String
                ? value['conversationId'] as String
                : '',
            displayName:
                ProfileWireContract.decodeDisplayName(value['displayName']) ??
                '',
            avatarBase64:
                ProfileWireContract.decodeAvatar(value['avatarBase64']) ?? '',
          ),
        );
      }
    }
    final rawRevision = result['revision'];
    final revision = rawRevision is int
        ? rawRevision
        : int.tryParse('$rawRevision') ?? 0;
    final rawGroups = result['groups'];
    final groups = <JamiGroup>[];
    if (rawGroups is List) {
      for (final raw in rawGroups.take(GroupWireContract.maxGroups)) {
        final value = _stringKeyedMap(raw);
        final conversationId = GroupWireContract.decodeConversationId(
          value['conversationId'],
        );
        if (conversationId == null) continue;
        final members = <JamiGroupMember>[];
        final rawMembers = value['members'];
        if (rawMembers is List) {
          for (final rawMember in rawMembers.take(
            GroupWireContract.maxMembers,
          )) {
            final member = _stringKeyedMap(rawMember);
            final peerId = GroupWireContract.decodePeerId(member['peerJamiId']);
            if (peerId == null) continue;
            members.add(
              JamiGroupMember(
                peerJamiId: peerId,
                role: switch (member['role']) {
                  'admin' => JamiGroupMemberRole.admin,
                  'member' => JamiGroupMemberRole.member,
                  'invited' => JamiGroupMemberRole.invited,
                  _ => JamiGroupMemberRole.unknown,
                },
                displayName:
                    ProfileWireContract.decodeDisplayName(
                      member['displayName'],
                    ) ??
                    '',
                avatarBase64:
                    ProfileWireContract.decodeAvatar(member['avatarBase64']) ??
                    '',
              ),
            );
          }
        }
        final rawCount = value['memberCount'];
        final memberCount = rawCount is int
            ? rawCount
            : int.tryParse('$rawCount') ?? 0;
        groups.add(
          JamiGroup(
            conversationId: conversationId,
            title:
                ProfileWireContract.decodeDisplayName(value['title']) ??
                'Untitled group',
            description: GroupWireContract.decodeDescription(
              value['description'],
            ),
            memberCount: memberCount.clamp(1, GroupWireContract.maxMembers),
            canManageMembers: value['canManageMembers'] == true,
            localRole: switch (value['localRole']) {
              'admin' => JamiGroupMemberRole.admin,
              'member' => JamiGroupMemberRole.member,
              _ => JamiGroupMemberRole.unknown,
            },
            members: List.unmodifiable(members),
          ),
        );
      }
    }
    return JamiFriendList(
      revision,
      List.unmodifiable(friends),
      List.unmodifiable(groups),
    );
  }

  Future<bool> addFriend(
    String peerJamiId, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('addFriend', {
        'peerJamiId': peerJamiId,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<String> createGroup(
    String title,
    Iterable<String> memberIds, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<String>('createGroup', {
        'title': title,
        'memberIds': memberIds.toList(growable: false),
        'expectedAccountId': ?expectedAccountId,
      })) ??
      '';

  Future<bool> addGroupMembers(
    String conversationId,
    Iterable<String> memberIds, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('addGroupMembers', {
        'conversationId': conversationId,
        'memberIds': memberIds.toList(growable: false),
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<bool> removeGroupMember(
    String conversationId,
    String memberId, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('removeGroupMember', {
        'conversationId': conversationId,
        'memberId': memberId,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<bool> renameGroup(
    String conversationId,
    String title, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('renameGroup', {
        'conversationId': conversationId,
        'title': title,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<bool> updateGroupLayout(
    String conversationId,
    String description, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('updateGroupLayout', {
        'conversationId': conversationId,
        'description': description,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<bool> leaveGroup(
    String conversationId, {
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('leaveGroup', {
        'conversationId': conversationId,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<void> setPresenceSubscriptions(Iterable<String> peerJamiIds) =>
      _requireTrue(_core, 'setPresenceSubscriptions', {
        'peerJamiIds': peerJamiIds.toList(growable: false),
      });

  Future<CallPlacement> placeCall(
    String peerJamiId, {
    bool withVideo = false,
    bool initialAudioMuted = false,
  }) async {
    final raw = await _core.invokeMethod('placeCall', {
      'peerJamiId': peerJamiId,
      'withVideo': withVideo,
      'initialAudioMuted': initialAudioMuted,
    });
    final result = _stringKeyedMap(raw);
    final callId = result['callId'] is String ? result['callId'] as String : '';
    return CallPlacement(
      callId,
      outgoingVideo: callId.isEmpty
          ? const OutgoingVideoSource.off()
          : OutgoingVideoSource.fromMap(result),
    );
  }

  Future<List<GroupActiveCall>> listGroupCalls(String conversationId) async {
    final raw = await _core.invokeMethod<List<Object?>>('listGroupCalls', {
      'conversationId': conversationId,
    });
    return [
      for (final value in raw ?? const <Object?>[])
        if (_stringKeyedMap(value) case {
          'conferenceId': final String conferenceId,
          'hostUri': final String hostUri,
          'hostDevice': final String hostDevice,
        })
          GroupActiveCall(
            conferenceId: conferenceId,
            hostUri: hostUri,
            hostDevice: hostDevice,
          ),
    ];
  }

  Future<bool> reserveGroupCall(
    String accountId,
    String conversationId,
    String reservationId,
  ) async =>
      await _core.invokeMethod<bool>('reserveGroupCall', {
        'accountId': accountId,
        'conversationId': conversationId,
        'reservationId': reservationId,
      }) ??
      false;

  Future<GroupCallPlacement> joinGroupCall({
    required String conversationId,
    required String conferenceId,
    String reservationId = '',
    String hostUri = '',
    String hostDevice = '',
    bool initialAudioMuted = false,
  }) async {
    final raw = _stringKeyedMap(
      await _core.invokeMethod('joinGroupCall', {
        'conversationId': conversationId,
        'conferenceId': conferenceId,
        'reservationId': reservationId,
        'hostUri': hostUri,
        'hostDevice': hostDevice,
        'initialAudioMuted': initialAudioMuted,
      }),
    );
    return GroupCallPlacement(
      conferenceId: raw['conferenceId'] is String
          ? raw['conferenceId'] as String
          : '',
      callId: raw['callId'] is String ? raw['callId'] as String : '',
      hosting: raw['hosting'] == true,
    );
  }

  Future<bool> leaveGroupCall(
    String conferenceId, {
    String reservationId = '',
  }) async =>
      (await _core.invokeMethod<bool>('leaveGroupCall', {
        'conferenceId': conferenceId,
        'reservationId': reservationId,
      })) ??
      false;

  Future<bool> setGroupMicMuted(String conferenceId, bool muted) async =>
      (await _core.invokeMethod<bool>('setGroupMicMuted', {
        'conferenceId': conferenceId,
        'muted': muted,
      })) ??
      false;

  Future<bool> setGroupDeafened(String conferenceId, bool deafened) async =>
      (await _core.invokeMethod<bool>('setGroupDeafened', {
        'conferenceId': conferenceId,
        'deafened': deafened,
      })) ??
      false;

  Future<bool> setGroupConferenceLayout(
    String conferenceId,
    int layout,
  ) async =>
      (await _core.invokeMethod<bool>('setGroupConferenceLayout', {
        'conferenceId': conferenceId,
        'layout': layout,
      })) ??
      false;

  Future<bool> setGroupActiveStream(
    String conferenceId,
    GroupConferenceStream stream,
    bool active,
  ) async =>
      (await _core.invokeMethod<bool>('setGroupActiveStream', {
        'conferenceId': conferenceId,
        'accountId': stream.accountId,
        'deviceId': stream.deviceId,
        'streamId': stream.sinkId,
        'active': active,
      })) ??
      false;

  Future<bool> muteGroupParticipant(
    String conferenceId,
    GroupConferenceStream stream,
    bool muted,
  ) async =>
      (await _core.invokeMethod<bool>('muteGroupParticipant', {
        'conferenceId': conferenceId,
        'accountId': stream.accountId,
        'deviceId': stream.deviceId,
        'streamId': stream.sinkId,
        'muted': muted,
      })) ??
      false;

  Future<bool> disconnectGroupParticipant(
    String conferenceId,
    GroupConferenceStream stream,
  ) async =>
      (await _core.invokeMethod<bool>('disconnectGroupParticipant', {
        'conferenceId': conferenceId,
        'accountId': stream.accountId,
        'deviceId': stream.deviceId,
      })) ??
      false;

  Future<bool> publishGroupCallPresence(
    String conversationId,
    String payload,
  ) async =>
      (await _core.invokeMethod<bool>('publishGroupCallPresence', {
        'conversationId': conversationId,
        'payload': payload,
      })) ??
      false;

  Future<void> answerCall(String callId, {bool initialAudioMuted = false}) =>
      _requireTrue(_core, 'answerCall', {
        'callId': callId,
        'initialAudioMuted': initialAudioMuted,
      });
  Future<void> hangUp(String callId) =>
      _requireTrue(_core, 'hangUp', {'callId': callId});
  Future<void> refuse(String callId) =>
      _requireTrue(_core, 'refuse', {'callId': callId});

  /// Fire ONE presence PING to the peer and return the daemon's message id (as a string); "" if it couldn't
  /// send. A non-swarm account message (rides the P2P message channel, opening one to wake a cold peer) whose
  /// payload is {"t":"ping","fg":0|1,"ts":ms} under our custom MIME. The peer's NATIVE bridge auto-replies with
  /// a pong ({"t":"pong",...}) — that pong (arriving on [events] as 'presenceMsg') is the end-to-end liveness
  /// proof. The daemon's own SENT ack (messageStatus state=2) is only a LOCAL socket-write success — a write
  /// into a zombie channel "succeeds" — so it is NOT liveness evidence; FAILURE=4 stays a real negative.
  /// Never a git commit (the shared-file history stays clean). Honest lifecycle: the daemon queues the message
  /// PERSISTENTLY (survives restarts) and retries on reconnect events until SENT or 20 cumulative retries; no
  /// cancel API, so callers keep at most one probe in flight (AppState.refreshPresence guards this).
  Future<String> probeReachable(String peerJamiId) async =>
      (await _core.invokeMethod<String>('probeReachable', {
        'peerJamiId': peerJamiId,
      })) ??
      '';

  /// Set libjami's composing state for one exact trusted direct conversation.
  Future<bool> sendComposerActivity(
    String accountId,
    String peerJamiId,
    String conversationId,
    ComposerActivityKind kind,
  ) async =>
      (await _core.invokeMethod<bool>('sendComposerActivity', {
        'accountId': accountId,
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'kind': kind.name,
      })) ??
      false;

  /// Send one tiny, non-swarm PNG preview for an exact connected-contact file
  /// offer. Receiver freshness and ownership checks fail closed.
  Future<bool> sendFileThumbnail(
    String peerJamiId,
    String conversationId,
    String fileId,
    Uint8List png,
  ) async =>
      (await _core.invokeMethod<bool>('sendFileThumbnail', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'fileId': fileId,
        'pngBase64': base64Encode(png),
      })) ??
      false;

  /// Persistently tell the exact direct peer that an offered file was
  /// declined. This is app state, not a swarm-visible chat message.
  Future<bool> sendFileDeclined(
    String peerJamiId,
    String conversationId,
    String fileId,
  ) async =>
      (await _core.invokeMethod<bool>('sendFileDeclined', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'fileId': fileId,
      })) ??
      false;

  /// Keep native foreground truth for local safety checks. Presence packets
  /// share that truth only after the activity-sharing opt-in is applied.
  Future<void> setForeground(bool fg) =>
      _core.invokeMethod('setForeground', {'fg': fg});

  /// Configure native-authored presence metadata. Both platforms use the
  /// sharing choice for foreground presence; Android never scans another app.
  Future<void> setPresenceMetadata({
    required bool shareActivity,
    required String color,
  }) => _core.invokeMethod('setPresenceMetadata', {
    'shareActivity': shareActivity,
    'color': color,
  });

  /// Consume a launch-time personalized invite. Windows passes the registered
  /// URI as a Dart entrypoint argument; Android owns the launch Intent until
  /// this one-shot method consumes it. Later links arrive as `inviteLink`
  /// events on both platforms.
  Future<String> takeInitialInviteLink() async {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      for (final argument in Platform.executableArguments) {
        if (argument.startsWith('sybl://') ||
            argument.startsWith('doorlight://')) {
          return argument;
        }
      }
      return '';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return (await _core.invokeMethod<String>('takePendingInviteLink')) ?? '';
    }
    return '';
  }

  Future<ConversationLaunchTarget?> takeInitialConversation() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return ConversationLaunchTarget.tryParse(
      await _core.invokeMethod<Object?>('takePendingConversation'),
    );
  }

  Future<bool> consumeConversationLaunch(
    ConversationLaunchTarget target,
  ) async {
    if (target.actionToken == null) return true;
    return await _core.invokeMethod<bool>('consumeMessageOpen', {
          'actionToken': target.actionToken,
          'accountId': target.accountId,
          'ownerKey': target.ownerKey,
          'conversationId': target.conversationId,
          'topicId': target.topicId,
          'startCall': target.startCall,
        }) ==
        true;
  }

  Future<void> setMessageNotificationPreview(
    bool showMessage, {
    required bool appLockEnabled,
  }) {
    if (defaultTargetPlatform != TargetPlatform.android) return Future.value();
    return _requireTrue(_core, 'setMessageNotificationPreview', {
      'showMessage': showMessage,
      'appLockEnabled': appLockEnabled,
    });
  }

  Future<void> dismissMessageNotification(String conversationId) {
    if (defaultTargetPlatform != TargetPlatform.android) return Future.value();
    return _core.invokeMethod('dismissMessageNotification', {
      'conversationId': conversationId,
    });
  }

  Future<bool> backgroundWakeAvailability() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    if (!WakeRelayConfig.validBaseUrl(WakeRelayConfig.baseUrl)) return false;
    return (await _core.invokeMethod<bool>('backgroundWakeAvailability')) ??
        false;
  }

  Future<bool> setReliableBackgroundNotifications({
    required bool enabled,
    required String connectionProfile,
    String? expectedAccountId,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    return (await _core
            .invokeMethod<bool>('setReliableBackgroundNotifications', {
              'enabled': enabled,
              'connectionProfile': connectionProfile,
              'relayUrl': WakeRelayConfig.baseUrl,
              'expectedAccountId': ?expectedAccountId,
            })) ??
        false;
  }

  Future<bool> rotateBackgroundWakeCapability({
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('rotateBackgroundWakeCapability', {
        'relayUrl': WakeRelayConfig.baseUrl,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  Future<bool> notifyCallRequest(String peerJamiId) async =>
      (await _core.invokeMethod<bool>('notifyCallRequest', {
        'peerJamiId': peerJamiId,
      })) ??
      false;

  /// Devices authenticated under this same Jami identity. Conversation and
  /// contact sync belongs to Jami; this is only the management projection.
  Future<List<JamiKnownDevice>> listKnownDevices() async {
    final raw =
        await _core.invokeListMethod<Object?>('listKnownDevices') ?? const [];
    final devices = <JamiKnownDevice>[];
    final seen = <String>{};
    for (final value in raw) {
      if (devices.length >= KnownDeviceWireContract.maxDevices) break;
      final map = _stringKeyedMap(value);
      final id = KnownDeviceWireContract.decodeId(map['id']);
      if (id == null || !seen.add(id)) continue;
      devices.add(
        JamiKnownDevice(
          id: id,
          name: KnownDeviceWireContract.decodeName(map['name']),
          current: map['current'] == true || map['current'] == 'true',
        ),
      );
    }
    devices.sort((a, b) {
      if (a.current != b.current) return a.current ? -1 : 1;
      return a.id.compareTo(b.id);
    });
    return List.unmodifiable(devices);
  }

  /// Await revocation of another exact device under the captured account.
  /// Native supplies the installation-held credential and refuses this device.
  Future<JamiDeviceRevocationStatus> revokeKnownDevice(
    String deviceId, {
    required String accountId,
  }) async {
    if (accountId.isEmpty) return JamiDeviceRevocationStatus.accountChanged;
    if (KnownDeviceWireContract.decodeId(deviceId) == null) {
      return JamiDeviceRevocationStatus.refused;
    }
    try {
      final value = await _core
          .invokeMethod<Object?>('revokeKnownDevice', {
            'accountId': accountId,
            'deviceId': deviceId,
          })
          .timeout(const Duration(seconds: 35));
      if (value is! Map ||
          value['accountId'] != accountId ||
          value['deviceId'] != deviceId) {
        return JamiDeviceRevocationStatus.unavailable;
      }
      return JamiDeviceRevocationStatus.fromWire(value['status']);
    } on TimeoutException {
      return JamiDeviceRevocationStatus.timeout;
    } catch (_) {
      return JamiDeviceRevocationStatus.unavailable;
    }
  }

  /// presence v2 zombie-janitor: the daemon's connectivityChanged() beacons every connected socket (3 s
  /// timeout kills dead ones → a NewBuddyNotification flips within ~3 s). Off-label (also resets DHT/ICE
  /// caches) — call it rate-limited and only on pong-timeout suspicion, never on a tight cadence.
  Future<void> connectivitySweep() => _core.invokeMethod('connectivitySweep');

  /// Mute this call's local audio sender. The call id is part of the contract so a delayed control cannot change a
  /// glare replacement or a later call that happens to own the process-global audio device.
  Future<void> setMicMuted(String callId, bool muted) =>
      _core.invokeMethod('setMicMuted', {'callId': callId, 'muted': muted});

  /// Select this call's daemon-owned transmission gate. Native validates that
  /// [callId] is still the authoritative live call, enables libjami's existing
  /// VAD before `voiceActivated`, and fails instead of silently falling back to
  /// an open microphone.
  Future<void> setAudioTransmissionMode(
    String callId,
    AudioTransmissionMode mode,
  ) => _core.invokeMethod('setAudioTransmissionMode', {
    'callId': callId,
    'mode': mode.name,
  });

  /// Diagnostic/display-only capture-ring RMS meter. It is not a transmission
  /// authority; production voice activation is [setAudioTransmissionMode].
  Future<void> setAudioMeterEnabled(bool enabled) =>
      _core.invokeMethod('setAudioMeterEnabled', {'enabled': enabled});

  Future<void> setSpeaker(bool on) =>
      _core.invokeMethod('setSpeaker', {'on': on});

  /// Windows-only: libjami's audio output device names, in daemon index order.
  Future<List<String>> audioOutputs() async =>
      ((await _core.invokeMethod<List<Object?>>('audioOutputs')) ?? const [])
          .whereType<String>()
          .toList(growable: false);

  /// Windows-only: selects an output device by [audioOutputs] index.
  Future<bool> setAudioOutput(int index) async =>
      (await _core.invokeMethod<bool>('setAudioOutput', {'index': index})) ??
      false;

  Future<List<String>> audioInputs() async =>
      ((await _core.invokeMethod<List<Object?>>('audioInputs')) ?? const [])
          .whereType<String>()
          .toList(growable: false);

  /// Windows-only: selects an input device by [audioInputs] index.
  Future<bool> setAudioInput(int index) async =>
      (await _core.invokeMethod<bool>('setAudioInput', {'index': index})) ??
      false;

  /// Android only: prompts for microphone and notification access if missing.
  Future<void> requestRuntimePermissions() =>
      _core.invokeMethod<void>('requestRuntimePermissions');

  /// Android only: hold Wi-Fi multicast reception for Nearby discovery. Not reference-counted natively, so
  /// repeated calls are safe; returns whether the lock is held.
  // Multiple local discovery channels share Android's non-reference-counted lock.
  int _multicastUsers = 0;
  Future<void> _multicastPending = Future<void>.value();

  Future<T> _multicastChange<T>(Future<T> Function() change) {
    final next = _multicastPending.then((_) => change());
    _multicastPending = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<bool> acquireMulticastLock() => _multicastChange(() async {
    if (_multicastUsers > 0) {
      _multicastUsers++;
      return true;
    }
    final acquired =
        (await _core.invokeMethod<bool>('acquireMulticastLock')) ?? false;
    if (acquired) _multicastUsers = 1;
    return acquired;
  });

  Future<void> releaseMulticastLock() => _multicastChange(() async {
    if (_multicastUsers == 0) return;
    if (_multicastUsers > 1) {
      _multicastUsers--;
      return;
    }
    await _core.invokeMethod<void>('releaseMulticastLock');
    _multicastUsers = 0;
  });

  Future<bool> hasMicPermission() async =>
      (await _core.invokeMethod<bool>('hasMicPermission')) ?? false;

  // ---- video (M2) ----

  /// Create (or reuse) the external texture for [role] = 'self' | 'remote'; returns the Flutter texture id.
  Future<int> createVideoTexture(String role) async =>
      (await _core.invokeMethod<int>('createVideoTexture', {'role': role})) ??
      -1;

  Future<bool> setOutgoingVideoSource(
    String callId,
    OutgoingVideoKind kind, {
    String? sourceId,
  }) async =>
      (await _core.invokeMethod<bool>('setOutgoingVideoSource', {
        'callId': callId,
        'kind': kind.name,
        'sourceId': sourceId,
      })) ??
      false;

  Future<List<ScreenSource>> listScreenSources(String callId) async {
    final raw = await _core.invokeMethod<Object?>('listScreenSources', {
      'callId': callId,
    });
    if (raw is! List) return const [];
    return raw.map(ScreenSource.fromMap).whereType<ScreenSource>().toList();
  }

  /// Compatibility adapters into the single typed source command.
  Future<bool> startVideo(String callId) async =>
      (await _core.invokeMethod<bool>('startVideo', {'callId': callId})) ??
      false;
  Future<bool> stopVideo(String callId) async =>
      (await _core.invokeMethod<bool>('stopVideo', {'callId': callId})) ??
      false;
  Future<void> switchCamera(String callId) =>
      _core.invokeMethod('switchCamera', {'callId': callId});

  Future<bool> hasCameraPermission() async =>
      (await _core.invokeMethod<bool>('hasCameraPermission')) ?? false;

  // ---- file transfer (M5) ----
  //
  // P2P over the peer's 1:1 swarm conversation (the only model libjami exposes — sendFile/downloadFile take a
  // conversationId; files are never server-hosted). Progress + completion arrive on [events] as 'fileProgress';
  // an incoming offer arrives as 'incomingFile'. The native side resolves the conversation and chooses the
  // download directory; pickers are the OS-native dialogs (no extra Flutter dependency).

  /// Open the OS file picker. Both platforms return a bounded app-private staged copy; successful sends hand it
  /// off to daemon-owned conversation storage and native lifecycle callbacks discard the picker copy. Returns null
  /// if cancelled.
  Future<String?> pickFile({
    String mimeType = '*/*',
    int maxBytes = maxPickedFileBytes,
  }) async => await _core.invokeMethod<String>('pickFile', {
    'mimeType': mimeType,
    'maxBytes': maxBytes,
  });

  Future<void> setHologramPrivacy(
    String accountId,
    int generation,
    bool enabled,
  ) => _core.invokeMethod<void>('setHologramPrivacy', {
    'accountId': accountId,
    'generation': generation,
    'enabled': enabled,
  });

  Future<String> hologramPresentationState(
    String accountId,
    String peer,
    String conversation,
    int generation,
  ) async =>
      await _core.invokeMethod<String>('hologramPresentationState', {
        'accountId': accountId,
        'peerJamiId': peer,
        'conversationId': conversation,
        'generation': generation,
      }) ??
      'unavailable';

  Future<bool> showHologram(
    String accountId,
    String peer,
    String conversation,
    String asset,
    int generation,
    bool reducedMotion,
  ) async =>
      await _core.invokeMethod<bool>('showHologram', {
        'accountId': accountId,
        'peerJamiId': peer,
        'conversationId': conversation,
        'assetId': asset,
        'generation': generation,
        'reducedMotion': reducedMotion,
      }) ??
      false;

  Future<void> cancelHologram(int generation) =>
      _core.invokeMethod<void>('cancelHologram', {'generation': generation});

  Future<bool> sendHologramControl(
    String accountId,
    String peer,
    String payload,
  ) async =>
      await _core.invokeMethod<bool>('sendHologramControl', {
        'accountId': accountId,
        'peerJamiId': peer,
        'payload': payload,
      }) ??
      false;

  Future<void> discardPickedFile(String path) =>
      _core.invokeMethod<void>('discardPickedFile', {'path': path});

  /// Local imported media, deliberately outside identity archives.
  Future<String?> gifLibraryDirectory() =>
      _core.invokeMethod<String>('gifLibraryDirectory');

  /// Read-only chat archives, private app storage outside identity archives.
  Future<String?> archivedChatsDirectory() =>
      _core.invokeMethod<String>('archivedChatsDirectory');

  Future<String?> captureComposerPhoto(String accountId) => _core
      .invokeMethod<String>('captureComposerPhoto', {'accountId': accountId});

  Future<String?> prepareVoiceRecording({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
  }) => _core.invokeMethod<String>('prepareVoiceRecording', {
    'accountId': accountId,
    'peerJamiId': peerJamiId,
    'conversationId': conversationId,
  });

  Future<bool> renewVoiceRecording(String path) async =>
      await _core.invokeMethod<bool>('renewVoiceRecording', {'path': path}) ??
      false;

  Future<String?> stageGifLibraryEntry(String hash) =>
      _core.invokeMethod<String>('stageGifLibraryEntry', {'hash': hash});

  Future<String?> stageStarterGif(String id) =>
      _core.invokeMethod<String>('stageStarterGif', {'id': id});

  Future<bool> updateProfile({
    required String displayName,
    required String avatarBase64,
    required String fileType,
    required int flag,
    String? expectedAccountId,
  }) async =>
      (await _core.invokeMethod<bool>('updateProfile', {
        'displayName': displayName,
        'avatar': avatarBase64,
        'fileType': fileType,
        'flag': flag,
        'expectedAccountId': ?expectedAccountId,
      })) ??
      false;

  /// Send a local file to the peer over their swarm conversation. Returns false if no conversation/path.
  /// Progress then streams as 'fileProgress' events (outgoing=true).
  Future<bool> sendFile(
    String peerJamiId,
    String conversationId,
    String path, {
    String? name,
    String topicId = '',
  }) async =>
      (await _core.invokeMethod<bool>('sendFile', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'path': path,
        'name': name,
        'topicId': topicId,
      })) ??
      false;

  /// Accept an offered incoming file → download it locally. Progress streams as 'fileProgress'.
  Future<bool> acceptFile(
    String peerJamiId,
    String conversationId,
    String interactionId,
    String fileId,
    String name, {
    int maxBytes = 0,
    String attemptId = '',
  }) async =>
      (await _core.invokeMethod<bool>('acceptFile', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'interactionId': interactionId,
        'fileId': fileId,
        'name': name,
        'maxBytes': maxBytes,
        'attemptId': attemptId,
      })) ??
      false;

  /// Ask the platform to open a completed incoming transfer with the user's
  /// registered app. Native validates that [path] is a regular file inside
  /// Syb-L's receive directory before handing it to the OS.
  Future<bool> openReceivedFile(String path) async =>
      (await _core.invokeMethod<bool>('openReceivedFile', {'path': path})) ??
      false;

  /// Decline an offered file or cancel an in-flight transfer.
  Future<bool> cancelFile(
    String peerJamiId,
    String conversationId,
    String fileId, {
    String attemptId = '',
  }) async =>
      (await _core.invokeMethod<bool>('cancelFile', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'fileId': fileId,
        'attemptId': attemptId,
      })) ??
      false;

  /// Poll byte progress for a transfer: {transferred, total, path}. Used to animate the bar between the
  /// daemon's sparse state-change events. Empty map if unknown.
  Future<Map<String, dynamic>> fileInfo(
    String peerJamiId,
    String conversationId,
    String fileId,
  ) async {
    final r = await _core.invokeMethod('fileInfo', {
      'peerJamiId': peerJamiId,
      'conversationId': conversationId,
      'fileId': fileId,
    });
    return _stringKeyedMap(r);
  }

  // ---- presence / appear-offline (M7) ----
  //
  // Go dark: Jami has NO "connected-but-invisible" state — being online is a side effect of the account
  // announcing on the DHT. So "appear offline" = disable the account (the daemon's sendRegister(acc, false),
  // which persists `Account.enable`). In steady state a dark account boots disabled; if the Dart preference and
  // daemon config drift, boot can queue peer work before Dart re-disables it. Peers see you offline and you become
  // unreachable to calls/files while dark. Toggling back re-enables + re-announces.
  Future<void> setAppearOffline(bool on, {String? expectedAccountId}) =>
      _core.invokeMethod('setAppearOffline', {
        'on': on,
        'expectedAccountId': ?expectedAccountId,
      });

  // ---- connection profile (M7) ----
  //
  // Switch HOW we reach the peer — a selectable libjami account config, NOT a rebuild (hard-rule #1). The native
  // side reads the full account details, overwrites the connection keys for [profile], and writes them back; the
  // daemon's setAccountDetails re-registers automatically so the change takes effect without an explicit re-register.
  //   'lan'    = Local Peer Discovery only (global bootstrap neutered, proxy/TURN/UPnP off) — same-LAN, zero servers.
  //   'jami'   = bootstrap.jami.net + DHT proxy + turn.jami.net fallback, with LAN discovery/publish off. Public
  //              infrastructure handles rendezvous and may relay encrypted media when ICE selects TURN.
  //   'strict' = custom dhtnode + optional coTURN with third-party discovery/proxy off. A blank bootstrap is replaced
  //              with unreachable 192.0.2.1 so it fails closed; useful cross-network operation needs a real host.
  Future<void> setConnectionProfile(
    String profile, {
    String? expectedAccountId,
    String dhtBootstrap = '',
    String turnServer = '',
    String turnRealm = '',
    String turnUser = '',
    String turnPassword = '',
  }) => _core.invokeMethod('setConnectionProfile', {
    'profile': profile,
    'expectedAccountId': ?expectedAccountId,
    'dhtBootstrap': dhtBootstrap,
    'turnServer': turnServer,
    'turnRealm': turnRealm,
    'turnUser': turnUser,
    'turnPassword': turnPassword,
  });

  // ---- file-keeping (M6) ----
  //
  // Load the persistent shared folder = the file history of the peer's 1:1 swarm conversation. The native side
  // resolves the canonical conversation, calls libjami loadConversation, and on the daemon's SwarmLoaded reply
  // scans the newest [keepLast] conversation commits and emits the file commits among them (up to [keepLast]).
  // Fire-and-forget: items arrive on [events]. Safe to call repeatedly after launch/synchronization.
  /// Returns a monotonic native load ID. Completion is one atomic `folderSnapshot`; callers must correlate the
  /// owner tuple and load generation before replacing their view.
  Future<int> loadFolder(
    String peerJamiId,
    String conversationId,
    int keepLast,
  ) async =>
      (await _core.invokeMethod<int>('loadFolder', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'n': keepLast,
      })) ??
      0;

  /// Commit text to the exact friend-owned libjami swarm conversation.
  Future<bool> sendChatMessage(
    String peerJamiId,
    String conversationId,
    String body, {
    String replyTo = '',
    String topicId = '',
  }) async =>
      (await _core.invokeMethod<bool>('sendChatMessage', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'body': body,
        'replyTo': replyTo,
        'topicId': topicId,
      })) ??
      false;

  /// Issue an owned publication. Final commit authority arrives through the
  /// correlated native completion event; a timeout is never a retry signal.
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
  }) async =>
      await _core.invokeMethod<String>('sendOwnedMessage', {
        'accountId': accountId,
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'mimeType': mimeType,
        'body': body,
        'operationId': operationId,
        'replyTo': replyTo,
        'topicId': topicId,
        'roomId': roomId,
      }) ??
      'unknown';

  /// Own a standard Jami reaction or an edition of the user's reaction commit.
  /// Admission is not proof of publication; completion uses the send journal.
  Future<String> sendOwnedReaction({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
    required String messageId,
    required String operationId,
    required String emoji,
    String removedId = '',
    String topicId = '',
    String roomId = '',
  }) async =>
      await _core.invokeMethod<String>('sendOwnedReaction', {
        'accountId': accountId,
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'messageId': messageId,
        'operationId': operationId,
        'emoji': emoji,
        'removedId': removedId,
        'topicId': topicId,
        'roomId': roomId,
      }) ??
      'unknown';

  /// Publish a staged file with independent commit and seed-ready callbacks.
  Future<String> sendOwnedFile({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
    required String path,
    required String operationId,
    String name = '',
    String topicId = '',
    String roomId = '',
    String media = '',
  }) async =>
      await _core.invokeMethod<String>('sendOwnedFile', {
        'accountId': accountId,
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'path': path,
        'operationId': operationId,
        'name': name,
        'topicId': topicId,
        'roomId': roomId,
        'media': media,
      }) ??
      'unknown';

  Future<bool> acknowledgeFileSeed({
    required String accountId,
    required String conversationId,
    required String operationId,
    required String commitId,
  }) async =>
      await _core.invokeMethod<bool>('acknowledgeFileSeed', {
        'accountId': accountId,
        'conversationId': conversationId,
        'operationId': operationId,
        'commitId': commitId,
      }) ??
      false;

  /// Commit one bounded signed DM-topic control event and return its daemon ID.
  Future<String> sendDmTopicEvent(
    String peerJamiId,
    String conversationId,
    String body,
  ) async =>
      (await _core.invokeMethod<String>('sendDmTopicEvent', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'body': body,
      })) ??
      '';

  /// Scan durable DM-topic state without adding scan items to the visible chat.
  Future<int> loadDmTopicState(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 200,
  }) async =>
      (await _core.invokeMethod<int>('loadDmTopicState', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'fromMessage': fromMessage,
        'pageSize': pageSize,
      })) ??
      0;

  Future<bool> setMessageDisplayed(
    String peerJamiId,
    String conversationId,
    String messageId,
  ) async =>
      (await _core.invokeMethod<bool>('setMessageDisplayed', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'messageId': messageId,
      })) ??
      false;

  /// Completes only when the native search worker terminates. Do not add an
  /// observation timeout here: the controller uses this future as its lease.
  Future<HistorySearchBatch> searchHistory(
    ConversationScope scope,
    HistorySearchQuery query,
    int limit,
  ) async {
    if (!HistorySearchWire.commit(scope.conversationId) ||
        limit < 1 ||
        limit > HistorySearchWire.maximumResults) {
      throw const FormatException('Invalid search request');
    }
    final value = await _core.invokeMethod<Object?>('searchHistory', {
      'accountId': scope.accountId,
      'peerJamiId': scope.peerId,
      'conversationId': scope.conversationId,
      'query': query.literal,
      'limit': limit,
    });
    final batch = HistorySearchBatch.fromWire(value, scope, limit);
    if (batch == null) {
      throw const FormatException('Search unavailable');
    }
    return batch;
  }

  /// Fresh native fold for a selected hit, distinct from cursor-based paging.
  /// The future also owns the scan lease; an observation timeout cannot release it.
  Future<SearchMessageSnapshot> loadSearchMessage(
    HistorySearchHit hit, {
    required String localAuthorId,
    Set<String>? allowedRemoteAuthorIds,
  }) async {
    if (!HistorySearchWire.commit(hit.scope.conversationId)) {
      throw const FormatException('Invalid message request');
    }
    final value = await _core.invokeMethod<Object?>('loadSearchMessage', {
      'accountId': hit.scope.accountId,
      'peerJamiId': hit.scope.peerId,
      'conversationId': hit.scope.conversationId,
      'messageId': hit.messageId,
    });
    final snapshot = SearchMessageSnapshot.fromWire(
      value,
      hit,
      localAuthorId: localAuthorId,
      allowedRemoteAuthorIds: allowedRemoteAuthorIds,
    );
    if (snapshot == null) {
      throw const FormatException('Message unavailable');
    }
    return snapshot;
  }

  Future<void> retireHistorySearch(String accountId) async {
    if (accountId.isEmpty) return;
    await _core.invokeMethod<void>('retireHistorySearch', {
      'accountId': accountId,
    });
  }

  /// Begin one daemon-correlated page of the persistent conversation history.
  Future<int> loadChat(
    String peerJamiId,
    String conversationId, {
    String fromMessage = '',
    int pageSize = 50,
  }) async =>
      (await _core.invokeMethod<int>('loadChat', {
        'peerJamiId': peerJamiId,
        'conversationId': conversationId,
        'fromMessage': fromMessage,
        'n': pageSize,
      })) ??
      0;

  /// Retire one abandoned native history-load correlation. libjami itself has
  /// no cancellation API, so this only prevents its eventual callback from
  /// retaining or reclaiming client ownership.
  Future<bool> cancelChatLoad(int loadId) async =>
      (await _core.invokeMethod<bool>('cancelChatLoad', {'loadId': loadId})) ??
      false;

  Future<bool> cancelDmTopicStateLoad(int loadId) async =>
      (await _core.invokeMethod<bool>('cancelDmTopicStateLoad', {
        'loadId': loadId,
      })) ??
      false;

  // ---- inbound-trust gate + remove/block (M7.5 d) ----
  //
  // Jami consumes trusted one-to-one requests before this callback. Native surfaces every remaining friend/group
  // request as {conversationId, fromJamiId, isGroup}; the UI always requires an explicit decision. Friend accepts
  // add contact trust; group accepts only join the group.
  Future<void> acceptConnect(String conversationId) =>
      _core.invokeMethod('acceptConnect', {'conversationId': conversationId});
  Future<void> declineConnect(String conversationId, String fromJamiId) =>
      _core.invokeMethod('declineConnect', {
        'conversationId': conversationId,
        'fromJamiId': fromJamiId,
      });

  /// Remove (or BLOCK) a contact. block=true bans them (removeContact ban) so future requests are auto-rejected.
  Future<void> removeContact(String uri, {bool block = false}) =>
      _requireTrue(_core, 'removeContact', {'uri': uri, 'ban': block});

  // ---- in-call side channel (M8: annotation draw events) ----
  //
  // A low-latency, ephemeral, P2P message channel that rides the LIVE call's SIP dialog — an in-dialog SIP MESSAGE
  // over the already-established ICE+TLS transport (the same path as the media), NOT the DHT and NOT a swarm git
  // conversation, so nothing is persisted. The native side wraps [payload] under a custom MIME and calls libjami
  // sendTextMessage(account, callId, …); inbound messages arrive on [events] as 'callMessage' {callId, fromJamiId,
  // payload}. The annotation overlay drives its draw protocol over this. Send only while the call is CURRENT (the
  // daemon queues/drops in-call messages sent earlier). Wire payloads stay below ~6 KB because the daemon's full
  // SIP packet cap is 8 KB including headers.
  Future<bool> sendCallMessage(
    String callId,
    String payload, {
    String channel = 'annotation',
  }) async =>
      (await _core.invokeMethod<bool>('sendCallMessage', {
        'callId': callId,
        'payload': payload,
        'channel': channel,
      })) ??
      false;

  // ---- remote control (M10) ----
  //
  // Windows owns its strict native authority and Android owns a separate
  // AccessibilityService-backed native authority. Dart remains only the
  // controller projection on Android; no input-injection MethodChannel command
  // exists.

  bool get _windowsRemoteControl =>
      defaultTargetPlatform == TargetPlatform.windows;
  bool get _androidRemoteController =>
      defaultTargetPlatform == TargetPlatform.android;

  Future<bool> requestRemoteControl({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required List<String> capabilities,
    required String identityColor,
    required String androidPacket,
  }) async {
    if (_windowsRemoteControl) {
      return (await _core.invokeMethod<bool>('remoteControlRequest', {
            'callId': callId,
            'peerJamiId': peerJamiId,
            'sourceRevision': sourceRevision,
            'capabilities': capabilities,
            'identityColor': identityColor,
          })) ??
          false;
    }
    if (!_androidRemoteController) return false;
    return sendCallMessage(callId, androidPacket, channel: 'control');
  }

  Future<bool> sendRemoteControlInput({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required List<List<Object>> events,
    required String androidPacket,
  }) async {
    if (_windowsRemoteControl) {
      return (await _core.invokeMethod<bool>('remoteControlInput', {
            'callId': callId,
            'peerJamiId': peerJamiId,
            'sourceRevision': sourceRevision,
            'events': events,
          })) ??
          false;
    }
    if (!_androidRemoteController) return false;
    return sendCallMessage(callId, androidPacket, channel: 'control');
  }

  Future<bool> endRemoteControl({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required String androidPacket,
  }) async {
    if (_windowsRemoteControl) {
      return (await _core.invokeMethod<bool>('remoteControlEnd', {
            'callId': callId,
            'peerJamiId': peerJamiId,
            'sourceRevision': sourceRevision,
          })) ??
          false;
    }
    if (!_androidRemoteController) return false;
    return sendCallMessage(callId, androidPacket, channel: 'control');
  }

  Future<bool> sendRemoteClipboard({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required String text,
    required String id,
    required String sha256Hex,
    required String androidOfferPacket,
    required String androidDataPacket,
    required bool fromHost,
    String controllerDeviceId = '',
    int hostGeneration = 0,
  }) async {
    if (_windowsRemoteControl) {
      if (fromHost) {
        return (await _core.invokeMethod<bool>('remoteClipboardHostSend', {
              'callId': callId,
              'peerJamiId': peerJamiId,
              'controllerDeviceId': controllerDeviceId,
              'sourceRevision': sourceRevision,
              'hostGeneration': hostGeneration,
              'text': text,
            })) ??
            false;
      }
      return (await _core.invokeMethod<bool>('remoteClipboardSend', {
            'callId': callId,
            'peerJamiId': peerJamiId,
            'sourceRevision': sourceRevision,
            'text': text,
          })) ??
          false;
    }
    if (!_androidRemoteController || fromHost) return false;
    // Reliable ordered in-dialog MESSAGE: the offer is deliberately sent
    // before the matching bytes. Receiver consent is bound to id+hash+size.
    final offered = await sendCallMessage(
      callId,
      androidOfferPacket,
      channel: 'control',
    );
    if (!offered) return false;
    return sendCallMessage(callId, androidDataPacket, channel: 'control');
  }

  Future<bool> respondRemoteClipboard({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required int promptGeneration,
    required String id,
    required bool accepted,
    required String androidPacket,
    required bool asController,
  }) async {
    if (_windowsRemoteControl) {
      final method = asController
          ? (accepted
                ? 'remoteClipboardControllerAccept'
                : 'remoteClipboardControllerReject')
          : (accepted ? 'remoteClipboardAccept' : 'remoteClipboardReject');
      final args = asController
          ? <String, Object>{
              'callId': callId,
              'peerJamiId': peerJamiId,
              'sourceRevision': sourceRevision,
              'promptGeneration': promptGeneration,
              'id': id,
            }
          : <String, Object>{'id': id, 'promptGeneration': promptGeneration};
      return (await _core.invokeMethod<bool>(method, args)) ?? false;
    }
    if (!_androidRemoteController || !asController) return false;
    return sendCallMessage(callId, androidPacket, channel: 'control');
  }

  Future<bool> allowRemoteControl({
    required String callId,
    required String controllerAccountId,
    required String controllerDeviceId,
    required int sourceRevision,
    required int hostGeneration,
    required bool persistDevice,
  }) async {
    if (!_windowsRemoteControl) return false;
    return (await _core.invokeMethod<bool>(
          persistDevice ? 'remoteControlAllowDevice' : 'remoteControlAllowOnce',
          {
            'callId': callId,
            'controllerAccountId': controllerAccountId,
            'controllerDeviceId': controllerDeviceId,
            'sourceRevision': sourceRevision,
            'hostGeneration': hostGeneration,
          },
        )) ??
        false;
  }

  Future<bool> denyRemoteControl({
    required String callId,
    required String controllerAccountId,
    required String controllerDeviceId,
    required int sourceRevision,
    required int hostGeneration,
  }) async {
    if (!_windowsRemoteControl) return false;
    return (await _core.invokeMethod<bool>('remoteControlDeny', {
          'callId': callId,
          'controllerAccountId': controllerAccountId,
          'controllerDeviceId': controllerDeviceId,
          'sourceRevision': sourceRevision,
          'hostGeneration': hostGeneration,
        })) ??
        false;
  }

  Future<bool> stopRemoteControlHost() async {
    if (!_windowsRemoteControl && !_androidRemoteController) return false;
    return (await _core.invokeMethod<bool>('remoteControlStop')) ?? false;
  }

  Future<RemoteControlHostAuthority?> remoteControlHostAuthority() async {
    if (!_windowsRemoteControl) return null;
    return RemoteControlHostAuthority.tryParse(
      await _core.invokeMethod<Object?>('remoteControlHostAuthority'),
    );
  }

  Future<RemoteControlHostAuthority?> setRemoteControlProtectedSurface({
    required int channelEpoch,
    required int surfaceRevision,
    required bool blocked,
  }) async {
    if (!_windowsRemoteControl) return null;
    return RemoteControlHostAuthority.tryParse(
      await _core.invokeMethod<Object?>('remoteControlSetProtectedSurface', {
        'channelEpoch': channelEpoch,
        'surfaceRevision': surfaceRevision,
        'blocked': blocked,
      }),
    );
  }

  Future<bool> setRemoteControlCoControl(bool enabled) async {
    if (!_windowsRemoteControl) return false;
    return (await _core.invokeMethod<bool>('remoteControlSetCoControl', {
          'enabled': enabled,
        })) ??
        false;
  }

  Future<bool> remoteControlAccessibilityEnabled() async {
    if (!_androidRemoteController) return false;
    return (await _core.invokeMethod<bool>(
          'remoteControlAccessibilityStatus',
        )) ??
        false;
  }

  Future<bool> openRemoteControlAccessibilitySettings() async {
    if (!_androidRemoteController) return false;
    return (await _core.invokeMethod<bool>(
          'openRemoteControlAccessibilitySettings',
        )) ??
        false;
  }

  /// Project annotations over this device's currently shared screen. Android
  /// uses the user-enabled accessibility overlay; Windows uses a native
  /// click-through desktop overlay. Each host revalidates the exact active
  /// local call/source revision before painting.
  Future<bool> setAnnotationOverlay(Map<String, Object?> snapshot) async {
    if (!_androidRemoteController && !_windowsRemoteControl) return false;
    return (await _core.invokeMethod<bool>('setAnnotationOverlay', snapshot)) ??
        false;
  }

  // ---- identity backup / restore (M7.5 a) ----
  /// Removes only the explicitly confirmed installation account. The host
  /// remains retired until process restart; exported/downloaded files remain.
  Future<bool> resetDoorlight(String expectedAccountId) async =>
      (await _core.invokeMethod<bool>('resetDoorlight', {
        'expectedAccountId': expectedAccountId,
      })) ??
      false;

  /// Ends a retired process (after reset, or a non-retryable engine start
  /// failure): Android relaunches itself, Windows quits (its single-instance
  /// lock forbids spawning the successor).
  Future<void> relaunchRetired() => _core.invokeMethod('relaunchRetired');
  //
  // The lost-phone safety net: export the identity archive and restore the same 40-hex.
  // Android exports to a temporary archive then copies it through SAF; Windows chooses the final path and exports
  // directly there. Native reads with the device-bound secret and writes a separate
  // snapshot with the requested output protection; it never re-keys the live archive.

  /// Back up the identity to a file the user chooses, protected when [passphrase] is non-empty. Returns true on
  /// success, false on cancel or failure.
  Future<bool> backupIdentity(
    String passphrase, {
    String settingsDocument = '',
    String? expectedAccountId,
  }) async {
    if (utf8.encode(settingsDocument).length > maxSettingsDocumentBytes) {
      return false;
    }
    return (await _core.invokeMethod<bool>('backupIdentity', {
          'passphrase': passphrase,
          'settingsDocument': settingsDocument,
          'expectedAccountId': ?expectedAccountId,
        })) ??
        false;
  }

  /// Restore an identity from an exported backup file (get [filePath] from [pickFile]). Re-imports the same 40-hex
  /// via addAccount{archivePath, archivePassword}. Native applies the supplied connectivity/privacy policy before
  /// selecting the imported account and returns the same bounded account projection as [ensureAccount].
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
    final r = await _core.invokeMethod('restoreIdentity', {
      'filePath': filePath,
      'passphrase': passphrase,
      'connectionProfile': connectionProfile,
      'dhtBootstrap': dhtBootstrap,
      'turnServer': turnServer,
      'turnRealm': turnRealm,
      'turnUser': turnUser,
      'turnPassword': turnPassword,
      'appearOffline': appearOffline,
      'expectedAccountId': expectedAccountId ?? '',
      'expectedJamiId': expectedJamiId,
    });
    return _stringKeyedMap(r);
  }

  /// Command the native journal-owned live link. No archive credentials cross
  /// this bridge, and accepting a command is never completion evidence.
  Future<Map<String, dynamic>> devicePairing({
    required String action,
    required String flowToken,
    String accountId = '',
    String expectedAccountId = '',
    String uri = '',
    String code = '',
    String settingsDocument = '',
    Map<String, String> network = const {},
    bool appearOffline = false,
  }) async {
    if (!const {
          'begin',
          'connect',
          'read',
          'approve',
          'code',
          'prepare',
          'retire',
          'discard',
        }.contains(action) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(flowToken) ||
        accountId.length > 128 ||
        expectedAccountId.length > 128 ||
        uri.length > 100 ||
        code.length > 8 ||
        utf8.encode(settingsDocument).length > maxSettingsDocumentBytes ||
        network.length > 6 ||
        network.entries.any(
          (entry) =>
              !const {
                'connectionProfile',
                'dhtBootstrap',
                'turnServer',
                'turnRealm',
                'turnUser',
                'turnPassword',
              }.contains(entry.key) ||
              entry.value.length > 4096,
        )) {
      throw const FormatException('Invalid device-link command');
    }
    return _stringKeyedMap(
      await _core.invokeMethod('devicePairing', {
        'action': action,
        'flowToken': flowToken,
        'accountId': accountId,
        'expectedAccountId': expectedAccountId,
        'uri': uri,
        'code': code,
        'settingsDocument': settingsDocument,
        'appearOffline': appearOffline,
        ...network,
      }),
    );
  }

  Future<Map<String, dynamic>> getPendingIdentityRestore() async =>
      _stringKeyedMap(await _core.invokeMethod('getPendingIdentityRestore'));

  Future<bool> discardIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String? expectedAccountId,
  }) async =>
      await _core.invokeMethod<bool>('discardIdentityRestore', {
        'accountId': accountId,
        'restoreToken': restoreToken,
        'expectedAccountId': expectedAccountId ?? '',
      }) ??
      false;

  /// Activate only an exact prepared identity after its normalized privacy
  /// document is durable. Native performs the final owner and policy checks.
  Future<Map<String, dynamic>> finalizeIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String settingsDocument,
  }) async {
    if (utf8.encode(settingsDocument).length > maxSettingsDocumentBytes) {
      throw const FormatException('restored settings exceed the native limit');
    }
    return _stringKeyedMap(
      await _core.invokeMethod('finalizeIdentityRestore', {
        'accountId': accountId,
        'restoreToken': restoreToken,
        'settingsDocument': settingsDocument,
      }),
    );
  }
}
