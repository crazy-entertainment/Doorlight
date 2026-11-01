import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/companion_links.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/game_bar_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    rootBundle.evict('assets/companion-links.json');
    messenger.setMockMessageHandler(
      'flutter/assets',
      (_) async => ByteData.sublistView(
        Uint8List.fromList(
          utf8.encode(
            '{"version":1,"desktopDownloadUrl":null,"widgetDownloadUrl":null}',
          ),
        ),
      ),
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMessageHandler('flutter/assets', null);
    rootBundle.evict('assets/companion-links.json');
  });

  test(
    'shared release configuration rejects executable and credential URLs',
    () {
      String config(Object? url) => jsonEncode({
        'version': 1,
        'desktopDownloadUrl': url,
        'widgetDownloadUrl': null,
      });
      expect(CompanionLinks.parse(config(null)).desktopDownloadUrl, isNull);
      expect(
        CompanionLinks.parse(
          config('https://apps.microsoft.com/detail/fixture'),
        ).desktopDownloadUrl,
        'https://apps.microsoft.com/detail/fixture',
      );
      for (final url in [
        'file:///C:/installer.exe',
        'http://example.test/app',
        'https://user:secret@example.test/app',
        'https://example.test/app?token=x',
        'https://example.test/app#fragment',
        'https://example.test/\napp',
        42,
      ]) {
        expect(() => CompanionLinks.parse(config(url)), throwsFormatException);
      }
      expect(
        () => CompanionLinks.parse('{"version":1}'),
        throwsFormatException,
      );
    },
  );

  Future<void> show(
    WidgetTester tester,
    Object? widget,
    Object? gameBar,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'widgetCompanionStatus');
      return {'widgetInstalled': widget, 'gameBarInstalled': gameBar};
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: const Scaffold(body: GameBarSetup()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desktop only gives honest unpublished install state', (
    tester,
  ) async {
    await show(tester, false, true);
    expect(find.text('Downloads aren’t available yet.'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets(
    'known missing Game Bar is actionable despite unknown widget status',
    (tester) async {
      await show(tester, null, false);
      expect(find.text('Install Game Bar'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('both installed enables opening and rechecks before activation', (
    tester,
  ) async {
    await show(tester, true, true);
    expect(find.text('Open widget'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    // Simulate removal while Settings remains open: no launch may be attempted.
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'widgetInstalled': false, 'gameBarInstalled': true},
    );
    await tester.tap(find.text('Open widget'));
    await tester.pumpAndSettle();
    expect(find.text('Install widget'), findsOneWidget);
    expect(
      find.text('Could not open. Check the installation and try again.'),
      findsNothing,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('failed detection is not described as missing', (tester) async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: const Scaffold(body: GameBarSetup()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Could not check the installation. Try again.'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('setup reflows at narrow width with large text', (tester) async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'widgetInstalled': false, 'gameBarInstalled': true},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: const SingleChildScrollView(child: GameBarSetup()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Check again'), findsOneWidget);
  });
}
