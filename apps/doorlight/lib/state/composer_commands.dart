import 'dart:collection';

enum ComposerResultKind {
  switchTopic,
  openChat,
  createTopic,
  renameTopic,
  gravity,
}

final class ComposerTopicTarget {
  const ComposerTopicTarget({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.archived = false,
  });

  final String id;
  final String name;
  final bool isDefault;
  final bool archived;
}

final class ComposerChatTarget {
  const ComposerChatTarget({
    required this.ownerKey,
    required this.conversationId,
    required this.displayName,
    required this.defaultTopicId,
    required this.lastTopicId,
    this.avatarBase64 = '',
    this.isGroup = false,
    this.topics = const [],
  });

  final String ownerKey;
  final String conversationId;
  final String displayName;
  final String avatarBase64;
  final String defaultTopicId;
  final String lastTopicId;
  final bool isGroup;
  final List<ComposerTopicTarget> topics;
}

final class ComposerQueryContext {
  const ComposerQueryContext({
    required this.currentOwnerKey,
    required this.currentConversationId,
    required this.activeTopicId,
    this.canCreateTopic = false,
    this.canRenameTopic = false,
  });

  final String currentOwnerKey;
  final String currentConversationId;
  final String activeTopicId;
  final bool canCreateTopic;
  final bool canRenameTopic;
}

final class ComposerResult {
  const ComposerResult({
    required this.kind,
    required this.label,
    this.ownerKey = '',
    this.conversationId = '',
    this.topicId = '',
    this.topicName,
    this.chatDisplayName = '',
    this.avatarBase64 = '',
    this.showChatIdentity = false,
    this.showActionIcon = false,
    this.executable = true,
    this.description = '',
  });

  final ComposerResultKind kind;
  final String label;
  final String ownerKey;
  final String conversationId;
  final String topicId;
  final String? topicName;
  final String chatDisplayName;
  final String avatarBase64;
  final bool showChatIdentity;
  final bool showActionIcon;
  final bool executable;

  /// One line shown beside the command in the preview.
  final String description;
}

final class ComposerQueryResult {
  const ComposerQueryResult({
    this.results = const [],
    this.isSendableText = true,
    this.isExactAction = false,
  });

  final List<ComposerResult> results;
  final bool isSendableText;
  final bool isExactAction;
}

abstract final class ComposerQuery {
  static ComposerQueryResult resolve(
    String input,
    ComposerQueryContext context,
    List<ComposerChatTarget> catalog,
  ) {
    final found = _resolve(input, context, catalog);
    if (!input.startsWith('/') || input.contains('\n')) return found;
    final typed = input.substring(1).toLowerCase();
    if (typed.isEmpty || !'gravity'.startsWith(typed)) return found;
    // Hidden from the bare "/" list; it previews once you start typing it.
    return ComposerQueryResult(
      results: List.unmodifiable([
        const ComposerResult(
          kind: ComposerResultKind.gravity,
          label: '/gravity',
          description: 'FIRST LAW!!',
          showActionIcon: true,
        ),
        ...found.results,
      ]),
      isSendableText: false,
      isExactAction: typed == 'gravity' || found.isExactAction,
    );
  }

  static ComposerQueryResult _resolve(
    String input,
    ComposerQueryContext context,
    List<ComposerChatTarget> catalog,
  ) {
    if (!input.startsWith('/') || input.contains('\n')) {
      return const ComposerQueryResult();
    }
    final query = input.substring(1);
    if (query.isEmpty) {
      return ComposerQueryResult(
        results: List.unmodifiable([
          if (context.canCreateTopic)
            const ComposerResult(
              kind: ComposerResultKind.createTopic,
              label: '/topic create',
              description: 'Start a new topic in this chat',
              executable: false,
            ),
          if (context.canRenameTopic)
            ComposerResult(
              kind: ComposerResultKind.renameTopic,
              label: '/topic rename',
              description: 'Rename the current topic',
              topicId: context.activeTopicId,
              executable: false,
            ),
        ]),
        isSendableText: false,
      );
    }
    final command = _topicCommand(query, context);
    if (command != null) return command;

    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const ComposerQueryResult();
    final current = catalog
        .where(
          (chat) =>
              chat.ownerKey == context.currentOwnerKey &&
              chat.conversationId == context.currentConversationId,
        )
        .firstOrNull;
    final results = <ComposerResult>[];
    if (current != null) {
      for (final topic in current.topics) {
        if (!topic.archived && topic.name.toLowerCase().startsWith(needle)) {
          results.add(_topicResult(current, topic, currentChat: true));
        }
      }
    }
    for (final chat in catalog) {
      if (identical(chat, current)) continue;
      for (final topic in chat.topics) {
        if (!topic.archived &&
            !topic.isDefault &&
            topic.name.toLowerCase().startsWith(needle)) {
          results.add(_topicResult(chat, topic, currentChat: false));
        }
      }
    }
    for (final chat in catalog) {
      if (identical(chat, current) ||
          !chat.displayName.toLowerCase().startsWith(needle)) {
        continue;
      }
      final availableLast = chat.topics.any(
        (topic) => topic.id == chat.lastTopicId && !topic.archived,
      );
      results.add(
        ComposerResult(
          kind: ComposerResultKind.openChat,
          label: chat.displayName,
          ownerKey: chat.ownerKey,
          conversationId: chat.conversationId,
          topicId: availableLast ? chat.lastTopicId : chat.defaultTopicId,
          chatDisplayName: chat.displayName,
          avatarBase64: chat.avatarBase64,
          showChatIdentity: true,
        ),
      );
    }
    final exact =
        results.isNotEmpty &&
        (results.first.topicName ?? results.first.chatDisplayName)
                .toLowerCase() ==
            needle;
    return ComposerQueryResult(
      results: List.unmodifiable(results),
      isSendableText: results.isEmpty,
      isExactAction: exact,
    );
  }

  static ComposerQueryResult? _topicCommand(
    String query,
    ComposerQueryContext context,
  ) {
    final lower = query.toLowerCase();
    if (lower == 'topic' ||
        (lower.startsWith('topic ') &&
            !lower.startsWith('topic create') &&
            !lower.startsWith('topic rename'))) {
      final fragment = lower == 'topic' ? '' : lower.substring(6).trim();
      final suggestions = <ComposerResult>[
        if (context.canCreateTopic && 'create'.startsWith(fragment))
          const ComposerResult(
            kind: ComposerResultKind.createTopic,
            label: '/topic create',
            executable: false,
          ),
        if (context.canRenameTopic && 'rename'.startsWith(fragment))
          ComposerResult(
            kind: ComposerResultKind.renameTopic,
            label: '/topic rename',
            topicId: context.activeTopicId,
            executable: false,
          ),
      ];
      return ComposerQueryResult(
        results: List.unmodifiable(suggestions),
        isSendableText: suggestions.isEmpty,
      );
    }
    for (final action in ['create', 'rename']) {
      final prefix = 'topic $action';
      if (lower != prefix && !lower.startsWith('$prefix ')) continue;
      final create = action == 'create';
      final allowed = create
          ? context.canCreateTopic
          : context.canRenameTopic;
      if (!allowed) return const ComposerQueryResult();
      final name = query.substring(prefix.length).trim();
      final topicName = name.isEmpty ? null : name;
      final actionLabel = create ? 'Create' : 'Rename';
      return ComposerQueryResult(
        results: [
          ComposerResult(
            kind: create
                ? ComposerResultKind.createTopic
                : ComposerResultKind.renameTopic,
            label: '$actionLabel ${topicName ?? 'topic'}',
            topicId: create ? '' : context.activeTopicId,
            topicName: topicName,
            showActionIcon: true,
          ),
        ],
        isSendableText: false,
        isExactAction: true,
      );
    }
    if (lower == 'topic' || lower.startsWith('topic ')) {
      return const ComposerQueryResult();
    }
    return null;
  }

  static ComposerResult _topicResult(
    ComposerChatTarget chat,
    ComposerTopicTarget topic, {
    required bool currentChat,
  }) => ComposerResult(
    kind: ComposerResultKind.switchTopic,
    label: topic.name,
    ownerKey: chat.ownerKey,
    conversationId: chat.conversationId,
    topicId: topic.id,
    topicName: topic.name,
    chatDisplayName: currentChat ? '' : chat.displayName,
    avatarBase64: currentChat ? '' : chat.avatarBase64,
    showChatIdentity: !currentChat,
  );
}
