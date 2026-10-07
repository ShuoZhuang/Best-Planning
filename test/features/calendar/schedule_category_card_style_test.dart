// 共享卡片视觉派生器的验收测试。
//
// **为什么要有这个文件**：卡片的深浅不是一个"随手挑个透明度"的审美问题。今天、七日历、
// 单日详情此前各自写了自己的 `withValues(alpha: …)`，同一个事项在三个页面里颜色不同，而且
// 越调越浅。这里把"派生规则"钉成一张**常量表**：测试不复刻 `Color.lerp` 的实现，而是直接
// 断言发布前人工确认过的十六进制值，公式被改动时测试会红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';

/// 只用于断言的 WCAG 相对对比度：`(亮 + 0.05) / (暗 + 0.05)`。
///
/// 刻意写在测试里而不是抽进生产代码：生产代码不需要它，而它一旦被抽出去就很容易被
/// "顺手调松"，那样对比度下限就再也守不住了。
double contrastRatio(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}

/// 旧版（1.0.11）卡片底色的**实测最亮值**，作为新卡片填充亮度的硬上限。
///
/// 取样来自用户提供的 1.0.11 真实截图（`docs/release/build-ledger.md` 记有出处）：
///
/// | 位置 | 卡片底色 | 相对亮度 |
/// | --- | --- | ---: |
/// | 今日·任务 | `#2C353E` | 0.0343 |
/// | 今日·保护时间 | `#1B3543` | 0.0318 |
/// | 七日·任务 | `#173E39` | 0.0392 |
/// | 七日·保护时间 | `#49371F` | 0.0425 |
/// | 七日·固定日程 | `#163B67` | **0.0428** ← 取这一张 |
///
/// 取"最亮的一张"而不是平均值：用户对亮度的感受由最亮的那几张决定，平均值会把它摊平
/// （`0.18` 的平均只比旧版高 14%，看起来"差不多"，最亮的却高了三成）。
const double _oldVersionBrightestCardLuminance = 0.0428;

/// 内置八色的**验收常量**：原始色 → 填充色 → 描边色。
///
/// 这是**人工确认过的值**，不是从实现反推的。两列的依据都是"与旧版的性格一致"，都有实测对照：
///
/// - **填充（色相不变 + 饱和度≤60% + 明度求解到亮度 `0.034`）**：八色亮度 `0.0335 ~ 0.0348`
///   （1.04 倍，几乎完全一致），落在旧版实测 `0.0318 ~ 0.0428` 的低端；**饱和度 40% ~ 76%**，
///   对应旧版的 **58% ~ 79%**。
/// - **描边（同一规则，亮度 `0.065`）**：八色亮度 `0.0642 ~ 0.0665`，落在旧版实测
///   `0.0420 ~ 0.0907` 的中段。
///
/// **这张表换过一次公式，原因值得留在这里**：早期用的是 `lerp(表面色, 分类色, t)`，`t` 从
/// `0.26` 一路降到 `0.12` 都没解决问题——因为混色把"变深"和"掉彩度"绑死了：`t = 0.12` 时琥珀色
/// 算出 `#2F3336`，HSV 饱和度只剩 **13%**，等于一块中性灰。用户的原话是"颜色比老版的浅还淡，
/// 看着还亮"——既是没彩度的灰（淡），又是被提亮的灰（浅、亮）。而旧版卡片是**深 + 有彩度**。
/// 所以现在改成：色相与彩度取自分类色，明度由目标亮度解出来。
const List<({int source, int fill, int border})> _approvedPalette = [
  (source: 0xff2f86ff, fill: 0xff17345b, border: 0xff20487f),
  (source: 0xff53c7a5, fill: 0xff133b2f, border: 0xff1b5241),
  (source: 0xfff2b35d, fill: 0xff463011, border: 0xff604218),
  (source: 0xfff06f7a, fill: 0xff62191f, border: 0xff88222b),
  (source: 0xffb391d3, fill: 0xff43265e, border: 0xff5d3483),
  (source: 0xff5ec8e5, fill: 0xff113843, border: 0xff174f5e),
  (source: 0xff7f92b2, fill: 0xff2a3546, border: 0xff3a4961),
  (source: 0xffa8b86f, fill: 0xff30371b, border: 0xff434c25),
];

void main() {
  test('derives the approved deep study card colors', () {
    const source = Color(0xff2f86ff);
    final style = scheduleCategoryCardStyle(source);

    expect(style.accent.toARGB32(), 0xff2f86ff);
    expect(style.fill.toARGB32(), 0xff17345b);
    expect(style.border.toARGB32(), 0xff20487f);
  });

  test('强调色原样保留，不由派生器改写', () {
    for (final entry in _approvedPalette) {
      final style = scheduleCategoryCardStyle(Color(entry.source));
      expect(style.accent.toARGB32(), entry.source);
    }
  });

  test('内置八色的填充与描边等于验收常量', () {
    for (final entry in _approvedPalette) {
      final style = scheduleCategoryCardStyle(Color(entry.source));
      expect(
        style.fill.toARGB32(),
        entry.fill,
        reason: '0x${entry.source.toRadixString(16)} 的填充色偏离验收值',
      );
      expect(
        style.border.toARGB32(),
        entry.border,
        reason: '0x${entry.source.toRadixString(16)} 的描边色偏离验收值',
      );
    }
  });

  test('八个内置领域色都派生出不透明、低亮、可读的深色卡片', () {
    expect(areaPaletteArgb, hasLength(8));
    for (final argb in areaPaletteArgb) {
      final style = scheduleCategoryCardStyle(Color(argb));
      final reason = '领域色 0x${argb.toRadixString(16)}';

      // 表面必须完全不透明：半透明填充正是"卡片发白"的根因——底下的玻璃背景会透上来。
      expect(style.fill.toARGB32() >>> 24, 0xff, reason: '$reason 的填充不是不透明色');
      expect(style.border.toARGB32() >>> 24, 0xff, reason: '$reason 的描边不是不透明色');

      // **亮度上限是旧版的实测值，不是"随便定一个 0.07"**。
      //
      // 原来的上限写的是 `0.07`——那比旧版最亮的卡片（`#163B67` = `0.0428`）高出一大截，等于
      // **根本没有守住"新卡片不能比旧版亮"**这条真正的需求。事实证明它会漏：比例升到 `0.18` 时，
      // 青绿 `0.0429`、琥珀 `0.0438`、青蓝 `0.0447` 三色都超过了旧版，而测试全绿——用户只好用
      // 眼睛来发现。这里改用**实测的旧版最亮卡片底色**做上限，那条回归就会在这里红掉。
      expect(
        style.fill.computeLuminance(),
        lessThanOrEqualTo(_oldVersionBrightestCardLuminance),
        reason:
            '$reason 的填充比旧版（1.0.11）最亮的卡片还亮——'
            '新卡片不允许比旧版亮，哪怕它仍然"不刺眼"',
      );

      // 领域原色仍是小面积强调，必须能从它自己的深色填充上分辨出来。
      expect(
        contrastRatio(style.accent, style.fill),
        greaterThanOrEqualTo(3),
        reason: '$reason 的强调色与填充对比度不足',
      );

      // 正文与次要文字在新深色底上仍然可读。
      expect(
        contrastRatio(PlannerPalette.textPrimary, style.fill),
        greaterThanOrEqualTo(4.5),
        reason: '$reason 的填充无法承载主文字',
      );
      expect(
        contrastRatio(PlannerPalette.textSecondary, style.fill),
        greaterThanOrEqualTo(3),
        reason: '$reason 的填充无法承载次要文字',
      );
    }
  });

  test('派生器对同一输入稳定，且不引入透明度分支', () {
    for (final argb in areaPaletteArgb) {
      final first = scheduleCategoryCardStyle(Color(argb));
      final second = scheduleCategoryCardStyle(Color(argb));
      expect(first.fill, second.fill);
      expect(first.border, second.border);
      expect(first.accent, second.accent);
    }
  });
}
