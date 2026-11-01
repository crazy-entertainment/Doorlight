import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/conversation_scope.dart';

ComposerDraftKey key([String topic = 'main']) => ComposerDraftKey(
  ConversationScope(
    accountId: 'account',
    peerId: 'peer',
    conversationId: 'swarm',
  ),
  topic,
);

void main() {
  test(
    'a delayed reply result cannot clear a changed reply or another visit',
    () {
      final draft = ComposerDraftSession(key());
      final owner = Object();
      draft.activate(owner);
      draft.updateText(owner, const TextEditingValue(text: 'A reply'));
      expect(draft.setReply(owner, 'first'), isTrue);
      final send = draft.begin(ComposerOperationKind.sendText, owner)!;
      expect(send.replyTo, 'first');
      draft.setReply(owner, 'second');
      expect(
        draft.complete(send, ComposerSendStatus.committed, commitId: 'sent'),
        isFalse,
      );
      expect(draft.text.text, 'A reply');
      expect(draft.replyTo, 'second');
      final next = draft.begin(ComposerOperationKind.sendText, owner)!;
      draft.deactivate(owner);
      draft.activate(Object());
      expect(
        draft.complete(
          next,
          ComposerSendStatus.committed,
          commitId: 'sent-next',
        ),
        isFalse,
      );
      expect(draft.replyTo, 'second');
      expect(draft.setReply(owner, 'stale'), isFalse);
    },
  );

  test(
    'confirmed reply clears its exact draft while unknown outcome keeps it',
    () {
      final draft = ComposerDraftSession(key());
      final owner = Object();
      draft.activate(owner);
      draft.setReply(owner, 'target');
      expect(draft.isEmpty, isFalse);
      draft.updateText(owner, const TextEditingValue(text: 'Reply'));
      final send = draft.begin(ComposerOperationKind.sendText, owner)!;
      expect(draft.complete(send, ComposerSendStatus.unknown), isFalse);
      expect(draft.begin(ComposerOperationKind.sendText, owner), isNull);
      expect(draft.replyTo, 'target');
      expect(
        draft.complete(send, ComposerSendStatus.committed, commitId: 'sent'),
        isTrue,
      );
      expect(draft.text.text, isEmpty);
      expect(draft.replyTo, isEmpty);
    },
  );
  test(
    'late committed media cannot be reissued or have its native seed deleted',
    () {
      final draft = ComposerDraftSession(key());
      final owner = Object();
      draft.activate(owner);
      final stage = ComposerMediaStage(
        kind: ComposerMediaKind.file,
        label: 'file',
        encodedBytes: 0,
        path: '/private/stage',
      );
      draft.replaceMedia(
        draft.begin(ComposerOperationKind.picker, owner)!,
        stage,
      );
      final send = draft.begin(ComposerOperationKind.sendMedia, owner)!;
      draft.deactivate(owner);
      final revisit = Object();
      draft.activate(revisit);
      draft.complete(send, ComposerSendStatus.committed, commitId: 'commit');
      expect(draft.mediaAlreadyCommitted, isTrue);
      expect(draft.begin(ComposerOperationKind.sendMedia, revisit), isNull);
      expect(draft.mayDiscardStage(stage), isFalse);
      expect(draft.removeMedia(revisit, stage), isTrue);
    },
  );
  test('pending and unknown media preserve the publication seed', () {
    final draft = ComposerDraftSession(key());
    final owner = Object();
    draft.activate(owner);
    final stage = ComposerMediaStage(
      kind: ComposerMediaKind.file,
      label: 'original',
      encodedBytes: 0,
    );
    draft.replaceMedia(
      draft.begin(ComposerOperationKind.picker, owner)!,
      stage,
    );
    final send = draft.begin(ComposerOperationKind.sendMedia, owner)!;
    final replacement = ComposerMediaStage(
      kind: ComposerMediaKind.file,
      label: 'replacement',
      encodedBytes: 1,
    );
    for (final status in [
      ComposerSendStatus.pending,
      ComposerSendStatus.unknown,
    ]) {
      draft.complete(send, status);
      expect(draft.removeMedia(owner, stage), isFalse);
      expect(
        draft.replaceMedia(
          draft.begin(ComposerOperationKind.picker, owner)!,
          replacement,
        ),
        isFalse,
      );
      expect(draft.media, same(stage));
    }
    draft.complete(send, ComposerSendStatus.failedBeforeCommit);
    expect(draft.removeMedia(owner, stage), isTrue);
  });

  test('A-B-A visits cannot revive preparation or clear a later draft', () {
    final draft = ComposerDraftSession(key());
    final first = Object();
    draft.activate(first);
    draft.updateText(first, const TextEditingValue(text: 'original'));
    final picker = draft.begin(ComposerOperationKind.picker, first)!;
    final send = draft.begin(ComposerOperationKind.sendText, first)!;
    draft.deactivate(first);
    final second = Object();
    draft.activate(second);
    expect(draft.text.text, 'original');
    expect(draft.owns(picker), isFalse);
    expect(
      draft.complete(send, ComposerSendStatus.committed, commitId: 'commit'),
      isFalse,
    );
    expect(draft.text.text, 'original');
  });

  test('unknown issued operation remains blocked across navigation', () {
    final draft = ComposerDraftSession(key());
    final owner = Object();
    draft.activate(owner);
    final send = draft.begin(ComposerOperationKind.sendText, owner)!;
    draft.complete(send, ComposerSendStatus.unknown);
    draft.deactivate(owner);
    final revisit = Object();
    draft.activate(revisit);
    expect(draft.begin(ComposerOperationKind.sendText, revisit), isNull);
  });

  test('newer picker and text revision fence replacements', () {
    final draft = ComposerDraftSession(key());
    final owner = Object();
    draft.activate(owner);
    final first = draft.begin(ComposerOperationKind.picker, owner)!;
    final second = draft.begin(ComposerOperationKind.picker, owner)!;
    final stage = ComposerMediaStage(
      kind: ComposerMediaKind.file,
      label: 'file',
      encodedBytes: 0,
    );
    expect(first.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(first.id, isNot(second.id));
    expect(draft.replaceMedia(first, stage), isFalse);
    expect(draft.replaceMedia(second, stage), isTrue);
    final replacement = draft.begin(ComposerOperationKind.picker, owner)!;
    draft.updateText(owner, const TextEditingValue(text: 'changed'));
    expect(draft.replaceMedia(replacement, stage), isFalse);
    expect(draft.media, same(stage));
  });

  test(
    'text success clears only text; failed media retains exact stage for retry',
    () {
      final draft = ComposerDraftSession(key());
      final owner = Object();
      draft.activate(owner);
      draft.updateText(owner, const TextEditingValue(text: 'caption'));
      final stage = ComposerMediaStage(
        kind: ComposerMediaKind.file,
        label: 'file',
        encodedBytes: 0,
      );
      draft.replaceMedia(
        draft.begin(ComposerOperationKind.picker, owner)!,
        stage,
      );
      final text = draft.begin(ComposerOperationKind.sendText, owner)!;
      expect(
        draft.complete(
          text,
          ComposerSendStatus.committed,
          commitId: 'text-commit',
        ),
        isTrue,
      );
      final media = draft.begin(ComposerOperationKind.sendMedia, owner)!;
      draft.complete(media, ComposerSendStatus.failedBeforeCommit);
      expect(draft.text.text, isEmpty);
      expect(draft.media, same(stage));
      expect(draft.begin(ComposerOperationKind.sendMedia, owner), isNotNull);
    },
  );

  test(
    'media-only send retains text and edited text survives late completion',
    () {
      final draft = ComposerDraftSession(key());
      final owner = Object();
      draft.activate(owner);
      draft.updateText(owner, const TextEditingValue(text: 'keep'));
      final stage = ComposerMediaStage(
        kind: ComposerMediaKind.voice,
        label: 'voice',
        encodedBytes: 500,
      );
      draft.replaceMedia(
        draft.begin(ComposerOperationKind.recording, owner)!,
        stage,
      );
      final media = draft.begin(ComposerOperationKind.sendMedia, owner)!;
      expect(
        draft.complete(media, ComposerSendStatus.committed, commitId: 'voice'),
        isTrue,
      );
      expect(draft.text.text, 'keep');
      final text = draft.begin(ComposerOperationKind.sendText, owner)!;
      draft.updateText(owner, const TextEditingValue(text: 'new text'));
      expect(
        draft.complete(text, ComposerSendStatus.committed, commitId: 'text'),
        isFalse,
      );
      expect(draft.text.text, 'new text');
    },
  );

  test(
    'draft limit refuses new content without evicting existing IME state',
    () {
      final store = ComposerDraftStore(maximumDrafts: 1);
      final draft = store.acquire(key())!;
      final owner = Object();
      draft.activate(owner);
      const value = TextEditingValue(
        text: '👩🏽‍💻',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 0, end: 7),
      );
      draft.updateText(owner, value);
      expect(store.acquire(key('other')), isNull);
      expect(store.acquire(key())!.text, value);
      draft.updateText(owner, TextEditingValue.empty);
      expect(store.acquire(key('other')), isNotNull);
    },
  );
}
