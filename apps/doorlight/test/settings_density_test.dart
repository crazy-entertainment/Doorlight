import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/settings_previews.dart';
import 'package:sybl/ui/message_time_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
      'Fraunces': 'assets/fonts/Fraunces-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  testWidgets('compact setting samples fit without clipping', (tester) async {
    for (final sample in <Widget>[
      for (final value in MessageTimestampStyle.values)
        MessageTimePreview(value),
      for (final value in MessageReceiptStyle.values) ReceiptPreview(value),
      for (final value in GroupHeaderPlacement.values)
        GroupHeaderPreview(value),
      for (final value in MobileGroupNavigation.values)
        MobileGroupPreview(value),
      for (final value in WindowEdgeSpacing.values)
        WindowEdgeSpacingPreview(value),
      const RepeatAuthorPreview(true),
      const RepeatAuthorPreview(false),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: sample is RepeatAuthorPreview ? 88 : 84,
                child: sample,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: sample.toString());
    }
  });

  testWidgets('timestamp placement menu compares options and stays compact', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = MessageTimestampStyle.inward;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: StatefulBuilder(
              builder: (context, update) => MessageTimeSettings(
                key: const ValueKey('times'),
                value: selected,
                enabled: true,
                onChanged: (v) => update(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );
    // Measure the actual controls, not the parent's full-height layout box.
    final top = tester.getTopLeft(find.text('Message times')).dy;
    final bottom = tester
        .getBottomLeft(find.byKey(const ValueKey('message-time-placement')))
        .dy;
    expect(bottom - top, lessThan(180));
    final dropdown = find.byKey(const ValueKey('message-time-placement'));
    expect(
      tester.getRect(
        find.descendant(of: dropdown, matching: find.byType(InkWell)),
      ),
      tester.getRect(
        find.ancestor(of: dropdown, matching: find.byType(Material)).first,
      ),
      reason: 'Timestamp hover/focus must match the complete outlined surface',
    );
    await tester.tap(find.byKey(const ValueKey('message-time-placement')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inside the bubble').last);
    await tester.pumpAndSettle();
    expect(selected, MessageTimestampStyle.whatsapp);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing pause styles retain their bubble shape and timing', (
    tester,
  ) async {
    var selected = MessageTimestampStyle.apple;
    final changes = <MessageTimestampStyle>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: StatefulBuilder(
              builder: (context, update) => MessageTimeSettings(
                value: selected,
                enabled: true,
                onChanged: (value) {
                  changes.add(value);
                  update(() => selected = value);
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(changes, isEmpty);
    expect(
      find.text('At the start and after a gap of 15 minutes or more.'),
      findsOneWidget,
    );
    expect(find.text('Above message groups').hitTestable(), findsOneWidget);
    expect(find.byType(MessageTimePreview), findsNothing);
    final placement = find.byKey(const ValueKey('message-time-placement'));
    expect(tester.getSize(placement).height, 48);
    final tail = find.byKey(const ValueKey('message-time-bubble-tail'));
    expect(tester.widget<Switch>(tail).value, isTrue);
    await tester.tap(tail);
    await tester.pumpAndSettle();
    expect(selected, MessageTimestampStyle.messenger);
    await tester.tap(tail);
    await tester.pumpAndSettle();
    expect(selected, MessageTimestampStyle.apple);
    await tester.tap(find.byKey(const ValueKey('message-time-placement')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Below the bubble').last);
    await tester.pumpAndSettle();
    expect(selected, MessageTimestampStyle.below);
    expect(tail, findsNothing);
    expect(
      find.byKey(const ValueKey('message-time-explanation')),
      findsNothing,
    );
    expect(changes, [
      MessageTimestampStyle.messenger,
      MessageTimestampStyle.apple,
      MessageTimestampStyle.below,
    ]);
    expect(tester.takeException(), isNull);
  });
}
