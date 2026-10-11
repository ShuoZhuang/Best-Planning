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
  }) => ScheduleProblem(
    planningWindow:
        window ??
        TimeRange(startUtc: day, endUtc: day.add(const Duration(days: 7))),
    timeZoneId: zoneId,
    tasks: tasks,
    fixedIntervals: fixed,
    protectedIntervals: protected,
    lockedBlocks: locked,
    rules: PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'unscheduled-reason',
  );

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
      expect(item.primaryReason.requiredMinutes, 60);
      expect(item.primaryReason.availableMinutes, 30);
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
      expect(item.primaryReason.availableMinutes, 30);
    });
  });

  group('优先级稳定，不依赖候选遍历顺序', () {
    test('同时有"每日上限"与"休息间隔"证据时，主原因是每日上限', () {
      // 依据路线图的优先级：dailyLimitReached 高于 requiredBreakUnavailable。
      const reasons = [
        UnscheduledReason(code: UnscheduledReasonCode.requiredBreakUnavailable),
        UnscheduledReason(code: UnscheduledReasonCode.dailyLimitReached),
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

    test('没有证据时回落到兜底的容量不足', () {
      expect(
        primaryUnscheduledReason(const []).code,
        UnscheduledReasonCode.insufficientCapacity,
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
            requiredMinutes: 45,
            availableMinutes: 20,
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

    test('**带证据的原因必须把数字说出来**（§13.2 的 requiredMinutes/availableMinutes）', () {
      // §13.2 点名要求复用 `requiredMinutes`／`availableMinutes`／`constraintLabel` 证据。
      // 只验"文案非空"不够：一句"时间不够"也能通过，而那正是规范要避免的
      // （"不能退回'可用时间不足'"）。
      for (final code in const [
        UnscheduledReasonCode.continuousGapTooShort,
        UnscheduledReasonCode.deadlineWindowTooShort,
        UnscheduledReasonCode.minimumChunkTooLarge,
        UnscheduledReasonCode.insufficientCapacity,
      ]) {
        final label = unscheduledReasonLabel(
          UnscheduledReason(
            code: code,
            requiredMinutes: 45,
            availableMinutes: 20,
          ),
        );
        expect(
          label,
          contains('45'),
          reason: '$code 必须报出"需要多少分钟"（requiredMinutes）',
        );
        expect(
          label,
          contains('20'),
          reason: '$code 必须报出"实际有多少分钟"（availableMinutes）',
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
            UnscheduledReason(code: code, constraintLabel: '固定日程'),
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
}
