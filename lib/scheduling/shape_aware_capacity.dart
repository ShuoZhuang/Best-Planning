import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一件任务在**某个本地日**的形状容量（算法 20，规范 §5.3 / ALG20-019）。
///
/// 六个量回答的是六件不同的事，缺一个就会把"总空闲够但形状不够"说成
/// "可用时间不足"：
///
/// | 字段 | 回答 |
/// | --- | --- |
/// | [hardFreeMinutes] | 这一天扣掉硬占用后还有多少空闲 |
/// | [constraintEligibleMinutes] | 再按最早开始、截止、允许星期裁剪后还剩多少 |
/// | [placeableMinutes] | 按连续/拆分、最小/最大片段与粒度，实际能放多少 |
/// | [longestContiguousMinutes] | 最长的一段连续空闲有多长 |
/// | [slotCountByChunkSize] | 每个候选片段长度分别有多少个可放槽位 |
/// | [remainingTaskDailyLimitMinutes] | 任务自己的单日上限还剩多少 |
final class TaskDayCapacity {
  TaskDayCapacity({
    required this.taskId,
    required this.localDate,
    required this.hardFreeMinutes,
    required this.constraintEligibleMinutes,
    required this.placeableMinutes,
    required this.longestContiguousMinutes,
    required Map<int, int> slotCountByChunkSize,
    required this.remainingTaskDailyLimitMinutes,
    required this.remainingGlobalDailyLimitMinutes,
    required Map<CandidateRejectionCode, int> rejectionCounts,
  }) : slotCountByChunkSize = UnmodifiableMapView(
         Map<int, int>.of(slotCountByChunkSize),
       ),
       rejectionCounts = UnmodifiableMapView(
         Map<CandidateRejectionCode, int>.of(rejectionCounts),
       ) {
    if (hardFreeMinutes < 0 ||
        constraintEligibleMinutes < 0 ||
        placeableMinutes < 0 ||
        longestContiguousMinutes < 0 ||
        remainingTaskDailyLimitMinutes < 0 ||
        remainingGlobalDailyLimitMinutes < 0) {
      throw ArgumentError('容量字段不得为负');
    }
    if (placeableMinutes > constraintEligibleMinutes) {
      throw ArgumentError(
        '可落地容量（$placeableMinutes）不得超过合规容量'
        '（$constraintEligibleMinutes）',
      );
    }
    if (constraintEligibleMinutes > hardFreeMinutes) {
      throw ArgumentError(
        '合规容量（$constraintEligibleMinutes）不得超过日硬空闲'
        '（$hardFreeMinutes）',
      );
    }
  }

  final String taskId;
  final DateTime localDate;
  final int hardFreeMinutes;
  final int constraintEligibleMinutes;
  final int placeableMinutes;
  final int longestContiguousMinutes;
  final Map<int, int> slotCountByChunkSize;
  final int remainingTaskDailyLimitMinutes;
  final int remainingGlobalDailyLimitMinutes;
  final Map<CandidateRejectionCode, int> rejectionCounts;

  bool get canPlaceAnything => placeableMinutes > 0;

  /// 形状签名：长度多重集 + 最长连续段 + 槽位数。用于确定性去重。
  List<Object> get shapeSignature => [
    localDate.year,
    localDate.month,
    localDate.day,
    hardFreeMinutes,
    constraintEligibleMinutes,
    placeableMinutes,
    longestContiguousMinutes,
    for (final size in slotCountByChunkSize.keys.toList()..sort())
      [size, slotCountByChunkSize[size]],
  ];
}

/// 计算 `taskDayCapacities`：逐任务、逐本地日的形状容量。
///
/// **唯一事实源**：空闲来自 [availability]，每日上限与粒度来自 [ledger] 与逐日策略，
/// 已选块来自 [allBlocks]。诊断、分配与预览都应当读这份结果，而不是各自再算一遍。
Map<String, Map<DateTime, TaskDayCapacity>> buildTaskDayCapacities({
  required ScheduleProblem problem,
  required AvailabilityAnalysis availability,
  required DayCapacityLedger ledger,
  required List<PlannedBlock> allBlocks,
  required TimeZoneDatabase zones,
}) {
  final slotsByDate = <DateTime, List<AvailabilitySlot>>{};
  for (final slot in availability.slots) {
    slotsByDate
        .putIfAbsent(normalizeLocalDate(slot.localDate), () => [])
        .add(slot);
  }
  final hardFreeByDate = <DateTime, int>{};
  for (final slot in availability.hardFreeSlots) {
    final date = normalizeLocalDate(slot.localDate);
    hardFreeByDate[date] = (hardFreeByDate[date] ?? 0) + slot.durationMinutes;
  }
  final usedMovableByDate = <DateTime, int>{};
  final usedByTaskDate = <String, Map<DateTime, int>>{};
  for (final block in allBlocks) {
    final date = localDateOf(block.startUtc, problem.timeZoneId, zones);
    usedMovableByDate[date] =
        (usedMovableByDate[date] ?? 0) + block.durationMinutes;
    usedByTaskDate
        .putIfAbsent(block.taskId, () => {})
        .update(
          date,
          (value) => value + block.durationMinutes,
          ifAbsent: () => block.durationMinutes,
        );
  }

  final result = <String, Map<DateTime, TaskDayCapacity>>{};
  for (final task in problem.tasks) {
    final byDate = <DateTime, TaskDayCapacity>{};
    for (final date in ledger.localDates) {
      final policy = problem.policyForLocalDate(date);
      final rules = policy.resolvedRules;
      final hardFree = hardFreeByDate[date] ?? 0;
      final ranges = <TimeRange>[];
      if (task.allowsWeekday(date.weekday)) {
        for (final slot in slotsByDate[date] ?? const <AvailabilitySlot>[]) {
          var range = slot.range;
          final from = task.availableFromUtc;
          if (from != null && from.isAfter(range.startUtc)) {
            if (!range.endUtc.isAfter(from)) continue;
            range = TimeRange(startUtc: from, endUtc: range.endUtc);
          }
          final due = task.dueAtUtc;
          if (due != null && !due.isAfter(range.startUtc)) continue;
          if (due != null && range.endUtc.isAfter(due)) {
            range = TimeRange(startUtc: range.startUtc, endUtc: due);
          }
          if (range.endUtc.isAfter(range.startUtc)) ranges.add(range);
        }
      }
      final merged = _mergeRanges(ranges);
      final eligible = _sum(merged);
      final longest = merged.isEmpty
          ? 0
          : merged
                .map((range) => range.durationMinutes)
                .reduce((a, b) => a > b ? a : b);
      final taskUsed = usedByTaskDate[task.id]?[date] ?? 0;
      final taskLimit = task.maxMinutesPerLocalDay;
      final remainingTaskLimit = taskLimit == null
          ? 24 * 60
          : (taskLimit - taskUsed).clamp(0, 24 * 60);
      final globalLimit = rules.dailyMovableTaskLimitMinutes;
      final remainingGlobalLimit =
          (globalLimit - (usedMovableByDate[date] ?? 0)).clamp(0, 24 * 60);

      final shape = _placeableShape(
        task: task,
        ranges: merged,
        granularity: rules.granularityMinutes,
        remainingTaskLimit: remainingTaskLimit,
        remainingGlobalLimit: remainingGlobalLimit,
      );
      final rejectionCounts = <CandidateRejectionCode, int>{};
      if (remainingTaskLimit <= 0) {
        rejectionCounts[CandidateRejectionCode.exceedsDailyTaskLimit] = 1;
      }
      if (remainingGlobalLimit <= 0) {
        rejectionCounts[CandidateRejectionCode.exceedsDailyMovableLimit] = 1;
      }
      if (eligible > 0 && shape.placeable == 0) {
        rejectionCounts[CandidateRejectionCode.exceedsGapCapacity] = 1;
      }
      byDate[date] = TaskDayCapacity(
        taskId: task.id,
        localDate: date,
        hardFreeMinutes: hardFree,
        constraintEligibleMinutes: eligible,
        placeableMinutes: shape.placeable,
        longestContiguousMinutes: longest,
        slotCountByChunkSize: shape.slotCounts,
        remainingTaskDailyLimitMinutes: remainingTaskLimit,
        remainingGlobalDailyLimitMinutes: remainingGlobalLimit,
        rejectionCounts: rejectionCounts,
      );
    }
    result[task.id] = byDate;
  }
  return result;
}

final class _Shape {
  const _Shape({required this.placeable, required this.slotCounts});
  final int placeable;
  final Map<int, int> slotCounts;
}

_Shape _placeableShape({
  required SchedulableTask task,
  required List<TimeRange> ranges,
  required int granularity,
  required int remainingTaskLimit,
  required int remainingGlobalLimit,
}) {
  final cap = remainingTaskLimit < remainingGlobalLimit
      ? remainingTaskLimit
      : remainingGlobalLimit;
  if (ranges.isEmpty || task.requiredMinutes <= 0 || cap <= 0) {
    return const _Shape(placeable: 0, slotCounts: {});
  }

  if (task.splitMode == TaskSplitMode.continuous) {
    final fitting = ranges.where(
      (range) => range.durationMinutes >= task.requiredMinutes,
    );
    if (fitting.isEmpty) {
      return _Shape(placeable: 0, slotCounts: {task.requiredMinutes: 0});
    }
    return _Shape(
      placeable: task.requiredMinutes < cap ? task.requiredMinutes : cap,
      slotCounts: {task.requiredMinutes: fitting.length},
    );
  }

  // **短余量**：剩余量本身短于最小片段时，唯一合法时长由
  // `shortRemainderAllowance` 决定（既有短尾契约），不能按 `minChunk` 向上取整——
  // 那会把 15 分钟任务的容量算成 0，进而让分配器不给它任何预算。
  if (task.requiredMinutes < task.minChunkMinutes) {
    final allowance = shortRemainderAllowance(
      requiredMinutes: task.requiredMinutes,
      granularityMinutes: granularity <= 0 ? 5 : granularity,
    );
    if (allowance <= 0) return const _Shape(placeable: 0, slotCounts: {});
    final fitting = ranges
        .where((range) => range.durationMinutes >= allowance)
        .length;
    if (fitting == 0) {
      return _Shape(placeable: 0, slotCounts: {allowance: 0});
    }
    final placeable = allowance < cap ? allowance : cap;
    return _Shape(placeable: placeable, slotCounts: {allowance: fitting});
  }

  final minChunk = _roundUp(task.minChunkMinutes, granularity);
  final maxChunk = task.maxChunkMinutes < task.requiredMinutes
      ? task.maxChunkMinutes
      : task.requiredMinutes;
  final maxAligned = _roundDown(maxChunk, granularity);
  if (minChunk <= 0 || maxAligned <= 0 || minChunk > maxAligned) {
    return const _Shape(placeable: 0, slotCounts: {});
  }
  final slotCounts = <int, int>{};
  var total = 0;
  for (var size = minChunk; size <= maxAligned; size += granularity) {
    slotCounts[size] = 0;
  }
  for (final range in ranges) {
    final chunks = range.durationMinutes ~/ minChunk;
    if (chunks <= 0) continue;
    total += chunks * minChunk;
    for (final size in slotCounts.keys) {
      if (range.durationMinutes >= size) {
        slotCounts[size] = slotCounts[size]! + 1;
      }
    }
  }
  if (total > task.requiredMinutes) total = task.requiredMinutes;
  if (total > cap) total = cap;
  return _Shape(placeable: total, slotCounts: slotCounts);
}

List<TimeRange> _mergeRanges(List<TimeRange> ranges) {
  if (ranges.isEmpty) return const [];
  final sorted = [...ranges]..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final merged = <TimeRange>[];
  var current = sorted.first;
  for (final next in sorted.skip(1)) {
    if (!next.startUtc.isAfter(current.endUtc)) {
      current = TimeRange(
        startUtc: current.startUtc,
        endUtc: next.endUtc.isAfter(current.endUtc)
            ? next.endUtc
            : current.endUtc,
      );
      continue;
    }
    merged.add(current);
    current = next;
  }
  merged.add(current);
  return merged;
}

int _sum(List<TimeRange> ranges) =>
    ranges.fold<int>(0, (sum, range) => sum + range.durationMinutes);

int _roundUp(int value, int step) =>
    step <= 0 ? value : ((value + step - 1) ~/ step) * step;

int _roundDown(int value, int step) =>
    step <= 0 ? value : (value ~/ step) * step;
