import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/scheduling/day_allocation.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一份方案**结构上**违规的类别（算法 17，计划 Task 7 Step 4）。
///
/// 与 `PlanValidator` 的分工：后者校验"块与固定日程／保护时间／睡眠／每日上限
/// 是否冲突"这些**对外可解释**的硬约束；这里校验的是**方案自身的自洽性**——
/// 块集合是否真的对应输入、是否真的守住了分配器给的预算。
///
/// 为什么需要它：`_improve` 是"逐块找更好的位置"，它的每一次替换都是局部的。
/// 局部最优的替换完全可能造出一份**结构上已经不再是合法方案**的块集合
/// （超日预算、任务分钟超发、重复 ID），而 `PlanValidator` 看不出这些。
enum PlanQualityViolationCode {
  /// 块 ID 重复。同一份方案里出现两个相同 id 会让"改哪一块"变得不可定义。
  duplicateBlockId,

  /// 任务被安排了**超过它目标**的分钟（超发）。
  ///
  /// 超发几乎总是"改进阶段把块搬到了已有块旁边"的副作用，它会静默消耗掉别
  /// 的任务的容量。
  taskMinutesExceedTarget,

  /// 某任务在某本地日超过了分配器给的预算。
  ///
  /// 这一条是算法 17 的核心纪律：预算来自方案级分配，局部改进无权突破它。
  exceedsDayBudget,

  /// 某本地日超过它自己的每日硬上限（逐日规则）。
  exceedsDailyHardLimit,

  /// 仍有合法候选却留下缺口——"排不下"与"没排好"是两件事。
  unexplainedShortage,

  /// 块集合与搜索结果不一致：方案声称还有缺口，但所有任务都排满了；
  /// 或者方案声称排满了，实际分钟数不够。
  outcomeMismatch,
}

/// 一处结构违规。
final class PlanQualityViolation {
  const PlanQualityViolation({
    required this.code,
    required this.message,
    this.taskId,
    this.localDate,
  });

  final PlanQualityViolationCode code;
  final String message;
  final String? taskId;
  final DateTime? localDate;

  @override
  String toString() =>
      'PlanQualityViolation(${code.name}'
      '${taskId == null ? '' : ' task=$taskId'}'
      '${localDate == null ? '' : ' date=${localDate!.year}-${localDate!.month}-${localDate!.day}'}'
      '): $message';
}

/// 校验一份方案的**结构自洽性**（计划 Task 7 Step 3/Step 4）。
///
/// 返回空列表表示通过。调用方（`_improve`）用它当"这次替换能不能接受"的
/// 第二道闸门：第一道是方案级目标不恶化，第二道是结构仍然自洽。
abstract final class PlanQualityValidator {
  static List<PlanQualityViolation> validate({
    required ScheduleProblem problem,
    required List<PlannedBlock> blocks,
    required DayCapacityLedger ledger,
    required TimeZoneDatabase zones,
    required Map<String, int> targets,
    DayAllocationPlan? allocationPlan,
  }) {
    final violations = <PlanQualityViolation>[];

    // ── ① 块 ID 唯一 ────────────────────────────────────────────────────────
    final seenIds = <String>{};
    for (final block in blocks) {
      if (!seenIds.add(block.id)) {
        violations.add(
          PlanQualityViolation(
            code: PlanQualityViolationCode.duplicateBlockId,
            taskId: block.taskId,
            message: '块 id「${block.id}」在同一份方案里出现了两次',
          ),
        );
      }
    }

    // ── ② 任务分钟不超发 ────────────────────────────────────────────────────
    final minutesByTask = <String, int>{};
    for (final block in blocks) {
      minutesByTask[block.taskId] =
          (minutesByTask[block.taskId] ?? 0) + block.durationMinutes;
    }
    for (final entry in minutesByTask.entries) {
      final target = targets[entry.key];
      if (target == null) {
        // 未知任务的块：来源不明，属于结构异常。
        violations.add(
          PlanQualityViolation(
            code: PlanQualityViolationCode.taskMinutesExceedTarget,
            taskId: entry.key,
            message: '方案里有不属于任何输入任务的块',
          ),
        );
        continue;
      }
      if (entry.value > target) {
        violations.add(
          PlanQualityViolation(
            code: PlanQualityViolationCode.taskMinutesExceedTarget,
            taskId: entry.key,
            message: '安排了 ${entry.value} 分钟，超过目标 $target',
          ),
        );
      }
    }

    // ── ③ 日预算 ────────────────────────────────────────────────────────────
    if (allocationPlan != null) {
      for (final task in problem.tasks) {
        final budget = allocationPlan.budgetFor(task.id);
        if (budget == null) continue;
        final plannedByDate = <DateTime, int>{};
        for (final block in blocks) {
          if (block.taskId != task.id) continue;
          final date = _localDate(block.startUtc, problem.timeZoneId, zones);
          plannedByDate[date] =
              (plannedByDate[date] ?? 0) + block.durationMinutes;
        }
        for (final entry in plannedByDate.entries) {
          final allowed = budget.minutesByLocalDate[entry.key] ?? 0;
          if (entry.value > allowed) {
            violations.add(
              PlanQualityViolation(
                code: PlanQualityViolationCode.exceedsDayBudget,
                taskId: task.id,
                localDate: entry.key,
                message: '该日安排了 ${entry.value} 分钟，超过预算 $allowed',
              ),
            );
          }
        }
      }
    }

    // ── ④ 每日硬上限（逐日规则）──────────────────────────────────────────────
    final minutesByDate = <DateTime, int>{};
    for (final block in blocks) {
      final date = _localDate(block.startUtc, problem.timeZoneId, zones);
      minutesByDate[date] = (minutesByDate[date] ?? 0) + block.durationMinutes;
    }
    for (final entry in minutesByDate.entries) {
      final limit = problem
          .policyForLocalDate(entry.key)
          .resolvedRules
          .dailyMovableTaskLimitMinutes;
      if (entry.value > limit) {
        violations.add(
          PlanQualityViolation(
            code: PlanQualityViolationCode.exceedsDailyHardLimit,
            localDate: entry.key,
            message: '该日安排了 ${entry.value} 分钟，超过每日上限 $limit',
          ),
        );
      }
    }

    // ── ⑤ 缺口与"是否真的排满"一致 ──────────────────────────────────────────
    for (final task in problem.tasks) {
      final target = targets[task.id] ?? task.requiredMinutes;
      final scheduled = minutesByTask[task.id] ?? 0;
      if (scheduled > target) continue; // 已在 ② 报告
      // 账本口径的最短片段：整段余量都凑不出一个片段时，缺口是**有解释的**。
      final minimumChunk = _minimumChunkOf(task, problem);
      final totalHeadroom = ledger.localDates.fold<int>(
        0,
        (sum, date) => sum + ledger.forDate(date).remainingMinutes,
      );
      if (scheduled < target && totalHeadroom >= minimumChunk) {
        violations.add(
          PlanQualityViolation(
            code: PlanQualityViolationCode.unexplainedShortage,
            taskId: task.id,
            message:
                '还缺 ${target - scheduled} 分钟，而账本仍有 $totalHeadroom 分钟可用'
                '（最短片段 $minimumChunk）——这是"没排好"，不是"排不下"',
          ),
        );
      }
    }

    return violations;
  }

  static int _minimumChunkOf(SchedulableTask task, ScheduleProblem problem) {
    final granularity = problem.rules.granularityMinutes;
    final base = task.minChunkMinutes;
    // 向上取整到粒度：与放置阶段的口径一致（计划 §3.4 第 7 条）。
    if (granularity <= 0) return base;
    return (base + granularity - 1) ~/ granularity * granularity;
  }

  static DateTime _localDate(
    DateTime instantUtc,
    String zoneId,
    TimeZoneDatabase zones,
  ) {
    final local = zones.toLocal(instantUtc, zoneId);
    return DateTime(local.year, local.month, local.day);
  }
}

/// 便于调用方按"有没有违规"判断的扩展。
extension PlanQualityViolationsOnList on List<PlanQualityViolation> {
  bool get isClean => isEmpty;

  /// 是否含有**结构破损**类违规（这类必须无条件阻断）。
  bool get hasStructuralBreak => any(
    (violation) =>
        violation.code == PlanQualityViolationCode.duplicateBlockId ||
        violation.code == PlanQualityViolationCode.taskMinutesExceedTarget ||
        violation.code == PlanQualityViolationCode.exceedsDayBudget ||
        violation.code == PlanQualityViolationCode.exceedsDailyHardLimit,
  );
}
