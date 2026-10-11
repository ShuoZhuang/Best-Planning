import 'dart:collection';

import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 相邻占用之间的一段间隔，按**用途**分成四类（设计规范 §12.1）。
///
/// **为什么四类而不是"坏／不坏"两分**：`unusable_gap.dart` 那套只回答"要不要惩罚"，
/// 而界面与解释需要回答"这段空白是什么"。四类的差别是**用户意图**的差别：
/// 规则休息与保护时间是用户要的，自由时间是"这一天到点了"，只有 orphan gap 才是失败。
/// 把后三类混成"没利用"会让排程器为了看起来紧凑去吞掉休息。
enum GapKind {
  /// 用户保护时间或规则要求的休息。**不惩罚**（全局不变量第 6 条"休息不是浪费"）。
  intentionalBreak,

  /// 至少能放入一个当前未完成任务的合法最小片段。
  usable,

  /// 大于所需过渡休息，但小于所有可候选任务的最小片段。**只有这一类计入惩罚。**
  orphan,

  /// 没有任务需要填入，或用户日容量已达到上限。**不惩罚。**
  ///
  /// 规范 §12.2 的原话："若硬约束决定它必须存在，界面把它显示为'空闲 20 分钟'，
  /// 而不是声称计划错误。"
  freeTime,
}

/// 一段已完成分类的间隔。
final class ClassifiedGap {
  const ClassifiedGap({
    required this.range,
    required this.kind,
    this.smallestChunkMinutes,
  });

  final TimeRange range;
  final GapKind kind;

  /// 当时"还没完成的任务里最小的片段"；没有可排任务时为 `null`。
  ///
  /// 保留它是为了让解释层能说清**为什么**这一段被判成 orphan
  /// （"放不下任何任务的 30 分钟最小片段"），而不是只给一个类别名。
  final int? smallestChunkMinutes;

  int get minutes => range.durationMinutes;
}

/// 把 [blocks] 之间的间隔逐段分类（设计规范 §12.1）。
///
/// **只看计划块之间的间隔**，不看一天的头尾：起床前与睡前的空白不是"排程失败"，
/// 而是"这一天到点了"。把它们算进来会让排程器为了填满而把任务排到深夜。
///
/// 判断顺序（**顺序本身就是语义**，"一段间隔只能归一类"）：
/// 1. 被 [protectedRanges] 覆盖，或短于 [breakMinutes] ⇒ [GapKind.intentionalBreak]；
/// 2. 没有可排任务，或已排分钟数 >= [dailyCapacityMinutes] ⇒ [GapKind.freeTime]；
/// 3. 短于最小片段 ⇒ [GapKind.orphan]；
/// 4. 否则 ⇒ [GapKind.usable]。
///
/// **第 1 条排在最前**：一段被保护时间覆盖的间隔无论多长都不是浪费，
/// 即便它同时"放得下任务"也不该被算成可用——那是用户明确说不排事的时间。
///
/// **第 2 条排在"可放性"之前**：日容量到顶之后剩下的空白不是"没能利用"，
/// 而是用户给自己设的上限；把它算成 orphan 会鼓励排程器忽视每日可排上限。
List<ClassifiedGap> classifyGaps({
  required List<PlannedBlock> blocks,
  required Iterable<SchedulableTask> tasks,
  List<TimeRange> protectedRanges = const [],
  int breakMinutes = 0,
  int? dailyCapacityMinutes,
}) {
  final ordered = [...blocks]..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  if (ordered.length < 2) return const [];

  final smallestChunk = _smallestChunkMinutes(tasks);
  // 已排分钟数只统计**可移动任务块**：固定日程与保护时间占用的是用户的硬约束时段，
  // 它们不该把"每日可排任务上限"提前吃满。
  final scheduledMinutes = ordered
      .where((block) => !block.locked)
      .fold<int>(0, (total, block) => total + block.durationMinutes);
  final capacityReached =
      dailyCapacityMinutes != null && scheduledMinutes >= dailyCapacityMinutes;

  final result = <ClassifiedGap>[];
  var cursorEnd = ordered.first.endUtc;
  for (final block in ordered.skip(1)) {
    if (!block.startUtc.isAfter(cursorEnd)) {
      // 重叠或相接：把游标推远，不产生间隔。
      if (block.endUtc.isAfter(cursorEnd)) cursorEnd = block.endUtc;
      continue;
    }
    final range = TimeRange(startUtc: cursorEnd, endUtc: block.startUtc);
    final isProtected = protectedRanges.any(
      (protected) => protected.overlaps(range),
    );
    final isRuleBreak =
        breakMinutes > 0 && range.durationMinutes < breakMinutes;

    final kind = switch (true) {
      _ when isProtected || isRuleBreak => GapKind.intentionalBreak,
      _ when smallestChunk == null || capacityReached => GapKind.freeTime,
      _ when range.durationMinutes < smallestChunk => GapKind.orphan,
      _ => GapKind.usable,
    };
    result.add(
      ClassifiedGap(
        range: range,
        kind: kind,
        smallestChunkMinutes: smallestChunk,
      ),
    );
    // **游标推进是最后一步**（与 `unusable_gap.dart` 同一个教训）：
    // 写在判定之前的话，被归为休息的那一段会把游标推到当前块结束，
    // **连带吃掉它后面那一段间隔**。
    cursorEnd = block.endUtc;
  }
  return UnmodifiableListView(result);
}

/// 还没完成的任务里**最小**的一个片段长度；没有可排任务时返回 `null`。
///
/// 与 `unusable_gap.dart` 的同名函数口径一致：用 `minChunkMinutes` 而不是剩余时长，
/// 且取 `min` 而不是 `max` —— 只要**有任意一件**任务放得下，这段间隔就是可用的。
int? _smallestChunkMinutes(Iterable<SchedulableTask> tasks) {
  int? smallest;
  for (final task in tasks) {
    if (task.requiredMinutes <= 0) continue;
    final chunk = task.minChunkMinutes <= 0 ? 1 : task.minChunkMinutes;
    if (smallest == null || chunk < smallest) smallest = chunk;
  }
  return smallest;
}
