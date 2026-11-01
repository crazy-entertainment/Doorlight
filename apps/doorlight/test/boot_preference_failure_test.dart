import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' show FakeJami;

class _BootJami extends FakeJami {
  int eventSubscriptions = 0;
  Completer<String>? pendingInvite;
  Object? restoreCheckFailure;
  @override
  Future<Map<String, dynamic>> getPendingIdentityRestore() async {
    if (restoreCheckFailure case final error?) throw error;
    return super.getPendingIdentityRestore();
  }

  @override
  Future<String> takeInitialInviteLink() =>
      pendingInvite?.future ?? super.takeInitialInviteLink();
  @override
  Future<ConversationLaunchTarget?> takeInitialConversation() async {
    final target = initialConversation;
    initialConversation = null;
    return target;
  }

  @override
  Stream<JamiEvent> events() {
    eventSubscriptions++;
    return super.events();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final error in [
    PlatformException(
      code: 'native_startup_failed',
      message: 'private identity path',
      details: 'secret account',
    ),
    StateError('private identity path'),
  ]) {
    test(
      'startup details explain the step without private exception text (${error.runtimeType})',
      () async {
        SharedPreferences.setMockInitialValues({});
        final jami = _BootJami()..restoreCheckFailure = error;
        final state = AppState(jami, await SharedPreferences.getInstance());
        addTearDown(state.dispose);
        await state.init();
        expect(state.bootErrorDetails, contains('Opening the saved profile'));
        expect(
          state.bootErrorDetails,
          isNot(contains('private identity path')),
        );
        expect(state.bootErrorDetails, isNot(contains('secret account')));
        if (error is PlatformException) {
          expect(state.bootErrorDetails, contains('native_startup_failed'));
        }
        jami.restoreCheckFailure = null;
        await state.retryBoot();
        expect(state.bootError, isNull);
        expect(state.bootErrorDetails, isNull);
      },
    );
  }

  test('startup retry preserves a consumed notification destination', () async {
    final peer = 'b' * 40;
    SharedPreferences.setMockInitialValues({'displayName': 123});
    final prefs = await SharedPreferences.getInstance();
    final jami = _BootJami();
    jami.daemonFriends[peer] = JamiFriend(
      peerJamiId: peer,
      confirmed: true,
      conversationId: 'notification-conversation',
    );
    jami.initialConversation = ConversationLaunchTarget(
      ownerKey: peer,
      conversationId: 'notification-conversation',
    );
    final state = AppState(jami, prefs);
    addTearDown(state.dispose);
    await state.init();
    expect(state.bootError, isNotNull);
    expect(jami.initialConversation, isNull);
    await prefs.remove('displayName');
    await state.retryBoot();
    expect(state.bootError, isNull);
    expect(state.peerId, peer);
    expect(
      jami.dismissedMessageNotifications,
      contains('notification-conversation'),
    );
  });

  test('concurrent init and retry share startup preparation', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final jami = _BootJami()..pendingInvite = Completer<String>();
    final state = AppState(jami, prefs);
    addTearDown(state.dispose);
    final first = state.init();
    final retry = state.retryBoot();
    expect(identical(first, retry), isTrue);
    jami.pendingInvite!.complete('');
    await Future.wait([first, retry]);
    expect(state.bootError, isNull);
    expect(jami.eventSubscriptions, 1);
    expect(
      jami.calls.where((value) => value.startsWith('ensureAccount:')),
      hasLength(1),
    );
  });

  test(
    'disposed startup cannot reach account boot after a late read',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final jami = _BootJami()..pendingInvite = Completer<String>();
      final state = AppState(jami, prefs);
      final pending = state.init();
      state.dispose();
      jami.pendingInvite!.complete('');
      await pending;
      expect(
        jami.calls.where((value) => value.startsWith('ensureAccount:')),
        isEmpty,
      );
      expect(jami.messagePreviewCalls, isEmpty);
      expect(jami.captureApplyCalls, isEmpty);
    },
  );

  for (final key in [
    'accountId',
    'displayName',
    'profileAvatarBase64',
    'appearOffline',
    'connectionProfile',
    'strictBootstrap',
    'strictTurnServer',
    'strictTurnRealm',
    'strictTurnUser',
    'strictTurnPassword',
  ]) {
    test(
      'wrong-type $key remains visible and retry cannot bypass startup policy',
      () async {
        SharedPreferences.setMockInitialValues({key: 123});
        final prefs = await SharedPreferences.getInstance();
        final jami = _BootJami();
        final state = AppState(jami, prefs);
        addTearDown(state.dispose);

        await expectLater(state.init(), completes);
        expect(state.bootError, isNotEmpty);
        expect(state.screen, Screen.loading);
        expect(
          jami.calls.where((value) => value.startsWith('ensureAccount:')),
          isEmpty,
        );
        expect(
          prefs.get(key),
          123,
          reason: 'Failure must not rewrite corrupt user state.',
        );

        await state.retryBoot();
        expect(state.bootError, isNotEmpty);
        expect(
          jami.calls.where((value) => value.startsWith('ensureAccount:')),
          isEmpty,
        );
        // The fixture repairs only its synthetic input; the product never does.
        await prefs.remove(key);
        await state.retryBoot();
        expect(state.bootError, isNull);
        expect(state.screen, isNot(Screen.loading));
        expect(
          jami.eventSubscriptions,
          1,
          reason: 'Retry must not duplicate event ownership.',
        );
      },
    );
  }
}
