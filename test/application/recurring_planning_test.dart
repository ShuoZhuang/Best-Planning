// M6（路线图 §3.4、§7.2、§11 Task 8）：周期目标进排程。
//
// 这个文件直接测**展开函数与引擎的组合**，不碰数据库：§11 Task 8 的三条验收
// （均匀分布不会全堆到周日、结果不依赖返回顺序、容量不足返回精确缺口且保护时间逐值不变）
// 都是纯逻辑，用真库跑只会慢，不会更准。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

const _timeZoneId = 'Asia/Shanghai';

/// 本地 2026-10-05（周一）00:00 对应的 UTC 瞬间。
final _weekStartUtc = DateTime.utc(2026, 10, 4, 16);
final _weekEndUtc = DateTime.utc(2026, 10, 11, 16);

final _zones = TimeZoneDatabase();

RecurringTaskTemplate _template({
  String id = 'template-1',
  String title = '每周英语',
  int targetMinutes = 180,
  RecurringPace pace = RecurringPace.even,
  int allowedWeekdaysMask = recurringAllWeekdaysMask,
  int minChunk = 30,
  int maxChunk = 60,
  TaskPriority priority = TaskPriority.medium,
}) => RecurringTaskTemplate(
  id: id,
  title: title,
  targetMinutes: targetMinutes,
  priority: priority,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: minChunk,
  maxChunkMinutes: maxChunk,
  pace: pace,
  allowedWeekdaysMask: allowedWeekdaysMask,
  startsOnLocalDate: DateTime(2026, 9, 28),
  timeZoneId: _timeZoneId,
  createdAtUtc: DateTime.utc(2026, 9, 28),
  updatedAtUtc: DateTime.utc(2026, 9, 28),
);

RecurringTaskCycle _cycle({
  String templateId = 'template-1',
  String taskId = 'recurring:template-1:2026-10-05',
  int baseTarget = 180,
  int carryIn = 0,
  RecurringCycleStatus status = RecurringCycleStatus.open,
}) => RecurringTaskCycle(
  templateId: templateId,
  periodStartLocalDate: DateTime(2026, 10, 5),
  taskId: taskId,
  baseTargetMinutes: baseTarget,
  carryInMinutes: carryIn,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 5),
  updatedAtUtc: DateTime.utc(2026, 10, 5),
);

RecurringProgress _progress({
  int recorded = 0,
  int target = 180,
  int carryIn = 0,
}) => RecurringProgress(
  templateId: 'template-1',
  periodStartLocalDate: DateTime(2026, 10, 5),
  targetMinutes: target + carryIn,
  recordedMinutes: recorded,
  remainingMinutes: (target + carryIn - recorded).clamp(0, 1 << 30),
  status: RecurringCycleStatus.open,
  carryInMinutes: carryIn,
);

WeeklyPeriod get _period =>
    WeeklyPeriod.startingAt(DateTime(2026, 10, 5), _timeZoneId, _zones);

List<SchedulableTask> _expand({
  required RecurringTaskTemplate template,
  required RecurringProgress progress,
  RecurringTaskCycle? cycle,
}) => recurringSchedulableTasks(
  input: RecurringScheduleInput(
    template: template,
    cycle: cycle ?? _cycle(baseTarget: template.targetMinutes),
    progress: progress,
    period: _period,
    planningStartUtc: _weekStartUtc,
  ),
  zones: _zones,
);

PlanningRules _rules({
  List<ProtectedTimeRule> protectedTimes = const [],
  int breakMinutes = 0,
}) => PlanningRules(
  energyWindows: const [],
  protectedTimes: protectedTimes,
  sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
  minimumSleepMinutes: 420,
  defaultFocusMinutes: 60,
  breakMinutes: breakMinutes,
  dailyMovableTaskLimitMinutes: 1440,
  weeklyLifeQuotaMinutes: 0,
  minChunkMinutes: 15,
  maxChunkMinutes: 120,
  granularityMinutes: 5,
);

void main() {
  group('展开成排程输入', () {
    test('180 目标、80 已记录 ⇒ 只送 100 分钟（§7.2 第二条）', () {
      final tasks = _expand(
        template: _template(),
        progress: _progress(recorded: 80),
      );
      expect(tasks, hasLength(1));
      expect(tasks.single.requiredMinutes, 100);
      // 截止＝本周末：引擎据此把 100 分钟摊到整周，而不是堆到最后一天。
      expect(tasks.single.dueAtUtc, _weekEndUtc);
    });

    test('已达标时不送任何排程输入', () {
      expect(
        _expand(template: _template(), progress: _progress(recorded: 180)),
        isEmpty,
      );
    });

    test('跳过的一周不送排程输入', () {
      expect(
        _expand(
          template: _template(),
          progress: _progress(),
          cycle: _cycle(status: RecurringCycleStatus.skipped),
        ),
        isEmpty,
      );
    });

    test('结转计入剩余量', () {
      final tasks = _expand(
        template: _template(),
        progress: _progress(target: 180, carryIn: 100),
      );
      expect(tasks.single.requiredMinutes, 280);
    });

    test('尽早完成把截止时间提前，且不晚于本周末', () {
      final tasks = _expand(
        template: _template(pace: RecurringPace.early),
        progress: _progress(),
      );
      expect(tasks.single.dueAtUtc!.isBefore(_weekEndUtc), isTrue);
    });

    test('仅指定星期保留一个任务并写入允许星期与均分策略', () {
      final tasks = _expand(
        template: _template(
          pace: RecurringPace.selectedWeekdays,
          allowedWeekdaysMask: weekdayMaskOf([
            DateTime.wednesday,
            DateTime.saturday,
          ]),
        ),
        progress: _progress(recorded: 80),
      );
      expect(tasks, hasLength(1));
      expect(tasks.single.requiredMinutes, 100);
      expect(
        tasks.single.allowedWeekdaysMask,
        weekdayMaskOf([DateTime.wednesday, DateTime.saturday]),
      );
      // **1.7.1 起不再写 `maxMinutesPerLocalDay`**（计划 Task 5 Step 2）：那个由
      // "剩余 ÷ 天数"算出的单一配额会被引擎的"第二轮全局放开"抵消，实测让一天堆到 125 分钟
      // （计划 §2.1）。现在表达"均匀"的是显式策略，每日预算由均分器按**真实容量**算。
      expect(
        tasks.single.maxMinutesPerLocalDay,
        isNull,
        reason: '均匀分布不再靠单日配额表达',
      );
      expect(
        tasks.single.distributionPolicy,
        TaskDistributionPolicy.even,
        reason: '仅指定星期同样是"在被选日期间均分"（计划 §3.4）',
      );
      expect(tasks.single.availableFromUtc, _weekStartUtc);
      expect(tasks.single.dueAtUtc, _weekEndUtc);
    });

    test('均匀分布与仅指定星期都映射为 even；尽早完成与截止加权不映射', () {
      // 计划 Task 5 Step 1 的映射矩阵。`early`／`deadlineWeighted` 表达的是"什么时候做完"，
      // 不是"每天做多少"，因此保持 unconstrained。
      TaskDistributionPolicy policyOf(RecurringPace pace, {int? mask}) =>
          _expand(
            template: _template(
              pace: pace,
              allowedWeekdaysMask: mask ?? recurringAllWeekdaysMask,
            ),
            progress: _progress(),
          ).single.distributionPolicy;

      expect(policyOf(RecurringPace.even), TaskDistributionPolicy.even);
      expect(
        policyOf(
          RecurringPace.selectedWeekdays,
          mask: weekdayMaskOf([DateTime.wednesday]),
        ),
        TaskDistributionPolicy.even,
      );
      expect(
        policyOf(RecurringPace.early),
        TaskDistributionPolicy.unconstrained,
      );
      expect(
        policyOf(RecurringPace.deadlineWeighted),
        TaskDistributionPolicy.unconstrained,
      );
    });

    test('仅指定星期选了全部七天时等价于均匀分布', () {
      final tasks = _expand(
        template: _template(pace: RecurringPace.selectedWeekdays),
        progress: _progress(),
      );
      expect(tasks, hasLength(1));
      expect(tasks.single.dueAtUtc, _weekEndUtc);
      expect(tasks.single.allowedWeekdaysMask, recurringAllWeekdaysMask);
    });
  });

  group('引擎里的表现', () {
    ScheduleProblem problem({
      required List<SchedulableTask> tasks,
      List<BusyInterval> protectedIntervals = const [],
      List<BusyInterval> fixedIntervals = const [],
    }) {
      final window = TimeRange(startUtc: _weekStartUtc, endUtc: _weekEndUtc);
      final zoneId = 'UTC';
      final rules = _rules();
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: tasks,
        fixedIntervals: fixedIntervals,
        protectedIntervals: protectedIntervals,
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'recurring-planning-v1',
      );
    }

    test('均匀分布不会把 180 分钟全堆到周日（§11 Task 8 Step 1）', () {
      // 片段上限定成 30 分钟：180 分钟因此**必须**拆成多段，否则这条用例的
      // "分布在多于一天上"会被"引擎本可以选择一段 60 分钟"掩盖掉。
      final tasks = _expand(
        template: _template(minChunk: 30, maxChunk: 30),
        progress: _progress(),
      );
      final proposal = DeterministicScheduleEngine(_zones)
          .generate(problem(tasks: tasks));

      final blocks = proposal.blocks
          .where((block) => block.taskId == tasks.single.id)
          .toList();
      expect(blocks.length, greaterThan(1), reason: '180 分钟应被拆成多段');
      final localDates = {
        for (final block in blocks)
          (() {
            final local = _zones.toLocal(block.startUtc, _timeZoneId);
            return '${local.year}-${local.month}-${local.day}';
          })(),
      };
      expect(
        localDates.length,
        greaterThan(1),
        reason: '“均匀分布”至少应跨两个本地日期，实际只有 $localDates',
      );
    });

    test('只送剩余 100 分钟 ⇒ 引擎最多排 100 分钟', () {
      final tasks = _expand(
        template: _template(),
        progress: _progress(recorded: 80),
      );
      final proposal = DeterministicScheduleEngine(_zones)
          .generate(problem(tasks: tasks));
      final scheduled = proposal.blocks
          .where((block) => block.taskId == tasks.single.id)
          .fold<int>(0, (sum, block) => sum + block.durationMinutes);
      expect(scheduled, lessThanOrEqualTo(100));
      expect(proposal.metrics.scheduledMinutes, lessThanOrEqualTo(100));
    });

    test('仅指定星期不会排到未选择的本地星期', () {
      final tasks = _expand(
        template: _template(
          pace: RecurringPace.selectedWeekdays,
          allowedWeekdaysMask: weekdayMaskOf([
            DateTime.wednesday,
            DateTime.saturday,
          ]),
        ),
        progress: _progress(recorded: 80),
      );
      final proposal = DeterministicScheduleEngine(_zones)
          .generate(problem(tasks: tasks));
      final blocks = proposal.blocks
          .where((block) => block.taskId == tasks.single.id)
          .toList();
      expect(blocks, isNotEmpty);
      expect(
        blocks.map(
          (block) => _zones.toLocal(block.startUtc, _timeZoneId).weekday,
        ),
        everyElement(isIn([DateTime.wednesday, DateTime.saturday])),
      );
    });

    test('结果不依赖输入顺序（§7.2 最后一条）', () {
      final tasks = _expand(template: _template(), progress: _progress());
      final forward = DeterministicScheduleEngine(_zones)
          .generate(problem(tasks: tasks));
      final reversed = DeterministicScheduleEngine(_zones)
          .generate(problem(tasks: [...tasks.reversed]));
      expect(
        reversed.blocks
            .map(
              (block) => '${block.taskId}@${block.startUtc.toIso8601String()}',
            )
            .toList(),
        forward.blocks
            .map(
              (block) => '${block.taskId}@${block.startUtc.toIso8601String()}',
            )
            .toList(),
      );
    });

    test('容量只有 120 分钟时：保护时间逐值不变，缺口恰好 60（§7.2）', () {
      // 一周里只留 120 分钟空闲：周日 20:00–22:00。保护时间占住其余全部时段。
      final protected = <BusyInterval>[
        BusyInterval(
          id: 'protected-week',
          range: TimeRange(
            startUtc: _weekStartUtc,
            endUtc: DateTime.utc(2026, 10, 11, 12),
          ),
        ),
        BusyInterval(
          id: 'protected-tail',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 11, 14),
            endUtc: _weekEndUtc,
          ),
        ),
      ];
      final before = [
        for (final interval in protected)
          '${interval.id}:${interval.range.startUtc.toIso8601String()}'
              '-${interval.range.endUtc.toIso8601String()}',
      ];
      final tasks = _expand(template: _template(), progress: _progress());
      final problemWithProtected = problem(
        tasks: tasks,
        protectedIntervals: protected,
      );

      final shortfall = capacityShortfallForRecurringGoal(
        templateId: 'template-1',
        title: '每周英语',
        periodStartLocalDate: DateTime(2026, 10, 5),
        targetMinutes: tasks.single.requiredMinutes,
        window: problemWithProtected.planningWindow,
        protectedRanges: [
          for (final interval in problemWithProtected.protectedIntervals)
            interval.range,
        ],
        protectedConstraint: ProtectedTimeKind.fixedRest,
      );
      expect(shortfall, isNotNull);
      expect(
        shortfall!.schedulableMinutes,
        120,
        reason: '窗口内只剩 2 小时（120 分钟）空闲',
      );
      expect(shortfall.shortfallMinutes, 60, reason: '180 − 120 = 60，必须精确');
      expect(shortfall.targetMinutes, 180);

      // **保护时间逐值不变**：缺口是一份报告，不是一个"挪开保护时间"的许可。
      final after = [
        for (final interval in problemWithProtected.protectedIntervals)
          '${interval.id}:${interval.range.startUtc.toIso8601String()}'
              '-${interval.range.endUtc.toIso8601String()}',
      ];
      expect(after, before);

      // 引擎也如实报告排不下，而不是假装安排成功。
      final proposal = DeterministicScheduleEngine(_zones)
          .generate(problemWithProtected);
      final shortage = proposal.unscheduled
          .where((item) => item.taskId == tasks.single.id)
          .fold<int>(0, (sum, item) => sum + item.shortageMinutes);
      expect(shortage, 60);
    });

    test('没有缺口时不报缺口（恰恰够用不算不够）', () {
      final tasks = _expand(
        template: _template(targetMinutes: 60),
        progress: _progress(target: 60),
      );
      expect(
        capacityShortfallForRecurringGoal(
          templateId: 'template-1',
          title: '每周英语',
          periodStartLocalDate: DateTime(2026, 10, 5),
          targetMinutes: tasks.single.requiredMinutes,
          window: TimeRange(startUtc: _weekStartUtc, endUtc: _weekEndUtc),
        ),
        isNull,
      );
    });

    test('恰恰够用时不报缺口（固定日程占掉 4 天，剩 3 天恰好 180 分钟）', () {
      final shortfall = capacityShortfallForRecurringGoal(
        templateId: 'template-1',
        title: '每周英语',
        periodStartLocalDate: DateTime(2026, 10, 5),
        targetMinutes: 180,
        window: TimeRange(startUtc: _weekStartUtc, endUtc: _weekEndUtc),
        fixedRanges: [
          TimeRange(startUtc: _weekStartUtc, endUtc: DateTime.utc(2026, 10, 9)),
        ],
      );
      // 窗口 7 天 = 10080 分钟；扣掉固定日程 4 天（5760）与其余 3 天各 480 分钟睡眠。
      expect(shortfall, isNull, reason: '恰恰够用不是不够');
    });

    test('固定日程占用会算进容量扣减', () {
      final shortfall = capacityShortfallForRecurringGoal(
        templateId: 'template-1',
        title: '每周英语',
        periodStartLocalDate: DateTime(2026, 10, 5),
        targetMinutes: 180,
        window: TimeRange(startUtc: _weekStartUtc, endUtc: _weekEndUtc),
        // **占满整周**：一段固定日程把 7 天全占掉时，连"再挤一挤"的余地都没有。
        fixedRanges: [
          TimeRange(
            startUtc: _weekStartUtc,
            endUtc: DateTime.utc(2026, 10, 11, 16),
          ),
        ],
      );
      expect(shortfall, isNotNull);
      expect(shortfall!.schedulableMinutes, 0);
      expect(shortfall.shortfallMinutes, 180);
    });

    test('重叠的保护区间不会重复扣减', () {
      final shortfall = capacityShortfallForRecurringGoal(
        templateId: 'template-1',
        title: '每周英语',
        periodStartLocalDate: DateTime(2026, 10, 5),
        targetMinutes: 10080,
        window: TimeRange(startUtc: _weekStartUtc, endUtc: _weekEndUtc),
        protectedRanges: [
          TimeRange(startUtc: _weekStartUtc, endUtc: DateTime.utc(2026, 10, 9)),
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 12),
            endUtc: DateTime.utc(2026, 10, 10),
          ),
        ],
      );
      expect(shortfall, isNotNull);
      // 两段合并后覆盖 10-05 00:00 → 10-10 16:00（本地），剩 40 小时 = 2400 分钟。
      // **若重复扣减**，结果会是 10080 − 7000 − 6700，负得离谱——而不是 2400。
      expect(shortfall!.schedulableMinutes, 2400);
    });
  });
}
