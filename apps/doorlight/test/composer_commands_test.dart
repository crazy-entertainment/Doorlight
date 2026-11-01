import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/composer_commands.dart';

void main() {
  const current = ComposerChatTarget(
    ownerKey: 'peer-a',
    conversationId: 'conv-a',
    displayName: 'Phone B',
    defaultTopicId: 'main',
    lastTopicId: 'plans-a',
    topics: [
      ComposerTopicTarget(id: 'main', name: 'main', isDefault: true),
      ComposerTopicTarget(id: 'plans-a', name: 'plans'),
      ComposerTopicTarget(id: 'archive-a', name: 'old', archived: true),
    ],
  );
  const other = ComposerChatTarget(
    ownerKey: 'peer-b',
    conversationId: 'conv-b',
    displayName: 'Phone A',
    avatarBase64: 'avatar',
    defaultTopicId: 'main',
    lastTopicId: 'vacation-b',
    topics: [
      ComposerTopicTarget(id: 'main', name: 'main', isDefault: true),
      ComposerTopicTarget(id: 'plans-b', name: 'plans'),
      ComposerTopicTarget(id: 'vacation-b', name: 'vacation'),
    ],
  );
  const group = ComposerChatTarget(
    ownerKey: 'group:group-a',
    conversationId: 'group-a',
    displayName: 'Chubbies',
    defaultTopicId: 'general',
    lastTopicId: 'games',
    isGroup: true,
    topics: [
      ComposerTopicTarget(id: 'general', name: 'general', isDefault: true),
      ComposerTopicTarget(id: 'games', name: 'games'),
    ],
  );
  const context = ComposerQueryContext(
    currentOwnerKey: 'peer-a',
    currentConversationId: 'conv-a',
    activeTopicId: 'plans-a',
    canCreateTopic: true,
    canRenameTopic: true,
  );
  const catalog = [current, other, group];

  test('current defaults stay local and global defaults do not multiply', () {
    final main = ComposerQuery.resolve('/main', context, catalog);
    expect(main.isSendableText, isFalse);
    expect(main.results, hasLength(1));
    expect(main.results.single.kind, ComposerResultKind.switchTopic);
    expect(main.results.single.ownerKey, current.ownerKey);
    expect(main.results.single.topicId, 'main');

    final general = ComposerQuery.resolve(
      '/general',
      const ComposerQueryContext(
        currentOwnerKey: 'group:group-a',
        currentConversationId: 'group-a',
        activeTopicId: 'games',
      ),
      catalog,
    );
    expect(general.results.single.topicId, 'general');
  });

  test(
    'custom topics rank the current chat before contextual cross-chat rows',
    () {
      final result = ComposerQuery.resolve('/pla', context, catalog);

      expect(result.results, hasLength(2));
      expect(result.results.first.ownerKey, current.ownerKey);
      expect(result.results.first.showChatIdentity, isFalse);
      expect(result.results.last.ownerKey, other.ownerKey);
      expect(result.results.last.showChatIdentity, isTrue);
      expect(result.results.last.chatDisplayName, 'Phone A');
      expect(result.results.last.avatarBase64, 'avatar');
    },
  );

  test('archived topics and cross-chat main are excluded', () {
    expect(ComposerQuery.resolve('/old', context, catalog).results, isEmpty);
    expect(
      ComposerQuery.resolve('/mai', context, catalog).results,
      hasLength(1),
    );
  });

  test('friend and group names open their last local topic', () {
    final friend = ComposerQuery.resolve(
      '/Phone A',
      context,
      catalog,
    ).results.single;
    expect(friend.kind, ComposerResultKind.openChat);
    expect(friend.ownerKey, other.ownerKey);
    expect(friend.topicId, other.lastTopicId);

    final groupResult = ComposerQuery.resolve(
      '/Chub',
      context,
      catalog,
    ).results.single;
    expect(groupResult.kind, ComposerResultKind.openChat);
    expect(groupResult.topicId, group.lastTopicId);
  });

  test('partial topic commands have no action icon', () {
    for (final input in ['/topic', '/topic cr', '/topic ren']) {
      final result = ComposerQuery.resolve(input, context, catalog);
      expect(result.results, isNotEmpty);
      expect(result.results.every((row) => !row.showActionIcon), isTrue);
      expect(result.isExactAction, isFalse);
    }
  });

  test('complete create and rename actions use all remaining words', () {
    final create = ComposerQuery.resolve(
      '/topic create summer trip',
      context,
      catalog,
    );
    expect(create.isExactAction, isTrue);
    expect(create.results.single.kind, ComposerResultKind.createTopic);
    expect(create.results.single.topicName, 'summer trip');
    expect(create.results.single.label, 'Create summer trip');
    expect(create.results.single.showActionIcon, isTrue);
    expect(create.results.single.showChatIdentity, isFalse);

    final rename = ComposerQuery.resolve(
      '/topic rename holiday plans',
      context,
      catalog,
    );
    expect(rename.results.single.kind, ComposerResultKind.renameTopic);
    expect(rename.results.single.topicId, context.activeTopicId);
    expect(rename.results.single.topicName, 'holiday plans');
  });

  test('exact verbs open dialogs and unknown slash text remains sendable', () {
    expect(
      ComposerQuery.resolve(
        '/topic create',
        context,
        catalog,
      ).results.single.topicName,
      isNull,
    );
    expect(
      ComposerQuery.resolve(
        '/topic rename',
        context,
        catalog,
      ).results.single.topicName,
      isNull,
    );

    final unknown = ComposerQuery.resolve('/does-not-exist', context, catalog);
    expect(unknown.results, isEmpty);
    expect(unknown.isSendableText, isTrue);
    expect(unknown.isExactAction, isFalse);
  });

  test('unavailable topic actions remain sendable text', () {
    const denied = ComposerQueryContext(
      currentOwnerKey: 'peer-a',
      currentConversationId: 'conv-a',
      activeTopicId: 'plans-a',
    );
    for (final verb in ['create', 'rename']) {
      final result = ComposerQuery.resolve(
        '/topic $verb plans',
        denied,
        catalog,
      );
      expect(result.results, isEmpty);
      expect(result.isSendableText, isTrue);
      expect(result.isExactAction, isFalse);
    }
  });

  test('blank names open dialogs and command lookalikes remain text', () {
    for (final verb in ['create', 'rename']) {
      final blank = ComposerQuery.resolve('/topic $verb   ', context, catalog);
      expect(blank.results.single.topicName, isNull);
      expect(
        blank.results.single.label,
        verb == 'create' ? 'Create topic' : 'Rename topic',
      );
      expect(blank.isExactAction, isTrue);
      final lookalike = ComposerQuery.resolve(
        '/topic ${verb}x',
        context,
        catalog,
      );
      expect(lookalike.results, isEmpty);
      expect(lookalike.isSendableText, isTrue);
      expect(lookalike.isExactAction, isFalse);
    }
  });

  test('a bare slash previews the available commands', () {
    final bare = ComposerQuery.resolve('/', context, catalog);
    expect(bare.results.map((r) => r.label), [
      '/topic create',
      '/topic rename',
    ]);
    expect(bare.results.every((r) => r.description.isNotEmpty), isTrue);
    expect(bare.isSendableText, isFalse);

    const plain = ComposerQueryContext(
      currentOwnerKey: 'peer-a',
      currentConversationId: 'conv-a',
      activeTopicId: 'plans-a',
    );
    expect(ComposerQuery.resolve('/', plain, catalog).results, isEmpty);
  });

  test('gravity previews once typed and is exact when complete', () {
    expect(
      ComposerQuery.resolve(
        '/',
        context,
        catalog,
      ).results.any((r) => r.kind == ComposerResultKind.gravity),
      isFalse,
    );
    final partial = ComposerQuery.resolve('/gra', context, catalog);
    expect(partial.results.first.kind, ComposerResultKind.gravity);
    expect(partial.isExactAction, isFalse);
    final exact = ComposerQuery.resolve('/Gravity', context, catalog);
    expect(exact.results.first.label, '/gravity');
    expect(exact.isExactAction, isTrue);
    expect(exact.isSendableText, isFalse);
    expect(
      ComposerQuery.resolve(
        '/gravity x',
        context,
        catalog,
      ).results.any((r) => r.kind == ComposerResultKind.gravity),
      isFalse,
    );
  });
}
