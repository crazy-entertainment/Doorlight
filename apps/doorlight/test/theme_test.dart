import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:sybl/state/appearance_preset.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/sybl_ui.dart';

void main() {
  double relativeLuminance(Color color) {
    double linearize(int component) {
      final value = component / 255;
      return value <= .04045
          ? value / 12.92
          : math.pow((value + .055) / 1.055, 2.4).toDouble();
    }

    final argb = color.toARGB32();
    return .2126 * linearize((argb >> 16) & 0xff) +
        .7152 * linearize((argb >> 8) & 0xff) +
        .0722 * linearize(argb & 0xff);
  }

  double contrast(Color foreground, Color background) {
    final first = relativeLuminance(foreground);
    final second = relativeLuminance(background);
    return ((first > second ? first : second) + .05) /
        ((first < second ? first : second) + .05);
  }

  test('every appearance preset installs its complete semantic palette', () {
    for (final preset in AppearancePreset.values) {
      final installed = Warm.theme(preset).extension<SyblColors>();
      expect(installed, same(Warm.palette(preset)));
    }

    expect(Warm.cozy.bg, isNot(Warm.disaccord.bg));
    expect(Warm.midnight.bg, isNot(Warm.disaccord.bg));
    expect(Warm.midnight.surfaceTop, isNot(Warm.disaccord.surfaceTop));
    expect(Warm.midnight.amber, isNot(Warm.disaccord.amber));
  });

  test(
    'legacy Calm storage selects Disaccord without changing other presets',
    () {
      expect(AppearancePreset.tryParse('calm'), AppearancePreset.disaccord);
      expect(AppearancePreset.disaccord.storageValue, 'calm');
      expect(AppearancePreset.tryParse('cozy'), AppearancePreset.cozy);
      expect(AppearancePreset.tryParse('midnight'), AppearancePreset.midnight);
      expect(AppearancePreset.tryParse('unknown'), isNull);
    },
  );

  test(
    'Disaccord uses Discord Dark surfaces and separate brand text and fills',
    () {
      final colors = Warm.disaccord;
      expect(colors.bg, const Color(0xFF202024));
      expect(colors.desk, const Color(0xFF121214));
      expect(colors.accentFill, const Color(0xFF5865F2));
      expect(
        colors.foregroundFor(colors.accentFill, preferred: Colors.black),
        Colors.white,
      );
      expect(colors.display.fontFamily, Warm.sansFamily);
      expect(colors.fieldOpacity, 0);
      expect(colors.copyWith().accentFill, colors.accentFill);
      final halfway = Warm.cozy.lerp(colors, .5);
      expect(
        halfway.accentFill,
        Color.lerp(Warm.cozy.accentFill, colors.accentFill, .5),
      );
      expect(halfway.fieldOpacity, .05);
      for (final preset in AppearancePreset.values) {
        final palette = Warm.palette(preset);
        expect(
          contrast(palette.onAccent, palette.accentFill),
          greaterThanOrEqualTo(4.5),
        );
        for (final surface in [
          palette.bg,
          palette.surface,
          palette.surfaceHi,
          palette.surfaceTop,
        ]) {
          expect(contrast(palette.amber, surface), greaterThanOrEqualTo(4.5));
        }
        final theme = Warm.theme(preset);
        expect(theme.colorScheme.onPrimary, palette.onAccent);
        expect(
          contrast(
            palette.foregroundFor(palette.dangerFill),
            palette.dangerFill,
          ),
          greaterThanOrEqualTo(4.5),
        );
        if (preset == AppearancePreset.disaccord) {
          for (final text in [palette.danger, palette.online]) {
            expect(
              contrast(text, palette.surfaceTop),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
        expect(
          theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
          palette.onAccent,
        );
        expect(
          theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          palette.accentFill,
        );
        expect(theme.textSelectionTheme.cursorColor, palette.amber);
        if (preset == AppearancePreset.disaccord) {
          final fill = theme.filledButtonTheme.style!.backgroundColor!;
          expect(fill.resolve({WidgetState.hovered}), palette.amberDeep);
          expect(fill.resolve({WidgetState.pressed}), palette.accentPressed);
          expect(
            fill.resolve({WidgetState.disabled}),
            isNot(palette.accentFill),
          );
        }
      }
    },
  );

  test(
    'Disaccord owns neutral button geometry, colors and interaction states',
    () {
      final colors = Warm.disaccord;
      final style = Warm.theme(
        AppearancePreset.disaccord,
      ).outlinedButtonTheme.style!;
      expect(style.shape!.resolve({}), isA<RoundedRectangleBorder>());
      expect(
        (style.shape!.resolve({})! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(8),
      );
      expect(style.backgroundColor!.resolve({}), const Color(0x1F97979F));
      expect(
        style.backgroundColor!.resolve({WidgetState.hovered}),
        const Color(0x2997979F),
      );
      expect(
        style.backgroundColor!.resolve({WidgetState.pressed}),
        const Color(0x3397979F),
      );
      expect(style.foregroundColor!.resolve({}), const Color(0xFFFBFBFB));
      expect(style.side!.resolve({WidgetState.focused})!.color, colors.amber);
      expect(
        style.foregroundColor!.resolve({WidgetState.disabled}),
        isNot(colors.neutralButtonForeground),
      );
      for (final state in [
        {WidgetState.hovered},
        {WidgetState.pressed},
        <WidgetState>{},
      ]) {
        for (final surface in [colors.desk, colors.bg, colors.surfaceTop]) {
          final background = Color.alphaBlend(
            style.backgroundColor!.resolve(state)!,
            surface,
          );
          expect(
            contrast(style.foregroundColor!.resolve(state)!, background),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
      expect(colors.copyWith().neutralButtonFill, colors.neutralButtonFill);
      expect(
        Warm.cozy.lerp(colors, .5).neutralButtonFill,
        Color.lerp(Warm.cozy.neutralButtonFill, colors.neutralButtonFill, .5),
      );
      for (final preset in [AppearancePreset.cozy, AppearancePreset.midnight]) {
        final original = Warm.theme(preset).outlinedButtonTheme.style!;
        expect(original.shape!.resolve({}), isA<StadiumBorder>());
        expect(
          original.foregroundColor!.resolve({}),
          Warm.palette(preset).amber,
        );
      }
    },
  );

  testWidgets(
    'call and video actions follow appearance including disabled state',
    (tester) async {
      Widget app(AppearancePreset preset, {bool enabled = true}) => MaterialApp(
        theme: Warm.theme(preset),
        home: Scaffold(
          body: SyblPillIconButton(
            label: 'Start call',
            icon: Icons.call,
            emphasized: true,
            onPressed: enabled ? () {} : null,
          ),
        ),
      );
      await tester.pumpWidget(app(AppearancePreset.disaccord));
      final neutral = tester.widget<IconButton>(find.byType(IconButton)).style!;
      expect(
        neutral.backgroundColor!.resolve({}),
        Warm.disaccord.neutralButtonFill,
      );
      expect(
        neutral.foregroundColor!.resolve({}),
        Warm.disaccord.neutralButtonForeground,
      );
      await tester.pumpWidget(app(AppearancePreset.disaccord, enabled: false));
      await tester.pumpAndSettle();
      final disabled = tester.widget<IconButton>(find.byType(IconButton));
      expect(disabled.onPressed, isNull);
      expect(
        disabled.style!.foregroundColor!.resolve({WidgetState.disabled}),
        isNot(Warm.disaccord.neutralButtonForeground),
      );
      await tester.pumpWidget(app(AppearancePreset.cozy));
      await tester.pumpAndSettle();
      final cozy = tester.widget<IconButton>(find.byType(IconButton)).style!;
      expect(cozy.backgroundColor!.resolve({}), Warm.cozy.accentFill);
      expect(cozy.foregroundColor!.resolve({}), Warm.cozy.onAccent);
    },
  );

  test(
    'Material chips, segmented controls and containers use each palette',
    () {
      for (final preset in AppearancePreset.values) {
        final colors = Warm.palette(preset);
        final scheme = Warm.theme(preset).colorScheme;
        expect(scheme.secondaryContainer, colors.glowSoft);
        expect(scheme.onSecondaryContainer, colors.ink);
        expect(scheme.onSurfaceVariant, colors.muted);
        expect(scheme.tertiary, colors.annotation);
        expect(
          scheme.tertiaryContainer,
          colors.annotation.withValues(alpha: .16),
        );
        expect(scheme.errorContainer, colors.danger.withValues(alpha: .16));
        expect(scheme.primaryFixed, colors.accentFill);
        expect(scheme.secondaryFixed, colors.accentFill);
        expect(scheme.surfaceTint, Colors.transparent);
        expect(scheme.inverseSurface, colors.ink);
        expect(scheme.onInverseSurface, colors.bg);
      }
    },
  );

  test('new Doorlight surfaces use the Cozy brown palette', () {
    expect(Warm.theme().extension<SyblColors>(), same(Warm.cozy));
  });

  test('shared lighting keeps secondary text readable across presets', () {
    for (final preset in AppearancePreset.values) {
      final colors = Warm.palette(preset);
      final field = colors.backdrop.gradient! as RadialGradient;
      expect(field.center, const Alignment(0, -.4));
      expect(field.colors.last.a, 0);
      for (final base in [colors.bg, colors.desk]) {
        final lit = Color.alphaBlend(field.colors.first, base);
        expect(contrast(colors.muted, lit), greaterThanOrEqualTo(4.5));
        expect(contrast(colors.faint, lit), greaterThanOrEqualTo(4.5));
      }
    }
  });

  test('essential faint text meets WCAG AA on every app surface', () {
    for (final preset in AppearancePreset.values) {
      final colors = Warm.palette(preset);
      for (final background in [
        colors.bg,
        colors.surface,
        colors.surfaceHi,
        colors.surfaceTop,
      ]) {
        expect(
          contrast(colors.faint, background),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.name} faint text on ${background.toARGB32()}',
        );
      }
    }
  });

  testWidgets('widgets resolve palette changes from the current theme', (
    tester,
  ) async {
    Widget app(AppearancePreset preset) {
      return MaterialApp(
        theme: Warm.theme(preset),
        home: Builder(
          builder: (context) => ColoredBox(
            key: const ValueKey('semantic-surface'),
            color: context.syblColors.bg,
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    await tester.pumpWidget(app(AppearancePreset.disaccord));
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const ValueKey('semantic-surface')))
          .color,
      Warm.disaccord.bg,
    );

    await tester.pumpWidget(app(AppearancePreset.midnight));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const ValueKey('semantic-surface')))
          .color,
      Warm.midnight.bg,
    );
  });

  testWidgets('avatar initials preserve complete Unicode graphemes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: const SyblAvatar(label: '👨‍👩‍👧‍👦 Family'),
      ),
    );

    expect(find.text('👨‍👩‍👧‍👦'), findsOneWidget);
  });

  testWidgets(
    'avatar initials remain readable on call surfaces and accent colors',
    (tester) async {
      for (final preset in AppearancePreset.values) {
        final colors = Warm.palette(preset);
        for (final background in [
          colors.surfaceHi,
          colors.surface,
          colors.rose,
          colors.amber,
          colors.accentFill,
          colors.sky,
          colors.sage,
          colors.online,
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: Warm.theme(preset),
              home: SyblAvatar(label: 'Doorlight', color: background),
            ),
          );
          await tester.pumpAndSettle();
          final foreground = tester.widget<Text>(find.text('D')).style!.color!;
          expect(
            contrast(foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.name} avatar on ${background.toARGB32()}',
          );
        }
      }
    },
  );

  testWidgets('avatar raster decode is capped at its physical display size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    final avatar = base64Encode(
      image.encodePng(image.Image(width: 512, height: 512)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: SyblAvatar(label: 'Ada', size: 40, imageBase64: avatar),
      ),
    );

    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).width, 80);
    expect(provider.height, 80);
  });
}
