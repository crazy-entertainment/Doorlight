import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/diagnostic_label.dart';

void main() {
  test('diagnostic status precedence and prefixes use fixed categories', () {
    expect(
      diagnosticLabel('→ answerCall rejected: private'),
      '→ answerCall rejected',
    );
    expect(
      diagnosticLabel('· incomingCall refusal: private'),
      '· incomingCall rejected',
    );
    expect(
      diagnosticLabel('answerCall rejected then failed: private'),
      'answerCall failed',
    );
    expect(
      diagnosticLabel('answerCall refusal with error: private'),
      'answerCall failed',
    );
    expect(
      diagnosticLabel('→ unknownOperation failed: private'),
      'Diagnostic event',
    );
    expect(
      diagnosticLabel('· unknownOperation rejected: private'),
      'Diagnostic event',
    );
  });

  test('diagnostics never retain identifiers, paths or exception payloads', () {
    final secret = 'private' * 6;
    for (final message in [
      'answerCall($secret) failed: /private/user/photo.png',
      '→ probe($secret) id=private-message',
      'glare: winner $secret; retired incoming=private-peer',
      'fileInfo($secret) failed: bearer $secret',
      '· wakeCapability handle=$secret',
      '$secret failed',
      'boot failed: secret\n→ placeCall secret',
    ]) {
      final label = diagnosticLabel(message);
      expect(label, isNot(contains(secret)));
      expect(label, isNot(contains('private')));
      expect(label, isNot(contains('secret')));
      expect(label, isNot(contains('\n')));
    }
    expect(
      diagnosticLabel('answerCall(private) failed: private'),
      'answerCall failed',
    );
    expect(diagnosticLabel('→ probe(private) id=private'), '→ probe');
    expect(
      diagnosticLabel('· wakeCapability handle=private'),
      '· wakeCapability',
    );
    expect(diagnosticLabel(''), 'Diagnostic event');
  });
}
