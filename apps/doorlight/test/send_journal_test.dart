import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/send_journal.dart';

void main() {
  final scope = ConversationScope(
    accountId: 'account',
    peerId: 'peer',
    conversationId: 'conversation',
  );
  final record = SendJournalRecord(
    operationId: 'a' * 32,
    scope: scope,
    status: ComposerSendStatus.pending,
  );

  test(
    'preparing a malformed reaction never persists or reserves its operation',
    () async {
      final writes = <String>[];
      final journal = SendJournal(
        source: null,
        persist: (source) async {
          writes.add(source);
          return true;
        },
      );
      for (final target in ['', 'HEAD', 'a' * 39, 'a' * 41, '${'a' * 40}\n']) {
        expect(
          await journal.prepare(
            SendJournalRecord(
              operationId: record.operationId,
              scope: scope,
              status: ComposerSendStatus.pending,
              reactionTarget: target,
            ),
          ),
          isFalse,
        );
        expect(journal.record(record.operationId), isNull);
      }
      expect(writes, isEmpty);
      expect(await journal.prepare(record), isTrue);
      expect(writes, hasLength(1));
    },
  );

  test(
    'reaction issue is serialized by exact owner and survives restart',
    () async {
      String? saved;
      final journal = SendJournal(
        source: null,
        persist: (source) async {
          saved = source;
          return true;
        },
      );
      SendJournalRecord reaction(
        String operation, {
        ConversationScope? owner,
        String? target,
      }) => SendJournalRecord(
        operationId: operation * 32,
        scope: owner ?? scope,
        status: ComposerSendStatus.pending,
        reactionTarget: target ?? 'c' * 40,
      );
      expect(await journal.prepare(reaction('a')), isTrue);
      expect(await journal.prepare(reaction('b')), isFalse);
      expect(journal.reactionUnresolved(scope, 'c' * 40), isTrue);
      final restored = SendJournal(source: saved, persist: (_) async => true);
      expect(restored.record('a' * 32)!.status, ComposerSendStatus.unknown);
      expect(await restored.prepare(reaction('b')), isFalse);
      expect(await restored.acknowledge('a' * 32), isFalse);
      expect(await restored.prepare(reaction('b', target: 'd' * 40)), isTrue);
      final other = ConversationScope(
        accountId: 'other',
        peerId: scope.peerId,
        conversationId: scope.conversationId,
      );
      expect(await restored.prepare(reaction('e', owner: other)), isTrue);
      expect(
        await restored.complete(
          'a' * 32,
          scope,
          ComposerSendStatus.committed,
          commitId: 'f' * 40,
        ),
        isTrue,
      );
      expect(restored.record('a' * 32)!.reactionTarget, 'c' * 40);
      expect(await restored.acknowledge('a' * 32), isTrue);
      expect(await restored.prepare(reaction('f')), isTrue);
    },
  );

  test(
    'reaction journal rejects malformed and mixed file command metadata',
    () async {
      for (final target in [null, '', 'HEAD', 'a' * 41]) {
        expect(
          SendJournalRecord.parse({
            ...record.toMap(),
            'reactionTarget': target,
          }),
          isNull,
        );
      }
      expect(
        SendJournalRecord.parse({
          ...record.toMap(),
          'reactionTarget': 'c' * 40,
          'stage': 'b' * 32,
        }),
        isNull,
      );
      expect(
        SendJournalRecord.parse({...record.toMap(), 'unexpected': 'c' * 40}),
        isNull,
      );
      final missingStage = {...record.toMap(), 'reactionTarget': 'c' * 40}
        ..remove('stage');
      expect(SendJournalRecord.parse(missingStage), isNull);
      final journal = SendJournal(source: null, persist: (_) async => true);
      expect(
        await journal.prepare(
          SendJournalRecord(
            operationId: 'a' * 32,
            scope: scope,
            status: ComposerSendStatus.pending,
            reactionTarget: 'c' * 40,
            stageReference: 'b' * 32,
          ),
        ),
        isFalse,
      );
    },
  );

  test('native load gates issue and migrates before a new command', () async {
    final loaded = Completer<String?>();
    final writes = <String>[];
    final journal = SendJournal(
      source: null,
      load: () => loaded.future,
      persist: (value) async {
        writes.add(value);
        return true;
      },
    );
    final preparing = journal.prepare(record);
    await Future<void>.delayed(Duration.zero);
    expect(writes, isEmpty);
    loaded.complete(null);
    expect(await preparing, isTrue);
    expect(writes, hasLength(2));
    expect((jsonDecode(writes.first) as Map)['operations'], isEmpty);
  });

  test('unreadable native journal never falls back or overwrites', () async {
    var writes = 0;
    final journal = SendJournal(
      source: null,
      load: () async => throw StateError('unavailable'),
      persist: (_) async {
        writes++;
        return true;
      },
    );
    expect(await journal.prepare(record), isFalse);
    expect(journal.healthy, isFalse);
    expect(writes, 0);
  });

  test('authoritative native journal overrides corrupt legacy data', () async {
    final journal = SendJournal(
      source: 'broken',
      load: () async => jsonEncode({
        'v': 1,
        'operations': [record.toMap()],
      }),
      persist: (_) async => true,
    );
    await journal.initialized;
    expect(journal.healthy, isTrue);
    expect(
      journal.record(record.operationId)!.status,
      ComposerSendStatus.unknown,
    );
    expect(await journal.prepare(record), isFalse);
  });

  test(
    'failed migration blocks commands and preserves legacy evidence',
    () async {
      var writes = 0;
      final journal = SendJournal(
        source: jsonEncode({
          'v': 1,
          'operations': [record.toMap()],
        }),
        load: () async => null,
        persist: (_) async {
          writes++;
          return false;
        },
      );
      await journal.initialized;
      expect(journal.healthy, isFalse);
      expect(journal.record(record.operationId), isNotNull);
      expect(await journal.prepare(record), isFalse);
      expect(writes, 1);
    },
  );

  test(
    'committed files retain repair references until exact seed acknowledgement',
    () async {
      String? saved;
      final journal = SendJournal(
        source: null,
        persist: (value) async {
          saved = value;
          return true;
        },
      );
      await journal.prepare(
        SendJournalRecord(
          operationId: record.operationId,
          scope: scope,
          status: ComposerSendStatus.pending,
          stageReference: 'b' * 32,
        ),
      );
      await journal.complete(
        record.operationId,
        scope,
        ComposerSendStatus.committed,
        commitId: 'commit',
      );
      expect(await journal.acknowledge(record.operationId), isFalse);
      final restored = SendJournal(source: saved, persist: (_) async => true);
      expect(restored.record(record.operationId)!.stageReference, 'b' * 32);
      expect(
        await restored.acknowledgeSeed(record.operationId, scope, 'wrong'),
        isFalse,
      );
      expect(
        await restored.acknowledgeSeed(record.operationId, scope, 'commit'),
        isTrue,
      );
      expect(await restored.acknowledge(record.operationId), isTrue);
    },
  );

  test(
    'seed readiness before commit callback resolves only its original operation',
    () async {
      final journal = SendJournal(source: null, persist: (_) async => true);
      await journal.prepare(
        SendJournalRecord(
          operationId: record.operationId,
          scope: scope,
          status: ComposerSendStatus.pending,
          stageReference: 'b' * 32,
        ),
      );
      final waiting = journal.wait(record.operationId);
      expect(
        await journal.acknowledgeSeed(record.operationId, scope, 'commit'),
        isTrue,
      );
      expect((await waiting)!.status, ComposerSendStatus.committed);
      expect(journal.record(record.operationId)!.stageReference, isNull);
      expect(
        await journal.complete(
          record.operationId,
          scope,
          ComposerSendStatus.unknown,
        ),
        isFalse,
      );
    },
  );

  test(
    'failed persistence never makes an operation eligible to issue and retry preserves exact ID',
    () async {
      var succeeds = false;
      final journal = SendJournal(source: null, persist: (_) async => succeeds);
      expect(await journal.prepare(record), isFalse);
      expect(journal.record(record.operationId), isNull);
      succeeds = true;
      expect(await journal.prepare(record), isTrue);
      expect(await journal.prepare(record), isFalse);
    },
  );

  test(
    'restart converts issued pending to unknown without storing message bodies',
    () async {
      String? saved;
      final journal = SendJournal(
        source: null,
        persist: (value) async {
          saved = value;
          return true;
        },
      );
      await journal.prepare(record);
      final decoded = jsonDecode(saved!);
      expect(decoded['operations'][0].keys.toSet(), {
        'operationId',
        'scope',
        'status',
        'commitId',
        'stage',
      });
      final restored = SendJournal(source: saved, persist: (_) async => true);
      expect(
        restored.record(record.operationId)!.status,
        ComposerSendStatus.unknown,
      );
      expect(await restored.acknowledge(record.operationId), isFalse);
    },
  );

  test(
    'callback before reply wins and late pending or unknown cannot erase commit',
    () async {
      final journal = SendJournal(source: null, persist: (_) async => true);
      await journal.prepare(record);
      await journal.complete(
        record.operationId,
        scope,
        ComposerSendStatus.committed,
        commitId: 'commit',
      );
      expect(
        await journal.complete(
          record.operationId,
          scope,
          ComposerSendStatus.unknown,
        ),
        isFalse,
      );
      expect((await journal.wait(record.operationId))!.commitId, 'commit');
      expect(await journal.acknowledge(record.operationId), isTrue);
    },
  );

  test('timeout is unknown and a later exact callback repairs it', () async {
    final journal = SendJournal(source: null, persist: (_) async => true);
    await journal.prepare(record);
    expect(
      (await journal.wait(record.operationId, timeout: Duration.zero))!.status,
      ComposerSendStatus.unknown,
    );
    expect(
      await journal.complete(
        record.operationId,
        ConversationScope(
          accountId: 'foreign',
          peerId: 'peer',
          conversationId: 'conversation',
        ),
        ComposerSendStatus.committed,
        commitId: 'wrong',
      ),
      isFalse,
    );
    expect(
      await journal.complete(
        record.operationId,
        scope,
        ComposerSendStatus.committed,
        commitId: 'late',
      ),
      isTrue,
    );
    expect(journal.record(record.operationId)!.commitId, 'late');
  });

  test(
    'corrupt future and over-limit journals remain closed without overwrite',
    () async {
      for (final source in [
        '{',
        '{"v":2,"operations":[]}',
        ' ' * (SendJournal.maximumBytes + 1),
      ]) {
        var writes = 0;
        final journal = SendJournal(
          source: source,
          persist: (_) async {
            writes++;
            return true;
          },
        );
        expect(journal.healthy, isFalse);
        expect(await journal.prepare(record), isFalse);
        expect(writes, 0);
      }
    },
  );

  test(
    'unresolved bound refuses new work and never silently evicts a command',
    () async {
      final journal = SendJournal(source: null, persist: (_) async => true);
      for (var index = 0; index < SendJournal.maximumOperations; index++) {
        expect(
          await journal.prepare(
            SendJournalRecord(
              operationId: index.toRadixString(16).padLeft(32, '0'),
              scope: scope,
              status: ComposerSendStatus.pending,
            ),
          ),
          isTrue,
        );
      }
      expect(await journal.prepare(record), isFalse);
      expect(journal.unresolved.length, SendJournal.maximumOperations);
    },
  );

  test('journal requires an integer schema and explicit scope kind', () async {
    final invalidRecords = [
      {
        ...record.toMap(),
        'scope': {...scope.toMap(), 'kind': 'future'},
      },
      {
        ...record.toMap(),
        'scope': {...scope.toMap()}..remove('kind'),
      },
    ];
    final sources = [
      jsonEncode({'v': 1.0, 'operations': []}),
      for (final invalid in invalidRecords)
        jsonEncode({
          'v': 1,
          'operations': [invalid],
        }),
    ];
    for (final source in sources) {
      var writes = 0;
      final journal = SendJournal(
        source: source,
        persist: (_) async {
          writes++;
          return true;
        },
      );
      expect(journal.healthy, isFalse);
      expect(await journal.prepare(record), isFalse);
      expect(writes, 0);
    }
  });
}
