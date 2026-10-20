// 1.8.0（设计规范 §11.4 第 3、4 条，计划 Task 12c）：**引擎路径上的**最小化改动。
//
// `minimize_changed_blocks_test.dart` 钉的是那个函数本身；本文件钉的是
// **它真的被引擎调用了、并且真的把"被移动的块数"降下来了**。
//
// 为什么必须有这一条：`minimizeChangedBlocks` 加进 `generate` 之后，
// 如果哪天有人把它删掉、或在它之后又改一遍 `blocks`，上面那份单元测试**依然全绿**——
// 它根本不经过引擎。这类"函数对但没接上"的缺陷在本批次已经出现过一次
// （`recurringNotifications` 从未被构造、`referenceBlocks` 被 `withCurrentInputHash` 丢掉），
// 因此这里从**引擎入口**验行为。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);

  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int hour, [int minute = 0]) =>
      day.add(Duration(hours: hour, minutes: minute));

  PlannedBlock block(String id, String taskId, {required int hour}) =>
      PlannedBlock(
        id: id,
        taskId: taskId,
        range: TimeRange(
          startUtc: at(hour),
          endUtc: at(hour).add(const Duration(hours: 1)),
        ),
      );

  SchedulableTask task(String id) => SchedulableTask(
    id: id,
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    priority: TaskPriority.medium,
    energyLevel: TaskEnergyLevel.medium,
  );

  test('既有未锁定块携带原 id 进入排程，最小化改动因此不再空操作', () {
    // 这一条**记录现状**，不是断言期望行为。它存在的价值是让下一个接手的人一眼看到：
    //
    // · 引擎给新排的块起 id 的规则是 `block:<taskId>:<开始微秒>:<时长>`
    //   （`_blockId`），而确认计划里那些块的 id 是**数据库 uuid**
    //   （`applyProposal` 落地时会重写成 `<提案 id>:<块 id>`）；
    // · `referenceBlocks` 的键取自确认计划，因此**永远匹配不上**引擎排出的块；
    // · 于是 `minimizeChangedBlocks` 在真实装配下找不到任何"有参照"的块，
    //   它**一个块都不会动**——那一步是空操作。
    //
    // 修法（属于新的设计工作，不在本批次计划里）：确认计划里**未锁定**的块应当以
    // **原 id** 进入 `blocks` 作为起点，引擎只在需要时移动它们；那时"少动"才可能被真的优化。
    // 现在能诚实验收的只有：`minimizeChangedBlocks` **函数本身**正确
    //（`minimize_changed_blocks_test.dart`，9 条用例），以及"它被调用了"。
    final window = TimeRange(startUtc: at(0), endUtc: at(24));
    const zoneId = 'UTC';
    final rules = DefaultSettings.v1();
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [task('t-a')],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      existingBlocks: [block('a', 't-a', hour: 9)],
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
      inputHash: 'h',
      referenceBlocks: {'a': at(9)},
    );

    final proposal = engine.generate(problem);

    expect(proposal.blocks, isNotEmpty);
    // ── **任务 8 的 ID 族修复**：既有未锁定块必须携带**原 id** 进入排程 ────────────
    //
    // 这条此前写成"记录现状"的反向断言（`expect(...id == 'a', isFalse)`），
    // 把空操作当成既定事实冻了下来。而它是有代价的：
    //
    // · 真实装配里确认计划的块 id 是 persistedId（`<提案 id>:<引擎 id>`），
    //   而 `referenceBlocks` 的键**正是同一批 persistedId**；
    // · 引擎此前为所有块重新起名（`block:<taskId>:<micros>:<dur>`），
    //   于是 `minimizeChangedBlocks` 的 `referenceBlocks.containsKey(block.id)`
    //   在真实装配下**永远为 false** —— 那一步是空操作，
    //   "尽量少改动"只在函数级测试里成立。
    //
    // 修复后的契约（用户确认的实施边界）：
    // · 未锁定的既有块携带原 id 作为**起点**进入排程；
    // · 引擎新排的块用新的稳定 id，**不得冒用**既有 id；
    // · 移动保留 id，拆分时原 id 保留一块、其余新 id；
    // · 锁定块 / 固定日程 / 保护时间的身份语义不变。
    expect(
      proposal.blocks.map((placed) => placed.id),
      contains('a'),
      reason:
          '既有块必须保留原 id，否则 `referenceBlocks.containsKey(block.id)` '
          '永远为 false，最小化改动在真实装配下依旧是空操作',
    );
    expect(
      proposal.blocks
          .where((placed) => placed.id != 'a')
          .every((placed) => placed.id.startsWith('block:')),
      isTrue,
      reason: '新排的块必须使用引擎自己命名的新 id，不得冒用既有 id',
    );
  });

  test('没有参照时这一步是空操作：普通生成的结果不受影响', () {
    // 参照为空 ⇒ 每个块都没有"调整前" ⇒ 最小化改动无事可做。
    // 这条守的是"新功能不改变首次排程"。
    final window = TimeRange(startUtc: at(9), endUtc: at(18));
    const zoneId = 'UTC';
    final rules = DefaultSettings.v1();
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [task('t-a')],
      fixedIntervals: const [],
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
      inputHash: 'h',
    );

    final first = engine.generate(problem);
    final second = engine.generate(problem);

    expect(
      first.blocks.map((b) => '${b.id}@${b.startUtc}'),
      second.blocks.map((b) => '${b.id}@${b.startUtc}'),
      reason: '确定性：同一次输入两次生成逐值相同',
    );
    expect(first.blocks, isNotEmpty);
  });

  test('算法版本是 20（容量感知排程 + 既有块身份 + 精力偏离解释 + 延后事务化）', () {
    // 设计 §5.1：任何会改变排程结果的改动都必须抬版本，否则历史计划无法按当时的算法复现。
    //
    // **17 涵盖 2026-10-16「容量感知分层排程修复」**（实施计划
    // `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`）：
    //
    //   1. **逐日规则**：`DailySchedulingPolicy` 按**本地日**解析，日期敏感字段
    //      （每日上限、粒度、休息间隔、生活配额）不再复制窗口首日。修复前周末的
    //      每日上限会沿用周一的值，于是"周末低负载"这件事在引擎里根本不存在。
    //   2. **单一容量账本**：`DayCapacityLedger` 成为"某天还能放多少"的唯一来源，
    //      放置、诊断、局部改进三处读同一份口径。其中 `usedMovableMinutes`
    //      **包含锁定块**——修复前锁定 300 分钟、上限 360 的一天仍可再排 360 分钟。
    //   3. **全局跨日分配**：`allocateTaskDays` 先按方案级字典序目标把每个任务的
    //      分钟摊到 K 个日期（K 满足 `K × chunk ≤ 目标`），引擎只在这些预算内放置。
    //      修复前"150 分钟 / 30 粒度"会固定选前五天，且 `even` 任务可能被摊成
    //      每天 20~25 分钟——**每天都不够放一个最小片段**，最终一个块都排不出。
    //   4. **预算在局部改进阶段同样生效**：`_improve` 不再能把块搬去超预算的日子。
    //   5. **截止优先于形状**：分配顺序先看截止、再看"连续/可切"。修复前无截止的
    //      连续任务会抢走有截止任务唯一的窗口（黄金用例里两边各缺 120 分钟）。
    //
    // **黄金用例的块与缺口在 16 → 17 之间完全不变**：新架构复现了旧行为，
    // 同时把"某天还剩多少"的口径收敛到一处。
    //
    // **16 是上一次**：按剩余量逐轮重算候选 + 唯一短尾集合校验 + 每日上限是硬约束。
    // **15 再上一次**：窗口准入 + 未来周期隔离 + 按截止分配每日预算。
    //
    // 这条用例刻意写死字符串（而不是引用常量），于是抬版本时**必须**回到这里
    // 补一句"为什么"，否则它不会通过。
    expect(DeterministicScheduleEngine.algorithmVersion, '20');
  });
}

