import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/group_topics.dart';
import 'app_state_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'voice rooms in a valid group without a general text room remain joinable',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'accountId': 'acc1',
        'widgetChatCaptureConsent.v1': true,
      });
      final jami = fixture.FakeJami()..accountRegistration = 'REGISTERED';
      final groupId = 'b' * 40;
      const layout = GroupLayout(
        collections: [],
        rooms: [
          GroupRoom(id: 'lobby', name: 'Lobby', kind: GroupRoomKind.text),
          GroupRoom(id: 'voice', name: 'Voice', kind: GroupRoomKind.voice),
        ],
      );
      jami.daemonGroups[groupId] = JamiGroup(
        conversationId: groupId,
        title: 'Test group',
        description: GroupLayoutCodec.encode(layout),
        memberCount: 2,
        canManageMembers: true,
        members: [
          JamiGroupMember(
            peerJamiId: jami.accountJamiId,
            role: JamiGroupMemberRole.admin,
          ),
          const JamiGroupMember(
            peerJamiId: fixture.peer,
            role: JamiGroupMemberRole.member,
          ),
        ],
      );
      final state = AppState(jami, await SharedPreferences.getInstance());
      addTearDown(state.dispose);
      await state.init();
      expect(
        (state.widgetOverlaySnapshot['chat'] as Map)['conversations'],
        isEmpty,
      );
      final voice = state.widgetOverlaySnapshot['voice'] as Map;
      expect(voice['status'], 'ready');
      final offers = voice['offers'] as List;
      expect(offers, hasLength(1));
      final token = (offers.single as Map)['id'];
      // The same scope is offered above, so admission must not reject it as stale.
      await state.handleWidgetOverlayCommand('voice.join', {'token': token});
      await pumpEventQueue();
      expect(state.groupCall, isNotNull);
      jami.push('groupCallLegState', {
        'reservationId': state.groupCall!.reservationId,
        'conferenceId': state.groupCall!.conferenceId,
        'callId': state.groupCall!.callId,
        'state': 'CURRENT',
      });
      await Future<void>.delayed(Duration.zero);
      final activeToken =
          (state.widgetOverlaySnapshot['voice'] as Map)['token'];
      await state.handleWidgetOverlayCommand('voice.mute', {
        'token': activeToken,
        'muted': true,
      });
      expect(state.groupCall!.micMuted, isTrue);
      await state.handleWidgetOverlayCommand('voice.deafen', {
        'token': activeToken,
        'deafened': true,
      });
      expect(state.groupCall!.deafened, isTrue);
      await state.handleWidgetOverlayCommand('voice.leave', {
        'token': activeToken,
      });
      expect(state.groupCall, isNull);
      await expectLater(
        state.handleWidgetOverlayCommand('voice.mute', {
          'token': activeToken,
          'muted': false,
        }),
        throwsA(isA<StateError>()),
      );
    },
  );
}
