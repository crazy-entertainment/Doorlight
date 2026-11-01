import 'dart:convert';
import 'dart:typed_data';

import '../core/jami_identity.dart';

/// Doorlight's own LAN discovery wire format. Jami's built-in LAN discovery
/// cannot be toggled without re-registering the account, so Nearby announces
/// over a separate UDP multicast group instead.
abstract final class NearbyProtocol {
  static const String group = '239.255.68.76';
  static const int port = 47321;
  static const int version = 1;
  static const int maxDatagramBytes = 512;
  static const int maxNameChars = 64;

  static const Set<String> _announcementKeys = {'doorlight', 'id', 'name'};
  static const Set<String> _byeKeys = {'doorlight', 'id', 'bye'};
  static const Set<String> _missileKeys = {
    'doorlight',
    'id',
    'at',
    'missile',
    'lvl',
  };

  /// A missile's damage, in thousandths of the full visibility window.
  static const int minMissile = 200;
  static const int maxMissile = 550;

  /// A missile's charge level; the sender's roll is capped by it.
  static const int maxLevel = 6;
  static int maxMissileAt(int level) => 250 + 50 * level;

  static bool validMissile(int permille, int level) =>
      level >= 0 &&
      level <= maxLevel &&
      permille >= minMissile &&
      permille <= maxMissileAt(level);

  /// Encodes an announcement, or returns `null` when [id] is not a canonical
  /// fingerprint. [name] is sanitized the same way the decoder validates it.
  /// A [ping] marks a deliberate sonar the receiver should always show.
  static Uint8List? encodeAnnouncement(
    String id,
    String name, {
    bool ping = false,
  }) {
    if (JamiIdentity.fingerprint(id) != id) return null;
    final bytes = utf8.encode(
      jsonEncode({
        'doorlight': version,
        'id': id,
        'name': sanitizeName(name),
        if (ping) 'ping': true,
      }),
    );
    return bytes.length > maxDatagramBytes ? null : bytes;
  }

  static Uint8List? encodeBye(String id) {
    if (JamiIdentity.fingerprint(id) != id) return null;
    return utf8.encode(
      jsonEncode({'doorlight': version, 'id': id, 'bye': true}),
    );
  }

  /// Encodes a Sonar missile from [id] at [at], or returns `null` for a
  /// non-canonical id, a self-target, or damage outside [level]'s bounds.
  static Uint8List? encodeMissile(
    String id,
    String at,
    int permille,
    int level, {
    String? nonce,
  }) {
    if (JamiIdentity.fingerprint(id) != id ||
        JamiIdentity.fingerprint(at) != at ||
        at == id ||
        !validMissile(permille, level) ||
        (nonce != null && !_validNonce(nonce))) {
      return null;
    }
    return utf8.encode(
      jsonEncode({
        'doorlight': version,
        'id': id,
        'at': at,
        'missile': permille,
        'lvl': level,
        'nonce': ?nonce,
      }),
    );
  }

  /// Strips forbidden characters, trims, and truncates to [maxNameChars].
  static String sanitizeName(String name) {
    final cleaned = String.fromCharCodes(
      name.runes.where((rune) => !_isForbidden(rune)),
    ).trim();
    final runes = cleaned.runes.toList();
    return runes.length <= maxNameChars
        ? cleaned
        : String.fromCharCodes(runes.take(maxNameChars)).trim();
  }

  /// Strict decoder for untrusted LAN input. Returns `null` for anything that
  /// is not exactly a current-version announcement, bye or missile; never
  /// throws.
  static NearbyPacket? decode(List<int> datagram) {
    if (datagram.isEmpty || datagram.length > maxDatagramBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(datagram));
      if (value is! Map<String, dynamic>) return null;
      final version = value['doorlight'];
      if (version is! int || version != NearbyProtocol.version) return null;
      final id = value['id'];
      if (id is! String || JamiIdentity.fingerprint(id) != id) return null;
      final keys = value.keys.toSet();
      if (keys.length == _byeKeys.length && keys.containsAll(_byeKeys)) {
        return value['bye'] == true ? NearbyBye(id) : null;
      }
      final missileKeys = {...keys}..remove('nonce');
      if (missileKeys.length == _missileKeys.length &&
          missileKeys.containsAll(_missileKeys)) {
        final at = value['at'];
        final permille = value['missile'];
        final level = value['lvl'];
        final nonce = value['nonce'];
        if (at is! String ||
            JamiIdentity.fingerprint(at) != at ||
            at == id ||
            permille is! int ||
            level is! int ||
            !validMissile(permille, level) ||
            (keys.contains('nonce') &&
                (nonce is! String || !_validNonce(nonce)))) {
          return null;
        }
        return NearbyMissile(id, at, permille, level, nonce: nonce as String?);
      }
      final ping = keys.remove('ping') && value['ping'] == true;
      if (keys.length != _announcementKeys.length ||
          !keys.containsAll(_announcementKeys) ||
          (value.containsKey('ping') && !ping)) {
        return null;
      }
      final rawName = value['name'];
      if (rawName is! String || rawName.runes.any(_isForbidden)) return null;
      final name = rawName.trim();
      if (name.runes.length > maxNameChars) return null;
      return NearbyAnnouncement(id, name, ping: ping);
    } on Object {
      return null;
    }
  }

  static bool _validNonce(String value) =>
      RegExp(r'^[0-9a-f]{16}$').hasMatch(value);

  /// C0/C1 controls, DEL, and bidirectional formatting characters that could
  /// reorder or hide surrounding UI text.
  static bool _isForbidden(int rune) =>
      rune < 0x20 ||
      (rune >= 0x7f && rune <= 0x9f) ||
      rune == 0x061c ||
      rune == 0x200e ||
      rune == 0x200f ||
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2066 && rune <= 0x2069);
}

sealed class NearbyPacket {
  const NearbyPacket(this.id);
  final String id;
}

final class NearbyAnnouncement extends NearbyPacket {
  const NearbyAnnouncement(super.id, this.name, {this.ping = false});
  final String name;
  final bool ping;
}

final class NearbyBye extends NearbyPacket {
  const NearbyBye(super.id);
}

/// Someone fired at [at]; [permille] of the full window is lost on impact.
/// The charge [level] sets the flight time on both ends.
final class NearbyMissile extends NearbyPacket {
  const NearbyMissile(
    super.id,
    this.at,
    this.permille,
    this.level, {
    this.nonce,
  });
  final String at;
  final int permille;
  final int level;
  final String? nonce;
}
