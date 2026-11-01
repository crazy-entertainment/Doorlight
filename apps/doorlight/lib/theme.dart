import 'package:flutter/material.dart';

import 'state/appearance_preset.dart';

/// Semantic colors used by every Doorlight surface.
///
/// Widgets read these colors from [ThemeData.extensions] so appearance changes
/// are scoped to the widget tree, rebuild predictably, and never depend on
/// mutable process-global palette state.
@immutable
final class SyblColors extends ThemeExtension<SyblColors> {
  const SyblColors({
    required this.bg,
    required this.desk,
    required this.surface,
    required this.surfaceHi,
    required this.surfaceTop,
    required this.amber,
    required this.amberDeep,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.online,
    required this.annotation,
    required this.idle,
    required this.danger,
    required this.rose,
    required this.sky,
    required this.sage,
    Color? accentFill,
    Color? accentPressed,
    Color? dangerFill,
    Color? onlineFill,
    this.neutralButtonFill,
    this.neutralButtonHover,
    this.neutralButtonPressed,
    this.neutralButtonForeground,
    this.neutralButtonBorder,
    this.buttonRadius,
    this.fieldOpacity = .10,
    this.displayFamily = Warm.serifFamily,
  }) : accentFill = accentFill ?? amber,
       accentPressed = accentPressed ?? amberDeep,
       dangerFill = dangerFill ?? danger,
       onlineFill = onlineFill ?? online;

  final Color bg;
  final Color desk;
  final Color surface;
  final Color surfaceHi;
  final Color surfaceTop;
  final Color amber;
  final Color amberDeep;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color online;
  final Color annotation;
  final Color idle;
  final Color danger;
  final Color rose;
  final Color sky;
  final Color sage;

  final Color accentFill;
  final Color accentPressed;
  final Color dangerFill;
  final Color onlineFill;
  final Color? neutralButtonFill;
  final Color? neutralButtonHover;
  final Color? neutralButtonPressed;
  final Color? neutralButtonForeground;
  final Color? neutralButtonBorder;
  final double? buttonRadius;
  final double fieldOpacity;
  final String displayFamily;

  OutlinedBorder get buttonShape => buttonRadius == null
      ? const StadiumBorder()
      : RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(buttonRadius!),
        );

  ButtonStyle get secondaryButtonStyle =>
      OutlinedButton.styleFrom(
        foregroundColor: neutralButtonForeground ?? amber,
        minimumSize: const Size(48, 48),
        side: BorderSide(color: neutralButtonBorder ?? lineStrong),
        shape: buttonShape,
      ).copyWith(
        backgroundColor: neutralButtonFill == null
            ? null
            : WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return ink.withValues(alpha: .12);
                }
                if (states.contains(WidgetState.pressed)) {
                  return neutralButtonPressed ?? neutralButtonFill;
                }
                if (states.contains(WidgetState.hovered)) {
                  return neutralButtonHover ?? neutralButtonFill;
                }
                return neutralButtonFill;
              }),
        foregroundColor: neutralButtonFill == null
            ? null
            : WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? ink.withValues(alpha: .38)
                    : (neutralButtonForeground ?? ink),
              ),
        overlayColor: neutralButtonFill == null
            ? null
            : const WidgetStatePropertyAll(Colors.transparent),
        side: neutralButtonFill == null
            ? null
            : WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color: states.contains(WidgetState.focused)
                      ? amber
                      : (neutralButtonBorder ?? lineStrong),
                  width: states.contains(WidgetState.focused) ? 2 : 1,
                ),
              ),
      );

  // Accent text/effects can be lighter than a filled control's brand color.
  Color get onAccent => foregroundFor(accentFill);

  Color foregroundFor(Color background, {Color? preferred}) {
    final luminance = background.computeLuminance();
    double contrast(Color color) {
      final other = color.computeLuminance();
      return luminance > other
          ? (luminance + .05) / (other + .05)
          : (other + .05) / (luminance + .05);
    }

    // Preserve legacy dark ink on light fills only when contrast is strong.
    if (preferred != null && contrast(preferred) >= 7) return preferred;
    final light = contrast(ink) >= 4.5 ? ink : Colors.white;
    final foreground = contrast(bg) >= contrast(light) ? bg : light;
    return contrast(foreground) >= 4.5 ? foreground : Colors.black;
  }

  Color get line => ink.withValues(alpha: .08);
  Color get lineStrong => ink.withValues(alpha: .14);
  Color get glowSoft => amber.withValues(alpha: .16);

  RadialGradient lightField({Alignment center = const Alignment(0, -.4)}) =>
      RadialGradient(
        center: center,
        radius: .85,
        colors: [
          amber.withValues(alpha: fieldOpacity),
          amber.withValues(alpha: 0),
        ],
      );

  BoxDecoration get backdrop =>
      BoxDecoration(color: bg, gradient: lightField());

  TextStyle get display => TextStyle(
    color: ink,
    fontFamily: displayFamily,
    fontFamilyFallback: displayFamily == Warm.serifFamily
        ? Warm.serifFallback
        : Warm.sansFallback,
    fontWeight: FontWeight.w500,
  );

  static SyblColors of(BuildContext context) {
    final colors = Theme.of(context).extension<SyblColors>();
    assert(colors != null, 'Warm.theme() must install SyblColors.');
    return colors!;
  }

  @override
  SyblColors copyWith({
    Color? bg,
    Color? desk,
    Color? surface,
    Color? surfaceHi,
    Color? surfaceTop,
    Color? amber,
    Color? amberDeep,
    Color? ink,
    Color? muted,
    Color? faint,
    Color? online,
    Color? annotation,
    Color? idle,
    Color? danger,
    Color? rose,
    Color? sky,
    Color? sage,
    Color? accentFill,
    Color? accentPressed,
    Color? dangerFill,
    Color? onlineFill,
    Color? neutralButtonFill,
    Color? neutralButtonHover,
    Color? neutralButtonPressed,
    Color? neutralButtonForeground,
    Color? neutralButtonBorder,
    double? buttonRadius,
    double? fieldOpacity,
    String? displayFamily,
  }) => SyblColors(
    bg: bg ?? this.bg,
    desk: desk ?? this.desk,
    surface: surface ?? this.surface,
    surfaceHi: surfaceHi ?? this.surfaceHi,
    surfaceTop: surfaceTop ?? this.surfaceTop,
    amber: amber ?? this.amber,
    amberDeep: amberDeep ?? this.amberDeep,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    online: online ?? this.online,
    annotation: annotation ?? this.annotation,
    idle: idle ?? this.idle,
    danger: danger ?? this.danger,
    rose: rose ?? this.rose,
    sky: sky ?? this.sky,
    sage: sage ?? this.sage,
    accentFill: accentFill ?? this.accentFill,
    accentPressed: accentPressed ?? this.accentPressed,
    dangerFill: dangerFill ?? this.dangerFill,
    onlineFill: onlineFill ?? this.onlineFill,
    neutralButtonFill: neutralButtonFill ?? this.neutralButtonFill,
    neutralButtonHover: neutralButtonHover ?? this.neutralButtonHover,
    neutralButtonPressed: neutralButtonPressed ?? this.neutralButtonPressed,
    neutralButtonForeground:
        neutralButtonForeground ?? this.neutralButtonForeground,
    neutralButtonBorder: neutralButtonBorder ?? this.neutralButtonBorder,
    buttonRadius: buttonRadius ?? this.buttonRadius,
    fieldOpacity: fieldOpacity ?? this.fieldOpacity,
    displayFamily: displayFamily ?? this.displayFamily,
  );

  @override
  SyblColors lerp(covariant SyblColors? other, double t) {
    if (other == null) return this;
    return SyblColors(
      bg: Color.lerp(bg, other.bg, t)!,
      desk: Color.lerp(desk, other.desk, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHi: Color.lerp(surfaceHi, other.surfaceHi, t)!,
      surfaceTop: Color.lerp(surfaceTop, other.surfaceTop, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      amberDeep: Color.lerp(amberDeep, other.amberDeep, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      online: Color.lerp(online, other.online, t)!,
      annotation: Color.lerp(annotation, other.annotation, t)!,
      idle: Color.lerp(idle, other.idle, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      rose: Color.lerp(rose, other.rose, t)!,
      sky: Color.lerp(sky, other.sky, t)!,
      sage: Color.lerp(sage, other.sage, t)!,
      accentFill: Color.lerp(accentFill, other.accentFill, t)!,
      accentPressed: Color.lerp(accentPressed, other.accentPressed, t)!,
      dangerFill: Color.lerp(dangerFill, other.dangerFill, t)!,
      onlineFill: Color.lerp(onlineFill, other.onlineFill, t)!,
      neutralButtonFill: Color.lerp(
        neutralButtonFill,
        other.neutralButtonFill,
        t,
      ),
      neutralButtonHover: Color.lerp(
        neutralButtonHover,
        other.neutralButtonHover,
        t,
      ),
      neutralButtonPressed: Color.lerp(
        neutralButtonPressed,
        other.neutralButtonPressed,
        t,
      ),
      neutralButtonForeground: Color.lerp(
        neutralButtonForeground ?? amber,
        other.neutralButtonForeground ?? other.amber,
        t,
      ),
      neutralButtonBorder: Color.lerp(
        neutralButtonBorder ?? lineStrong,
        other.neutralButtonBorder ?? other.lineStrong,
        t,
      ),
      buttonRadius: t == 0
          ? buttonRadius
          : t == 1
          ? other.buttonRadius
          : (buttonRadius ?? 24) +
                ((other.buttonRadius ?? 24) - (buttonRadius ?? 24)) * t,
      fieldOpacity: fieldOpacity + (other.fieldOpacity - fieldOpacity) * t,
      displayFamily: t < .5 ? displayFamily : other.displayFamily,
    );
  }
}

extension SyblThemeContext on BuildContext {
  SyblColors get syblColors => SyblColors.of(this);
}

/// Theme factory locked to the Windows reference's semantic hierarchy.
///
/// Fraunces and Hanken Grotesk are bundled OFL assets so the reference
/// hierarchy is deterministic and works offline. Platform fallbacks cover
/// glyphs outside the bundled families.
abstract final class Warm {
  static const sansFamily = 'HankenGrotesk';
  static const serifFamily = 'Fraunces';
  static const sansFallback = <String>[
    'Segoe UI',
    'Roboto',
    'Arial',
    'sans-serif',
  ];
  static const serifFallback = <String>['Georgia', 'Times New Roman', 'serif'];

  // Discord Dark (.theme-darker), public app tokens retrieved 2026-10-14.
  // Dark is distinct from Ash (.theme-dark).
  // https://discord.com/assets/952007.3b490a4a037fd35b.css
  static const disaccord = SyblColors(
    bg: Color(0xFF202024), // neutral-82: background-base-low
    desk: Color(0xFF121214), // neutral-92: background-base-lowest
    surface: Color(0xFF1A1A1E), // neutral-86: background-base-lower
    surfaceHi: Color(0xFF242429), // neutral-79: background-surface-high
    surfaceTop: Color(0xFF2C2D32), // neutral-73: background-surface-highest
    amber: Color(0xFF8CA0FD), // blurple-29: control-brand-foreground
    amberDeep: Color(0xFF4452BB), // blurple-60: primary hover
    accentFill: Color(0xFF5865F2), // blurple-50: primary default
    accentPressed: Color(0xFF3A48A3), // blurple-65: primary active
    ink: Color(0xFFEFEFF1), // neutral-5: text-default
    muted: Color(0xFFABACB2), // neutral-23: interactive-text-default
    faint: Color(0xFF96979E), // neutral-29: text-muted
    online: Color(0xFF5EB479), // text-feedback-positive
    onlineFill: Color(0xFF008545), // control-connected-background-default
    annotation: Color(0xFF4D96EE), // blue-new-37: text-link
    idle: Color(0xFFFDB833), // status-warning
    danger: Color(0xFFF87E7A), // text-feedback-critical
    dangerFill: Color(
      0xFFD22D39,
    ), // control-critical-primary-background-default
    rose: Color(0xFFE0A18C),
    sky: Color(0xFF4D96EE),
    sage: Color(0xFFADC7A4),
    // Discord control-secondary opacity tokens over the current surface.
    neutralButtonFill: Color(0x1F97979F),
    neutralButtonHover: Color(0x2997979F),
    neutralButtonPressed: Color(0x3397979F),
    neutralButtonForeground: Color(0xFFFBFBFB),
    neutralButtonBorder: Color(0x0A97979F),
    buttonRadius: 8,
    fieldOpacity: 0,
    displayFamily: sansFamily,
  );

  static const cozy = SyblColors(
    bg: Color(0xFF211714),
    desk: Color(0xFF140E0C),
    surface: Color(0xFF2A1D19),
    surfaceHi: Color(0xFF34231F),
    surfaceTop: Color(0xFF422C26),
    amber: Color(0xFFF2B775),
    amberDeep: Color(0xFFE69A4E),
    ink: Color(0xFFF4E9DF),
    muted: Color(0xFFB49D90),
    faint: Color(0xFFB19A8F),
    online: Color(0xFF7FD893),
    annotation: Color(0xFFF08A6C),
    idle: Color(0xFFE8C06A),
    danger: Color(0xFFE36E63),
    rose: Color(0xFFE0A18C),
    sky: Color(0xFFA5BFDA),
    sage: Color(0xFFADC7A4),
  );

  static const midnight = SyblColors(
    bg: Color(0xFF0B0D12),
    desk: Color(0xFF07090D),
    surface: Color(0xFF11131A),
    surfaceHi: Color(0xFF181C26),
    surfaceTop: Color(0xFF222735),
    amber: Color(0xFF9BB8D6),
    amberDeep: Color(0xFF7F9FCA),
    ink: Color(0xFFE8ECF3),
    muted: Color(0xFF9CA5B4),
    faint: Color(0xFF8993A3),
    online: Color(0xFF75D39A),
    annotation: Color(0xFFF08A7A),
    idle: Color(0xFFE1BD6E),
    danger: Color(0xFFE16E69),
    rose: Color(0xFFC69A9B),
    sky: Color(0xFF9BB8D6),
    sage: Color(0xFF9EBEAA),
  );

  static SyblColors palette(AppearancePreset preset) => switch (preset) {
    AppearancePreset.disaccord => disaccord,
    AppearancePreset.cozy => cozy,
    AppearancePreset.midnight => midnight,
  };

  static ThemeData theme([AppearancePreset preset = AppearancePreset.cozy]) =>
      fromPalette(palette(preset));

  static ThemeData fromPalette(SyblColors colors) {
    final scheme = ColorScheme.dark(
      primary: colors.accentFill,
      onPrimary: colors.onAccent,
      primaryContainer: colors.glowSoft,
      onPrimaryContainer: colors.ink,
      secondary: colors.accentFill,
      onSecondary: colors.onAccent,
      secondaryContainer: colors.glowSoft,
      onSecondaryContainer: colors.ink,
      tertiary: colors.annotation,
      onTertiary: colors.foregroundFor(colors.annotation),
      tertiaryContainer: colors.annotation.withValues(alpha: .16),
      onTertiaryContainer: colors.ink,
      primaryFixed: colors.accentFill,
      primaryFixedDim: colors.amberDeep,
      onPrimaryFixed: colors.onAccent,
      onPrimaryFixedVariant: colors.foregroundFor(colors.amberDeep),
      secondaryFixed: colors.accentFill,
      secondaryFixedDim: colors.amberDeep,
      onSecondaryFixed: colors.onAccent,
      onSecondaryFixedVariant: colors.foregroundFor(colors.amberDeep),
      tertiaryFixed: colors.annotation,
      tertiaryFixedDim: colors.annotation,
      onTertiaryFixed: colors.foregroundFor(colors.annotation),
      onTertiaryFixedVariant: colors.foregroundFor(colors.annotation),
      errorContainer: colors.danger.withValues(alpha: .16),
      onErrorContainer: colors.ink,
      error: colors.danger,
      onError: colors.foregroundFor(colors.danger),
      surface: colors.surface,
      onSurface: colors.ink,
      onSurfaceVariant: colors.muted,
      surfaceDim: colors.desk,
      surfaceBright: colors.surfaceTop,
      surfaceTint: Colors.transparent,
      inverseSurface: colors.ink,
      onInverseSurface: colors.bg,
      inversePrimary: colors.bg,
      surfaceContainerLowest: colors.desk,
      surfaceContainerLow: colors.bg,
      surfaceContainer: colors.surface,
      surfaceContainerHigh: colors.surfaceHi,
      surfaceContainerHighest: colors.surfaceTop,
      outline: colors.lineStrong,
      outlineVariant: colors.line,
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.bg,
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      visualDensity: VisualDensity.standard,
      extensions: [colors],
    );
    final textTheme = base.textTheme.apply(
      bodyColor: colors.ink,
      displayColor: colors.ink,
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
    );

    return base.copyWith(
      textTheme: textTheme,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.amber,
        selectionColor: colors.amber.withValues(alpha: .3),
        selectionHandleColor: colors.amber,
      ),
      dividerColor: colors.line,
      disabledColor: colors.faint,
      splashColor: colors.glowSoft,
      highlightColor: colors.glowSoft,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.bg,
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: colors.line),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: colors.lineStrong),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceHi,
        hintStyle: TextStyle(color: colors.faint),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: colors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: colors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: colors.amber),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style:
            IconButton.styleFrom(
              foregroundColor: colors.muted,
              minimumSize: const Size(48, 48),
            ).copyWith(
              shape: colors.buttonRadius == null
                  ? null
                  : WidgetStatePropertyAll(colors.buttonShape),
              foregroundColor: colors.neutralButtonFill == null
                  ? null
                  : WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.disabled)) {
                        return colors.ink.withValues(alpha: .38);
                      }
                      return states.contains(WidgetState.hovered) ||
                              states.contains(WidgetState.focused) ||
                              states.contains(WidgetState.pressed)
                          ? colors.neutralButtonForeground
                          : colors.muted;
                    }),
              overlayColor: colors.neutralButtonFill == null
                  ? null
                  : WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.disabled)) {
                        return Colors.transparent;
                      }
                      if (states.contains(WidgetState.pressed)) {
                        return colors.neutralButtonPressed;
                      }
                      if (states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.focused)) {
                        return colors.neutralButtonHover;
                      }
                      return Colors.transparent;
                    }),
            ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              backgroundColor: colors.accentFill,
              foregroundColor: colors.onAccent,
              minimumSize: const Size(48, 48),
              shape: colors.buttonShape,
              textStyle: const TextStyle(
                fontFamily: sansFamily,
                fontFamilyFallback: sansFallback,
                fontWeight: FontWeight.w600,
              ),
            ).copyWith(
              backgroundColor: colors.accentFill == colors.amber
                  ? null
                  : WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.disabled)) {
                        return colors.ink.withValues(alpha: .12);
                      }
                      if (states.contains(WidgetState.pressed)) {
                        return colors.accentPressed;
                      }
                      return states.contains(WidgetState.hovered)
                          ? colors.amberDeep
                          : colors.accentFill;
                    }),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: colors.secondaryButtonStyle,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.amber,
          minimumSize: const Size(48, 48),
          shape: colors.buttonShape,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.amber
              : colors.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.glowSoft
              : colors.surfaceTop,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceTop,
        contentTextStyle: TextStyle(color: colors.ink),
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.surfaceTop,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          border: Border.fromBorderSide(BorderSide(color: colors.lineStrong)),
        ),
        textStyle: TextStyle(color: colors.ink, fontSize: 12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.amber,
        linearTrackColor: colors.surfaceTop,
      ),
    );
  }
}
