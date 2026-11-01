import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/windows_pane_layout.dart';
import 'package:sybl/ui/window_presentation.dart';

class _LivePane extends StatefulWidget {
  const _LivePane({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_LivePane> createState() => _LivePaneState();
}

class _LivePaneState extends State<_LivePane> {
  final text = TextEditingController();
  final focus = FocusNode();
  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(onPressed: widget.onTap, child: Text(widget.label)),
      TextField(controller: text, focusNode: focus),
    ],
  );
}

void main() {
  test('layout easing matches native window bounds at intermediate frames', () {
    expect(WindowPresentation.animationDuration.inMilliseconds, 220);
    expect(WindowPresentation.animationCurve.transform(.5), .875);
    expect(WindowPresentation.animationCurve.transform(.25), .578125);
    expect(WindowPresentation.animationCurve.transform(1), 1);
  });
  for (final people in [true, false]) {
    testWidgets(
      'live ${people ? 'people' : 'conversation'} slides continuously and reverses',
      (tester) async {
        tester.view
          ..physicalSize = const Size(700, 500)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final railKey = GlobalKey<_LivePaneState>();
        final paneKey = GlobalKey<_LivePaneState>();
        var compact = false;
        var taps = 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return WindowsPaneLayout(
                    compact: compact,
                    showPeople: people,
                    railWidth: 212,
                    rail: _LivePane(
                      key: railKey,
                      label: 'People',
                      onTap: () => taps++,
                    ),
                    pane: _LivePane(
                      key: paneKey,
                      label: 'Conversation',
                      onTap: () => taps++,
                    ),
                    divider: const VerticalDivider(width: 1),
                  );
                },
              ),
            ),
          ),
        );
        final railState = railKey.currentState;
        final paneState = paneKey.currentState;
        paneState!.text.text = 'Draft stays here';
        paneState.focus.requestFocus();
        await tester.pump();
        update(() => compact = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 55));
        final firstRail = tester.getRect(find.byKey(railKey));
        final firstPane = tester.getRect(find.byKey(paneKey));
        if (people) {
          expect(firstRail.width, inExclusiveRange(212, 320));
          expect(firstPane.left, greaterThan(213));
        } else {
          expect(firstRail.left, inExclusiveRange(-212, 0));
          expect(firstPane.left, inExclusiveRange(0, 213));
        }
        tester.view.physicalSize = const Size(500, 420);
        await tester.pump(const Duration(milliseconds: 35));
        expect(railKey.currentState, same(railState));
        expect(paneKey.currentState, same(paneState));
        final beforeReverse = tester.getRect(find.byKey(railKey));
        update(() => compact = false);
        await tester.pump();
        expect(tester.getRect(find.byKey(railKey)), beforeReverse);
        await tester.pump(const Duration(milliseconds: 50));
        update(() => compact = true);
        await tester.pump();
        tester.view.physicalSize = const Size(320, 360);
        await tester.pumpAndSettle();
        expect(railKey.currentState, same(railState));
        expect(paneKey.currentState, same(paneState));
        expect(paneState.text.text, 'Draft stays here');
        final hidden = people ? find.byKey(paneKey) : find.byKey(railKey);
        final visible = people ? find.byKey(railKey) : find.byKey(paneKey);
        expect(hidden, findsNothing);
        expect(visible, findsOneWidget);
        expect(
          find.byKey(people ? paneKey : railKey, skipOffstage: false),
          findsOneWidget,
        );
        if (people) expect(paneState.focus.hasFocus, isFalse);
        await tester.tap(find.text(people ? 'People' : 'Conversation'));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('app motion off applies final layout immediately', (
    tester,
  ) async {
    var compact = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return WindowsPaneLayout(
                  compact: compact,
                  showPeople: true,
                  railWidth: 212,
                  rail: const SizedBox(key: ValueKey('rail')),
                  pane: const SizedBox(key: ValueKey('pane')),
                  divider: const VerticalDivider(width: 1),
                );
              },
            ),
          ),
        ),
      ),
    );
    update(() => compact = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('pane')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
