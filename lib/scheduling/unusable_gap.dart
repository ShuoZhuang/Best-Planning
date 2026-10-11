import 'dart:collection';

import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一段**无法利用的短空档**（1.8.0，设计规范 §11.4 第 6 条／§2.6）。
final class UnusableGap {
  const UnusableGap({required this.range, required this.smallestChunkMinutes});

  final TimeRange range;

  /// 当时还没完成的任务里**最小**的一个片段长度。空档比它还短，因此谁也放不进去。
  final int smallestChunkMinutes;

  int get minutes => range.durationMinutes;
}

/// 找出 [blocks] 之间的**无法利用的短空档**。
///
/// **什么叫"无法利用"**：一段空档比"当时还没完成的任务里最小的那个片段"还短，
/// 因此它放不下任何一件待办。规范 §2.6 的原话是"20 多分钟的空白可能既不是用户设置的休息，
/// 也放不下任何任务"。
///
/// **两条明确的排除**（规范全局不变量第 6 条"休息不是浪费"）：
/// - [protectedRanges] 覆盖的空档是用户**明确建立**的保护时间，不算坏空档；
/// - 比 [breakMinutes] 短的空档算**规则要求的间隔**，同样不算。
///
/// [tasks] 只应包含**还没排完的**任务：已经排满的任务不需要空档，把它算进来会让
/// "最小片段"偏大，从而把本来可用的空档误判成坏空档。任何一件任务都排不下时
/// （`tasks` 为空或全部为 0 分钟）返回空列表——那时"坏空档"这个概念没有意义。
///
/// **只看计划块之间的空档**，不看一天的头尾：起床前与睡前的空白不是"排程失败"，
/// 而是"这一天到点了"，把它算成浪费会让排程器为了填满而把任务排到深夜。
List<UnusableGap> findUnusableGaps({
  required List<PlannedBlock> blocks,
  required Iterable<SchedulableTask> tasks,
  List<TimeRange> protectedRanges = const [],
  int breakMinutes = 0,
}) {
  final smallestChunk = _smallestChunkMinutes(tasks);
  if (smallestChunk == null) return const [];

  // **合并重叠或相接的块之后再找空档**：两块首尾相接时中间的空档是 0 分钟，
  // 不先合并就会造出一堆零长度"空档"。同一任务被切成两段相邻的块也是常见情形。
  final ordered = [...blocks]..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  if (ordered.length < 2) return const [];

  final gaps = <UnusableGap>[];
  var cursorEnd = ordered.first.endUtc;
  for (final block in ordered.skip(1)) {
    if (!block.startUtc.isAfter(cursorEnd)) {
      // 重叠或相接：把游标推远，不产生空档。
      if (block.endUtc.isAfter(cursorEnd)) cursorEnd = block.endUtc;
      continue;
    }
    final range = TimeRange(startUtc: cursorEnd, endUtc: block.startUtc);
    final tooShortForAnyTask = range.durationMinutes < smallestChunk;
    final isRuleBreak =
        breakMinutes > 0 && range.durationMinutes < breakMinutes;
    final isProtected = protectedRanges.any(
      (protected) => protected.overlaps(range),
    );
    final isWasted = tooShortForAnyTask && !isRuleBreak && !isProtected;
    if (isWasted) {
      gaps.add(UnusableGap(range: range, smallestChunkMinutes: smallestChunk));
    }
    // **推进游标是循环的最后一步**（原先是第一步）。
    //
    // 原先这一行紧跟在 `range` 之后、在三个排除条件**之前**，于是被排除掉的那一段空档
    // 会把游标一路推到当前块的结束时刻，**连带吃掉它后面那一段**：
    // 09:00–09:30 / 09:40–10:00 / 10:10–10:30 在"休息间隔 15 分钟"下，
    // 第一段 09:30–09:40（10 分钟）被排除是对的，但游标被推到 10:00，
    // 于是第二段被量成 10:00–10:10（10 分钟），而它其实是 09:40–10:10 的 **30 分钟**。
    //
    // 后果是双重的：既漏报真正的 30 分钟空档，又凭空造出一段 10 分钟的空档；
    // 而"排除一条就吃掉下一条"会**连续累积**。浪费分钟数正是评分里那一条惩罚的原料。
    cursorEnd = block.endUtc;
  }
  return UnmodifiableListView(gaps);
}

/// 坏空档造成的**浪费分钟总数**，也就是评分里那一条惩罚的原料。
int unusableGapMinutes({
  required List<PlannedBlock> blocks,
  required Iterable<SchedulableTask> tasks,
  List<TimeRange> protectedRanges = const [],
  int breakMinutes = 0,
}) {
  var total = 0;
  for (final gap in findUnusableGaps(
    blocks: blocks,
    tasks: tasks,
    protectedRanges: protectedRanges,
    breakMinutes: breakMinutes,
  )) {
    total += gap.minutes;
  }
  return total;
}

/// 还没完成的任务里**最小**的一个片段长度；没有可排任务时返回 `null`。
///
/// **用 `minChunkMinutes` 而不是剩余时长**：一个还剩 120 分钟、最小片段 30 分钟的任务
/// 完全可以放进一个 30 分钟的空档——按剩余时长判断会把这种空档误判成坏空档，
/// 而它其实完全可用。
///
/// **用 `min` 而不是 `max`**：只要**有任意一件**任务放得下，这段空档就不是浪费的。
int? _smallestChunkMinutes(Iterable<SchedulableTask> tasks) {
  int? smallest;
  for (final task in tasks) {
    if (task.requiredMinutes <= 0) continue;
    // `minChunkMinutes` 为 0 表示"没有下限"（连续型任务），此时任何非零空档都可用，
    // 于是直接得出下限 1 分钟：它比任何非零空档都小，坏空档因此只剩零长度这种退化情形。
    final chunk = task.minChunkMinutes <= 0 ? 1 : task.minChunkMinutes;
    if (smallest == null || chunk < smallest) smallest = chunk;
  }
  return smallest;
}
