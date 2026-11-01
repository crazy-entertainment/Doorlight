import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/theme_reveal.dart';

void main() {
  testWidgets(
    'closing before any theme change safely disposes the controller',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ThemeReveal(enabled: true, child: SizedBox())),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  test('circle uncovers the origin first and reaches every corner', () {
    const size = Size(700, 500), origin = Offset(550, 120);
    final halfway = ThemeRevealClipper(
      origin: origin,
      progress: .25,
    ).getClip(size);
    expect(halfway.contains(origin), isFalse);
    expect(halfway.contains(const Offset(1, 499)), isTrue);
    final complete = ThemeRevealClipper(
      origin: origin,
      progress: 1,
    ).getClip(size);
    for (final point in [const Offset(1, 1), const Offset(699, 499)]) {
      expect(complete.contains(point), isFalse);
    }
  });

  for (final enabled in [false, true]) {
    testWidgets('theme changes with in-app motion enabled=$enabled', (
      tester,
    ) async {
      var changed = false;
      late BuildContext buttonContext;
      await tester.pumpWidget(
        MaterialApp(
          home: ThemeReveal(
            enabled: enabled,
            child: Builder(
              builder: (context) {
                buttonContext = context;
                return const ColoredBox(color: Colors.red);
              },
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        ThemeReveal.change(buttonContext, () => changed = true);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(changed, isTrue);
      expect(
        find.byKey(const ValueKey('theme-circle-reveal')),
        enabled ? findsOneWidget : findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('theme-circle-reveal')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
