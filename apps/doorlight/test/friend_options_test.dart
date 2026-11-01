import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/friend_options.dart';
import 'app_state_test.dart' as fixture;

void main() {
  final peer = 'b' * 40;
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
  });
  for (final width in [390.0, 1000.0]) {
    testWidgets(
      'friend controls save exact choices and retire stale owner at $width',
      (tester) async {
        tester.view
          ..physicalSize = Size(width, 844)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'displayName': 'Me',
          'accountId': 'acc1',
        });
        final native = fixture.FakeJami();
        native.daemonFriends[peer] = JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: 'e' * 40,
          displayName: 'Alex',
        );
        final state = (await tester.runAsync(() async {
          final state = AppState(native, await SharedPreferences.getInstance());
          await state.init();
          return state;
        }))!;
        addTearDown(state.dispose);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 844),
                textScaler: TextScaler.linear(width == 390 ? 2 : 1),
              ),
              child: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: FriendOptionsDialog(state: state, peer: peer),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (Platform.environment['DOORLIGHT_FRIEND_UI_CAPTURE'] == '1') {
          await tester.runAsync(() async {
            final surface =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await surface.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final file = File(
              '../../local/tmp/doorlight-friend-ui/options-${width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
          });
        }
        final holograms = find.byType(
          DropdownButtonFormField<FriendHologramPreference>,
        );
        await tester.tap(holograms);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Block').last);
        await tester.pumpAndSettle();
        expect(
          state.friendPreferencesFor(peer).holograms,
          FriendHologramPreference.block,
        );
        final alerts = find.byType(
          DropdownButtonFormField<FriendMessageAlertPreference>,
        );
        await tester.ensureVisible(alerts);
        await tester.tap(alerts);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mute').last);
        await tester.pumpAndSettle();
        expect(
          state.friendPreferencesFor(peer).messageAlerts,
          FriendMessageAlertPreference.mute,
        );
        final mic = find.byType(DropdownButtonFormField<String>);
        await tester.ensureVisible(mic);
        await tester.tap(mic);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Push-to-talk').last);
        await tester.pumpAndSettle();
        expect(
          state.microphoneModeForFriend(peer).mode,
          MicrophoneMode.pushToTalk,
        );
        await tester.tap(mic);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use global default').last);
        await tester.pumpAndSettle();
        expect(
          state.microphoneModeForFriend(peer).source,
          MicrophoneModeSource.globalDefault,
        );
        state.appSettings = AppSettings(friendPreferencesReviewRequired: true);
        state.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButtonFormField<FriendHologramPreference>>(
                find.byType(DropdownButtonFormField<FriendHologramPreference>),
              )
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<DropdownButtonFormField<FriendMessageAlertPreference>>(
                find.byType(
                  DropdownButtonFormField<FriendMessageAlertPreference>,
                ),
              )
              .onChanged,
          isNull,
        );
        state.accountId = 'other';
        state.accountId = 'acc1';
        state.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Friend options unavailable'), findsOneWidget);
        expect(
          find.byType(DropdownButtonFormField<FriendHologramPreference>),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
