/// 领域（学业／科研／竞赛／工作／生活…）的默认色板与取色规则。
///
/// 放在 `core` 而不是 `design`：**新建领域时要挑默认色**，而那一层是应用层，不该为了拿一个
/// 颜色整数去依赖 Flutter 的 `Color`。视图层再把这里的 ARGB 变成 `Color`。
///
/// 设计口径（`design-system/default/MASTER.md`）："领域色使用低饱和语义色，不得抢过主强调色"。
/// 因此这里是一组**固定的低饱和色**，而不是自由取色盘——自由取色很容易选出比主强调色更抢眼的
/// 颜色，把"当前状态／主行动"的视觉层级压掉。
library;

/// 领域默认色板（ARGB）：蓝、青绿、赭、紫、玫、灰蓝。
const List<int> areaPaletteArgb = <int>[
  0xff4a7bd1,
  0xff5aa88a,
  0xffb98a4a,
  0xff7d6bb5,
  0xffc07a8c,
  0xff6f8fa8,
];

/// 色板的可读名字，与 [areaPaletteArgb] 一一对应。
///
/// 给选择控件用：色块本身说不出自己叫什么，无障碍读屏与悬停提示需要一个名字。
const List<String> areaPaletteNames = <String>['蓝', '青绿', '赭', '紫', '玫', '灰蓝'];

/// `areas.color` 为 0 表示**没有选过颜色**。
///
/// 这是一条兼容约定而不是猜测：列一直存在，但建表以来的写入路径都写的是 0，因此历史库里
/// 每个领域都是 0。把 0 当作"未设置"并按排序落到色板上，就**不需要数据迁移**也能立刻用上
/// 颜色；用户一旦选过，存的就是真实 ARGB，不会再是 0（纯黑是 `0xff000000`，与 0 可区分）。
int resolveAreaColorArgb({required int storedColor, required int sortOrder}) {
  if (storedColor != 0) return storedColor;
  final index = sortOrder < 0 ? 0 : sortOrder % areaPaletteArgb.length;
  return areaPaletteArgb[index];
}

/// 该领域是否使用自定义颜色（而不是回落到色板）。
bool hasCustomAreaColor(int storedColor) => storedColor != 0;
