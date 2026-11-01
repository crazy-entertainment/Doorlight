import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/voice_review_player.dart';
import 'package:sybl/ui/pane_activity.dart';
import 'package:sybl/core/media_retirement.dart';

final class _Player implements VoicePlaybackDevice {
  final positionEvents = StreamController<Duration>.broadcast();
  final completeEvents = StreamController<void>.broadcast();
  int plays = 0;
  int stops = 0;
  int closes = 0;
  Completer<void>? pendingPlay;
  Completer<void>? pendingStop;
  bool failRelease = false;
  @override
  Stream<Duration> get positions => positionEvents.stream;
  @override
  Stream<void> get completions => completeEvents.stream;
  @override
  Future<void> play(String path) async {
    plays++;
    await pendingPlay?.future;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {
    stops++;
    await pendingStop?.future;
    if (failRelease) throw StateError('stop');
  }

  @override
  Future<void> dispose() async {
    closes++;
    if (failRelease) throw StateError('dispose');
  }

  Future<void> closeStreams() async {
    await positionEvents.close();
    await completeEvents.close();
  }
}

void main() {
  testWidgets(
    'hidden retained pane retires late playback and requires a fresh play',
    (tester) async {
      final player = _Player()..pendingPlay = Completer<void>();
      var active = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return PaneActivityScope(
                active: active,
                child: VoiceReviewPlayer(
                  path: 'owned.m4a',
                  duration: const Duration(seconds: 1),
                  isCurrent: () => true,
                  validate: () async => true,
                  createDevice: () => player,
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('Play voice message'));
      await tester.pump();
      expect(player.plays, 1);
      update(() => active = false);
      await tester.pump();
      expect(player.stops, 1);
      player.pendingPlay!.complete();
      await tester.pump();
      expect(player.stops, greaterThanOrEqualTo(2));
      await tester.tap(find.byTooltip('Play voice message'));
      await tester.pump();
      expect(player.plays, 1);
      update(() => active = true);
      await tester.pump();
      expect(player.plays, 1);
      await tester.tap(find.byTooltip('Play voice message'));
      await tester.pump();
      expect(player.plays, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await player.closeStreams();
    },
  );
  testWidgets(
    'identity retirement awaits late native play and its final stop',
    (tester) async {
      final player = _Player()..pendingPlay = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: VoiceReviewPlayer(
            path: 'owned.m4a',
            duration: const Duration(seconds: 1),
            isCurrent: () => true,
            validate: () async => true,
            createDevice: () => player,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Play voice message'));
      await tester.pump();
      bool? retired;
      unawaited(MediaRetirement.stopAll().then((value) => retired = value));
      await tester.pump();
      expect(retired, isNull);
      expect(player.stops, 1);
      player.pendingPlay!.complete();
      await tester.pump();
      expect(retired, isTrue);
      expect(player.stops, greaterThanOrEqualTo(2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await player.closeStreams();
    },
  );
  testWidgets('another player waits for pending start and actual release', (
    tester,
  ) async {
    final first = _Player()..pendingPlay = Completer<void>();
    final second = _Player();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (final entry in [('first', first), ('second', second)])
              VoiceReviewPlayer(
                key: ValueKey(entry.$1),
                path: '${entry.$1}.m4a',
                duration: const Duration(seconds: 1),
                isCurrent: () => true,
                validate: () async => true,
                createDevice: () => entry.$2,
              ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play voice message').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Play voice message').last);
    await tester.pump();
    expect(second.plays, 0);
    first.pendingStop = Completer<void>();
    first.pendingPlay!.complete();
    await tester.pump();
    expect(first.stops, 1);
    expect(second.plays, 0);
    first.pendingStop!.complete();
    await tester.pump();
    expect(second.plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await first.closeStreams();
    await second.closeStreams();
  });

  testWidgets('failed stop and disposal cannot free playback authority', (
    tester,
  ) async {
    final first = _Player();
    final second = _Player();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (final entry in [('first', first), ('second', second)])
              VoiceReviewPlayer(
                key: ValueKey(entry.$1),
                path: '${entry.$1}.m4a',
                duration: const Duration(seconds: 1),
                isCurrent: () => true,
                validate: () async => true,
                createDevice: () => entry.$2,
              ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play voice message').first);
    await tester.pump();
    first.failRelease = true;
    await tester.tap(find.byTooltip('Play voice message'));
    await tester.pump();
    expect(first.stops, 1);
    expect(first.closes, 1);
    expect(second.plays, 0);
    expect(find.text('Voice playback unavailable'), findsNWidgets(2));
    first.failRelease = false;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await first.closeStreams();
    await second.closeStreams();
  });
  testWidgets('invalid or stale validation never creates a playback device', (
    tester,
  ) async {
    var created = 0;
    var current = true;
    final validation = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceReviewPlayer(
          path: 'owned.m4a',
          duration: const Duration(seconds: 1),
          isCurrent: () => current,
          validate: () => validation.future,
          createDevice: () {
            created++;
            return _Player();
          },
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play voice message'));
    current = false;
    validation.complete(true);
    await tester.pump();
    expect(created, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('late native play completion is stopped after backgrounding', (
    tester,
  ) async {
    final player = _Player()..pendingPlay = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceReviewPlayer(
          path: 'owned.m4a',
          duration: const Duration(seconds: 1),
          isCurrent: () => true,
          validate: () async => true,
          createDevice: () => player,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play voice message'));
    await tester.pump();
    expect(player.plays, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final stopsBeforeCompletion = player.stops;
    player.pendingPlay!.complete();
    await tester.pump();
    expect(player.stops, greaterThan(stopsBeforeCompletion));
    expect(find.byTooltip('Pause voice message'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(player.closes, 1);
    expect(player.positionEvents.hasListener, isFalse);
    await player.closeStreams();
  });
  testWidgets('owner loss stops playback without requiring a widget rebuild', (
    tester,
  ) async {
    var current = true;
    final player = _Player();
    await tester.pumpWidget(
      MaterialApp(
        home: VoiceReviewPlayer(
          path: 'owned.m4a',
          duration: const Duration(seconds: 1),
          isCurrent: () => current,
          validate: () async => true,
          createDevice: () => player,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Play voice message'));
    await tester.pump();
    expect(find.byTooltip('Pause voice message'), findsOneWidget);
    current = false;
    await tester.pump(const Duration(milliseconds: 101));
    expect(player.stops, 1);
    expect(find.byTooltip('Pause voice message'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await player.closeStreams();
  });
}
