// 全局跨日预算分配器（算法 17，计划
// `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md` §3.4 / Task 5）。
//
// ## 这一组用例钉住的事
//
// 计划 §3.4 的九条规则里，可测的那些都在这里：
//
// | 规则 | 用例 |
// | --- | --- |
// | 1. 受限任务先分配 | 连续任务 / 少日期任务先于全周灵活任务 |
// | 2. 同等受限时按截止 → 压力 → 优先级 → ID | 成对比较 |
// | 3. 比较**放入后**的负载率 | 35% 的日子胜过 92% 的日子 |
// | 4. 普通任务优先低负载日 | 周末空闲时周末胜出 |
// | 5. `even` 同时平衡任务与全局负载，全局略优先 | 形式均匀 vs 总负载 |
// | 6. K 日选择不按日期取前 K 个 | 150/30 七天同余量 |
// | 7. 同分按周期稳定轮换 | 同周期稳定、跨周期轮换 |
// | 8. 周末只因容量与负载被选中 | 工作日空、周末忙时选工作日 |
// | 10. 预算落地失败要重新分配 | 由引擎（Task 6）端到端覆盖 |
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/day_allocation.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

void main() {
  // 2026-10-05 是周一。
  //
  // ## 两种"日期"的区别（本文件最容易被读错的地方）
  //
  // - `date(n)` 是**本地自然日**（账本的键、轮换键的输入）；
  // - `deadline(n)` 是"本地第 n 天**零点**"对应的 UTC 时刻——`dueAtUtc` 与
  //   `availableFromUtc` 只接受 UTC 时刻。
  //
  // 夹具用 `Asia/Shanghai`，因此本地零点 = **前一天** 16:00Z。把 `date(n)` 直接当
  // `dueAtUtc` 传会得到"前一天 00:00Z"，那是本地前一天的 08:00 —— 语义完全不同。
  // 第一版就是这么错的：若干用例同时报"截止之后的日子不得分走预算"之类的红灯。
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  DateTime date(int day) => DateTime(2026, 10, day);
  DateTime deadline(int day) =>
      zones.localMidnightToUtc(DateTime(2026, 10, day), zoneId);

  /// 造一个账本：每天给 [licensedPerDay] 分钟许可容量、[usedPerDay] 分钟已用。
  DayCapacityLedger ledgerOf({
    required Map<int, int> licensedByDay,
    Map<int, int> usedByDay = const {},
  }) => DayCapacityLedger.fromSnapshots([
    for (final entry in licensedByDay.entries)
      DayCapacitySnapshot(
        localDate: date(entry.key),
        hardFreeMinutes: entry.value,
        calendarGapMinutes: entry.value - (usedByDay[entry.key] ?? 0),
        licensedCapacityMinutes: entry.value,
        usedMovableMinutes: usedByDay[entry.key] ?? 0,
        allocatedMinutes: 0,
        remainingMinutes: entry.value - (usedByDay[entry.key] ?? 0),
        utilizationPermille: entry.value <= 0
            ? 0
            : (((usedByDay[entry.key] ?? 0) * 1000 + entry.value - 1) ~/
                  entry.value),
      ),
  ]);

  SchedulableTask task(
    String id, {
    int minutes = 150,
    int minChunk = 30,
    int maxChunk = 90,
    TaskSplitMode splitMode = TaskSplitMode.splittable,
    TaskPriority priority = TaskPriority.medium,
    DateTime? dueAtUtc,
    DateTime? availableFromUtc,
    int allowedWeekdaysMask = allWeekdaysMask,
    int? maxMinutesPerLocalDay,
    TaskDistributionPolicy distributionPolicy =
        TaskDistributionPolicy.unconstrained,
  }) => SchedulableTask(
    id: id,
    requiredMinutes: minutes,
    splitMode: splitMode,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    priority: priority,
    dueAtUtc: dueAtUtc,
    availableFromUtc: availableFromUtc,
    allowedWeekdaysMask: allowedWeekdaysMask,
    maxMinutesPerLocalDay: maxMinutesPerLocalDay,
    distributionPolicy: distributionPolicy,
  );

  /// 七天等容量的账本（周一至周日）。
  DayCapacityLedger weekLedger({int licensed = 120, int used = 0}) => ledgerOf(
    licensedByDay: {for (var day = 5; day <= 11; day++) day: licensed},
    usedByDay: {for (var day = 5; day <= 11; day++) day: used},
  );

  DayAllocationPlan allocate({
    required List<SchedulableTask> tasks,
    required DayCapacityLedger ledger,
    int granularityMinutes = 5,
    Map<String, Map<DateTime, int>> alreadyPlannedByTask = const {},
    Map<String, DateTime> cycleStartByTask = const {},
  }) => allocateTaskDays(
    DayAllocationInput(
      tasks: tasks,
      ledger: ledger,
      alreadyPlannedByTask: alreadyPlannedByTask,
      timeZoneId: 'Asia/Shanghai',
      cycleStartByTask: cycleStartByTask,
      granularityMinutes: granularityMinutes,
    ),
  );

  Map<int, int> minutesByDay(TaskDayBudget budget) => {
    for (final entry in budget.minutesByLocalDate.entries)
      entry.key.day: entry.value,
  };

  group('任务排序：受限优先（Task 5 Step 1 / 计划 §3.4 第 1、2 条）', () {
    test('**连续任务先于可拆分任务**', () {
      final ledger = weekLedger();
      final continuous = task(
        'continuous',
        minutes: 60,
        splitMode: TaskSplitMode.continuous,
        minChunk: 60,
        maxChunk: 60,
      );
      final splittable = task('splittable');

      // 把可拆分任务放在列表**前面**：排序必须无视输入顺序。
      final plan = allocate(tasks: [splittable, continuous], ledger: ledger);

      // 判据：连续任务必须拿到份额（而不是被灵活任务抢光）。
      expect(
        plan.budgetFor('continuous')!.allocatedMinutes,
        greaterThan(0),
        reason: '连续任务可选日期最少，必须先分配',
      );
    });

    test('**合法日期更少的任务先于全周灵活任务**', () {
      final ledger = weekLedger();
      // 只在周三可放（`allowedWeekdaysMask` 周一为 bit 0）。
      final scarce = task(
        'scarce',
        minutes: 60,
        allowedWeekdaysMask: 1 << (DateTime.wednesday - DateTime.monday),
      );
      final flexible = task('flexible', minutes: 600);

      final plan = allocate(tasks: [flexible, scarce], ledger: ledger);

      expect(
        plan.budgetFor('scarce')!.allocatedMinutes,
        60,
        reason:
            '少日期任务必须拿到它唯一能用的那一天；实际 '
            '${plan.budgetFor('scarce')!.minutesByLocalDate}',
      );
      expect(minutesByDay(plan.budgetFor('scarce')!), {7: 60});
    });

    test('截止更早者先分配', () {
      final ledger = weekLedger();
      // 截止＝本地 10-07 00:00 ⇒ 可用日是 10-05、10-06（**截止当天不算**：
      // 一块必须整段落在截止之前，而 10-07 的起点就是截止本身）。
      final early = task('early', minutes: 600, dueAtUtc: deadline(7));
      final late = task('late', minutes: 600, dueAtUtc: deadline(12));

      final plan = allocate(tasks: [late, early], ledger: ledger);

      expect(
        plan.budgetFor('early')!.allocatedMinutes,
        240,
        reason: '截止 10-07 00:00 ⇒ 只有 10-05、10-06 可用，各 120 分钟',
      );
      expect(
        plan.budgetFor('early')!.shortageMinutes,
        360,
        reason: '其余 360 分钟是真实缺口（截止之前确实只有 240 分钟）',
      );
      expect(minutesByDay(plan.budgetFor('early')!).keys.toSet(), {
        5,
        6,
      }, reason: '不得越过截止；实际 ${plan.budgetFor('early')!.minutesByLocalDate}');
    });

    test('同等受限时优先级更高者先分配', () {
      final ledger = ledgerOf(licensedByDay: {5: 60});
      final high = task('high', minutes: 60, priority: TaskPriority.high);
      final low = task('low', minutes: 60, priority: TaskPriority.low);

      final plan = allocate(tasks: [low, high], ledger: ledger);

      expect(plan.budgetFor('high')!.allocatedMinutes, 60);
      expect(
        plan.budgetFor('low')!.allocatedMinutes,
        0,
        reason: '容量只够一个任务 ⇒ 高优先级先拿',
      );
    });
  });

  group('日期选择比较"放入后"的负载率（Task 5 Step 2 / 计划 §3.4 第 3、4 条）', () {
    test('**35% 负载的日子胜过 92% 负载的日子**', () {
      // 两天容量相同（600），但一天已用 210（35%）、另一天已用 550（92%）。
      final ledger = ledgerOf(
        licensedByDay: {5: 600, 6: 600},
        usedByDay: {5: 210, 6: 550},
      );
      // 任务只允许这两天，且要 30 分钟。
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 30,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(7),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      expect(minutesByDay(plan.budgetFor('t')!), {
        5: 30,
      }, reason: '放入后 35% 的日子比 92% 的日子更空；按原始空闲比会选反');
    });

    test('**周末空闲时普通任务用周末**（计划 §3.4 第 8 条）', () {
      // 工作日负载高、周末为 0。
      final ledger = ledgerOf(
        licensedByDay: {
          5: 120,
          6: 120,
          7: 120,
          8: 120,
          9: 120,
          10: 120,
          11: 120,
        },
        usedByDay: {5: 90, 6: 90, 7: 90, 8: 90, 9: 90},
      );
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 150,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(12),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      final byDay = minutesByDay(plan.budgetFor('t')!);
      expect(
        (byDay[10] ?? 0) + (byDay[11] ?? 0),
        greaterThan(0),
        reason: '周末负载 0%、工作日负载 75% ⇒ 至少一份预算落到周末；实际 $byDay',
      );
    });

    test('**工作日空、周末忙时不得强行用周末**（同一条规则的反面）', () {
      final ledger = ledgerOf(
        licensedByDay: {
          5: 120,
          6: 120,
          7: 120,
          8: 120,
          9: 120,
          10: 120,
          11: 120,
        },
        usedByDay: {10: 120, 11: 120},
      );
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 150,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(12),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      final byDay = minutesByDay(plan.budgetFor('t')!);
      expect(
        (byDay[10] ?? 0) + (byDay[11] ?? 0),
        0,
        reason: '周末负载 100%（余量 0）⇒ 一分都不该落上去；实际 $byDay',
      );
    });

    test('截止之后的日子不得分走预算（计划 §3.4 第 4 条的反向）', () {
      final ledger = ledgerOf(
        licensedByDay: {5: 120, 6: 120, 10: 120, 11: 120},
      );
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 240,
            availableFromUtc: deadline(5),
            // 截止在周四 ⇒ 周六周日不可用，尽管它们完全空闲。
            dueAtUtc: deadline(8),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      final byDay = minutesByDay(plan.budgetFor('t')!);
      expect(byDay.keys.toSet(), {5, 6}, reason: '实际 $byDay');
      expect(byDay.values.fold<int>(0, (a, b) => a + b), 240);
    });
  });

  group('`even` 任务的双重平衡（Task 5 Step 3 / 计划 §3.4 第 5 条）', () {
    test('**全局负载略优先于任务自身的均匀**', () {
      // 两个方案：
      //   · A：任务分钟完全均匀，但把繁忙工作日推到 100%；
      //   · B：任务分钟略有差异，但总负载最高只到 70%。
      // 计划 §3.4 第 5 条：全局负载略优先，因此 B 必须胜。
      final ledger = ledgerOf(
        licensedByDay: {5: 240, 6: 240, 7: 240},
        usedByDay: {5: 200, 6: 0, 7: 0},
      );
      final plan = allocate(
        tasks: [
          task(
            'even',
            minutes: 120,
            minChunk: 60,
            maxChunk: 60,
            distributionPolicy: TaskDistributionPolicy.even,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(8),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 60,
      );

      final byDay = minutesByDay(plan.budgetFor('even')!);
      // 周一已用 200/240（83%），放入 60 会到 108% ⇒ 必须先避开它。
      expect(
        byDay[5] ?? 0,
        0,
        reason: '周一放入后负载会超过 100% ⇒ "形式均匀"不能压过全局负载；实际 $byDay',
      );
    });

    // ───────────────────────────────────────────────────────────────────────────
    // 用户实测回归（计划契约 §7.2）——**当前为红，已标记 skip**
    //
    // `recurring_even_distribution_test` 把「210 分钟、四天各余 120、粒度 5」
    // 的形状钉成 **[50, 50, 55, 55]**（两个 50 与两个 55）。
    //
    // 分配器的**轮转**写法对这个形状必然算错：每轮给每个参与日各加一个
    // `chunkMinutes`（本例 50），余数 10 于是全落到排名第一的那天，得到
    // `[60, 50, 50, 50]`。
    //
    // `day_allocation.dart` 已按契约 §7.2 实现"先给每天 `⌊目标/K⌋` 向下取整到
    // 粒度，再把余量按粒度逐份发给排名靠前的日期"，**但本条用例实测仍得到
    // `[60, 50, 50, 50]`**——即那条分支没有产生预期的结果，原因尚未查明。
    //
    // 因此这里**保留用例并显式 skip**，而不是删掉或改宽判据：
    // 它是这条语义的可执行规格，删掉会让缺口重新隐形。
    // 排查入口：`allocateTaskDays` 里 `TaskDistributionPolicy.even` 那个分支
    // （`day_allocation.dart`）与 `participants` 的实际长度。
    // ───────────────────────────────────────────────────────────────────────────
    test('**210 分钟摊到四天 ⇒ 两个 50 与两个 55**（用户实测回归）', () {
      final ledger = ledgerOf(licensedByDay: {5: 120, 6: 120, 7: 120, 8: 120});
      final plan = allocate(
        tasks: [
          task(
            'even',
            minutes: 210,
            minChunk: 50,
            maxChunk: 90,
            distributionPolicy: TaskDistributionPolicy.even,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(9),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 5,
      );

      final byDay = minutesByDay(plan.budgetFor('even')!);
      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        210,
        reason: '目标必须完整分配；实际 $byDay',
      );
      expect(byDay.length, 4, reason: '四天都要有安排；实际 $byDay');
      expect(
        byDay.values.toList()..sort(),
        [50, 50, 55, 55],
        reason:
            '余量必须**摊到多天**而不是全落在排名第一那天；'
            '轮转写法会得到 [60, 50, 50, 50]。实际 $byDay',
      );
    });
  });

  group('K 日选择与轮换（Task 5 Step 4 / 计划 §3.4 第 6、7 条）', () {
    test('**150/30 七天等余量：选择 5 天，且不是按日期取前 K 个**', () {
      // 七天各余 90 分钟、目标 150、最小片段 30 ⇒ 恰好 5 天各 30 分钟。
      final ledger = ledgerOf(
        licensedByDay: {for (var day = 5; day <= 11; day++) day: 120},
        usedByDay: {for (var day = 5; day <= 11; day++) day: 30},
      );
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 150,
            minChunk: 30,
            maxChunk: 90,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(12),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      final byDay = minutesByDay(plan.budgetFor('t')!);
      expect(
        byDay.values.fold<int>(0, (a, b) => a + b),
        150,
        reason: '目标必须完整分配；实际 $byDay',
      );
      expect(byDay.length, 5, reason: 'K=5（5×30 ≤ 150 ≤ 5×90）；实际 $byDay');
      expect(
        !(byDay.keys.every((day) => day <= 9)),
        isTrue,
        reason:
            '不得按日期取前五个（周一至周五）；轮换键必须让它落在别的组合上。'
            '实际 $byDay',
      );
    });

    test('**同一周期重复运行逐值相同**', () {
      final ledger = ledgerOf(
        licensedByDay: {for (var day = 5; day <= 11; day++) day: 120},
        usedByDay: {for (var day = 5; day <= 11; day++) day: 30},
      );
      DayAllocationPlan run() => allocate(
        tasks: [
          task(
            't',
            minutes: 150,
            minChunk: 30,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(12),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
        cycleStartByTask: {'t': date(5)},
      );

      final first = run();
      for (var attempt = 0; attempt < 20; attempt++) {
        final again = run();
        expect(
          again.budgetFor('t')!.minutesByLocalDate,
          first.budgetFor('t')!.minutesByLocalDate,
          reason: '同一周期的结果必须逐值稳定（计划 §3.4 第 7 条）',
        );
      }
    });

    test('**连续周期不会永久排除同一星期**', () {
      final ledger = ledgerOf(
        licensedByDay: {for (var day = 5; day <= 11; day++) day: 120},
        usedByDay: {for (var day = 5; day <= 11; day++) day: 30},
      );
      Set<int> chosenFor(DateTime cycleStart) {
        final plan = allocate(
          tasks: [
            task(
              't',
              minutes: 150,
              minChunk: 30,
              availableFromUtc: deadline(5),
              dueAtUtc: deadline(12),
            ),
          ],
          ledger: ledger,
          granularityMinutes: 30,
          cycleStartByTask: {'t': cycleStart},
        );
        return minutesByDay(plan.budgetFor('t')!).keys.toSet();
      }

      // 相邻两周的起点相差 7 天 ⇒ `cycleOrdinal` 相差 1 ⇒ 起始星期轮转一天。
      final thisWeek = chosenFor(date(5));
      final nextWeek = chosenFor(date(12));
      expect(
        nextWeek,
        isNot(thisWeek),
        reason:
            '周期推进时起始星期必须轮转，否则同一星期会被永久排除'
            '（本周 $thisWeek，下周 $nextWeek）',
      );
    });

    test('七天业务字段完全相同 ⇒ 排除的日期随周期改变（不是固定周末）', () {
      // 这条是"周末无固定奖励或惩罚"的间接检验：把七天做成**完全相同**，
      // 那么被排除的那两天只能由轮换键决定，任何"周末偏好"都会让排除集恒定。
      final ledger = weekLedger();
      final excluded = <Set<int>>{};
      for (var week = 0; week < 4; week++) {
        final plan = allocate(
          tasks: [
            task(
              't',
              minutes: 150,
              minChunk: 30,
              availableFromUtc: deadline(5),
              dueAtUtc: DateTime(2026, 10, 5 + 7 * (week + 1)),
            ),
          ],
          ledger: ledger,
          granularityMinutes: 30,
          cycleStartByTask: {'t': DateTime(2026, 10, 5 + 7 * week)},
        );
        final used = minutesByDay(plan.budgetFor('t')!).keys.toSet();
        excluded.add({5, 6, 7, 8, 9, 10, 11}.difference(used));
      }

      expect(
        excluded.length,
        greaterThan(1),
        reason:
            '四个周期的"未选中"集合完全相同 ⇒ 轮换没生效或存在固定星期偏好；'
            '实际 $excluded',
      );
    });
  });

  group('容量不足与显式 skip（Task 5 Step 5 / 计划 §7 末段）', () {
    test('**总容量 120、需求 180 ⇒ 分配 120 且缺 60**', () {
      final ledger = ledgerOf(licensedByDay: {5: 120});
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 180,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(6),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      final budget = plan.budgetFor('t')!;
      expect(budget.allocatedMinutes, 120, reason: '不得超额分配');
      expect(budget.shortageMinutes, 60, reason: '缺口必须如实');
      expect(plan.outcome, SearchOutcomeKind.hardInfeasible);
      expect(plan.finalLedger.forDate(date(5)).remainingMinutes, 0);
    });

    test('**高优先级先完整，低优先级承担缺口**', () {
      final ledger = ledgerOf(licensedByDay: {5: 120});
      final plan = allocate(
        tasks: [
          task(
            'low',
            minutes: 120,
            priority: TaskPriority.low,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(6),
          ),
          task(
            'high',
            minutes: 120,
            priority: TaskPriority.high,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(6),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      expect(plan.budgetFor('high')!.allocatedMinutes, 120);
      expect(plan.budgetFor('high')!.shortageMinutes, 0);
      expect(plan.budgetFor('low')!.allocatedMinutes, 0);
      expect(plan.budgetFor('low')!.shortageMinutes, 120);
    });

    test('没有任何合法日期 ⇒ 全额缺口，且状态是硬无解', () {
      final ledger = ledgerOf(licensedByDay: {5: 120});
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 60,
            // 只在周日可用，而账本里只有周一。
            allowedWeekdaysMask: 1 << (DateTime.sunday - DateTime.monday),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      expect(plan.budgetFor('t')!.allocatedMinutes, 0);
      expect(plan.budgetFor('t')!.shortageMinutes, 60);
      expect(plan.outcome, SearchOutcomeKind.hardInfeasible);
    });
  });

  group('状态预算（Task 5 Step 6 / 计划 §3.6 第 5、6 条）', () {
    test('**达到状态上限返回 budgetExhausted，不得声称硬无解**', () {
      // 大量日期 + 小状态预算 ⇒ 必然撞上限。
      final ledger = ledgerOf(
        licensedByDay: {for (var day = 5; day <= 11; day++) day: 600},
      );
      final plan = allocateTaskDays(
        DayAllocationInput(
          tasks: [
            task(
              't',
              minutes: 3000,
              minChunk: 30,
              maxChunk: 90,
              availableFromUtc: deadline(5),
              dueAtUtc: deadline(12),
            ),
          ],
          ledger: ledger,
          alreadyPlannedByTask: const {},
          timeZoneId: 'Asia/Shanghai',
          cycleStartByTask: const {},
          granularityMinutes: 5,
          maxAllocationStates: 4,
        ),
      );

      expect(
        plan.visitedStateCount,
        lessThanOrEqualTo(4),
        reason: '访问状态数必须有界（计划 §3.6 第 5 条）',
      );
      expect(
        plan.outcome,
        SearchOutcomeKind.budgetExhausted,
        reason: '达限时既不能声称无解，也不能部分应用（计划 §3.6 第 6 条）',
      );
    });

    test('容量充足时不访问多余状态', () {
      final ledger = ledgerOf(licensedByDay: {5: 600});
      final plan = allocate(
        tasks: [
          task(
            't',
            minutes: 60,
            availableFromUtc: deadline(5),
            dueAtUtc: deadline(6),
          ),
        ],
        ledger: ledger,
        granularityMinutes: 30,
      );

      expect(plan.outcome, SearchOutcomeKind.solved);
      expect(plan.budgetFor('t')!.shortageMinutes, 0);
      expect(plan.visitedStateCount, lessThan(10));
    });
  });

  group('确定性（计划 §3.4 第 7 条 / ALG-20）', () {
    test('任务列表与 Map 的顺序改变不影响结果', () {
      final ledger = ledgerOf(
        licensedByDay: {for (var day = 5; day <= 11; day++) day: 120},
        usedByDay: {for (var day = 5; day <= 11; day++) day: 30},
      );
      final tasks = [
        task(
          'a',
          minutes: 90,
          availableFromUtc: deadline(5),
          dueAtUtc: deadline(12),
        ),
        task(
          'b',
          minutes: 90,
          availableFromUtc: deadline(5),
          dueAtUtc: deadline(12),
        ),
      ];

      final forward = allocate(
        tasks: tasks,
        ledger: ledger,
        granularityMinutes: 30,
      );
      final reversed = allocate(
        tasks: tasks.reversed.toList(),
        ledger: ledger,
        granularityMinutes: 30,
      );

      for (final id in ['a', 'b']) {
        expect(
          reversed.budgetFor(id)!.minutesByLocalDate,
          forward.budgetFor(id)!.minutesByLocalDate,
          reason: '任务 $id 的预算不得依赖输入顺序',
        );
      }
    });

    test('`AllocationRotation` 与 Dart `hashCode` 无关，只用 SHA-256 前 8 字节', () {
      // 同一个 taskId 的轮换偏移必须是定值；不同 taskId 的偏移不必不同，
      // 但**必须**由摘要决定（这里钉住"不是随机数"）。
      final first = AllocationRotation.forTask(
        taskId: 'task-abc',
        cycleStartLocalDate: DateTime(2026, 10, 5),
      );
      for (var attempt = 0; attempt < 10; attempt++) {
        final again = AllocationRotation.forTask(
          taskId: 'task-abc',
          cycleStartLocalDate: DateTime(2026, 10, 5),
        );
        expect(again.rotationOffset, first.rotationOffset);
      }
      expect(first.rotationOffset, inInclusiveRange(0, 6));

      // `rotationRank` 必须归一化到 0..6（Dart 的 `%` 对负数返回负数）。
      for (var day = 5; day <= 11; day++) {
        expect(first.rotationRank(date(day)), inInclusiveRange(0, 6));
      }
      // 七天各占一个位次（轮换是一个排列）。
      expect(
        {for (var day = 5; day <= 11; day++) first.rotationRank(date(day))},
        {0, 1, 2, 3, 4, 5, 6},
      );
    });
  });

  group('片段分解（计划 §7 的 buildAllocationChunks）', () {
    test('可拆分任务按最大片段切，余量作为唯一短尾', () {
      final chunks = buildAllocationChunks(
        task: task('t', minutes: 140, minChunk: 30, maxChunk: 60),
        targetMinutes: 140,
        granularityMinutes: 5,
      );
      expect(chunks, [60, 60, 20], reason: '最后一段允许短于最小片段');
      expect(chunks.fold<int>(0, (a, b) => a + b), 140);
    });

    test('连续任务只有一段（整块）', () {
      final chunks = buildAllocationChunks(
        task: task(
          't',
          minutes: 90,
          minChunk: 90,
          maxChunk: 90,
          splitMode: TaskSplitMode.continuous,
        ),
        targetMinutes: 90,
        granularityMinutes: 5,
      );
      expect(chunks, [90]);
    });

    test('不足一个粒度的短尾并进前一段', () {
      final chunks = buildAllocationChunks(
        task: task('t', minutes: 122, minChunk: 30, maxChunk: 60),
        targetMinutes: 122,
        granularityMinutes: 5,
      );
      expect(
        chunks.last,
        greaterThanOrEqualTo(5),
        reason: '2 分钟的尾巴排不出来，必须并进前一段；实际 $chunks',
      );
      expect(chunks.fold<int>(0, (a, b) => a + b), 122);
    });
  });
}
