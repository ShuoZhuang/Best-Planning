// 计划 `2026-10-13-calendar-preview-and-scheduling-integrity-repair.md` Task 5 Step 4：
// **gap exclusion 矩阵**。
//
// ## 这个文件钉的是什么
//
// `diagnoseTaskPlacement` 是"为什么排不下"的**唯一**事实源：它在所有块稳定之后重新问一遍
// "按最终块集合看，这件任务还有合法位置吗？"。它替换掉了**跨轮次累计**的
// `rejectionEvidence`——那条路径会把"试过一个候选、当时被拒"当最终结论，于是原因随遍历
// 顺序漂移，甚至盖过真正的最终约束（R5）。
//
// 因此这里逐条钉住十种"空档为什么用不上"：
//
// | # | 输入 | code |
// | --- | --- | --- |
// | 1 | 最早开始时间 | `beforeAvailableFrom` |
// | 2 | 截止时间 | `afterDeadline` |
// | 3 | 星期 | `disallowedWeekday` |
// | 4 | 最小连续片段 | `shorterThanRequiredChunk` |
// | 5 | 任务每日上限 | `dailyTaskLimitReached` |
// | 6 | 全局每日可移动上限 | `dailyMovableLimitReached` |
// | 7 | 片段间休息 | `requiredBreakUnavailable` |
// | 8 | 固定日程 | `occupiedByFixedSchedule` |
// | 9 | 保护时间 | `occupiedByProtectedTime` |
// | 10 | 锁定块 | `occupiedByLockedBlock` |
//
// 每个用例都断言 **code、UTC range 与数字**三件事。只断言 code 不够：`range` 是用户
// 在"查看未使用空档"里看到的那一行，错一分钟就会让他去找一段根本不存在的时间。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'UTC';
  final day = DateTime.utc(2026, 10, 5);

  DateTime at(int hour, [int minute = 0]) =>
      DateTime.utc(2026, 10, 5, hour, minute);

  PlanningRules rules({
    int dailyMovableTaskLimitMinutes = 600,
    int granularityMinutes = 5,
  }) => PlanningRules(
    energyWindows: const [],
    sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
    minimumSleepMinutes: 420,
    defaultFocusMinutes: 50,
    breakMinutes: 10,
    dailyMovableTaskLimitMinutes: dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes: 0,
    granularityMinutes: granularityMinutes,
  );

  ScheduleProblem problem({
    required SchedulableTask task,
    required TimeRange window,
    List<BusyInterval> fixed = const [],
    List<BusyInterval> protected = const [],
    List<PlannedBlock> locked = const [],
    int dailyMovableTaskLimitMinutes = 600,
    int granularityMinutes = 5,
  }) {
    final planningRules = rules(
      dailyMovableTaskLimitMinutes: dailyMovableTaskLimitMinutes,
      granularityMinutes: granularityMinutes,
    );
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [task],
      fixedIntervals: fixed,
      protectedIntervals: protected,
      lockedBlocks: locked,
      rules: planningRules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: planningRules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: planningRules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'gap-matrix',
    );
  }

  SchedulableTask task({
    String id = 't1',
    int requiredMinutes = 60,
    int minChunk = 30,
    int maxChunk = 60,
    TaskSplitMode splitMode = TaskSplitMode.splittable,
    DateTime? dueAtUtc,
    DateTime? availableFromUtc,
    int? maxMinutesPerLocalDay,
    int allowedWeekdaysMask = allWeekdaysMask,
  }) => SchedulableTask(
    id: id,
    requiredMinutes: requiredMinutes,
    splitMode: splitMode,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    dueAtUtc: dueAtUtc,
    availableFromUtc: availableFromUtc,
    maxMinutesPerLocalDay: maxMinutesPerLocalDay,
    allowedWeekdaysMask: allowedWeekdaysMask,
  );

  /// 一次完整的诊断：容量证据、排除空档与判定都从**同一份空闲分析**算出
  /// （诊断器不自己重建 `AvailabilityAnalysis`——那会让它与引擎看到两批空闲）。
  TaskPlacementDiagnostics diagnose({
    required ScheduleProblem forProblem,
    required SchedulableTask forTask,
    required int remainingMinutes,
    List<PlannedBlock> finalBlocks = const [],
  }) {
    final window = forProblem.planningWindow;
    final problemTimeZoneId = forProblem.timeZoneId;
    final planningRules = forProblem.rules;
    final availability = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: problemTimeZoneId,
        rules: planningRules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: zones,
          window: window,
          rules: planningRules,
          timeZoneId: problemTimeZoneId,
        ),
        fixedIntervals: forProblem.fixedIntervals
            .map((item) => item.range)
            .toList(),
        protectedIntervals: forProblem.protectedIntervals
            .map((item) => item.range)
            .toList(),
        lockedBlocks: forProblem.lockedBlocks
            .map((item) => item.range)
            .toList(),
      ),
    );
    return diagnoseTaskPlacement(
      problem: forProblem,
      task: forTask,
      remainingMinutes: remainingMinutes,
      availability: availability,
      // **账本与引擎同源**（算法 17，计划 Task 3）：诊断与放置读同一份逐日容量，
      // 否则"引擎排得下、诊断说排不下"迟早发生。
      ledger: buildDayCapacityLedger(
        problem: forProblem,
        availability: availability,
        baselineBlocks: finalBlocks,
        zones: zones,
      ),
      finalBlocks: finalBlocks,
      zones: zones,
    );
  }

  /// 直接调**放置循环也会调用的那个**判定函数（计划 §2.3 Task 5 Step 1）。
  ///
  /// 三类"被占住"的 code 只能这样验（见 ⑧ 的说明）：固定日程与保护时间会被
  /// `AvailabilityBuilder` 从空闲里扣掉，诊断器枚举的空档里永远没有"起点被它们压住"
  /// 的候选。用同一个函数 + 同一个映射，钉住的仍然是产品代码里那条真实路径。
  List<CandidateEligibilityRejection> evaluatePlacement({
    required ScheduleProblem problem,
    required SchedulableTask task,
    required SchedulingCandidate candidate,
    required List<PlannedBlock> blocks,
  }) => evaluateCandidateEligibility(
    CandidateEligibilityContext(
      problem: problem,
      task: task,
      remainingMinutes: candidate.durationMinutes,
      blocks: blocks,
      policies: PolicyLookupCache.forProblem(problem),
      movableMinutesByDate: movableMinutesByLocalDate(
        problem: problem,
        zones: zones,
        blocks: blocks,
      ),
      plannedMinutesForTaskByDate: taskMinutesByLocalDate(
        problem: problem,
        task: task,
        zones: zones,
        blocks: blocks,
      ),
      allowUnschedulableLeftover: false,
    ),
    candidate,
  );

  ExcludedGapEvidence onlyGapWith(
    TaskPlacementDiagnostics diagnostics,
    GapExclusionCode code,
  ) {
    final matches = diagnostics.excludedGaps
        .where((item) => item.code == code)
        .toList();
    expect(
      matches,
      hasLength(1),
      reason:
          '这条用例的前提是恰好一段 "$code"；实测 '
          '${diagnostics.excludedGaps.map((item) => '${item.code.name}'
              '(${item.range.startUtc.toIso8601String()}→'
              '${item.range.endUtc.toIso8601String()})').toList()}',
    );
    return matches.single;
  }

  // 一整天的窗口（本地日 = UTC 日），睡眠在 23:00–07:00 之外
  final fullDay = TimeRange(
    startUtc: day,
    endUtc: day.add(const Duration(days: 1)),
  );

  group('gap exclusion 矩阵：十种输入各自的 code、range 与数字', () {
    test('① 最早开始时间 ⇒ beforeAvailableFrom 覆盖 [空档起点, 最早开始)', () {
      // 空档 07:00–09:00，任务最早 07:30 才能开始 ⇒ 前 30 分钟用不上。
      final t = task(availableFromUtc: at(7, 30));
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(9)),
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      final gap = onlyGapWith(
        diagnostics,
        GapExclusionCode.beforeAvailableFrom,
      );
      expect(gap.range.startUtc, at(7));
      expect(gap.range.endUtc, at(7, 30));
      // 07:30–09:00 有 90 分钟，够放一个 60 分钟的片段 ⇒ 任务其实排得下。
      expect(diagnostics.hasEligibleCandidate, isTrue);
      expect(diagnostics.remainingMinutes, 60, reason: '诊断的剩余量就是调用方给出的最终缺口');
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.unexplainedSchedulingFailure,
        reason: '有合法候选却仍有缺口 ⇒ 主原因固定为"无法解释"，并生成 blocking conflict',
      );
    });

    test('② 截止时间 ⇒ afterDeadline 覆盖 [截止, 空档终点)，并报截止前的可用分钟', () {
      final t = task(
        requiredMinutes: 30,
        minChunk: 30,
        maxChunk: 30,
        dueAtUtc: at(7, 20),
      );
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(8)),
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 30,
      );

      final gap = onlyGapWith(diagnostics, GapExclusionCode.afterDeadline);
      expect(gap.range.startUtc, at(7, 20));
      expect(gap.range.endUtc, at(8));
      // 截止之前只有 20 分钟可用，装不下 30 分钟的片段。
      expect(gap.availableMinutes, 20);
      expect(diagnostics.hasEligibleCandidate, isFalse);
      final reason = diagnostics.reasons.first;
      expect(reason.code, UnscheduledReasonCode.deadlineWindowTooShort);
      expect(reason.placementRemainingMinutes, 30);
      expect(reason.constraintRequiredMinutes, 30);
      expect(reason.constraintAvailableMinutes, 20);
    });

    test('③ 星期 ⇒ disallowedWeekday 覆盖整个空档，数字给出最小片段与空档长度', () {
      // 2026-10-05 是周一。只允许周二至周日时，这一天的空档整段用不上。
      final t = task(
        allowedWeekdaysMask: allWeekdaysMask & ~(1 << (DateTime.monday - 1)),
      );
      final prob = problem(task: t, window: fullDay);

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      final gap = onlyGapWith(diagnostics, GapExclusionCode.disallowedWeekday);
      expect(gap.range.startUtc, at(7));
      expect(gap.range.endUtc, at(23));
      expect(gap.requiredMinutes, 30);
      expect(gap.availableMinutes, 16 * 60);
      expect(diagnostics.hasEligibleCandidate, isFalse);
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.insufficientCapacity,
        reason: '排除原因是"这一天不许排"，而容量口径上确实一分钟也用不上',
      );
    });

    test('④ 最小连续片段 ⇒ shorterThanRequiredChunk 给出 20 分钟空档', () {
      // 默认睡眠 23:00–07:00，窗口 00:00–08:00 ⇒ 唯一空档是 07:00–08:00（60 分钟），
      // 被固定日程切到只剩 07:00–07:20。
      final t = task();
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: day, endUtc: at(8)),
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: at(7, 20), endUtc: at(8)),
          ),
        ],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      final gap = onlyGapWith(
        diagnostics,
        GapExclusionCode.shorterThanRequiredChunk,
      );
      expect(gap.range.startUtc, at(7));
      expect(gap.range.endUtc, at(7, 20));
      expect(gap.requiredMinutes, 30, reason: '最小可排片段 = 30 分钟');
      expect(gap.availableMinutes, 20);
      expect(diagnostics.hasEligibleCandidate, isFalse);
      // "可放置分钟"因此是 0 ⇒ 容量证据如实报"没地方"，而不是把它说成"排程器没排好"。
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.insufficientCapacity,
      );
    });

    test('⑤ 任务每日上限 ⇒ dailyTaskLimitReached 并报本日上限余量', () {
      // 片段固定 60 分钟（剩余量也是 60 ⇒ 不会命中"最终余量凑不出片段"），
      // 而任务自己声明每天最多 10 分钟 ⇒ 唯一的候选必然被每日上限拦下。
      final t = task(minChunk: 60, maxChunk: 60, maxMinutesPerLocalDay: 10);
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: day, endUtc: at(9)),
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: day, endUtc: at(8)),
          ),
        ],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      final gap = onlyGapWith(
        diagnostics,
        GapExclusionCode.dailyTaskLimitReached,
      );
      expect(gap.range.startUtc, at(8));
      expect(gap.range.endUtc, at(9));
      expect(gap.requiredMinutes, 60, reason: '这条约束要求的是"这个片段要多长"（候选时长）');
      expect(gap.availableMinutes, 60, reason: '同一口径下的可用量是这段空档的长度');
      expect(diagnostics.hasEligibleCandidate, isFalse);
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.dailyLimitReached,
      );
    });

    test('⑥ 全局每日可移动上限 ⇒ dailyMovableLimitReached', () {
      // 一天的可移动上限压到 10 分钟，而最小片段是 20 分钟 ⇒ 一个片段也放不下。
      final t = task(requiredMinutes: 20, minChunk: 20, maxChunk: 20);
      final prob = problem(
        task: t,
        window: fullDay,
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: day, endUtc: at(7)),
          ),
        ],
        dailyMovableTaskLimitMinutes: 10,
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 20,
      );

      final gap = onlyGapWith(
        diagnostics,
        GapExclusionCode.dailyMovableLimitReached,
      );
      expect(gap.range.startUtc, at(7));
      expect(gap.range.endUtc, at(7, 20));
      expect(gap.requiredMinutes, 20);
      expect(diagnostics.hasEligibleCandidate, isFalse);
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.dailyLimitReached,
      );
    });

    test('⑦ 片段间休息 ⇒ requiredBreakUnavailable（锁定块紧贴空档终点）', () {
      // 空档 07:00–07:30，锁定块 07:30–11:00：30 分钟的候选结束处距锁定块 0 分钟 < 休息 10 分钟。
      final t = task();
      final locked = PlannedBlock(
        id: 'locked',
        taskId: 'other',
        range: TimeRange(startUtc: at(7, 30), endUtc: at(11)),
        locked: true,
      );
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(11)),
        locked: [locked],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
        finalBlocks: [locked],
      );

      final gap = onlyGapWith(
        diagnostics,
        GapExclusionCode.requiredBreakUnavailable,
      );
      expect(gap.range.startUtc, at(7));
      expect(gap.range.endUtc, at(7, 30));
      expect(diagnostics.hasEligibleCandidate, isFalse);
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.requiredBreakUnavailable,
      );
    });

    test('⑧ 固定日程 ⇒ occupiedByFixedSchedule', () {
      // **为什么用"共同的判定函数 + code 映射"而不是一段可放置的空档**：
      // 固定日程被 `AvailabilityBuilder` 从空闲里扣掉，空档起点永远落在它**之后**；
      // 而"候选压到固定日程上"与"片段之间要留 10 分钟休息"天生冲突
      // （重叠意味着间隔为 0，休息判据先拒）。因此这一条由**放置循环也会调用的**
      // `evaluateCandidateEligibility` 直接钉：上下文里放一个落在固定日程内的块，
      // 问"这个候选压到谁"，再把拒绝映射成空档 code。
      final t = task(minChunk: 60, maxChunk: 60);
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(11)),
        fixed: [
          BusyInterval(
            id: 'class',
            range: TimeRange(startUtc: at(7, 15), endUtc: at(9)),
          ),
        ],
      );
      final candidate = SchedulingCandidate(
        id: 'c',
        taskId: t.id,
        range: TimeRange(startUtc: at(7), endUtc: at(8)),
        localDate: DateTime.utc(2026, 10, 5),
      );

      final rejections = evaluatePlacement(
        problem: prob,
        task: t,
        candidate: candidate,
        blocks: [
          PlannedBlock(
            id: 'other-task',
            taskId: 'other',
            range: TimeRange(startUtc: at(7), endUtc: at(8)),
          ),
        ],
      );

      final overlap = rejections.firstWhere(
        (item) => item.code == CandidateRejectionCode.overlapsExistingBlock,
      );
      expect(overlap.blockingKind, BlockingKind.fixedSchedule);
      expect(
        gapCodeForRejection(overlap),
        GapExclusionCode.occupiedByFixedSchedule,
      );
    });

    test('⑨ 保护时间 ⇒ occupiedByProtectedTime', () {
      final t = task(minChunk: 60, maxChunk: 60);
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(11)),
        protected: [
          BusyInterval(
            id: 'lunch',
            range: TimeRange(startUtc: at(7, 15), endUtc: at(9)),
          ),
        ],
      );
      final candidate = SchedulingCandidate(
        id: 'c',
        taskId: t.id,
        range: TimeRange(startUtc: at(7), endUtc: at(8)),
        localDate: DateTime.utc(2026, 10, 5),
      );

      final rejections = evaluatePlacement(
        problem: prob,
        task: t,
        candidate: candidate,
        blocks: [
          PlannedBlock(
            id: 'other-task',
            taskId: 'other',
            range: TimeRange(startUtc: at(7), endUtc: at(8)),
          ),
        ],
      );

      final overlap = rejections.firstWhere(
        (item) => item.code == CandidateRejectionCode.overlapsExistingBlock,
      );
      expect(overlap.blockingKind, BlockingKind.protectedTime);
      expect(
        gapCodeForRejection(overlap),
        GapExclusionCode.occupiedByProtectedTime,
      );
    });

    test('⑩ 锁定块 ⇒ occupiedByLockedBlock', () {
      // 锁定块落在空档里时，它既不是固定日程也不是保护时间 ⇒ 只能报"锁定计划块"。
      final t = task(minChunk: 60, maxChunk: 60);
      final locked = PlannedBlock(
        id: 'pinned',
        taskId: 'other',
        range: TimeRange(startUtc: at(7), endUtc: at(8)),
        locked: true,
      );
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(11)),
        locked: [locked],
      );
      final candidate = SchedulingCandidate(
        id: 'c',
        taskId: t.id,
        range: TimeRange(startUtc: at(7), endUtc: at(8)),
        localDate: DateTime.utc(2026, 10, 5),
      );

      final rejections = evaluatePlacement(
        problem: prob,
        task: t,
        candidate: candidate,
        blocks: [locked],
      );

      final overlap = rejections.firstWhere(
        (item) => item.code == CandidateRejectionCode.overlapsExistingBlock,
      );
      expect(overlap.blockingKind, BlockingKind.lockedBlock);
      expect(
        gapCodeForRejection(overlap),
        GapExclusionCode.occupiedByLockedBlock,
      );
    });
  });

  group('判定与不变量', () {
    test('有合法候选且剩余大于零 ⇒ 主原因是 unexplainedSchedulingFailure', () {
      // 空档 3 小时，任务只要 60 分钟 ⇒ 一定有合法候选。
      final t = task();
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: day, endUtc: at(9)),
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      expect(diagnostics.hasEligibleCandidate, isTrue);
      expect(diagnostics.remainingMinutes, greaterThan(0));
      final reason = diagnostics.reasons.first;
      expect(
        reason.code,
        UnscheduledReasonCode.unexplainedSchedulingFailure,
        reason: '它就是"排程没有使用仍可用的合法时段"（计划 §2.3 / §2.4）',
      );
      expect(reason.placementRemainingMinutes, diagnostics.remainingMinutes);
    });

    test('没有合法候选时不得报"无法解释"（那会把可解释的缺口说成排程故障）', () {
      final t = task();
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: day, endUtc: at(8)),
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: at(7, 20), endUtc: at(8)),
          ),
        ],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      expect(diagnostics.hasEligibleCandidate, isFalse);
      expect(
        diagnostics.reasons.first.code,
        isNot(UnscheduledReasonCode.unexplainedSchedulingFailure),
      );
    });

    test('每条原因的放置剩余量都等于 `remainingMinutes`（计划 §2.4 不变量）', () {
      final t = task();
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: day, endUtc: at(8)),
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: at(7, 20), endUtc: at(8)),
          ),
        ],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      expect(diagnostics.reasons, isNotEmpty);
      for (final reason in diagnostics.reasons) {
        expect(reason.placementRemainingMinutes, 60);
      }
    });
  });

  group('excludedGaps：排序、相邻同 code 合并与稳定性', () {
    test('按起点升序，且**相邻且 code 相同**的区间被合并', () {
      // 窗口 07:00–09:00、固定日程 07:40–08:00 把它切成两段（07:00–07:40、08:00–09:00），
      // 而任务只允许周二至周日 ⇒ 周一两段空档都被星期排除，且**彼此不相邻**（中间隔着固定日程）。
      // 合并的判据是"相邻"，因此这里得到两段；下一条用例才钉合并。
      final t = task(
        allowedWeekdaysMask: allWeekdaysMask & ~(1 << (DateTime.monday - 1)),
      );
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(9)),
        fixed: [
          BusyInterval(
            id: 'break',
            range: TimeRange(startUtc: at(7, 40), endUtc: at(8)),
          ),
        ],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      final starts = diagnostics.excludedGaps
          .map((item) => item.range.startUtc)
          .toList();
      final sorted = [...starts]..sort();
      expect(starts, sorted, reason: '排除空档必须按起点升序');
      for (var index = 1; index < diagnostics.excludedGaps.length; index++) {
        final previous = diagnostics.excludedGaps[index - 1];
        final current = diagnostics.excludedGaps[index];
        expect(
          previous.code == current.code &&
              !current.range.startUtc.isAfter(previous.range.endUtc),
          isFalse,
          reason: '相邻且 code 相同的区间必须已合并（${previous.code.name}）',
        );
      }
      final weekdayGaps = diagnostics.excludedGaps
          .where((item) => item.code == GapExclusionCode.disallowedWeekday)
          .toList();
      expect(weekdayGaps, hasLength(2), reason: '两段空档被固定日程隔开 ⇒ 不相邻 ⇒ 不合并');
      expect(weekdayGaps.first.range.startUtc, at(7));
      expect(weekdayGaps.first.range.endUtc, at(7, 40));
      expect(weekdayGaps.last.range.startUtc, at(8));
      expect(weekdayGaps.last.range.endUtc, at(9));
    });

    test('同一个 code 的**相邻**区间合并成一段（直接钉合并规则本身）', () {
      // 合并判据有两条：**相邻**（`next.start <= previous.end`）且 **code 相同**。
      // 这里直接对 `mergeExcludedGaps` 构造两组输入：
      // · 相邻同 code ⇒ 合成一段；
      // · 相邻但 code 不同 ⇒ 保持两段（不同处置不能并成一句）。
      final merged = mergeExcludedGaps([
        ExcludedGapEvidence(
          range: TimeRange(startUtc: at(7, 30), endUtc: at(8)),
          code: GapExclusionCode.occupiedByLockedBlock,
          requiredMinutes: 30,
          availableMinutes: 30,
        ),
        ExcludedGapEvidence(
          range: TimeRange(startUtc: at(7), endUtc: at(7, 30)),
          code: GapExclusionCode.occupiedByLockedBlock,
          requiredMinutes: 30,
          availableMinutes: 30,
        ),
      ]);

      expect(merged, hasLength(1), reason: '相邻且 code 相同 ⇒ 一段');
      expect(merged.single.range.startUtc, at(7));
      expect(merged.single.range.endUtc, at(8));

      final notMerged = mergeExcludedGaps([
        ExcludedGapEvidence(
          range: TimeRange(startUtc: at(7), endUtc: at(7, 30)),
          code: GapExclusionCode.beforeAvailableFrom,
        ),
        ExcludedGapEvidence(
          range: TimeRange(startUtc: at(7, 30), endUtc: at(8)),
          code: GapExclusionCode.occupiedByLockedBlock,
        ),
      ]);

      expect(notMerged, hasLength(2), reason: 'code 不同 ⇒ 不合并');
      expect(notMerged.first.range.startUtc, at(7));
      expect(notMerged.last.range.startUtc, at(7, 30));
    });

    test('同一个 code 的两段**不相邻**空档保持两段', () {
      // 窗口 07:00–09:00、固定日程 07:40–08:00 把它切成两段，任务不允许周一。
      // 两段都被星期排除，但中间隔着固定日程 ⇒ 不相邻 ⇒ 不合并。
      final t = task(
        allowedWeekdaysMask: allWeekdaysMask & ~(1 << (DateTime.monday - 1)),
      );
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(7), endUtc: at(9)),
        fixed: [
          BusyInterval(
            id: 'break',
            range: TimeRange(startUtc: at(7, 40), endUtc: at(8)),
          ),
        ],
      );

      final gaps = diagnose(forProblem: prob, forTask: t, remainingMinutes: 60)
          .excludedGaps
          .where((item) => item.code == GapExclusionCode.disallowedWeekday);

      expect(gaps, hasLength(2));
      expect(gaps.first.range.startUtc, at(7));
      expect(gaps.first.range.endUtc, at(7, 40));
      expect(gaps.last.range.startUtc, at(8));
      expect(gaps.last.range.endUtc, at(9));
    });

    test('诊断器输出的证据已经排好序且不留可合并的相邻项', () {
      // 窗口 06:00–09:00、最早开始 07:30、固定日程 07:30–07:40 ⇒ 空档
      // [07:00, 07:30) 与 [07:40, 09:00)；只有第一段早于最早开始时间，
      // 而第二段可用 80 分钟、够放一个 60 分钟的片段（因此不是排除项）。
      final t = task(availableFromUtc: at(7, 30), minChunk: 60, maxChunk: 60);
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: at(6), endUtc: at(9)),
        fixed: [
          BusyInterval(
            id: 'class',
            range: TimeRange(startUtc: at(7, 30), endUtc: at(7, 40)),
          ),
        ],
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      final before = diagnostics.excludedGaps
          .where((item) => item.code == GapExclusionCode.beforeAvailableFrom)
          .toList();
      expect(before, hasLength(1));
      expect(before.single.range.startUtc, at(7));
      expect(before.single.range.endUtc, at(7, 30));
      expect(
        diagnostics.hasEligibleCandidate,
        isTrue,
        reason: '07:40–09:00 有 80 分钟，装得下 60 分钟的片段',
      );
    });
    test('相同输入两次调用结果**逐值相同**（诊断数据也必须确定）', () {
      final t = task();
      final prob = problem(
        task: t,
        window: TimeRange(startUtc: day, endUtc: at(9)),
        fixed: [
          BusyInterval(
            id: 'a',
            range: TimeRange(startUtc: at(7, 20), endUtc: at(7, 40)),
          ),
          BusyInterval(
            id: 'b',
            range: TimeRange(startUtc: at(8), endUtc: at(8, 30)),
          ),
        ],
      );

      List<String> signature(TaskPlacementDiagnostics diagnostics) => [
        for (final gap in diagnostics.excludedGaps)
          '${gap.code.name}|${gap.range.startUtc.toIso8601String()}|'
              '${gap.range.endUtc.toIso8601String()}|${gap.requiredMinutes}|'
              '${gap.availableMinutes}',
        for (final reason in diagnostics.reasons)
          '${reason.code.name}|${reason.placementRemainingMinutes}|'
              '${reason.constraintRequiredMinutes}|'
              '${reason.constraintAvailableMinutes}',
      ];

      final first = signature(
        diagnose(forProblem: prob, forTask: t, remainingMinutes: 60),
      );
      final second = signature(
        diagnose(forProblem: prob, forTask: t, remainingMinutes: 60),
      );

      expect(second, first, reason: '同一份输入必须得到逐值相同的诊断');
    });

    test('没有空档时 `excludedGaps` 为空，而不是凭空造一段', () {
      final t = task();
      final prob = problem(
        task: t,
        window: TimeRange(
          startUtc: day,
          endUtc: day.add(const Duration(hours: 6)),
        ),
      );

      final diagnostics = diagnose(
        forProblem: prob,
        forTask: t,
        remainingMinutes: 60,
      );

      expect(diagnostics.excludedGaps, isEmpty, reason: '整段窗口都在睡眠里 ⇒ 没有空档可报');
      expect(diagnostics.hasEligibleCandidate, isFalse);
      expect(
        diagnostics.reasons.first.code,
        UnscheduledReasonCode.insufficientCapacity,
      );
    });
  });
}
