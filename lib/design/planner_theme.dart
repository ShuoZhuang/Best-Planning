import 'package:flutter/material.dart';
import 'package:personal_planner/application/appearance_service.dart';

/// “专注控制台”视觉令牌。
///
/// 颜色与尺寸对应 `design-system/default/MASTER.md`，集中在这里避免各页面
/// 各自猜测深色值，后续移动端也可以复用同一套语义。
///
/// **色值受 M2 的对比度约束**（路线图 §6：正文 ≥ 4.5:1，非文本控件 ≥ 3:1）。
/// 三个曾经不达标的取值与它们的实测替代（用与 `textContrastGuideline` 同一套 WCAG
/// 公式算出来的）：
///
/// | 令牌 | 旧值 | 旧实测 | 新值 | 新实测 |
/// | --- | --- | --- | --- | --- |
/// | `textMuted` | `#78889d` | **4.19**（对 `surfaceRaised`）→ 不达标 | `#8e9eb1` | **5.54** |
/// | `accent` | `#2f86ff` | 白字只有 **3.27** → 不达 4.5 | `#2a6cd2` | **4.61** |
/// | `accentHover` | `#5aa0ff` | 白字只有 **2.47** | `#2f6ecc` | **4.63** |
///
/// **为什么改颜色而不是改字号**：把按钮文字调大确实能让 3:1 的阈值适用于"大号文字"，
/// 但那是**用更大的字绕过标准**——真正的问题是这个蓝太亮，撑不住任何正常字号的文字。
/// 压暗之后按钮在深色面板上仍然是明显的主色（对 `canvas` 仍有 3.6:1），
/// 而文字终于读得清。
abstract final class PlannerPalette {
  static const canvas = Color(0xff0c1522);
  static const navigation = Color(0xff101b2a);
  static const surface = Color(0xff142131);
  static const surfaceRaised = Color(0xff182738);
  static const surfaceHover = Color(0xff1d3045);
  static const outline = Color(0xff2a3b50);
  static const textPrimary = Color(0xfff4f7fb);
  static const textSecondary = Color(0xffa9b6c7);
  static const textMuted = Color(0xff8e9eb1);
  static const accent = Color(0xff2a6cd2);
  static const accentHover = Color(0xff2f6ecc);
  static const positive = Color(0xff53c7a5);
  static const warning = Color(0xfff2b35d);
  static const danger = Color(0xfff06f7a);
}

@immutable
final class PlannerGlassTheme extends ThemeExtension<PlannerGlassTheme> {
  const PlannerGlassTheme({
    required this.mode,
    required this.surface,
    required this.surfaceHighlight,
    required this.chrome,
    required this.border,
    required this.ambientPrimary,
    required this.ambientSecondary,
    required this.shadow,
    required this.blurSigma,
    required this.chromeBlurSigma,
    required this.shadowBlur,
  });

  final PlannerMaterialMode mode;
  final Color surface;
  final Color surfaceHighlight;
  final Color chrome;
  final Color border;
  final Color ambientPrimary;
  final Color ambientSecondary;
  final Color shadow;
  final double blurSigma;
  final double chromeBlurSigma;
  final double shadowBlur;

  static PlannerGlassTheme of(BuildContext context) =>
      Theme.of(context).extension<PlannerGlassTheme>() ??
      forMode(PlannerMaterialMode.restrained);

  static PlannerGlassTheme forMode(PlannerMaterialMode mode) => switch (mode) {
    PlannerMaterialMode.off => const PlannerGlassTheme(
      mode: PlannerMaterialMode.off,
      surface: PlannerPalette.surface,
      surfaceHighlight: PlannerPalette.surface,
      chrome: PlannerPalette.navigation,
      border: PlannerPalette.outline,
      ambientPrimary: Colors.transparent,
      ambientSecondary: Colors.transparent,
      shadow: Colors.transparent,
      blurSigma: 0,
      chromeBlurSigma: 0,
      shadowBlur: 0,
    ),
    PlannerMaterialMode.restrained => const PlannerGlassTheme(
      mode: PlannerMaterialMode.restrained,
      surface: Color(0xcc142131),
      surfaceHighlight: Color(0xd6182a3d),
      chrome: Color(0xc4101b2a),
      border: Color(0x26ffffff),
      ambientPrimary: Color(0x332f86ff),
      ambientSecondary: Color(0x1c53c7a5),
      shadow: Color(0x38000000),
      blurSigma: 16,
      chromeBlurSigma: 18,
      shadowBlur: 24,
    ),
    PlannerMaterialMode.aggressive => const PlannerGlassTheme(
      mode: PlannerMaterialMode.aggressive,
      surface: Color(0xa6142131),
      surfaceHighlight: Color(0xb51d3045),
      chrome: Color(0x99101b2a),
      border: Color(0x3dffffff),
      ambientPrimary: Color(0x522f86ff),
      ambientSecondary: Color(0x3353c7a5),
      shadow: Color(0x66000000),
      blurSigma: 26,
      chromeBlurSigma: 28,
      shadowBlur: 34,
    ),
    PlannerMaterialMode.liquid => const PlannerGlassTheme(
      mode: PlannerMaterialMode.liquid,
      surface: Color(0x73142131),
      surfaceHighlight: Color(0x8a2b4562),
      chrome: Color(0x70101b2a),
      border: Color(0x66ffffff),
      ambientPrimary: Color(0x702f86ff),
      ambientSecondary: Color(0x5053c7a5),
      shadow: Color(0x80000000),
      blurSigma: 38,
      chromeBlurSigma: 40,
      shadowBlur: 44,
    ),
  };

  @override
  PlannerGlassTheme copyWith({
    PlannerMaterialMode? mode,
    Color? surface,
    Color? surfaceHighlight,
    Color? chrome,
    Color? border,
    Color? ambientPrimary,
    Color? ambientSecondary,
    Color? shadow,
    double? blurSigma,
    double? chromeBlurSigma,
    double? shadowBlur,
  }) => PlannerGlassTheme(
    mode: mode ?? this.mode,
    surface: surface ?? this.surface,
    surfaceHighlight: surfaceHighlight ?? this.surfaceHighlight,
    chrome: chrome ?? this.chrome,
    border: border ?? this.border,
    ambientPrimary: ambientPrimary ?? this.ambientPrimary,
    ambientSecondary: ambientSecondary ?? this.ambientSecondary,
    shadow: shadow ?? this.shadow,
    blurSigma: blurSigma ?? this.blurSigma,
    chromeBlurSigma: chromeBlurSigma ?? this.chromeBlurSigma,
    shadowBlur: shadowBlur ?? this.shadowBlur,
  );

  @override
  PlannerGlassTheme lerp(PlannerGlassTheme? other, double t) {
    if (other == null) return this;
    return PlannerGlassTheme(
      mode: t < 0.5 ? mode : other.mode,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHighlight: Color.lerp(
        surfaceHighlight,
        other.surfaceHighlight,
        t,
      )!,
      chrome: Color.lerp(chrome, other.chrome, t)!,
      border: Color.lerp(border, other.border, t)!,
      ambientPrimary: Color.lerp(ambientPrimary, other.ambientPrimary, t)!,
      ambientSecondary: Color.lerp(
        ambientSecondary,
        other.ambientSecondary,
        t,
      )!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      blurSigma: _lerpDouble(blurSigma, other.blurSigma, t),
      chromeBlurSigma: _lerpDouble(chromeBlurSigma, other.chromeBlurSigma, t),
      shadowBlur: _lerpDouble(shadowBlur, other.shadowBlur, t),
    );
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

abstract final class PlannerTheme {
  static ThemeData dark({
    PlannerMaterialMode glassMode = PlannerMaterialMode.restrained,
  }) {
    final glass = PlannerGlassTheme.forMode(glassMode);
    final scheme = ColorScheme.dark(
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
      surface: glass.surface,
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
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: 'Microsoft YaHei UI',
      extensions: [glass],
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
      appBarTheme: AppBarTheme(
        backgroundColor: glass.chrome,
        foregroundColor: PlannerPalette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 20,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Colors.transparent,
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
      cardTheme: CardThemeData(
        color: glass.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: glass.border),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
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
      // **`OutlinedButton` 此前没有主题**（M2 对比度实测发现）：没配 `style` 时它的
      // 前景色回落到 `colorScheme.primary`，即那个亮蓝，画在深色表面上只有 **2.17:1**
      // ——"本周／今天／本月／自定义范围"这些按钮上的字就是这么淡的。这里补上与其他
      // 次级按钮一致的配色：前景用正文色（7.9:1），描边用 `outline`。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: PlannerPalette.textSecondary,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          side: const BorderSide(color: PlannerPalette.outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      // 同上：`ChoiceChip`／`FilterChip` 此前只配了底色与描边，**没配文字色**，
      // 选中态更是完全走默认（深色主题下 Material 的默认选中文字色对比不足）。
      // 任务页筛选栏与统计页的图型选择都用到它们，因此在这里一次配齐：
      // 未选中用正文色，选中用主色底 + 近白字（`onPrimaryContainer`）。
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: PlannerPalette.surfaceRaised,
        selectedColor: PlannerPalette.accent,
        side: const BorderSide(color: PlannerPalette.outline),
        labelStyle: const TextStyle(
          color: PlannerPalette.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: const TextStyle(
          color: PlannerPalette.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        shape: const StadiumBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glassMode == PlannerMaterialMode.off
            ? PlannerPalette.surface
            : const Color(0xe6142131),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: PlannerPalette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: glass.border),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: PlannerPalette.accent, width: 2),
        ),
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
