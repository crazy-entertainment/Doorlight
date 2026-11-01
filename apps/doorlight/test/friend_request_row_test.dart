import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/friend_rail.dart';

const _from = 'b3f12c9a0123456789abcdef0123456789abcdef';

final class _RequestState extends AppState {
  _RequestState(super.jami, super.prefs);

  Map<String, FriendState> known = const {};
  String? hint;

  @override
  Map<String, FriendState> get friends => known;

  @override
  String? nameHint(String peerId) => peerId == _from ? hint : null;

  @override
  ({String convId, String fromJamiId, bool isGroup})? get pendingConnect =>
      (convId: 'conv', fromJamiId: _from, isGroup: false);
}

void main() {
  testWidgets('a request keeps one placeholder until the name arrives', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state =
        _RequestState(JamiClient(), await SharedPreferences.getInstance())
          ..jamiId = 'a' * 40
          ..accountId = 'account'
          ..screen = Screen.home
          ..seedCaptureStateForTesting(
            resolved: true,
            applied: WindowCaptureProtectionStatus.exclude,
          );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (context, _) => FriendRail(
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
    expect(find.text('Friend request'), findsOneWidget);
    expect(find.text('wants to be friends'), findsOneWidget);
    expect(find.text('Someone'), findsNothing);

    // The contact appears before its profile: still the same placeholder.
    state
      ..known = {
        _from: const FriendState(
          peerId: _from,
          confirmed: false,
          conversationId: 'conv',
        ),
      }
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Friend request'), findsOneWidget);
    expect(find.text('wants to be friends'), findsOneWidget);

    state
      ..known = {
        _from: const FriendState(
          peerId: _from,
          confirmed: false,
          conversationId: 'conv',
          displayName: 'Phone B',
        ),
      }
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Phone B'), findsWidgets);
    expect(find.text('wants to be friends'), findsOneWidget);
    expect(find.text('Friend request'), findsNothing);
  });

  testWidgets('a request name is shown as unverified until the profile', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state =
        _RequestState(JamiClient(), await SharedPreferences.getInstance())
          ..jamiId = 'a' * 40
          ..accountId = 'account'
          ..screen = Screen.home
          ..hint = 'Mara'
          ..seedCaptureStateForTesting(
            resolved: true,
            applied: WindowCaptureProtectionStatus.exclude,
          );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (context, _) => FriendRail(
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
    expect(find.text('Mara'), findsOneWidget);
    expect(find.text('wants to be friends'), findsOneWidget);
    expect(find.text('Friend request'), findsNothing);

    // The authenticated profile replaces the claim.
    state
      ..known = {
        _from: const FriendState(
          peerId: _from,
          confirmed: false,
          conversationId: 'conv',
          displayName: 'Phone B',
        ),
      }
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Phone B'), findsWidgets);
    expect(find.text('Mara'), findsNothing);
    expect(find.text('wants to be friends'), findsOneWidget);
  });
}
