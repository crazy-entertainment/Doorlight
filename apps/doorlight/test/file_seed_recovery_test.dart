import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/send_journal.dart';

import 'app_state_test.dart' show FakeJami;

class _SeedNative extends FakeJami {
  final repairs = <(String, String, String, String)>[];
  final results = <Completer<bool>>[];
  @override
  Future<bool> acknowledgeFileSeed({
    required String accountId,
    required String conversationId,
    required String operationId,
    required String commitId,
  }) {
    repairs.add((accountId, conversationId, operationId, commitId));
    final result = Completer<bool>();
    results.add(result);
    return result.future;
  }
}

Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = ConversationScope(
    accountId: 'acc1',
    peerId: 'peer',
    conversationId: 'conversation',
  );
  final operation = 'a' * 32;
  final commit = 'b' * 40;
  test(
    'failed native seed acknowledgement retains repair evidence until success',
    () async {
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
      });
      final native = _SeedNative()..accountExists = true;
      final state = AppState(native, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      expect(
        await state.sendJournal.prepare(
          SendJournalRecord(
            operationId: operation,
            scope: scope,
            status: ComposerSendStatus.pending,
            stageReference: operation,
          ),
        ),
        isTrue,
      );
      void seed({String account = 'acc1'}) => native.push('fileSeedReady', {
        'accountId': account,
        'peerJamiId': 'peer',
        'conversationId': 'conversation',
        'operationId': operation,
        'commitId': commit,
        'fileId': '${commit}_1',
        'ready': false,
      });
      seed(account: 'other');
      await _drain();
      expect(native.repairs, isEmpty);
      seed();
      await _drain();
      expect(native.repairs.single, (
        'acc1',
        'conversation',
        operation,
        commit,
      ));
      expect(state.sendJournal.record(operation)!.stageReference, operation);
      native.results.first.complete(false);
      await _drain();
      expect(state.sendJournal.record(operation)!.stageReference, operation);
      seed();
      await _drain();
      expect(native.repairs, hasLength(2));
      native.results.last.complete(true);
      await _drain();
      expect(state.sendJournal.record(operation)!.stageReference, isNull);
      expect(state.sendJournal.record(operation)!.commitId, commit);
    },
  );

  test(
    'restart repairs original committed operation without sending again',
    () async {
      final record = SendJournalRecord(
        operationId: operation,
        scope: scope,
        status: ComposerSendStatus.committed,
        commitId: commit,
        stageReference: operation,
      );
      SharedPreferences.setMockInitialValues({
        'displayName': 'Me',
        'accountId': 'acc1',
        SendJournal.preferenceKey: jsonEncode({
          'v': 1,
          'operations': [record.toMap()],
        }),
      });
      final native = _SeedNative()..accountExists = true;
      final state = AppState(native, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      await _drain();
      expect(native.repairs.single, (
        'acc1',
        'conversation',
        operation,
        commit,
      ));
      expect(native.sendFileCalls, 0);
      native.results.single.complete(true);
      await _drain();
      expect(state.sendJournal.record(operation)!.stageReference, isNull);
    },
  );
}
