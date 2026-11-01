import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/surface_protection.dart';
import 'package:sybl/ui/capture_sensitive_scope.dart';

class _Native {
  final calls = <bool>[];
  final pending = <Completer<bool>>[];
  bool autoReply = true;
  bool replyValue = true;
  bool throwOnApply = false;

  Future<bool> apply(bool visible) {
    calls.add(visible);
    if (throwOnApply) return Future.error(StateError('native failed'));
    if (autoReply) return Future.value(visible && replyValue);
    final completer = Completer<bool>();
    pending.add(completer);
    return completer.future;
  }
}

void main() {
  late _Native native;
  late bool armed;
  late Completer<void> settleGate;
  late bool holdSettle;
  late SensitiveSurfaceProtection protection;

  setUp(() {
    native = _Native();
    armed = true;
    holdSettle = false;
    settleGate = Completer<void>();
    protection = SensitiveSurfaceProtection(
      apply: native.apply,
      armed: () => armed,
      settle: () => holdSettle ? settleGate.future : Future<void>.value(),
    );
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('idle boot lifts the launch-time protection once', () async {
    protection.refresh();
    await flush();
    expect(native.calls, [false]);
    protection.refresh();
    await flush();
    expect(native.calls, [false, false]);
  });

  test('a sensitive surface stays hidden until native confirms', () async {
    native.autoReply = false;
    protection.acquire();
    await flush();
    expect(native.calls, [true]);
    expect(protection.revealAllowed, isFalse);
    native.pending.single.complete(true);
    await flush();
    expect(protection.revealAllowed, isTrue);
  });

  test('protection is lifted only after settle with no holders', () async {
    protection.acquire();
    await flush();
    holdSettle = true;
    protection.release();
    await flush();
    expect(native.calls, [true], reason: 'still settling');
    settleGate.complete();
    await flush();
    expect(native.calls, [true, false]);
    expect(protection.revealAllowed, isFalse);
  });

  test('reacquiring during settle keeps the window secure', () async {
    protection.acquire();
    await flush();
    holdSettle = true;
    protection.release();
    await flush();
    protection.acquire();
    expect(protection.revealAllowed, isTrue, reason: 'never lifted');
    settleGate.complete();
    await flush();
    expect(native.calls, [true]);
  });

  test('a surface opened during settle does not wait it out', () async {
    holdSettle = true;
    protection.refresh();
    await flush();
    expect(native.calls, isEmpty, reason: 'boot lift is settling');
    protection.acquire();
    await flush();
    expect(native.calls, [true]);
    expect(protection.revealAllowed, isTrue);
  });

  test('native refusal or error fails closed until retry', () async {
    native.replyValue = false;
    protection.acquire();
    await flush();
    expect(protection.revealAllowed, isFalse);
    expect(protection.failed, isTrue);

    native.replyValue = true;
    native.throwOnApply = true;
    protection.refresh();
    await flush();
    expect(protection.revealAllowed, isFalse);
    expect(protection.failed, isTrue);

    native.throwOnApply = false;
    protection.refresh();
    await flush();
    expect(protection.revealAllowed, isTrue);
  });

  test('an opt-out reveals without native calls', () async {
    armed = false;
    protection.acquire();
    await flush();
    expect(protection.revealAllowed, isTrue);
    expect(native.calls, isEmpty);
  });

  testWidgets('scope shows a placeholder until protection is confirmed', (
    tester,
  ) async {
    native.autoReply = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CaptureSensitiveScope(
          protection: protection,
          child: const Text('private message'),
        ),
      ),
    );
    expect(find.text('private message'), findsNothing);
    expect(
      find.byKey(const ValueKey('capture-sensitive-placeholder')),
      findsOneWidget,
    );
    native.pending.single.complete(true);
    await tester.pump();
    expect(find.text('private message'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(protection.holders, 0);
  });

  testWidgets('failed protection offers a retry and never reveals', (
    tester,
  ) async {
    native.replyValue = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CaptureSensitiveScope(
          protection: protection,
          child: const Text('private message'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('private message'), findsNothing);
    native.replyValue = true;
    await tester.tap(find.byKey(const ValueKey('capture-sensitive-retry')));
    await tester.pump();
    await tester.pump();
    expect(find.text('private message'), findsOneWidget);
  });

  testWidgets('a pending corner preview collapses instead of overflowing', (
    tester,
  ) async {
    native.autoReply = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              top: 10,
              right: 10,
              child: CaptureSensitiveScope(
                protection: protection,
                child: const Text('live video'),
              ),
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('live video'), findsNothing);
    expect(
      tester.getSize(
        find.byKey(const ValueKey('capture-sensitive-placeholder')),
      ),
      Size.zero,
    );
  });

  testWidgets('call surfaces are never gated, but still hold protection', (
    tester,
  ) async {
    native.replyValue = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CaptureSensitiveScope(
          protection: protection,
          gate: false,
          child: const Text('Accept'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Accept'), findsOneWidget);
    expect(protection.holders, 1);
    expect(native.calls, [true]);
  });

  testWidgets('Show anyway reveals only after an explicit choice', (
    tester,
  ) async {
    native.replyValue = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CaptureSensitiveScope(
          protection: protection,
          child: const Text('private message'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('private message'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('capture-sensitive-show')));
    await tester.pump();
    expect(find.text('private message'), findsOneWidget);
  });
}
