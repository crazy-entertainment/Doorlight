import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/sound_effects.dart';
import 'package:sybl/core/sticker_assets.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/hologram_live.dart';
import 'package:sybl/state/rich_content.dart';
import 'app_state_test.dart' as fixture;

final _peer = 'b' * 40,
    _conversation = 'e' * 40,
    _op = 'c' * 32,
    _commit = 'd' * 40;
const _asset = 'sybl.chubby-cats.angry.v1';

class _Native extends fixture.FakeJami {
  final controls = <HologramPacket>[];
  final order = <String>[];
  bool autoReady = false;
  String? published;
  String nativeSurface = 'visible';
  int privacyGeneration = -1, nativeShows = 0;
  bool privacyEnabled = false;
  Completer<String>? pendingSurface;
  @override
  Future<void> setHologramPrivacy(String accountId, int generation, bool enabled) async {
    privacyGeneration = generation; privacyEnabled = enabled;
  }
  @override
  Future<String> hologramPresentationState(String accountId, String peer, String conversation, int generation) async =>
      pendingSurface?.future ?? (privacyEnabled && privacyGeneration == generation ? nativeSurface : 'unavailable');
  @override
  Future<bool> showHologram(String accountId, String peer, String conversation, String asset, int generation, bool reducedMotion) async {
    expect(asset, _asset); expect(privacyGeneration, generation); expect(privacyEnabled, isTrue);
    nativeShows++;
    return true;
  }
  @override
  Future<void> cancelHologram(int generation) async {}

  void control(HologramPacket packet) => push('hologramControl', {
    'accountId': 'acc1',
    'fromJamiId': _peer,
    'payload': packet.encode(),
  });
  void durable({String? op, String? commit, String? author}) =>
      push('chatMessage', {
        'accountId': 'acc1',
        'peerJamiId': _peer,
        'conversationId': _conversation,
        'item': {
          'accountId': 'acc1',
          'peerId': _peer,
          'conversationId': _conversation,
          'daemonId': commit ?? _commit,
          'versionId': commit ?? _commit,
          'mimeType': RichContentWire.stickerMime,
          'authorId': author ?? _peer,
          'timestampSeconds': 1700000000,
          'operationId': op ?? _op,
          'body': const StickerContent(
            _asset,
            StickerPresentation.hologram,
          ).encode(),
        },
      });
  @override
  Future<bool> sendHologramControl(
    String accountId,
    String peer,
    String payload,
  ) async {
    final packet = HologramPacket.parse(payload)!;
    controls.add(packet);
    order.add(packet.type);
    if (autoReady && packet.type == 'prepare') {
      control(
        HologramPacket(
          'ready',
          _conversation,
          packet.operation,
          nonce: '1' * 32,
        ),
      );
    }
    return true;
  }

  @override
  Future<String> sendOwnedMessage({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
    required String mimeType,
    required String body,
    required String operationId,
    String replyTo = '',
    String topicId = '',
    String roomId = '',
  }) async {
    order.add('commit');
    published = body;
    // An otherwise valid readiness received during publication is already too late.
    control(
      HologramPacket('ready', _conversation, operationId, nonce: '2' * 32),
    );
    push('sendOperationCompleted', {
      'accountId': accountId,
      'peerJamiId': peerJamiId,
      'conversationId': conversationId,
      'operationId': operationId,
      'status': 'committed',
      'commitId': _commit,
    });
    return 'pending';
  }
}

Future<(AppState, _Native)> _boot() async {
  SharedPreferences.setMockInitialValues({
    'displayName': 'Me',
    'accountId': 'acc1',
  });
  final native = _Native();
  native.daemonFriends[_peer] = JamiFriend(
    peerJamiId: _peer,
    confirmed: true,
    conversationId: _conversation,
  );
  final state = AppState(native, await SharedPreferences.getInstance());
  await state.init();
  await bundledStickerManifest;
  await Future<void>.delayed(Duration.zero);
  return (state, native);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('friend Allow overrides the default but Block retires active presentation without replay', () async {
    final (state, native) = await _boot();
    addTearDown(state.dispose);
    expect(await state.setHologramPresentationEnabled(false), isTrue);
    native.control(HologramPacket('prepare', _conversation, _op));
    expect(native.controls, isEmpty);
    expect(await state.setFriendPreferences(_peer, const FriendPreferences(
      holograms: FriendHologramPreference.allow,
      messageAlerts: FriendMessageAlertPreference.mute,
    )), isTrue);
    native.control(HologramPacket('prepare', _conversation, 'f' * 32));
    expect(native.controls, hasLength(1));
    final ready = native.controls.single;
    native.durable(op: 'f' * 32);
    native.control(HologramPacket('present', _conversation, 'f' * 32,
      nonce: ready.nonce, commit: _commit));
    expect(state.hologramPresentation, isNotNull);
    expect(await state.setFriendPreferences(_peer, const FriendPreferences(
      holograms: FriendHologramPreference.block,
    )), isTrue);
    expect(state.hologramPresentation, isNull);
    expect(await state.setFriendPreferences(_peer, const FriendPreferences(
      holograms: FriendHologramPreference.allow,
    )), isTrue);
    native.control(HologramPacket('present', _conversation, 'f' * 32,
      nonce: ready.nonce, commit: _commit));
    expect(state.hologramPresentation, isNull);
    state.setProtectedSurfaceLocked(true);
    native.control(HologramPacket('prepare', _conversation, '9' * 32));
    expect(native.controls, hasLength(1));
  });
  test('Windows hidden surface uses native presentation and fails closed on unsafe session', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() { debugDefaultTargetPlatformOverride = null; });
    final (state, native) = await _boot();
    addTearDown(state.dispose);
    native.nativeSurface = 'hidden';
    state.didChangeAppLifecycleState(AppLifecycleState.hidden);
    native.control(HologramPacket('prepare', _conversation, _op));
    await Future<void>.delayed(Duration.zero);
    final ready = native.controls.single;
    native.durable();
    native.control(HologramPacket('present', _conversation, _op, nonce: ready.nonce, commit: _commit));
    await Future<void>.delayed(Duration.zero);
    expect(native.nativeShows, 1);
    expect(state.hologramPresentation, isNull, reason: 'No in-app duplicate for a native popup');
    state.setProtectedSurfaceLocked(true);
    expect(native.privacyEnabled, isFalse);
  });
  test('a pending native surface check cannot outlive lock', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() { debugDefaultTargetPlatformOverride = null; });
    final (state, native) = await _boot();
    addTearDown(state.dispose);
    native.pendingSurface = Completer<String>();
    native.control(HologramPacket('prepare', _conversation, _op));
    state.setProtectedSurfaceLocked(true);
    native.pendingSurface!.complete('hidden');
    await Future<void>.delayed(Duration.zero);
    expect(native.controls, isEmpty);
    expect(native.nativeShows, 0);
  });

  test(
    'native event names, live commit, privacy and fade sound share one admission',
    () async {
      final (state, native) = await _boot();
      addTearDown(state.dispose);
      final sounds = <SyblSoundEvent>[];
      final subscription = state.soundEvents.listen(sounds.add);
      addTearDown(subscription.cancel);
      native.control(HologramPacket('prepare', _conversation, _op));
      expect(native.controls, hasLength(1));
      final nonce = native.controls.single.nonce!;
      native.durable();
      expect(state.hologramPresentation, isNull);
      expect(sounds, isEmpty);
      expect(state.friendActivity(_peer).unreadMessages, 1);
      native.control(
        HologramPacket(
          'present',
          _conversation,
          _op,
          nonce: nonce,
          commit: _commit,
        ),
      );
      final presentation = state.hologramPresentation!;
      expect(sounds, isEmpty);
      state.hologramFadeStarted(presentation);
      state.hologramFadeStarted(presentation);
      expect(sounds, [SyblSoundEvent.hologram]);
      native.durable();
      expect(state.friendActivity(_peer).unreadMessages, 1);
      state.setProtectedSurfaceLocked(true);
      expect(state.hologramPresentation, isNull);
      expect(sounds.last, SyblSoundEvent.stopHologram);
      state.setProtectedSurfaceLocked(false);
      native.control(
        HologramPacket(
          'present',
          _conversation,
          _op,
          nonce: nonce,
          commit: _commit,
        ),
      );
      expect(state.hologramPresentation, isNull);
    },
  );
  test(
    'background or visible sender stays quiet and history cannot create freshness',
    () async {
      final (state, native) = await _boot();
      addTearDown(state.dispose);
      await state.selectFriend(_peer);
      state.setConversationVisible(_peer);
      native.control(HologramPacket('prepare', _conversation, _op));
      expect(native.controls, isEmpty);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      native.control(HologramPacket('prepare', _conversation, _op));
      native.durable();
      expect(native.controls, isEmpty);
      expect(state.hologramPresentation, isNull);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      native.control(
        HologramPacket(
          'present',
          _conversation,
          _op,
          nonce: '1' * 32,
          commit: _commit,
        ),
      );
      expect(state.hologramPresentation, isNull);
    },
  );
  test(
    'real composer publishes selected hologram alone after readiness freeze',
    () async {
      final (state, native) = await _boot();
      addTearDown(state.dispose);
      await state.selectFriend(_peer);
      native.autoReady = true;
      final owner = state.conversationActionOwner;
      final draft = ComposerDraftSession(
        ComposerDraftKey(state.selectedConversationScope!, 'main'),
      )..activate(owner);
      draft.updateText(owner, const TextEditingValue(text: 'keep this text'));
      final pick = draft.begin(ComposerOperationKind.picker, owner)!;
      expect(
        draft.replaceMedia(
          pick,
          ComposerMediaStage(
            kind: ComposerMediaKind.sticker,
            label: 'Angry cat',
            encodedBytes: 0,
            assetId: _asset,
          ),
        ),
        isTrue,
      );
      final send = draft.begin(ComposerOperationKind.sendMedia, owner)!;
      final result = await state.sendComposerFile(
        draft,
        send,
        asHologram: true,
      );
      expect(result?.status, ComposerSendStatus.committed);
      expect(native.order, ['prepare', 'commit', 'present']);
      expect(native.controls.last.nonce, '1' * 32);
      expect(
        StickerContent.parse(native.published)?.presentation,
        StickerPresentation.hologram,
      );
      expect(draft.text.text, 'keep this text');
    },
  );
}
