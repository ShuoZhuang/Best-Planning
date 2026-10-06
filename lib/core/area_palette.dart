/// 领域（学业／科研／竞赛／工作／生活…）的默认色板与取色规则。
///
/// 放在 `core` 而不是 `design`：**新建领域时要挑默认色**，而那一层是应用层，不该为了拿一个
/// 颜色整数去依赖 Flutter 的 `Color`。视图层再把这里的 ARGB 变成 `Color`。
///
/// 设计口径（`design-system/default/MASTER.md`）："领域色使用低饱和语义色，不得抢过主强调色"。
/// 因此这里是一组**固定的低饱和色**，而不是自由取色盘——自由取色很容易选出比主强调色更抢眼的
/// 颜色，把"当前状态／主行动"的视觉层级压掉。
library;

/// 领域默认色板（ARGB）。
///
/// 这几个色**刻意取自设计系统原有的语义色**（`PlannerPalette.accent` / `positive` /
/// `warning` / `danger`，以及原本"生活"用的紫），而不是另外调一组"低饱和"色：
/// 第一版我自行调了一组偏灰的蓝／赭／玫，明度和彩度都掉出原有那一带，落在深色底上发浑，
/// 比原来的观感差很多（用户反馈"比原先丑多了"）。沿用已验证的色，再补两个同族的。
///
/// 第一个色是主强调蓝、第五个是原本"生活"的紫：**新建库**里默认领域按顺序建立
/// （学业／科研／竞赛／工作／生活，见 `DefaultAreas`），因此"生活＝紫"这个原有观感得以保留。
///
/// 历史库要注意：它们颜色列一律是 0，取色按**各库自己的 sortOrder** 兜底，而早期种下的顺序与
/// 现在不同（实测某个库是 学业／科研／**生活**／竞赛／工作），因此那些库里"生活"未必落在紫上。
/// 这是兜底的固有代价，颜色本身用户可在领域设置里改。
const List<int> areaPaletteArgb = <int>[
  0xff2f86ff, // 蓝（= PlannerPalette.accent）
  0xff53c7a5, // 青绿（= PlannerPalette.positive）
  0xfff2b35d, // 琥珀（= PlannerPalette.warning）
  0xfff06f7a, // 玫红（= PlannerPalette.danger）
  0xffb391d3, // 紫（原本"生活"用的色）
  0xff5ec8e5, // 青蓝（同族补充）
];

/// 色板的可读名字，与 [areaPaletteArgb] 一一对应。
///
/// 给选择控件用：色块本身说不出自己叫什么，无障碍读屏与悬停提示需要一个名字。
const List<String> areaPaletteNames = <String>[
  '蓝',
  '青绿',
  '琥珀',
  '玫红',
  '紫',
  '青蓝',
];

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
