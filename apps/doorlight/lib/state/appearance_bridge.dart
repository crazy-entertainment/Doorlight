import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'app_state.dart';

/// The widget is a client of canonical app settings, never another settings store.
final class AppearanceBridge {
  AppearanceBridge(
    this.state, {
    MethodChannel? channel,
    String? epoch,
    this.canEdit,
  }) : _channel = channel ?? const MethodChannel('syb.l/appearance_bridge'),
       epoch = epoch ?? _newEpoch();

  final AppState state;
  final MethodChannel _channel;
  final bool Function()? canEdit;
  final String epoch;
  static const maxFrameBytes = 4096;
  static const _fields = {
    'theme',
    'vibe',
    'vibeOpacity',
    'vibeIntensity',
    'vibeAnimated',
  };
  Map<String, Object>? _appearance;
  Object? _owner;
  int _revision = 0;
  bool _pending = false;
  bool _disposed = false;
  String? _lastPublished;
  int _publishGeneration = 0;
  Timer? _retry;
  Future<void> _publishing = Future<void>.value();
  bool get _writable =>
      state.appearanceBridgeWritable && (canEdit?.call() ?? true);
  void refresh() => _changed();

  static String _newEpoch() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void start() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'request' || call.arguments is! String) {
        throw MissingPluginException();
      }
      return handle(call.arguments as String);
    });
    state.addListener(_changed);
    _changed();
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    state.removeListener(_changed);
    _channel.setMethodCallHandler(null);
  }

  Map<String, Object> _readAppearance() => {
    'theme': state.appearancePreset == AppearancePreset.disaccord
        ? 'disaccord'
        : state.appearancePreset.storageValue,
    'vibe': state.appSettings.ambientVibe.name,
    'vibeOpacity': state.appSettings.vibeOpacity,
    'vibeIntensity': state.appSettings.vibeIntensity,
    'vibeAnimated': state.chatMotionEnabled,
  };

  void _refresh() {
    // AppState exposes optimistic values during a save. Only publish its settled
    // document; a failed write must never become a widget's authoritative state.
    if (!state.appearanceBridgeReady || state.settingsBusy) return;
    final next = _readAppearance();
    final owner = state.appearanceBridgeOwner;
    if (_appearance != null &&
        (jsonEncode(_appearance) != jsonEncode(next) || _owner != owner)) {
      _revision++;
    }
    _appearance = next;
    _owner = owner;
  }

  Map<String, Object> get snapshot {
    _refresh();
    return {
      'v': 1,
      'type': 'snapshot',
      'epoch': epoch,
      'revision': _revision,
      'writable': !_disposed && !_pending && _writable,
      'appearance': _appearance ?? _readAppearance(),
    };
  }

  void _changed() {
    if (_disposed ||
        (_appearance == null &&
            (!state.appearanceBridgeReady || state.settingsBusy))) {
      return;
    }
    final encoded = jsonEncode(snapshot);
    if (_lastPublished == encoded) return;
    _lastPublished = encoded;
    final generation = ++_publishGeneration;
    _retry?.cancel();
    _retry = null;
    _publishing = _publishing.then((_) async {
      if (_disposed || _publishGeneration != generation) return;
      var accepted = false;
      try {
        accepted =
            await _channel.invokeMethod<bool>('publish', encoded) == true;
      } on MissingPluginException {
        if (_publishGeneration == generation) _lastPublished = null;
        return;
      } on PlatformException {
        // A failed transport never turns an optimistic frontend value into state.
      }
      if (!accepted && !_disposed && _publishGeneration == generation) {
        _lastPublished = null;
        _retry = Timer(const Duration(seconds: 2), () {
          _retry = null;
          _changed();
        });
      }
    });
  }

  Future<String> handle(String frame) async {
    Object? id;
    String result({String? error}) => jsonEncode({
      'v': 1,
      'type': 'result',
      'id': id,
      'ok': error == null,
      'error': ?error,
      'snapshot': snapshot,
    });
    try {
      if (utf8.encode(frame).length > maxFrameBytes) {
        return result(error: 'invalid');
      }
      final request = jsonDecode(frame);
      if (request is! Map<String, dynamic> ||
          request.length != 6 ||
          !request.keys.toSet().containsAll({
            'v',
            'type',
            'id',
            'epoch',
            'revision',
            'patch',
          }) ||
          request['v'] is! int ||
          request['v'] != 1 ||
          request['type'] != 'patch' ||
          request['id'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(request['id'] as String)) {
        return result(error: 'invalid');
      }
      id = request['id'];
      final patch = request['patch'];
      if (patch is! Map<String, dynamic> ||
          patch.isEmpty ||
          patch.keys.any((key) => !_fields.contains(key)) ||
          (patch.containsKey('theme') &&
              !['disaccord', 'cozy', 'midnight'].contains(patch['theme'])) ||
          (patch.containsKey('vibe') &&
              !['none', 'rain', 'snow', 'halloween'].contains(patch['vibe'])) ||
          (patch.containsKey('vibeAnimated') &&
              patch['vibeAnimated'] is! bool) ||
          ['vibeOpacity', 'vibeIntensity'].any(
            (key) =>
                patch.containsKey(key) &&
                (patch[key] is! int ||
                    (patch[key] as int) < 0 ||
                    (patch[key] as int) > 100),
          ) ||
          request['epoch'] is! String ||
          request['revision'] is! int ||
          (request['revision'] as int) < 0 ||
          (request['revision'] as int) > 9007199254740991) {
        return result(error: 'invalid');
      }
      _refresh();
      if (request['epoch'] != epoch || request['revision'] != _revision) {
        return result(error: 'stale');
      }
      if (_disposed || _pending || !_writable) {
        return result(error: 'busy');
      }
      if (patch.entries.every(
        (entry) => _appearance?[entry.key] == entry.value,
      )) {
        return result();
      }
      _pending = true;
      _changed();
      bool saved;
      try {
        saved = await state.setWidgetAppearance(
          theme: switch (patch['theme']) {
            'disaccord' => AppearancePreset.disaccord,
            'cozy' => AppearancePreset.cozy,
            'midnight' => AppearancePreset.midnight,
            _ => null,
          },
          vibe: patch.containsKey('vibe')
              ? AmbientVibe.values.byName(patch['vibe'] as String)
              : null,
          opacity: patch['vibeOpacity'] as int?,
          intensity: patch['vibeIntensity'] as int?,
          animations: patch['vibeAnimated'] as bool?,
        );
      } finally {
        _pending = false;
        _changed();
      }
      return result(error: saved ? null : 'save_failed');
    } on Object {
      return result(error: 'invalid');
    }
  }
}
