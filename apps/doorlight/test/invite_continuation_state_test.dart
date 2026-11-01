import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/invite_link.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/pending_invite.dart';

import 'app_state_test.dart' show FakeJami;

final class _DelayedFriendJami extends FakeJami {
  final completion = Completer<bool>();
  String? requestedOwner;
  @override
  Future<bool> addFriend(String peerJamiId, {String? expectedAccountId}) {
    requestedOwner = expectedAccountId;
    return completion.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'release-configured launch uses the same persisted confirmation pipeline',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final invite = SyblInviteLink.create(
        jamiId: 'c' * 40,
        displayName: 'Zoë & Mara',
      )!;
      final link = invite.shareUri();
      if (SyblInviteLink.configuredHttpsOrigin.isNotEmpty) {
        expect(
          link,
          startsWith('${SyblInviteLink.configuredHttpsOrigin}/invite/#'),
        );
      }
      final jami = _DelayedFriendJami()..initialInviteLink = link;
      final state = AppState(jami, prefs);
      await state.init();
      expect(state.pendingInvite, invite);
      final record = state.inviteContinuation.pending!;
      expect(jami.requestedOwner, isNull);
      jami.push('inviteLink', {
        'link': 'https://unconfigured.example.test/invite/#v=1&id=${'d' * 40}',
      });
      expect(state.inviteContinuation.pending, same(record));
      expect(state.inviteContinuation.replacement, isNull);
      expect(state.debugLog.join('\n'), isNot(contains(link)));
      await pumpEventQueue();
      state.dispose();
      final restarted = AppState(JamiClient(), prefs);
      addTearDown(restarted.dispose);
      expect(restarted.pendingInvite, invite);
      expect(
        restarted.inviteContinuation.pending!.receivedAt,
        record.receivedAt,
      );
    },
  );

  test(
    'launch and live hints survive restart outside settings and diagnostics',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final jami = FakeJami()
        ..initialInviteLink = 'doorlight://add/${'b' * 40}?name=Mara';
      final state = AppState(jami, prefs);
      await state.init();
      expect(state.pendingInvite!.displayName, 'Mara');
      final record = state.inviteContinuation.pending!;
      jami.push('inviteLink', {'link': 'secret-short-malformed-hint'});
      jami.push('inviteLink', {'link': 'sybl://add/${'c' * 40}?name=Lee'});
      expect(state.inviteContinuation.pending, same(record));
      expect(state.inviteContinuation.replacement!.invite.displayName, 'Lee');
      expect(state.debugLog.join('\n'), isNot(contains('inviteLink')));
      expect(
        state.debugLog.join('\n'),
        isNot(contains('secret-short-malformed-hint')),
      );
      final settings = jsonEncode(
        const AppSettingsCodec().encode(state.appSettings),
      );
      expect(settings, isNot(contains('Mara')));
      expect(settings, isNot(contains(PendingInviteStore.preferenceKey)));
      await pumpEventQueue();
      state.dispose();
      final next = AppState(JamiClient(), prefs);
      addTearDown(next.dispose);
      expect(next.pendingInvite!.displayName, 'Mara');
      expect(next.inviteContinuation.pending!.receivedAt, record.receivedAt);
      expect(next.inviteContinuation.replacement, isNull);
    },
  );

  for (final returnToOriginal in [false, true]) {
    test(
      'late Add Friend does not select a conversation after owner change (return=$returnToOriginal)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final jami = _DelayedFriendJami();
        final state = AppState(jami, await SharedPreferences.getInstance());
        addTearDown(state.dispose);
        await state.init();
        final original = state.accountId!;
        final add = state.addFriend('c' * 40);
        expect(jami.requestedOwner, original);
        state.accountId = 'replacement';
        if (returnToOriginal) state.accountId = original;
        jami.completion.complete(true);
        expect(await add, isFalse);
        expect(state.peerId, isNot('c' * 40));
      },
    );
  }
}
