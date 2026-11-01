import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami_identity.dart';

void main() {
  const fingerprint = 'abcdef0123456789abcdef0123456789abcdef01';

  test('normalizes bare fingerprints and canonical Jami URIs', () {
    expect(JamiIdentity.fingerprint(fingerprint), fingerprint);
    expect(
      JamiIdentity.fingerprint('  JAMI:${fingerprint.toUpperCase()}  '),
      fingerprint,
    );
    expect(JamiIdentity.canonicalUri(fingerprint), 'jami:$fingerprint');
  });

  test('rejects names, partial fingerprints, and decorated URIs', () {
    expect(JamiIdentity.fingerprint('mara'), isNull);
    expect(JamiIdentity.fingerprint(fingerprint.substring(1)), isNull);
    expect(JamiIdentity.fingerprint('jami:$fingerprint?device=1'), isNull);
    expect(JamiIdentity.fingerprint('<jami:$fingerprint>'), isNull);
    expect(JamiIdentity.fingerprint('jami:$fingerprint/path'), isNull);
  });
}
