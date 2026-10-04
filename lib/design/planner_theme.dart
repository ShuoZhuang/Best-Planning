import 'package:flutter/material.dart';

/// “专注控制台”视觉令牌。
///
/// 颜色与尺寸对应 `design-system/default/MASTER.md`，集中在这里避免各页面
/// 各自猜测深色值，后续移动端也可以复用同一套语义。
abstract final class PlannerPalette {
  static const canvas = Color(0xff0c1522);
  static const navigation = Color(0xff101b2a);
  static const surface = Color(0xff142131);
  static const surfaceRaised = Color(0xff182738);
  static const surfaceHover = Color(0xff1d3045);
  static const outline = Color(0xff2a3b50);
  static const textPrimary = Color(0xfff4f7fb);
  static const textSecondary = Color(0xffa9b6c7);
  static const textMuted = Color(0xff78889d);
  static const accent = Color(0xff2f86ff);
  static const accentHover = Color(0xff5aa0ff);
  static const positive = Color(0xff53c7a5);
  static const warning = Color(0xfff2b35d);
  static const danger = Color(0xfff06f7a);
}

abstract final class PlannerTheme {
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: PlannerPalette.accent,
      onPrimary: PlannerPalette.textPrimary,
      primaryContainer: Color(0xff163b67),
      onPrimaryContainer: Color(0xffd7e9ff),
      secondary: PlannerPalette.positive,
      onSecondary: Color(0xff08251d),
      secondaryContainer: Color(0xff173e39),
      onSecondaryContainer: Color(0xffc9f2e7),
      tertiary: PlannerPalette.warning,
      onTertiary: Color(0xff2d1b00),
      tertiaryContainer: Color(0xff49371f),
      onTertiaryContainer: Color(0xffffe4ba),
      error: PlannerPalette.danger,
      onError: Color(0xff310006),
      surface: PlannerPalette.surface,
      onSurface: PlannerPalette.textPrimary,
      onSurfaceVariant: PlannerPalette.textSecondary,
      outline: PlannerPalette.outline,
      outlineVariant: Color(0xff213247),
      shadow: Color(0x66000000),
      scrim: Color(0xaa000000),
    );

    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: PlannerPalette.canvas,
      fontFamily: 'Microsoft YaHei UI',
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          color: PlannerPalette.textPrimary,
          fontSize: 30,
          height: 1.2,
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          color: PlannerPalette.textPrimary,
          fontSize: 24,
          height: 1.25,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          color: PlannerPalette.textPrimary,
          fontSize: 18,
          height: 1.35,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          color: PlannerPalette.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          color: PlannerPalette.textPrimary,
          height: 1.55,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: PlannerPalette.textSecondary,
          height: 1.55,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          color: PlannerPalette.textMuted,
          height: 1.5,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: PlannerPalette.canvas,
        foregroundColor: PlannerPalette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 20,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: PlannerPalette.navigation,
        elevation: 0,
        useIndicator: true,
        indicatorColor: Color(0xff173b67),
        minWidth: 72,
        minExtendedWidth: 196,
        groupAlignment: -0.72,
        selectedIconTheme: IconThemeData(
          color: PlannerPalette.accent,
          size: 22,
        ),
        unselectedIconTheme: IconThemeData(
          color: PlannerPalette.textMuted,
          size: 21,
        ),
        selectedLabelTextStyle: TextStyle(
          color: PlannerPalette.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: PlannerPalette.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      cardTheme: const CardThemeData(
        color: PlannerPalette.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: PlannerPalette.outline),
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: PlannerPalette.outline,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? PlannerPalette.accentHover
                : PlannerPalette.accent,
          ),
          foregroundColor: const WidgetStatePropertyAll(
            PlannerPalette.textPrimary,
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: PlannerPalette.textSecondary,
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: PlannerPalette.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: PlannerPalette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: PlannerPalette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: PlannerPalette.accent, width: 2),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: PlannerPalette.surfaceRaised,
        side: const BorderSide(color: PlannerPalette.outline),
        labelStyle: const TextStyle(color: PlannerPalette.textSecondary),
        shape: const StadiumBorder(),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: PlannerPalette.surfaceRaised,
        contentTextStyle: TextStyle(color: PlannerPalette.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: PlannerPalette.accent,
      ),
    );
  }
}
