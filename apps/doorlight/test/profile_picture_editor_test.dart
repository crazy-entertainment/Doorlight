import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/profile_picture_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
  });
  test('hostile compressed dimensions are rejected before pixel decode', () {
    final hostile = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAA//8AAP//CAYAAAC2BdlQAAAAAElFTkSuQmCC',
    );

    expect(decodeProfileImage(hostile), isNull);
  });

  test('profile preview and crop pixels share baked EXIF orientation', () {
    final source = image.Image(width: 2, height: 3)
      ..exif.imageIfd.orientation = 6;
    final decoded = decodeProfileImage(
      Uint8List.fromList(image.encodeJpg(source)),
    );

    expect(decoded, isNotNull);
    expect(decoded!.pixels.width, 3);
    expect(decoded.pixels.height, 2);

    final preview = image.decodePng(decoded.previewBytes);
    expect(preview, isNotNull);
    expect(preview!.width, decoded.pixels.width);
    expect(preview.height, decoded.pixels.height);
    expect(preview.exif.imageIfd.hasOrientation, isFalse);
  });

  test('mobile preview and exported crop use the same covered pixels', () {
    final source = image.Image(width: 800, height: 400);
    image.fill(source, color: image.ColorRgb8(0, 80, 220));
    image.fillRect(
      source,
      x1: 0,
      y1: 0,
      x2: 199,
      y2: 399,
      color: image.ColorRgb8(220, 20, 20),
    );
    image.fillRect(
      source,
      x1: 600,
      y1: 0,
      x2: 799,
      y2: 399,
      color: image.ColorRgb8(220, 20, 20),
    );
    final transform = profilePictureTransform(scale: .8, x: -160, y: 0);

    expect(transform.getMaxScaleOnAxis(), closeTo(.8, .0001));
    final cropped = cropProfileImage(
      source: source,
      transform: transform,
      viewport: 320,
      previewScale: 1,
    );

    expect(cropped.width, 400);
    expect(cropped.height, 400);
    final edge = cropped.getPixel(0, cropped.height ~/ 2);
    expect(edge.b, greaterThan(180));
    expect(edge.r, lessThan(80));
  });

  test('wide, tall, tiny, and large sources stay inside a square crop', () {
    for (final size in const [
      (width: 2400, height: 120),
      (width: 120, height: 2400),
      (width: 8, height: 5),
      (width: 2048, height: 2048),
    ]) {
      final source = image.Image(width: size.width, height: size.height);
      final previewScale = math.min(
        1.0,
        1200 / math.max(size.width, size.height),
      );
      final previewWidth = size.width * previewScale;
      final previewHeight = size.height * previewScale;
      const viewport = 320.0;
      final coverScale = math.max(
        viewport / previewWidth,
        viewport / previewHeight,
      );
      final crop = cropProfileImage(
        source: source,
        transform: profilePictureTransform(
          scale: coverScale,
          x: (viewport - previewWidth * coverScale) / 2,
          y: (viewport - previewHeight * coverScale) / 2,
        ),
        viewport: viewport,
        previewScale: previewScale,
      );

      expect(crop.width, crop.height, reason: '$size must export square');
      expect(crop.width, lessThanOrEqualTo(math.min(size.width, size.height)));
      expect(crop.width, greaterThan(0));
    }
  });

  testWidgets('disposed picker context still discards its staged file', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final jami = _PickerJami();
    final state = AppState(jami, await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    late BuildContext pickerContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pickerContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final editor = showProfilePictureEditor(pickerContext, state: state);
    await tester.pumpWidget(const SizedBox.shrink());
    jami.picked.complete('staged/profile.png');
    await tester.pump();

    expect(await editor, isNull);
    expect(jami.discarded, ['staged/profile.png']);
  });

  testWidgets(
    'crop preview and actions fit short windows and retain selection on resize',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final source = image.Image(width: 800, height: 400);
      image.fill(source, color: image.ColorRgb8(70, 120, 170));
      image.fillRect(
        source,
        x1: 0,
        y1: 0,
        x2: 300,
        y2: 399,
        color: image.ColorRgb8(190, 105, 65),
      );
      final sourceBytes = Uint8List.fromList(image.encodePng(source));
      final state = AppState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      addTearDown(state.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(635, 500);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Scaffold(
            body: profilePictureEditorForTesting(
              state: state,
              sourceBytes: sourceBytes,
              source: source,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = find.byKey(const ValueKey('profile-picture-viewport'));
      final initialElement = tester.element(viewport);
      final zoom = find.byKey(const ValueKey('profile-picture-zoom'));
      final slider = tester.widget<Slider>(zoom);
      slider.onChanged!(slider.min * 2.5);
      await tester.pumpAndSettle();
      await tester.drag(viewport, const Offset(-26, 10));
      await tester.pumpAndSettle();
      Uint8List selectedPixels() => Uint8List.fromList(
        image.encodePng(
          cropProfileImage(
            source: source,
            transform: tester
                .widget<InteractiveViewer>(find.byType(InteractiveViewer))
                .transformationController!
                .value,
            viewport: tester.getSize(viewport).width,
            previewScale: 1,
          ),
        ),
      );
      final before = selectedPixels();
      for (final size in const [
        Size(390, 420),
        Size(700, 300),
        Size(280, 400),
        Size(635, 500),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.element(viewport), same(initialElement));
        final preview = tester.getRect(viewport);
        expect(preview.width, preview.height);
        expect(preview.width, greaterThan(48), reason: '$size');
        for (final control in [
          find.text('Profile picture'),
          viewport,
          zoom,
          find.byTooltip('Reset crop'),
          find.text('Cancel'),
          find.byKey(const ValueKey('save-profile-picture')),
        ]) {
          final rect = tester.getRect(control);
          expect(rect.top, greaterThanOrEqualTo(20), reason: '$size $control');
          expect(
            rect.bottom,
            lessThanOrEqualTo(size.height - 20),
            reason: '$size $control',
          );
        }
        expect(find.text('Cancel').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('save-profile-picture')).hitTestable(),
          findsOneWidget,
        );
        expect(preview.bottom, lessThanOrEqualTo(tester.getRect(zoom).top));
        expect(
          selectedPixels(),
          orderedEquals(before),
          reason: 'Resizing must keep the selected source pixels',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip('Reset crop'));
      await tester.pumpAndSettle();
      expect(selectedPixels(), isNot(orderedEquals(before)));
    },
  );

  for (final fixture in [
    (
      size: const Size(635, 500),
      scale: 1.0,
      platform: TargetPlatform.windows,
      name: 'desktop',
    ),
    (
      size: const Size(390, 420),
      scale: 1.0,
      platform: TargetPlatform.android,
      name: 'phone',
    ),
    (
      size: const Size(280, 400),
      scale: 2.0,
      platform: TargetPlatform.windows,
      name: 'large_text',
    ),
  ]) {
    testWidgets('crop dialog fits ${fixture.name}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final source = image.Image(width: 800, height: 400);
      image.fill(source, color: image.ColorRgb8(70, 120, 170));
      image.fillRect(
        source,
        x1: 0,
        y1: 0,
        x2: 300,
        y2: 399,
        color: image.ColorRgb8(190, 105, 65),
      );
      final state = AppState(
        JamiClient(),
        await SharedPreferences.getInstance(),
      );
      addTearDown(state.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = fixture.size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: fixture.platform),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(fixture.scale)),
            child: child!,
          ),
          home: Scaffold(
            body: profilePictureEditorForTesting(
              state: state,
              sourceBytes: Uint8List.fromList(image.encodePng(source)),
              source: source,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Profile picture'), findsOneWidget);
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Reset crop').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-profile-picture')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('profile-picture-viewport')))
            .width,
        greaterThan(48),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/profile_crop_${fixture.name}.png'),
      );
    });
  }
}

final class _PickerJami extends JamiClient {
  final picked = Completer<String?>();
  final discarded = <String>[];

  @override
  Future<String?> pickFile({
    String mimeType = '*/*',
    int maxBytes = JamiClient.maxPickedFileBytes,
  }) => picked.future;

  @override
  Future<void> discardPickedFile(String path) async {
    discarded.add(path);
  }
}
