import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sybl/state/overlay_settings.dart';

class MemoryOverlayStore implements OverlayDocumentStore {
  String? document;
  bool succeeds = true;
  Completer<void>? barrier;
  @override
  String? read() => document;
  @override
  Future<bool> write(String value) async {
    await barrier?.future;
    if (!succeeds) return false;
    document = value;
    return true;
  }
}

const timerId = '0123456789abcdef0123456789abcdef';
Map<String, Object> timerSettings(DateTime start, {String mode = 'Countdown'}) {
  final end = OverlayTimers.ticks(start.add(const Duration(seconds: 10)));
  final raw =
      '$timerId|Tea|$mode|Duration|10000|${mode == 'Stopwatch' ? 0 : 10000}|0|${mode == 'Stopwatch' ? OverlayTimers.ticks(start) : end}|1|0|1|Minutes,,;,,%3A;Seconds,,';
  return {
    'timer.activeId': timerId,
    'timer.records.v2': '@0:1',
    'timer.records.chunk.0.0': raw,
  };
}

void main() {
  test('reset preserves each timer mode and serialized remaining value', () {
    final start = DateTime.utc(2026, 10, 20);
    for (final example in [
      (mode: 'Stopwatch', kind: 'Duration', elapsed: 3, expected: '0'),
      (mode: 'Countdown', kind: 'Duration', elapsed: 3, expected: '10000.0'),
      (mode: 'Countdown', kind: 'Until', elapsed: 3, expected: '7000.0'),
      (mode: 'Countdown', kind: 'Until', elapsed: 11, expected: '0'),
    ]) {
      final settings = timerSettings(start, mode: example.mode);
      final original = OverlayTimers.read(settings).single;
      original[3] = example.kind;
      original[6] = OverlayTimers.ticks(
        start.add(const Duration(seconds: 10)),
      ).toString();
      settings['timer.records.chunk.0.0'] = original.join('|');
      final reset = OverlayTimers.update(
        settings,
        start.add(Duration(seconds: example.elapsed)),
        action: 'reset',
        id: timerId,
      )!;
      final row = OverlayTimers.read(reset).single;
      expect(row[5], example.expected);
      expect(row.sublist(8, 11), ['0', '0', '1']);
      expect(row.sublist(0, 5), original.sublist(0, 5));
      expect(OverlayTimers.read(settings).single, original);
    }
  });

  test(
    'failed durable import leaves migration and confirmed values unchanged',
    () async {
      final store = MemoryOverlayStore()..succeeds = false;
      final settings = OverlaySettings(store);
      expect(
        await settings.replace(
          {'chat.names': false},
          expectedRevision: 0,
          importing: true,
        ),
        false,
      );
      expect(settings.imported, false);
      expect(settings.values, isEmpty);
      expect(settings.revision, 0);
      store.succeeds = true;
      expect(
        await settings.replace(
          {'chat.names': false},
          expectedRevision: 0,
          importing: true,
        ),
        true,
      );
      final restarted = OverlaySettings(store);
      expect(restarted.values['chat.names'], false);
      expect(
        await restarted.replace({}, expectedRevision: 1, importing: true),
        false,
      );
    },
  );

  test(
    'concurrent and stale replacements cannot overwrite a committed transaction',
    () async {
      final store = MemoryOverlayStore()..barrier = Completer<void>();
      final settings = OverlaySettings(store);
      final pending = settings.replace({
        'cross.visible': true,
      }, expectedRevision: 0);
      expect(
        await settings.replace({'cross.visible': false}, expectedRevision: 0),
        false,
      );
      expect(settings.values, isEmpty);
      store.barrier!.complete();
      expect(await pending, true);
      expect(
        await settings.replace({'cross.visible': false}, expectedRevision: 0),
        false,
      );
      expect(settings.values['cross.visible'], true);
    },
  );

  test('damaged document cannot be replaced by migration defaults', () async {
    final store = MemoryOverlayStore()..document = '{broken';
    final settings = OverlaySettings(store);
    expect(settings.available, false);
    expect(
      await settings.replace({}, expectedRevision: 0, importing: true),
      false,
    );
    expect(store.document, '{broken');
  });

  test(
    'settings reject private authority, paths, invalid numbers and incomplete timer transactions',
    () {
      for (final map in <Map<String, Object>>[
        {'overlayChatConsent': true},
        {'account.id': 'x'},
        {'cross.imageFile': '../identity'},
        {'timer.soundFile': r'C:\private.wav'},
        {'cross.gap': double.nan},
        {'chat.textSize': 200},
        {'timer.records.v2': '@0:2', 'timer.records.chunk.0.0': ''},
        {'timer.records.v2': '@0:999'},
      ]) {
        expect(() => OverlaySettings.validate(map), throwsFormatException);
      }
      expect(
        OverlaySettings.validate({
          'helper.theme': 'cozy',
          'cross.editing': true,
          'clock.fadeOpacity': .5,
          'clock.shown': true,
          'weather.windowWidth': 400.0,
          'weather.windowHeight': 300.0,
          'chat.text': false,
        }),
        {'chat.text': false},
      );
    },
  );

  test(
    'deadline survives desktop restart and completion commits only once',
    () async {
      final start = DateTime.utc(2026, 10, 20);
      final store = MemoryOverlayStore();
      final initial = OverlaySettings(store);
      await initial.replace(
        timerSettings(start),
        expectedRevision: 0,
        importing: true,
      );
      final restarted = OverlaySettings(store);
      final rows = OverlayTimers.read(restarted.values);
      expect(
        OverlayTimers.remaining(
          rows.single,
          OverlayTimers.ticks(start.add(const Duration(seconds: 3))),
        ),
        7000,
      );
      final completed = OverlayTimers.update(
        restarted.values,
        start.add(const Duration(seconds: 11)),
      )!;
      expect(
        await restarted.replace(
          completed,
          expectedRevision: restarted.revision,
        ),
        true,
      );
      expect(OverlayTimers.read(restarted.values).single.sublist(8, 11), [
        '0',
        '1',
        '1',
      ]);
      expect(
        OverlayTimers.update(
          restarted.values,
          start.add(const Duration(seconds: 12)),
        ),
        null,
      );
      expect(jsonDecode(store.document!)['revision'], 2);
    },
  );

  test(
    'pause/resume uses original ID, elapsed stopwatch and explicit visibility',
    () {
      final start = DateTime.utc(2026, 10, 20);
      final paused = OverlayTimers.update(
        timerSettings(start, mode: 'Stopwatch'),
        start.add(const Duration(seconds: 3)),
        action: 'toggle',
        id: timerId,
      )!;
      final row = OverlayTimers.read(paused).single;
      expect(row[0], timerId);
      expect(row[5], '3000.0');
      expect(row[8], '0');
      final resumed = OverlayTimers.update(
        paused,
        start.add(const Duration(seconds: 5)),
        action: 'toggle',
        id: timerId,
      )!;
      expect(
        OverlayTimers.remaining(
          OverlayTimers.read(resumed).single,
          OverlayTimers.ticks(start.add(const Duration(seconds: 7))),
        ),
        5000,
      );
      final hidden = OverlayTimers.update(
        resumed,
        start,
        action: 'visibility',
        id: timerId,
        visible: false,
      )!;
      expect(OverlayTimers.read(hidden).single[10], '0');
    },
  );
}
