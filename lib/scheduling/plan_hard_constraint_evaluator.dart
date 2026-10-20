import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 硬约束的**稳定码**（计划 Task 6 Step 2）。
///
/// 这些码是业务判断：界面据此给出原因，测试据此断言"候选资格 / 局部修复 /
/// 最终校验"对同一个放置给出**同一个结论**。软目标（精力、偏好、均衡、坏空档）
/// 不在其中——它们只进评分与解释，不得把存在硬合法位置的方案判成无解。
enum HardConstraintCode {
  outsidePlanningWindow,
  beforeAvailableFrom,
  afterDeadline,
  disallowedWeekday,
  invalidChunkDuration,
  offGrid,
  fixedConflict,
  protectedConflict,
  sleepConflict,
  planBlockConflict,
  requiredBreakUnavailable,
  taskDailyLimitReached,
  globalDailyLimitReached,
  lockedOrStartedBlockMoved,

  /// 某天缺少策略：装配不变量破坏。**不得**偷偷套用首日规则（DFR-027）。
  missingDailyPolicy,
}

final class HardConstraintViolation {
  const HardConstraintViolation({
    required this.code,
    required this.localDate,
    required this.requiredMinutes,
    required this.availableMinutes,
    this.blockId,
    this.relatedBlockId,
  });

  final HardConstraintCode code;

  /// 违规所在的本地日（只含年月日）；与日期无关时为 null。
  final DateTime? localDate;

  /// 该约束要求的分钟数（缺口/休息/片段上限等）。
  final int requiredMinutes;

  /// 该约束口径下可用的分钟数。
  final int availableMinutes;

  final String? blockId;

  /// 与本次违规直接相关的另一块（休息/重叠）。用于在整份计划校验里去重。
  final String? relatedBlockId;

  @override
  String toString() =>
      'HardConstraintViolation(${code.name}, required=$requiredMinutes, '
      'available=$availableMinutes)';
}

/// 一次校验所需的全部事实。
///
/// 显式携带 `problem` 与 `nowUtc`（而不是读全局/系统时钟）：同一份事实必须得到
/// 同一个结论，否则"候选允许但应用校验拒绝"又会以别的形式回来。
final class HardConstraintContext {
  const HardConstraintContext({required this.problem, required this.nowUtc});

  final ScheduleProblem problem;
  final DateTime nowUtc;

  DailySchedulingPolicy? policyFor(DateTime localDate) =>
      problem.dailyPolicies[normalizeLocalDate(localDate)];
}

/// 普通候选、局部修复与最终校验**共用**的硬约束事实源（计划 Task 6）。
///
/// 它只做判定、不排序、不评分：返回的列表按冻结优先级排序，首项用于用户原因。
/// 调用方（validator / 局部修复）负责把码翻译成各自的冲突类型。
final class PlanHardConstraintEvaluator {
  const PlanHardConstraintEvaluator(this.zones);

  final TimeZoneDatabase zones;

  /// 校验**单个放置**。`otherBlocks` 是同一份计划里已存在的其他块。
  List<HardConstraintViolation> validatePlacement({
    required SchedulableTask task,
    required PlannedBlock block,
    required HardConstraintContext context,
    Iterable<PlannedBlock> otherBlocks = const [],
  }) {
    final problem = context.problem;
    final violations = <HardConstraintViolation>[];
    final localDate = _localDate(context, block.startUtc);
    final policy = context.policyFor(localDate);
    final granularity = policy?.resolvedRules.granularityMinutes ?? 1;

    // ① 规划窗口（半开区间）。
    if (block.startUtc.isBefore(problem.planningWindow.startUtc) ||
        !block.endUtc.isAfter(block.startUtc)) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.outsidePlanningWindow,
          localDate: localDate,
          requiredMinutes: block.durationMinutes,
          availableMinutes: 0,
          blockId: block.id,
        ),
      );
    } else if (block.endUtc.isAfter(problem.planningWindow.endUtc)) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.outsidePlanningWindow,
          localDate: localDate,
          requiredMinutes: block.durationMinutes,
          availableMinutes: 0,
          blockId: block.id,
        ),
      );
    }

    // ② 任务最早开始。
    final availableFrom = task.availableFromUtc;
    if (availableFrom != null && block.startUtc.isBefore(availableFrom)) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.beforeAvailableFrom,
          localDate: localDate,
          requiredMinutes: 0,
          availableMinutes: 0,
          blockId: block.id,
        ),
      );
    }

    // ③ 截止时间。
    final due = task.dueAtUtc;
    if (due != null && block.endUtc.isAfter(due)) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.afterDeadline,
          localDate: localDate,
          requiredMinutes: block.durationMinutes,
          availableMinutes: 0,
          blockId: block.id,
        ),
      );
    }

    // ④ 允许星期。
    if (!task.allowsWeekday(localDate.weekday)) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.disallowedWeekday,
          localDate: localDate,
          requiredMinutes: 0,
          availableMinutes: 0,
          blockId: block.id,
        ),
      );
    }

    // ⑤ 片段时长与网格。**网格单独判**：`isValidPlannedChunk` 只检查时长能否
    // 整除粒度，从不检查起止时刻是否落在当日网格上（09:03 开始、60 分钟的块会
    // 被它判为合法），而"按目标日粒度向上吸附"正是延后路径要保证的事。
    final duration = block.durationMinutes;
    final offGrid =
        _minuteOfDay(block.startUtc, context) % granularity != 0 ||
        _minuteOfDay(block.endUtc, context) % granularity != 0;
    if (offGrid) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.offGrid,
          localDate: localDate,
          requiredMinutes: task.minChunkMinutes,
          availableMinutes: duration,
          blockId: block.id,
        ),
      );
    }
    if (!isValidPlannedChunk(
      task: task,
      block: block,
      granularityMinutes: granularity,
    )) {
      violations.add(
        HardConstraintViolation(
          code: HardConstraintCode.invalidChunkDuration,
          localDate: localDate,
          requiredMinutes: task.minChunkMinutes,
          availableMinutes: duration,
          blockId: block.id,
        ),
      );
    }

    // ⑥ 固定日程 / 保护时间 / 睡眠（睡眠已并入保护区间）。
    for (final fixed in problem.fixedIntervals) {
      if (block.range.overlaps(fixed.range)) {
        violations.add(
          HardConstraintViolation(
            code: HardConstraintCode.fixedConflict,
            localDate: localDate,
            requiredMinutes: block.durationMinutes,
            availableMinutes: 0,
            blockId: block.id,
          ),
        );
        break;
      }
    }
    for (final protected in problem.protectedIntervals) {
      if (block.range.overlaps(protected.range)) {
        violations.add(
          HardConstraintViolation(
            code: HardConstraintCode.protectedConflict,
            localDate: localDate,
            requiredMinutes: block.durationMinutes,
            availableMinutes: 0,
            blockId: block.id,
          ),
        );
        break;
      }
    }

    // ⑦ 与计划内其他块重叠（含锁定块）。
    for (final other in [...otherBlocks, ...problem.lockedBlocks]) {
      if (other.id == block.id) continue;
      if (block.range.overlaps(other.range)) {
        violations.add(
          HardConstraintViolation(
            code: HardConstraintCode.planBlockConflict,
            localDate: localDate,
            requiredMinutes: block.durationMinutes,
            availableMinutes: 0,
            blockId: block.id,
          ),
        );
        break;
      }
    }

    // ⑧ 任务之间（以及**同一任务相邻片段之间**）的休息。引擎的既有契约是
    // "任意两个任务块之间保留休息，不区分任务类型"，因此这里**不跳过同任务块**；
    // 唯一例外是模型显式允许的连续片段——本仓库没有这种标记，故不设例外。
    final neighbours = [
      for (final other in [...otherBlocks, ...problem.lockedBlocks])
        if (other.id != block.id) other,
    ];
    for (final other in neighbours) {
      final gap = other.startUtc.isBefore(block.startUtc)
          ? block.startUtc.difference(other.endUtc).inMinutes
          : other.startUtc.difference(block.endUtc).inMinutes;
      if (gap < 0) continue; // 重叠由 planBlockConflict 负责
      final otherPolicy = context.policyFor(
        _localDate(context, other.startUtc),
      );
      final required = _maxBreak(policy, otherPolicy);
      if (required > 0 && gap < required) {
        violations.add(
          HardConstraintViolation(
            code: HardConstraintCode.requiredBreakUnavailable,
            // 日期取后一块所在本地日：跨日时严格值由它那边决定，
            // 用户看到的也是“后一段安排所在的那一天”。
            localDate: _localDate(context, other.startUtc),
            requiredMinutes: required,
            availableMinutes: gap,
            blockId: block.id,
            relatedBlockId: other.id,
          ),
        );
        break;
      }
    }

    violations.sort(_priority);
    return List.unmodifiable(violations);
  }

  /// 校验**整份计划**：逐块放置 + 每日上限 + 相邻休息。
  List<HardConstraintViolation> validatePlan({
    required Iterable<PlannedBlock> blocks,
    required HardConstraintContext context,
  }) {
    final problem = context.problem;
    final tasks = {for (final task in problem.tasks) task.id: task};
    final list = blocks.toList();
    final violations = <HardConstraintViolation>[];
    for (final block in list) {
      final task = tasks[block.taskId];
      if (task == null) continue;
      violations.addAll(
        validatePlacement(
          task: task,
          block: block,
          context: context,
          otherBlocks: list,
        ),
      );
    }

    // 每日可移动上限：按块所在**本地日**查当天策略（DFR-027）。
    final minutesByDate = <DateTime, int>{};
    for (final block in list) {
      if (block.locked) continue;
      final date = _localDate(context, block.startUtc);
      minutesByDate.update(
        date,
        (value) => value + block.durationMinutes,
        ifAbsent: () => block.durationMinutes,
      );
    }
    for (final entry in minutesByDate.entries) {
      final policy = context.policyFor(entry.key);
      if (policy == null) {
        // 缺策略是装配错误：既不跳过，也不回退首日上限。
        violations.add(
          HardConstraintViolation(
            code: HardConstraintCode.missingDailyPolicy,
            localDate: entry.key,
            requiredMinutes: 0,
            availableMinutes: 0,
          ),
        );
        continue;
      }
      final limit = policy.resolvedRules.dailyMovableTaskLimitMinutes;
      if (entry.value > limit) {
        violations.add(
          HardConstraintViolation(
            code: HardConstraintCode.taskDailyLimitReached,
            localDate: entry.key,
            requiredMinutes: entry.value,
            availableMinutes: limit,
          ),
        );
      }
    }

    // 相邻休息在逐块校验里会从**两侧各报一次**：按无向对去重，保证"一对相邻块
    // 只有一条休息证据"（与 validator 旧口径一致）。
    final seenBreakPairs = <String>{};
    final deduped = <HardConstraintViolation>[];
    for (final violation in violations) {
      if (violation.code == HardConstraintCode.requiredBreakUnavailable &&
          violation.blockId != null &&
          violation.relatedBlockId != null) {
        final ids = [violation.blockId!, violation.relatedBlockId!]..sort();
        if (!seenBreakPairs.add('${ids[0]}|${ids[1]}')) continue;
      }
      deduped.add(violation);
    }

    deduped.sort(_priority);
    return List.unmodifiable(deduped);
  }

  // ── 内部 ─────────────────────────────────────────────────────────────────

  DateTime _localDate(HardConstraintContext context, DateTime instantUtc) =>
      normalizeLocalDate(zones.toLocal(instantUtc, context.problem.timeZoneId));

  int _minuteOfDay(DateTime instantUtc, HardConstraintContext context) {
    final local = zones.toLocal(instantUtc, context.problem.timeZoneId);
    return local.hour * 60 + local.minute;
  }

  int _maxBreak(DailySchedulingPolicy? a, DailySchedulingPolicy? b) {
    final first = a?.resolvedRules.breakMinutes ?? 0;
    final second = b?.resolvedRules.breakMinutes ?? 0;
    return first > second ? first : second;
  }

  /// 冻结优先级（计划 Task 6 Step 2）：结构/时间边界 → 占用 → 上限 → 休息。
  static int _priority(HardConstraintViolation a, HardConstraintViolation b) =>
      a.code.index.compareTo(b.code.index);
}
