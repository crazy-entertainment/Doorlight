import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/ui/composer_stickers.dart';
import 'package:sybl/state/gif_library_store.dart';
import 'package:sybl/ui/sticker_image.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/state/starter_gifs.dart';

import 'gif_validation_test.dart' show gif;

void main() {
  setUpAll(() async {
    await bundledStarterGifs;
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late Directory scratch;
  late GifLibraryStore store;
  setUp(() async {
    await bundledStickerManifest;
    scratch = await Directory('../../local/tmp').createTemp('gif-picker-test-');
    store = GifLibraryStore(() async => Directory('${scratch.path}/library'));
    final source = await File(
      '${scratch.path}/source.gif',
    ).writeAsBytes(gif(frames: 2));
    expect(await store.import(source.path), GifLibraryResult.saved);
  });
  tearDown(() async => scratch.delete(recursive: true));
  for (final narrow in [false, true]) {
    testWidgets(
      'offline Doorlight shelf selects without personal storage ${narrow ? 'mobile' : 'desktop'}',
      (tester) async {
        tester.view.physicalSize = narrow
            ? const Size(390, 300)
            : const Size(700, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(narrow ? 2 : 1),
                disableAnimations: true,
              ),
              child: RepaintBoundary(
                key: const ValueKey('gif-shelf'),
                child: Scaffold(
                  body: ComposerPicker(
                    onSticker: (_) {},
                    onEmoji: (_) {},
                    onImportGif: null,
                    onStarterGif: (entry) => selected = entry.id,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('GIFs'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          final buttons = tester.widgetList<TextButton>(
            find.byType(TextButton),
          );
          if (buttons.any(
                (button) =>
                    button.child is Text &&
                    (button.child as Text).data == 'Hello' &&
                    button.onPressed != null,
              ) &&
              tester
                      .widgetList<RawImage>(find.byType(RawImage))
                      .where((image) => image.image != null)
                      .length >=
                  16) {
            break;
          }
        }
        expect(find.text('Doorlight'), findsOneWidget);
        expect(find.text('Your GIFs'), findsOneWidget);
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .where((image) => image.image != null)
              .length,
          16,
        );
        await tester.pump(const Duration(milliseconds: 300));
        await expectLater(
          find.byKey(const ValueKey('gif-shelf')),
          matchesGoldenFile(
            'goldens/${narrow ? 'mobile' : 'desktop'}_doorlight_gif_shelf.png',
          ),
        );
        await tester.ensureVisible(find.text('Hello'));
        await tester.tap(find.text('Hello'));
        expect(selected, 'hello');
        expect(store.index.entries, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('local GIF selection and removal work at 200 percent text', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SizedBox(
              width: 360,
              height: 300,
              child: ComposerPicker(
                gifLibrary: store,
                onSticker: (_) {},
                onEmoji: (_) {},
                onImportGif: () {},
                onGif: (hash) => selected = hash,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('GIFs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(find.text('Your GIFs'));
    await tester.tap(find.text('Your GIFs'));
    await tester.pump();
    for (var i = 0; i < 50 && find.text('Use GIF').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Use GIF'));
    await tester.tap(find.text('Use GIF'));
    expect(selected, store.index.entries.keys.single);
    await tester.ensureVisible(find.byTooltip('Remove GIF from library'));
    await tester.tap(find.byTooltip('Remove GIF from library'));
    for (var i = 0; i < 50 && store.index.entries.isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(store.index.entries, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('bundled picker remains selectable at 200 percent text', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              height: 220,
              child: ComposerStickers(
                onSelected: (sticker) => selected = sticker.id,
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 50 && find.text('Angry cat').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Angry cat'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Angry cat'));
    expect(selected, 'sybl.chubby-cats.angry.v1');
    expect(tester.takeException(), isNull);
  });
}
