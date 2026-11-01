import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/window_dismiss.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/state/app_settings.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/window-dismiss');
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> native(String method, [Object? arguments]) {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) {
        if (data == null) {
          done.completeError(MissingPluginException());
        } else {
          codec.decodeEnvelope(data);
          done.complete();
        }
      },
    );
    return done.future;
  }

  Widget surface({
    bool enabled = true,
    WindowCloseAnimation openAnimation = WindowCloseAnimation.tray,
    WindowCloseAnimation minimizeAnimation = WindowCloseAnimation.tray,
    WindowCloseAnimation closeAnimation = WindowCloseAnimation.tray,
    int openDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    int minimizeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    int closeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
    Widget child = const ColoredBox(color: Color(0xff306090)),
  }) => MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: WindowDismiss(
        enabled: enabled,
        openAnimation: openAnimation,
        minimizeAnimation: minimizeAnimation,
        closeAnimation: closeAnimation,
        openDurationMs: openDurationMs,
        minimizeDurationMs: minimizeDurationMs,
        closeDurationMs: closeDurationMs,
        child: child,
      ),
    ),
  );

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('app preference enables effect even when OS motion is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, _configuration());
    await tester.pumpWidget(surface(enabled: false));
    expect(calls.last.arguments, _configuration(enabled: false));
  });

  testWidgets('all window animation settings reach the native bridge', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    for (final animation in WindowCloseAnimation.values) {
      await tester.pumpWidget(
        surface(
          openAnimation: animation,
          minimizeAnimation: animation,
          closeAnimation: animation,
          openDurationMs: 300,
          minimizeDurationMs: 500,
          closeDurationMs: 700,
        ),
      );
      expect(
        calls.last.arguments,
        _configuration(
          openAnimation: animation,
          minimizeAnimation: animation,
          closeAnimation: animation,
          openDurationMs: 300,
          minimizeDurationMs: 500,
          closeDurationMs: 700,
        ),
      );
    }
    await tester.pumpWidget(
      surface(enabled: false, closeAnimation: WindowCloseAnimation.warp),
    );
    expect(
      calls.last.arguments,
      _configuration(enabled: false, closeAnimation: WindowCloseAnimation.warp),
    );
    await tester.pumpWidget(const SizedBox());
    expect(
      calls.last.arguments,
      _configuration(enabled: false, closeAnimation: WindowCloseAnimation.warp),
    );
  });

  test(
    'preview sends action, style, and duration to the native bridge',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });

      expect(
        await WindowDismiss.preview(
          action: 'minimize',
          animation: WindowCloseAnimation.fade,
          durationMs: 640,
        ),
        isTrue,
      );
      expect(calls.single.method, 'preview');
      expect(calls.single.arguments, {
        'action': 'minimize',
        'animation': 'fade',
        'durationMs': 640,
      });
    },
  );

  test('preview treats native and plugin errors as unavailable', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'preview-unavailable');
    });
    expect(
      await WindowDismiss.preview(
        action: 'open',
        animation: WindowCloseAnimation.tray,
        durationMs: 240,
      ),
      isFalse,
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    expect(
      await WindowDismiss.preview(
        action: 'close',
        animation: WindowCloseAnimation.door,
        durationMs: 420,
      ),
      isFalse,
    );
  });

  testWidgets(
    'captures only current app pixels at physical size and resets input',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Map<Object?, Object?>? presented;
      Uint8List? copiedPixels;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'present') {
          presented = call.arguments as Map<Object?, Object?>;
          copiedPixels = Uint8List.fromList(presented!['rgba'] as Uint8List);
        }
        return null;
      });
      await tester.pumpWidget(surface());
      await native('attention');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      late Future<void> capture;
      await tester.runAsync(() async {
        capture = native('capture', 7);
      });
      await tester.pump();
      await tester.runAsync(() async {
        await capture.timeout(const Duration(seconds: 5));
      });
      expect(presented?['token'], 7);
      expect(presented?['width'], 320);
      expect(presented?['height'], 240);
      expect(copiedPixels?.length, 320 * 240 * 4);
      expect(copiedPixels?.take(4), [0x30, 0x60, 0x90, 0xff]);
      final centerPixel = (120 * 320 + 160) * 4;
      expect(
        copiedPixels?.sublist(centerPixel, centerPixel + 4),
        [0x30, 0x60, 0x90, 0xff],
        reason:
            'The attention wave stays outside the captured repaint boundary',
      );
      final ignore = find
          .byType(IgnorePointer)
          .evaluate()
          .map((e) => e.widget)
          .whereType<IgnorePointer>()
          .where((w) => w.ignoring);
      expect(ignore, isNotEmpty);
      await native('reset');
      await tester.pump();
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .descendant(
                    of: find.byType(WindowDismiss),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        false,
      );
    },
  );

  testWidgets('retiring privacy surface invalidates a pending capture', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    final capture = native('capture', 8);
    await tester.pumpWidget(surface(enabled: false));
    await tester.pump();
    await capture;
    expect(calls.where((c) => c.method == 'present'), isEmpty);
    expect(calls.last.arguments, _configuration(enabled: false));
  });

  testWidgets('disabled effects never capture a frame', (tester) async {
    await tester.pumpWidget(surface(enabled: false));
    await native('capture', 9);
    await tester.pump();
    expect(calls.where((c) => c.method == 'present'), isEmpty);
    expect(binding.hasScheduledFrame, false);
  });

  testWidgets('attention keeps input live with OS motion disabled', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      surface(
        child: GestureDetector(
          key: const ValueKey('attention-target'),
          onTap: () => taps++,
          child: const ColoredBox(color: Color(0xff306090)),
        ),
      ),
    );

    await native('attention');
    await tester.pump();
    expect(binding.hasScheduledFrame, isTrue);
    await tester.tap(find.byKey(const ValueKey('attention-target')));
    expect(taps, 1);
  });

  testWidgets('duplicate attention messages do not restart the wave', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(surface());
    await native('attention');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 50));
    await native('attention');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 249));
    expect(binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 16));
    expect(binding.hasScheduledFrame, isFalse);
  });

  testWidgets('attention is disabled, reset, and capture stop the wave', (
    tester,
  ) async {
    await tester.pumpWidget(surface(enabled: false));
    await native('attention');
    await tester.pump();
    expect(binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(surface());
    await native('attention');
    await tester.pump();
    expect(binding.hasScheduledFrame, isTrue);
    await native('reset');
    await tester.pump();
    expect(binding.hasScheduledFrame, isFalse);

    await native('attention');
    await tester.pump();
    expect(binding.hasScheduledFrame, isTrue);
    late Future<void> capture;
    await tester.runAsync(() async {
      capture = native('capture', 12);
    });
    await tester.pump();
    await tester.runAsync(() async {
      await capture.timeout(const Duration(seconds: 5));
    });
    expect(binding.hasScheduledFrame, isFalse);
    await native('reset');
  });

  testWidgets('disposing stops the attention ticker', (tester) async {
    await tester.pumpWidget(surface());
    await native('attention');
    await tester.pump();
    expect(binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'exit frame includes the shell background, not just foreground widgets',
    (tester) async {
      Uint8List? frame;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'present') {
          final args = call.arguments as Map<Object?, Object?>;
          frame = Uint8List.fromList(args['rgba'] as Uint8List);
        }
        return null;
      });
      const core = MethodChannel('syb.l/core');
      messenger.setMockMethodCallHandler(core, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(core, null));
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => WindowsChrome(
            jami: JamiClient(),
            renderControls: false,
            child: child!,
          ),
          home: const SizedBox.expand(),
        ),
      );
      late Future<void> capture;
      await tester.runAsync(() async {
        capture = native('capture', 11);
      });
      await tester.pump();
      await tester.runAsync(() async {
        await capture.timeout(const Duration(seconds: 5));
      });
      expect(frame, isNotNull);
      expect(
        frame![3],
        255,
        reason: 'The native exit must carry the full opaque window surface',
      );
      await native('reset');
      await tester.pump();
    },
  );

  testWidgets('account replacement keeps the successor native handler', (
    tester,
  ) async {
    Widget account(String id) => MaterialApp(
      home: WindowDismiss(
        key: ValueKey(id),
        enabled: true,
        child: const SizedBox.expand(),
      ),
    );
    await tester.pumpWidget(account('first'));
    await tester.pumpWidget(account('second'));
    await native('reset');
    expect(calls.map((c) => c.arguments), [
      _configuration(),
      _configuration(enabled: false),
      _configuration(),
    ]);
  });
}

Map<String, Object> _configuration({
  bool enabled = true,
  WindowCloseAnimation openAnimation = WindowCloseAnimation.tray,
  WindowCloseAnimation minimizeAnimation = WindowCloseAnimation.tray,
  WindowCloseAnimation closeAnimation = WindowCloseAnimation.tray,
  int openDurationMs = AppSettings.defaultWindowAnimationDurationMs,
  int minimizeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
  int closeDurationMs = AppSettings.defaultWindowAnimationDurationMs,
}) => {
  'enabled': enabled,
  'openAnimation': openAnimation.name,
  'minimizeAnimation': minimizeAnimation.name,
  'closeAnimation': closeAnimation.name,
  'openDurationMs': openDurationMs,
  'minimizeDurationMs': minimizeDurationMs,
  'closeDurationMs': closeDurationMs,
};
