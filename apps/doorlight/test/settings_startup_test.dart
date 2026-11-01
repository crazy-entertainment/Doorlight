import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file/memory.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:sybl/ui/settings_startup.dart';

class _StartupPaths extends PathProviderWindows {
  String root = '';
  @override
  Future<String> getPath(String folderID) async => root;
}

void main() {
  testWidgets(
    'unavailable Windows location blocks private startup and permits retry',
    (tester) async {
      SharedPreferences.resetStatic();
      final previous = SharedPreferencesStorePlatform.instance;
      final paths = _StartupPaths();
      final fs = MemoryFileSystem(style: FileSystemStyle.windows);
      fs.file(r'C:\fixture\app.sybl\sybl\shared_preferences.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"flutter.retained":"yes"}');
      SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
        ..fs = fs
        ..pathProvider = paths;
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = previous;
      });
      var builds = 0;
      await tester.pumpWidget(
        SettingsStartup(
          load: SharedPreferences.getInstance,
          readyBuilder: (prefs) {
            builds++;
            expect(prefs.getString('retained'), 'yes');
            return const MaterialApp(home: Text('Private app'));
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(builds, 0);
      expect(find.textContaining('could not read'), findsOneWidget);
      paths.root = r'C:\fixture';
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(builds, 1);
      expect(find.text('Private app'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('failed app construction requires restart without retrying', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'retained': 'yes'});
    final prefs = await SharedPreferences.getInstance();
    var builds = 0;
    await tester.pumpWidget(
      SettingsStartup(
        load: () async => prefs,
        readyBuilder: (_) {
          builds++;
          throw StateError('PRIVATE WRONG TYPE');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(builds, 1);
    expect(find.text('Doorlight could not start.'), findsOneWidget);
    expect(find.textContaining('PRIVATE WRONG TYPE'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Opening Doorlight…'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(prefs.getString('retained'), 'yes');
  });

  testWidgets(
    'failure blocks private state; retry is single-flight and recovers',
    (tester) async {
      SharedPreferences.setMockInitialValues({'retained': 'yes'});
      final prefs = await SharedPreferences.getInstance();
      var reads = 0;
      var builds = 0;
      var pending = Completer<SharedPreferences>();
      await tester.pumpWidget(
        SettingsStartup(
          load: () {
            reads++;
            return pending.future;
          },
          readyBuilder: (loaded) {
            builds++;
            expect(identical(loaded, prefs), isTrue);
            return const MaterialApp(home: Text('Private app'));
          },
        ),
      );
      expect(builds, 0);
      pending.completeError(const FormatException('PRIVATE SETTINGS BYTES'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not read'), findsOneWidget);
      expect(find.textContaining('PRIVATE SETTINGS BYTES'), findsNothing);
      expect(builds, 0);
      pending = Completer<SharedPreferences>();
      final retry = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      retry();
      retry();
      await tester.pump();
      expect(reads, 2);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.completeError(StateError('PRIVATE PATH'));
      await tester.pumpAndSettle();
      expect(builds, 0);
      expect(find.textContaining('PRIVATE PATH'), findsNothing);
      pending = Completer<SharedPreferences>();
      await tester.tap(find.text('Retry'));
      pending.complete(prefs);
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(builds, 1);
      expect(find.text('Private app'), findsOneWidget);
      expect(prefs.getString('retained'), 'yes');
    },
  );

  testWidgets('disposed bootstrap ignores late successful read', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pending = Completer<SharedPreferences>();
    var builds = 0;
    await tester.pumpWidget(
      SettingsStartup(
        load: () => pending.future,
        readyBuilder: (_) {
          builds++;
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(const SizedBox());
    pending.complete(prefs);
    await tester.pump();
    expect(builds, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure surface fits narrow viewport and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      SettingsStartup(
        load: () => Future.error(const FormatException()),
        readyBuilder: (_) => throw StateError('must remain blocked'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
