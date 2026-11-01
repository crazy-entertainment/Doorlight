import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'package:sybl/ui/doorlight_brand.dart';
import 'package:sybl/ui/gravity.dart';
import 'package:sybl/ui/onboarding_surface.dart';
import 'package:sybl/ui/window_presentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const core = MethodChannel('syb.l/core');
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() => messenger.setMockMethodCallHandler(core, null));

  testWidgets('window reset preference updates without replacing controller', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(core, (call) async => null);
    final jami = JamiClient();
    WindowPresentation? controller;
    Widget shell(bool remember) => MaterialApp(
      theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
      home: WindowsChrome(
        jami: jami,
        rememberDefaultWindowPosition: remember,
        child: Builder(
          builder: (context) {
            controller = WindowPresentationScope.maybeOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(shell(false));
    final initial = controller!;
    expect(initial.rememberDefaultWindowPosition, isFalse);
    await tester.pumpWidget(shell(true));
    expect(controller, same(initial));
    expect(initial.rememberDefaultWindowPosition, isTrue);
    await tester.pumpWidget(shell(false));
    expect(initial.rememberDefaultWindowPosition, isFalse);
  });

  testWidgets('page chrome leaves sidebar at top and modal covers controls', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(core, (call) async {
      calls.add(call);
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        builder: (context, child) => WindowsChrome(
          jami: JamiClient(),
          renderControls: false,
          child: child!,
        ),
        home: Builder(
          builder: (context) => WindowsChromeContent(
            child: Row(
              children: [
                const SizedBox(
                  key: ValueKey('sidebar'),
                  width: 212,
                  height: double.infinity,
                ),
                Expanded(
                  child: Center(
                    child: TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            const AlertDialog(content: Text('Modal')),
                      ),
                      child: const Text('Open modal'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey('sidebar'))).dy, 0);
    final close = find.byKey(const ValueKey('windows-close-button'));
    expect(tester.getTopLeft(close).dy, 0);
    await tester.tap(find.text('Open modal'));
    await tester.pumpAndSettle();
    calls.clear();
    await tester.tapAt(tester.getCenter(close));
    await tester.pump();
    expect(calls.where((call) => call.method == 'windowCommand'), isEmpty);
    expect(find.byType(ModalBarrier), findsWidgets);
  });

  testWidgets('onboarding keeps one surface and only native window controls', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(core, (call) async {
      calls.add(call);
      return null;
    });
    final jami = JamiClient();
    Widget shell(bool onboarding) => MaterialApp(
      theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
      home: WindowsChrome(
        jami: jami,
        onboarding: onboarding,
        child: const OnboardingSurface(child: SizedBox.expand()),
      ),
    );
    await tester.pumpWidget(shell(true));
    expect(find.byType(DoorlightMark), findsNothing);
    expect(find.text('Doorlight'), findsNothing);
    expect(find.byType(WindowModeButtons), findsNothing);
    expect(
      find.byKey(const ValueKey('onboarding-warm-surface')),
      findsOneWidget,
    );
    for (final key in ['windows-minimize-button', 'windows-close-button']) {
      await tester.tap(find.byKey(ValueKey(key)));
    }
    final drag = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('windows-title-drag-region')),
    );
    drag.onPanStart!(DragStartDetails());
    await tester.pump();
    expect(
      calls
          .where((call) => call.method == 'windowCommand')
          .map((call) => call.arguments),
      [
        {'command': 'minimize'},
        {'command': 'close'},
        {'command': 'drag'},
      ],
    );
    await tester.pumpWidget(shell(false));
    expect(
      find.byKey(const ValueKey('onboarding-warm-surface')),
      findsOneWidget,
    );
    expect(find.byType(DoorlightMark), findsNothing);
    expect(find.text('Doorlight'), findsNothing);
    expect(find.byType(WindowModeButtons), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final animations in [true, false]) {
    testWidgets('size transition follows app motion setting: $animations', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(core, (call) async {
        calls.add(call);
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: !animations),
            child: WindowsChrome(
              jami: JamiClient(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Compact'));
      await tester.pump();
      expect(
        calls
            .where((call) => call.method == 'windowCommand')
            .map((call) => call.arguments),
        [
          {'command': animations ? 'compactAnimated' : 'compact'},
        ],
      );
    });
  }

  testWidgets('custom Windows chrome delegates native window behavior', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(core, (call) async {
      calls.add(call);
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: WindowsChrome(
          jami: JamiClient(),
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('windows-title-bar')), findsOneWidget);
    final sizeButton = find.byTooltip('Compact');
    expect(
      tester.getCenter(find.byTooltip('Pin')).dx,
      lessThan(
        tester
            .getCenter(find.byKey(const ValueKey('windows-minimize-button')))
            .dx,
      ),
    );
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('windows-minimize-button')))
          .dx,
      lessThan(tester.getCenter(sizeButton).dx),
    );
    expect(
      tester.getCenter(sizeButton).dx,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('windows-close-button'))).dx,
      ),
    );

    for (final key in const [
      ValueKey('windows-minimize-button'),
      ValueKey('windows-close-button'),
    ]) {
      expect(find.byKey(key), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('windows-minimize-button')));
    await tester.tap(find.byKey(const ValueKey('windows-close-button')));
    final dragRegion = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('windows-title-drag-region')),
    );
    dragRegion.onPanStart!(DragStartDetails());
    await tester.tap(find.byKey(const ValueKey('windows-title-drag-region')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('windows-title-drag-region')));
    dragRegion.onSecondaryTapUp!(TapUpDetails(kind: PointerDeviceKind.mouse));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const ValueKey('windows-maximize-button')), findsNothing);
    expect(
      calls
          .where((call) => call.method == 'windowCommand')
          .map((call) => call.arguments),
      [
        {'command': 'minimize'},
        {'command': 'close'},
        {'command': 'drag'},
        {'command': 'toggleMaximize'},
        {'command': 'systemMenu'},
      ],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('under gravity the reset button takes the close button spot', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(core, (_) async => null);
    gravityImpactSound = (_, _) {};
    addTearDown(() => gravityMode.value = false);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        builder: (context, child) => WindowsChrome(
          jami: JamiClient(),
          renderControls: false,
          child: child!,
        ),
        home: Builder(
          builder: (context) =>
              const WindowsChromeContent(child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    final close = find.byKey(const ValueKey('windows-close-button'));
    final spot = tester.getRect(close);
    const reset = ValueKey('gravity-reset');

    gravityMode.value = true;
    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.byKey(reset), findsNothing);
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The real close button has fallen; the reset button sits in its spot
    // in the same flat caption look.
    final x = find.byIcon(Icons.close_rounded);
    expect(tester.getRect(x).center.dy, greaterThan(spot.bottom + 100));
    expect(tester.getRect(find.byKey(reset)), spot);
    final face = tester.widget<IconButton>(find.byKey(reset));
    final caption = tester.widget<IconButton>(
      find.ancestor(of: x, matching: find.byType(IconButton)),
    );
    expect((face.icon as Icon).icon, Icons.restart_alt_rounded);
    expect((face.icon as Icon).size, (caption.icon as Icon).size);
    expect(face.color, caption.color);
    // Hovered and pressed like minimize and maximize, not close's red, and
    // without a tooltip.
    final minimize = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.horizontal_rule_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(face.hoverColor, minimize.hoverColor);
    expect(face.highlightColor, minimize.highlightColor);
    expect(face.focusColor, minimize.focusColor);
    expect(face.hoverColor, isNot(caption.hoverColor));
    expect(face.tooltip, isNull);
    expect(face.style, caption.style);

    await tester.tap(find.byKey(reset));
    for (var i = 0; gravityMode.value && i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(gravityMode.value, isFalse);
    expect(
      tester.getRect(find.byIcon(Icons.close_rounded)).center,
      spot.center,
    );
    expect(find.byKey(reset), findsNothing);
  });
}
