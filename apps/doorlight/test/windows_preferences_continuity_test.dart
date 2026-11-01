import 'dart:convert';
import 'dart:io' as io;

import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

import '../third_party/shared_preferences_windows/test/legacy_shared_preferences_windows_test.dart'
    as legacy;
import '../third_party/shared_preferences_windows/test/shared_preferences_windows_async_test.dart'
    as modern;
import '../third_party/shared_preferences_windows/test/atomic_preferences_test.dart'
    as atomic;

class _RenamedProductPaths extends PathProviderWindows {
  _RenamedProductPaths({this.available = true});
  final bool available;

  @override
  Future<String?> getApplicationSupportPath() async =>
      throw StateError('The product-name-derived path must never be queried');

  @override
  Future<String> getPath(String folderID) async {
    expect(folderID, '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}');
    return available ? r'C:\fixture\Roaming' : '';
  }
}

void main() {
  group('upstream legacy preferences', legacy.main);
  group('upstream async preferences', modern.main);
  group('atomic preferences', atomic.main);

  test(
    'Windows canonical lease blocks replacement without damaging settings',
    () async {
      final parent = io.Directory('../../local/tmp')..createSync(recursive: true);
      final fixture = parent.createTempSync('preferences-lease-test-');
      final canonical = io.File(
        '${fixture.path}/app.sybl/sybl/shared_preferences.json',
      );
      canonical.parent.createSync(recursive: true);
      const original = '{"flutter.lock":true}';
      canonical.writeAsStringSync(original, flush: true);
      io.Process? holder;
      try {
        holder = await io.Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '\$file = [IO.File]::Open(\$env:DOORLIGHT_TEST_PREFS, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read); '
                'try { [Console]::WriteLine("READY"); [Console]::Out.Flush(); while (!(Test-Path -LiteralPath \$env:DOORLIGHT_TEST_RELEASE)) { Start-Sleep -Milliseconds 50 } } finally { \$file.Dispose() }',
          ],
          environment: {
            'DOORLIGHT_TEST_PREFS': canonical.absolute.path,
            'DOORLIGHT_TEST_RELEASE': '${fixture.absolute.path}/release',
          },
        );
        final stderr = holder.stderr.transform(utf8.decoder).join();
        expect(
          await holder.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 15)),
          'READY',
        );
        final adapter = SharedPreferencesWindows()
          ..pathProvider = atomic.FixturePaths(fixture.absolute.path);
        expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
        expect(canonical.readAsStringSync(), original);
        io.File('${fixture.path}/release').writeAsStringSync('release');
        expect(await holder.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await stderr, isEmpty);
        holder = null;
        expect(await adapter.setValue('Bool', 'flutter.lock', false), true);
        expect(jsonDecode(canonical.readAsStringSync())['flutter.lock'], false);
      } finally {
        if (holder != null) {
          holder.kill();
          await holder.exitCode;
        }
        fixture.deleteSync(recursive: true);
      }
    },
    skip: !io.Platform.isWindows,
  );

  test('rebrand reads and updates the exact legacy preferences file', () async {
    final fs = MemoryFileSystem(style: FileSystemStyle.windows);
    final file =
        fs.file(r'C:\fixture\Roaming\app.sybl\sybl\shared_preferences.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'flutter.existingSetting': 'kept',
              'flutter.lockLatch': true,
            }),
          );
    final adapter = SharedPreferencesWindows()
      ..fs = fs
      ..pathProvider = _RenamedProductPaths();
    expect(await adapter.getAll(), {
      'flutter.existingSetting': 'kept',
      'flutter.lockLatch': true,
    });
    expect(
      await adapter.setValue('String', 'flutter.newSetting', 'saved'),
      isTrue,
    );
    final reloaded = SharedPreferencesWindows()
      ..fs = fs
      ..pathProvider = _RenamedProductPaths();
    expect((await reloaded.getAll())['flutter.existingSetting'], 'kept');
    expect(jsonDecode(file.readAsStringSync())['flutter.lockLatch'], isTrue);
    expect(
      fs.directory(r'C:\fixture\Roaming\app.sybl\Doorlight').existsSync(),
      isFalse,
    );
  });

  test(
    'missing Windows known folder never creates a fallback preference file',
    () async {
      final fs = MemoryFileSystem(style: FileSystemStyle.windows);
      final adapter = SharedPreferencesWindows()
        ..fs = fs
        ..pathProvider = _RenamedProductPaths(available: false);
      expect(await adapter.setValue('String', 'flutter.key', 'value'), isFalse);
      expect(fs.directory('C:\\').listSync(recursive: true), isEmpty);
    },
  );
}
