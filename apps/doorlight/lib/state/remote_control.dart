import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/jami.dart';

const remoteControlMimeType = 'application/x-sybl-control';

enum RemoteControlCapability {
  mouse('mouse', 1),
  keyboard('keyboard', 2),
  text('text', 4),
  clipboard('clipboard', 8),
  back('back', 16),
  home('home', 32),
  recents('recents', 64);

  const RemoteControlCapability(this.wireName, this.bit);
  final String wireName;
  final int bit;

  static RemoteControlCapability? fromWire(Object? value) {
    for (final capability in values) {
      if (capability.wireName == value) return capability;
    }
    return null;
  }
}

enum RemoteGlobalAction {
  back('back', RemoteControlCapability.back),
  home('home', RemoteControlCapability.home),
  recents('recents', RemoteControlCapability.recents);

  const RemoteGlobalAction(this.wireName, this.capability);
  final String wireName;
  final RemoteControlCapability capability;

  static RemoteGlobalAction? fromWire(Object? value) {
    for (final action in values) {
      if (action.wireName == value) return action;
    }
    return null;
  }
}

enum RemoteControlPhase { idle, requesting, controlling, denied, ended }

enum RemoteControlHostPhase {
  idle,
  prompting,
  active,
  suspended,
  hostPriority,
  revoking,
}

String _controlDenialNotice(Object? reason) => switch (reason) {
  'timeout' => 'Control request timed out.',
  'busy' => 'They are already helping someone.',
  'unsupported' => 'Remote control is not ready on their device.',
  _ => 'They said no.',
};

enum RemoteMouseButton {
  left('left'),
  right('right'),
  middle('middle'),
  x1('x1'),
  x2('x2');

  const RemoteMouseButton(this.wireName);
  final String wireName;

  static RemoteMouseButton? fromWire(Object? value) {
    for (final button in values) {
      if (button.wireName == value) return button;
    }
    return null;
  }
}

@immutable
class RemoteControlBinding {
  const RemoteControlBinding({
    required this.callId,
    required this.peerId,
    required this.sourceRevision,
    this.peerDeviceId = '',
  });

  final String callId;
  final String peerId;
  final int sourceRevision;
  final String peerDeviceId;

  RemoteControlBinding copyWith({String? peerDeviceId}) => RemoteControlBinding(
    callId: callId,
    peerId: peerId,
    sourceRevision: sourceRevision,
    peerDeviceId: peerDeviceId ?? this.peerDeviceId,
  );

  bool sameSource(RemoteControlBinding other) =>
      callId == other.callId &&
      peerId == other.peerId &&
      sourceRevision == other.sourceRevision;

  bool matchesEnvelope({
    required String callId,
    required String peerId,
    required int sourceRevision,
    String peerDeviceId = '',
  }) =>
      this.callId == callId &&
      this.peerId == peerId &&
      this.sourceRevision == sourceRevision &&
      (this.peerDeviceId.isEmpty ||
          peerDeviceId.isEmpty ||
          this.peerDeviceId == peerDeviceId);

  @override
  bool operator ==(Object other) =>
      other is RemoteControlBinding &&
      callId == other.callId &&
      peerId == other.peerId &&
      sourceRevision == other.sourceRevision &&
      peerDeviceId == other.peerDeviceId;

  @override
  int get hashCode => Object.hash(callId, peerId, sourceRevision, peerDeviceId);
}

/// Who an outgoing clipboard send belongs to, captured before the clipboard is
/// read. [lifetime] changes on every start, stop, revoke or replacement of the
/// role's session, so equal identifiers reached again do not compare equal.
@immutable
class RemoteClipboardOwner {
  const RemoteClipboardOwner._({
    required this.fromHost,
    required this.binding,
    required this.hostSession,
    required this.hostGeneration,
    required this.lifetime,
  });

  final bool fromHost;
  final RemoteControlBinding binding;
  final RemoteControlBinding? hostSession;
  final int hostGeneration;
  final int lifetime;
}

@immutable
class RemoteControlHostRequest {
  const RemoteControlHostRequest({
    required this.binding,
    required this.generation,
    required this.controllerAccountId,
    required this.controllerDeviceId,
    required this.capabilities,
    required this.persistentAvailable,
  });

  final RemoteControlBinding binding;

  /// Receiver-generated native identity of the exact consent transaction.
  final int generation;
  final String controllerAccountId;
  final String controllerDeviceId;
  final Set<RemoteControlCapability> capabilities;
  final bool persistentAvailable;
}

enum RemoteClipboardReceiver { controller, controllee }

@immutable
class RemoteClipboardRequest {
  const RemoteClipboardRequest({
    required this.binding,
    required this.generation,
    required this.id,
    required this.text,
    required this.receiver,
    this.declaredByteLength,
  });

  final RemoteControlBinding binding;

  /// Receiver-generated identity. [id] remains wire correlation only.
  final int generation;
  final String id;
  final String text;
  final RemoteClipboardReceiver receiver;
  final int? declaredByteLength;

  int get byteLength => declaredByteLength ?? utf8.encode(text).length;
  String get preview {
    const maxRunes = 160;
    final runes = text.runes.toList(growable: false);
    final result = StringBuffer();
    for (final rune in runes.take(maxRunes)) {
      if (_escapeInConsentPreview(rune)) {
        result.write(
          '\\u{${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}}',
        );
      } else {
        result.writeCharCode(rune);
      }
    }
    if (runes.length > maxRunes) result.write('…');
    return result.toString();
  }

  static bool _escapeInConsentPreview(int rune) =>
      rune <= 0x1f ||
      (rune >= 0x7f && rune <= 0x9f) ||
      rune == 0x00ad ||
      rune == 0x034f ||
      (rune >= 0x0600 && rune <= 0x0605) ||
      rune == 0x061c ||
      rune == 0x06dd ||
      rune == 0x070f ||
      (rune >= 0x0890 && rune <= 0x0891) ||
      rune == 0x08e2 ||
      (rune >= 0x115f && rune <= 0x1160) ||
      (rune >= 0x17b4 && rune <= 0x17b5) ||
      (rune >= 0x180b && rune <= 0x180e) ||
      (rune >= 0x200b && rune <= 0x200f) ||
      (rune >= 0x2028 && rune <= 0x202e) ||
      (rune >= 0x2060 && rune <= 0x206f) ||
      rune == 0x3164 ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      rune == 0xfeff ||
      rune == 0xffa0 ||
      (rune >= 0xfff9 && rune <= 0xfffb) ||
      rune == 0x110bd ||
      rune == 0x110cd ||
      (rune >= 0x13430 && rune <= 0x13455) ||
      (rune >= 0x1bca0 && rune <= 0x1bca3) ||
      (rune >= 0x1d173 && rune <= 0x1d17a) ||
      rune == 0xe0001 ||
      (rune >= 0xe0020 && rune <= 0xe007f) ||
      (rune >= 0xe0100 && rune <= 0xe01ef);
}

sealed class RemoteInputEvent {
  const RemoteInputEvent();
  List<Object> toWire();
}

@immutable
class RemoteMoveEvent extends RemoteInputEvent {
  const RemoteMoveEvent(this.x, this.y);
  final double x;
  final double y;

  @override
  List<Object> toWire() => <Object>['m', x, y];
}

@immutable
class RemoteButtonEvent extends RemoteInputEvent {
  const RemoteButtonEvent(this.button, {required this.down});
  final RemoteMouseButton button;
  final bool down;

  @override
  List<Object> toWire() => <Object>[down ? 'd' : 'u', button.wireName];
}

@immutable
class RemoteWheelEvent extends RemoteInputEvent {
  const RemoteWheelEvent(this.delta);
  final int delta;

  @override
  List<Object> toWire() => <Object>['w', delta];
}

@immutable
class RemoteKeyEvent extends RemoteInputEvent {
  const RemoteKeyEvent(this.virtualKey, {required this.down});
  final int virtualKey;
  final bool down;

  @override
  List<Object> toWire() => <Object>['k', virtualKey, down];
}

@immutable
class RemoteTextEvent extends RemoteInputEvent {
  const RemoteTextEvent(this.text);
  final String text;

  @override
  List<Object> toWire() => <Object>['t', text];
}

@immutable
class RemoteActionEvent extends RemoteInputEvent {
  const RemoteActionEvent(this.action);
  final RemoteGlobalAction action;

  @override
  List<Object> toWire() => <Object>['a', action.wireName];
}

enum RemoteControlWireDirection {
  controllerToControllee,
  controlleeToController,
}

enum RemoteControlWireType {
  request,
  grant,
  deny,
  revoke,
  input,
  clipboardOffer,
  clipboardData,
  clipboardAccept,
  clipboardReject,
  end,
}

@immutable
class RemoteControlWireMessage {
  const RemoteControlWireMessage(this.type, this.fields);
  final RemoteControlWireType type;
  final Map<String, Object> fields;
}

/// Strict Dart counterpart of `remote_control_protocol.cpp`.
///
/// Windows serializes/parses this protocol natively. Android's controller role
/// uses this implementation; host input authority remains native on both
/// platforms. Keep the golden vectors in
/// `remote_control_test.dart` synchronized with the C++ protocol test.
class RemoteControlProtocol {
  RemoteControlProtocol._();

  static const int version = 1;

  /// Must match `kMaxPacketBytes` (`remote_control_protocol.h`) and the in-call
  /// MESSAGE firewalls (`jami_bridge.cpp` `kMaxTypedCallMessageBytes`,
  /// `JamiCore.kt` `MAX_TYPED_CALL_MESSAGE_BYTES`): 6000 bytes.
  static const int maxPacketBytes = 6000;
  static const int maxJsonDepth = 20;
  static const int maxInputEvents = 64;
  static const int maxTextEventBytes = 256;
  static const int maxClipboardBytes = 4096;

  static final RegExp _lowerHex = RegExp(r'^[0-9a-f]+$');
  static const Set<String> _denyReasons = {
    'user',
    'timeout',
    'unsupported',
    'busy',
  };

  static String request({
    required Set<RemoteControlCapability> capabilities,
    required int sourceRevision,
    required String identityColor,
  }) {
    if (PresenceWireContract.decodeIdentityColor(identityColor).isEmpty) {
      throw ArgumentError.value(identityColor, 'identityColor');
    }
    return _encodeAndCheck(<String, Object>{
      'caps': _capabilityNames(capabilities),
      'color': identityColor,
      'sourceRevision': sourceRevision,
      't': 'req',
      'v': version,
    }, RemoteControlWireDirection.controllerToControllee);
  }

  static String input({
    required String token,
    required int epoch,
    required int sequence,
    required int sourceRevision,
    required List<RemoteInputEvent> events,
  }) => _encodeAndCheck(<String, Object>{
    'epoch': epoch,
    'ev': <Object>[for (final event in events) event.toWire()],
    'seq': sequence,
    'sourceRevision': sourceRevision,
    't': 'input',
    'token': token,
    'v': version,
  }, RemoteControlWireDirection.controllerToControllee);

  static String clipboardOffer({
    required String id,
    required String sha256Hex,
    required int size,
    required RemoteControlWireDirection direction,
  }) => _encodeAndCheck(<String, Object>{
    'id': id,
    'sha256': sha256Hex,
    'size': size,
    't': 'clip-offer',
    'v': version,
  }, direction);

  static String clipboardData({
    required String id,
    required String sha256Hex,
    required String text,
    required RemoteControlWireDirection direction,
  }) => _encodeAndCheck(<String, Object>{
    'id': id,
    'sha256': sha256Hex,
    't': 'clip-data',
    'text': text,
    'v': version,
  }, direction);

  static String clipboardResponse({
    required String id,
    required bool accepted,
    required RemoteControlWireDirection direction,
  }) => _encodeAndCheck(<String, Object>{
    'id': id,
    't': accepted ? 'clip-accept' : 'clip-reject',
    'v': version,
  }, direction);

  static String end(RemoteControlWireDirection direction) => _encodeAndCheck(
    const <String, Object>{'t': 'end', 'v': version},
    direction,
  );

  static RemoteControlWireMessage? parse(
    String packet,
    RemoteControlWireDirection direction,
  ) {
    if (!_validPacketBytes(packet)) return null;
    try {
      RemoteControlJsonValidator(packet).validate();
      final decoded = jsonDecode(packet);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] is! int || decoded['v'] != version) return null;
      final type = decoded['t'];
      if (type is! String || !_directionAllows(type, direction)) return null;

      switch (type) {
        case 'req':
          if (!_exact(decoded, const {
            'v',
            't',
            'caps',
            'color',
            'sourceRevision',
          })) {
            return null;
          }
          final capabilities = _parseCapabilities(decoded['caps']);
          final identityColor = PresenceWireContract.decodeIdentityColor(
            decoded['color'],
          );
          final revision = _positiveInt(decoded['sourceRevision']);
          if (capabilities == null ||
              identityColor.isEmpty ||
              revision == null) {
            return null;
          }
          return RemoteControlWireMessage(
            RemoteControlWireType.request,
            <String, Object>{
              'capabilities': capabilities,
              'identityColor': identityColor,
              'sourceRevision': revision,
            },
          );
        case 'grant':
          if (!_exact(decoded, const {
            'v',
            't',
            'token',
            'epoch',
            'sourceRevision',
            'caps',
          })) {
            return null;
          }
          final token = decoded['token'];
          final epoch = _positiveInt(decoded['epoch']);
          final revision = _positiveInt(decoded['sourceRevision']);
          final capabilities = _parseCapabilities(decoded['caps']);
          if (token is! String ||
              !_validToken(token) ||
              epoch == null ||
              revision == null ||
              capabilities == null) {
            return null;
          }
          return RemoteControlWireMessage(
            RemoteControlWireType.grant,
            <String, Object>{
              'token': token,
              'epoch': epoch,
              'sourceRevision': revision,
              'capabilities': capabilities,
            },
          );
        case 'deny':
          if (!_exact(decoded, const {'v', 't', 'reason'})) return null;
          final reason = decoded['reason'];
          if (reason is! String ||
              reason.length > 16 ||
              !_denyReasons.contains(reason)) {
            return null;
          }
          return RemoteControlWireMessage(
            RemoteControlWireType.deny,
            <String, Object>{'reason': reason},
          );
        case 'revoke':
          if (!_exact(decoded, const {'v', 't'})) return null;
          return const RemoteControlWireMessage(
            RemoteControlWireType.revoke,
            <String, Object>{},
          );
        case 'input':
          if (!_exact(decoded, const {
            'v',
            't',
            'token',
            'epoch',
            'seq',
            'sourceRevision',
            'ev',
          })) {
            return null;
          }
          final token = decoded['token'];
          final epoch = _positiveInt(decoded['epoch']);
          final sequence = _positiveInt(decoded['seq']);
          final revision = _positiveInt(decoded['sourceRevision']);
          final events = _parseEvents(decoded['ev']);
          if (token is! String ||
              !_validToken(token) ||
              epoch == null ||
              sequence == null ||
              revision == null ||
              events == null) {
            return null;
          }
          return RemoteControlWireMessage(
            RemoteControlWireType.input,
            <String, Object>{
              'token': token,
              'epoch': epoch,
              'sequence': sequence,
              'sourceRevision': revision,
              'events': events,
            },
          );
        case 'clip-offer':
          if (!_exact(decoded, const {'v', 't', 'id', 'sha256', 'size'})) {
            return null;
          }
          final id = decoded['id'];
          final hash = decoded['sha256'];
          final size = decoded['size'];
          if (id is! String ||
              hash is! String ||
              size is! int ||
              !_validClipboardId(id) ||
              !_validHash(hash) ||
              size <= 0 ||
              size > maxClipboardBytes) {
            return null;
          }
          return RemoteControlWireMessage(
            RemoteControlWireType.clipboardOffer,
            <String, Object>{'id': id, 'sha256': hash, 'size': size},
          );
        case 'clip-data':
          if (!_exact(decoded, const {'v', 't', 'id', 'sha256', 'text'})) {
            return null;
          }
          final id = decoded['id'];
          final hash = decoded['sha256'];
          final text = decoded['text'];
          if (id is! String ||
              hash is! String ||
              text is! String ||
              !_validClipboardId(id) ||
              !_validHash(hash) ||
              !_validText(text, maxClipboardBytes)) {
            return null;
          }
          return RemoteControlWireMessage(
            RemoteControlWireType.clipboardData,
            <String, Object>{'id': id, 'sha256': hash, 'text': text},
          );
        case 'clip-accept':
        case 'clip-reject':
          if (!_exact(decoded, const {'v', 't', 'id'})) return null;
          final id = decoded['id'];
          if (id is! String || !_validClipboardId(id)) return null;
          return RemoteControlWireMessage(
            type == 'clip-accept'
                ? RemoteControlWireType.clipboardAccept
                : RemoteControlWireType.clipboardReject,
            <String, Object>{'id': id},
          );
        case 'end':
          if (!_exact(decoded, const {'v', 't'})) return null;
          return const RemoteControlWireMessage(
            RemoteControlWireType.end,
            <String, Object>{},
          );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static String _encodeAndCheck(
    Map<String, Object> value,
    RemoteControlWireDirection direction,
  ) {
    final packet = jsonEncode(value);
    if (parse(packet, direction) == null) {
      throw ArgumentError('Invalid remote-control packet');
    }
    return packet;
  }

  static bool _validPacketBytes(String packet) {
    if (packet.isEmpty) return false;
    try {
      return utf8.encode(packet).length <= maxPacketBytes;
    } on FormatException {
      return false;
    }
  }

  static bool _directionAllows(
    String type,
    RemoteControlWireDirection direction,
  ) {
    if (const {
      'clip-offer',
      'clip-data',
      'clip-accept',
      'clip-reject',
      'end',
    }.contains(type)) {
      return true;
    }
    return direction == RemoteControlWireDirection.controllerToControllee
        ? type == 'req' || type == 'input'
        : type == 'grant' || type == 'deny' || type == 'revoke';
  }

  static bool _exact(Map<String, dynamic> value, Set<String> fields) =>
      value.length == fields.length && value.keys.toSet().containsAll(fields);

  static int? _positiveInt(Object? value) =>
      value is int && value > 0 ? value : null;

  static Set<RemoteControlCapability>? _parseCapabilities(Object? raw) {
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > RemoteControlCapability.values.length) {
      return null;
    }
    final result = <RemoteControlCapability>{};
    for (final value in raw) {
      final capability = RemoteControlCapability.fromWire(value);
      if (capability == null || !result.add(capability)) return null;
    }
    return Set.unmodifiable(result);
  }

  static List<String> _capabilityNames(
    Set<RemoteControlCapability> capabilities,
  ) {
    if (capabilities.isEmpty) {
      throw ArgumentError.value(capabilities, 'capabilities');
    }
    return <String>[
      for (final capability in RemoteControlCapability.values)
        if (capabilities.contains(capability)) capability.wireName,
    ];
  }

  static bool _validToken(String token) =>
      token.length >= 32 &&
      token.length <= 128 &&
      token.length.isEven &&
      _lowerHex.hasMatch(token);

  static bool _validClipboardId(String id) =>
      id.length >= 16 && id.length <= 64 && _lowerHex.hasMatch(id);

  static bool _validHash(String hash) =>
      hash.length == 64 && _lowerHex.hasMatch(hash);

  static bool _validText(String text, int maxBytes) {
    if (text.isEmpty) return false;
    late List<int> bytes;
    try {
      bytes = utf8.encode(text);
    } on FormatException {
      return false;
    }
    if (bytes.length > maxBytes) return false;
    for (final rune in text.runes) {
      if (rune == 0 ||
          (rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
          (rune >= 0xd800 && rune <= 0xdfff) ||
          rune > 0x10ffff) {
        return false;
      }
    }
    return true;
  }

  static List<RemoteInputEvent>? _parseEvents(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > maxInputEvents) {
      return null;
    }
    final events = <RemoteInputEvent>[];
    for (final item in raw) {
      if (item is! List || item.isEmpty || item.first is! String) return null;
      switch (item.first) {
        case 'm':
          if (item.length != 3 || item[1] is! num || item[2] is! num) {
            return null;
          }
          final x = (item[1] as num).toDouble();
          final y = (item[2] as num).toDouble();
          if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
            return null;
          }
          events.add(RemoteMoveEvent(x, y));
        case 'd':
        case 'u':
          if (item.length != 2) return null;
          final button = RemoteMouseButton.fromWire(item[1]);
          if (button == null) return null;
          events.add(RemoteButtonEvent(button, down: item.first == 'd'));
        case 'w':
          if (item.length != 2 || item[1] is! int) return null;
          final delta = item[1] as int;
          if (delta == 0 || delta < -12000 || delta > 12000) return null;
          events.add(RemoteWheelEvent(delta));
        case 'k':
          if (item.length != 3 ||
              item[1] is! int ||
              item[2] is! bool ||
              (item[1] as int) <= 0 ||
              (item[1] as int) > 0xff) {
            return null;
          }
          events.add(RemoteKeyEvent(item[1] as int, down: item[2] as bool));
        case 't':
          if (item.length != 2 ||
              item[1] is! String ||
              !_validText(item[1] as String, maxTextEventBytes)) {
            return null;
          }
          events.add(RemoteTextEvent(item[1] as String));
        case 'a':
          if (item.length != 2) return null;
          final action = RemoteGlobalAction.fromWire(item[1]);
          if (action == null) return null;
          events.add(RemoteActionEvent(action));
        default:
          return null;
      }
    }
    return List.unmodifiable(events);
  }
}

/// Validates JSON grammar while retaining object-key occurrences. Dart's
/// `jsonDecode` intentionally accepts duplicate keys, whereas JsonCpp is
/// configured with `rejectDupKeys=true`; this small pre-pass closes that gap.
class RemoteControlJsonValidator {
  RemoteControlJsonValidator(this.source);
  final String source;
  int _index = 0;

  void validate() {
    _space();
    _value();
    _space();
    if (_index != source.length) throw const FormatException('trailing data');
  }

  void _value([int depth = 1]) {
    // JsonCpp counts the root and each nested value as one level.
    if (depth > RemoteControlProtocol.maxJsonDepth) {
      throw const FormatException('JSON depth');
    }
    _space();
    if (_index >= source.length) throw const FormatException('missing value');
    switch (source.codeUnitAt(_index)) {
      case 0x7b:
        _object(depth);
      case 0x5b:
        _array(depth);
      case 0x22:
        _string();
      case 0x74:
        _literal('true');
      case 0x66:
        _literal('false');
      case 0x6e:
        _literal('null');
      default:
        _number();
    }
  }

  void _object(int depth) {
    _expect('{');
    _space();
    if (_take('}')) return;
    final keys = <String>{};
    while (true) {
      _space();
      final key = _string();
      if (!keys.add(key)) throw const FormatException('duplicate key');
      _space();
      _expect(':');
      _value(depth + 1);
      _space();
      if (_take('}')) return;
      _expect(',');
    }
  }

  void _array(int depth) {
    _expect('[');
    _space();
    if (_take(']')) return;
    while (true) {
      _value(depth + 1);
      _space();
      if (_take(']')) return;
      _expect(',');
    }
  }

  String _string() {
    final start = _index;
    _expect('"');
    while (_index < source.length) {
      final code = source.codeUnitAt(_index++);
      if (code == 0x22) {
        return jsonDecode(source.substring(start, _index)) as String;
      }
      if (code < 0x20) throw const FormatException('control in string');
      if (code != 0x5c) continue;
      if (_index >= source.length) throw const FormatException('bad escape');
      final escaped = source.codeUnitAt(_index++);
      if (escaped == 0x75) {
        if (_index + 4 > source.length) {
          throw const FormatException('short unicode escape');
        }
        for (var i = 0; i < 4; i++) {
          final hex = source.codeUnitAt(_index++);
          final valid =
              (hex >= 0x30 && hex <= 0x39) ||
              (hex >= 0x41 && hex <= 0x46) ||
              (hex >= 0x61 && hex <= 0x66);
          if (!valid) throw const FormatException('bad unicode escape');
        }
      } else if (!const {
        0x22,
        0x5c,
        0x2f,
        0x62,
        0x66,
        0x6e,
        0x72,
        0x74,
      }.contains(escaped)) {
        throw const FormatException('bad escape');
      }
    }
    throw const FormatException('unterminated string');
  }

  void _number() {
    final start = _index;
    _take('-');
    if (_take('0')) {
      if (_index < source.length && _digit(source.codeUnitAt(_index))) {
        throw const FormatException('leading zero');
      }
    } else {
      _digits();
    }
    if (_take('.')) _digits();
    if (_take('e') || _take('E')) {
      _take('+') || _take('-');
      _digits();
    }
    if (_index == start || (source[start] == '-' && _index == start + 1)) {
      throw const FormatException('bad number');
    }
  }

  void _digits() {
    final start = _index;
    while (_index < source.length && _digit(source.codeUnitAt(_index))) {
      _index++;
    }
    if (_index == start) throw const FormatException('missing digit');
  }

  bool _digit(int value) => value >= 0x30 && value <= 0x39;

  void _literal(String value) {
    if (!source.startsWith(value, _index)) {
      throw const FormatException('bad literal');
    }
    _index += value.length;
  }

  void _space() {
    while (_index < source.length &&
        const {0x20, 0x09, 0x0a, 0x0d}.contains(source.codeUnitAt(_index))) {
      _index++;
    }
  }

  bool _take(String value) {
    if (!source.startsWith(value, _index)) return false;
    _index += value.length;
    return true;
  }

  void _expect(String value) {
    if (!_take(value)) throw FormatException('expected $value');
  }
}

abstract interface class RemoteControlTransport {
  bool get nativeHostAuthority;
  Future<RemoteControlHostAuthority?> hostAuthority();
  Future<RemoteControlHostAuthority?> setProtectedSurface({
    required int channelEpoch,
    required int surfaceRevision,
    required bool blocked,
  });

  /// Windows owns request/session expiry in the native controller. Android's
  /// controller-only transport relies on the Dart projection for that timer.
  bool get nativeControllerAuthority;

  /// Windows mints and correlates clipboard ids inside the native controller
  /// or host. Android sends the Dart wire packets and therefore correlates
  /// their ids here.
  bool get nativeClipboardCorrelation;

  Future<bool> request(
    RemoteControlBinding binding,
    Set<RemoteControlCapability> capabilities,
    String identityColor,
    String androidPacket,
  );

  Future<bool> input(
    RemoteControlBinding binding,
    List<RemoteInputEvent> events,
    String androidPacket,
  );

  Future<bool> end(RemoteControlBinding binding, String androidPacket);

  Future<bool> sendClipboard({
    required RemoteControlBinding binding,
    required String text,
    required String id,
    required String sha256Hex,
    required String androidOfferPacket,
    required String androidDataPacket,
    required bool fromHost,
    required RemoteClipboardOwner owner,
  });

  Future<bool> respondToClipboard({
    required RemoteControlBinding binding,
    required int promptGeneration,
    required String id,
    required bool accepted,
    required String androidPacket,
    required bool asController,
  });

  Future<bool> allowHostRequest(
    RemoteControlHostRequest request, {
    required bool persistDevice,
  });

  Future<bool> denyHostRequest(RemoteControlHostRequest request);

  Future<bool> stopHostControl();

  Future<bool> setCoControl(bool enabled);
}

class JamiRemoteControlTransport implements RemoteControlTransport {
  JamiRemoteControlTransport(this.jami);
  final JamiClient jami;

  @override
  bool get nativeHostAuthority =>
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<RemoteControlHostAuthority?> hostAuthority() =>
      jami.remoteControlHostAuthority();

  @override
  Future<RemoteControlHostAuthority?> setProtectedSurface({
    required int channelEpoch,
    required int surfaceRevision,
    required bool blocked,
  }) => jami.setRemoteControlProtectedSurface(
    channelEpoch: channelEpoch,
    surfaceRevision: surfaceRevision,
    blocked: blocked,
  );

  @override
  bool get nativeControllerAuthority =>
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  bool get nativeClipboardCorrelation =>
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<bool> request(
    RemoteControlBinding binding,
    Set<RemoteControlCapability> capabilities,
    String identityColor,
    String androidPacket,
  ) => jami.requestRemoteControl(
    callId: binding.callId,
    peerJamiId: binding.peerId,
    sourceRevision: binding.sourceRevision,
    capabilities: <String>[
      for (final capability in RemoteControlCapability.values)
        if (capabilities.contains(capability)) capability.wireName,
    ],
    identityColor: identityColor,
    androidPacket: androidPacket,
  );

  @override
  Future<bool> input(
    RemoteControlBinding binding,
    List<RemoteInputEvent> events,
    String androidPacket,
  ) => jami.sendRemoteControlInput(
    callId: binding.callId,
    peerJamiId: binding.peerId,
    sourceRevision: binding.sourceRevision,
    events: <List<Object>>[for (final event in events) event.toWire()],
    androidPacket: androidPacket,
  );

  @override
  Future<bool> end(RemoteControlBinding binding, String androidPacket) =>
      jami.endRemoteControl(
        callId: binding.callId,
        peerJamiId: binding.peerId,
        sourceRevision: binding.sourceRevision,
        androidPacket: androidPacket,
      );

  @override
  Future<bool> sendClipboard({
    required RemoteControlBinding binding,
    required String text,
    required String id,
    required String sha256Hex,
    required String androidOfferPacket,
    required String androidDataPacket,
    required bool fromHost,
    required RemoteClipboardOwner owner,
  }) {
    final session = owner.hostSession ?? binding;
    return jami.sendRemoteClipboard(
      callId: session.callId,
      peerJamiId: session.peerId,
      sourceRevision: session.sourceRevision,
      text: text,
      id: id,
      sha256Hex: sha256Hex,
      androidOfferPacket: androidOfferPacket,
      androidDataPacket: androidDataPacket,
      fromHost: fromHost,
      controllerDeviceId: session.peerDeviceId,
      hostGeneration: owner.hostGeneration,
    );
  }

  @override
  Future<bool> respondToClipboard({
    required RemoteControlBinding binding,
    required int promptGeneration,
    required String id,
    required bool accepted,
    required String androidPacket,
    required bool asController,
  }) => jami.respondRemoteClipboard(
    callId: binding.callId,
    peerJamiId: binding.peerId,
    sourceRevision: binding.sourceRevision,
    promptGeneration: promptGeneration,
    id: id,
    accepted: accepted,
    androidPacket: androidPacket,
    asController: asController,
  );

  @override
  Future<bool> allowHostRequest(
    RemoteControlHostRequest request, {
    required bool persistDevice,
  }) => jami.allowRemoteControl(
    callId: request.binding.callId,
    controllerAccountId: request.controllerAccountId,
    controllerDeviceId: request.controllerDeviceId,
    sourceRevision: request.binding.sourceRevision,
    hostGeneration: request.generation,
    persistDevice: persistDevice,
  );

  @override
  Future<bool> denyHostRequest(RemoteControlHostRequest request) =>
      jami.denyRemoteControl(
        callId: request.binding.callId,
        controllerAccountId: request.controllerAccountId,
        controllerDeviceId: request.controllerDeviceId,
        sourceRevision: request.binding.sourceRevision,
        hostGeneration: request.generation,
      );

  @override
  Future<bool> stopHostControl() => jami.stopRemoteControlHost();

  @override
  Future<bool> setCoControl(bool enabled) =>
      jami.setRemoteControlCoControl(enabled);
}

class _PendingClipboardWire {
  _PendingClipboardWire({
    required this.binding,
    required this.id,
    required this.sha256Hex,
    required this.size,
  });

  final RemoteControlBinding binding;
  final String id;
  final String sha256Hex;
  final int size;
  Timer? timeout;
}

/// Call/source/device-scoped Dart projection. Native Windows and Android code
/// remain the controllee authorities; this class owns controller interaction,
/// lifecycle projection, coalescing, and stale-completion rejection.
class RemoteControlController extends ChangeNotifier {
  RemoteControlController(
    this._transport, {
    this._moveInterval = const Duration(milliseconds: 36),
    this._requestTimeout = const Duration(seconds: 20),
    this._clipboardTimeout = const Duration(seconds: 20),
    Random? secureRandom,
    String Function()? identityColor,
    bool Function()? requestAllowed,
  }) : _random = secureRandom ?? Random.secure(),
       _identityColor = identityColor ?? (() => 'amber'),
       _requestAllowed = requestAllowed ?? (() => true);

  static const Set<RemoteControlCapability> defaultCapabilities = {
    RemoteControlCapability.mouse,
    RemoteControlCapability.keyboard,
    RemoteControlCapability.text,
    RemoteControlCapability.clipboard,
    RemoteControlCapability.back,
    RemoteControlCapability.home,
    RemoteControlCapability.recents,
  };
  static const int _maxQueuedBatches = 32;
  static const int _maxOutgoingClipboards = 8;
  static final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{40,128}$');

  final RemoteControlTransport _transport;
  final Duration _moveInterval;
  final Duration _requestTimeout;
  final Duration _clipboardTimeout;
  final Random _random;
  final String Function() _identityColor;
  final bool Function() _requestAllowed;

  Timer? _clipboardRequestTimer;
  // The prompt whose accept is mid-flight, if any. Non-null only across the
  // clipboard write's await.
  RemoteClipboardRequest? _clipboardDecisionInFlight;
  int _nextClipboardPromptGeneration = 1;
  int? _decidingHostGeneration;
  RemoteControlPhase phase = RemoteControlPhase.idle;
  RemoteControlHostPhase hostPhase = RemoteControlHostPhase.idle;
  RemoteControlBinding? controllerBinding;
  RemoteControlBinding? _availableRemoteBinding;
  RemoteControlBinding? _availableHostBinding;
  RemoteControlBinding? _hostSessionBinding;
  int? _hostSessionGenerationValue;
  // Changes whenever the host session identity changes, so an identical
  // generation reached again after a stop is still a different lifetime.
  int _hostLifetime = 0;
  int? get _hostSessionGeneration => _hostSessionGenerationValue;
  set _hostSessionGeneration(int? value) {
    if (value != _hostSessionGenerationValue) _hostLifetime++;
    _hostSessionGenerationValue = value;
  }

  RemoteControlHostRequest? hostRequest;
  // Read-only outside this class so callers cannot bypass prompt exclusivity.
  RemoteClipboardRequest? _clipboardRequest;
  RemoteClipboardRequest? get clipboardRequest => _clipboardRequest;
  Set<RemoteControlCapability> grantedCapabilities = const {};
  String? notice;
  String? hostReason;
  // Null means native has not reported hotkey registration. Do not infer a
  // successful kill switch from an active session or a missing event field.
  bool? hotkeyAvailable;
  bool coControl = false;
  bool _foreground = true;

  String _token = '';
  int _epoch = 0;
  int _sequence = 0;
  int _generation = 0;
  RemoteMoveEvent? _pendingMove;
  final Set<int> _heldKeys = <int>{};
  final Set<RemoteMouseButton> _heldButtons = <RemoteMouseButton>{};
  Timer? _moveTimer;
  Timer? _textTimer;
  String _pendingText = '';
  Timer? _requestTimer;
  final Queue<List<RemoteInputEvent>> _sendQueue =
      Queue<List<RemoteInputEvent>>();
  bool _draining = false;
  _PendingClipboardWire? _pendingClipboardWire;
  final Set<String> _observedClipboardIds = {};
  final Map<String, Timer> _outgoingClipboardIds = {};
  String? _pendingNativeClipboardApplyId;
  int? _pendingNativeClipboardApplyGeneration;
  RemoteControlBinding? _pendingNativeClipboardApplyBinding;
  bool _disposed = false;
  int _retiredHostGeneration = 0;
  int _hostOperation = 0;
  RemoteControlHostAuthority? _hostAuthority;
  int _hostSurfaceRevision = 0;
  bool _hostDesiredBlocked = true;
  bool _hostChannelFailed = false;
  bool _hostLeaseExpired = false;
  Future<void>? _hostInitialization;
  Future<bool>? _hostSurfaceRequest;
  bool? _hostRequestedBlocked;
  Timer? _hostLeaseTimer;
  Timer? _hostLeaseTimeout;
  (int, int)? _hostRenewal;

  bool get _nativeHostReady =>
      !_transport.nativeHostAuthority ||
      (!_hostChannelFailed &&
          !_hostLeaseExpired &&
          !_hostDesiredBlocked &&
          _hostAuthority != null &&
          !_hostAuthority!.blocked &&
          _hostAuthority!.surfaceRevision == _hostSurfaceRevision &&
          _hostAuthority!.releaseComplete &&
          _hostAuthority!.state != 'revoking');

  /// Bootstrap only after the EventChannel listener is attached. Native starts
  /// blocked; a current epoch and a successful surface update are required.
  Future<void> initializeHostAuthority() {
    if (!_transport.nativeHostAuthority || _disposed) return Future.value();
    return _hostInitialization ??= () async {
      try {
        final value = await _transport.hostAuthority();
        if (!_disposed && value != null) _applyHostAuthority(value);
        if (!_disposed && _hostAuthority == null) _retireHostProjection();
      } catch (_) {
        if (!_disposed) _retireHostProjection();
      }
    }();
  }

  void _retireHostProjection() {
    _hostLeaseTimer?.cancel();
    _hostLeaseTimer = null;
    _hostLeaseTimeout?.cancel();
    _hostLeaseTimeout = null;
    _hostOperation++;
    _decidingHostGeneration = null;
    _retiredHostGeneration = max(
      _retiredHostGeneration,
      _hostSessionGeneration ?? hostRequest?.generation ?? 0,
    );
    hostRequest = null;
    _hostSessionBinding = null;
    _hostSessionGeneration = null;
    hostPhase = RemoteControlHostPhase.revoking;
    coControl = false;
    hotkeyAvailable = null;
    _clearPendingNativeClipboardApply();
    if (clipboardRequest?.receiver == RemoteClipboardReceiver.controllee) {
      _clearClipboardRequest();
    }
  }

  void applyNativeHostAuthority(Map<String, dynamic> data) {
    if (!_transport.nativeHostAuthority || _disposed) return;
    final value = RemoteControlHostAuthority.tryParse(data);
    if (value == null) {
      hostChannelFailed();
      return;
    }
    _applyHostAuthority(value);
  }

  bool _applyHostAuthority(RemoteControlHostAuthority value) {
    final previous = _hostAuthority;
    if (previous != null && value.channelEpoch < previous.channelEpoch) {
      return false;
    }
    if (previous == null || value.channelEpoch > previous.channelEpoch) {
      _retireHostProjection();
      _retiredHostGeneration = value.revokedThrough;
      _hostSurfaceRevision = value.surfaceRevision;
      _hostRequestedBlocked = null;
      _hostSurfaceRequest = null;
      _hostChannelFailed = false;
      _hostLeaseExpired = false;
    } else if (value.surfaceRevision < _hostSurfaceRevision ||
        value.revokedThrough < previous.revokedThrough) {
      return false;
    } else if (value.surfaceRevision > _hostSurfaceRevision && value.blocked) {
      // Native lease expiry is a new barrier, not permission to reopen it.
      _hostLeaseExpired = true;
    }
    _hostAuthority = value;
    _hostSurfaceRevision = value.surfaceRevision;
    _retiredHostGeneration = max(_retiredHostGeneration, value.revokedThrough);
    if (value.blocked || value.state == 'revoking' || !value.releaseComplete) {
      _retireHostProjection();
    }
    if (value.revoked) {
      if (_hostSessionGeneration == null ||
          _hostSessionGeneration! <= value.revokedThrough) {
        if (_hostSessionGeneration != null || hostRequest != null) {
          _retireHostProjection();
        }
        hostPhase = RemoteControlHostPhase.idle;
      }
      if (value.blocked &&
          !_hostDesiredBlocked &&
          !_hostChannelFailed &&
          !_hostLeaseExpired) {
        unawaited(_setHostSurface(false));
      }
    }
    if (_nativeHostReady) _startHostLease();
    _notify();
    return true;
  }

  void _startHostLease() {
    _hostLeaseTimeout?.cancel();
    _hostLeaseTimeout = Timer(
      const Duration(milliseconds: 1500),
      _failHostLease,
    );
    _hostLeaseTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_disposed || !_nativeHostReady) {
        _failHostLease();
        return;
      }
      unawaited(_renewHostLease());
    });
  }

  Future<void> _renewHostLease() async {
    final authority = _hostAuthority!;
    final revision = _hostSurfaceRevision;
    final renewal = (authority.channelEpoch, revision);
    if (_hostRenewal == renewal) return;
    _hostRenewal = renewal;
    try {
      final value = await _transport.setProtectedSurface(
        channelEpoch: authority.channelEpoch,
        surfaceRevision: revision,
        blocked: false,
      );
      if (_disposed ||
          _hostAuthority?.channelEpoch != authority.channelEpoch ||
          _hostSurfaceRevision != revision ||
          !_nativeHostReady) {
        return;
      }
      if (value == null ||
          value.channelEpoch != authority.channelEpoch ||
          value.surfaceRevision != revision ||
          value.blocked ||
          !value.releaseComplete ||
          value.state == 'revoking') {
        _failHostLease();
        return;
      }
      if (!_applyHostAuthority(value)) _failHostLease();
    } catch (_) {
      if (!_disposed &&
          _hostAuthority?.channelEpoch == authority.channelEpoch &&
          _hostSurfaceRevision == revision) {
        _failHostLease();
      }
    } finally {
      if (_hostRenewal == renewal) _hostRenewal = null;
    }
  }

  void _failHostLease() {
    if (_disposed) return;
    _hostLeaseExpired = true;
    _retireHostProjection();
    if (_hostAuthority != null) unawaited(_setHostSurface(true));
    _notify();
  }

  Future<bool> _setHostSurface(bool blocked) {
    if (_hostSurfaceRequest != null && _hostRequestedBlocked == blocked) {
      return _hostSurfaceRequest!;
    }
    final authority = _hostAuthority;
    if (authority == null) return Future.value(false);
    final epoch = authority.channelEpoch;
    final revision = ++_hostSurfaceRevision;
    _hostRequestedBlocked = blocked;
    if (blocked) _retireHostProjection();
    // Invoke the channel before yielding: a block must not queue behind the
    // completion of an older unblock or Allow operation.
    final response = Future.sync(
      () => _transport.setProtectedSurface(
        channelEpoch: epoch,
        surfaceRevision: revision,
        blocked: blocked,
      ),
    );
    final result = () async {
      try {
        final value = await response;
        if (_disposed ||
            _hostAuthority?.channelEpoch != epoch ||
            _hostSurfaceRevision != revision) {
          return false;
        }
        if (value == null ||
            value.channelEpoch != epoch ||
            value.surfaceRevision != revision ||
            value.blocked != blocked) {
          _hostLeaseExpired = true;
          _retireHostProjection();
          _notify();
          return false;
        }
        if (!_applyHostAuthority(value)) {
          _hostLeaseExpired = true;
          _retireHostProjection();
          _notify();
          return false;
        }
        return blocked
            ? value.revoked
            : !value.blocked && value.releaseComplete;
      } catch (_) {
        if (!_disposed &&
            _hostAuthority?.channelEpoch == epoch &&
            _hostSurfaceRevision == revision) {
          _hostLeaseExpired = true;
          _retireHostProjection();
          _notify();
        }
        return false;
      } finally {
        if (_hostAuthority?.channelEpoch == epoch &&
            _hostSurfaceRevision == revision) {
          _hostSurfaceRequest = null;
          _hostRequestedBlocked = null;
        }
      }
    }();
    _hostSurfaceRequest = result;
    return result;
  }

  Future<bool> _revokeNativeHost() async {
    _retireHostProjection();
    if (_hostAuthority == null) await initializeHostAuthority();
    if (_disposed || _hostAuthority == null) return false;
    return _setHostSurface(true);
  }

  Future<void> _recoverHostLease() async {
    if (_hostChannelFailed) return;
    try {
      final value = await _transport.hostAuthority();
      if (_disposed || _hostChannelFailed || value == null) return;
      if (!_applyHostAuthority(value)) return;
      _hostLeaseExpired = false;
      await _revokeNativeHost();
    } catch (_) {
      if (!_disposed) _retireHostProjection();
    }
  }

  /// An event-channel failure removes the local permission to reopen. Native
  /// also closes its channel lease; only a newer epoch can recover this one.
  void hostChannelFailed() {
    if (!_transport.nativeHostAuthority || _disposed) return;
    _hostChannelFailed = true;
    _retireHostProjection();
    if (_hostAuthority != null) unawaited(_setHostSurface(true));
    _notify();
  }

  bool get canRequest =>
      _requestAllowed() &&
      _foreground &&
      phase != RemoteControlPhase.requesting &&
      phase != RemoteControlPhase.controlling &&
      _availableRemoteBinding != null;
  bool get isControlling => phase == RemoteControlPhase.controlling;
  bool get hostActive =>
      hostPhase == RemoteControlHostPhase.active ||
      hostPhase == RemoteControlHostPhase.suspended ||
      hostPhase == RemoteControlHostPhase.hostPriority;
  bool get canSendClipboard =>
      (isControlling &&
          grantedCapabilities.contains(RemoteControlCapability.clipboard)) ||
      hostActive;
  bool supportsCapability(RemoteControlCapability capability) =>
      isControlling && grantedCapabilities.contains(capability);

  /// Reconcile against the only live call slot and both independently-owned
  /// screen-source revisions. Any change invalidates the old session before
  /// the UI can enqueue another event.
  void syncCall({
    required bool live,
    required bool foreground,
    bool? hostAvailable,
    required String callId,
    required String peerId,
    required bool peerScreenActive,
    required int? peerSourceRevision,
    required bool localScreenActive,
    required int localSourceRevision,
  }) {
    _foreground = foreground;
    final remote =
        live &&
            foreground &&
            callId.isNotEmpty &&
            peerId.isNotEmpty &&
            peerScreenActive &&
            peerSourceRevision != null &&
            peerSourceRevision > 0
        ? RemoteControlBinding(
            callId: callId,
            peerId: peerId,
            sourceRevision: peerSourceRevision,
          )
        : null;
    final host =
        live &&
            (hostAvailable ?? foreground) &&
            callId.isNotEmpty &&
            peerId.isNotEmpty &&
            localScreenActive &&
            localSourceRevision > 0
        ? RemoteControlBinding(
            callId: callId,
            peerId: peerId,
            sourceRevision: localSourceRevision,
          )
        : null;

    final active = controllerBinding;
    if (active != null && (remote == null || !active.sameSource(remote))) {
      _retireController(sendEnd: true, reason: 'screen-changed');
    }
    final hostChanged = _availableHostBinding != host;
    if (_transport.nativeHostAuthority) {
      _hostDesiredBlocked = host == null;
      if (hostChanged &&
          host != null &&
          _hostLeaseExpired &&
          !_hostChannelFailed) {
        unawaited(_recoverHostLease());
      } else if (hostChanged &&
          (_availableHostBinding != null || host == null)) {
        unawaited(_revokeNativeHost());
      } else if (host != null && hostChanged) {
        unawaited(() async {
          await initializeHostAuthority();
          final authority = _hostAuthority;
          if (!_disposed &&
              !_hostDesiredBlocked &&
              !_hostChannelFailed &&
              !_hostLeaseExpired &&
              authority != null &&
              authority.blocked &&
              authority.revoked) {
            await _setHostSurface(false);
          }
        }());
      }
    }
    if (!_transport.nativeHostAuthority &&
        hostRequest != null &&
        (host == null || !hostRequest!.binding.sameSource(host))) {
      final staleRequest = hostRequest!;
      _bestEffortTeardown(
        'deny stale host request',
        () => _transport.denyHostRequest(staleRequest),
      );
      hostRequest = null;
      _hostSessionBinding = null;
      _hostSessionGeneration = null;
      coControl = false;
      hotkeyAvailable = null;
    }
    if (!_transport.nativeHostAuthority &&
        hostActive &&
        (_availableHostBinding == null ||
            host == null ||
            !_availableHostBinding!.sameSource(host))) {
      unawaited(stopHost());
    }
    final changed =
        _availableRemoteBinding != remote || _availableHostBinding != host;
    _availableRemoteBinding = remote;
    _availableHostBinding = host;
    if (changed) _notify();
  }

  Future<bool> requestControl() async {
    final binding = _availableRemoteBinding;
    if (!canRequest || binding == null) return false;
    _retireController(sendEnd: false);
    controllerBinding = binding;
    phase = RemoteControlPhase.requesting;
    notice = null;
    final generation = ++_generation;
    _notify();
    final identityColor = _identityColor();
    final packet = RemoteControlProtocol.request(
      capabilities: defaultCapabilities,
      sourceRevision: binding.sourceRevision,
      identityColor: identityColor,
    );
    bool sent;
    try {
      sent = await _transport.request(
        binding,
        defaultCapabilities,
        identityColor,
        packet,
      );
    } catch (_) {
      sent = false;
    }
    if (_disposed ||
        generation != _generation ||
        controllerBinding != binding ||
        phase != RemoteControlPhase.requesting) {
      return false;
    }
    if (!sent) {
      _retireController(sendEnd: false, reason: 'request-send-failed');
      notice = 'Could not ask for control.';
      _notify();
    } else if (generation == _generation &&
        phase == RemoteControlPhase.requesting) {
      _requestTimer?.cancel();
      _requestTimer = Timer(_requestTimeout, () {
        if (_disposed ||
            generation != _generation ||
            phase != RemoteControlPhase.requesting ||
            controllerBinding != binding) {
          return;
        }
        _retireController(sendEnd: false, reason: 'request-timeout');
        notice = 'Control request timed out.';
        _notify();
      });
    }
    return sent;
  }

  Future<void> stopControlling({String reason = 'local-stop'}) async {
    final binding = controllerBinding;
    if (binding == null) return;
    _retireController(sendEnd: false, reason: reason);
    _notify();
    try {
      await _transport.end(
        binding,
        RemoteControlProtocol.end(
          RemoteControlWireDirection.controllerToControllee,
        ),
      );
    } catch (_) {
      // Local teardown is authoritative for the controller UI. The Windows
      // apply-time grant remains protected by call/source/lifecycle teardown.
    }
  }

  void move(double x, double y) {
    if (!supportsCapability(RemoteControlCapability.mouse)) return;
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      return;
    }
    _pendingMove = RemoteMoveEvent(_round(x), _round(y));
    _moveTimer ??= Timer(_moveInterval, _flushMove);
  }

  void button(RemoteMouseButton button, {required bool down}) {
    if (!supportsCapability(RemoteControlCapability.mouse) ||
        (button != RemoteMouseButton.left &&
            button != RemoteMouseButton.right)) {
      return;
    }
    if (down) {
      _heldButtons.add(button);
    } else {
      _heldButtons.remove(button);
    }
    _discrete(RemoteButtonEvent(button, down: down));
  }

  void click([RemoteMouseButton button = RemoteMouseButton.left]) {
    this.button(button, down: true);
    this.button(button, down: false);
  }

  void wheel(int delta) {
    if (!supportsCapability(RemoteControlCapability.mouse) || delta == 0) {
      return;
    }
    _discrete(RemoteWheelEvent(delta.clamp(-12000, 12000)));
  }

  void key(int virtualKey, {required bool down}) {
    if (!supportsCapability(RemoteControlCapability.keyboard) ||
        virtualKey <= 0 ||
        virtualKey > 0xff) {
      return;
    }
    if (down) {
      _heldKeys.add(virtualKey);
    } else {
      _heldKeys.remove(virtualKey);
    }
    _discrete(RemoteKeyEvent(virtualKey, down: down));
  }

  /// Releases every input this controller may still be holding.
  ///
  /// Desktop focus can move without Flutter receiving the matching key-up or
  /// pointer-up. The controllee also releases held input on suspend/revoke,
  /// but sending explicit ups here prevents a remote key from sticking while
  /// the grant legitimately remains active.
  void releaseHeldInputs() {
    if (!isControlling) {
      _heldKeys.clear();
      _heldButtons.clear();
      return;
    }
    final releases = <RemoteInputEvent>[
      for (final key in _heldKeys) RemoteKeyEvent(key, down: false),
      for (final button in _heldButtons) RemoteButtonEvent(button, down: false),
    ];
    _heldKeys.clear();
    _heldButtons.clear();
    if (releases.isEmpty) return;

    final pendingMove = _takePendingMove();
    var offset = 0;
    while (offset < releases.length && isControlling) {
      final capacity =
          RemoteControlProtocol.maxInputEvents -
          (offset == 0 && pendingMove != null ? 1 : 0);
      final end = min(offset + capacity, releases.length);
      _enqueue(<RemoteInputEvent>[
        if (offset == 0 && pendingMove != null) pendingMove,
        ...releases.sublist(offset, end),
      ]);
      offset = end;
    }
  }

  void text(String value) {
    if (!supportsCapability(RemoteControlCapability.text)) return;
    if (value.length > RemoteControlProtocol.maxClipboardBytes) return;
    late final int byteLength;
    try {
      byteLength = utf8.encode(value).length;
    } on FormatException {
      return;
    }
    if (!RemoteControlProtocol._validText(value, byteLength) ||
        byteLength + utf8.encode(_pendingText).length >
            RemoteControlProtocol.maxClipboardBytes) {
      notice = 'Wait for the pending text to finish sending.';
      _notify();
      return;
    }
    _pendingText += value;
    if (_textTimer == null) _flushText();
  }

  void _flushText() {
    _textTimer = null;
    if (!isControlling || _pendingText.isEmpty) return;
    // Generate only the next bounded chunk, leaving room for mouse/key work
    // and explicit releases. A slow transport cannot accumulate all chunks.
    if (_sendQueue.length < 4) {
      var end = 0;
      for (final rune in _pendingText.runes) {
        final units = rune > 0xffff ? 2 : 1;
        if (end + units > 32) break;
        end += units;
      }
      final chunk = _pendingText.substring(0, end);
      _pendingText = _pendingText.substring(end);
      _discrete(RemoteTextEvent(chunk));
    }
    if (isControlling) {
      _textTimer = Timer(const Duration(milliseconds: 500), _flushText);
    }
  }

  void action(RemoteGlobalAction action) {
    if (!grantedCapabilities.contains(action.capability)) return;
    _discrete(RemoteActionEvent(action));
  }

  /// The owner is captured before [readText] runs and must still be current
  /// afterwards; a session replaced in between cancels the send. [stillCurrent]
  /// lets the caller add ownership this class cannot see (the local account).
  Future<bool> sendClipboardFromReader(
    Future<String?> Function() readText, {
    bool Function()? stillCurrent,
  }) async {
    final owner = _captureClipboardOwner();
    if (owner == null) return false;
    String? text;
    try {
      text = await readText();
    } catch (_) {
      return false;
    }
    if (text == null ||
        text.isEmpty ||
        (stillCurrent != null && !stillCurrent())) {
      return false;
    }
    return sendClipboardText(text, fromHost: owner.fromHost, owner: owner);
  }

  RemoteClipboardOwner? _captureClipboardOwner() {
    if (_disposed) return null;
    if (hostActive) {
      final session = _hostSessionBinding;
      final generation = _hostSessionGeneration;
      final available = _availableHostBinding;
      if (session == null || generation == null || available == null) {
        return null;
      }
      return RemoteClipboardOwner._(
        fromHost: true,
        binding: available,
        hostSession: session,
        hostGeneration: generation,
        lifetime: _hostLifetime,
      );
    }
    final binding = controllerBinding;
    if (binding == null || !isControlling) return null;
    return RemoteClipboardOwner._(
      fromHost: false,
      binding: binding,
      hostSession: null,
      hostGeneration: 0,
      lifetime: _generation,
    );
  }

  bool _clipboardOwnerCurrent(RemoteClipboardOwner owner) {
    if (_disposed || hostActive != owner.fromHost) return false;
    if (owner.fromHost) {
      return owner.lifetime == _hostLifetime &&
          owner.binding == _availableHostBinding &&
          owner.hostSession == _hostSessionBinding &&
          owner.hostGeneration == _hostSessionGeneration;
    }
    return owner.lifetime == _generation &&
        owner.binding == controllerBinding &&
        isControlling &&
        grantedCapabilities.contains(RemoteControlCapability.clipboard);
  }

  Future<bool> sendClipboardText(
    String text, {
    required bool fromHost,
    RemoteClipboardOwner? owner,
  }) async {
    final captured = owner ?? _captureClipboardOwner();
    if (captured == null ||
        captured.fromHost != fromHost ||
        !_clipboardOwnerCurrent(captured) ||
        !RemoteControlProtocol._validText(
          text,
          RemoteControlProtocol.maxClipboardBytes,
        )) {
      return false;
    }
    final binding = captured.binding;
    if (!_transport.nativeClipboardCorrelation &&
        _outgoingClipboardIds.length >= _maxOutgoingClipboards) {
      notice = 'Wait for an earlier clipboard transfer to finish.';
      _notify();
      return false;
    }
    final bytes = utf8.encode(text);
    final id = _randomHex(16);
    final hash = sha256.convert(bytes).toString();
    final direction = fromHost
        ? RemoteControlWireDirection.controlleeToController
        : RemoteControlWireDirection.controllerToControllee;
    late final String offer;
    late final String data;
    try {
      offer = RemoteControlProtocol.clipboardOffer(
        id: id,
        sha256Hex: hash,
        size: bytes.length,
        direction: direction,
      );
      data = RemoteControlProtocol.clipboardData(
        id: id,
        sha256Hex: hash,
        text: text,
        direction: direction,
      );
    } on ArgumentError {
      return false;
    }
    if (!_transport.nativeClipboardCorrelation) {
      late final Timer timeout;
      timeout = Timer(_clipboardTimeout, () {
        if (!identical(_outgoingClipboardIds[id], timeout)) return;
        _outgoingClipboardIds.remove(id);
        notice = 'Clipboard response timed out.';
        _notify();
      });
      _outgoingClipboardIds[id] = timeout;
    }
    bool sent;
    try {
      sent = await _transport.sendClipboard(
        binding: binding,
        text: text,
        id: id,
        sha256Hex: hash,
        androidOfferPacket: offer,
        androidDataPacket: data,
        fromHost: fromHost,
        owner: captured,
      );
    } catch (_) {
      sent = false;
    }
    if (!sent) {
      _removeOutgoingClipboard(id);
      notice = 'Clipboard was not sent.';
      _notify();
    }
    return sent;
  }

  /// Accepts only the exact [expectedRequest] captured by the displayed prompt.
  /// A delayed tap must not approve a request that replaced it.
  Future<bool> acceptClipboard(
    Future<void> Function(String text) writeClipboard, {
    required RemoteClipboardRequest expectedRequest,
  }) async {
    final request = clipboardRequest;
    if (request == null || !identical(request, expectedRequest)) return false;
    // Keep one decision in flight while the clipboard write completes.
    if (_clipboardDecisionInFlight != null) return false;
    _clipboardDecisionInFlight = request;
    try {
      return await _completeClipboardAccept(request, writeClipboard);
    } finally {
      if (identical(_clipboardDecisionInFlight, request)) {
        _clipboardDecisionInFlight = null;
      }
    }
  }

  Future<bool> _completeClipboardAccept(
    RemoteClipboardRequest request,
    Future<void> Function(String text) writeClipboard,
  ) async {
    if (request.receiver == RemoteClipboardReceiver.controller &&
        !_transport.nativeClipboardCorrelation) {
      try {
        await writeClipboard(request.text);
      } catch (_) {
        await _rejectClipboardRequest(
          request,
          reason: 'clipboard-write-failed',
        );
        return false;
      }
    } else if (request.receiver == RemoteClipboardReceiver.controllee) {
      _pendingNativeClipboardApplyId = request.id;
      _pendingNativeClipboardApplyGeneration = request.generation;
      _pendingNativeClipboardApplyBinding = request.binding;
    }
    // The prompt may expire during the clipboard write; clear only this request.
    if (identical(clipboardRequest, request)) _clearClipboardRequest();
    _notify();
    final direction = request.receiver == RemoteClipboardReceiver.controller
        ? RemoteControlWireDirection.controllerToControllee
        : RemoteControlWireDirection.controlleeToController;
    final packet = RemoteControlProtocol.clipboardResponse(
      id: request.id,
      accepted: true,
      direction: direction,
    );
    try {
      final applied = await _transport.respondToClipboard(
        binding: request.binding,
        promptGeneration: request.generation,
        id: request.id,
        accepted: true,
        androidPacket: packet,
        asController: request.receiver == RemoteClipboardReceiver.controller,
      );
      if (!applied &&
          _pendingNativeClipboardApplyGeneration == request.generation &&
          request.receiver == RemoteClipboardReceiver.controllee) {
        _clearPendingNativeClipboardApply();
        notice = 'Clipboard was not applied.';
        _notify();
      }
      return applied;
    } catch (_) {
      if (_pendingNativeClipboardApplyGeneration == request.generation) {
        _clearPendingNativeClipboardApply();
        notice = 'Clipboard was not applied.';
        _notify();
      }
      return false;
    }
  }

  Future<bool> rejectClipboard({
    required RemoteClipboardRequest expectedRequest,
    String reason = 'user',
  }) async {
    final request = clipboardRequest;
    if (request == null || !identical(request, expectedRequest)) return false;
    // An accept for this prompt is already committing; a reject arriving now
    // would contradict it (and the write-failure path re-enters here by
    // design, which is why it is allowed through below).
    if (_clipboardDecisionInFlight != null && reason == 'user') return false;
    return _rejectClipboardRequest(request, reason: reason);
  }

  Future<bool> _rejectClipboardRequest(
    RemoteClipboardRequest request, {
    required String reason,
  }) async {
    if (identical(clipboardRequest, request)) _clearClipboardRequest();
    notice = reason == 'user' ? null : 'Clipboard was not applied.';
    _notify();
    final direction = request.receiver == RemoteClipboardReceiver.controller
        ? RemoteControlWireDirection.controllerToControllee
        : RemoteControlWireDirection.controlleeToController;
    final packet = RemoteControlProtocol.clipboardResponse(
      id: request.id,
      accepted: false,
      direction: direction,
    );
    try {
      return await _transport.respondToClipboard(
        binding: request.binding,
        promptGeneration: request.generation,
        id: request.id,
        accepted: false,
        androidPacket: packet,
        asController: request.receiver == RemoteClipboardReceiver.controller,
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> allowHost({
    required RemoteControlHostRequest expectedRequest,
    required bool persistDevice,
  }) async {
    final request = hostRequest;
    if (request == null ||
        !identical(request, expectedRequest) ||
        _decidingHostGeneration != null ||
        !_nativeHostReady ||
        persistDevice) {
      return false;
    }
    _decidingHostGeneration = request.generation;
    final operation = _hostOperation;
    bool applied;
    try {
      applied = await _transport.allowHostRequest(
        request,
        persistDevice: persistDevice,
      );
    } catch (_) {
      applied = false;
    } finally {
      if (_hostOperation == operation &&
          _decidingHostGeneration == request.generation) {
        _decidingHostGeneration = null;
      }
    }
    if (_disposed || operation != _hostOperation || !_nativeHostReady) {
      return false;
    }
    final activatedByNative =
        _hostSessionGeneration == request.generation && hostActive;
    if (!identical(hostRequest, request) && !activatedByNative) return false;
    if (applied) {
      if (!activatedByNative && !_transport.nativeHostAuthority) {
        hostRequest = null;
        _hostSessionBinding = request.binding;
        _hostSessionGeneration = request.generation;
        hostPhase = RemoteControlHostPhase.active;
      }
      hostReason = null;
    } else {
      notice = 'That control request is no longer current.';
    }
    _notify();
    return applied;
  }

  Future<bool> denyHost(RemoteControlHostRequest expectedRequest) async {
    final request = hostRequest;
    if (request == null ||
        !identical(request, expectedRequest) ||
        _decidingHostGeneration != null) {
      return false;
    }
    _decidingHostGeneration = request.generation;
    final operation = _hostOperation;
    bool applied;
    try {
      applied = await _transport.denyHostRequest(request);
    } catch (_) {
      applied = false;
    } finally {
      if (_hostOperation == operation &&
          _decidingHostGeneration == request.generation) {
        _decidingHostGeneration = null;
      }
    }
    if (_disposed || operation != _hostOperation) return false;
    if (!applied || !identical(hostRequest, request)) return applied;
    _retiredHostGeneration = max(_retiredHostGeneration, request.generation);
    hostRequest = null;
    _hostSessionBinding = null;
    _hostSessionGeneration = null;
    hostPhase = RemoteControlHostPhase.idle;
    coControl = false;
    hotkeyAvailable = null;
    _notify();
    return true;
  }

  Future<bool> stopHost() async {
    _retireHostProjection();
    hostReason = 'local-stop';
    _notify();
    if (_transport.nativeHostAuthority) return _revokeNativeHost();
    final operation = _hostOperation;
    try {
      final stopped = await _transport.stopHostControl();
      if (!_disposed && operation == _hostOperation && stopped) {
        hostPhase = RemoteControlHostPhase.idle;
        _notify();
      }
      return stopped;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setCoControl(bool enabled) async {
    if (!hostActive || enabled == coControl) return false;
    final binding = _hostSessionBinding;
    if (binding == null) return false;
    bool applied;
    try {
      applied = await _transport.setCoControl(enabled);
    } catch (_) {
      applied = false;
    }
    if (applied && _hostSessionBinding == binding && hostActive) {
      coControl = enabled;
      _notify();
    }
    return applied && _hostSessionBinding == binding && hostActive;
  }

  /// Android controller ingress. The envelope account/device values come from
  /// the authenticated live-call certificate fields emitted by JamiCore.
  void applyControlleePacket({
    required String callId,
    required String peerId,
    required String peerDeviceId,
    required String payload,
  }) {
    final binding = controllerBinding;
    if (binding == null ||
        !_validDeviceId(peerDeviceId) ||
        !binding.matchesEnvelope(
          callId: callId,
          peerId: peerId,
          sourceRevision: binding.sourceRevision,
          peerDeviceId: peerDeviceId,
        )) {
      return;
    }
    final message = RemoteControlProtocol.parse(
      payload,
      RemoteControlWireDirection.controlleeToController,
    );
    if (message == null) return;
    switch (message.type) {
      case RemoteControlWireType.grant:
        if (phase != RemoteControlPhase.requesting ||
            message.fields['sourceRevision'] != binding.sourceRevision) {
          return;
        }
        final capabilities =
            message.fields['capabilities'] as Set<RemoteControlCapability>;
        if (!defaultCapabilities.containsAll(capabilities)) return;
        controllerBinding = binding.copyWith(peerDeviceId: peerDeviceId);
        _token = message.fields['token']! as String;
        _epoch = message.fields['epoch']! as int;
        grantedCapabilities = capabilities;
        _requestTimer?.cancel();
        _requestTimer = null;
        phase = RemoteControlPhase.controlling;
        notice = null;
        _notify();
      case RemoteControlWireType.deny:
        if (phase != RemoteControlPhase.requesting) return;
        _retireController(sendEnd: false);
        phase = RemoteControlPhase.denied;
        notice = _controlDenialNotice(message.fields['reason']);
        _notify();
      case RemoteControlWireType.revoke:
      case RemoteControlWireType.end:
        if (binding.peerDeviceId.isNotEmpty &&
            binding.peerDeviceId != peerDeviceId) {
          return;
        }
        _retireController(sendEnd: false);
        phase = RemoteControlPhase.ended;
        notice = 'Control ended.';
        _notify();
      case RemoteControlWireType.clipboardOffer:
        if (!isControlling) return;
        _observeClipboardOffer(
          binding.copyWith(peerDeviceId: peerDeviceId),
          message,
        );
      case RemoteControlWireType.clipboardData:
        if (!isControlling) return;
        _observeClipboardData(
          binding.copyWith(peerDeviceId: peerDeviceId),
          message,
        );
      case RemoteControlWireType.clipboardAccept:
      case RemoteControlWireType.clipboardReject:
        final id = message.fields['id']! as String;
        if (!_removeOutgoingClipboard(id)) return;
        notice = message.type == RemoteControlWireType.clipboardAccept
            ? 'Clipboard shared.'
            : 'Clipboard was declined.';
        _notify();
      case RemoteControlWireType.request:
      case RemoteControlWireType.input:
        // Direction parser rejects these before this switch.
        return;
    }
  }

  /// Windows controller state. Native has already parsed the strict protocol
  /// and retained token/epoch/sequence; Dart still re-checks the live UI owner.
  void applyNativeControllerState(Map<String, dynamic> data) {
    final binding = controllerBinding;
    if (binding == null) return;
    final callId = _string(data['callId']);
    final peerId = _string(data['peerJamiId']);
    final device = _string(data['peerDeviceId']);
    final revision = _integer(data['sourceRevision']);
    final state = _string(data['state']);
    // The local "requesting" projection is emitted before any authenticated
    // peer response exists, so it intentionally has no device id yet. It may
    // confirm only the exact locally-requested call/source tuple.
    if (state == 'requesting') {
      if (phase == RemoteControlPhase.requesting &&
          binding.matchesEnvelope(
            callId: callId,
            peerId: peerId,
            sourceRevision: revision,
          )) {
        _notify();
      }
      return;
    }
    if (state == 'denied' &&
        device.isEmpty &&
        _string(data['reason']) == 'timeout') {
      if (phase == RemoteControlPhase.requesting &&
          binding.matchesEnvelope(
            callId: callId,
            peerId: peerId,
            sourceRevision: revision,
          )) {
        _retireController(sendEnd: false);
        phase = RemoteControlPhase.denied;
        notice = 'Control request timed out.';
        _notify();
      }
      return;
    }
    if (!_validDeviceId(device) ||
        !binding.matchesEnvelope(
          callId: callId,
          peerId: peerId,
          sourceRevision: revision,
          peerDeviceId: device,
        )) {
      return;
    }
    switch (state) {
      case 'active':
        if (phase != RemoteControlPhase.requesting &&
            phase != RemoteControlPhase.controlling) {
          return;
        }
        final capabilities = _capabilitiesFromBits(
          _integer(data['controlCapabilities']),
        );
        if (capabilities.isEmpty ||
            !defaultCapabilities.containsAll(capabilities)) {
          return;
        }
        controllerBinding = binding.copyWith(peerDeviceId: device);
        grantedCapabilities = capabilities;
        _requestTimer?.cancel();
        _requestTimer = null;
        phase = RemoteControlPhase.controlling;
        notice = null;
        _notify();
      case 'denied':
        if (phase != RemoteControlPhase.requesting) return;
        _retireController(sendEnd: false);
        phase = RemoteControlPhase.denied;
        notice = _controlDenialNotice(_string(data['reason']));
        _notify();
      case 'revoked':
      case 'ended':
        _retireController(sendEnd: false);
        phase = RemoteControlPhase.ended;
        notice = 'Control ended.';
        _notify();
    }
  }

  void applyNativeHostRequest(Map<String, dynamic> data) {
    if (_disposed || !_currentHostEvent(data)) return;
    final available = _availableHostBinding;
    if (available == null) return;
    final callId = _string(data['callId']);
    final controller = _string(data['controllerAccountId']);
    final device = _string(data['controllerDeviceId']);
    final revision = _integer(data['sourceRevision']);
    final generation = _integer(data['hostGeneration']);
    if (controller.isEmpty ||
        !_validDeviceId(device) ||
        generation <= _retiredHostGeneration ||
        controller != available.peerId ||
        !available.matchesEnvelope(
          callId: callId,
          peerId: controller,
          sourceRevision: revision,
        )) {
      return;
    }
    final capabilities = _capabilitiesFromBits(
      _integer(data['controlCapabilities']),
    );
    if (capabilities.isEmpty) return;
    final current = hostRequest;
    if (current != null) {
      // Native event replay may repeat the same receiver generation. Keep the
      // exact object the dialog captured; recreating it would make both
      // buttons safely but needlessly refuse the still-current request.
      return;
    }
    hostRequest = RemoteControlHostRequest(
      binding: available.copyWith(peerDeviceId: device),
      generation: generation,
      controllerAccountId: controller,
      controllerDeviceId: device,
      capabilities: capabilities,
      persistentAvailable: false,
    );
    _hostSessionBinding = hostRequest!.binding;
    _hostSessionGeneration = generation;
    hostPhase = RemoteControlHostPhase.prompting;
    _notify();
  }

  void applyNativeHostState(Map<String, dynamic> data) {
    if (_disposed || !_currentHostEvent(data)) return;
    final state = _string(data['state']);
    final callId = _string(data['callId']);
    final controller = _string(data['controllerAccountId']);
    final device = _string(data['controllerDeviceId']);
    final revision = _integer(data['sourceRevision']);
    final generation = _integer(data['hostGeneration']);
    var binding = _hostSessionBinding ?? hostRequest?.binding;
    // A persistent exact-device grant activates without a prompt. Accept that
    // projection only from the exact currently shareable host envelope.
    if (binding == null && state == 'active') {
      final available = _availableHostBinding;
      if (available != null &&
          available.matchesEnvelope(
            callId: callId,
            peerId: controller,
            sourceRevision: revision,
          )) {
        binding = available.copyWith(peerDeviceId: device);
      }
    }
    if (binding == null ||
        generation <= _retiredHostGeneration ||
        (_hostSessionGeneration != null &&
            _hostSessionGeneration != generation) ||
        !_validDeviceId(device) ||
        !binding.matchesEnvelope(
          callId: callId,
          peerId: controller,
          sourceRevision: revision,
          peerDeviceId: device,
        )) {
      return;
    }
    switch (state) {
      case 'active':
        hostRequest = null;
        _hostSessionBinding = binding.copyWith(peerDeviceId: device);
        _hostSessionGeneration = generation;
        hostPhase = RemoteControlHostPhase.active;
      case 'suspended':
        hostPhase = RemoteControlHostPhase.suspended;
      case 'host-priority':
        hostPhase = RemoteControlHostPhase.hostPriority;
      case 'ended':
      case 'denied':
        _retiredHostGeneration = max(_retiredHostGeneration, generation);
        hostRequest = null;
        _hostSessionBinding = null;
        _hostSessionGeneration = null;
        _clearPendingNativeClipboardApply();
        hostPhase = _transport.nativeHostAuthority
            ? RemoteControlHostPhase.revoking
            : RemoteControlHostPhase.idle;
        // Don't carry one session's kill-switch answer into the next; back to
        // "unanswered", not to a claim in either direction.
        hotkeyAvailable = null;
        coControl = false;
      case 'arbitration':
        coControl = _boolean(data['coControl']);
      default:
        return;
    }
    if (data.containsKey('coControl')) {
      coControl = _boolean(data['coControl']);
    }
    // Native attaches hotkeyAvailable only on lifecycle emissions; takeover and
    // arbitration events omit it. A missing key means "unchanged", never "true".
    if (data.containsKey('hotkeyAvailable')) {
      hotkeyAvailable = _boolean(data['hotkeyAvailable']);
    }
    hostReason = _string(data['reason']);
    _notify();
  }

  bool get _mayShowClipboardRequest =>
      clipboardRequest == null && _clipboardDecisionInFlight == null;

  bool _currentHostEvent(Map<String, dynamic> data) =>
      !_transport.nativeHostAuthority ||
      (_nativeHostReady &&
          data['channelEpoch'] == _hostAuthority?.channelEpoch &&
          data['surfaceRevision'] == _hostSurfaceRevision);

  int _freshClipboardPromptGeneration() {
    final generation = _nextClipboardPromptGeneration;
    _nextClipboardPromptGeneration = generation == 0x7fffffffffffffff
        ? 1
        : generation + 1;
    return generation;
  }

  /// All ingress paths share this guard: displayed or in-flight prompts cannot
  /// be replaced, even when a peer reuses an ID. Ignored prompts expire on our
  /// clock so they cannot indefinitely block later offers.
  void _showClipboardRequest(RemoteClipboardRequest request) {
    if (!_mayShowClipboardRequest) {
      final shown = _clipboardRequest;
      if (shown?.id != request.id || shown?.generation != request.generation) {
        _declineUnshownClipboard(request);
      }
      return;
    }
    _clipboardRequestTimer?.cancel();
    _clipboardRequest = request;
    _clipboardRequestTimer = Timer(_clipboardTimeout, () {
      if (!identical(_clipboardRequest, request)) return;
      _clipboardRequest = null;
      if (!identical(_clipboardDecisionInFlight, request)) {
        _declineUnshownClipboard(request);
      }
      _notify();
    });
  }

  void _declineUnshownClipboard(RemoteClipboardRequest request) {
    final controller = request.receiver == RemoteClipboardReceiver.controller;
    _bestEffortTeardown(
      'decline clipboard',
      () => _transport.respondToClipboard(
        binding: request.binding,
        promptGeneration: request.generation,
        id: request.id,
        accepted: false,
        asController: controller,
        androidPacket: RemoteControlProtocol.clipboardResponse(
          id: request.id,
          accepted: false,
          direction: controller
              ? RemoteControlWireDirection.controllerToControllee
              : RemoteControlWireDirection.controlleeToController,
        ),
      ),
    );
  }

  void _clearClipboardRequest() {
    _clipboardRequestTimer?.cancel();
    _clipboardRequestTimer = null;
    _clipboardRequest = null;
  }

  void applyNativeClipboardRequest(
    Map<String, dynamic> data, {
    required bool forController,
  }) {
    final binding = forController ? controllerBinding : _availableHostBinding;
    if (binding == null) return;
    final callId = _string(data['callId']);
    final peer = _string(
      data[forController ? 'peerJamiId' : 'controllerAccountId'],
    );
    final device = _string(
      data[forController ? 'peerDeviceId' : 'controllerDeviceId'],
    );
    final revision = forController
        ? _integer(data['sourceRevision'])
        : binding.sourceRevision;
    final id = _string(data['id']);
    final generation = _integer(data['promptGeneration']);
    final text = _string(data['text'], _string(data['preview']));
    final bytes = _integer(data['clipboardBytes']);
    if (!RemoteControlProtocol._validClipboardId(id) ||
        generation <= 0 ||
        !_validDeviceId(device) ||
        !RemoteControlProtocol._validText(
          text,
          RemoteControlProtocol.maxClipboardBytes,
        ) ||
        bytes <= 0 ||
        (forController && bytes != utf8.encode(text).length) ||
        bytes > RemoteControlProtocol.maxClipboardBytes ||
        !binding.matchesEnvelope(
          callId: callId,
          peerId: peer,
          sourceRevision: revision,
          peerDeviceId: device,
        )) {
      return;
    }
    _showClipboardRequest(
      RemoteClipboardRequest(
        binding: binding.copyWith(
          peerDeviceId: device.isEmpty ? binding.peerDeviceId : device,
        ),
        generation: generation,
        id: id,
        text: text,
        receiver: forController
            ? RemoteClipboardReceiver.controller
            : RemoteClipboardReceiver.controllee,
        declaredByteLength: bytes,
      ),
    );
    _notify();
  }

  /// Windows-native outbound clipboard correlation. Native mints the id and
  /// emits a result only after matching it against its bounded session map, so
  /// Dart gates the projection by the exact live role and call rather than a
  /// second, divergent id registry.
  void applyNativeClipboardResult(
    Map<String, dynamic> data, {
    required bool fromHost,
  }) {
    if (!_transport.nativeClipboardCorrelation) return;
    final binding = fromHost ? _hostSessionBinding : controllerBinding;
    if (binding == null ||
        (fromHost ? !hostActive : !isControlling) ||
        _string(data['callId']) != binding.callId) {
      return;
    }
    final id = _string(data['id']);
    final state = _string(data['state']);
    if (!RemoteControlProtocol._validClipboardId(id) ||
        (state != 'accepted' && state != 'rejected')) {
      return;
    }
    notice = switch ((state, _string(data['reason']))) {
      ('accepted', _) => 'Clipboard shared.',
      ('rejected', 'timeout') => 'Clipboard response timed out.',
      _ => 'Clipboard was declined.',
    };
    _notify();
  }

  /// Result of applying an inbound clipboard to the Windows host OS. This is
  /// deliberately separate from outbound sharing: the id belongs to the
  /// consent request that Dart just accepted, not an outbound transfer.
  void applyNativeClipboardApplyResult(Map<String, dynamic> data) {
    final id = _string(data['id']);
    final generation = _integer(data['promptGeneration']);
    final binding = _pendingNativeClipboardApplyBinding;
    if (binding == null ||
        id != _pendingNativeClipboardApplyId ||
        generation != _pendingNativeClipboardApplyGeneration ||
        (data.containsKey('callId') &&
            _string(data['callId']) != binding.callId)) {
      return;
    }
    _clearPendingNativeClipboardApply();
    if (_string(data['state']) == 'rejected') {
      notice = _string(data['reason']) == 'os-failure'
          ? 'Windows could not apply the clipboard.'
          : 'Clipboard was not applied.';
    }
    _notify();
  }

  void _rejectClipboardOffer(RemoteControlBinding binding, String id) {
    _bestEffortTeardown(
      'reject busy clipboard',
      () => _transport.respondToClipboard(
        binding: binding,
        promptGeneration: _freshClipboardPromptGeneration(),
        id: id,
        accepted: false,
        asController: true,
        androidPacket: RemoteControlProtocol.clipboardResponse(
          id: id,
          accepted: false,
          direction: RemoteControlWireDirection.controllerToControllee,
        ),
      ),
    );
  }

  void _observeClipboardOffer(
    RemoteControlBinding binding,
    RemoteControlWireMessage message,
  ) {
    final offeredId = message.fields['id']! as String;
    if (!grantedCapabilities.contains(RemoteControlCapability.clipboard)) {
      return;
    }
    if (_observedClipboardIds.contains(offeredId)) return;
    if (_observedClipboardIds.length >= 64) {
      _rejectClipboardOffer(binding, offeredId);
      return;
    }
    _observedClipboardIds.add(offeredId);
    if (!_mayShowClipboardRequest || _pendingClipboardWire != null) {
      _rejectClipboardOffer(binding, offeredId);
      return;
    }
    final pending = _PendingClipboardWire(
      binding: binding,
      id: offeredId,
      sha256Hex: message.fields['sha256']! as String,
      size: message.fields['size']! as int,
    );
    pending.timeout = Timer(_clipboardTimeout, () {
      if (identical(_pendingClipboardWire, pending)) {
        _pendingClipboardWire = null;
      }
    });
    _pendingClipboardWire = pending;
  }

  void _observeClipboardData(
    RemoteControlBinding binding,
    RemoteControlWireMessage message,
  ) {
    final pending = _pendingClipboardWire;
    final id = message.fields['id']! as String;
    final hash = message.fields['sha256']! as String;
    final text = message.fields['text']! as String;
    final bytes = utf8.encode(text);
    if (pending == null ||
        !pending.binding.sameSource(binding) ||
        pending.id != id ||
        pending.sha256Hex != hash ||
        pending.size != bytes.length ||
        sha256.convert(bytes).toString() != hash) {
      return;
    }
    pending.timeout?.cancel();
    _pendingClipboardWire = null;
    _showClipboardRequest(
      RemoteClipboardRequest(
        binding: binding,
        generation: _freshClipboardPromptGeneration(),
        id: id,
        text: text,
        receiver: RemoteClipboardReceiver.controller,
      ),
    );
    _notify();
  }

  void _discrete(RemoteInputEvent event) {
    if (!isControlling) return;
    final batch = <RemoteInputEvent>[];
    final move = _takePendingMove();
    if (move != null) batch.add(move);
    batch.add(event);
    _enqueue(batch);
  }

  RemoteMoveEvent? _takePendingMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final move = _pendingMove;
    _pendingMove = null;
    return move;
  }

  void _flushMove() {
    _moveTimer = null;
    final move = _pendingMove;
    _pendingMove = null;
    if (move != null && isControlling) _enqueue(<RemoteInputEvent>[move]);
  }

  void _enqueue(List<RemoteInputEvent> events) {
    if (!isControlling || events.isEmpty) return;
    if (events.length > RemoteControlProtocol.maxInputEvents ||
        _sendQueue.length >= _maxQueuedBatches) {
      unawaited(stopControlling(reason: 'queue-overflow'));
      notice = 'Control stopped because the connection could not keep up.';
      _notify();
      return;
    }
    _sendQueue.add(List.unmodifiable(events));
    _drain();
  }

  void _drain() {
    if (_draining || _sendQueue.isEmpty || !isControlling) return;
    _draining = true;
    final generation = _generation;
    unawaited(() async {
      try {
        while (!_disposed &&
            generation == _generation &&
            isControlling &&
            _sendQueue.isNotEmpty) {
          final binding = controllerBinding;
          if (binding == null) break;
          final events = _sendQueue.removeFirst();
          late final String packet;
          try {
            if (_token.isEmpty) {
              packet = '';
            } else {
              final nextSequence = _sequence + 1;
              packet = RemoteControlProtocol.input(
                token: _token,
                epoch: _epoch,
                sequence: nextSequence,
                sourceRevision: binding.sourceRevision,
                events: events,
              );
              _sequence = nextSequence;
            }
          } on ArgumentError {
            await stopControlling(reason: 'invalid-input');
            notice = 'Control ended because an input was invalid.';
            _notify();
            break;
          }
          bool sent;
          try {
            sent = await _transport.input(binding, events, packet);
          } catch (_) {
            sent = false;
          }
          if (!sent && generation == _generation && isControlling) {
            await stopControlling(reason: 'send-failed');
            notice = 'Control ended because input could not be sent.';
            _notify();
            break;
          }
        }
      } finally {
        _draining = false;
        if (_sendQueue.isNotEmpty && isControlling) _drain();
      }
    }());
  }

  void _retireController({required bool sendEnd, String? reason}) {
    final binding = controllerBinding;
    _generation++;
    _requestTimer?.cancel();
    _requestTimer = null;
    _moveTimer?.cancel();
    _moveTimer = null;
    _pendingMove = null;
    _heldKeys.clear();
    _textTimer?.cancel();
    _textTimer = null;
    _pendingText = '';
    _heldButtons.clear();
    _sendQueue.clear();
    _pendingClipboardWire?.timeout?.cancel();
    _pendingClipboardWire = null;
    _observedClipboardIds.clear();
    // A controllee-side prompt survives controller retirement (it belongs to
    // the other direction); anything else goes, timer included.
    if (clipboardRequest?.receiver != RemoteClipboardReceiver.controllee) {
      _clearClipboardRequest();
    }
    _clearOutgoingClipboards();
    _token = '';
    _epoch = 0;
    _sequence = 0;
    grantedCapabilities = const {};
    controllerBinding = null;
    phase = reason == null ? RemoteControlPhase.idle : RemoteControlPhase.ended;
    if (sendEnd && binding != null) {
      _bestEffortTeardown(
        'end stale controller session',
        () => _transport.end(
          binding,
          RemoteControlProtocol.end(
            RemoteControlWireDirection.controllerToControllee,
          ),
        ),
      );
    }
  }

  void _bestEffortTeardown(String operation, Future<bool> Function() action) {
    unawaited(() async {
      try {
        if (!await action()) {
          debugPrint('[remote-control] $operation was rejected');
        }
      } catch (error) {
        debugPrint('[remote-control] operation failed');
      }
    }());
  }

  Set<RemoteControlCapability> _capabilitiesFromBits(int bits) {
    final knownBits = RemoteControlCapability.values.fold<int>(
      0,
      (value, capability) => value | capability.bit,
    );
    if (bits <= 0 || (bits & ~knownBits) != 0) return const {};
    return {
      for (final capability in RemoteControlCapability.values)
        if ((bits & capability.bit) != 0) capability,
    };
  }

  String _randomHex(int bytes) {
    final result = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      result.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return result.toString();
  }

  double _round(double value) => (value * 100000).roundToDouble() / 100000;

  String _string(Object? value, [String fallback = '']) =>
      value is String ? value : fallback;
  int _integer(Object? value) =>
      value is int ? value : int.tryParse('$value') ?? 0;
  bool _boolean(Object? value) => value == true || value?.toString() == 'true';
  bool _validDeviceId(String value) => _deviceIdPattern.hasMatch(value);

  bool _removeOutgoingClipboard(String id) {
    final timer = _outgoingClipboardIds.remove(id);
    timer?.cancel();
    return timer != null;
  }

  void _clearOutgoingClipboards() {
    for (final timer in _outgoingClipboardIds.values) {
      timer.cancel();
    }
    _outgoingClipboardIds.clear();
  }

  void _clearPendingNativeClipboardApply() {
    _pendingNativeClipboardApplyId = null;
    _pendingNativeClipboardApplyGeneration = null;
    _pendingNativeClipboardApplyBinding = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _hostLeaseTimer?.cancel();
    _hostLeaseTimer = null;
    _hostLeaseTimeout?.cancel();
    _hostLeaseTimeout = null;
    if (_transport.nativeHostAuthority) {
      _hostDesiredBlocked = true;
      _hostChannelFailed = true;
      if (_hostAuthority != null) unawaited(_setHostSurface(true));
    }
    _disposed = true;
    _generation++;
    _requestTimer?.cancel();
    _moveTimer?.cancel();
    _textTimer?.cancel();
    _pendingText = '';
    _pendingClipboardWire?.timeout?.cancel();
    _clipboardRequestTimer?.cancel();
    _heldKeys.clear();
    _heldButtons.clear();
    _clearOutgoingClipboards();
    _clearPendingNativeClipboardApply();
    _sendQueue.clear();
    super.dispose();
  }
}
