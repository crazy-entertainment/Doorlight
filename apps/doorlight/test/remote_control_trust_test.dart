import 'package:sybl/ui/notice.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/state/remote_control.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/friend_rail.dart';
import 'package:sybl/ui/remote_control_surface.dart';

import 'app_state_test.dart' show FakeJami;

final _peer = 'b' * 40;
final _other = 'c' * 40;
final _device = 'd' * 40;

class _TrustJami extends FakeJami {
  String removal = 'ok';
  final pendingRemovals = <String, Completer<void>>{};
  final removalStarted = <String, Completer<void>>{};
  int friendReads = 0;
  Completer<JamiFriendList>? pendingFriends;
  Completer<void>? pendingHostBlock;
  Completer<void>? offlineCompletion;
  final offlineStarted = Completer<void>();
  Completer<void>? pendingSubscriptions;
  final subscriptionsStarted = Completer<void>();
  RemoteControlHostAuthority authority = const RemoteControlHostAuthority(
    channelEpoch: 1,
    surfaceRevision: 0,
    hostGeneration: 0,
    revokedThrough: 0,
    blocked: true,
    releaseComplete: true,
    state: 'inactive',
  );

  @override
  Future<JamiFriendList> listFriends() async {
    friendReads++;
    return pendingFriends?.future ?? super.listFriends();
  }

  @override
  Future<void> setAppearOffline(bool on, {String? expectedAccountId}) async {
    final pending = offlineCompletion;
    if (pending == null) return super.setAppearOffline(on);
    calls.add('appearOffline:$on');
    offlineStarted.complete();
    await pending.future;
  }

  @override
  Future<void> setPresenceSubscriptions(Iterable<String> peerJamiIds) async {
    final pending = pendingSubscriptions;
    if (pending != null) {
      subscriptionsStarted.complete();
      await pending.future;
    }
    await super.setPresenceSubscriptions(peerJamiIds);
  }

  @override
  Future<void> removeContact(String uri, {bool block = false}) async {
    final result = removal;
    if (result == 'refused') throw StateError('synthetic removal refused');
    final pending = pendingRemovals[uri];
    if (pending != null) {
      removalStarted[uri]?.complete();
      await pending.future;
    }
    await super.removeContact(uri, block: block);
    if (result == 'partial') {
      throw PlatformException(
        code: 'operation_rejected',
        message: 'synthetic grant purge failure',
      );
    }
  }

  @override
  Future<RemoteControlHostAuthority?> remoteControlHostAuthority() async =>
      authority;

  @override
  Future<RemoteControlHostAuthority?> setRemoteControlProtectedSurface({
    required int channelEpoch,
    required int surfaceRevision,
    required bool blocked,
  }) async {
    calls.add('controlSurface:$blocked');
    if (blocked) await pendingHostBlock?.future;
    authority = RemoteControlHostAuthority(
      channelEpoch: channelEpoch,
      surfaceRevision: surfaceRevision,
      hostGeneration: authority.hostGeneration,
      revokedThrough: blocked
          ? authority.hostGeneration
          : authority.revokedThrough,
      blocked: blocked,
      releaseComplete: true,
      state: 'inactive',
    );
    return authority;
  }

  @override
  Future<bool> endRemoteControl({
    required String callId,
    required String peerJamiId,
    required int sourceRevision,
    required String androidPacket,
  }) async {
    calls.add('controlEnd:$callId:$peerJamiId');
    return true;
  }
}

class _Preferences extends Fake implements SharedPreferences {
  _Preferences(this.stored);
  final SharedPreferences stored;
  Completer<void>? holdColorRemoval;
  final colorRemovalStarted = Completer<void>();
  Completer<void>? holdSelectedFriendWrite;
  final selectedFriendWriteStarted = Completer<void>();
  String heldSelectionKey = 'selectedFriendId';
  bool holdBeforeSelectionWrite = false;
  bool failHeldSelectionWrite = false;
  @override
  Object? get(String key) => stored.get(key);
  @override
  bool containsKey(String key) => stored.containsKey(key);
  @override
  String? getString(String key) => stored.getString(key);
  @override
  bool? getBool(String key) => stored.getBool(key);
  @override
  int? getInt(String key) => stored.getInt(key);
  @override
  Future<bool> setString(String key, String value) async {
    final held =
        key == heldSelectionKey &&
        holdSelectedFriendWrite != null &&
        !selectedFriendWriteStarted.isCompleted;
    if (held && holdBeforeSelectionWrite) {
      selectedFriendWriteStarted.complete();
      await holdSelectedFriendWrite!.future;
    }
    if (held && failHeldSelectionWrite) {
      throw StateError('synthetic selection write failure');
    }
    final result = await stored.setString(key, value);
    if (held && !holdBeforeSelectionWrite) {
      selectedFriendWriteStarted.complete();
      await holdSelectedFriendWrite!.future;
    }
    return result;
  }

  @override
  Future<bool> setBool(String key, bool value) => stored.setBool(key, value);
  @override
  Future<bool> remove(String key) async {
    if (key == 'friendIdentityColor.v1.$_peer' && holdColorRemoval != null) {
      colorRemovalStarted.complete();
      await holdColorRemoval!.future;
    }
    return stored.remove(key);
  }
}

Future<(AppState, _TrustJami, _Preferences)> _boot({
  bool active = false,
  String? target,
}) async {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }
  SharedPreferences.setMockInitialValues({
    'friendIdentityColor.v1.$_peer': 'amber',
  });
  final jami = _TrustJami();
  for (final peer in [_peer, _other]) {
    jami.daemonFriends[peer] = JamiFriend(
      peerJamiId: peer,
      confirmed: true,
      conversationId: 'conversation-$peer',
    );
  }
  jami.daemonGroups['group-selection'] = const JamiGroup(
    conversationId: 'group-selection',
    title: 'Selection fixture',
    memberCount: 1,
    canManageMembers: true,
    localRole: JamiGroupMemberRole.admin,
    members: [
      JamiGroupMember(
        peerJamiId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        role: JamiGroupMemberRole.admin,
      ),
    ],
  );
  final preferences = _Preferences(await SharedPreferences.getInstance());
  final state = AppState(jami, preferences);
  addTearDown(state.dispose);
  await state.init();
  state.seedCaptureStateForTesting(
    resolved: true,
    applied: WindowCaptureProtectionStatus.exclude,
  );
  final peer = target ?? _peer;
  state.call = CallSession(
    callId: 'control-call',
    dir: CallDir.outgoing,
    peerId: peer,
    state: 'CURRENT',
    remoteActive: true,
    remoteWidth: 1200,
    remoteHeight: 800,
    peerVideo: true,
    peerVideoKind: OutgoingVideoKind.screen,
  );
  state.annotation.syncSources(
    localOwner: state.jamiId,
    peerOwner: peer,
    localRevision: 1,
    localKind: OutgoingVideoKind.off,
    peerKind: OutgoingVideoKind.screen,
  );
  state.annotation.applyInbound(
    '{"v":1,"t":"src","sourceOwner":"$peer","sourceRevision":4,"sourceKind":"screen"}',
  );
  expect(await state.requestRemoteControl(), isTrue);
  if (active) {
    jami.push('remoteControlControllerState', {
      'accountId': state.accountId,
      'callId': 'control-call',
      'peerJamiId': peer,
      'peerDeviceId': _device,
      'sourceRevision': 4,
      'controlCapabilities': 117,
      'state': 'active',
    });
    expect(state.remoteControl.isControlling, isTrue);
  }
  return (state, jami, preferences);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final active in [false, true]) {
    for (final removed in [false, true]) {
      test(
        '${active ? 'active' : 'pending'} control retires when friend becomes ${removed ? 'absent' : 'unconfirmed'}',
        () async {
          final (state, jami, _) = await _boot(active: active);
          if (removed) {
            jami.daemonFriends.remove(_peer);
          } else {
            jami.daemonFriends[_peer] = JamiFriend(
              peerJamiId: _peer,
              confirmed: false,
              conversationId: 'conversation-$_peer',
            );
          }
          jami.friendsRevision++;
          jami.push('friendsChanged', {'accountId': state.accountId});
          await pumpEventQueue();
          expect(state.remoteControl.controllerBinding, isNull);
          expect(state.remoteControl.canRequest, isFalse);
          expect(jami.calls, contains('controlEnd:control-call:$_peer'));
          expect(await state.requestRemoteControl(), isFalse);
        },
      );
    }
  }

  test('trust retirement happens before delayed preference cleanup', () async {
    final (state, jami, prefs) = await _boot(active: true);
    prefs.holdColorRemoval = Completer<void>();
    jami.daemonFriends.remove(_peer);
    jami.friendsRevision++;
    jami.push('friendsChanged', {'accountId': state.accountId});
    await prefs.colorRemovalStarted.future;
    try {
      expect(state.remoteControl.controllerBinding, isNull);
    } finally {
      prefs.holdColorRemoval!.complete();
    }
    await pumpEventQueue();
  });

  test('older friend refresh cannot trim newer wake authorization', () async {
    final (state, jami, prefs) = await _boot(active: true, target: _other);
    prefs.holdColorRemoval = Completer<void>();
    jami.daemonFriends.remove(_peer);
    jami.friendsRevision++;
    jami.push('friendsChanged', {'accountId': state.accountId});
    await prefs.colorRemovalStarted.future;
    final added = 'e' * 40;
    try {
      jami.daemonFriends[added] = JamiFriend(
        peerJamiId: added,
        confirmed: true,
        conversationId: 'new-conversation',
      );
      jami.friendsRevision++;
      jami.push('friendsChanged', {'accountId': state.accountId});
      await pumpEventQueue();
      jami.push('wakeCapability', {'fromJamiId': added, 'handle': 'A' * 43});
      await pumpEventQueue();
      expect(
        jsonDecode(prefs.getString('wakeCapabilitiesV1')!),
        contains(added),
      );
    } finally {
      prefs.holdColorRemoval!.complete();
    }
    await pumpEventQueue();
    expect(state.friends[added]?.confirmed, isTrue);
    expect(jsonDecode(prefs.getString('wakeCapabilitiesV1')!), contains(added));
    expect(state.remoteControl.isControlling, isTrue);
  });

  test('late friend refresh cannot replay across account A-B-A', () async {
    final (state, jami, _) = await _boot();
    final pending = Completer<void>();
    jami.pendingSubscriptions = pending;
    final replayCount = jami.replayPendingNativeEventsCalls;
    jami.push('friendsChanged', {'accountId': state.accountId});
    await jami.subscriptionsStarted.future;
    state.accountId = 'account-b';
    state.accountId = 'acc1';
    pending.complete();
    await pumpEventQueue();
    expect(jami.replayPendingNativeEventsCalls, replayCount);
  });

  for (final returnToOriginal in [false, true]) {
    test(
      'friend refresh selection writes stop after navigation: A-B-A=$returnToOriginal',
      () async {
        final (state, jami, prefs) = await _boot();
        await state.selectFriend(_peer);
        final pending = Completer<void>();
        prefs.holdSelectedFriendWrite = pending;
        jami.push('friendsChanged', {'accountId': state.accountId});
        await prefs.selectedFriendWriteStarted.future;
        late int subscriptions;
        late int replayCount;
        final selections = <Future<void>>[];
        try {
          selections.add(state.selectFriend(_other));
          if (returnToOriginal) selections.add(state.selectFriend(_peer));
          await pumpEventQueue();
          subscriptions = jami.calls
              .where((call) => call.startsWith('subscribe:'))
              .length;
          replayCount = jami.replayPendingNativeEventsCalls;
        } finally {
          pending.complete();
        }
        await Future.wait(selections);
        await pumpEventQueue();
        final selected = returnToOriginal ? _peer : _other;
        expect(state.peerId, selected);
        expect(prefs.getString('selectedFriendId'), selected);
        expect(prefs.getString('peerId'), selected);
        expect(
          jami.calls.where((call) => call.startsWith('subscribe:')).length,
          subscriptions,
        );
        expect(jami.replayPendingNativeEventsCalls, replayCount);
      },
    );
  }

  for (final partial in [false, true]) {
    test(
      'failed remove reconciles actual daemon removal: partial=$partial',
      () async {
        final (state, jami, _) = await _boot(active: true);
        jami.removal = partial ? 'partial' : 'refused';
        final result = await state.removeFriend(_peer);
        expect(state.friends.containsKey(_peer), !partial);
        // Clicking Remove ends the live session at once; a refused removal
        // only makes control requestable again, it never revives the session.
        expect(state.remoteControl.isControlling, isFalse);
        expect(state.remoteControl.canRequest, !partial);
        expect(state.friends.containsKey(_other), isTrue);
        expect(
          result.status,
          partial
              ? FriendRemovalStatus.incomplete
              : FriendRemovalStatus.notRemoved,
        );
        expect(result.warning, isNotNull);
      },
    );
  }

  test('a running removal closes control; a refused one reopens it', () async {
    final (state, jami, _) = await _boot();
    jami
      ..autoDeliverLeftNotice = false
      ..removal = 'refused';
    state.friendRemovalNoticeWindow = const Duration(milliseconds: 100);
    expect(state.remoteControl.controllerBinding?.peerId, _peer);
    final removing = state.removeFriend(_peer);
    await pumpEventQueue();
    expect(state.isRemovalPending(_peer), isTrue);
    expect(state.remoteControl.controllerBinding, isNull);
    expect(state.remoteControl.canRequest, isFalse);

    expect((await removing).status, FriendRemovalStatus.notRemoved);
    expect(state.isRemovalPending(_peer), isFalse);
    expect(state.remoteControl.canRequest, isTrue);
  });

  test('removing another friend preserves current control owner', () async {
    final (state, jami, _) = await _boot(active: true, target: _other);
    await state.removeFriend(_peer);
    expect(state.remoteControl.isControlling, isTrue);
    expect(state.remoteControl.controllerBinding?.peerId, _other);
    expect(
      jami.calls.where((c) => c == 'controlEnd:control-call:$_other'),
      isEmpty,
    );
  });

  test(
    'overlapping friend removals retain each exact cleanup result',
    () async {
      final (state, jami, _) = await _boot(active: true);
      final pending = Completer<void>();
      final started = Completer<void>();
      jami.pendingRemovals[_peer] = pending;
      jami.removalStarted[_peer] = started;
      jami.removal = 'partial';
      final first = state.removeFriend(_peer);
      await started.future;
      try {
        jami.removal = 'ok';
        final second = await state.removeFriend(_other);
        expect(second.status, FriendRemovalStatus.removed);
        expect(state.friends.containsKey(_peer), isTrue);
      } finally {
        pending.complete();
      }
      final result = await first;
      expect(result.peerId, _peer);
      expect(result.status, FriendRemovalStatus.incomplete);
      expect(
        result.warning,
        'Friend removed. Remote-control cleanup could not be confirmed.',
      );
      expect(state.friends.containsKey(_peer), isFalse);
      expect(state.friends.containsKey(_other), isFalse);
      expect(state.remoteControl.controllerBinding, isNull);
    },
  );

  test('navigation preserves an exact pending removal result', () async {
    final (state, jami, _) = await _boot();
    final pending = Completer<void>();
    final started = Completer<void>();
    jami.pendingRemovals[_peer] = pending;
    jami.removalStarted[_peer] = started;
    jami.removal = 'partial';
    final removing = state.removeFriend(_peer);
    await started.future;
    try {
      await state.selectFriend(_other);
    } finally {
      pending.complete();
    }
    final result = await removing;
    expect(result.status, FriendRemovalStatus.incomplete);
    expect(result.warning, isNotNull);
    expect(state.peerId, _other);
    expect(state.friends.containsKey(_other), isTrue);
  });

  test('old same-peer removal cannot retire its successor operation', () async {
    final (state, jami, _) = await _boot();
    final firstPending = Completer<void>();
    final firstStarted = Completer<void>();
    jami.pendingRemovals[_peer] = firstPending;
    jami.removalStarted[_peer] = firstStarted;
    jami.removal = 'partial';
    final first = state.removeFriend(_peer);
    await firstStarted.future;
    final secondPending = Completer<void>();
    final secondStarted = Completer<void>();
    jami.pendingRemovals[_peer] = secondPending;
    jami.removalStarted[_peer] = secondStarted;
    jami.removal = 'ok';
    final second = state.removeFriend(_peer);
    await secondStarted.future;
    try {
      firstPending.complete();
      final old = await first;
      expect(old.status, FriendRemovalStatus.stale);
      expect(old.warning, isNull);
    } finally {
      secondPending.complete();
    }
    final current = await second;
    expect(current.status, FriendRemovalStatus.removed);
    expect(state.friends.containsKey(_peer), isFalse);
    expect(state.friends.containsKey(_other), isTrue);
  });

  test('removal completion cannot cross an account A-B-A change', () async {
    final (state, jami, _) = await _boot();
    final pending = Completer<void>();
    final started = Completer<void>();
    jami.pendingRemovals[_peer] = pending;
    jami.removalStarted[_peer] = started;
    jami.removal = 'partial';
    final removing = state.removeFriend(_peer);
    await started.future;
    state.accountId = 'account-b';
    state.accountId = 'acc1';
    final reads = jami.friendReads;
    pending.complete();
    final result = await removing;
    expect(result.status, FriendRemovalStatus.stale);
    expect(result.warning, isNull);
    expect(jami.friendReads, reads);
    expect(state.remoteControl.controllerBinding, isNull);
  });

  test('failed offline change does not restore a removed friend', () async {
    final (state, jami, _) = await _boot(active: true);
    final pending = Completer<void>();
    jami.offlineCompletion = pending;
    final offline = state.setAppearOffline(true);
    await jami.offlineStarted.future;
    jami.daemonFriends.remove(_peer);
    jami.friendsRevision++;
    jami.push('friendsChanged', {'accountId': state.accountId});
    await pumpEventQueue();
    try {
      expect(state.friends.containsKey(_peer), isFalse);
      expect(state.remoteControl.controllerBinding, isNull);
    } finally {
      pending.completeError(StateError('synthetic late offline failure'));
      await offline;
    }
    expect(state.friends.containsKey(_peer), isFalse);
    expect(state.friends.containsKey(_other), isTrue);
    expect(await state.requestRemoteControl(), isFalse);
  });

  test('offline rollback preserves newer trust and profile evidence', () async {
    final (state, jami, _) = await _boot(active: true);
    final pending = Completer<void>();
    jami.offlineCompletion = pending;
    final offline = state.setAppearOffline(true);
    await jami.offlineStarted.future;
    final added = 'e' * 40;
    jami.daemonFriends[_peer] = JamiFriend(
      peerJamiId: _peer,
      confirmed: false,
      conversationId: 'replacement-conversation',
      displayName: 'Updated friend',
    );
    jami.daemonFriends[added] = JamiFriend(
      peerJamiId: added,
      confirmed: true,
      conversationId: 'new-conversation',
    );
    jami.friendsRevision++;
    jami.push('friendsChanged', {'accountId': state.accountId});
    await pumpEventQueue();
    pending.completeError(StateError('synthetic late offline failure'));
    await offline;
    expect(state.friends[_peer]?.confirmed, isFalse);
    expect(state.friends[_peer]?.conversationId, 'replacement-conversation');
    expect(state.friends[_peer]?.displayName, 'Updated friend');
    expect(state.friends[added]?.confirmed, isTrue);
    expect(state.remoteControl.controllerBinding, isNull);
    expect(await state.requestRemoteControl(), isFalse);
  });

  test('offline rollback cannot cross an account A-B-A change', () async {
    final (state, jami, _) = await _boot();
    final pending = Completer<void>();
    jami.offlineCompletion = pending;
    final offline = state.setAppearOffline(true);
    await jami.offlineStarted.future;
    state.accountId = 'account-b';
    state.accountId = 'acc1';
    pending.completeError(StateError('synthetic stale offline failure'));
    await offline;
    expect(state.appearOffline, isTrue);
    expect(state.prefs.getBool('appearOffline'), isTrue);
    expect(state.remoteControl.controllerBinding, isNull);
  });

  test(
    'pending host consent retires before native release acknowledgement',
    () async {
      final (state, jami, _) = await _boot();
      await state.stopRemoteControl();
      state.call!.outgoingVideo = const OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        revision: 9,
      );
      state.annotation.syncSources(
        localOwner: state.jamiId,
        peerOwner: _peer,
        localRevision: 9,
        localKind: OutgoingVideoKind.screen,
        peerKind: OutgoingVideoKind.screen,
      );
      await pumpEventQueue();
      jami.authority = RemoteControlHostAuthority(
        channelEpoch: 1,
        surfaceRevision: jami.authority.surfaceRevision,
        hostGeneration: 2,
        revokedThrough: 0,
        blocked: false,
        releaseComplete: true,
        state: 'pending',
      );
      jami.push('remoteControlRequest', {
        'accountId': state.accountId,
        'channelEpoch': 1,
        'surfaceRevision': jami.authority.surfaceRevision,
        'callId': 'control-call',
        'controllerAccountId': _peer,
        'controllerDeviceId': _device,
        'sourceRevision': 9,
        'hostGeneration': 2,
        'controlCapabilities': 15,
        'persistentAvailable': true,
      });
      expect(state.remoteControl.hostRequest, isNotNull);
      final original = state.remoteControl.hostRequest!;
      jami.pendingHostBlock = Completer<void>();
      jami.daemonFriends.remove(_peer);
      jami.friendsRevision++;
      jami.push('friendsChanged', {'accountId': state.accountId});
      await pumpEventQueue();
      try {
        expect(state.remoteControl.hostRequest, isNull);
        expect(state.remoteControl.hostPhase, RemoteControlHostPhase.revoking);
        expect(await state.allowRemoteControl(original), isFalse);
      } finally {
        jami.pendingHostBlock!.complete();
      }
      await pumpEventQueue();
      expect(state.remoteControl.hostPhase, RemoteControlHostPhase.idle);
    },
  );

  testWidgets(
    'partial removal is visible after its friend row disappears',
    (tester) async {
      final (state, jami, _) = await _boot();
      jami.removal = 'partial';
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          builder: (context, child) => withNoticeHost(child!, state),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                final friend = state.friends[_peer];
                return friend == null
                    ? const SizedBox.shrink()
                    : FriendRailRow(
                        state: state,
                        friend: friend,
                        onPressed: () {},
                      );
              },
            ),
          ),
        ),
      );
      await tester.longPress(find.byKey(ValueKey('friend-$_peer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('friend-$_peer')), findsNothing);
      expect(
        find.text(
          'Friend removed. Remote-control cleanup could not be confirmed.',
        ),
        findsOneWidget,
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'native cleanup failure is visible without claiming release completion',
    (tester) async {
      final (state, jami, _) = await _boot(active: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (context, _) => RemoteControlHud(state: state),
            ),
          ),
        ),
      );
      jami.push('remoteControlTrustRetired', {
        'accountId': state.accountId,
        'peerJamiId': _peer,
        'grantsRemoved': false,
        'releaseComplete': false,
      });
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('remote-control-trust-warning')),
        findsOneWidget,
      );
      expect(
        find.text('A previous remote-control release could not be confirmed.'),
        findsOneWidget,
      );
      expect(
        state.remoteControl.isControlling,
        isTrue,
        reason: 'The event alone has no consent generation for a replacement.',
      );
      jami.push('remoteControlTrustRetired', {
        'accountId': state.accountId,
        'peerJamiId': _other,
        'grantsRemoved': false,
        'releaseComplete': true,
      });
      await tester.pump();
      await tester.pump();
      expect(
        find.text('A previous remote-control release could not be confirmed.'),
        findsOneWidget,
        reason: 'Another friend cannot hide the active call release failure.',
      );
      jami.removal = 'partial';
      final removal = await state.removeFriend(_other);
      await tester.pump();
      expect(removal.warning, isNotNull);
      expect(
        find.text('A previous remote-control release could not be confirmed.'),
        findsOneWidget,
        reason: 'Other removal warnings remain in their own result.',
      );
      final failedTrust = Completer<JamiFriendList>();
      jami.pendingFriends = failedTrust;
      final staleAllow = state.allowRemoteControl(
        RemoteControlHostRequest(
          binding: RemoteControlBinding(
            callId: 'old-call',
            peerId: _other,
            sourceRevision: 1,
          ),
          generation: 1,
          controllerAccountId: _other,
          controllerDeviceId: _device,
          capabilities: const {},
          persistentAvailable: false,
        ),
      );
      failedTrust.completeError(StateError('synthetic trust read failure'));
      expect(await staleAllow, isFalse);
      await tester.pump();
      expect(
        find.text('A previous remote-control release could not be confirmed.'),
        findsOneWidget,
        reason: 'A stale consent callback cannot replace the call warning.',
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  test('old friend snapshot cannot cross an account A-B-A change', () async {
    final (state, jami, _) = await _boot(active: true);
    final pending = Completer<JamiFriendList>();
    jami.pendingFriends = pending;
    jami.push('friendsChanged', {'accountId': state.accountId});
    state.accountId = 'account-b';
    state.accountId = 'acc1';
    pending.complete(JamiFriendList(100, const [], const []));
    await pumpEventQueue();
    expect(state.friends.containsKey(_peer), isTrue);
  });

  for (final account in ['other-account', 'acc1']) {
    test('trust event refresh is exact-account scoped: $account', () async {
      final (state, jami, _) = await _boot(active: true);
      final reads = jami.friendReads;
      jami.push('remoteControlTrustRetired', {
        'accountId': account,
        'peerJamiId': _peer,
        'grantsRemoved': true,
        'releaseComplete': true,
      });
      await pumpEventQueue();
      expect(jami.friendReads > reads, account == 'acc1');
      expect(
        state.remoteControl.isControlling,
        isTrue,
        reason:
            'A trust event without consent generation cannot retire a later trusted session.',
      );
    });
  }

  for (final beforeWrite in [false, true]) {
    test(
      'direct selection A-B-A survives held write: before=$beforeWrite',
      () async {
        final (state, _, prefs) = await _boot();
        await state.selectFriend(_peer);
        final pending = Completer<void>();
        prefs.holdSelectedFriendWrite = pending;
        prefs.holdBeforeSelectionWrite = beforeWrite;
        final first = state.selectFriend(_other);
        await prefs.selectedFriendWriteStarted.future;
        final last = state.selectFriend(_peer);
        try {
          await pumpEventQueue();
          expect(state.peerId, _peer);
        } finally {
          pending.complete();
        }
        await Future.wait([first, last]);
        expect(prefs.getString('selectedFriendId'), _peer);
        expect(prefs.getString('peerId'), _peer);
        expect(prefs.containsKey('selectedGroupId'), isFalse);
      },
    );

    test(
      'direct-group-direct selection survives held write: before=$beforeWrite',
      () async {
        final (state, _, prefs) = await _boot();
        await state.selectFriend(_peer);
        final pending = Completer<void>();
        prefs.holdSelectedFriendWrite = pending;
        prefs.heldSelectionKey = 'selectedGroupId';
        prefs.holdBeforeSelectionWrite = beforeWrite;
        final group = state.selectGroup('group-selection');
        await prefs.selectedFriendWriteStarted.future;
        final direct = state.selectFriend(_other);
        try {
          await pumpEventQueue();
          expect(state.peerId, _other);
          expect(state.selectedGroupId, isNull);
        } finally {
          pending.complete();
        }
        await Future.wait([group, direct]);
        expect(prefs.getString('selectedFriendId'), _other);
        expect(prefs.getString('peerId'), _other);
        expect(prefs.containsKey('selectedGroupId'), isFalse);
      },
    );
  }

  test(
    'a failed old selection write does not prevent the latest save',
    () async {
      final (state, _, prefs) = await _boot();
      await state.selectFriend(_peer);
      final pending = Completer<void>();
      prefs.holdSelectedFriendWrite = pending;
      prefs.holdBeforeSelectionWrite = true;
      prefs.failHeldSelectionWrite = true;
      final first = state.selectFriend(_other);
      final failure = expectLater(first, throwsStateError);
      await prefs.selectedFriendWriteStarted.future;
      final last = state.selectFriend(_peer);
      pending.complete();
      await failure;
      await last;
      expect(prefs.getString('selectedFriendId'), _peer);
      expect(prefs.getString('peerId'), _peer);
    },
  );
}
