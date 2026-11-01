import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native pairing diagnostics never interpolate peer material', () {
    const root = '../../native/jami/src/jamidht';
    for (final file in [
      'archive_account_pairing.cpp',
      'device_pairing_wire.h',
      'device_pairing_commitment.h',
    ]) {
      final source = File('$root/$file').readAsStringSync();
      expect(
        RegExp(r'JAMI_(?:DEBUG|LOG|WARNING|ERROR)\(').hasMatch(source),
        isFalse,
        reason: 'Wire handlers must not log their private payloads',
      );
    }
    final account = File('$root/jamiaccount.cpp').readAsStringSync();
    final pairing =
        account.substring(
          account.indexOf('JamiAccount::addDevice('),
          account.indexOf('JamiAccount::cancelAddDevice('),
        ) +
        File('$root/auth_channel_handler.cpp').readAsStringSync() +
        File('$root/accountarchive.cpp').readAsStringSync();
    final logCalls = RegExp(
      r'JAMI_(?:DEBUG|LOG|WARNING|ERROR)\([\s\S]*?\);',
    ).allMatches(pairing);
    expect(logCalls, isNotEmpty);
    final sensitiveExpressions = RegExp(
      r'\b(?:msgKey|msgVal|uriProvided|peerTempAcc|peerCodeS|'
      r'accountScheme|authScheme|credentialsFromUser|accData|password|'
      r'name|token|key|err)\b|\.what\(\)|->name\(\)',
    );
    for (final match in logCalls) {
      // Literal diagnostic wording is harmless; inspect interpolated values.
      final arguments = match
          .group(0)!
          .replaceAll(RegExp(r'"(?:\\.|[^"\\])*"'), '""');
      expect(
        sensitiveExpressions.hasMatch(arguments),
        isFalse,
        reason: 'Pairing diagnostic exposes private or peer-controlled data',
      );
    }
  });
}
