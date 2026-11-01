import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/conversation_scope.dart';

void main() {
  late ComposerDraftSession draft;
  late Object owner;
  late List<String> discarded;
  setUp(() {
    owner = Object();
    discarded = [];
    draft = ComposerDraftSession(
      ComposerDraftKey(
        ConversationScope(accountId: 'a', peerId: 'p', conversationId: 'c'),
        'main',
      ),
    )..activate(owner);
  });

  ComposerOperation pick() => draft.begin(ComposerOperationKind.picker, owner)!;
  ComposerMediaPreparer preparer(Future<int?> Function(String) inspect) =>
      ComposerMediaPreparer(
        discard: (path) async {
          discarded.add(path);
        },
        inspect: inspect,
      );

  test(
    'valid replacement adopts first then disposes previous exact path',
    () async {
      final media = preparer((_) async => 0);
      expect(
        await media.prepare(
          draft: draft,
          operation: pick(),
          produce: () async => '/stage/one',
        ),
        ComposerPreparationResult.staged,
      );
      expect(draft.media!.encodedBytes, 0);
      expect(
        await media.prepare(
          draft: draft,
          operation: pick(),
          produce: () async => '/stage/two',
        ),
        ComposerPreparationResult.staged,
      );
      expect(draft.media!.path, '/stage/two');
      expect(discarded, ['/stage/one']);
    },
  );

  test(
    'invalid replacement preserves original and cleans only candidate',
    () async {
      final media = preparer((path) async => path.endsWith('one') ? 1 : 11);
      await media.prepare(
        draft: draft,
        operation: pick(),
        produce: () async => '/stage/one',
      );
      expect(
        await media.prepare(
          draft: draft,
          operation: pick(),
          produce: () async => '/stage/two',
          maxBytes: 10,
        ),
        ComposerPreparationResult.invalid,
      );
      expect(draft.media!.path, '/stage/one');
      expect(discarded, ['/stage/two']);
    },
  );

  test('A-B-A during validation discards stale candidate', () async {
    final inspected = Completer<int?>();
    final started = Completer<void>();
    final media = preparer((_) {
      started.complete();
      return inspected.future;
    });
    final result = media.prepare(
      draft: draft,
      operation: pick(),
      produce: () async => '/stage/stale',
    );
    await started.future;
    draft.deactivate(owner);
    owner = Object();
    draft.activate(owner);
    inspected.complete(10);
    expect(await result, ComposerPreparationResult.stale);
    expect(draft.media, isNull);
    expect(discarded, ['/stage/stale']);
  });

  test('alias cannot delete the existing stage', () async {
    final media = preparer((_) async => 1);
    await media.prepare(
      draft: draft,
      operation: pick(),
      produce: () async => '/stage/one',
    );
    expect(
      await media.prepare(
        draft: draft,
        operation: pick(),
        produce: () async => '/stage/one',
      ),
      ComposerPreparationResult.invalid,
    );
    expect(draft.media!.path, '/stage/one');
    expect(discarded, isEmpty);
  });

  test('cancelled picker releases draft capacity', () async {
    final media = preparer((_) async => 1);
    expect(
      await media.prepare(
        draft: draft,
        operation: pick(),
        produce: () async => null,
      ),
      ComposerPreparationResult.cancelled,
    );
    expect(draft.isEmpty, isTrue);
  });

  test(
    'external account authority loss fences an otherwise active draft',
    () async {
      var current = true;
      final media = preparer((_) async {
        current = false;
        return 1;
      });
      expect(
        await media.prepare(
          draft: draft,
          operation: pick(),
          produce: () async => '/stage/new',
          isCurrent: () => current,
        ),
        ComposerPreparationResult.stale,
      );
      expect(discarded, ['/stage/new']);
      expect(draft.isEmpty, isTrue);
    },
  );

  test('removed successfully prepared stage releases draft capacity', () async {
    final media = preparer((_) async => 1);
    await media.prepare(
      draft: draft,
      operation: pick(),
      produce: () async => '/stage/one',
    );
    expect(draft.removeMedia(owner, draft.media!), isTrue);
    expect(draft.isEmpty, isTrue);
  });

  test(
    'inspection failure cleans candidate and keeps retained stage',
    () async {
      final media = preparer(
        (_) async => throw StateError('inspection failed'),
      );
      await expectLater(
        media.prepare(
          draft: draft,
          operation: pick(),
          produce: () async => '/stage/new',
        ),
        throwsStateError,
      );
      expect(discarded, ['/stage/new']);
      expect(draft.media, isNull);
    },
  );
}
