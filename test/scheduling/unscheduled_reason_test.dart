// Task 12A Step 6（用户 2026-10-08 的接口决定）：排程引擎输出**结构化**的未安排原因。
//
// 这个文件钉住路线图里那五条实施约束中属于引擎的三条：
//
// 1. 原因由引擎输出，预览层不得推测——因此断言的是引擎给的 `primaryReason.code`；
// 2. **不采用"最后一次被拒绝的约束"**：累计全部证据后按固定优先级选主原因，
//    因此同样的输入永远得到同样的说法（下面有专门的顺序无关用例）；
// 3. **`preferredWindow` 是软偏好，不得作为未安排主原因**——引擎可以排到期望时段之外。
//
// 为什么归因必须准确：用户据主原因决定下一步。说成"容量不足"他会去腾时间，而真实原因是
// "任务要求连续 30 分钟、截止前最长空档只有 20 分钟"——那要改的是截止时间或拆分方式。
// 归因错误比没有归因更糟。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);
  final day = DateTime.utc(2026, 10, 5);
  const zoneId = 'UTC';

  /// 一段固定的可用窗口。默认整整七天，能量窗口留空（不额外限制）。
  ScheduleProblem problem({
    required List<SchedulableTask> tasks,
    TimeRange? window,
    List<BusyInterval> fixed = const [],
    List<BusyInterval> protected = const [],
    List<PlannedBlock> locked = const [],
    LocalTimeRange? preferredStartWindow,
  }) {
    final planningWindow =
        window ??
        TimeRange(startUtc: day, endUtc: day.add(const Duration(days: 7)));
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
    );
    return ScheduleProblem(
      planningWindow: planningWindow,
      timeZoneId: zoneId,
      tasks: tasks,
      fixedIntervals: fixed,
      protectedIntervals: protected,
      lockedBlocks: locked,
      rules: rules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: planningWindow,
        rules: rules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: planningWindow,
        rules: rules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'unscheduled-reason',
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
    LocalTimeRange? preferredWindow,
  }) => SchedulableTask(
    id: id,
    requiredMinutes: requiredMinutes,
    splitMode: splitMode,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    dueAtUtc: dueAtUtc,
    availableFromUtc: availableFromUtc,
    maxMinutesPerLocalDay: maxMinutesPerLocalDay,
    preferredWindow: preferredWindow,
  );

  UnscheduledTask onlyUnscheduled(ScheduleProposal proposal) {
    expect(proposal.unscheduled, hasLength(1), reason: '这条用例的前提是恰好一个任务排不下');
    return proposal.unscheduled.single;
  }

  group('主原因由引擎给出，且能区分真实的约束', () {
    test('可用时段为零 ⇒ 兜底的总体容量不足', () {
      // 整周被保护时间占满。
      final proposal = engine.generate(
        problem(
          tasks: [task()],
          protected: [
            BusyInterval(
              id: 'all',
              range: TimeRange(
                startUtc: day,
                endUtc: day.add(const Duration(days: 7)),
              ),
            ),
          ],
        ),
      );

      final item = onlyUnscheduled(proposal);
      expect(
        item.primaryReason.code,
        UnscheduledReasonCode.insufficientCapacity,
      );
    });

    test('连续任务要求 60 分钟，但最长空档只有 30 分钟 ⇒ 连续空档太短', () {
      // 每天只有一个 30 分钟空档，分七天；任务要求一次做完 60 分钟。
      final fixed = <BusyInterval>[];
      for (var index = 0; index < 7; index++) {
        final base = day.add(Duration(days: index));
        fixed.add(
          BusyInterval(
            id: 'busy-morning-$index',
            range: TimeRange(
              startUtc: base,
              endUtc: base.add(const Duration(hours: 9)),
            ),
          ),
        );
        fixed.add(
          BusyInterval(
            id: 'busy-afternoon-$index',
            range: TimeRange(
              startUtc: base.add(const Duration(hours: 9, minutes: 30)),
              endUtc: base.add(const Duration(hours: 24)),
            ),
          ),
        );
      }

      final proposal = engine.generate(
        problem(
          tasks: [
            task(
              requiredMinutes: 60,
              minChunk: 60,
              maxChunk: 60,
              splitMode: TaskSplitMode.continuous,
            ),
          ],
          fixed: fixed,
        ),
      );

      final item = onlyUnscheduled(proposal);
      expect(
        item.primaryReason.code,
        UnscheduledReasonCode.continuousGapTooShort,
        reason: '唯一的空档只有 30 分钟，装不下"必须一次做完 60 分钟"的任务',
      );
      expect(item.primaryReason.constraintRequiredMinutes, 60);
      expect(item.primaryReason.constraintAvailableMinutes, 30);
    });

    test('最早开始时间在窗口之后 ⇒ 尚未到开始时间', () {
      final proposal = engine.generate(
        problem(
          tasks: [
            task(availableFromUtc: day.add(const Duration(days: 7, hours: 1))),
          ],
        ),
      );

      final item = onlyUnscheduled(proposal);
      expect(
        item.primaryReason.code,
        UnscheduledReasonCode.availableTimeNotReached,
      );
    });

    test('截止时间落在窗口前 ⇒ 截止前窗口不足，而不是笼统的容量不足', () {
      // 任务在窗口第一天 00:00 就到期，但可用时段从 09:00 才开始。
      final fixed = [
        BusyInterval(
          id: 'busy',
          range: TimeRange(
            startUtc: day,
            endUtc: day.add(const Duration(hours: 9)),
          ),
        ),
      ];
      final proposal = engine.generate(
        problem(
          tasks: [
            task(
              requiredMinutes: 60,
              dueAtUtc: day.add(const Duration(hours: 1)),
            ),
          ],
          fixed: fixed,
          // 只留第一天，确保别的日子帮不上忙。
          window: TimeRange(
            startUtc: day,
            endUtc: day.add(const Duration(days: 1)),
          ),
        ),
      );

      final item = onlyUnscheduled(proposal);
      expect(
        item.primaryReason.code,
        UnscheduledReasonCode.deadlineWindowTooShort,
        reason: '处置是"把截止时间往后挪"，与"腾出时间"完全不同',
      );
    });

    test('每日上限把量卡住 ⇒ 达到每日上限（且带上两个数字）', () {
      // 一周只留第一天一个 8 小时空档，日配额 30 分钟 ⇒ 只能放 30 分钟，其余排不下。
      final proposal = engine.generate(
        problem(
          tasks: [
            task(
              requiredMinutes: 120,
              minChunk: 30,
              maxChunk: 30,
              maxMinutesPerLocalDay: 30,
            ),
          ],
          window: TimeRange(
            startUtc: day,
            endUtc: day.add(const Duration(hours: 8)),
          ),
        ),
      );

      final item = onlyUnscheduled(proposal);
      expect(
        item.primaryReason.code,
        UnscheduledReasonCode.dailyLimitReached,
        reason: '容量其实够（8 小时空档），是单日配额把它拦住了',
      );
      expect(item.primaryReason.constraintAvailableMinutes, 30);
    });
  });

  group('优先级稳定，不依赖候选遍历顺序', () {
    test('同时有"每日上限"与"休息间隔"证据时，主原因是每日上限', () {
      // 依据路线图的优先级：dailyLimitReached 高于 requiredBreakUnavailable。
      const reasons = [
        UnscheduledReason(
          code: UnscheduledReasonCode.requiredBreakUnavailable,
          placementRemainingMinutes: 30,
        ),
        UnscheduledReason(
          code: UnscheduledReasonCode.dailyLimitReached,
          placementRemainingMinutes: 30,
        ),
      ];

      expect(
        primaryUnscheduledReason(reasons).code,
        UnscheduledReasonCode.dailyLimitReached,
      );
      // 换个顺序必须得到同一个答案——这正是"不采用最后一次拒绝原因"的可判定形式。
      expect(
        primaryUnscheduledReason(reasons.reversed.toList()).code,
        UnscheduledReasonCode.dailyLimitReached,
      );
    });

    test('**没有证据时不得回落"可用时间不足"**（1.8.0 专项 §2.4）', () {
      // 修复前这里返回 `insufficientCapacity`，而它**不带任何数字**——用户看到的是一句
      // 无法行动、也无法被测试证伪的"可用时间不足"。这与 Global Constraints
      // "引擎不得在没有 availableMinutes 或其它可判定证据时，把默认原因写成可用时间不足"
      // 直接冲突：空证据只说明"收集不到可判定的约束证据"，那正是"无法解释"的定义。
      expect(
        primaryUnscheduledReason(const []).code,
        UnscheduledReasonCode.unexplainedSchedulingFailure,
      );
    });

    test('**空 evidence 不得显示"可用时间不足"**（文案层同样钉住）', () {
      expect(
        unscheduledReasonLabel(primaryUnscheduledReason(const [])),
        isNot(contains('可用时间不足')),
      );
    });

    test('优先级表覆盖了枚举里的每一个取值', () {
      // 漏一个的后果是"那个原因永远不会成为主原因"，而失败表现完全看不出来——
      // 它只会让某类任务永远显示成别的说法。
      for (final code in UnscheduledReasonCode.values) {
        expect(
          unscheduledReasonPriority,
          contains(code),
          reason: '$code 不在优先级表里，它永远不会成为主原因',
        );
      }
      expect(
        unscheduledReasonPriority.toSet(),
        hasLength(UnscheduledReasonCode.values.length),
        reason: '优先级表里不该有重复项',
      );
    });

    test('**翻译链覆盖了枚举里的每一个取值**，且都不是空话（规范 §13.2）', () {
      // §13.2 要求"只有现有枚举确实无法表达新事实时，才增加**单一**新枚举值
      // **并补齐所有翻译测试**"。优先级表那一条已经钉住"每个取值都能当主原因"，
      // 但**没有任何用例钉住"每个取值都翻译得出来"** —— 而后者才是
      // "补齐所有翻译测试"的字面内容。
      //
      // 漏一个的后果很具体：原因位置是一句空文案，或者（更糟）有人为了让 switch 编过
      // 补一个 `_ => code.name` 之类兜底，于是**内部枚举名直接显示给用户**。
      final labels = <String, UnscheduledReasonCode>{};
      for (final code in UnscheduledReasonCode.values) {
        final label = unscheduledReasonLabel(
          UnscheduledReason(
            code: code,
            placementRemainingMinutes: 45,
            constraintRequiredMinutes: 45,
            constraintAvailableMinutes: 20,
            constraintLabel: '固定日程',
          ),
        );
        expect(label.trim(), isNotEmpty, reason: '$code 没有翻译文案，用户会看到一片空白');
        expect(
          label,
          isNot(contains(code.name)),
          reason:
              '$code 的文案里出现了枚举名本身，说明有人用 `code.name` 兜底——'
              '那是把内部标识显示给用户（与 §13.1 同类）',
        );
        labels[label] = code;
      }
      expect(
        labels,
        hasLength(UnscheduledReasonCode.values.length),
        reason: '两个不同的原因用了同一句文案，用户就分不出它们',
      );
    });

    test('**带证据的原因必须把数字说出来**（§13.2 的 constraint 数字）', () {
      // §13.2 点名要求复用两个 constraint 数字与 `constraintLabel` 证据。
      // 只验"文案非空"不够：一句"时间不够"也能通过，而那正是规范要避免的
      // （"不能退回'可用时间不足'"）。
      //
      // **它们不是总缺口**（计划 §2.4）：这里给的是某一条约束要求的量与同一口径下的
      // 可用量，正文因此只说约束，不再由它们推出第二个"还缺"（R7）。
      for (final code in const [
        UnscheduledReasonCode.continuousGapTooShort,
        UnscheduledReasonCode.deadlineWindowTooShort,
        UnscheduledReasonCode.minimumChunkTooLarge,
        UnscheduledReasonCode.insufficientCapacity,
      ]) {
        final label = unscheduledReasonLabel(
          UnscheduledReason(
            code: code,
            placementRemainingMinutes: 45,
            constraintRequiredMinutes: 45,
            constraintAvailableMinutes: 20,
          ),
        );
        expect(
          label,
          contains('45'),
          reason: '$code 必须报出"约束要求多少分钟"（constraintRequiredMinutes）',
        );
        expect(
          label,
          contains('20'),
          reason: '$code 必须报出"同一口径下有多少分钟"（constraintAvailableMinutes）',
        );
        expect(
          label,
          isNot(contains('还缺')),
          reason:
              '正文只描述约束；"还缺多少"只在标题里显示 `shortageMinutes`（R7：'
              'UI 不得从两个 constraint 数字推出第三个数字）',
        );
      }
    });

    test('`constraintLabel` 证据出现在它的两类原因里', () {
      for (final code in const [
        UnscheduledReasonCode.lockedPlanOccupied,
        UnscheduledReasonCode.availableTimeNotReached,
      ]) {
        expect(
          unscheduledReasonLabel(
            UnscheduledReason(
              code: code,
              placementRemainingMinutes: 30,
              constraintLabel: '固定日程',
            ),
          ),
          contains('固定日程'),
          reason: '$code 必须把"被什么挡住"这个证据说出来',
        );
      }
    });
  });

  group('§4：preferredWindow 是软偏好，不得作为未安排主原因', () {
    test('期望时段外仍有空间 ⇒ 正常排入，不产生未安排', () {
      final proposal = engine.generate(
        problem(
          tasks: [
            task(
              requiredMinutes: 60,
              minChunk: 30,
              maxChunk: 60,
              // 期望时段只覆盖深夜；白天排到它之外是允许的。
              preferredWindow: LocalTimeRange(
                startMinute: 23 * 60,
                endMinute: 24 * 60,
              ),
            ),
          ],
          // 窗口只有白天。
          window: TimeRange(
            startUtc: day.add(const Duration(hours: 9)),
            endUtc: day.add(const Duration(hours: 17)),
          ),
        ),
      );

      expect(proposal.unscheduled, isEmpty, reason: '期望时段是软偏好：引擎可以排到它之外');
      expect(proposal.blocks, isNotEmpty);
    });

    test('枚举里**没有**"期望时段不可用"这个原因', () {
      // 本批次不加"必须在此时段"的开关（路线图 Step 6 第 4 条）。等到那一天再加
      // `requiredWindowUnavailable`；现在如果有这个取值，就说明有人在把软偏好当硬约束。
      expect(
        UnscheduledReasonCode.values.map((code) => code.name),
        isNot(contains('requiredWindowUnavailable')),
      );
    });
  });

  group('A06/A07：精力匹配是**软偏好**，不得让候选消失', () {
    // 1.8.0 专项 §1.5：`CandidateScorer` 只在 `hardConstraintsSatisfied == false` 时拒绝候选；
    // `energyMatch` 只是正负评分。它**不能**让候选消失，否则"高精力任务排不进低精力时段"
    // 就会以"可用时间不足"的形态出现——而用户看到的日历明明还有空档。

    /// 一整周只有 [freeWindow] 可用。
    List<BusyInterval> busyExcept(TimeRange freeWindow, TimeRange window) {
      final result = <BusyInterval>[];
      if (freeWindow.startUtc.isAfter(window.startUtc)) {
        result.add(
          BusyInterval(
            id: 'before',
            range: TimeRange(
              startUtc: window.startUtc,
              endUtc: freeWindow.startUtc,
            ),
          ),
        );
      }
      if (freeWindow.endUtc.isBefore(window.endUtc)) {
        result.add(
          BusyInterval(
            id: 'after',
            range: TimeRange(
              startUtc: freeWindow.endUtc,
              endUtc: window.endUtc,
            ),
          ),
        );
      }
      return result;
    }

    test('A06 高精力时段被占、只剩低精力时段 ⇒ 仍然排进去', () {
      final window = TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 1)),
      );
      // 精力窗口：09:00–12:00 高、19:00–22:00 低。
      final rules = PlanningRules(
        energyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
            level: EnergyLevel.high,
          ),
          EnergyWindow(
            range: LocalTimeRange(startMinute: 19 * 60, endMinute: 22 * 60),
            level: EnergyLevel.low,
          ),
        ],
        sleepRange: LocalTimeRange(startMinute: 0, endMinute: 60),
        minimumSleepMinutes: 60,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 1440,
        weeklyLifeQuotaMinutes: 0,
      );
      final withEnergy = ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: [
          task(
            requiredMinutes: 60,
            minChunk: 60,
            maxChunk: 60,
            splitMode: TaskSplitMode.continuous,
          ),
        ],
        fixedIntervals: busyExcept(
          TimeRange(
            startUtc: day.add(const Duration(hours: 19)),
            endUtc: day.add(const Duration(hours: 22)),
          ),
          window,
        ),
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'energy-soft-preference',
      );

      final proposal = engine.generate(withEnergy);

      expect(
        proposal.unscheduled,
        isEmpty,
        reason:
            '高精力任务在只剩低精力时段时**必须**排进去：`energyMatch` 只是评分，'
            '不是候选资格。修复前若它被当成硬过滤，这里会以"可用时间不足"报缺口',
      );
      expect(proposal.blocks, isNotEmpty);
      expect(
        proposal.blocks.fold<int>(0, (sum, b) => sum + b.durationMinutes),
        60,
      );
    });

    test('A07 高低精力都有空 ⇒ 高精力候选优先（两者都合法）', () {
      final window = TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 1)),
      );
      // **只留两个空档**：09:00–12:00（高精力）与 19:00–22:00（低精力）。
      // 这样"选中的那块落在哪个空档"就是可判定的——若把整天都留成空闲，
      // 引擎还会在凌晨等"没有精力标签"的时段里挑位置，而那与 A07 要证的事无关。
      final highStart = day.add(const Duration(hours: 9));
      final highEnd = day.add(const Duration(hours: 12));
      final lowStart = day.add(const Duration(hours: 19));
      final lowEnd = day.add(const Duration(hours: 22));
      final rules = PlanningRules(
        energyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
            level: EnergyLevel.high,
          ),
          EnergyWindow(
            range: LocalTimeRange(startMinute: 19 * 60, endMinute: 22 * 60),
            level: EnergyLevel.low,
          ),
        ],
        sleepRange: LocalTimeRange(startMinute: 0, endMinute: 60),
        minimumSleepMinutes: 60,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 1440,
        weeklyLifeQuotaMinutes: 0,
      );
      final problem = ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: [task(requiredMinutes: 60, minChunk: 60, maxChunk: 60)],
        fixedIntervals: [
          BusyInterval(
            id: 'before',
            range: TimeRange(startUtc: day, endUtc: highStart),
          ),
          BusyInterval(
            id: 'middle',
            range: TimeRange(startUtc: highEnd, endUtc: lowStart),
          ),
          BusyInterval(
            id: 'after',
            range: TimeRange(
              startUtc: lowEnd,
              endUtc: day.add(const Duration(days: 1)),
            ),
          ),
        ],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'energy-both-available',
      );

      final proposal = engine.generate(problem);

      expect(proposal.unscheduled, isEmpty);
      expect(proposal.blocks, hasLength(1));
      final start = proposal.blocks.single.startUtc;
      expect(start.isBefore(highEnd), isTrue);
      expect(
        start.isBefore(highStart),
        isFalse,
        reason: '两个空档都合法，但高精力时段匹配 ⇒ 优先落在 09:00–12:00',
      );
    });
  });

  group('证据完整性：`insufficientCapacity` 必须带真实数字', () {
    // 1.8.0 专项 §2.5 第二条不变量（字段改名后仍逐条成立，计划 §2.4）：
    //   `insufficientCapacity => constraintAvailableMinutes != null
    //                            && constraintAvailableMinutes
    //                                 < constraintRequiredMinutes`
    // 这一条不是"文案好不好看"：没有数字的容量不足既无法被用户据以行动，
    // 也无法被测试证伪——它曾经是每一次排程故障的统一出口。
    test('整周被保护时间占满 ⇒ 容量不足，且两个数字都在', () {
      final proposal = engine.generate(
        problem(
          tasks: [task()],
          protected: [
            BusyInterval(
              id: 'all',
              range: TimeRange(
                startUtc: day,
                endUtc: day.add(const Duration(days: 7)),
              ),
            ),
          ],
        ),
      );

      final item = onlyUnscheduled(proposal);
      final reason = item.primaryReason;
      expect(reason.code, UnscheduledReasonCode.insufficientCapacity);
      expect(
        reason.constraintAvailableMinutes,
        isNotNull,
        reason: '必须带"同一口径下实际有多少分钟"',
      );
      expect(reason.constraintRequiredMinutes, isNotNull);
      expect(
        reason.constraintAvailableMinutes! < reason.constraintRequiredMinutes!,
        isTrue,
        reason: '容量不足的定义就是"可用少于需要"；不满足它就不是容量不足',
      );
      // 计划 §2.4 的字段不变量：放置剩余量就是最终缺口，正文里的两个
      // constraint 数字**不是**总缺口。
      expect(
        reason.placementRemainingMinutes,
        item.shortageMinutes,
        reason:
            '`placementRemainingMinutes == UnscheduledTask.shortageMinutes`',
      );
      // **空证据不得回落"可用时间不足"**：这一条与上面那条一起构成不变量。
      expect(
        item.primaryReason.code,
        isNot(UnscheduledReasonCode.unexplainedSchedulingFailure),
        reason: '整周被保护时间占满是**可解释**的容量不足',
      );
    });

    test('每条原因都钉住 `placementRemainingMinutes == shortageMinutes`', () {
      // 计划 §2.4 的不变量必须在**所有**原因上成立，而不只是主原因：
      // "展开查看其他限制"读的就是 `reasons`，它若带着别的轮次的剩余量，
      // 用户就会看到两组互相矛盾的数字。
      for (final proposal in [
        engine.generate(
          problem(
            tasks: [task()],
            protected: [
              BusyInterval(
                id: 'all',
                range: TimeRange(
                  startUtc: day,
                  endUtc: day.add(const Duration(days: 7)),
                ),
              ),
            ],
          ),
        ),
        engine.generate(
          problem(
            tasks: [
              task(
                requiredMinutes: 120,
                minChunk: 30,
                maxChunk: 30,
                maxMinutesPerLocalDay: 30,
              ),
            ],
            window: TimeRange(
              startUtc: day,
              endUtc: day.add(const Duration(hours: 8)),
            ),
          ),
        ),
      ]) {
        expect(proposal.unscheduled, isNotEmpty, reason: '前提：这条输入确实排不下');
        for (final item in proposal.unscheduled) {
          expect(
            item.primaryReason.placementRemainingMinutes,
            item.shortageMinutes,
          );
          for (final reason in item.reasons) {
            expect(reason.placementRemainingMinutes, item.shortageMinutes);
          }
        }
      }
    });

    test('**无法解释的零安排被结构化识别**（§2.5 第三条不变量）', () {
      // 构造"有可放置容量、却一个块都没落下"的形状：这只能通过**注入**实现
      // ——引擎自己若产出这种结果，本身就是它被识别出来的理由。
      // 这里钉的是"识别规则"本身：空证据 ⇒ unexplainedSchedulingFailure，
      // 且它**不含 UUID**、文案是固定那一句。
      const reason = UnscheduledReason(
        code: UnscheduledReasonCode.unexplainedSchedulingFailure,
        placementRemainingMinutes: 60,
        constraintRequiredMinutes: 60,
        constraintAvailableMinutes: 120,
      );
      expect(
        unscheduledReasonLabel(reason),
        isNot(contains('可用时间不足')),
        reason: '它的处置是"重新生成并导出诊断"，不是"腾时间"',
      );
      expect(unscheduledReasonLabel(reason), contains('本次计划未自动应用'));
    });
  });
}
