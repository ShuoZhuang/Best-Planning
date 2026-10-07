import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 日程卡片按分类取的三个颜色：强调、填充、描边。
///
/// **为什么这三个值要绑在一个不可变对象里**：它们是从同一个分类色派生出来的，分开取用
/// 迟早会漂移——今天页面的 `alpha: 0.10` 与七日历的 `alpha: 0.18` 就是这么来的，同一个事项
/// 在三个页面里呈现出三种深浅。把它们绑在一起，页面就没有"自己再调一下"的余地。
@immutable
final class ScheduleCategoryCardStyle {
  const ScheduleCategoryCardStyle({
    required this.accent,
    required this.fill,
    required this.border,
  });

  /// 分类原色。只用于**小面积**强调：卡片左侧色条、时间轴圆点、分类图标与图例。
  final Color accent;

  /// 卡片表面填充。**完全不透明**，否则底下的玻璃背景会透上来把卡片冲淡。
  final Color fill;

  /// 卡片描边。同样不透明，且明显暗于 [accent]——描边可辨认，但不发光、不抢主按钮。
  final Color border;
}

/// 卡片填充的目标**相对亮度**。
///
/// `0.034` 是旧版（1.0.11）卡片底色的实测值：今日·任务 `#2C353E` = `0.0343`、
/// 今日·保护时间 `#1B3543` = `0.0318`（七日那几张是 `0.039 ~ 0.043`）。
///
/// **为什么是"目标亮度"而不是一个混色比例**：比例式派生（`lerp(表面色, 分类色, t)`）里，
/// 颜色越深就必然越靠近表面色，**饱和度同比掉光**。`t = 0.12` 时琥珀色算出来是 `#2F3336`
/// ——R47 G51 B54，HSV 饱和度只剩 **13%**，等于一块中性灰。用户的原话因此是"颜色比老版的
/// 浅还淡，看着还亮"：既没有彩度（淡），又是被提亮的灰（浅、亮）。而旧版卡片底色的饱和度是
/// **58% ~ 79%**——它是"深 + 有彩度"。降比例这条路走不到那里去。
const double _fillLuminance = 0.034;

/// 卡片描边的目标相对亮度。
///
/// `0.065` 落在旧版描边实测的 `0.0420 ~ 0.0907` 中段：可辨认，但不像 `0.32` 混色比例时期那样
/// （`0.0850 ~ 0.1239`）比旧版还亮、把卡片的"亮"转移到边线上。
const double _borderLuminance = 0.065;

/// 派生时允许的**饱和度上限**。
///
/// `0.60` 取自旧版实测卡片底色的饱和度下沿（58%）。取 `min(原色饱和度, 上限)` 而不是直接套用
/// 上限：本来就灰的色板色（如灰蓝 `#7f92b2`）不该被硬拉成彩色，那样又会变成"分类之间差别过大"。
const double _saturationCap = 0.60;

/// 求明度时的二分次数。20 次把 `[0, 1]` 收敛到 `1e-6`，远超 8 位色深所需；
/// 用固定次数而不是"迭代到误差小于 ε"，是为了让**同样的输入永远得到同样的输出**
/// （这个项目的排程与配色都要求可复现）。
const int _lightnessSearchSteps = 20;

/// 由分类色派生卡片的强调色、填充色与描边色。
///
/// **今日、七日历、单日详情必须共用这一个函数**：跨页面一致性就是"同一个事项在三个页面里
/// 逐值相等"，任何页面自己算一遍都会破坏它。这里刻意不接受页面、任务类型或玻璃模式参数——
/// 那些维度正是之前让颜色分叉的原因。任务类型由图标表达，不再参与配色。
ScheduleCategoryCardStyle scheduleCategoryCardStyle(Color categoryColor) {
  return ScheduleCategoryCardStyle(
    accent: categoryColor,
    fill: toneAtLuminance(categoryColor, _fillLuminance),
    border: toneAtLuminance(categoryColor, _borderLuminance),
  );
}

/// 取 [categoryColor] 的**色相**，把饱和度压到 [_saturationCap] 以内，再解出明度，
/// 使结果的相对亮度等于 [targetLuminance]。
///
/// **为什么在 HSL 里做而不是直接混色**：混色把"变深"和"掉彩度"绑死；这里两者分开——色相和
/// 彩度来自分类色，明度由目标亮度决定。这样八张卡片**明度一致**（实测 `0.0335 ~ 0.0348`，
/// 1.04 倍），又是**有彩度的深色**，与旧版卡片底色的性格一致。
///
/// 明度没有闭式解：相对亮度是明度的非线性函数（同样的明度下，黄比蓝亮得多）。所以这里二分求解，
/// 并且用的是 `computeLuminance()`——也就是验收测试所用的同一个量，避免"算的是一个、测的是另一个"。
Color toneAtLuminance(Color categoryColor, double targetLuminance) {
  final hsl = HSLColor.fromColor(categoryColor);
  final saturation = math.min(hsl.saturation, _saturationCap);
  var low = 0.0;
  var high = 1.0;
  for (var step = 0; step < _lightnessSearchSteps; step++) {
    final mid = (low + high) / 2;
    final probe = hsl
        .withSaturation(saturation)
        .withLightness(mid)
        .toColor()
        .computeLuminance();
    if (probe < targetLuminance) {
      low = mid;
    } else {
      high = mid;
    }
  }
  // 结果不透明：`HSLColor.toColor()` 的 alpha 恒为 1，而分类色本身也是不透明的。
  return hsl
      .withSaturation(saturation)
      .withLightness((low + high) / 2)
      .toColor();
}
