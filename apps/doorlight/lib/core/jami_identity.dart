/// Parsing and presentation rules for the Jami public-key fingerprint used by
/// Syb-L's account-sharing surfaces.
///
/// Jami's canonical URI form is `jami:<40 lowercase hexadecimal characters>`.
/// The UI also accepts a bare fingerprint because that is what Jami commonly
/// exposes for copying. Registered Jami names are intentionally not accepted:
/// resolving them belongs to libjami, and Syb-L does not currently expose that
/// daemon API.
abstract final class JamiIdentity {
  static final RegExp _fingerprintPattern = RegExp(r'^[0-9a-f]{40}$');

  /// Returns the normalized 40-character fingerprint, or `null` when [input]
  /// is neither a bare fingerprint nor a canonical Jami URI.
  static String? fingerprint(String input) {
    final candidate = input.trim().toLowerCase();
    final withoutScheme = candidate.startsWith('jami:')
        ? candidate.substring('jami:'.length)
        : candidate;
    return _fingerprintPattern.hasMatch(withoutScheme) ? withoutScheme : null;
  }

  /// Returns the canonical Jami URI for [input], or `null` when it is invalid.
  static String? canonicalUri(String input) {
    final normalized = fingerprint(input);
    return normalized == null ? null : 'jami:$normalized';
  }
}
