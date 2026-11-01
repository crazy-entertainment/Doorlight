import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// A single document is committed by the Windows preferences adapter's atomic
/// replacement/lease. Package LocalSettings is only a one-time migration source.
abstract interface class OverlayDocumentStore {
  String? read();
  Future<bool> write(String document);
}

final class PreferencesOverlayStore implements OverlayDocumentStore {
  PreferencesOverlayStore(this.preferences);
  final SharedPreferences preferences;
  static const key = 'overlay.document.v1';
  @override
  String? read() => preferences.getString(key);
  @override
  Future<bool> write(String document) async {
    bool saved;
    try {
      saved = await preferences.setString(key, document);
    } on Object {
      await preferences.reload();
      rethrow;
    }
    // SharedPreferences updates its cache before the platform write completes.
    if (!saved) await preferences.reload();
    return saved;
  }
}

final class OverlaySettings extends ChangeNotifier {
  OverlaySettings(this.store) {
    try {
      final raw = store.read();
      if (raw == null) return;
      final document = jsonDecode(raw);
      if (document is! Map ||
          document.length != 4 ||
          document['v'] != 1 ||
          document['imported'] is! bool ||
          document['revision'] is! int ||
          document['revision'] < 0) {
        throw const FormatException('Invalid overlay document');
      }
      _values = validate(document['values']);
      imported = document['imported'];
      revision = document['revision'];
    } on Object {
      // Never overwrite a damaged document with a default or a package import.
      available = false;
    }
  }

  final OverlayDocumentStore store;
  Map<String, Object> _values = {};
  Map<String, Object> get values => Map.unmodifiable(_values);
  bool imported = false;
  bool available = true;
  bool busy = false;
  int revision = 0;
  static const maxBytes = 160 * 1024;

  static const _appearance = {
    'helper.theme',
    'helper.vibe',
    'helper.vibeOpacity',
    'helper.vibeIntensity',
    'helper.vibeAnimated',
  };
  static const _transient = {
    'cross.editing',
    'cross.windowWidth',
    'cross.center',
    'cross.reset',
    'cross.toggle',
    'cross.refreshEditor',
    'cross.simpleSize',
    'helper.appearance',
    // Retired widget runtime measurements, never user settings.
    'clock.fadeOpacity',
    'clock.shown',
    'weather.windowWidth',
    'weather.windowHeight',
  };
  static const _boolOptions = {
    'visible',
    'writable',
    'names',
    'avatars',
    'text',
    'fade',
    'hasPlace',
    'temp',
    'date',
    'dateOnly',
    'aimToggle',
    'outlineOpacityLinked',
    'outline',
    'initialSizePending',
    'progress',
    'confetti',
    'flash',
    'running',
    'appearanceOverride',
  };
  static const _stringOptions = {
    'tab',
    'crossEditorMode',
    'clockEditorMode',
    'weatherEditorMode',
    'kind',
    'mode',
    'style',
    'color',
    'outlineColor',
    'pixels',
    'imageFile',
    'imageName',
    'hold',
    'ids',
    'active',
    'activeId',
    'name',
    'window',
    'zone',
    'format',
    'dateFormat',
    'layout',
    'prefix',
    'suffix',
    'font',
    'bg',
    'place',
    'placeLabel',
    'unit',
    'iconSet',
    'sound',
    'soundFile',
    'soundName',
    'recent',
    'presets',
  };
  static const _ranges = <String, (double, double)>{
    'fadeStart': (0, 240),
    'fadeEnd': (0, 240),
    'opacity': (0, 1),
    'width': (200, 900),
    'height': (120, 900),
    'minSeconds': (1, 30),
    'fadeSeconds': (0, 300),
    'textSize': (10, 24),
    'bgOpacity': (0, 1),
    'length': (1, 40),
    'thickness': (1, 10),
    'gap': (0, 30),
    'outlineOpacity': (0, 1),
    'outlineThickness': (0, 6),
    'pixelSize': (1, 6),
    'imageScale': (.25, 4),
    'aimFadeMs': (0, 750),
    'aimFadeInMs': (0, 750),
    'lat': (-90, 90),
    'lon': (-180, 180),
    'size': (1, 1000),
    'contentWidth': (0, 10000),
    'contentHeight': (0, 10000),
    'volume': (0, 1),
    'duration': (.001, 86400000),
    'minutes': (0, 1440000),
    'remaining': (0, 86400000),
  };

  static Map<String, Object> validate(Object? candidate) {
    if (candidate is! Map || candidate.length > 3000) {
      throw const FormatException('Invalid settings');
    }
    final result = <String, Object>{};
    for (final entry in candidate.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          key.length > 180 ||
          !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(key)) {
        throw const FormatException('Invalid settings key');
      }
      if (_appearance.contains(key) || _transient.contains(key)) continue;
      if (!RegExp(
        r'^(general|helper|time|chat|voice|clock|weather|weatherInstances|timer|cross|crossPresets|hotkey)\.',
      ).hasMatch(key)) {
        throw const FormatException('Unknown settings family');
      }
      final option = key.split('.').last;
      bool valid = false;
      if (key.startsWith('timer.records.')) {
        valid =
            (key == 'timer.records.v2' ||
                RegExp(
                  r'^timer\.records\.chunk\.[01]\.\d{1,3}$',
                ).hasMatch(key)) &&
            value is String &&
            value.length <= 64000;
      } else if (key.startsWith('hotkey.')) {
        valid =
            value is String &&
            value.length <= 80 &&
            !value.contains(RegExp(r'[\x00-\x1f]'));
      } else if (key.startsWith('timer.simpleEmptyDuration.')) {
        valid = value is bool;
      } else if (_boolOptions.contains(option)) {
        valid = value is bool;
      } else if (_stringOptions.contains(option)) {
        valid =
            value is String &&
            value.length <= 16000 &&
            !value.contains('\u0000');
        if (valid && const {'imageFile', 'soundFile'}.contains(option)) {
          valid =
              value.isEmpty ||
              RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9]{1,8}$').hasMatch(value);
        }
      } else if (_ranges[option] case final range?) {
        valid =
            value is num &&
            value.isFinite &&
            value >= range.$1 &&
            value <= range.$2;
      } else if (const {'utcEnd', 'endsAt', 'imageVersion'}.contains(option)) {
        // JSON integer preserves .NET's 100ns ticks without a floating conversion.
        valid =
            value is num &&
            value.isFinite &&
            value == value.roundToDouble() &&
            value >= 0 &&
            value <= 3155378975999999999;
      }
      if (!valid) throw FormatException('Invalid setting: $key');
      result[key] = value as Object;
    }
    if (utf8.encode(jsonEncode(result)).length > maxBytes) {
      throw const FormatException('Settings too large');
    }
    // Also validate the aggregate timer transaction, not each chunk in isolation.
    OverlayTimers.read(result);
    return result;
  }

  Future<bool> replace(
    Object? candidate, {
    required int expectedRevision,
    bool importing = false,
  }) async {
    if (!available ||
        busy ||
        expectedRevision != revision ||
        importing && imported) {
      return false;
    }
    final next = validate(candidate);
    busy = true;
    notifyListeners();
    try {
      final nextRevision = revision + 1;
      final encoded = jsonEncode({
        'v': 1,
        'imported': true,
        'revision': nextRevision,
        'values': next,
      });
      if (!await store.write(encoded)) return false;
      _values = next;
      imported = true;
      revision = nextRevision;
      return true;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

/// Timers retain their original IDs and UTC anchors. Only the desktop commits
/// runtime changes; a disconnected widget may interpolate the last deadline.
final class OverlayTimers {
  static const ticksPerMs = 10000;
  static const unixEpochTicks = 621355968000000000;
  static int ticks(DateTime now) =>
      unixEpochTicks + now.toUtc().microsecondsSinceEpoch * 10;

  static List<List<String>> read(Map<String, Object> settings) {
    final manifest = settings['timer.records.v2'];
    if (manifest == null) return [];
    if (manifest is! String) {
      throw const FormatException('Invalid timer manifest');
    }
    var raw = manifest;
    if (raw.startsWith('@')) {
      final match = RegExp(r'^@([01]):(\d{1,3})$').firstMatch(raw);
      if (match == null) throw const FormatException('Invalid timer manifest');
      final count = int.parse(match[2]!);
      if (count > 64) throw const FormatException('Too many timer chunks');
      raw = List.generate(count, (i) {
        final chunk = settings['timer.records.chunk.${match[1]}.$i'];
        if (chunk is! String || chunk.length > 3000) {
          throw const FormatException('Incomplete timer document');
        }
        return chunk;
      }).join();
    }
    final rows = <List<String>>[];
    final ids = <String>{};
    for (final line in raw.split('\n').where((line) => line.isNotEmpty)) {
      final row = line.split('|');
      if (row.length != 12 ||
          !RegExp(r'^[0-9A-Fa-f]{32}$').hasMatch(row[0]) ||
          !ids.add(row[0]) ||
          !const {'Countdown', 'Stopwatch'}.contains(row[2]) ||
          !const {'Duration', 'Until'}.contains(row[3]) ||
          ![8, 9, 10].every((i) => row[i] == '0' || row[i] == '1')) {
        throw const FormatException('Invalid timer');
      }
      for (final i in [4, 5]) {
        final n = double.tryParse(row[i]);
        if (n == null || !n.isFinite || n < 0 || n > 86400000000) {
          throw const FormatException('Invalid timer duration');
        }
      }
      for (final i in [6, 7]) {
        final n = int.tryParse(row[i]);
        if (n == null || n < 0 || n > 3155378975999999999) {
          throw const FormatException('Invalid timer deadline');
        }
      }
      if (rows.length >= 64) throw const FormatException('Too many timers');
      rows.add(row);
    }
    return rows;
  }

  static double remaining(List<String> row, int now) {
    if (row[8] != '1') return double.parse(row[5]);
    if (row[2] == 'Stopwatch') {
      return (double.parse(row[5]) + (now - int.parse(row[7])) / ticksPerMs)
          .clamp(0, 86400000000);
    }
    return ((int.parse(row[row[3] == 'Until' ? 6 : 7]) - now) / ticksPerMs)
        .clamp(0, 86400000000);
  }

  static Map<String, Object>? update(
    Map<String, Object> settings,
    DateTime now, {
    String? action,
    String? id,
    bool? visible,
  }) {
    final rows = read(settings);
    final stamp = ticks(now);
    var changed = false;
    for (final row in rows) {
      if (action != null && row[0] == id) {
        changed = true;
        switch (action) {
          case 'toggle':
            if (row[8] == '1') {
              row[5] = remaining(row, stamp).toString();
              row[8] = '0';
            } else {
              var ms = double.parse(row[5]);
              if (row[2] == 'Countdown' && row[3] == 'Duration' && ms <= 0) {
                ms = double.parse(row[4]);
                row[5] = ms.toString();
              }
              row[7] =
                  (row[2] == 'Stopwatch'
                          ? stamp
                          : stamp + (ms * ticksPerMs).round())
                      .toString();
              row[8] = '1';
              row[9] = '0';
            }
          case 'reset':
            row[8] = '0';
            row[9] = '0';
            if (row[2] == 'Stopwatch') {
              row[5] = '0';
            } else if (row[3] == 'Until') {
              row[5] = ((int.parse(row[6]) - stamp) / ticksPerMs)
                  .clamp(0, 86400000000)
                  .toString();
            } else {
              row[5] = double.parse(row[4]).toString();
            }
          case 'visibility':
            row[10] = (visible ?? row[10] != '1') ? '1' : '0';
          default:
            throw const FormatException('Invalid timer action');
        }
      }
      if (row[8] == '1' &&
          row[2] == 'Countdown' &&
          remaining(row, stamp) <= 0) {
        row[8] = '0';
        row[9] = '1';
        row[5] = '0';
        changed = true;
      }
    }
    if (!changed) return null;
    final next = Map<String, Object>.from(settings);
    next.removeWhere((key, _) => key.startsWith('timer.records.chunk.'));
    final encoded = rows.map((row) => row.join('|')).join('\n');
    final count = (encoded.length + 2999) ~/ 3000;
    for (var i = 0; i < count; i++) {
      next['timer.records.chunk.0.$i'] = encoded.substring(
        i * 3000,
        ((i + 1) * 3000).clamp(0, encoded.length),
      );
    }
    next['timer.records.v2'] = '@0:$count';
    return next;
  }
}
