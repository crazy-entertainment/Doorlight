import 'dart:ui'
    show ViewFocusEvent, ViewFocusState, ViewFocusDirection, SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/doorlight_brand.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'package:sybl/ui/playful_door.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
      'Fraunces': 'assets/fonts/Fraunces-Variable.ttf',
      // The onboarding word reel's faces.
      'InstrumentSerif': 'assets/fonts/InstrumentSerif-Italic.ttf',
      'BricolageGrotesque': 'assets/fonts/BricolageGrotesque-Variable.ttf',
      'Silkscreen': 'assets/fonts/Silkscreen-Regular.ttf',
      'PlayfairDisplay': 'assets/fonts/PlayfairDisplay-Italic-Variable.ttf',
      'LilitaOne': 'assets/fonts/LilitaOne-Regular.ttf',
      'Fredoka': 'assets/fonts/Fredoka-Variable.ttf',
      'Anton': 'assets/fonts/Anton-Regular.ttf',
      'Pacifico': 'assets/fonts/Pacifico-Regular.ttf',
      'Caveat': 'assets/fonts/Caveat-Variable.ttf',
      'VT323': 'assets/fonts/VT323-Regular.ttf',
      'SpaceMono': 'assets/fonts/SpaceMono-Regular.ttf',
      'GochiHand': 'assets/fonts/GochiHand-Regular.ttf',
      'Rubik': 'assets/fonts/Rubik-Variable.ttf',
      'Righteous': 'assets/fonts/Righteous-Regular.ttf',
      'CourierPrime': 'assets/fonts/CourierPrime-Regular.ttf',
      'Quicksand': 'assets/fonts/Quicksand-Variable.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  Future<void> open(WidgetTester tester, {bool chrome = false}) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    SharedPreferences.setMockInitialValues({});
    final state = AppState(JamiClient(), await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: chrome
            ? WindowsChrome(
                jami: state.jami,
                onboarding: true,
                child: OnboardingScreen(state: state),
              )
            : OnboardingScreen(state: state),
      ),
    );
  }

  double openness(WidgetTester tester) =>
      tester.widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark)).openness;

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('Windows intro opens with ${key.keyLabel}', (tester) async {
      await open(tester);
      await tester.pump();
      expect(openness(tester), 0);
      final create = find.byKey(const ValueKey('onboarding-create-choice'));
      final hiddenFocus = Focus.of(
        tester.element(
          find.descendant(of: create, matching: find.byType(Text)).first,
        ),
      );
      expect(hiddenFocus.canRequestFocus, isFalse);
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(openness(tester), greaterThan(0));
      expect(openness(tester), lessThan(1.4));
      await tester.pumpAndSettle();
      expect(openness(tester), 1.4);
      expect(create.hitTestable(), findsOneWidget);
    });
  }

  testWidgets('Windows intro has an accessible activation action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    await tester.pump();
    final door = tester.getSemantics(find.bySemanticsLabel('Open Doorlight'));
    expect(door.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    door.owner!.performAction(door.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(openness(tester), 1.4);
      semantics.dispose();
  });

  testWidgets('door Easter eggs wait until the entire intro finishes', (
    tester,
  ) async {
    await open(tester);
    final mark = find.byType(DoorlightDoorMark);
    final initial = tester.widget<DoorlightDoorMark>(mark);
    final handle =
        tester.getTopLeft(mark) +
        DoorlightDoorMark.handlePosition(initial.openness) *
            (initial.size / 100);
    final drag = await tester.startGesture(handle);
    await drag.moveBy(const Offset(-60, 0));
    await drag.moveBy(const Offset(-30, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(openness(tester), 0);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<PlayfulDoor>(find.byType(PlayfulDoor)).interactive,
      isFalse,
    );
    await tester.tap(mark);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(openness(tester), greaterThan(0));
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester.widget<PlayfulDoor>(find.byType(PlayfulDoor)).interactive,
      isTrue,
    );
    await tester.tap(mark);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(openness(tester), 0);
  });

  for (final size in [
    const Size(700, 500),
    const Size(684, 492),
    const Size(640, 480),
  ]) {
    testWidgets('welcome fits the Windows content area at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, chrome: true);
      await tester.tap(find.byType(DoorlightDoorMark));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark)).size,
        moreOrLessEquals(
          ((size.height - WindowsChrome.height) * .26).clamp(96.0, 160.0),
        ),
      );
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scroll.position.maxScrollExtent, 0);
      expect(
        find.byKey(const ValueKey('onboarding-existing-choice')).hitTestable(),
        findsOneWidget,
      );
    });
  }

  testWidgets('first click opens without a lifecycle focus cycle', (
    tester,
  ) async {
    await open(tester);
    await tester.pump(const Duration(milliseconds: 800));
    expect(openness(tester), 0);
    await tester.tap(find.byType(DoorlightDoorMark));
    await tester.pumpAndSettle();
    expect(openness(tester), 1.4);
  });

  testWidgets('view focus waits for an app click and unfocus pauses', (
    tester,
  ) async {
    await open(tester);
    void focus(ViewFocusState state, {int? viewId}) {
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: viewId ?? tester.view.viewId,
          state: state,
          direction: ViewFocusDirection.undefined,
        ),
      );
    }

    focus(ViewFocusState.focused, viewId: tester.view.viewId + 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(openness(tester), 0);
    focus(ViewFocusState.focused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(openness(tester), 0);
    await tester.tap(find.byType(DoorlightDoorMark));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final partial = openness(tester);
    expect(partial, greaterThan(0));
    expect(partial, lessThan(1.4));
    focus(ViewFocusState.unfocused);
    await tester.pump(const Duration(milliseconds: 500));
    expect(openness(tester), partial);
    focus(ViewFocusState.focused);
    await tester.pumpAndSettle();
    expect(openness(tester), 1.4);
  });

  testWidgets('the spinning word never moves “Let’s get you” on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.tap(find.byType(DoorlightDoorMark));
    await tester.pumpAndSettle();

    // Phone layout: the door's centre near a quarter of the height, both
    // paths in thumb reach at the bottom.
    final door = tester.getCenter(
      find.byKey(const ValueKey('onboarding-door-mark')),
    );
    expect(door.dy, moreOrLessEquals(844 * .26, epsilon: 2));
    final existing = tester.getRect(
      find.byKey(const ValueKey('onboarding-existing-choice')),
    );
    expect(existing.bottom, moreOrLessEquals(844 - 28, epsilon: 1));
    final create = tester.getRect(
      find.byKey(const ValueKey('onboarding-create-choice')),
    );
    expect(existing.top - create.bottom, moreOrLessEquals(12, epsilon: .5));

    final lead = find.text('Let’s get you');
    final second = find.text('with your friends');
    final anchor = tester.getTopLeft(lead);
    final secondAnchor = tester.getTopLeft(second);
    final settled = <String>[];
    final words = find.descendant(
      of: find.byKey(const ValueKey('spinning-word')),
      matching: find.byType(Text),
    );
    // Every frame through the reel and round again, including mid-spin.
    final reelLength = 16;
    for (var frame = 0; frame < (reelLength + 3) * 1700 ~/ 50; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(lead), anchor);
      expect(tester.getTopLeft(second), secondAnchor);
      for (final word in words.evaluate()) {
        expect(tester.getRect(find.byWidget(word.widget)).right, lessThan(390));
        expect(
          tester.getRect(find.byWidget(word.widget)).left -
              tester.getRect(lead).right,
          greaterThanOrEqualTo(26 * .4 - .5),
        );
      }
      // Each word keeps the line box, whatever its face or size.
      if (words.evaluate().length == 1) {
        final word = tester.widget<Text>(words).data!;
        if (settled.isEmpty || settled.last != word) settled.add(word);
        final box = tester.getRect(words);
        final line = tester.getRect(lead);
        expect(box.top, greaterThanOrEqualTo(line.top - .5));
        expect(box.bottom, lessThanOrEqualTo(line.bottom + .5));
      }
    }
    // Sixteen distinct words, then it keeps turning instead of resting.
    expect(settled.toSet(), hasLength(reelLength));
    expect(settled.length, greaterThan(reelLength + 1));
    expect(settled[reelLength], settled.first);
    expect(settled, isNot(contains('trauma-dumping')));
    expect(settled, isNot(contains('catching up')));
    expect(settled, isNot(contains('screen-sharing')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop reel leaves a clear space after the rendered prefix', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.tap(find.byType(DoorlightDoorMark));
    await tester.pumpAndSettle();
    final prefix = find.text('Let’s get you');
    final anchor = tester.getTopLeft(prefix);
    final words = find.descendant(
      of: find.byKey(const ValueKey('spinning-word')),
      matching: find.byType(Text),
    );
    for (var frame = 0; frame < 16 * 1700 ~/ 50; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(prefix), anchor);
      for (final word in words.evaluate()) {
        expect(
          tester.getRect(find.byWidget(word.widget)).left -
              tester.getRect(prefix).right,
          greaterThanOrEqualTo(22 * .4 - .5),
        );
      }
    }
    expect(tester.takeException(), isNull);
  });
}
