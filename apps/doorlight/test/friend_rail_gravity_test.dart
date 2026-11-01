import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/friend_rail.dart';
import 'package:sybl/ui/gravity.dart';

const _peer = 'b3f12c9a0123456789abcdef0123456789abcdef';

final class _RailState extends AppState {
  _RailState(super.jami, super.prefs);

  @override
  Map<String, FriendState> get friends => const {
    _peer: FriendState(
      peerId: _peer,
      confirmed: true,
      conversationId: 'conv',
      displayName: 'Robin',
    ),
  };
}

void main() {
  testWidgets('a friend row background falls as its own piece', (tester) async {
    gravityImpactSound = (_, _) {};
    addTearDown(() => gravityMode.value = false);
    // Fixed drop order, so the pile settles the same way every run.
    gravityRandom = math.Random(1);
    SharedPreferences.setMockInitialValues({});
    final state =
        _RailState(JamiClient(), await SharedPreferences.getInstance())
          ..jamiId = 'a' * 40
          ..accountId = 'account'
          ..screen = Screen.home;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: FriendRail(
              state: state,
              onOpenFriend: (_) {},
              onOpenGroup: (_) {},
              onAddFriend: () {},
              onCreateGroup: () {},
              onInviteFriend: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    );
    const key = ValueKey('friend-row-background-$_peer');
    // The same widget is shown in place and, once lifted, in the overlay.
    final background = find.byWidget(
      tester.widget(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(DecoratedBox),
        ),
      ),
    );
    final row = tester.getRect(background);
    final name = tester.getRect(find.text('Robin'));
    // The text sits on the background, not inside the same piece.
    expect(row.contains(name.center), isTrue);
    expect(
      find.descendant(of: find.byKey(key), matching: find.text('Robin')),
      findsNothing,
    );

    gravityMode.value = true;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(gravityDebug().masses, contains(key));
    final fallen = tester.getRect(background);
    expect(tester.getSize(background).width, closeTo(row.width, .5));
    expect(fallen.center.dy, greaterThan(row.center.dy + 200));
    expect(gravityDebug().awake, 0);
  });
}
