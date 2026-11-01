import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'conversation_scope.dart';
import 'dm_topics.dart';
import 'rich_content.dart';
import 'message_reactions.dart';

abstract final class TimelineWireContract {
  static const String textMimeType = 'text/plain';
  static const String fileMimeType = 'application/data-transfer+json';

  static const int maxDaemonIdCodeUnits = 1024;
  static const int maxAuthorIdCodeUnits = 1024;
  static const int maxTextCodeUnits = 64 * 1024;
  static const int maxFileIdCodeUnits = 4096;
  static const int maxDisplayNameCodeUnits = 1024;
  static const int maxHashCodeUnits = 256;
  static const int maxGroupReceiptMembers = 63;
  static const int maxSnapshotItems = 500;
  static const int maxSnapshotEncodedBytes = 8 * 1024 * 1024;
}

enum TimelineDirection { incoming, outgoing }

enum TimelineDeliveryState { sent, delivered, read }

sealed class ConversationTimelineItem {
  const ConversationTimelineItem({
    required this.scope,
    required this.daemonId,
    required this.versionId,
    required this.authorId,
    required this.direction,
    required this.createdAt,
    this.deliveryState = TimelineDeliveryState.sent,
    this.readByMemberIds = const {},
    this.topicId = DmTopicWire.mainId,
    this.topicTagged = false,
    this.linearizedParent = '',
    this.operationId,
    this.roomId,
    this.replyTo = '',
    this.reactions = MessageReactions.empty,
  });

  final ConversationScope scope;
  final String daemonId;
  final String versionId;
  final String authorId;
  final TimelineDirection direction;
  final DateTime createdAt;
  final TimelineDeliveryState deliveryState;
  final Set<String> readByMemberIds;
  final String topicId;
  final bool topicTagged;
  final String linearizedParent;
  final String? operationId;
  final String? roomId;

  /// Authenticated Jami commit reference. Any preview must resolve local history.
  final String replyTo;
  final MessageReactions reactions;

  String get mimeType;

  /// Returns a deterministic union for duplicate daemon ids, or null when the
  /// two values cannot represent the same daemon interaction.
  ConversationTimelineItem? mergeCompatible(ConversationTimelineItem other);

  ConversationTimelineItem withDeliveryState(
    TimelineDeliveryState state, {
    Set<String>? readByMemberIds,
    MessageReactions? reactionSnapshot,
  });

  bool hasSameEnvelope(ConversationTimelineItem other) =>
      scope == other.scope &&
      daemonId == other.daemonId &&
      versionId == other.versionId &&
      authorId == other.authorId &&
      direction == other.direction &&
      createdAt == other.createdAt &&
      topicId == other.topicId &&
      topicTagged == other.topicTagged &&
      operationId == other.operationId &&
      roomId == other.roomId &&
      replyTo == other.replyTo &&
      linearizedParent == other.linearizedParent;

  bool hasSameInteraction(ConversationTimelineItem other) =>
      scope == other.scope &&
      daemonId == other.daemonId &&
      authorId == other.authorId &&
      direction == other.direction &&
      createdAt == other.createdAt;
}

final class TimelineTextItem extends ConversationTimelineItem {
  const TimelineTextItem({
    required super.scope,
    required super.daemonId,
    required super.versionId,
    required super.authorId,
    required super.direction,
    required super.createdAt,
    super.deliveryState,
    super.readByMemberIds,
    super.topicId,
    super.topicTagged,
    super.linearizedParent,
    super.operationId,
    super.roomId,
    super.replyTo,
    super.reactions,
    required this.text,
  });

  final String text;

  @override
  String get mimeType => TimelineWireContract.textMimeType;

  @override
  TimelineTextItem? mergeCompatible(ConversationTimelineItem other) {
    if (other is! TimelineTextItem || !hasSameEnvelope(other)) return null;
    if (text != other.text) return null;
    return withDeliveryState(
      deliveryState.index > other.deliveryState.index
          ? deliveryState
          : other.deliveryState,
      readByMemberIds: Set.unmodifiable({
        ...readByMemberIds,
        ...other.readByMemberIds,
      }),
    );
  }

  @override
  TimelineTextItem withDeliveryState(
    TimelineDeliveryState state, {
    Set<String>? readByMemberIds,
    MessageReactions? reactionSnapshot,
  }) => TimelineTextItem(
    scope: scope,
    daemonId: daemonId,
    versionId: versionId,
    authorId: authorId,
    direction: direction,
    createdAt: createdAt,
    deliveryState: state,
    readByMemberIds: readByMemberIds ?? this.readByMemberIds,
    topicId: topicId,
    topicTagged: topicTagged,
    linearizedParent: linearizedParent,
    text: text,
    operationId: operationId,
    roomId: roomId,
    replyTo: replyTo,
    reactions: reactionSnapshot ?? reactions,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineTextItem &&
          hasSameEnvelope(other) &&
          reactions == other.reactions &&
          deliveryState == other.deliveryState &&
          setEquals(readByMemberIds, other.readByMemberIds) &&
          text == other.text;

  @override
  int get hashCode => Object.hash(
    scope,
    daemonId,
    versionId,
    authorId,
    direction,
    createdAt,
    deliveryState,
    Object.hashAllUnordered(readByMemberIds),
    topicId,
    topicTagged,
    linearizedParent,
    text,
  );
}

final class TimelineFileItem extends ConversationTimelineItem {
  const TimelineFileItem({
    required super.scope,
    required super.daemonId,
    required super.versionId,
    required super.authorId,
    required super.direction,
    required super.createdAt,
    super.deliveryState,
    super.readByMemberIds,
    super.topicId,
    super.topicTagged,
    super.linearizedParent,
    super.operationId,
    super.roomId,
    super.replyTo,
    super.reactions,
    this.mediaMetadata,
    required this.fileId,
    required this.displayName,
    required this.totalBytes,
    required this.sha3,
    required this.downloaded,
  });

  final String fileId;
  final String displayName;
  final int? totalBytes;
  final String? sha3;
  final bool downloaded;

  /// Bounded signed metadata. Unsupported versions remain ordinary files.
  final String? mediaMetadata;
  FileMediaContent? get media => FileMediaContent.parse(mediaMetadata);

  /// A picker hint, never proof of format or native transfer completion.
  bool get mayContainGif =>
      media is GifMediaContent ||
      ((mediaMetadata == null || mediaMetadata!.isEmpty) &&
          displayName.toLowerCase().endsWith('.gif'));

  @override
  String get mimeType => TimelineWireContract.fileMimeType;

  @override
  TimelineFileItem? mergeCompatible(ConversationTimelineItem other) {
    if (other is! TimelineFileItem ||
        !hasSameEnvelope(other) ||
        fileId != other.fileId) {
      return null;
    }
    if (displayName != other.displayName ||
        mediaMetadata != other.mediaMetadata ||
        (totalBytes != null &&
            other.totalBytes != null &&
            totalBytes != other.totalBytes) ||
        (sha3 != null && other.sha3 != null && sha3 != other.sha3)) {
      return null;
    }
    return TimelineFileItem(
      scope: scope,
      daemonId: daemonId,
      versionId: versionId,
      authorId: authorId,
      direction: direction,
      createdAt: createdAt,
      deliveryState: deliveryState.index >= other.deliveryState.index
          ? deliveryState
          : other.deliveryState,
      readByMemberIds: Set.unmodifiable({
        ...readByMemberIds,
        ...other.readByMemberIds,
      }),
      topicId: topicId,
      topicTagged: topicTagged,
      linearizedParent: linearizedParent,
      fileId: fileId,
      displayName: displayName,
      totalBytes: totalBytes ?? other.totalBytes,
      sha3: sha3 ?? other.sha3,
      downloaded: downloaded || other.downloaded,
      operationId: operationId,
      roomId: roomId,
      replyTo: replyTo,
      reactions: reactions,
      mediaMetadata: mediaMetadata,
    );
  }

  @override
  TimelineFileItem withDeliveryState(
    TimelineDeliveryState state, {
    Set<String>? readByMemberIds,
    MessageReactions? reactionSnapshot,
  }) => TimelineFileItem(
    scope: scope,
    daemonId: daemonId,
    versionId: versionId,
    authorId: authorId,
    direction: direction,
    createdAt: createdAt,
    deliveryState: state,
    readByMemberIds: readByMemberIds ?? this.readByMemberIds,
    topicId: topicId,
    topicTagged: topicTagged,
    linearizedParent: linearizedParent,
    fileId: fileId,
    displayName: displayName,
    totalBytes: totalBytes,
    sha3: sha3,
    downloaded: downloaded,
    operationId: operationId,
    roomId: roomId,
    replyTo: replyTo,
    reactions: reactionSnapshot ?? reactions,
    mediaMetadata: mediaMetadata,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineFileItem &&
          hasSameEnvelope(other) &&
          reactions == other.reactions &&
          deliveryState == other.deliveryState &&
          setEquals(readByMemberIds, other.readByMemberIds) &&
          fileId == other.fileId &&
          displayName == other.displayName &&
          totalBytes == other.totalBytes &&
          sha3 == other.sha3 &&
          mediaMetadata == other.mediaMetadata &&
          downloaded == other.downloaded;

  @override
  int get hashCode => Object.hash(
    scope,
    daemonId,
    versionId,
    authorId,
    direction,
    createdAt,
    deliveryState,
    Object.hashAllUnordered(readByMemberIds),
    topicId,
    topicTagged,
    linearizedParent,
    fileId,
    displayName,
    totalBytes,
    sha3,
    downloaded,
  );
}

/// Unknown built-in IDs or future bounded sticker bodies stay visible as a
/// neutral placeholder. They never cause a fetch or native presentation.
final class TimelineStickerItem extends ConversationTimelineItem {
  const TimelineStickerItem({
    required super.scope,
    required super.daemonId,
    required super.versionId,
    required super.authorId,
    required super.direction,
    required super.createdAt,
    super.deliveryState,
    super.readByMemberIds,
    super.topicId,
    super.topicTagged,
    super.linearizedParent,
    super.operationId,
    super.roomId,
    super.replyTo,
    super.reactions,
    required this.body,
  });

  final String body;
  StickerContent? get sticker => StickerContent.parse(body);
  @override
  String get mimeType => RichContentWire.stickerMime;

  @override
  TimelineStickerItem? mergeCompatible(ConversationTimelineItem other) {
    if (other is! TimelineStickerItem ||
        !hasSameEnvelope(other) ||
        body != other.body) {
      return null;
    }
    return withDeliveryState(
      deliveryState.index >= other.deliveryState.index
          ? deliveryState
          : other.deliveryState,
      readByMemberIds: Set.unmodifiable({
        ...readByMemberIds,
        ...other.readByMemberIds,
      }),
    );
  }

  @override
  TimelineStickerItem withDeliveryState(
    TimelineDeliveryState state, {
    Set<String>? readByMemberIds,
    MessageReactions? reactionSnapshot,
  }) => TimelineStickerItem(
    scope: scope,
    daemonId: daemonId,
    versionId: versionId,
    authorId: authorId,
    direction: direction,
    createdAt: createdAt,
    deliveryState: state,
    readByMemberIds: readByMemberIds ?? this.readByMemberIds,
    topicId: topicId,
    topicTagged: topicTagged,
    linearizedParent: linearizedParent,
    operationId: operationId,
    roomId: roomId,
    replyTo: replyTo,
    reactions: reactionSnapshot ?? reactions,
    body: body,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineStickerItem &&
          hasSameEnvelope(other) &&
          reactions == other.reactions &&
          body == other.body &&
          deliveryState == other.deliveryState &&
          setEquals(readByMemberIds, other.readByMemberIds);
  @override
  int get hashCode => Object.hash(
    scope,
    daemonId,
    versionId,
    body,
    deliveryState,
    Object.hashAllUnordered(readByMemberIds),
    operationId,
    roomId,
  );
}

final class TimelineDmTopicEventItem extends ConversationTimelineItem {
  const TimelineDmTopicEventItem({
    required super.scope,
    required super.daemonId,
    required super.versionId,
    required super.authorId,
    required super.direction,
    required super.createdAt,
    required super.linearizedParent,
    required this.eventBody,
  });

  final String eventBody;

  @override
  String get mimeType => DmTopicWire.mimeType;

  @override
  TimelineDmTopicEventItem? mergeCompatible(ConversationTimelineItem other) {
    if (other is! TimelineDmTopicEventItem ||
        !hasSameEnvelope(other) ||
        eventBody != other.eventBody) {
      return null;
    }
    return this;
  }

  @override
  TimelineDmTopicEventItem withDeliveryState(
    TimelineDeliveryState state, {
    Set<String>? readByMemberIds,
    MessageReactions? reactionSnapshot,
  }) => this;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineDmTopicEventItem &&
          hasSameEnvelope(other) &&
          reactions == other.reactions &&
          eventBody == other.eventBody;

  @override
  int get hashCode => Object.hash(
    scope,
    daemonId,
    versionId,
    authorId,
    direction,
    createdAt,
    linearizedParent,
    eventBody,
  );
}

enum TimelineParseFailure {
  malformedScope,
  scopeMismatch,
  malformedEnvelope,
  unexpectedAuthor,
  unsupportedMimeType,
  malformedText,
  malformedFile,
  malformedTopic,
  malformedTopicEvent,
}

enum TimelineMutationKind { snapshot, edit, delete }

/// One parsed daemon interaction or tombstone.
///
/// `edit` is valid only for the live `SwarmMessageUpdated` route. History is a
/// folded snapshot and must use `snapshot`; an empty text body is always a
/// `delete` tombstone.
final class TimelineMutation {
  const TimelineMutation({
    required this.kind,
    required this.scope,
    required this.daemonId,
    required this.versionId,
    required this.authorId,
    required this.direction,
    required this.createdAt,
    required this.item,
  });

  final TimelineMutationKind kind;
  final ConversationScope scope;
  final String daemonId;
  final String versionId;
  final String authorId;
  final TimelineDirection direction;
  final DateTime createdAt;
  final ConversationTimelineItem? item;
}

final class TimelineParseResult {
  const TimelineParseResult.accepted(this.mutation) : failure = null;
  const TimelineParseResult.rejected(this.failure) : mutation = null;

  final TimelineMutation? mutation;
  final TimelineParseFailure? failure;

  ConversationTimelineItem? get item => mutation?.item;
  bool get isAccepted => mutation != null;
}

/// Parses the normalized native-to-Dart timeline contract.
///
/// The integration adapter must provide:
/// - `accountId`, `peerId`, `conversationId`
/// - `daemonId`
/// - `versionId = latestEditionId.isEmpty ? daemonId : latestEditionId`
/// - `mimeType`, `authorId`, and the daemon body's Unix `timestamp` exposed as
///   `timestampSeconds`
/// - optional `operation: edit` only for `SwarmMessageUpdated`; omitted means
///   a history/live snapshot
/// - optional `deleted: true` for an adapter-level tombstone
/// - optional `readByMemberIds` only for an outgoing group interaction
/// - a String `body` for text, or a map containing `fileId`,
///   `displayName`, optional `totalBytes`, `sha3`, and `downloaded` for files.
final class TimelineItemParser {
  const TimelineItemParser();

  TimelineParseResult parse({
    required ConversationScope expectedScope,
    required String localAuthorId,
    Set<String>? allowedRemoteAuthorIds,
    required Map<String, Object?> value,
  }) {
    final scope = ConversationScope.tryParse(value);
    if (scope == null) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.malformedScope,
      );
    }
    if (scope != expectedScope) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.scopeMismatch,
      );
    }

    final daemonId = _boundedString(
      value['daemonId'],
      TimelineWireContract.maxDaemonIdCodeUnits,
    );
    final versionId = _boundedString(
      value['versionId'],
      TimelineWireContract.maxDaemonIdCodeUnits,
    );
    final authorId = _boundedString(
      value['authorId'],
      TimelineWireContract.maxAuthorIdCodeUnits,
    );
    final validLocalAuthorId = _boundedString(
      localAuthorId,
      TimelineWireContract.maxAuthorIdCodeUnits,
    );
    final mimeType = value['mimeType'];
    final timestampSeconds = _timestampSeconds(value['timestampSeconds']);
    final operation = switch (value['operation']) {
      null || 'snapshot' => TimelineMutationKind.snapshot,
      'edit' => TimelineMutationKind.edit,
      _ => null,
    };
    final deletedValue = value['deleted'];
    final deleted = deletedValue == null ? false : _strictBool(deletedValue);
    if (daemonId == null ||
        versionId == null ||
        authorId == null ||
        validLocalAuthorId == null ||
        mimeType is! String ||
        timestampSeconds == null ||
        operation == null ||
        deleted == null) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.malformedEnvelope,
      );
    }
    final rawTopicId = value['topicId'] ?? DmTopicWire.mainId;
    final topicTaggedValue = value['topicTagged'];
    final topicTagged = topicTaggedValue == null
        ? false
        : _strictBool(topicTaggedValue);
    final linearizedParentValue = value['linearizedParent'] ?? '';
    final topicId =
        rawTopicId is String &&
            (rawTopicId == DmTopicWire.mainId ||
                DmTopicWire.isCustomId(rawTopicId))
        ? rawTopicId
        : null;
    final linearizedParent =
        linearizedParentValue is String &&
            linearizedParentValue.length <=
                TimelineWireContract.maxDaemonIdCodeUnits
        ? linearizedParentValue
        : null;
    if (topicId == null ||
        topicTagged == null ||
        linearizedParent == null ||
        (!topicTagged && topicId != DmTopicWire.mainId)) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.malformedTopic,
      );
    }

    final remoteAuthors = allowedRemoteAuthorIds ?? {scope.peerId};
    // This flag is constructed by the native Jami projector from an owned
    // authenticated swarm commit, never copied from its content fields.
    final historicalGroupAuthor =
        scope.isGroup && value['authenticatedGroupHistory'] == true;
    final operationId = value['operationId'];
    final roomId = value['roomId'];
    final rawReplyTo = value['replyTo'];
    final replyTo = rawReplyTo == null || rawReplyTo == ''
        ? ''
        : _boundedString(rawReplyTo, TimelineWireContract.maxDaemonIdCodeUnits);
    final reactions = mimeType == DmTopicWire.mimeType
        ? MessageReactions.empty
        : MessageReactions.fromWire(value['reactions'], messageId: daemonId);
    if (replyTo == null || reactions == null) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.malformedEnvelope,
      );
    }
    if (!historicalGroupAuthor &&
        reactions.entries.any(
          (reaction) =>
              reaction.authorId != validLocalAuthorId &&
              !remoteAuthors.contains(reaction.authorId),
        )) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.unexpectedAuthor,
      );
    }
    if ((operationId != null && !RichContentWire.validOperation(operationId)) ||
        (roomId != null &&
            (!scope.isGroup || !RichContentWire.validRoom(roomId))) ||
        (scope.isGroup && topicTagged)) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.malformedTopic,
      );
    }
    final direction = switch (authorId) {
      _ when authorId == validLocalAuthorId => TimelineDirection.outgoing,
      _ when remoteAuthors.contains(authorId) || historicalGroupAuthor =>
        TimelineDirection.incoming,
      _ => null,
    };
    if (direction == null) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.unexpectedAuthor,
      );
    }

    final rawReaders = value['readByMemberIds'];
    final readByMemberIds = <String>{};
    if (rawReaders != null) {
      if (!scope.isGroup ||
          direction != TimelineDirection.outgoing ||
          rawReaders is! List ||
          rawReaders.length > TimelineWireContract.maxGroupReceiptMembers) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedEnvelope,
        );
      }
      for (final rawReader in rawReaders) {
        final reader = _boundedString(
          rawReader,
          TimelineWireContract.maxAuthorIdCodeUnits,
        );
        if (reader == null ||
            reader == validLocalAuthorId ||
            !remoteAuthors.contains(reader)) {
          return const TimelineParseResult.rejected(
            TimelineParseFailure.malformedEnvelope,
          );
        }
        readByMemberIds.add(reader);
      }
    }

    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      timestampSeconds * Duration.millisecondsPerSecond,
      isUtc: true,
    );
    final deliveryState = direction == TimelineDirection.outgoing
        ? _deliveryState(value['deliveryState'])
        : TimelineDeliveryState.sent;
    if (deliveryState == null) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.malformedEnvelope,
      );
    }
    if (mimeType != TimelineWireContract.textMimeType &&
        mimeType != TimelineWireContract.fileMimeType &&
        mimeType != RichContentWire.stickerMime &&
        mimeType != DmTopicWire.mimeType) {
      return const TimelineParseResult.rejected(
        TimelineParseFailure.unsupportedMimeType,
      );
    }
    if (mimeType == DmTopicWire.mimeType) {
      final eventBody = value['eventBody'];
      if (scope.isGroup ||
          deleted ||
          operation != TimelineMutationKind.snapshot ||
          versionId != daemonId ||
          topicId != DmTopicWire.mainId ||
          topicTagged ||
          eventBody is! String ||
          eventBody.isEmpty ||
          utf8.encode(eventBody).length > DmTopicWire.maxEventBytes) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedTopicEvent,
        );
      }
      final item = TimelineDmTopicEventItem(
        scope: scope,
        daemonId: daemonId,
        versionId: versionId,
        authorId: authorId,
        direction: direction,
        createdAt: createdAt,
        linearizedParent: linearizedParent,
        eventBody: eventBody,
      );
      return TimelineParseResult.accepted(
        TimelineMutation(
          kind: TimelineMutationKind.snapshot,
          scope: scope,
          daemonId: daemonId,
          versionId: versionId,
          authorId: authorId,
          direction: direction,
          createdAt: createdAt,
          item: item,
        ),
      );
    }
    if (mimeType == RichContentWire.stickerMime) {
      final body = value['body'];
      if (deleted ||
          operation != TimelineMutationKind.snapshot ||
          versionId != daemonId ||
          body is! String ||
          body.isEmpty ||
          body.length > RichContentWire.maximumBytes ||
          utf8.encode(body).length > RichContentWire.maximumBytes) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedEnvelope,
        );
      }
      final item = TimelineStickerItem(
        scope: scope,
        daemonId: daemonId,
        versionId: versionId,
        authorId: authorId,
        direction: direction,
        createdAt: createdAt,
        deliveryState: deliveryState,
        readByMemberIds: Set.unmodifiable(readByMemberIds),
        topicId: topicId,
        topicTagged: topicTagged,
        linearizedParent: linearizedParent,
        operationId: operationId as String?,
        roomId: roomId as String?,
        replyTo: replyTo,
        reactions: reactions,
        body: body,
      );
      return TimelineParseResult.accepted(
        TimelineMutation(
          kind: TimelineMutationKind.snapshot,
          scope: scope,
          daemonId: daemonId,
          versionId: versionId,
          authorId: authorId,
          direction: direction,
          createdAt: createdAt,
          item: item,
        ),
      );
    }
    if (deleted) {
      return TimelineParseResult.accepted(
        TimelineMutation(
          kind: TimelineMutationKind.delete,
          scope: scope,
          daemonId: daemonId,
          versionId: versionId,
          authorId: authorId,
          direction: direction,
          createdAt: createdAt,
          item: null,
        ),
      );
    }
    if (mimeType == TimelineWireContract.textMimeType) {
      final body = value['body'];
      if (body is! String ||
          body.length > TimelineWireContract.maxTextCodeUnits) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedText,
        );
      }
      if (body.isEmpty) {
        return TimelineParseResult.accepted(
          TimelineMutation(
            kind: TimelineMutationKind.delete,
            scope: scope,
            daemonId: daemonId,
            versionId: versionId,
            authorId: authorId,
            direction: direction,
            createdAt: createdAt,
            item: null,
          ),
        );
      }
      final item = TimelineTextItem(
        scope: scope,
        daemonId: daemonId,
        versionId: versionId,
        authorId: authorId,
        direction: direction,
        createdAt: createdAt,
        deliveryState: deliveryState,
        readByMemberIds: Set.unmodifiable(readByMemberIds),
        topicId: topicId,
        topicTagged: topicTagged,
        linearizedParent: linearizedParent,
        text: body,
        operationId: operationId as String?,
        roomId: roomId as String?,
        replyTo: replyTo,
        reactions: reactions,
      );
      return TimelineParseResult.accepted(
        TimelineMutation(
          kind: operation,
          scope: scope,
          daemonId: daemonId,
          versionId: versionId,
          authorId: authorId,
          direction: direction,
          createdAt: createdAt,
          item: item,
        ),
      );
    }
    if (mimeType == TimelineWireContract.fileMimeType) {
      final body = value['body'];
      final mediaMetadata = value['mediaMetadata'];
      if (mediaMetadata != null &&
          (mediaMetadata is! String ||
              mediaMetadata.isEmpty ||
              mediaMetadata.length > RichContentWire.maximumBytes ||
              utf8.encode(mediaMetadata).length >
                  RichContentWire.maximumBytes)) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedFile,
        );
      }
      if (body is! Map || operation != TimelineMutationKind.snapshot) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedFile,
        );
      }
      final fileId = _boundedString(
        body['fileId'],
        TimelineWireContract.maxFileIdCodeUnits,
      );
      final displayName = _boundedString(
        body['displayName'],
        TimelineWireContract.maxDisplayNameCodeUnits,
      );
      final totalBytesValue = body['totalBytes'];
      final totalBytes = totalBytesValue == null
          ? null
          : _nonNegativeInt(totalBytesValue);
      final sha3Value = body['sha3'];
      final sha3 = sha3Value == null
          ? null
          : _boundedString(sha3Value, TimelineWireContract.maxHashCodeUnits);
      final downloadedValue = body['downloaded'];
      final downloaded = downloadedValue == null
          ? false
          : _strictBool(downloadedValue);
      if (fileId == null ||
          displayName == null ||
          (totalBytesValue != null && totalBytes == null) ||
          (sha3Value != null && sha3 == null) ||
          downloaded == null) {
        return const TimelineParseResult.rejected(
          TimelineParseFailure.malformedFile,
        );
      }
      final item = TimelineFileItem(
        scope: scope,
        daemonId: daemonId,
        versionId: versionId,
        authorId: authorId,
        direction: direction,
        createdAt: createdAt,
        deliveryState: deliveryState,
        readByMemberIds: Set.unmodifiable(readByMemberIds),
        topicId: topicId,
        topicTagged: topicTagged,
        linearizedParent: linearizedParent,
        fileId: fileId,
        displayName: displayName,
        totalBytes: totalBytes,
        sha3: sha3,
        downloaded: downloaded,
        operationId: operationId as String?,
        roomId: roomId as String?,
        replyTo: replyTo,
        reactions: reactions,
        mediaMetadata: mediaMetadata as String?,
      );
      return TimelineParseResult.accepted(
        TimelineMutation(
          kind: TimelineMutationKind.snapshot,
          scope: scope,
          daemonId: daemonId,
          versionId: versionId,
          authorId: authorId,
          direction: direction,
          createdAt: createdAt,
          item: item,
        ),
      );
    }
    return const TimelineParseResult.rejected(
      TimelineParseFailure.unsupportedMimeType,
    );
  }

  static String? _boundedString(Object? value, int maxCodeUnits) {
    if (value is! String || value.isEmpty || value.length > maxCodeUnits) {
      return null;
    }
    return value;
  }

  static int? _nonNegativeInt(Object? value) {
    final parsed = switch (value) {
      int number => number,
      String text => int.tryParse(text),
      _ => null,
    };
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  static int? _timestampSeconds(Object? value) {
    const maxDateTimeSeconds = 8640000000000;
    final parsed = _nonNegativeInt(value);
    return parsed != null && parsed <= maxDateTimeSeconds ? parsed : null;
  }

  static bool? _strictBool(Object? value) => switch (value) {
    true || 'true' || 1 || '1' => true,
    false || 'false' || 0 || '0' => false,
    _ => null,
  };

  static TimelineDeliveryState? _deliveryState(Object? value) =>
      switch (value) {
        null || 0 || 1 => TimelineDeliveryState.sent,
        2 => TimelineDeliveryState.delivered,
        3 => TimelineDeliveryState.read,
        _ => null,
      };
}

final class TimelineLoadRequest {
  const TimelineLoadRequest({
    required this.scope,
    required this.generation,
    required this.requestId,
    required this.beforeCursor,
    required this.limit,
  });

  final ConversationScope scope;
  final int generation;
  final int requestId;
  final String? beforeCursor;
  final int limit;
}

final class TimelineHistoryPage {
  TimelineHistoryPage({
    required this.scope,
    required this.generation,
    required this.requestId,
    required this.daemonLoadId,
    required this.requestedCursor,
    required this.nextCursor,
    required this.hasMore,
    required List<Map<String, Object?>> items,
  }) : items = List.unmodifiable(items.map(_freezeWireItem));

  final ConversationScope scope;
  final int generation;
  final int requestId;
  final String daemonLoadId;
  final String? requestedCursor;
  final String? nextCursor;
  final bool hasMore;
  final List<Map<String, Object?>> items;
}

Map<String, Object?> _freezeWireItem(Map<String, Object?> item) =>
    Map.unmodifiable({
      for (final entry in item.entries)
        entry.key: _freezeWireValue(entry.value),
    });

Object? _freezeWireValue(Object? value) => switch (value) {
  Map map => Map.unmodifiable({
    for (final entry in map.entries) entry.key: _freezeWireValue(entry.value),
  }),
  List list => List.unmodifiable(list.map(_freezeWireValue)),
  _ => value,
};

/// A daemon load registration followed by the callback correlated to its id.
///
/// Implementations must register/buffer the callback before returning this
/// handle so a fast daemon response cannot be lost.
final class TimelineLoadHandle {
  const TimelineLoadHandle({
    required this.daemonLoadId,
    required this.completion,
  });

  final String daemonLoadId;
  final Future<TimelineHistoryPage> completion;
}

/// Adapter over the daemon's existing conversation history. It is not a store
/// and must not introduce a parallel message database.
abstract interface class ConversationTimelineRepository {
  Future<TimelineLoadHandle> startLoad(TimelineLoadRequest request);

  /// Best-effort, idempotent retirement of one daemon history load.
  ///
  /// A controller generation may stop owning a load before its callback
  /// arrives. Implementations must release local correlation state and ask the
  /// daemon to cancel, without making a replacement generation wait for that
  /// cleanup.
  Future<void> cancelLoad(String daemonLoadId);
}

/// libjami answers a load with id 0 while a just-accepted conversation is
/// still being cloned from the peer. Not a failure: the load is retried.
final class TimelineNotReadyException implements Exception {
  const TimelineNotReadyException();

  @override
  String toString() => 'TimelineNotReadyException';
}

final class TimelineProtocolException implements Exception {
  const TimelineProtocolException(this.message);

  final String message;

  @override
  String toString() => 'TimelineProtocolException: $message';
}

enum TimelineMergeOutcome { inserted, updated, unchanged, rejected }

final class _TimelineIdentity {
  const _TimelineIdentity({
    required this.scope,
    required this.authorId,
    required this.direction,
    required this.createdAt,
  });

  factory _TimelineIdentity.fromMutation(TimelineMutation mutation) =>
      _TimelineIdentity(
        scope: mutation.scope,
        authorId: mutation.authorId,
        direction: mutation.direction,
        createdAt: mutation.createdAt,
      );

  final ConversationScope scope;
  final String authorId;
  final TimelineDirection direction;
  final DateTime createdAt;

  bool matches(TimelineMutation mutation) =>
      scope == mutation.scope &&
      authorId == mutation.authorId &&
      direction == mutation.direction &&
      createdAt == mutation.createdAt;
}

final class _DeliveryEvidence {
  int state = 0;
  final Set<String> readers = {};
}

final class _TimelineRefreshStage {
  _TimelineRefreshStage(this.generation);

  final int generation;
  final Map<String, _DeliveryEvidence> deliveryEvidence = {};
  final List<List<TimelineMutation>> pages = [];
  final Map<String, TimelineMutation> visibleByDaemonId = {};
  final List<TimelineMutation> liveMutations = [];

  void addPage(List<TimelineMutation> mutations) {
    pages.add(mutations);
    for (final mutation in mutations) {
      if (mutation.item == null) {
        visibleByDaemonId.remove(mutation.daemonId);
      } else if (mutation.item is! TimelineDmTopicEventItem) {
        visibleByDaemonId[mutation.daemonId] = mutation;
      }
    }
  }
}

/// Owns one exact conversation timeline and no other friend's state.
final class ConversationTimelineController extends ChangeNotifier {
  ConversationTimelineController({
    required this.scope,
    required this.localAuthorId,
    required this.repository,
    this.pageSize = 50,
    this.parser = const TimelineItemParser(),
    Set<String>? allowedRemoteAuthorIds,
  }) {
    if (pageSize < 1 || pageSize > 500) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be 1..500');
    }
    this.allowedRemoteAuthorIds = Set.unmodifiable(
      allowedRemoteAuthorIds ?? {scope.peerId},
    );
    if (localAuthorId.isEmpty ||
        localAuthorId.length > TimelineWireContract.maxAuthorIdCodeUnits) {
      throw ArgumentError.value(
        localAuthorId,
        'localAuthorId',
        'must be a bounded Jami account URI',
      );
    }
  }

  final ConversationScope scope;
  final String localAuthorId;
  final int pageSize;
  final ConversationTimelineRepository repository;
  final TimelineItemParser parser;
  late final Set<String> allowedRemoteAuthorIds;

  final Map<String, ConversationTimelineItem> _byDaemonId = {};
  final Map<String, String> _versionByDaemonId = {};
  final Map<String, _TimelineIdentity> _identityByDaemonId = {};
  final Map<String, int> _orderByDaemonId = {};
  final Set<String> _completedDaemonLoadIds = {};
  int _oldestOrder = 0;
  int _nextNewerOrder = 0;
  int _generation = 0;
  int _nextRequestId = 0;
  int? _activeRequestId;
  String? _activeDaemonLoadId;
  String? _nextCursor;
  final Set<String> _visitedPageCursors = {};
  bool _isLoading = false;
  bool _hasMore = true;
  bool _disposed = false;
  Object? _lastError;
  int _rejectedItemCount = 0;
  _TimelineRefreshStage? _refreshStage;
  static const maximumPendingReactionChanges = 1024;
  static const maximumPendingDeliveryEvidence = 1024;
  final List<ReactionChange> _pendingReactionChanges = [];

  int get generation => _generation;
  bool get isLoading => _isLoading;
  bool get hasMore => _hasMore;
  Object? get lastError => _lastError;
  int get rejectedItemCount => _rejectedItemCount;
  String? get activeDaemonLoadId => _activeDaemonLoadId;

  List<ConversationTimelineItem> get allItems {
    final result = _byDaemonId.values.toList()
      ..sort((left, right) {
        final order = (_orderByDaemonId[left.daemonId] ?? 0).compareTo(
          _orderByDaemonId[right.daemonId] ?? 0,
        );
        if (order != 0) return order;
        final time = left.createdAt.compareTo(right.createdAt);
        return time != 0 ? time : left.daemonId.compareTo(right.daemonId);
      });
    return List.unmodifiable(result);
  }

  List<ConversationTimelineItem> get items => List.unmodifiable(
    allItems.where((item) => item is! TimelineDmTopicEventItem),
  );

  int get _visibleItemCount => _byDaemonId.values
      .where((item) => item is! TimelineDmTopicEventItem)
      .length;

  Future<void> refresh() {
    if (_disposed) return Future.value();
    _cancelLoadBestEffort(_activeDaemonLoadId);
    _generation++;
    _pendingReactionChanges.clear();
    _completedDaemonLoadIds.clear();
    _activeRequestId = null;
    _activeDaemonLoadId = null;
    _nextCursor = null;
    _visitedPageCursors.clear();
    _hasMore = true;
    _lastError = null;
    _rejectedItemCount = 0;
    _isLoading = false;
    final stage = _TimelineRefreshStage(_generation);
    _refreshStage = stage;
    notifyListeners();
    return _loadPage(
      generation: _generation,
      beforeCursor: null,
      refreshStage: stage,
    );
  }

  /// Load actual contiguous daemon pages from the latest edge to a commit.
  /// The caller owns account/access/route lifetime; snippets never enter here.
  Future<bool> loadThrough(
    String daemonId, {
    required bool Function() isCurrent,
    void Function(int loadedItems)? onProgress,
  }) async {
    if (_disposed || !isCurrent()) return false;
    final expectedGeneration = _generation + 1;
    await refresh();
    bool current() =>
        !_disposed && _generation == expectedGeneration && isCurrent();
    while (current() && _lastError == null) {
      onProgress?.call(_visibleItemCount);
      if (_byDaemonId.containsKey(daemonId)) return current();
      if (!_hasMore) return false;
      await loadMore();
    }
    return false;
  }

  /// Release only this controller's outstanding page; a late callback cannot
  /// refill a retired navigation. The repository retains native quarantine.
  void cancelPendingLoad() {
    if (_disposed || !_isLoading) return;
    _cancelLoadBestEffort(_activeDaemonLoadId);
    _generation++;
    _activeRequestId = null;
    _activeDaemonLoadId = null;
    _refreshStage = null;
    _pendingReactionChanges.clear();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMore() {
    if (_disposed || _isLoading || !_hasMore) return Future.value();
    return _loadPage(generation: _generation, beforeCursor: _nextCursor);
  }

  TimelineMergeOutcome mergeLive(Map<String, Object?> value) {
    if (_disposed) return TimelineMergeOutcome.rejected;
    final parsed = parser.parse(
      expectedScope: scope,
      localAuthorId: localAuthorId,
      allowedRemoteAuthorIds: allowedRemoteAuthorIds,
      value: value,
    );
    final mutation = parsed.mutation;
    if (mutation == null) {
      _rejectedItemCount++;
      notifyListeners();
      return TimelineMergeOutcome.rejected;
    }
    final outcome = _mergeMutation(
      mutation,
      allowVersionAdvance: mutation.kind != TimelineMutationKind.snapshot,
      insertionOrder: _nextNewerOrder,
    );
    final refreshStage = _refreshStage;
    if (outcome != TimelineMergeOutcome.rejected &&
        outcome != TimelineMergeOutcome.unchanged &&
        refreshStage != null &&
        refreshStage.generation == _generation) {
      refreshStage.liveMutations.add(mutation);
    }
    if (outcome == TimelineMergeOutcome.inserted) {
      _nextNewerOrder++;
    }
    if (outcome != TimelineMergeOutcome.unchanged) {
      if (outcome == TimelineMergeOutcome.rejected) {
        _rejectedItemCount++;
      }
      notifyListeners();
    }
    return outcome;
  }

  bool updateDelivery(String daemonId, int wireState, {String? memberId}) {
    if (_disposed || wireState < 1 || wireState > 3) return false;
    final current = _byDaemonId[daemonId];
    if (current != null && current.direction != TimelineDirection.outgoing) {
      return false;
    }
    final next = TimelineDeliveryState.values[wireState - 1];
    final reader =
        scope.isGroup &&
            wireState == 3 &&
            memberId != null &&
            memberId != localAuthorId &&
            allowedRemoteAuthorIds.contains(memberId)
        ? memberId
        : null;
    _recordDeliveryEvidence(daemonId, wireState, reader);
    if (current == null) return false;
    final readers = {...current.readByMemberIds};
    if (reader != null) readers.add(reader);
    if (next.index <= current.deliveryState.index &&
        setEquals(readers, current.readByMemberIds)) {
      return false;
    }
    _byDaemonId[daemonId] = current.withDeliveryState(
      next.index > current.deliveryState.index ? next : current.deliveryState,
      readByMemberIds: Set.unmodifiable(readers),
    );
    notifyListeners();
    return true;
  }

  /// A receipt seen while a refresh is staged is retained for that stage only,
  /// so the older snapshot cannot overwrite it at commit. It never creates a row.
  void _recordDeliveryEvidence(String daemonId, int wireState, String? reader) {
    final stage = _refreshStage;
    if (stage == null || stage.generation != _generation) return;
    var evidence = stage.deliveryEvidence[daemonId];
    if (evidence == null) {
      if (stage.deliveryEvidence.length >= maximumPendingDeliveryEvidence) {
        // Same overflow behaviour as reactions: retire the stale snapshot
        // rather than silently dropping evidence needed to reconcile it.
        _cancelLoadBestEffort(_activeDaemonLoadId);
        _generation++;
        _activeRequestId = null;
        _activeDaemonLoadId = null;
        _refreshStage = null;
        _isLoading = false;
        _pendingReactionChanges.clear();
        _lastError = const TimelineProtocolException(
          'delivery receipts exceeded the pending snapshot bound',
        );
        notifyListeners();
        return;
      }
      evidence = stage.deliveryEvidence[daemonId] = _DeliveryEvidence();
    }
    if (wireState > evidence.state) evidence.state = wireState;
    if (reader != null) evidence.readers.add(reader);
  }

  void _replayDeliveryEvidence(_TimelineRefreshStage stage) {
    stage.deliveryEvidence.forEach((daemonId, evidence) {
      final current = _byDaemonId[daemonId];
      if (current == null || current.direction != TimelineDirection.outgoing) {
        return;
      }
      final next = TimelineDeliveryState.values[evidence.state - 1];
      final readers = {...current.readByMemberIds, ...evidence.readers};
      final raised = next.index > current.deliveryState.index;
      if (!raised && setEquals(readers, current.readByMemberIds)) return;
      _byDaemonId[daemonId] = current.withDeliveryState(
        raised ? next : current.deliveryState,
        readByMemberIds: Set.unmodifiable(readers),
      );
    });
  }

  /// Reaction signals are metadata updates only: never insert a message or
  /// produce a message delivery/read transition.
  TimelineMergeOutcome mergeReaction(Map<String, Object?> value) {
    if (_disposed || ConversationScope.tryParse(value) != scope) {
      return TimelineMergeOutcome.rejected;
    }
    final change = ReactionChange.fromWire(value);
    if (change == null ||
        (change.added != null &&
            change.added!.authorId != localAuthorId &&
            !allowedRemoteAuthorIds.contains(change.added!.authorId) &&
            !(scope.isGroup && value['authenticatedGroupHistory'] == true))) {
      return TimelineMergeOutcome.rejected;
    }
    final current = _byDaemonId[change.messageId];
    if (current is TimelineDmTopicEventItem) {
      return TimelineMergeOutcome.rejected;
    }
    final next = current?.reactions.apply(change);
    if (current != null && next == null) return TimelineMergeOutcome.rejected;
    if (_activeRequestId != null || _refreshStage != null) {
      if (_pendingReactionChanges.length >= maximumPendingReactionChanges) {
        // Cancel the stale snapshot instead of silently dropping the changes
        // needed to reconcile it. Existing visible messages remain intact.
        _cancelLoadBestEffort(_activeDaemonLoadId);
        _generation++;
        _activeRequestId = null;
        _activeDaemonLoadId = null;
        _refreshStage = null;
        _isLoading = false;
        _pendingReactionChanges.clear();
        _lastError = const TimelineProtocolException(
          'reaction changes exceeded the pending snapshot bound',
        );
        notifyListeners();
      } else {
        _pendingReactionChanges.add(change);
      }
    }
    if (current == null || next == current.reactions) {
      return TimelineMergeOutcome.unchanged;
    }
    _byDaemonId[change.messageId] = current.withDeliveryState(
      current.deliveryState,
      reactionSnapshot: next,
    );
    notifyListeners();
    return TimelineMergeOutcome.updated;
  }

  void _replayReactionChanges() {
    for (final change in _pendingReactionChanges) {
      final current = _byDaemonId[change.messageId];
      if (current == null || current is TimelineDmTopicEventItem) continue;
      final next = current.reactions.apply(change);
      if (next != null) {
        _byDaemonId[change.messageId] = current.withDeliveryState(
          current.deliveryState,
          reactionSnapshot: next,
        );
      }
    }
  }

  Future<void> _loadPage({
    required int generation,
    required String? beforeCursor,
    _TimelineRefreshStage? refreshStage,
  }) async {
    final requestId = ++_nextRequestId;
    if (refreshStage == null) _pendingReactionChanges.clear();
    _activeRequestId = requestId;
    _activeDaemonLoadId = null;
    _isLoading = true;
    _lastError = null;
    notifyListeners();

    final request = TimelineLoadRequest(
      scope: scope,
      generation: generation,
      requestId: requestId,
      beforeCursor: beforeCursor,
      limit: pageSize,
    );
    String? continueFromCursor;
    try {
      final handle = await repository.startLoad(request);
      if (!_isCurrent(generation, requestId)) {
        _cancelLoadBestEffort(handle.daemonLoadId);
        return;
      }
      if (handle.daemonLoadId.isEmpty ||
          _completedDaemonLoadIds.contains(handle.daemonLoadId)) {
        throw const TimelineProtocolException(
          'daemon load id is empty or already completed',
        );
      }
      _activeDaemonLoadId = handle.daemonLoadId;

      final page = await handle.completion;
      if (!_isCurrent(generation, requestId)) return;
      _validatePage(
        request: request,
        expectedDaemonLoadId: handle.daemonLoadId,
        page: page,
      );
      if (page.hasMore && !_visitedPageCursors.add(page.nextCursor!)) {
        throw const TimelineProtocolException('history paging cursor repeated');
      }
      final parsedPage = <TimelineMutation>[];
      final visibleItemCountBefore = _visibleItemCount;
      for (final value in page.items) {
        final parsed = parser.parse(
          expectedScope: scope,
          localAuthorId: localAuthorId,
          allowedRemoteAuthorIds: allowedRemoteAuthorIds,
          value: value,
        );
        final mutation = parsed.mutation;
        if (mutation == null || mutation.kind == TimelineMutationKind.edit) {
          _rejectedItemCount++;
          continue;
        }
        parsedPage.add(mutation);
      }
      _completedDaemonLoadIds.add(handle.daemonLoadId);
      _nextCursor = page.nextCursor;
      _hasMore = page.hasMore;
      if (refreshStage != null) {
        if (!identical(_refreshStage, refreshStage) ||
            refreshStage.generation != generation) {
          return;
        }
        refreshStage.addPage(parsedPage);
        if (page.hasMore && refreshStage.visibleByDaemonId.length < pageSize) {
          // libjami pages raw conversation commits, not just the text/file
          // records Syb-L renders. Fill one visible page before publishing the
          // refreshed snapshot.
          continueFromCursor = page.nextCursor;
        } else {
          _commitRefreshStage(refreshStage);
        }
      } else {
        _mergeHistoryPage(parsedPage);
        _replayReactionChanges();
        if (page.hasMore && _visibleItemCount == visibleItemCountBefore) {
          continueFromCursor = page.nextCursor;
        }
      }
    } catch (error) {
      if (_isCurrent(generation, requestId)) {
        _lastError = error;
        if (identical(_refreshStage, refreshStage)) _refreshStage = null;
      }
    } finally {
      if (_isCurrent(generation, requestId)) {
        _isLoading = continueFromCursor != null;
        _activeRequestId = null;
        _activeDaemonLoadId = null;
        if (_refreshStage == null) _pendingReactionChanges.clear();
        notifyListeners();
      }
    }
    if (continueFromCursor != null && !_disposed && generation == _generation) {
      await _loadPage(
        generation: generation,
        beforeCursor: continueFromCursor,
        refreshStage: refreshStage,
      );
    }
  }

  void _mergeHistoryPage(List<TimelineMutation> parsedPage) {
    // libjami pages are newest-first. Preserve that authoritative page order
    // when several commits share the same one-second timestamp; daemon ids are
    // hashes and have no chronology.
    var pageOrder = _oldestOrder - parsedPage.length;
    for (final mutation in parsedPage.reversed) {
      if (_mergeMutation(
            mutation,
            allowVersionAdvance: false,
            insertionOrder: pageOrder++,
          ) ==
          TimelineMergeOutcome.rejected) {
        _rejectedItemCount++;
      }
    }
    _oldestOrder -= parsedPage.length;
  }

  void _commitRefreshStage(_TimelineRefreshStage stage) {
    if (!identical(_refreshStage, stage)) return;
    _byDaemonId.clear();
    _versionByDaemonId.clear();
    _identityByDaemonId.clear();
    _orderByDaemonId.clear();
    _oldestOrder = 0;
    _nextNewerOrder = 0;
    for (final page in stage.pages) {
      _mergeHistoryPage(page);
    }
    for (final mutation in stage.liveMutations) {
      final outcome = _mergeMutation(
        mutation,
        allowVersionAdvance: mutation.kind != TimelineMutationKind.snapshot,
        insertionOrder: _nextNewerOrder,
      );
      if (outcome == TimelineMergeOutcome.inserted) _nextNewerOrder++;
      if (outcome == TimelineMergeOutcome.rejected) _rejectedItemCount++;
    }
    _replayReactionChanges();
    _replayDeliveryEvidence(stage);
    _refreshStage = null;
  }

  void _validatePage({
    required TimelineLoadRequest request,
    required String expectedDaemonLoadId,
    required TimelineHistoryPage page,
  }) {
    if (page.scope != scope ||
        page.generation != request.generation ||
        page.requestId != request.requestId ||
        page.daemonLoadId != expectedDaemonLoadId ||
        page.requestedCursor != request.beforeCursor) {
      throw const TimelineProtocolException(
        'history page does not match its exact request correlation',
      );
    }
    if (page.hasMore && (page.nextCursor?.isEmpty ?? true)) {
      throw const TimelineProtocolException(
        'a paginated history page requires a non-empty next cursor',
      );
    }
    if (!page.hasMore && page.nextCursor != null) {
      throw const TimelineProtocolException(
        'a terminal history page cannot advertise a next cursor',
      );
    }
    if (page.nextCursor != null && page.nextCursor == request.beforeCursor) {
      throw const TimelineProtocolException(
        'pagination cursor did not advance',
      );
    }
  }

  TimelineMergeOutcome _mergeMutation(
    TimelineMutation mutation, {
    required bool allowVersionAdvance,
    required int insertionOrder,
  }) {
    final daemonId = mutation.daemonId;
    final existingVersion = _versionByDaemonId[daemonId];
    final existingIdentity = _identityByDaemonId[daemonId];
    if (existingVersion == null) {
      _versionByDaemonId[daemonId] = mutation.versionId;
      _identityByDaemonId[daemonId] = _TimelineIdentity.fromMutation(mutation);
      final item = mutation.item;
      if (item != null) {
        _byDaemonId[daemonId] = item;
        _orderByDaemonId[daemonId] = insertionOrder;
        return TimelineMergeOutcome.inserted;
      }
      return TimelineMergeOutcome.updated;
    }
    if (existingIdentity == null || !existingIdentity.matches(mutation)) {
      return TimelineMergeOutcome.rejected;
    }

    if (existingVersion != mutation.versionId) {
      if (!allowVersionAdvance ||
          mutation.kind == TimelineMutationKind.snapshot) {
        return TimelineMergeOutcome.rejected;
      }
      final previous = _byDaemonId[daemonId];
      final item = mutation.item;
      if (item == null) {
        _versionByDaemonId[daemonId] = mutation.versionId;
        _byDaemonId.remove(daemonId);
        return TimelineMergeOutcome.updated;
      }
      if (previous != null && !previous.hasSameInteraction(item)) {
        return TimelineMergeOutcome.rejected;
      }
      _versionByDaemonId[daemonId] = mutation.versionId;
      _byDaemonId[daemonId] = item;
      _orderByDaemonId.putIfAbsent(daemonId, () => insertionOrder);
      return previous == null
          ? TimelineMergeOutcome.inserted
          : TimelineMergeOutcome.updated;
    }

    final incoming = mutation.item;
    final existing = _byDaemonId[daemonId];
    if (incoming == null) {
      if (existing == null) return TimelineMergeOutcome.unchanged;
      _byDaemonId.remove(daemonId);
      return TimelineMergeOutcome.updated;
    }
    if (existing == null) {
      // A same-version tombstone is authoritative and must not be resurrected.
      return TimelineMergeOutcome.rejected;
    }
    final merged = existing.mergeCompatible(incoming);
    if (merged == null) return TimelineMergeOutcome.rejected;
    if (merged == existing) return TimelineMergeOutcome.unchanged;
    _byDaemonId[daemonId] = merged;
    return TimelineMergeOutcome.updated;
  }

  bool _isCurrent(int generation, int requestId) =>
      !_disposed && generation == _generation && requestId == _activeRequestId;

  void _cancelLoadBestEffort(String? daemonLoadId) {
    if (daemonLoadId == null || daemonLoadId.isEmpty) return;
    unawaited(() async {
      try {
        await repository.cancelLoad(daemonLoadId);
      } catch (_) {
        // Ownership is already retired locally. Cancellation failure must not
        // resurrect the stale generation or block its replacement.
      }
    }());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _cancelLoadBestEffort(_activeDaemonLoadId);
    _disposed = true;
    _pendingReactionChanges.clear();
    _generation++;
    _activeRequestId = null;
    _activeDaemonLoadId = null;
    _refreshStage = null;
    super.dispose();
  }
}
