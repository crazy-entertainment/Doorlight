import 'dart:convert';
import 'dart:math';

import 'app_settings.dart';
import 'outgoing_video.dart';

final class GroupActiveCall {
  const GroupActiveCall({
    required this.conferenceId,
    required this.hostUri,
    required this.hostDevice,
  });

  final String conferenceId;
  final String hostUri;
  final String hostDevice;

  @override
  bool operator ==(Object other) =>
      other is GroupActiveCall &&
      conferenceId == other.conferenceId &&
      hostUri == other.hostUri &&
      hostDevice == other.hostDevice;

  @override
  int get hashCode => Object.hash(conferenceId, hostUri, hostDevice);
}

final class GroupCallPlacement {
  const GroupCallPlacement({
    required this.conferenceId,
    required this.callId,
    required this.hosting,
  });

  final String conferenceId;
  final String callId;
  final bool hosting;

  bool get succeeded => conferenceId.isNotEmpty;
}

enum GroupCallPhase { joining, connected, recovering, leaving, failed }

final class GroupCallSession {
  GroupCallSession({
    required this.conversationId,
    required this.roomId,
    required this.conferenceId,
    required this.sessionId,
    this.callId = '',
    this.hosting = false,
    this.phase = GroupCallPhase.joining,
    this.micMuted = false,
    this.micMode = MicrophoneMode.open,
    this.manuallyMuted = false,
    this.pushToTalkPressed = false,
    this.deafened = false,
    this.video = false,
    this.screenShare = false,
    this.screenSourceId,
    this.mediaRestorePending = false,
    this.mediaRestoreInFlight = false,
    this.speakerOn = false,
    this.speaking = false,
    this.videoActive = false,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.sourceChanging = false,
    this.sourceChangeKind,
    this.conference = const GroupConferenceSnapshot([]),
    this.videoTextureId,
    this.focusedStreamKey,
    this.recoveryAttempts = 0,
    this.retryAtMs = 0,
    Set<String>? failedConferenceIds,
    this.error,
  }) : acknowledgedMicrophoneMuted = micMuted,
       failedConferenceIds = failedConferenceIds ?? <String>{};

  final String conversationId;
  final String roomId;
  String conferenceId;
  final String sessionId;
  String callId;
  bool hosting;
  GroupCallPhase phase;
  bool micMuted;
  bool? acknowledgedMicrophoneMuted;
  MicrophoneMode micMode;
  bool manuallyMuted;
  int manualMuteRevision = 0;
  bool pushToTalkPressed;
  bool deafened;
  bool? acknowledgedDeafened = false;
  bool video;
  bool screenShare;
  String? screenSourceId;
  bool mediaRestorePending;
  bool mediaRestoreInFlight;
  bool speakerOn;
  bool speaking;
  bool videoActive;
  int videoWidth;
  int videoHeight;
  bool sourceChanging;
  OutgoingVideoKind? sourceChangeKind;
  GroupConferenceSnapshot conference;
  int? videoTextureId;
  String? focusedStreamKey;
  int recoveryAttempts;
  bool connectionAnnounced = false;
  bool nativePlacementIssued = false;
  bool replacementInProgress = false;
  String reservationId = '';
  int retryAtMs;
  final Set<String> failedConferenceIds;
  String? error;

  bool get connected => phase == GroupCallPhase.connected;
  bool get hasVideo =>
      video || screenShare || videoActive || conference.videoStreams.isNotEmpty;
  double get videoAspectRatio => videoWidth > 0 && videoHeight > 0
      ? videoWidth / videoHeight
      : conference.primary?.aspectRatio ?? 16 / 9;
}

final class GroupConferenceAddress {
  const GroupConferenceAddress._(this.roomId, this.conferenceId);

  static final RegExp _roomId = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');
  static final RegExp _conferenceId = RegExp(
    r'^syblv1-([a-z0-9][a-z0-9-]{0,31})-([1-9][0-9]{0,19})$',
  );

  final String roomId;
  final String conferenceId;

  factory GroupConferenceAddress.create({
    required String roomId,
    String? randomSuffix,
  }) {
    if (!_roomId.hasMatch(roomId)) {
      throw ArgumentError.value(roomId, 'roomId', 'invalid voice room id');
    }
    final suffix = randomSuffix ?? _randomSuffix();
    final value = 'syblv1-$roomId-$suffix';
    return tryParse(value) ??
        (throw ArgumentError.value(suffix, 'randomSuffix', 'invalid suffix'));
  }

  static GroupConferenceAddress? tryParse(String value) {
    final match = _conferenceId.firstMatch(value);
    if (match == null) return null;
    return GroupConferenceAddress._(match.group(1)!, value);
  }

  static GroupActiveCall? chooseCanonical(
    Iterable<GroupActiveCall> calls, {
    required String roomId,
    Set<String> excludedConferenceIds = const {},
  }) {
    final matching = calls
        .where(
          (call) =>
              tryParse(call.conferenceId)?.roomId == roomId &&
              !excludedConferenceIds.contains(call.conferenceId) &&
              call.hostUri.isNotEmpty &&
              call.hostDevice.isNotEmpty,
        )
        .toList();
    if (matching.isEmpty) return null;
    return matching.last;
  }

  static String _randomSuffix() {
    final random = Random.secure();
    final value =
        (BigInt.from(random.nextInt(1 << 31)) << 31) |
        BigInt.from(random.nextInt(1 << 31));
    return (value + BigInt.one).toString();
  }
}

final class GroupCallPresence {
  const GroupCallPresence({
    required this.conversationId,
    required this.roomId,
    required this.conferenceId,
    required this.accountId,
    required this.sessionId,
    required this.sequence,
    required this.joined,
    required this.muted,
    required this.deafened,
    required this.video,
    required this.screenShare,
    required this.speaking,
  });

  static const int maxPayloadBytes = 2048;
  static final RegExp _accountId = RegExp(r'^[0-9a-f]{40,128}$');
  static final RegExp _sessionId = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  final String conversationId;
  final String roomId;
  final String conferenceId;
  final String accountId;
  final String sessionId;
  final int sequence;
  final bool joined;
  final bool muted;
  final bool deafened;
  final bool video;
  final bool screenShare;
  final bool speaking;

  GroupCallPresence copyWith({String? conferenceId}) => GroupCallPresence(
    conversationId: conversationId,
    roomId: roomId,
    conferenceId: conferenceId ?? this.conferenceId,
    accountId: accountId,
    sessionId: sessionId,
    sequence: sequence,
    joined: joined,
    muted: muted,
    deafened: deafened,
    video: video,
    screenShare: screenShare,
    speaking: speaking,
  );

  String encode() => jsonEncode({
    'v': 1,
    'g': conversationId,
    'r': roomId,
    'c': conferenceId,
    'a': accountId,
    's': sessionId,
    'q': sequence,
    'j': joined,
    'm': muted,
    'd': deafened,
    'x': video,
    'h': screenShare,
    'p': speaking,
  });

  static GroupCallPresence? decode(
    String payload, {
    required String senderAccountId,
    required String conversationId,
    required Set<String> voiceRoomIds,
  }) {
    if (utf8.encode(payload).length > maxPayloadBytes ||
        !_accountId.hasMatch(senderAccountId) ||
        !_accountId.hasMatch(conversationId)) {
      return null;
    }
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map<String, dynamic> ||
          raw['v'] != 1 ||
          raw['g'] != conversationId ||
          raw['a'] != senderAccountId ||
          raw['r'] is! String ||
          !voiceRoomIds.contains(raw['r']) ||
          raw['c'] is! String ||
          GroupConferenceAddress.tryParse(raw['c'])?.roomId != raw['r'] ||
          raw['s'] is! String ||
          !_sessionId.hasMatch(raw['s']) ||
          raw['q'] is! int ||
          raw['q'] < 0 ||
          raw['q'] > 0x7fffffff ||
          raw['j'] is! bool ||
          raw['m'] is! bool ||
          raw['d'] is! bool ||
          raw['x'] is! bool ||
          raw['h'] is! bool ||
          raw['p'] is! bool) {
        return null;
      }
      return GroupCallPresence(
        conversationId: conversationId,
        roomId: raw['r'],
        conferenceId: raw['c'],
        accountId: senderAccountId,
        sessionId: raw['s'],
        sequence: raw['q'],
        joined: raw['j'],
        muted: raw['m'],
        deafened: raw['d'],
        video: raw['x'],
        screenShare: raw['h'],
        speaking: raw['p'],
      );
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GroupCallPresence &&
      conversationId == other.conversationId &&
      roomId == other.roomId &&
      conferenceId == other.conferenceId &&
      accountId == other.accountId &&
      sessionId == other.sessionId &&
      sequence == other.sequence &&
      joined == other.joined &&
      muted == other.muted &&
      deafened == other.deafened &&
      video == other.video &&
      screenShare == other.screenShare &&
      speaking == other.speaking;

  @override
  int get hashCode => Object.hash(
    conversationId,
    roomId,
    conferenceId,
    accountId,
    sessionId,
    sequence,
    joined,
    muted,
    deafened,
    video,
    screenShare,
    speaking,
  );
}

final class GroupRoomParticipant {
  const GroupRoomParticipant({
    required this.accountId,
    required this.muted,
    required this.deafened,
    required this.video,
    required this.screenShare,
    required this.speaking,
  });

  final String accountId;
  final bool muted;
  final bool deafened;
  final bool video;
  final bool screenShare;
  final bool speaking;
}

final class GroupCallPresenceBook {
  static const int defaultTtlMs = 45000;
  // Bound transient session metadata, including recent leave sequence markers.
  // Existing sessions can still update at capacity. Do not evict live entries
  // to admit a flood of new identifiers, or alter the established expiry time.
  static const int maxSessionsPerMember = 32;
  static const int maxSessions = 1024;
  final Map<String, _PresenceEntry> _sessions = {};

  bool get isEmpty => _sessions.isEmpty;

  bool prune({required int nowMs, int ttlMs = defaultTtlMs}) {
    final before = _sessions.length;
    _sessions.removeWhere((_, entry) => nowMs - entry.arrivedAtMs > ttlMs);
    return _sessions.length != before;
  }

  bool accept(GroupCallPresence value, int arrivedAtMs) {
    prune(nowMs: arrivedAtMs);
    final key = '${value.accountId}\u0000${value.sessionId}';
    final old = _sessions[key];
    if (old != null && value.sequence <= old.value.sequence) return false;
    if (old == null &&
        (_sessions.length >= maxSessions ||
            _sessions.values
                    .where((entry) => entry.value.accountId == value.accountId)
                    .length >=
                maxSessionsPerMember)) {
      return false;
    }
    _sessions[key] = _PresenceEntry(value, arrivedAtMs);
    return true;
  }

  bool isJoined(
    String accountId,
    String conversationId,
    String roomId, {
    required int nowMs,
    int ttlMs = defaultTtlMs,
  }) {
    prune(nowMs: nowMs, ttlMs: ttlMs);
    return _sessions.values.any(
      (entry) =>
          entry.value.accountId == accountId &&
          entry.value.conversationId == conversationId &&
          entry.value.roomId == roomId &&
          entry.value.joined,
    );
  }

  List<GroupRoomParticipant> participants(
    String conversationId,
    String roomId, {
    required int nowMs,
    int ttlMs = defaultTtlMs,
  }) {
    final byAccount = <String, List<GroupCallPresence>>{};
    prune(nowMs: nowMs, ttlMs: ttlMs);
    for (final entry in _sessions.values) {
      final value = entry.value;
      if (!value.joined ||
          value.conversationId != conversationId ||
          value.roomId != roomId) {
        continue;
      }
      byAccount.putIfAbsent(value.accountId, () => []).add(value);
    }
    final result = [
      for (final entry in byAccount.entries)
        GroupRoomParticipant(
          accountId: entry.key,
          muted: entry.value.every((value) => value.muted),
          deafened: entry.value.every((value) => value.deafened),
          video: entry.value.any((value) => value.video),
          screenShare: entry.value.any((value) => value.screenShare),
          speaking: entry.value.any((value) => value.speaking),
        ),
    ]..sort((a, b) => a.accountId.compareTo(b.accountId));
    return List.unmodifiable(result);
  }
}

final class _PresenceEntry {
  const _PresenceEntry(this.value, this.arrivedAtMs);
  final GroupCallPresence value;
  final int arrivedAtMs;
}

final class GroupConferenceStream {
  const GroupConferenceStream({
    required this.accountId,
    required this.deviceId,
    required this.sinkId,
    required this.width,
    required this.height,
    required this.videoMuted,
    required this.speaking,
    required this.active,
    required this.moderator,
    required this.selfAudioMuted,
    required this.moderatorAudioMuted,
  });

  final String accountId;
  final String deviceId;
  final String sinkId;
  final int width;
  final int height;
  final bool videoMuted;
  final bool speaking;
  final bool active;
  final bool moderator;
  final bool selfAudioMuted;
  final bool moderatorAudioMuted;

  String get key => '$accountId\u0000$deviceId\u0000$sinkId';
  bool get hasVideo => !videoMuted && width > 0 && height > 0;
  bool get audioMuted => selfAudioMuted || moderatorAudioMuted;
  double? get aspectRatio => hasVideo ? width / height : null;
}

final class GroupConferenceSnapshot {
  const GroupConferenceSnapshot(this.streams);

  static const maxStreams = 128;
  static const maxFields = 32;
  static const maxFieldBytes = 1024;
  static const maxTotalBytes = 64 * 1024;
  static const maxEncodedLength = 512 * 1024;

  static final RegExp _accountId = RegExp(r'^[0-9a-f]{40,128}$');
  static final RegExp _deviceId = RegExp(r'^[0-9a-f]{8,128}$');

  final List<GroupConferenceStream> streams;

  List<GroupConferenceStream> get videoStreams =>
      List.unmodifiable(streams.where((stream) => stream.hasVideo));

  GroupConferenceStream? get primary => videoStreams.firstOrNull;

  factory GroupConferenceSnapshot.fromWire(Iterable<Object?> values) {
    final parsed = <GroupConferenceStream>[];
    final keys = <String>{};
    var count = 0;
    var bytes = 0;
    for (final value in values) {
      if (++count > maxStreams) return const GroupConferenceSnapshot([]);
      if (value is! Map) continue;
      if (value.length > maxFields) return const GroupConferenceSnapshot([]);
      for (final entry in value.entries) {
        if (entry.key is! String ||
            (entry.value is! String &&
                entry.value is! bool &&
                entry.value is! num)) {
          return const GroupConferenceSnapshot([]);
        }
        final key = entry.key as String;
        final field = entry.value.toString();
        if (key.length > maxFieldBytes || field.length > maxFieldBytes) {
          return const GroupConferenceSnapshot([]);
        }
        final keyBytes = utf8.encode(key).length;
        final fieldBytes = utf8.encode(field).length;
        bytes += keyBytes + fieldBytes;
        if (keyBytes > maxFieldBytes ||
            fieldBytes > maxFieldBytes ||
            bytes > maxTotalBytes) {
          return const GroupConferenceSnapshot([]);
        }
      }
      final uri = '${value['uri'] ?? ''}'
          .replaceFirst(RegExp(r'^jami:'), '')
          .split('@')
          .first;
      final device = '${value['device'] ?? ''}';
      final sink = '${value['sinkId'] ?? ''}';
      final width = int.tryParse('${value['w'] ?? ''}') ?? 0;
      final height = int.tryParse('${value['h'] ?? ''}') ?? 0;
      if (!_accountId.hasMatch(uri) ||
          !_deviceId.hasMatch(device) ||
          sink.isEmpty ||
          sink.length > 256 ||
          width < 0 ||
          height < 0 ||
          width > 16384 ||
          height > 16384) {
        continue;
      }
      bool flag(String key) => value[key] == true || value[key] == 'true';
      if (!keys.add('$uri/$device/$sink')) {
        return const GroupConferenceSnapshot([]);
      }
      parsed.add(
        GroupConferenceStream(
          accountId: uri,
          deviceId: device,
          sinkId: sink,
          width: width,
          height: height,
          videoMuted: flag('videoMuted'),
          speaking: flag('voiceActivity'),
          active: flag('active'),
          moderator: flag('isModerator'),
          selfAudioMuted: flag('audioLocalMuted'),
          moderatorAudioMuted: flag('audioModeratorMuted'),
        ),
      );
    }
    parsed.sort((a, b) {
      final active = (b.active ? 1 : 0).compareTo(a.active ? 1 : 0);
      if (active != 0) return active;
      final speaking = (b.speaking ? 1 : 0).compareTo(a.speaking ? 1 : 0);
      if (speaking != 0) return speaking;
      final account = a.accountId.compareTo(b.accountId);
      if (account != 0) return account;
      final device = a.deviceId.compareTo(b.deviceId);
      return device != 0 ? device : a.sinkId.compareTo(b.sinkId);
    });
    return GroupConferenceSnapshot(List.unmodifiable(parsed));
  }
}

abstract final class GroupCallRecovery {
  static const int maxAttempts = 3;

  static int delayMs(String accountId, int attempt) {
    final prefix = accountId.length >= 8 ? accountId.substring(0, 8) : '0';
    final stable = int.tryParse(prefix, radix: 16) ?? 0;
    return 250 + stable % 750 + attempt.clamp(0, maxAttempts) * 1000;
  }
}
