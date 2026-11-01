import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/ui/window_presentation.dart';

class DelayedWindow extends JamiClient {
  @override
  Future<void> setWindowEdgeSpacing(
    String spacing, {
    required bool reposition,
  }) async {}

  final commands = <String>[];
  Completer<void>? blocked;

  @override
  Future<Map<String, dynamic>?> windowPresentationState() async => null;

  @override
  Future<void> windowCommand(String command) async {
    commands.add(command);
    await blocked?.future;
  }
}

void main() {
  testWidgets('animated resize delegates immediately without hiding content', (
    tester,
  ) async {
    final native = DelayedWindow();
    final window = WindowPresentation(native);
    addTearDown(window.dispose);
    await window.refresh();
    await window.setCompact(true, animate: true);
    expect(native.commands, ['compactAnimated']);
    expect(window.compact, isTrue);
    await window.setCompact(false, animate: true);
    expect(native.commands, ['compactAnimated', 'resetWindowAnimated']);
    expect(window.compact, isFalse);
  });

  test('a call arriving during pinning still gets its HUD bounds', () async {
    final native = DelayedWindow();
    final window = WindowPresentation(native);
    addTearDown(window.dispose);
    await window.setCompact(true);
    final gate = native.blocked = Completer<void>();
    final pin = window.togglePin();
    await Future<void>.delayed(Duration.zero);
    final hud = window.fit(CompactSurface.groupAudio);
    native.blocked = null;
    gate.complete();
    await Future.wait([pin, hud]);
    expect(native.commands, ['compact', 'pin', 'compactGroupAudio']);
    expect(window.pinned, isTrue);
    expect(window.surface, CompactSurface.groupAudio);
    await window.setCompact(false);
    expect(window.pinned, isTrue);
  });

  test('expansion wins over a queued compact fit', () async {
    final native = DelayedWindow();
    final window = WindowPresentation(native);
    addTearDown(window.dispose);
    await window.setCompact(true);
    final expand = window.setCompact(false);
    final staleFit = window.fit(CompactSurface.directAudio);
    await Future.wait([expand, staleFit]);
    expect(native.commands, ['compact', 'resetWindow']);
    expect(window.compact, isFalse);
  });

  test(
    'a failed native command does not block the next queued command',
    () async {
      final native = DelayedWindow();
      final window = WindowPresentation(native);
      addTearDown(window.dispose);
      await window.refresh();
      final gate = native.blocked = Completer<void>();
      final pin = window.togglePin();
      final failure = expectLater(pin, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final compact = window.setCompact(true);
      native.blocked = null;
      gate.completeError(StateError('Native window unavailable'));
      await failure;
      await compact;
      expect(native.commands, ['pin', 'compact']);
      expect(window.pinned, isFalse);
      expect(window.compact, isTrue);
    },
  );
}
