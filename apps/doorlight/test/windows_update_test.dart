import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/windows_update.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/conversation_scope.dart';

void main() {
  test('verified selection binds version sequence and manifest', () {
    final result = <String, dynamic>{
      'schema': 1,
      'workerPid': 42,
      'state': 'checked',
      'eligible': true,
      'version': '1.2.0',
      'releaseSequence': 12,
      'manifestSha256': 'a' * 64,
    };
    final selected = verifiedUpdateSelection(result, '1.1.0')!;
    expect(selected.version, '1.2.0');
    expect(selected.sequence, 12);
    expect(selected.manifestSha256, 'a' * 64);
    for (final change in [
      {'state': 'error'},
      {'workerPid': 0},
      {'releaseSequence': 0},
      {'manifestSha256': 'a' * 63},
      {'version': '1.1.0'},
    ]) {
      expect(
        () => verifiedUpdateSelection({...result, ...change}, '1.1.0'),
        throwsFormatException,
      );
    }
    expect(
      verifiedUpdateSelection({...result, 'eligible': false}, '1.1.0'),
      isNull,
    );
    expect(() => verifiedUpdateSelection(null, '1.1.0'), throwsFormatException);
  });

  test(
    'automatic handoff is revoked by input during native preparation',
    () async {
      final policy = UpdateRestartPolicy();
      final preparing = Completer<bool>();
      var requested = false, committed = false, released = false;
      final handoff = UpdateRestartHandoff(
        policy: policy,
        automatic: () => true,
        reserve: () => true,
        stillSafe: () => true,
        prepare: () => preparing.future,
        commit: () async {
          committed = true;
          return true;
        },
        cancel: () async => true,
        release: () => released = true,
      );
      final result = handoff.run(
        requestApply: () async => requested = true,
        helperState: () async => 'shutdownReady',
        cancelApply: () async {},
      );
      policy.activity();
      preparing.complete(true);
      expect(await result, isFalse);
      expect(requested, isFalse);
      expect(committed, isFalse);
      expect(released, isTrue);
    },
  );

  test(
    'foreground return during helper acknowledgment prevents automatic quit',
    () async {
      final policy = UpdateRestartPolicy();
      policy.lifecycle(AppLifecycleState.inactive);
      var committed = false, cancelled = false;
      final handoff = UpdateRestartHandoff(
        policy: policy,
        automatic: () => true,
        reserve: () => true,
        stillSafe: () => true,
        prepare: () async => true,
        commit: () async {
          committed = true;
          return true;
        },
        cancel: () async => true,
        release: () {},
      );
      expect(
        await handoff.run(
          requestApply: () async {},
          helperState: () async {
            policy.lifecycle(AppLifecycleState.resumed);
            return 'shutdownReady';
          },
          cancelApply: () async => cancelled = true,
        ),
        isFalse,
      );
      expect(committed, isFalse);
      expect(cancelled, isTrue);
    },
  );

  test(
    'manual handoff still respects native veto and cancels its reservation',
    () async {
      var released = false, cancelSent = false;
      final handoff = UpdateRestartHandoff(
        policy: UpdateRestartPolicy(),
        automatic: () => false,
        reserve: () => true,
        stillSafe: () => true,
        prepare: () async => true,
        commit: () async => false,
        cancel: () async => true,
        release: () => released = true,
      );
      expect(
        await handoff.run(
          requestApply: () async {},
          helperState: () async => 'shutdownReady',
          cancelApply: () async => cancelSent = true,
        ),
        isFalse,
      );
      expect(released, isTrue);
      expect(cancelSent, isTrue);
    },
  );

  test('a helper that never acknowledges cannot close the app', () async {
    var committed = false, released = false;
    final handoff = UpdateRestartHandoff(
      policy: UpdateRestartPolicy(),
      automatic: () => false,
      reserve: () => true,
      stillSafe: () => true,
      prepare: () async => true,
      commit: () async {
        committed = true;
        return true;
      },
      cancel: () async => true,
      release: () => released = true,
    );
    expect(
      await handoff.run(
        requestApply: () async {},
        helperState: () async => 'ready',
        cancelApply: () async {},
        timeout: Duration.zero,
      ),
      isFalse,
    );
    expect(committed, isFalse);
    expect(released, isTrue);
  });

  test('idle time is monotonic and being active defers background updates', () {
    var elapsed = Duration.zero;
    final policy = UpdateRestartPolicy(elapsed: () => elapsed);
    policy.activity();
    elapsed = const Duration(minutes: 6);
    expect(policy.automaticEligible, isFalse);
    policy.lifecycle(AppLifecycleState.inactive);
    expect(policy.automaticEligible, isTrue);
    policy.lifecycle(AppLifecycleState.resumed);
    policy.lifecycle(AppLifecycleState.inactive);
    expect(policy.automaticEligible, isFalse);
    elapsed += const Duration(minutes: 5);
    expect(policy.automaticEligible, isTrue);
  });
  for (final stalled in ['prepare', 'helper', 'commit']) {
    test('stalled $stalled is cancelled before releasing input', () async {
      final nativeReply = Completer<bool>();
      final helperReply = Completer<String?>();
      final events = <String>[];
      final handoff = UpdateRestartHandoff(
        policy: UpdateRestartPolicy(),
        automatic: () => false,
        reserve: () => true,
        stillSafe: () => true,
        prepare: () =>
            stalled == 'prepare' ? nativeReply.future : Future.value(true),
        commit: () => nativeReply.future,
        cancel: () async {
          events.add('cancel native');
          return true;
        },
        release: () => events.add('release input'),
      );
      await expectLater(
        handoff.run(
          requestApply: () async {},
          helperState: () => stalled == 'helper'
              ? helperReply.future
              : Future.value('shutdownReady'),
          cancelApply: () async => events.add('cancel helper'),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      final expected = [
        'cancel native',
        if (stalled != 'prepare') 'cancel helper',
        'release input',
      ];
      expect(events, expected);
      nativeReply.complete(true);
      helperReply.complete('shutdownReady');
      await Future<void>.delayed(Duration.zero);
      expect(events, expected);
    });
  }
  test('an already committed quit keeps the helper armed', () async {
    final commitReply = Completer<bool>();
    var helperCancelled = false, released = false;
    final handoff = UpdateRestartHandoff(
      policy: UpdateRestartPolicy(),
      automatic: () => false,
      reserve: () => true,
      stillSafe: () => true,
      prepare: () async => true,
      commit: () => commitReply.future,
      cancel: () async => false,
      release: () => released = true,
    );
    await expectLater(
      handoff.run(
        requestApply: () async {},
        helperState: () async => 'shutdownReady',
        cancelApply: () async => helperCancelled = true,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(helperCancelled, isFalse);
    expect(released, isFalse);
    commitReply.complete(true);
  });
  test('foreground return ends untouched startup eligibility', () {
    var elapsed = Duration.zero;
    final policy = UpdateRestartPolicy(elapsed: () => elapsed);
    expect(policy.automaticEligible, isTrue);
    policy.lifecycle(AppLifecycleState.inactive);
    policy.lifecycle(AppLifecycleState.resumed);
    expect(policy.automaticEligible, isFalse);
    policy.lifecycle(AppLifecycleState.inactive);
    elapsed = const Duration(minutes: 4, seconds: 59);
    expect(policy.automaticEligible, isFalse);
    elapsed = const Duration(minutes: 5);
    expect(policy.automaticEligible, isTrue);
  });
  for (final foregroundReturn in [false, true]) {
    test(
      'automatic commit is revoked by ${foregroundReturn ? 'foreground return' : 'input'}',
      () async {
        final policy = UpdateRestartPolicy();
        if (foregroundReturn) policy.lifecycle(AppLifecycleState.inactive);
        final commitStarted = Completer<void>();
        final commitReply = Completer<bool>();
        final events = <String>[];
        final handoff = UpdateRestartHandoff(
          policy: policy,
          automatic: () => true,
          reserve: () => true,
          stillSafe: () => true,
          prepare: () async => true,
          commit: () {
            commitStarted.complete();
            return commitReply.future;
          },
          cancel: () async {
            events.add('cancel native');
            return true;
          },
          release: () => events.add('release input'),
        );
        final result = handoff.run(
          requestApply: () async {},
          helperState: () async => 'shutdownReady',
          cancelApply: () async => events.add('cancel helper'),
        );
        await commitStarted.future;
        if (foregroundReturn) {
          policy.lifecycle(AppLifecycleState.resumed);
        } else {
          policy.activity();
        }
        expect(await result.timeout(const Duration(seconds: 1)), isFalse);
        expect(events, ['cancel native', 'cancel helper', 'release input']);
        commitReply.complete(true);
        await Future<void>.delayed(Duration.zero);
        expect(events.length, 3);
      },
    );
  }
  test('manual commit is retained when the user returns', () async {
    final policy = UpdateRestartPolicy();
    final commitStarted = Completer<void>();
    final commitReply = Completer<bool>();
    var cancelled = false, released = false;
    final handoff = UpdateRestartHandoff(
      policy: policy,
      automatic: () => false,
      reserve: () => true,
      stillSafe: () => true,
      prepare: () async => true,
      commit: () {
        commitStarted.complete();
        return commitReply.future;
      },
      cancel: () async => cancelled = true,
      release: () => released = true,
    );
    final result = handoff.run(
      requestApply: () async {},
      helperState: () async => 'shutdownReady',
      cancelApply: () async {},
    );
    await commitStarted.future;
    policy.activity();
    commitReply.complete(true);
    expect(await result, isTrue);
    expect(cancelled, isFalse);
    expect(released, isFalse);
  });
  test('release ordering is numeric and rejects unsupported versions', () {
    expect(WindowsUpdate.newer('1.10.0', '1.9.9'), isTrue);
    for (final candidate in [
      '1.0.0',
      '0.9.9',
      'v2.0.0',
      '2.0.0-preview',
      '2.0',
      '../2.0.0',
    ]) {
      expect(WindowsUpdate.newer(candidate, '1.0.0'), isFalse);
    }
  });

  test('idle update gate preserves drafts and active recording operations', () {
    final store = ComposerDraftStore();
    final key = ComposerDraftKey(
      ConversationScope(
        accountId: 'account',
        peerId: 'peer',
        conversationId: 'chat',
      ),
      'main',
    );
    final draft = store.acquire(key)!;
    final owner = Object();
    draft.activate(owner);
    expect(store.hasUnfinishedDrafts, isFalse);
    draft.updateText(owner, const TextEditingValue(text: 'Unsent'));
    expect(store.hasUnfinishedDrafts, isTrue);
    draft.updateText(owner, TextEditingValue.empty);
    final recording = draft.begin(ComposerOperationKind.recording, owner);
    expect(recording, isNotNull);
    expect(store.hasUnfinishedDrafts, isTrue);
  });
}
