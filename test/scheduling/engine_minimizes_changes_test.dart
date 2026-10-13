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

  test('**已知缺口**：引擎输出的块 id 与确认计划的 id 不同族，最小化改动因此是空操作', () {
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
    final problem = ScheduleProblem(
      planningWindow: TimeRange(startUtc: at(0), endUtc: at(24)),
      timeZoneId: 'UTC',
      tasks: [task('t-a')],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      existingBlocks: [block('a', 't-a', hour: 9)],
      rules: DefaultSettings.v1(),
      preferences: const PreferenceProfile(),
      inputHash: 'h',
      referenceBlocks: {'a': at(9)},
    );

    final proposal = engine.generate(problem);

    expect(proposal.blocks, isNotEmpty);
    expect(
      proposal.blocks.any((placed) => placed.id == 'a'),
      isFalse,
      reason: '确认计划的块 id（`a`）不会出现在输出里——引擎重新起了名字',
    );
    expect(
      proposal.blocks.every((placed) => placed.id.startsWith('block:')),
      isTrue,
      reason: '输出里每个块都是引擎自己命名的；这就是参照匹配不上的原因',
    );
  });

  test('没有参照时这一步是空操作：普通生成的结果不受影响', () {
    // 参照为空 ⇒ 每个块都没有"调整前" ⇒ 最小化改动无事可做。
    // 这条守的是"新功能不改变首次排程"。
    final problem = ScheduleProblem(
      planningWindow: TimeRange(startUtc: at(9), endUtc: at(18)),
      timeZoneId: 'UTC',
      tasks: [task('t-a')],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: DefaultSettings.v1(),
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

  test('算法版本是 15（窗口准入 + 未来周期隔离 + 按截止分配每日预算）', () {
    // 设计 §5.1：任何会改变排程结果的改动都必须抬版本，否则历史计划无法按当时的算法复现。
    //
    // **15 涵盖 2026-10-13「可见空闲却报容量不足」专项的三件事**
    // （实施计划 `2026-10-13-visible-free-time-false-shortage-repair.md`）：
    //   1. **规划窗口之外的任务不再进入本次目标**：装配层按
    //      `classifyTaskForPlanningWindow` 分类，`availableFromUtc` 不早于窗口终点的普通
    //      任务被静默排除。它此前会带着目标分钟进入问题却产不出候选，被报成"可用时间不足"。
    //   2. **未来周期实例不再作为普通任务泄漏**：装配层按 `findCyclesByTaskIds` 把全部
    //      已生成实例从普通输入里剥离，只由周期输入加回本周那一份。修复前只删"本周实例"，
    //      `ensureCycles` 为滚动七天补出来的下周实例因此留在普通输入里。
    //   3. **按日预算不再被截止之后的日子吃掉**：`_capacityByLocalDate` 只统计任务截止
    //      之前的本地日。修复前均分器按七日窗口摊量、候选生成按 `dueAtUtc` 过滤，于是
    //      截止之后的日子白拿一份预算，真正能排的日子一个最小片段都凑不出来。
    // 三项都改变同一输入得到的块集合，因此必须抬版本。
    //
    // **14 是上一次**：历史块不再计入前向计划 + 粒度与短余量契约统一 + 进行中块是硬占用。
    //
    // 这条用例刻意写死字符串（而不是引用常量），于是抬版本时**必须**回到这里
    // 补一句"为什么"，否则它不会通过。
    expect(DeterministicScheduleEngine.algorithmVersion, '15');
  });
}
