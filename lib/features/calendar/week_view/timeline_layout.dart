import 'dart:math' as math;

import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

/// 周时间轴的**纯几何**：给定一天的条目，算出每一块画在哪、多高、多宽。
///
/// **为什么抽成不依赖 Flutter 的纯函数**（与 M1 的 `task_list_filter.dart` 同一做法）：
/// "高度与时长成比例"和"重叠的块并排"这两件事都**很容易算错，而肉眼极难发现**——
/// 一眼看去"排得挺整齐"，实际上两块各占一半宽却仍然左右重叠，或者 30 分钟与 60 分钟
/// 高度差不多。做成纯函数就能穷举边界（交叉、嵌套、相邻、极短、跨午夜、空）。
final class TimelineMetrics {
  const TimelineMetrics({
    required this.windowStartMinute,
    required this.windowEndMinute,
    required this.pixelsPerMinute,
    required this.minimumBlockHeight,
  });

  /// 可见范围的起点：**当天第几分钟**（0..1440）。
  final int windowStartMinute;
  final int windowEndMinute;

  /// 每分钟多少像素。这是"真实时间比例"的唯一来源。
  final double pixelsPerMinute;

  /// 极短任务的最小可点击高度。没有它，一个 5 分钟的块会变成 2 像素、点不中。
  final double minimumBlockHeight;

  int get windowMinutes => windowEndMinute - windowStartMinute;

  /// 整个可见范围的高度。
  double get contentHeight => windowMinutes * pixelsPerMinute;

  /// 某分钟（当天第几分钟）对应的纵坐标。
  double topFor(int minute) => (minute - windowStartMinute) * pixelsPerMinute;

  /// 一段时长对应的高度，**下限是 [minimumBlockHeight]**。
  ///
  /// 比例关系只在"没有触及下限"时严格成立——这是有意的：宁可让极短任务看起来偏高，
  /// 也不能让它小到点不中。测试对两种情形分别断言。
  double heightFor(int minutes) =>
      math.max(minutes * pixelsPerMinute, minimumBlockHeight);

  /// 这个范围是不是被最小高度"抬"过（用于测试与调试）。
  bool isClampedFor(int minutes) =>
      minutes * pixelsPerMinute < minimumBlockHeight;
}

/// 时间轴上的一块。
final class TimelineBlock {
  const TimelineBlock({
    required this.itemId,
    required this.top,
    required this.height,
    required this.lane,
    required this.laneCount,
  });

  final String itemId;
  final double top;
  final double height;

  /// 并排时的第几列（从 0 起）。
  final int lane;

  /// 本块所在**团**里必须并排的总列数。
  final int laneCount;

  /// 宽度占整列的比例。
  double get widthFraction => 1 / laneCount;

  /// 左边界占整列的比例。
  double get leftFraction => lane / laneCount;
}

/// 一天的可见时间范围：**用户有安排的有效范围**，向内取整并留出余量。
///
/// - 无条目时回落到 08:00–22:00：给一个可用的默认视野，而不是 0 高度的空图。
/// - 内外都按 [stepMinutes] 取整，让刻度落在整点/半点上。
/// - 至少保留 [minimumWindowMinutes]，否则"只安排了一件事"会得到一条极扁的带子。
({int start, int end}) timelineWindowFor(
  Iterable<({int start, int end})> ranges, {
  int fallbackStart = 8 * 60,
  int fallbackEnd = 22 * 60,
  int stepMinutes = 30,
  int minimumWindowMinutes = 120,
}) {
  final list = ranges.toList();
  if (list.isEmpty) return (start: fallbackStart, end: fallbackEnd);

  var earliest = list.first.start;
  var latest = list.first.end;
  for (final range in list) {
    if (range.start < earliest) earliest = range.start;
    if (range.end > latest) latest = range.end;
  }

  // 向内取整：起点往下取、终点往上取，保证不会把内容裁掉。
  var start = (earliest ~/ stepMinutes) * stepMinutes;
  var end = ((latest + stepMinutes - 1) ~/ stepMinutes) * stepMinutes;
  // 夹在一天之内（跨午夜的块已按当天裁剪，但调用方可能传进来未裁剪的值）。
  start = start.clamp(0, 24 * 60);
  end = end.clamp(0, 24 * 60);

  if (end - start < minimumWindowMinutes) {
    // **先往上扩，再往下补**。反过来做是错的：先把起点往下拉，用户看到的视野就整体左移了
    // ——"09:10 的安排"被撑成"从 08:00 开始"，与"默认显示有效时间范围"相悖。
    // 往上扩不动（贴着 24:00）时才回头往下补。
    end = math.min(24 * 60, start + minimumWindowMinutes);
    if (end - start < minimumWindowMinutes) {
      start = math.max(0, end - minimumWindowMinutes);
    }
  }
  return (start: start, end: end);
}

/// 算出一天的并排布局。
///
/// **并排规则（这是本文件的核心）**：时间上重叠的两块在视觉上**绝不能重叠**，
/// 且同一时刻可见的块**都要能被看到**。
///
/// 做法是**团（clique）**：把"与当前团中任一块都重叠"的条目并入同一团；
/// 一旦某条与团中**所有**块都不重叠，就另起一团。团内的块两两重叠，因此团的大小
/// 就是"必须并排的最大数量"，每块宽度 = `1 / 团大小`。
///
/// **为什么不用"与已放下的块比较、找第一个空位"那种贪心**：它对**交叉区间**会给出
/// 不一致且常常仍然重叠的结果。例：A 09:00–11:00、B 09:30–10:00、C 10:30–11:30——
/// 三者两两重叠（A 与 C 也重叠），必须三列；贪心很容易只给出两列。
/// 团的做法对这种情形给出确定答案。
///
/// **每个团独立计算列数**：否则一个拥挤的上午会把整个下午也压窄。
List<TimelineBlock> layoutTimelineDay({
  required Iterable<ScheduleViewItem> items,
  required TimelineMetrics metrics,
  required int Function(ScheduleViewItem item) startMinuteOf,
  required int Function(ScheduleViewItem item) endMinuteOf,
}) {
  // 按开始时间排序；同一开始时间按结束时间排，保证结果稳定（同样的输入永远同样的输出）。
  final ordered = items.toList()
    ..sort((a, b) {
      final byStart = startMinuteOf(a).compareTo(startMinuteOf(b));
      if (byStart != 0) return byStart;
      return endMinuteOf(a).compareTo(endMinuteOf(b));
    });

  final blocks = <TimelineBlock>[];

  // 当前团：成员 (item, start, end, lane)。
  var clique = <({ScheduleViewItem item, int start, int end, int lane})>[];

  void flush() {
    if (clique.isEmpty) return;
    // 团的大小 = 必须并排的最大列数。
    final laneCount = clique.length;
    for (final member in clique) {
      blocks.add(
        TimelineBlock(
          itemId: member.item.id,
          top: metrics.topFor(member.start),
          height: metrics.heightFor(member.end - member.start),
          lane: member.lane,
          laneCount: laneCount,
        ),
      );
    }
    clique = <({ScheduleViewItem item, int start, int end, int lane})>[];
  }

  for (final item in ordered) {
    final start = startMinuteOf(item);
    final end = endMinuteOf(item);
    // 与当前团中**所有**成员都不重叠 → 团结束，另起一团。
    final overlapsAny = clique.any(
      (member) => start < member.end && member.start < end,
    );
    if (clique.isNotEmpty && !overlapsAny) flush();
    // 团内按加入顺序（即开始时间顺序）分配列号，因此结果对同样输入永远一致。
    clique.add((item: item, start: start, end: end, lane: clique.length));
  }
  flush();

  return blocks;
}

/// 把一个（**本地**）时刻换算成"当天第几分钟"。
///
/// 时间轴的纵坐标只关心"几点几分"，不关心日期——日期由列决定。
int minuteOfDay(DateTime local) => local.hour * 60 + local.minute;

/// 把一条已按当天裁剪的区间换算成 `(startMinute, endMinute)`。
///
/// **跨午夜要特别处理**：一块 23:00–01:00 经数据源按当天裁剪后，结束时间正好落在
/// **次日 00:00**，`minuteOfDay` 得到 0；直接相减会得到 -1380。这里按
/// "结束不早于开始"钳制：结束落在同一天更早的时刻时，视为当天 24:00（画到列底）。
///
/// [startLocal] / [endLocal] 必须是**已经换算成本地时间**的值——换算由调用方
/// （页面持有 `toLocal`）负责，与今日页、单日页同一分工。
({int start, int end}) minuteRangeInDay(
  DateTime startLocal,
  DateTime endLocal,
) {
  final start = minuteOfDay(startLocal).clamp(0, 24 * 60);
  final rawEnd = minuteOfDay(endLocal);
  final end = rawEnd <= start ? 24 * 60 : rawEnd;
  return (start: start, end: end.clamp(0, 24 * 60));
}
