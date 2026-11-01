import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/notice.dart';

Future<void> _pump(WidgetTester tester, {bool reduced = false}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(JamiClient(), await SharedPreferences.getInstance());
  addTearDown(state.dispose);
  addTearDown(clearNotices);
  clearNotices();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: Warm.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Stack(
          children: [
            Positioned.fill(child: child!),
            NoticeHost(state: state),
          ],
        ),
      ),
      home: const Scaffold(),
    ),
  );
}

void main() {
  testWidgets('appears top-right and auto-hides', (tester) async {
    await _pump(tester);
    showNotice('Saved');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final rect = tester.getRect(find.text('Saved'));
    expect(rect.center.dx, greaterThan(600));
    expect(rect.center.dy, lessThan(400));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('action fires and dismisses', (tester) async {
    await _pump(tester);
    var fired = 0;
    showNotice('Sent', actionLabel: 'Undo', onAction: () => fired++);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(fired, 1);
    expect(find.text('Sent'), findsNothing);
  });

  testWidgets('keeps at most 3, newest on top', (tester) async {
    await _pump(tester);
    for (final t in ['a', 'b', 'c', 'd']) {
      showNotice(t);
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('a'), findsNothing);
    expect(
      tester.getTopLeft(find.text('d')).dy,
      lessThan(tester.getTopLeft(find.text('c')).dy),
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('reduced motion shows immediately', (tester) async {
    await _pump(tester, reduced: true);
    showNotice('Now');
    await tester.pump();
    final fade = tester.widget<Opacity>(
      find.ancestor(of: find.text('Now'), matching: find.byType(Opacity)).first,
    );
    expect(fade.opacity, 1);
    await tester.pump(const Duration(seconds: 5));
  });
}
