import 'package:flutter/foundation.dart';

/// The initial authoring palette. Reaction bodies remain standard Jami text.
abstract final class ReactionWire {
  static const palette = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
  static const maximumEntries = 512;
  static final _identity = RegExp(r'^[0-9a-f]{40}$');

  static bool identity(Object? value) =>
      value is String && value.length == 40 && _identity.hasMatch(value);
}

/// One authenticated reaction commit, distinct from its target message commit.
@immutable
final class MessageReaction {
  const MessageReaction._(this.commitId, this.authorId, this.emoji);

  final String commitId;
  final String authorId;
  final String emoji;

  static MessageReaction? fromWire(Object? value) {
    if (value is! Map ||
        !ReactionWire.identity(value['commitId']) ||
        !ReactionWire.identity(value['authorId']) ||
        !ReactionWire.palette.contains(value['emoji'])) {
      return null;
    }
    return MessageReaction._(
      value['commitId'] as String,
      value['authorId'] as String,
      value['emoji'] as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MessageReaction &&
      commitId == other.commitId &&
      authorId == other.authorId &&
      emoji == other.emoji;

  @override
  int get hashCode => Object.hash(commitId, authorId, emoji);
}

/// A native event from Jami's reaction signals. A removal names the reaction
/// commit rather than borrowing the target message's identity.
@immutable
final class ReactionChange {
  const ReactionChange._(this.messageId, this.added, this.removedId);
  final String messageId;
  final MessageReaction? added;
  final String? removedId;

  static ReactionChange? fromWire(Object? value) {
    if (value is! Map || !ReactionWire.identity(value['messageId'])) {
      return null;
    }
    final message = value['messageId'] as String;
    if (value['reaction'] != null && value['removedId'] == null) {
      final added = MessageReaction.fromWire(value['reaction']);
      if (added == null || added.commitId == message) return null;
      return ReactionChange._(message, added, null);
    }
    final removed = value['removedId'];
    if (value['reaction'] != null ||
        !ReactionWire.identity(removed) ||
        removed == message) {
      return null;
    }
    return ReactionChange._(message, null, removed as String);
  }
}

/// Bounded projection of Jami's folded reaction history, never a separate store.
/// Incomplete projections must not be displayed as exact counts or used to
/// remove a user's entire selection.
@immutable
final class MessageReactions {
  const MessageReactions._(this.entries, this.complete);
  static const empty = MessageReactions._([], true);

  final List<MessageReaction> entries;
  final bool complete;

  MessageReactions? apply(ReactionChange change) {
    final added = change.added;
    final values = {for (final entry in entries) entry.commitId: entry};
    if (added != null) {
      final previous = values[added.commitId];
      if (previous != null && previous != added) return null;
      if (previous == null && values.length >= ReactionWire.maximumEntries) {
        return MessageReactions._(entries, false);
      }
      values[added.commitId] = added;
    } else {
      values.remove(change.removedId);
    }
    final next = values.values.toList()
      ..sort((a, b) => a.commitId.compareTo(b.commitId));
    return MessageReactions._(List.unmodifiable(next), complete);
  }

  static MessageReactions? fromWire(
    Object? value, {
    required String messageId,
  }) {
    if (value == null) return empty;
    if (value is! Map ||
        value['messageId'] != messageId ||
        value['complete'] is! bool ||
        value['entries'] is! List) {
      return null;
    }
    final raw = value['entries'] as List;
    if (raw.length > ReactionWire.maximumEntries) return null;
    final byCommit = <String, MessageReaction>{};
    for (final value in raw) {
      final reaction = MessageReaction.fromWire(value);
      if (reaction == null || reaction.commitId == messageId) return null;
      final previous = byCommit[reaction.commitId];
      if (previous != null && previous != reaction) return null;
      byCommit[reaction.commitId] = reaction;
    }
    final entries = byCommit.values.toList()
      ..sort((a, b) => a.commitId.compareTo(b.commitId));
    return MessageReactions._(
      List.unmodifiable(entries),
      value['complete'] as bool,
    );
  }

  /// Repeated commits by one author do not inflate the displayed people count.
  int count(String emoji) => entries
      .where((entry) => entry.emoji == emoji)
      .map((entry) => entry.authorId)
      .toSet()
      .length;

  /// Each returned ID is the user's reaction commit, never the target message.
  /// Null means a complete removal cannot be derived from this projection.
  List<String>? removalCommitIds(String authorId, String emoji) => !complete
      ? null
      : List.unmodifiable(
          entries
              .where(
                (entry) => entry.authorId == authorId && entry.emoji == emoji,
              )
              .map((entry) => entry.commitId),
        );

  @override
  bool operator ==(Object other) =>
      other is MessageReactions &&
      complete == other.complete &&
      listEquals(entries, other.entries);

  @override
  int get hashCode => Object.hash(complete, Object.hashAll(entries));
}
