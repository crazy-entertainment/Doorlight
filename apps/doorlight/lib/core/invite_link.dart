import 'dart:convert';

import 'jami_identity.dart';

/// An untrusted, personalized friend-invite hint.
///
/// Opening one may prefill the Add friend dialog, but never mutates trust.
/// The recipient must still confirm the exact public Jami fingerprint.
final class SyblInviteLink {
  const SyblInviteLink({required this.jamiId, this.displayName = ''});

  static const int maxLinkCharacters = 1024;
  static const int maxDisplayNameUtf8Bytes = 64;
  static const configuredHttpsOrigin = String.fromEnvironment(
    'DOORLIGHT_INVITE_ORIGIN',
  );

  final String jamiId;
  final String displayName;

  Uri get uri => Uri(
    scheme: 'sybl',
    host: 'add',
    pathSegments: [jamiId],
    queryParameters: displayName.isEmpty ? null : {'name': displayName},
  );

  String get canonicalUri => uri.toString();

  /// Only release-configured origins are trusted as invitation wrappers.
  /// The fragment is public display material, never a friendship grant.
  String shareUri({String httpsOrigin = configuredHttpsOrigin}) {
    final origin = _httpsOrigin(httpsOrigin);
    if (origin == null) return canonicalUri;
    final fields = Uri(
      queryParameters: {
        'v': '1',
        'id': jamiId,
        if (displayName.isNotEmpty) 'name': displayName,
      },
    ).query;
    return origin.replace(path: '/invite/', fragment: fields).toString();
  }

  static Uri? _httpsOrigin(String value) {
    if (value.isEmpty || value.length > 300) return null;
    final parsed = Uri.tryParse(value);
    if (parsed == null ||
        parsed.scheme != 'https' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasPort ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        parsed.host.length > 253 ||
        parsed.host
            .split('.')
            .any(
              (label) =>
                  label.length > 63 ||
                  !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
            ) ||
        (value != parsed.origin && value != '${parsed.origin}/')) {
      return null;
    }
    return parsed.replace(path: '');
  }

  static SyblInviteLink? create({
    required String jamiId,
    required String displayName,
  }) {
    final fingerprint = JamiIdentity.fingerprint(jamiId);
    if (fingerprint == null) return null;
    return SyblInviteLink(
      jamiId: fingerprint,
      displayName: _decodeDisplayName(displayName),
    );
  }

  static SyblInviteLink? tryParse(
    Object? value, {
    String httpsOrigin = configuredHttpsOrigin,
  }) {
    if (value is! String ||
        value.isEmpty ||
        value.length > maxLinkCharacters ||
        RegExp(r'[\x00-\x20\x7f]|%(?![0-9a-fA-F]{2})').hasMatch(value)) {
      return null;
    }
    try {
      final parsed = Uri.parse(value);
      if (parsed.scheme == 'https') {
        final origin = _httpsOrigin(httpsOrigin);
        if (origin == null ||
            parsed.origin != origin.origin ||
            parsed.userInfo.isNotEmpty ||
            parsed.hasPort ||
            parsed.path != '/invite/' ||
            parsed.hasQuery ||
            !parsed.hasFragment) {
          return null;
        }
        // Reuse the custom-URI parser's duplicate/unknown field and UTF-8 checks.
        if (parsed.fragment.split('&').any((field) => !field.contains('='))) {
          return null;
        }
        final fields = Uri(query: parsed.fragment).queryParametersAll;
        if (fields['v']?.length != 1 ||
            fields['v']?.single != '1' ||
            fields['id']?.length != 1 ||
            fields.keys.any(
              (key) => !const {'v', 'id', 'name'}.contains(key),
            ) ||
            (fields['name']?.length ?? 0) > 1) {
          return null;
        }
        final rawId = fields['id']!.single;
        if (!RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(rawId)) return null;
        final fingerprint = JamiIdentity.fingerprint(rawId);
        if (fingerprint == null) return null;
        return SyblInviteLink(
          jamiId: fingerprint,
          displayName: _decodeDisplayName(fields['name']?.single ?? ''),
        );
      }
      return _parseUri(parsed);
    } on FormatException {
      // URI components decode lazily, including malformed UTF-8 in queries.
      return null;
    }
  }

  static SyblInviteLink? _parseUri(Uri parsed) {
    if ((parsed.scheme != 'sybl' && parsed.scheme != 'doorlight') ||
        parsed.host != 'add' ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasPort ||
        parsed.hasFragment ||
        parsed.pathSegments.length != 1) {
      return null;
    }
    final fingerprint = JamiIdentity.fingerprint(parsed.pathSegments.single);
    if (fingerprint == null) return null;
    final allowedKeys = parsed.queryParametersAll.keys.toSet();
    final names = parsed.queryParametersAll['name'];
    if (allowedKeys.difference(const {'name'}).isNotEmpty ||
        (names != null && names.length > 1)) {
      return null;
    }
    return SyblInviteLink(
      jamiId: fingerprint,
      displayName: _decodeDisplayName(parsed.queryParameters['name'] ?? ''),
    );
  }

  static String _decodeDisplayName(String value) {
    if (value.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return '';
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        utf8.encode(trimmed).length > maxDisplayNameUtf8Bytes) {
      return '';
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is SyblInviteLink &&
      other.jamiId == jamiId &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(jamiId, displayName);
}
