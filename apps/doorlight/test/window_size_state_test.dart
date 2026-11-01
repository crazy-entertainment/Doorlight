import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/window_presentation.dart';
import 'package:sybl/ui/windows_chrome.dart';

class _WindowJami extends JamiClient {
  bool compact = false;
  bool defaultSize = true;
  bool animating = false;
  bool fail = false;
  final commands = <String>[];
  final spacings = <(String, bool)>[];

  @override
  Future<void> setWindowEdgeSpacing(
    String spacing, {
    required bool reposition,
  }) async {
    spacings.add((spacing, reposition));
  }

  @override
  Future<Map<String, dynamic>?> windowPresentationState() async => {
    'compact': compact,
    'defaultSize': defaultSize,
    'animating': animating,
  };

  @override
  Future<void> windowCommand(String command) async {
    if (fail) throw PlatformException(code: 'window_mode_failed');
    commands.add(command);
    compact = command == 'compact';
    defaultSize = command == 'expand' || command == 'resetWindow';
  }
}

void main() {
  testWidgets('hydrating saved spacing does not move a restored window', (
    tester,
  ) async {
    final jami = _WindowJami();
    Future<void> mount(WindowEdgeSpacing spacing) => tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: WindowsChrome(
          jami: jami,
          windowEdgeSpacing: spacing,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await mount(WindowEdgeSpacing.close);
    await tester.pumpAndSettle();
    await mount(WindowEdgeSpacing.floating);
    await tester.pumpAndSettle();
    expect(jami.spacings, [('close', false), ('floating', false)]);
  });
  testWidgets('bootstrap preserves placement; selecting spacing reanchors', (
    tester,
  ) async {
    final jami = _WindowJami();
    final window = WindowPresentation(
      jami,
      edgeSpacing: WindowEdgeSpacing.floating,
    );
    addTearDown(window.dispose);
    await window.refresh();
    expect(jami.spacings, [('floating', false)]);
    await window.setEdgeSpacing(WindowEdgeSpacing.close);
    expect(jami.spacings, [('floating', false), ('close', true)]);
    await window.toggleSize();
    expect(jami.commands, ['compact']);
  });
  testWidgets('native target layout stays separate from animation activity', (
    tester,
  ) async {
    final jami = _WindowJami()..animating = true;
    final window = WindowPresentation(jami);
    addTearDown(window.dispose);
    await window.refresh();
    expect(window.compact, isFalse);
    expect(window.animating, isTrue);
    jami.animating = false;
    await window.refresh();
    expect(window.animating, isFalse);
    jami
      ..compact = true
      ..animating = true;
    await window.refresh();
    expect(window.compact, isTrue);
    expect(window.animating, isTrue);
  });
  testWidgets(
    'resized and compact windows return to default before compacting',
    (tester) async {
      for (final compact in [false, true]) {
        final jami = _WindowJami()
          ..compact = compact
          ..defaultSize = false;
        final window = WindowPresentation(jami);
        await window.refresh();
        expect(window.compact, compact);
        expect(window.defaultSize, isFalse);
        await window.toggleSize();
        expect(jami.commands, ['resetWindow']);
        expect(window.compact, isFalse);
        expect(window.defaultSize, isTrue);
        await window.toggleSize();
        expect(jami.commands, ['resetWindow', 'compact']);
        expect(window.compact, isTrue);
        window.dispose();
      }
    },
  );

  testWidgets('remembered placement is an explicit reset preference', (
    tester,
  ) async {
    final jami = _WindowJami()..defaultSize = false;
    final window = WindowPresentation(
      jami,
      rememberDefaultWindowPosition: true,
    );
    addTearDown(window.dispose);
    await window.toggleSize();
    expect(jami.commands, ['expand']);
    jami.defaultSize = false;
    window.rememberDefaultWindowPosition = false;
    await window.toggleSize();
    expect(jami.commands, ['expand', 'resetWindow']);
  });

  testWidgets(
    'native maximize and restore update layout through window metrics',
    (tester) async {
      final jami = _WindowJami()
        ..compact = true
        ..defaultSize = false;
      final window = WindowPresentation(jami);
      addTearDown(window.dispose);
      await window.refresh();
      expect(window.compact, isTrue);
      jami.compact = false;
      window.didChangeMetrics();
      await window.refresh();
      expect(window.compact, isFalse);
      expect(window.defaultSize, isFalse);
      jami.compact = true;
      window.didChangeMetrics();
      await window.refresh();
      expect(window.compact, isTrue);
    },
  );

  testWidgets('failed reset preserves confirmed geometry and visibility', (
    tester,
  ) async {
    final jami = _WindowJami()..defaultSize = false;
    final window = WindowPresentation(jami);
    addTearDown(window.dispose);
    await window.refresh();
    jami.fail = true;
    await expectLater(window.toggleSize(), throwsA(isA<PlatformException>()));
    expect(window.defaultSize, isFalse);
    expect(window.compact, isFalse);
  });
}
