import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/task_capacity_analyzer.dart';

/// 一段空档**为什么没有被用来排这件事**（计划 §2.3）。
///
/// **它是位置语义，不是候选语义**：`CandidateRejectionCode` 说的是"这个候选违反了哪条规则"，
/// 这里说的是"这段时间为什么整段用不上"。用户要看的是后者——他盯着日历上那段空档，
/// 想知道的就是它为什么空着。
enum GapExclusionCode {
  /// 还没到任务的最早开始时间。
  beforeAvailableFrom,

  /// 已经过了任务的截止时间。
  afterDeadline,

  /// 这一天不在任务允许的星期里。
  disallowedWeekday,

  /// 空档比一个最小可排片段还短，什么也放不下。
  shorterThanRequiredChunk,

  /// 该本地日的**任务自己的**每日上限已经用满。
  dailyTaskLimitReached,

  /// 该本地日的全局每日可移动上限已经用满。
  dailyMovableLimitReached,

  /// 均匀分布任务在该本地日的**按日预算**已经用满（计划 §2.1：不放宽，由均分器改分给别的日子）。
  dailyEvenBudgetReached,

  /// 片段之间的休息间隔凑不出来。
  requiredBreakUnavailable,

  /// 被固定日程占住。
  occupiedByFixedSchedule,

  /// 被保护时间占住。
  occupiedByProtectedTime,

  /// 被锁定计划块（或本次已放下的块）占住。
  occupiedByLockedBlock,
}

/// 一段**未被使用**的空档，附上可核对的原因与数字。
///
/// 诊断数据**只进内存提案**：不写日志、不写遥测。原因见
/// [TaskPlacementDiagnostics] 的说明。
final class ExcludedGapEvidence {
  const ExcludedGapEvidence({
    required this.range,
    required this.code,
    this.requiredMinutes,
    this.availableMinutes,
  });

  final TimeRange range;
  final GapExclusionCode code;
  final int? requiredMinutes;
  final int? availableMinutes;

  @override
  String toString() =>
      'ExcludedGapEvidence(${range.startUtc.toIso8601String()}→'
      '${range.endUtc.toIso8601String()}, ${code.name}, '
      'required=$requiredMinutes, available=$availableMinutes)';
}

/// 一件任务在**最终块集合**上的放置诊断（计划 §2.3）。
///
/// ## 它替换掉了什么
///
/// 修复前引擎把"为什么排不下"记在**放置循环里**（跨轮次累计的 `rejectionEvidence`）。
/// 那条路径有个结构性缺陷：循环里每一次拒绝都是"**试**一个候选"的副产物——
/// 判据不成立时先记一条，该候选随后仍可能被选中（`allowUnschedulableLeftover` 的第二遍
/// 就是这么做的）。于是一条在成功放置**之前**、按**当时**剩余量算出来的拒绝会活到最终结论里，
/// 甚至因为优先级位次更高而盖过真正的最终约束（R5）。
///
/// 正确的方式是**在所有块稳定之后**重新问一遍："按最终的块集合看，这件任务还有合法位置吗？"
/// 这就是本文件唯一的职责。
///
/// ## 它不得读取放置循环的中间状态
///
/// 入参只有 `problem`、`task`、`remainingMinutes`、`availability`、`finalBlocks`、`zones`，
/// 没有任何"累计证据"。判定**共用** `evaluateCandidateEligibility`（放置循环也调它），
/// 因此"引擎排得下、诊断说排不下"在结构上不可能发生。
final class TaskPlacementDiagnostics {
  const TaskPlacementDiagnostics({
    required this.remainingMinutes,
    required this.capacity,
    required this.reasons,
    required this.excludedGaps,
    required this.hasEligibleCandidate,
  });

  /// 最终缺口分钟（`target − 最终已排`）。主原因里的
  /// `placementRemainingMinutes` 必须等于它。
  final int remainingMinutes;

  final TaskCapacityEvidence capacity;

  /// 全部结构化拒绝证据，按 [unscheduledReasonPriority] 的优先级选主原因。
  final List<UnscheduledReason> reasons;

  /// 未被使用的空档，已按起点排序并合并相邻同 code 区间。相同输入输出顺序稳定。
  final List<ExcludedGapEvidence> excludedGaps;

  /// 按**最终块集合**看，是否至少存在一个可采纳的候选。
  ///
  /// 它为真而 [remainingMinutes] 大于零，就是**排程没有使用仍可用的合法时段**：
  /// 引擎必须同时给出 `unexplainedSchedulingFailure` 与
  /// `ConflictCode.schedulingInvariantViolation`（计划 §2.3 / Task 5 Step 6）。
  final bool hasEligibleCandidate;
}

/// 在 `_improve()`、稳定块最小化与最终排序**之后**诊断一件任务（计划 §2.3）。
///
/// 契约：
/// - 纯函数：不查库、不读时钟、不写日志、不碰放置循环的中间状态；
/// - 候选资格判定与引擎放置**共用** [evaluateCandidateEligibility]，不复制第二套约束；
/// - `excludedGaps` 先按起点排序，再合并**相邻且 code 相同**的区间，相同输入输出稳定；
/// - 覆盖"最早开始、截止、星期、最小片段、日上限、全局日上限、休息、固定日程、保护时间、
///   锁定块"十类排除原因（另有均匀分布的按日预算，见 [GapExclusionCode]）。
TaskPlacementDiagnostics diagnoseTaskPlacement({
  required ScheduleProblem problem,
  required SchedulableTask task,
  required int remainingMinutes,
  required AvailabilityAnalysis availability,
  required List<PlannedBlock> finalBlocks,
  required TimeZoneDatabase zones,
}) {
  final capacity = analyzeTaskCapacity(
    task: task,
    problem: problem,
    availability: availability,
    allBlocks: finalBlocks,
    zones: zones,
  );
  final granularity = problem.rules.granularityMinutes;
  final ctx = _context(
    problem: problem,
    task: task,
    remainingMinutes: remainingMinutes,
    finalBlocks: finalBlocks,
    zones: zones,
  );
  final evidence = <ExcludedGapEvidence>[];
  final collectedReasons = <UnscheduledReason>[];
  var hasEligibleCandidate = false;
  final minimum = minimumPlacementMinutes(
    task: task,
    remainingMinutes: remainingMinutes,
    granularityMinutes: granularity,
  );
  // 截止之前真正可用的总分钟：**算一次**，后面每个被截止切掉的空档共用它。
  final beforeDeadlineMinutes = _availableBeforeDeadline(
    task: task,
    availability: availability,
  );

  for (final slot in availability.slots) {
    // ① 星期：这一天根本不在任务允许的星期里。
    //
    // 判定用 `slot.localDate.weekday`，与 `CandidateGenerator.generate` 同源——
    // 把 UTC 时刻再换算一遍只会在夏令时切换日引入第二个真相。
    if (!task.allowsWeekday(slot.localDate.weekday)) {
      evidence.add(
        ExcludedGapEvidence(
          range: slot.range,
          code: GapExclusionCode.disallowedWeekday,
          requiredMinutes: minimum,
          availableMinutes: slot.durationMinutes,
        ),
      );
      continue;
    }
    // ② 最早开始时间：空档起点早于 `availableFromUtc` 时，只有
    // `availableFrom` 之后的部分能用。于是 [start, availableFrom) 被排除。
    final availableFrom = task.availableFromUtc;
    if (availableFrom != null && availableFrom.isAfter(slot.startUtc)) {
      evidence.add(
        ExcludedGapEvidence(
          range: TimeRange(
            startUtc: slot.startUtc,
            endUtc: availableFrom.isBefore(slot.endUtc)
                ? availableFrom
                : slot.endUtc,
          ),
          code: GapExclusionCode.beforeAvailableFrom,
        ),
      );
    }
    // ③ 截止时间：`dueAtUtc` 之后的可用分钟用不上（候选必须整段落在截止之前）。
    final dueAtUtc = task.dueAtUtc;
    final usableEnd = dueAtUtc != null && dueAtUtc.isBefore(slot.endUtc)
        ? dueAtUtc
        : slot.endUtc;
    if (dueAtUtc != null && dueAtUtc.isBefore(slot.endUtc)) {
      evidence.add(
        ExcludedGapEvidence(
          range: TimeRange(startUtc: dueAtUtc, endUtc: slot.endUtc),
          code: GapExclusionCode.afterDeadline,
          availableMinutes: beforeDeadlineMinutes,
        ),
      );
    }
    final usableStart =
        availableFrom != null && availableFrom.isAfter(slot.startUtc)
        ? availableFrom
        : slot.startUtc;
    if (!usableEnd.isAfter(usableStart)) continue;
    final usableMinutes = usableEnd.difference(usableStart).inMinutes;

    // 逐时长判定：**任何**一个时长可采纳，这段空档就是"还有地方可排"。
    //
    // 逐时长而不是只试最长的那个：剩余 100 分钟、片段上限 30 时，90 分钟会因为
    // "留下 10 分钟凑不出片段"被挡，而 30 分钟是合法的。只试最长会把这种情况误报成
    // "没有候选"，从而把一件本来排得下的任务说成排程异常。
    //
    // 时长一个也没有（剩余量不足一个粒度、或连续任务已经排过一段）时 `best` 保持 null，
    // 由下面那句如实报"最小片段放不下"。
    final durations = placementDurations(
      task,
      remainingMinutes: remainingMinutes,
      granularityMinutes: granularity,
    );
    final gapReasons = <UnscheduledReason>[];
    ExcludedGapEvidence? best;
    for (final duration in durations) {
      if (duration > usableMinutes) continue;
      final placement = SchedulingCandidate(
        id:
            'diagnostic:${task.id}:${usableStart.microsecondsSinceEpoch}'
            ':$duration',
        taskId: task.id,
        range: TimeRange(
          startUtc: usableStart,
          endUtc: usableStart.add(Duration(minutes: duration)),
        ),
        localDate: slot.localDate,
      );
      final rejections = evaluateCandidateEligibility(
        ctx,
        placement,
        gapEndUtc: usableEnd,
      );
      if (isCandidateAcceptable(ctx, rejections)) {
        hasEligibleCandidate = true;
        break;
      }
      for (final rejection in rejections) {
        final reason = _reasonFor(rejection, remainingMinutes);
        if (!gapReasons.any((item) => item.code == reason.code)) {
          gapReasons.add(reason);
        }
        if (!collectedReasons.any((item) => item.code == reason.code)) {
          collectedReasons.add(reason);
        }
      }
      if (best == null || duration > (best.requiredMinutes ?? 0)) {
        best = ExcludedGapEvidence(
          range: placement.range,
          code: _gapCodeFor(_dominantRejection(rejections)),
          requiredMinutes: duration,
          availableMinutes: usableMinutes,
        );
      }
    }
    if (hasEligibleCandidate) break;
    if (best == null) {
      // 逐时长判定一个候选也没试到（剩余量不足一个粒度、或连续任务已经排过一段）。
      // 这段空档确实用不上，但**说不出更具体的原因** ⇒ 如实报"最小片段放不下"。
      evidence.add(
        ExcludedGapEvidence(
          range: TimeRange(startUtc: usableStart, endUtc: usableEnd),
          code: GapExclusionCode.shorterThanRequiredChunk,
          requiredMinutes: minimum,
          availableMinutes: usableMinutes,
        ),
      );
      continue;
    }
    evidence.add(best);
  }

  // ── 判定 ────────────────────────────────────────────────────────────────────
  //
  // **存在合法候选却仍有缺口** ⇒ 排程自己没排好。主原因固定为
  // `unexplainedSchedulingFailure`，并由引擎生成 blocking conflict。
  final primary = hasEligibleCandidate && remainingMinutes > 0
      ? UnscheduledReason(
          code: UnscheduledReasonCode.unexplainedSchedulingFailure,
          placementRemainingMinutes: remainingMinutes,
          constraintRequiredMinutes: remainingMinutes,
          constraintAvailableMinutes: capacity.remainingPlaceableMinutes,
        )
      : _primaryReason(
          task: task,
          problem: problem,
          remainingMinutes: remainingMinutes,
          beforeDeadlineMinutes: beforeDeadlineMinutes,
          capacity: capacity,
          evidence: evidence,
          reasons: collectedReasons,
        );

  return TaskPlacementDiagnostics(
    remainingMinutes: remainingMinutes,
    capacity: capacity,
    reasons: [
      primary,
      ...collectedReasons.where((item) => item.code != primary.code),
    ],
    excludedGaps: mergeExcludedGaps(evidence),
    hasEligibleCandidate: hasEligibleCandidate,
  );
}

/// 把排除证据**先按起点排序，再合并相邻且 code 相同的区间**（计划 §2.3）。
///
/// 排序键除了起点还包含 code 与数字，因此**相同输入必然得到相同的输出顺序**——
/// 排程器的确定性要求同样适用于诊断数据，否则同一次失败两次显示的顺序可能不同。
List<ExcludedGapEvidence> mergeExcludedGaps(
  List<ExcludedGapEvidence> evidence,
) {
  if (evidence.isEmpty) return const [];
  final sorted = [...evidence]
    ..sort((a, b) {
      final start = a.range.startUtc.compareTo(b.range.startUtc);
      if (start != 0) return start;
      final end = a.range.endUtc.compareTo(b.range.endUtc);
      if (end != 0) return end;
      final code = a.code.index.compareTo(b.code.index);
      if (code != 0) return code;
      final required = (a.requiredMinutes ?? -1).compareTo(
        b.requiredMinutes ?? -1,
      );
      if (required != 0) return required;
      return (a.availableMinutes ?? -1).compareTo(b.availableMinutes ?? -1);
    });
  final merged = <ExcludedGapEvidence>[];
  for (final item in sorted) {
    final previous = merged.isEmpty ? null : merged.last;
    if (previous != null &&
        previous.code == item.code &&
        !item.range.startUtc.isAfter(previous.range.endUtc)) {
      merged[merged.length - 1] = ExcludedGapEvidence(
        range: TimeRange(
          startUtc: previous.range.startUtc,
          endUtc: item.range.endUtc.isAfter(previous.range.endUtc)
              ? item.range.endUtc
              : previous.range.endUtc,
        ),
        code: previous.code,
        // 合并时取**可用的那个数**（两者都有时取较小值，即更严格的约束）。
        requiredMinutes: _mergeNumber(
          previous.requiredMinutes,
          item.requiredMinutes,
        ),
        availableMinutes: _mergeNumber(
          previous.availableMinutes,
          item.availableMinutes,
        ),
      );
      continue;
    }
    merged.add(item);
  }
  return List.unmodifiable(merged);
}

int? _mergeNumber(int? first, int? second) {
  if (first == null) return second;
  if (second == null) return first;
  return first < second ? first : second;
}

CandidateEligibilityContext _context({
  required ScheduleProblem problem,
  required SchedulableTask task,
  required int remainingMinutes,
  required List<PlannedBlock> finalBlocks,
  required TimeZoneDatabase zones,
}) => CandidateEligibilityContext(
  problem: problem,
  task: task,
  remainingMinutes: remainingMinutes,
  blocks: finalBlocks,
  movableMinutesByDate: movableMinutesByLocalDate(
    problem: problem,
    zones: zones,
    blocks: finalBlocks,
  ),
  plannedMinutesForTaskByDate: taskMinutesByLocalDate(
    problem: problem,
    task: task,
    zones: zones,
    blocks: finalBlocks,
  ),
  // 诊断器问的是"最终的块集合上还能不能排"：按日预算与"最终余量"两件事
  // 都**不放宽**——放宽是放置循环为了不白丢容量而做的取舍，不是最终事实。
  allowUnschedulableLeftover: false,
);

UnscheduledReason _reasonFor(
  CandidateEligibilityRejection rejection,
  int remainingMinutes,
) {
  final label = switch (rejection.code) {
    CandidateRejectionCode.durationExceedsRemaining => '这一片段比本次剩余时间还长',
    CandidateRejectionCode.exceedsGapCapacity => '最终余量不足一个片段',
    CandidateRejectionCode.overlapsExistingBlock =>
      switch (rejection.blockingKind) {
        BlockingKind.fixedSchedule => '固定日程',
        BlockingKind.protectedTime => '保护时间',
        BlockingKind.lockedBlock => '已有计划块或固定日程',
        null => '已有计划块或固定日程',
      },
    CandidateRejectionCode.exceedsEvenDailyBudget => '本日均匀份额',
    CandidateRejectionCode.exceedsDailyTaskLimit => '每日上限',
    CandidateRejectionCode.exceedsDailyMovableLimit => '每日可移动上限',
    CandidateRejectionCode.violatesRequiredBreak => '片段间休息',
    CandidateRejectionCode.leavesUnschedulableLeftover => '最终余量不足一个片段',
  };
  return UnscheduledReason(
    code: _reasonCodeFor(rejection),
    placementRemainingMinutes: remainingMinutes,
    constraintRequiredMinutes: rejection.candidate.durationMinutes,
    constraintAvailableMinutes: _availableFor(rejection),
    constraintLabel: label,
  );
}

int? _availableFor(CandidateEligibilityRejection rejection) =>
    switch (rejection.code) {
      // 重叠与休息没有"还有多少分钟"这个量：它们说的是"这上面有东西"。
      CandidateRejectionCode.overlapsExistingBlock => null,
      CandidateRejectionCode.violatesRequiredBreak => null,
      _ => rejection.candidate.durationMinutes,
    };

UnscheduledReasonCode _reasonCodeFor(
  CandidateEligibilityRejection rejection,
) => switch (rejection.code) {
  CandidateRejectionCode.durationExceedsRemaining =>
    UnscheduledReasonCode.minimumChunkTooLarge,
  CandidateRejectionCode.exceedsGapCapacity =>
    UnscheduledReasonCode.minimumChunkTooLarge,
  CandidateRejectionCode.overlapsExistingBlock =>
    switch (rejection.blockingKind) {
      BlockingKind.fixedSchedule => UnscheduledReasonCode.fixedScheduleOccupied,
      BlockingKind.protectedTime => UnscheduledReasonCode.protectedTimeOccupied,
      _ => UnscheduledReasonCode.lockedPlanOccupied,
    },
  CandidateRejectionCode.exceedsEvenDailyBudget =>
    UnscheduledReasonCode.dailyLimitReached,
  CandidateRejectionCode.exceedsDailyTaskLimit =>
    UnscheduledReasonCode.dailyLimitReached,
  CandidateRejectionCode.exceedsDailyMovableLimit =>
    UnscheduledReasonCode.dailyLimitReached,
  CandidateRejectionCode.violatesRequiredBreak =>
    UnscheduledReasonCode.requiredBreakUnavailable,
  CandidateRejectionCode.leavesUnschedulableLeftover =>
    UnscheduledReasonCode.minimumChunkTooLarge,
};

GapExclusionCode _gapCodeFor(CandidateEligibilityRejection rejection) =>
    switch (rejection.code) {
      CandidateRejectionCode.durationExceedsRemaining =>
        GapExclusionCode.shorterThanRequiredChunk,
      CandidateRejectionCode.exceedsGapCapacity =>
        GapExclusionCode.shorterThanRequiredChunk,
      CandidateRejectionCode.overlapsExistingBlock => switch (rejection
          .blockingKind) {
        BlockingKind.fixedSchedule => GapExclusionCode.occupiedByFixedSchedule,
        BlockingKind.protectedTime => GapExclusionCode.occupiedByProtectedTime,
        _ => GapExclusionCode.occupiedByLockedBlock,
      },
      CandidateRejectionCode.exceedsEvenDailyBudget =>
        GapExclusionCode.dailyEvenBudgetReached,
      CandidateRejectionCode.exceedsDailyTaskLimit =>
        GapExclusionCode.dailyTaskLimitReached,
      CandidateRejectionCode.exceedsDailyMovableLimit =>
        GapExclusionCode.dailyMovableLimitReached,
      CandidateRejectionCode.violatesRequiredBreak =>
        GapExclusionCode.requiredBreakUnavailable,
      CandidateRejectionCode.leavesUnschedulableLeftover =>
        GapExclusionCode.shorterThanRequiredChunk,
    };

/// 一条候选拒绝对应"这段空档为什么用不上"（计划 §2.3 的 code 映射）。
///
/// **公开而不是私有**：测试要用同一个映射逐条钉住十种 code，而在测试里重新实现一遍映射
/// 就等于放进第二个事实源。
GapExclusionCode gapCodeForRejection(CandidateEligibilityRejection rejection) =>
    _gapCodeFor(rejection);

/// 一段空档里有**多条**拒绝时，用哪一条代表这段空档。
///
/// 顺序刻意把"这段空档装不下任何合法片段"排在前面：它是对整段空档的结论
/// （"不是被谁占住了，而是它本身太短"），而重叠／休息说的是"这一块压到了别的东西上"。
/// 只看 `rejections.first` 会让结论随判定顺序漂移。
CandidateEligibilityRejection _dominantRejection(
  List<CandidateEligibilityRejection> rejections,
) {
  for (final code in const [
    CandidateRejectionCode.exceedsGapCapacity,
    CandidateRejectionCode.durationExceedsRemaining,
    CandidateRejectionCode.exceedsEvenDailyBudget,
    CandidateRejectionCode.exceedsDailyTaskLimit,
    CandidateRejectionCode.exceedsDailyMovableLimit,
    CandidateRejectionCode.overlapsExistingBlock,
    CandidateRejectionCode.violatesRequiredBreak,
    CandidateRejectionCode.leavesUnschedulableLeftover,
  ]) {
    for (final rejection in rejections) {
      if (rejection.code == code) return rejection;
    }
  }
  return rejections.first;
}

/// 在所有空档都无法采纳时，按**最终事实**给出主原因。
///
/// 顺序刻意与引擎既有语义一致：先"还没到开始时间"，再"截止装不下"，
/// 再"连续任务找不到足够长的空档"，最后才是容量与逐条证据的优先级表。
UnscheduledReason _primaryReason({
  required SchedulableTask task,
  required ScheduleProblem problem,
  required int remainingMinutes,
  required TaskCapacityEvidence capacity,
  required int beforeDeadlineMinutes,
  required List<ExcludedGapEvidence> evidence,
  required List<UnscheduledReason> reasons,
}) {
  UnscheduledReason build(
    UnscheduledReasonCode code, {
    int? requiredMinutes,
    int? availableMinutes,
    String? label,
  }) => UnscheduledReason(
    code: code,
    placementRemainingMinutes: remainingMinutes,
    constraintRequiredMinutes: requiredMinutes,
    constraintAvailableMinutes: availableMinutes,
    constraintLabel: label,
  );

  final availableFrom = task.availableFromUtc;
  if (availableFrom != null &&
      !availableFrom.isBefore(problem.planningWindow.endUtc)) {
    return build(
      UnscheduledReasonCode.availableTimeNotReached,
      label: '最早开始时间',
    );
  }
  if (evidence.any(
    (item) => item.code == GapExclusionCode.beforeAvailableFrom,
  )) {
    return build(
      UnscheduledReasonCode.availableTimeNotReached,
      label: '最早开始时间',
    );
  }
  if (evidence.any((item) => item.code == GapExclusionCode.afterDeadline)) {
    return build(
      UnscheduledReasonCode.deadlineWindowTooShort,
      requiredMinutes: task.minChunkMinutes,
      availableMinutes: beforeDeadlineMinutes,
      label: '截止时间',
    );
  }
  if (task.splitMode == TaskSplitMode.continuous &&
      capacity.largestTaskWindowGapMinutes > 0 &&
      capacity.largestTaskWindowGapMinutes < remainingMinutes) {
    return build(
      UnscheduledReasonCode.continuousGapTooShort,
      requiredMinutes: remainingMinutes,
      availableMinutes: capacity.largestTaskWindowGapMinutes,
      label: '连续时长',
    );
  }
  // **具体证据优先于笼统的容量**（与 `unscheduledReasonPriority` 同一条纪律）：
  // 每日上限、被固定日程／保护时间／锁定块挡住、休息间隔不足这些原因都**指向一个可操作
  // 的约束**（调上限、改保护时间、解锁），而"容量不足"只是"没地方了"。
  //
  // 实测（1.8.0 专项回归夹具）：120 分钟的任务、`maxMinutesPerLocalDay = 30`、
  // 窗口只剩 8 小时 ⇒ 最终排入 30 分钟、缺口 90，而"截止窗口内的可放置分钟"只有 60。
  // 若让容量分支先跑，用户会被告知"可用时段不足"并去腾时间——而真正该做的是调上限或换一天。
  if (reasons.isNotEmpty) {
    return _withPlacementRemaining(
      primaryUnscheduledReason(reasons),
      remainingMinutes,
    );
  }
  // 空证据时**才**回落到"容量确实不够"的有证据判断：
  // `remainingPlaceableMinutes < remainingMinutes` 说明"就是没地方"，这是可解释的容量不足。
  if (capacity.remainingPlaceableMinutes < remainingMinutes) {
    return build(
      UnscheduledReasonCode.insufficientCapacity,
      requiredMinutes: minimumPlacementMinutes(
        task: task,
        remainingMinutes: remainingMinutes,
        granularityMinutes: problem.rules.granularityMinutes,
      ),
      availableMinutes: capacity.largestRemainingGapMinutes,
      label: '可用时段不足',
    );
  }
  return build(
    UnscheduledReasonCode.unexplainedSchedulingFailure,
    requiredMinutes: remainingMinutes,
    availableMinutes: capacity.remainingPlaceableMinutes,
  );
}

UnscheduledReason _withPlacementRemaining(
  UnscheduledReason reason,
  int remainingMinutes,
) => UnscheduledReason(
  code: reason.code,
  placementRemainingMinutes: remainingMinutes,
  constraintRequiredMinutes: reason.constraintRequiredMinutes,
  constraintAvailableMinutes: reason.constraintAvailableMinutes,
  constraintLabel: reason.constraintLabel,
);

/// 截止时间之前**真正有多少分钟可用**（各空档与截止求交后求和）。
///
/// `0` 表示截止之前一分钟都用不上——那正是 `deadlineWindowTooShort` 的字面含义。
int _availableBeforeDeadline({
  required SchedulableTask task,
  required AvailabilityAnalysis availability,
}) {
  final dueAtUtc = task.dueAtUtc;
  if (dueAtUtc == null) return 0;
  var total = 0;
  final availableFrom = task.availableFromUtc;
  for (final slot in availability.slots) {
    if (!task.allowsWeekday(slot.localDate.weekday)) continue;
    var start = slot.startUtc;
    if (availableFrom != null && availableFrom.isAfter(start)) {
      start = availableFrom;
    }
    final end = dueAtUtc.isBefore(slot.endUtc) ? dueAtUtc : slot.endUtc;
    if (!end.isAfter(start)) continue;
    total += end.difference(start).inMinutes;
  }
  return total;
}
