import 'dart:convert';
import 'dart:math';

import 'conversation_scope.dart';

/// Opaque, process-local authorization handle presented to a companion widget.
/// It is intentionally not a Jami identifier and cannot be reused after the
/// owning overlay session is retired.
final class WidgetChatConversation {
  const WidgetChatConversation({
    required this.token,
    required this.scope,
    required this.label,
    required this.kind,
    this.draftKey = '',
  });

  final String token;
  final ConversationScope scope;
  final String label;
  final String kind;
  // Identifies local drafts, never grants command authority.
  final String draftKey;

  Map<String, Object?> toMap() => {
    'id': token,
    'label': label,
    'kind': kind,
    'draftKey': draftKey,
  };
}

final class WidgetVoiceTarget {
  const WidgetVoiceTarget({
    required this.token,
    required this.kind,
    required this.accountRevision,
    required this.identity,
    this.scope,
    this.roomId,
  });

  final String token;
  final String kind;
  final int accountRevision;
  final String identity;
  final ConversationScope? scope;
  final String? roomId;
}

String createWidgetToken() {
  final bytes = List<int>.generate(24, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes);
}

bool isWidgetNativeRevision(Object? value) =>
    value is String && RegExp(r'^\d{1,20}$').hasMatch(value);

bool isTrustedWidgetRemoteAudioMeter({
  required String expectedAccountId,
  required String eventAccountId,
  required String expectedCallId,
  required String eventCallId,
  required String? expectedNativeRevision,
  required String eventNativeRevision,
  required String eventStreamId,
  required double? level,
}) =>
    expectedAccountId.isNotEmpty &&
    eventAccountId == expectedAccountId &&
    expectedCallId.isNotEmpty &&
    eventCallId == expectedCallId &&
    expectedNativeRevision != null &&
    eventNativeRevision == expectedNativeRevision &&
    eventStreamId.length <= 256 &&
    eventStreamId.startsWith('${expectedCallId}_') &&
    RegExp(
      r'^[A-Za-z0-9_-]{1,128}$',
    ).hasMatch(eventStreamId.substring(expectedCallId.length + 1)) &&
    level != null &&
    level.isFinite &&
    level >= 0 &&
    level <= 1;

bool? widgetRemoteSpeakingAt({
  required double? level,
  required DateTime? sampledAt,
  required DateTime now,
}) {
  if (level == null ||
      !level.isFinite ||
      level < 0 ||
      level > 1 ||
      sampledAt == null ||
      now.difference(sampledAt) >= const Duration(seconds: 1) ||
      now.isBefore(sampledAt)) {
    return null;
  }
  return level >= .02;
}
