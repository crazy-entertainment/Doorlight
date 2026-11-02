import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';

import 'app_state_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'desktop restart retains draft binding but retires command tokens',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'accountId': 'acc1',
        'displayName': 'Me',
        'widgetChatCaptureConsent.v1': true,
      });
      Future<AppState> boot() async {
        final jami = fixture.FakeJami()..accountRegistration = 'REGISTERED';
        jami.daemonFriends[fixture.peer] = JamiFriend(
          peerJamiId: fixture.peer,
          confirmed: true,
          conversationId: fixture.peerConversation,
          displayName: 'Friend',
        );
        final state = AppState(jami, await SharedPreferences.getInstance());
        await state.init();
        return state;
      }

      Map conversation(AppState state) =>
          ((state.widgetOverlaySnapshot['chat'] as Map)['conversations']
                      as List)
                  .single
              as Map;
      final first = await boot();
      final old = Map.of(conversation(first));
      first.dispose();
      final restarted = await boot();
      addTearDown(restarted.dispose);
      final next = conversation(restarted);
      expect(next['draftKey'], old['draftKey']);
      expect(next['id'], isNot(old['id']));
      await expectLater(
        restarted.handleWidgetOverlayCommand('chat.select', {
          'token': old['id'],
          'conversation': old['id'],
        }),
        throwsA(isA<StateError>()),
      );
      restarted.accountId = 'replacement-account';
      expect(conversation(restarted)['draftKey'], isNot(old['draftKey']));
    },
  );
}
