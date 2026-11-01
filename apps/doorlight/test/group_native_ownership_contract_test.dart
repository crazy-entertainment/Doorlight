import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

String _part(String source, String start, String end) {
  final from = source.indexOf(start);
  expect(from, isNonNegative);
  final to = source.indexOf(end, from + start.length);
  expect(to, greaterThan(from));
  return source.substring(from, to);
}

void main() {
  final core = File(
    'android/app/src/main/kotlin/app/sybl/sybl/JamiCore.kt',
  ).readAsStringSync();
  final activity = File(
    'android/app/src/main/kotlin/app/sybl/sybl/MainActivity.kt',
  ).readAsStringSync();
  final bridge = File('windows/runner/jami_bridge.cpp').readAsStringSync();
  final channels = File('windows/runner/jami_channels.cpp').readAsStringSync();
  final commands = [
    'createGroup',
    'addGroupMembers',
    'removeGroupMember',
    'renameGroup',
    'updateGroupLayout',
    'leaveGroup',
  ];
  for (var i = 0; i < commands.length; i++) {
    final name = commands[i];
    final next = i + 1 < commands.length
        ? commands[i + 1]
        : 'setPresenceSubscriptions';
    final nativeName = name[0].toUpperCase() + name.substring(1);
    final nativeNext = next[0].toUpperCase() + next.substring(1);
    test(
      '$name captures before queuing and checks ownership before native mutation',
      () {
        final dispatch = _part(activity, '"$name" -> {', '"$next" -> {');
        final capture = dispatch.indexOf(
          'JamiCore.captureAccountScope(call.argument<String>("expectedAccountId"))',
        );
        expect(capture, isNonNegative);
        expect(capture, lessThan(dispatch.indexOf('JamiCore.submit(')));
        expect(dispatch, contains(', scope)'));
        final operation = _part(core, 'fun $name(', 'fun $next(');
        expect(operation, contains('accountAuthority.owns(scope)'));
        expect(operation, contains('scope?.accountId'));
        expect(
          operation.indexOf('accountAuthority.owns(scope)'),
          lessThan(operation.indexOf('JamiService.')),
        );
        expect(operation, isNot(contains('val acc = accountId')));

        final windows = _part(
          bridge,
          'void $nativeName(',
          i == commands.length - 1
              ? '// presence v2 zombie-janitor:'
              : 'void $nativeNext(',
        );
        expect(
          windows.indexOf('CaptureAccountCommandOwner(expectedAccountId)'),
          isNonNegative,
        );
        expect(
          windows.indexOf('CaptureAccountCommandOwner(expectedAccountId)'),
          lessThan(windows.indexOf('Post(')),
        );
        expect(windows, contains('owner = *owner'));
        expect(windows, contains('OwnsAccountCommand(owner)'));
        expect(windows, isNot(contains('CurrentAccountId()')));
        final platform = _part(
          channels,
          'method == "$name"',
          'method == "$next"',
        );
        expect(platform, contains('ArgExpectedAccountId(call)'));
      },
    );
  }
}
