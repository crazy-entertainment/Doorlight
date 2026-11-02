import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'app_state.dart';
import 'overlay_settings.dart';

/// The package is a view/controller. Desktop state owns admission, durable
/// settings, timers, conversation ownership and microphone policy.
final class OverlayBridge {
  OverlayBridge(
    this.state, {
    OverlayDocumentStore? store,
    MethodChannel? channel,
    this.canEdit,
    this.onUserActivity,
    String? epoch,
    DateTime Function()? now,
  }) : settings = store == null
           ? state.overlaySettings
           : OverlaySettings(store),
       _channel = channel ?? const MethodChannel('syb.l/overlay_bridge'),
       epoch =
           epoch ??
           List.generate(
             16,
             (_) =>
                 Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
           ).join(),
       _now = now ?? DateTime.now;

  final AppState state;
  final OverlaySettings settings;
  final MethodChannel _channel;
  final bool Function()? canEdit;
  final void Function()? onUserActivity;
  final String epoch;
  final DateTime Function() _now;
  bool _disposed = false;
  bool _pending = false;
  bool _syncingUpdateBusy = false;
  bool _connected = false;
  bool _widgetReportedBusy = true;
  DateTime? _widgetPresenceUntil;
  int _connectionLease = 0;
  int _revision = 0;
  int _publishGeneration = 0;
  int _inputSequence = 0;
  Map<String, Object?> _input = {};
  Map<String, Object?> _compose = {};
  Map<String, Object?> _submission = {};
  String _inputOwner = '';
  String _surfaceOwner = '';
  DateTime? _surfaceUntil;
  String? _lastPublished;
  String? _lastConfig;
  Timer? _clock;
  Timer? _retry;
  Future<void> _publishing = Future.value();
  Map<String, Object?>? _privateProjection;
  DateTime? _privateProjectionUntil;
  final _completed =
      <String, ({String command, String args, Map<String, Object?> result})>{};
  bool get writable =>
      !_disposed &&
      settings.available &&
      !settings.busy &&
      state.appearanceBridgeWritable &&
      (canEdit?.call() ?? true);

  void start() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'request' && call.arguments is String) {
        return handle(call.arguments as String);
      }
      if (call.method == 'input' && call.arguments is Map) {
        await _onInput(Map<String, dynamic>.from(call.arguments as Map));
        return null;
      }
      throw MissingPluginException();
    });
    state.addListener(_onStateChanged);
    settings.addListener(refresh);
    _clock = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(tick()),
    );
    refresh();
  }

  void dispose() {
    _disposed = true;
    _clock?.cancel();
    _retry?.cancel();
    state.removeListener(_onStateChanged);
    state.setWidgetUpdateBusy(false);
    settings.removeListener(refresh);
    _channel.setMethodCallHandler(null);
    unawaited(_channel.invokeMethod<void>('cancel').catchError((Object _) {}));
    _completed.clear();
    _privateProjection = null;
  }

  void _onStateChanged() {
    if (_syncingUpdateBusy) return;
    _privateProjection = null;
    refresh();
  }

  Map<String, Object?> _privateSnapshot(bool safe) {
    if (!safe) {
      _privateProjection = null;
      return {};
    }
    final now = _now();
    if (_privateProjection == null ||
        _privateProjectionUntil == null ||
        !now.isBefore(_privateProjectionUntil!)) {
      _privateProjection = state.widgetOverlaySnapshot;
      _privateProjectionUntil = now.add(const Duration(milliseconds: 250));
    }
    return _privateProjection!;
  }

  Map<String, Object?> get snapshot {
    final safe = state.appearanceBridgeWritable && (canEdit?.call() ?? true);
    final privateState = _privateSnapshot(safe);
    final chat = Map<String, Object?>.from(
      privateState['chat'] as Map? ?? {'status': 'locked'},
    );
    final prefs = settings.values;
    final owner = chat['token'] as String? ?? '';
    if (!safe || owner != _inputOwner) {
      _inputOwner = owner;
      _compose = {};
      _submission = {};
      _input = {};
      _surfaceOwner = '';
      _surfaceUntil = null;
    }
    // Admission replies are prompt; the app publishes the journal's durable
    // outcome later. Keep the captured text/owner scoped to this quick-chat send.
    if (chat['submission'] case final Map outcome
        when safe &&
            _submission.isNotEmpty &&
            _submission['owner'] == owner &&
            outcome['operationId'] == _submission['operationId'] &&
            const {
              'pending',
              'committed',
              'failedBeforeCommit',
              'unknown',
            }.contains(outcome['status'])) {
      _submission = {..._submission, 'status': outcome['status']};
    }
    if (chat['messages'] case final List messages) {
      chat['messages'] = messages.map((row) {
        final copy = Map<String, Object?>.from(row as Map);
        if (prefs['chat.names'] == false) copy['author'] = '';
        if (prefs['chat.text'] == false) copy['text'] = '';
        if (prefs['chat.avatars'] == false) copy.remove('avatar');
        return copy;
      }).toList();
    }
    if (chat['conversations'] case final List choices
        when prefs['chat.names'] == false) {
      chat['conversations'] = choices
          .map(
            (row) => {
              ...Map<String, Object?>.from(row as Map),
              'label': 'Conversation',
            },
          )
          .toList();
    }
    final voice = Map<String, Object?>.from(
      privateState['voice'] as Map? ??
          {'kind': 'none', 'participants': <Object>[]},
    );
    if (voice['participants'] case final List participants) {
      voice['participants'] = participants
          .map(
            (row) => {
              ...Map<String, Object?>.from(row as Map),
              if (prefs['chat.names'] == false) 'name': '',
            },
          )
          .toList();
    }
    if (voice['offers'] case final List offers) {
      voice['offers'] = offers
          .map(
            (row) => {
              ...Map<String, Object?>.from(row as Map),
              if (prefs['chat.names'] == false) 'label': 'Voice chat',
            },
          )
          .toList();
    }
    final result = <String, Object?>{
      'v': 1,
      'type': 'snapshot',
      'epoch': epoch,
      'revision': _revision,
      'settingsRevision': settings.revision,
      'imported': settings.imported,
      'writable': writable && !_pending,
      'settings': prefs,
      'chat': chat,
      'voice': voice,
      'input': {
        'sequence': _inputSequence,
        'event': safe ? _input : <String, Object?>{},
        'compose': safe ? _compose : <String, Object?>{},
        'submission': safe ? _submission : <String, Object?>{},
      },
    };
    // Escape expansion and long participant rosters also count toward the wire
    // limit. Trimming a view must never alter the underlying timeline/settings.
    while (utf8.encode(jsonEncode(result)).length > 240 * 1024) {
      final messages = chat['messages'];
      if (messages is List && messages.isNotEmpty) {
        messages.removeAt(0);
        chat['hasOlder'] = true;
        continue;
      }
      final voice = result['voice'];
      if (voice is Map &&
          voice['participants'] is List &&
          (voice['participants'] as List).isNotEmpty) {
        (voice['participants'] as List).removeLast();
        continue;
      }
      // The validated settings document is bounded below the frame budget.
      // Unexpected private-state expansion fails closed.
      result['chat'] = {'status': 'unavailable'};
      result['voice'] = {'kind': 'none', 'participants': <Object>[]};
      result['input'] = <String, Object?>{};
      break;
    }
    return result;
  }

  void refresh() {
    if (_disposed || !state.appearanceBridgeReady) return;
    final current = snapshot;
    _syncUpdateBusy();
    final withoutRevision = {...current, 'revision': 0};
    final encoded = jsonEncode(withoutRevision);
    if (_lastPublished == encoded) return;
    _lastPublished = encoded;
    ++_revision;
    final generation = ++_publishGeneration;
    final publish = jsonEncode({...current, 'revision': _revision});
    unawaited(_configure());
    _publishing = _publishing.then((_) async {
      if (_disposed || generation != _publishGeneration) return;
      try {
        final accepted = await _channel.invokeMethod<bool>('publish', publish);
        if (accepted != true) _scheduleRetry();
      } on MissingPluginException {
        _lastPublished = null;
      } on PlatformException {
        _scheduleRetry();
      }
    });
  }

  void _syncUpdateBusy() {
    _syncingUpdateBusy = true;
    try {
      state.setWidgetUpdateBusy(
        !_disposed &&
            (_pending ||
                (_connected &&
                    (_widgetReportedBusy ||
                        _widgetPresenceUntil == null ||
                        !_now().isBefore(_widgetPresenceUntil!))) ||
                _compose['active'] == true ||
                (_compose['text'] is String &&
                    (_compose['text'] as String).isNotEmpty &&
                    _submission['status'] != 'committed') ||
                const {'pending', 'unknown'}.contains(_submission['status'])),
      );
    } finally {
      _syncingUpdateBusy = false;
    }
  }

  void _scheduleRetry() {
    if (_disposed || _retry != null) return;
    _retry = Timer(const Duration(seconds: 2), () {
      _retry = null;
      _lastPublished = null;
      refresh();
    });
  }

  Future<void> _configure() async {
    final values = settings.values;
    final chat = snapshot['chat'] as Map;
    final config = <String, Object>{
      'enabled':
          !_disposed &&
          settings.available &&
          state.appearanceBridgeWritable &&
          (canEdit?.call() ?? true) &&
          _connected,
      'owner': chat['token'] as String? ?? '',
      'lease': _connectionLease,
      'quickChatAllowed':
          !_disposed &&
          settings.available &&
          state.appearanceBridgeWritable &&
          (canEdit?.call() ?? true) &&
          _connected &&
          chat['canSend'] == true &&
          !_canonicalSendBlocked(chat) &&
          !const {'pending', 'unknown'}.contains(_submission['status']) &&
          chat['status'] == 'ready' &&
          chat['token'] is String &&
          (chat['token'] as String).isNotEmpty &&
          _surfaceOwner == chat['token'] &&
          _surfaceUntil != null &&
          _now().isBefore(_surfaceUntil!) &&
          values['chat.writable'] != false,
      'hotkeys': {
        'chat.quick': 'Ctrl+Alt+C',
        for (final row in values.entries)
          if (row.key.startsWith('hotkey.') && row.value is String)
            row.key.substring(7): row.value,
      },
      'crossHold': values['cross.hold'] as String? ?? 'off',
      'aimToggle': values['cross.aimToggle'] == true,
    };
    final encoded = jsonEncode(config);
    if (encoded == _lastConfig) return;
    _lastConfig = encoded;
    try {
      await _channel.invokeMethod<void>('configure', config);
    } on Object {
      _lastConfig = null;
    }
  }

  bool _canonicalSendBlocked(Map chat) {
    final submission = chat['submission'];
    return submission is Map &&
        const {'pending', 'unknown'}.contains(submission['status']);
  }

  Future<void> tick() async {
    if (!_disposed) await _configure();
    if (!_disposed) _syncUpdateBusy();
    if (_disposed ||
        !state.appearanceBridgeReady ||
        !state.settingsControlsEnabled ||
        state.resettingDoorlight ||
        state.resetDoorlightPending ||
        state.resetDoorlightRestartRequired ||
        settings.busy ||
        !settings.imported ||
        !settings.available) {
      return;
    }
    final candidate = OverlayTimers.update(settings.values, _now());
    if (candidate != null) {
      try {
        await settings.replace(candidate, expectedRevision: settings.revision);
      } on Object {
        /* Keep the last committed deadline on a failed save. */
      }
      refresh();
    }
  }

  Future<void> _onInput(Map<String, dynamic> event) async {
    if (_disposed) return;
    if (event['type'] == 'connection') {
      if (event['lease'] is! int ||
          (event['lease'] as int) < _connectionLease) {
        return;
      }
      // Native can coalesce an intervening disconnect before Dart observes it.
      final replaced = _connected && event['lease'] > _connectionLease;
      _connectionLease = event['lease'];
      _connected = event['connected'] == true;
      if (!_connected || replaced || _widgetPresenceUntil == null) {
        _widgetReportedBusy = true;
        _widgetPresenceUntil = null;
      }
      _lastConfig = null;
      if (!_connected || replaced) {
        _input = {};
        _compose = {};
        _submission = {};
        _inputOwner = '';
        _surfaceOwner = '';
        _surfaceUntil = null;
        state.retireWidgetOverlaySession();
        _syncUpdateBusy();
      }
      await _configure();
      _syncUpdateBusy();
      return;
    }
    if (event['lease'] != _connectionLease) return;
    if (!state.appearanceBridgeWritable ||
        !(canEdit?.call() ?? true) ||
        !_connected) {
      return;
    }
    final type = event['type'];
    final chatOwner = snapshot['chat'] as Map;
    if (const {'compose', 'submit'}.contains(type) &&
        (chatOwner['canSend'] != true || _canonicalSendBlocked(chatOwner))) {
      return;
    }
    if (const {'compose', 'submit', 'cancel'}.contains(type) &&
        event['owner'] != chatOwner['token']) {
      return;
    }
    if (const {'compose', 'submit'}.contains(type) &&
        const {'pending', 'unknown'}.contains(_submission['status'])) {
      return;
    }
    if (const {'compose', 'submit'}.contains(type) &&
        (_surfaceOwner != event['owner'] ||
            _surfaceUntil == null ||
            !_now().isBefore(_surfaceUntil!))) {
      return;
    }
    if (type == 'compose') {
      if (event['text'] is! String) return;
      _compose = {
        'owner': event['owner'],
        'text': event['text'],
        'active': true,
      };
    } else if (type == 'cancel') {
      _compose = {'owner': event['owner'], 'text': '', 'active': false};
    }
    if (const {'compose', 'cancel'}.contains(type) ||
        type == 'submit' && event['text'] is String) {
      onUserActivity?.call();
      _syncUpdateBusy();
    }
    if (type == 'hotkey') {
      final action = event['action'];
      if (action is String && action.startsWith('timer.')) {
        final parts = action.split('.');
        if (parts.length == 3) {
          await _timer(parts[2] == 'toggle' ? 'toggle' : parts[2], {
            'id': parts[1],
          });
          onUserActivity?.call();
        } else if (parts.length == 2 &&
            settings.values['timer.activeId'] is String) {
          await _timer(parts[1], {'id': settings.values['timer.activeId']});
          onUserActivity?.call();
        }
      } else if (action == 'cross.toggle') {
        final next = Map<String, Object>.from(settings.values);
        final active = next['crossPresets.active'];
        if (active is! String || active.isEmpty) return;
        final key = 'crossPresets.$active.visible';
        next[key] = next[key] == false;
        await settings.replace(next, expectedRevision: settings.revision);
        onUserActivity?.call();
      }
    } else if (type == 'capture' &&
        event['action'] is String &&
        event['text'] is String) {
      if (!settings.imported || !writable) return;
      final next = Map<String, Object>.from(settings.values);
      next['hotkey.${event['action']}'] = event['text'] as String;
      await settings.replace(next, expectedRevision: settings.revision);
      onUserActivity?.call();
    } else if (type == 'submit' && event['text'] is String) {
      final chat = snapshot['chat'] as Map;
      final operation = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      var status = 'failedBeforeCommit';
      _compose = {
        'owner': event['owner'],
        'text': event['text'],
        'active': false,
      };
      _submission = {
        'owner': event['owner'],
        'text': event['text'],
        'operationId': operation,
        'status': 'pending',
      };
      ++_inputSequence;
      refresh();
      if (chat['canSend'] == true) {
        try {
          final receipt = await state.handleWidgetOverlayCommand('chat.send', {
            'token': chat['token'],
            'conversation': chat['selected'],
            'text': event['text'],
            'operationId': operation,
          });
          status = receipt['status'] as String? ?? 'unknown';
        } on StateError catch (error) {
          status = error.message == 'unknown'
              ? 'unknown'
              : 'failedBeforeCommit';
        } on Object {
          status = 'unknown';
        }
      }
      if ((snapshot['chat'] as Map)['token'] != event['owner']) return;
      _input = {
        'type': 'sendResult',
        'owner': event['owner'],
        'text': event['text'],
        'status': status,
        'operationId': operation,
      };
      _submission = {
        'owner': event['owner'],
        'text': event['text'],
        'operationId': operation,
        'status': status,
      };
      ++_inputSequence;
      refresh();
      return;
    }
    _input = Map<String, Object?>.from(event);
    ++_inputSequence;
    refresh();
  }

  Future<Map<String, Object?>> _timer(
    String action,
    Map<String, dynamic> args,
  ) async {
    if (!const {'toggle', 'reset', 'visibility'}.contains(action) ||
        args['id'] is! String ||
        args['visible'] != null && args['visible'] is! bool) {
      throw StateError('invalid');
    }
    final next = OverlayTimers.update(
      settings.values,
      _now(),
      action: action,
      id: args['id'] as String,
      visible: args['visible'] as bool?,
    );
    if (next == null) throw StateError('stale');
    if (!await settings.replace(next, expectedRevision: settings.revision)) {
      throw StateError('save_failed');
    }
    return {};
  }

  Future<String> handle(String frame) async {
    String? id;
    String response({String? error, Map<String, Object?>? result}) =>
        jsonEncode({
          'v': 1,
          'type': 'result',
          'id': id,
          'ok': error == null,
          'error': ?error,
          'result': ?result,
          'snapshot': snapshot,
        });
    try {
      if (utf8.encode(frame).length > 256 * 1024) {
        return response(error: 'invalid');
      }
      final request = jsonDecode(frame);
      if (request is! Map<String, dynamic> ||
          request.length != 6 ||
          !request.keys.toSet().containsAll({
            'v',
            'type',
            'id',
            'epoch',
            'command',
            'args',
          }) ||
          request['v'] != 1 ||
          request['type'] != 'command' ||
          request['id'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(request['id']) ||
          request['command'] is! String ||
          request['args'] is! Map<String, dynamic>) {
        return response(error: 'invalid');
      }
      id = request['id'];
      if (request['epoch'] != epoch) return response(error: 'stale');
      if (_disposed || _pending || !writable) return response(error: 'busy');
      final command = request['command'] as String;
      final args = request['args'] as Map<String, dynamic>;
      final fingerprint = jsonEncode(args);
      final prior = _completed[id];
      if (prior != null) {
        return prior.command == command && prior.args == fingerprint
            ? response(result: prior.result)
            : response(error: 'invalid');
      }
      _pending = true;
      _syncUpdateBusy();
      Map<String, Object?> result;
      try {
        if (command == 'update.capabilities') {
          if (args.isNotEmpty) throw StateError('invalid');
          result = {
            'protocol': 1,
            'desktopIdleGuard': true,
            'presenceLeaseSeconds': 3,
          };
        } else if (command == 'update.presence') {
          if (!_connected ||
              args.length != 2 ||
              args['busy'] is! bool ||
              args['activity'] is! bool) {
            throw StateError('invalid');
          }
          _widgetReportedBusy = args['busy'] as bool;
          _widgetPresenceUntil = _now().add(const Duration(seconds: 3));
          if (args['activity'] == true) onUserActivity?.call();
          result = {};
        } else if (command == 'chat.surface') {
          final chat = snapshot['chat'] as Map;
          if (args.length != 2 ||
              args['visible'] is! bool ||
              args['token'] is! String ||
              args['token'] != chat['token']) {
            throw StateError('stale');
          }
          _surfaceOwner = args['token'];
          _surfaceUntil = args['visible'] == true
              ? _now().add(const Duration(seconds: 2))
              : null;
          await _configure();
          result = {};
        } else if (command == 'settings.import' ||
            command == 'settings.replace') {
          if (args.length != 2 ||
              args['revision'] is! int ||
              args['values'] is! Map ||
              args['revision'] != settings.revision) {
            throw StateError('stale');
          }
          if (command == 'settings.import' && settings.imported) {
            throw StateError('stale');
          }
          if (!await settings.replace(
            args['values'],
            expectedRevision: args['revision'],
            importing: command == 'settings.import',
          )) {
            throw StateError('save_failed');
          }
          result = {};
        } else if (command.startsWith('timer.')) {
          result = await _timer(command.substring(6), args);
        } else if (command == 'input.capture') {
          if (!settings.imported) throw StateError('unavailable');
          if (args.length != 1 ||
              args['action'] is! String ||
              (args['action'] as String).length > 100) {
            throw StateError('invalid');
          }
          if (await _channel.invokeMethod<bool>('capture', args['action']) !=
              true) {
            throw StateError('unavailable');
          }
          result = {};
        } else if (command == 'input.cancel') {
          await _channel.invokeMethod<void>('cancel');
          result = {};
        } else if (command.startsWith('chat.') ||
            command.startsWith('voice.')) {
          result = await state.handleWidgetOverlayCommand(command, args);
        } else {
          throw StateError('invalid');
        }
        result = Map<String, Object?>.from(result)..remove('snapshot');
        if (command != 'chat.surface' &&
            command != 'settings.import' &&
            command != 'update.presence' &&
            command != 'update.capabilities') {
          onUserActivity?.call();
        }
        _completed[id!] = (command: command, args: fingerprint, result: result);
        if (_completed.length > 128) _completed.remove(_completed.keys.first);
      } finally {
        _pending = false;
        refresh();
      }
      return response(result: result);
    } on StateError catch (error) {
      final code = error.message;
      return response(
        error:
            const {
              'invalid',
              'stale',
              'busy',
              'save_failed',
              'consent',
              'locked',
              'disconnected',
              'unavailable',
              'unknown',
            }.contains(code)
            ? code
            : 'unavailable',
      );
    } on Object {
      return response(error: 'invalid');
    }
  }
}
