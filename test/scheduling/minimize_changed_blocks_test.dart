// 1.8.0（设计规范 §11.4 第 3、4 条，计划 Task 12c）：**按块数与位移最小化改动**。
//
// 规范把这两条排在硬约束之后的第一、二位：
// 3. 移动的其他块数量最少；
// 4. 所有被移动块的总位移分钟最少。
//
// `LocalRepairPlan.compare` 已经会**比较**两份候选；本文件钉的是"能产出一份更少改动的候选"：
// 引擎生成完之后，把**还能回到原位**的块放回原位。修复前完全没有这一步——
// 一次延后可以让引擎顺手把一整天重排一遍，而用户只要求"这一块往后挪 30 分钟"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();

void main() {
  final dayStart = DateTime.utc(2026, 10, 12, 0);
  final dayEnd = DateTime.utc(2026, 10, 12, 24);

  DateTime at(int hour, [int minute = 0]) =>
      dayStart.add(Duration(hours: hour, minutes: minute));

  PlannedBlock block(
    String id, {
    required int hour,
    int minute = 0,
    int minutes = 60,
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: 'task-$id',
    range: TimeRange(
      startUtc: at(hour, minute),
      endUtc: at(hour, minute).add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  SchedulableTask task(String id) => SchedulableTask(
    id: 'task-$id',
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    priority: TaskPriority.medium,
    energyLevel: TaskEnergyLevel.medium,
  );

  ScheduleProblem problem({
    required List<PlannedBlock> reference,
    List<BusyInterval> fixed = const [],
    List<BusyInterval> protected = const [],
    List<PlannedBlock> locked = const [],
    List<String> extraTaskIds = const [],
  }) {
    final window = TimeRange(startUtc: dayStart, endUtc: dayEnd);
    const zoneId = 'UTC';
    final rules = DefaultSettings.v1();
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [
        for (final block in reference) task(block.id),
        // **新排进来的块也要有任务**：`PlanValidator` 对"任务不存在"的块直接报
        // `invalidInput`，而那条检查在 overlap 检查**之前**——于是它根本不参与重叠判定。
        // 第一版忘了给 `newcomer` 建任务，那条"原位被占"的用例便静默失去了意义
        // （它仍然通过，但通过的原因是错的）。
        for (final id in extraTaskIds) task(id),
      ],
      fixedIntervals: fixed,
      protectedIntervals: protected,
      lockedBlocks: locked,
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
      inputHash: 'h',
      referenceBlocks: {
        for (final block in reference) block.id: block.startUtc,
      },
    );
  }

  test('还能回到原位的块被放回，改动块数从 2 降到 1', () {
    // 参照：a 在 09:00、b 在 11:00。引擎交出的结果把两块都挪了，
    // 但 a 原位其实空着——它不该被算作"被移动的块"。
    final reference = [block('a', hour: 9), block('b', hour: 11)];
    final proposed = [block('a', hour: 14), block('b', hour: 16)];

    final result = minimizeChangedBlocks(
      problem: problem(reference: reference),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(result.movedBlockIds, isEmpty);
    expect(result.blocks.firstWhere((b) => b.id == 'a').startUtc, at(9));
    expect(result.blocks.firstWhere((b) => b.id == 'b').startUtc, at(11));
  });

  test('原位被别的块占着时不动那一块，只放回能放的', () {
    // a 原位 09:00 空着 ⇒ 放回；b 原位 11:00 被 c 占着 ⇒ 保持引擎给的位置。
    final reference = [
      block('a', hour: 9),
      block('b', hour: 11),
      block('c', hour: 11),
    ];
    final proposed = [
      block('a', hour: 14),
      block('b', hour: 16),
      block('c', hour: 11),
    ];

    final result = minimizeChangedBlocks(
      problem: problem(reference: reference),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(
      result.blocks.firstWhere((b) => b.id == 'a').startUtc,
      at(9),
      reason: 'a 能回去就该回去——它原地空着',
    );
    expect(
      result.blocks.firstWhere((b) => b.id == 'b').startUtc,
      isNot(at(11)),
      reason: 'b 的原位被 c 占着；不能为了放回 b 而把 c 也挤走（那只会多动一块）',
    );
  });

  test('放回时**不越过固定日程与保护时间**：那些位置不是空的', () {
    final reference = [block('a', hour: 9)];
    final proposed = [block('a', hour: 14)];

    final result = minimizeChangedBlocks(
      problem: problem(
        reference: reference,
        fixed: [
          BusyInterval(
            id: 'class',
            range: TimeRange(startUtc: at(9), endUtc: at(10)),
          ),
        ],
      ),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(
      result.blocks.firstWhere((b) => b.id == 'a').startUtc,
      at(14),
      reason: '原位现在被固定日程占着，放回去就是制造 overlap 冲突',
    );
  });

  test('放回时**不越过保护时间**', () {
    final reference = [block('a', hour: 9)];
    final proposed = [block('a', hour: 14)];

    final result = minimizeChangedBlocks(
      problem: problem(
        reference: reference,
        protected: [
          BusyInterval(
            id: 'lunch',
            range: TimeRange(startUtc: at(9), endUtc: at(10)),
          ),
        ],
      ),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(result.blocks.firstWhere((b) => b.id == 'a').startUtc, at(14));
  });

  test('锁定块与没有参照的块**一律不动**', () {
    final locked = block('locked', hour: 20, locked: true);
    final reference = [block('a', hour: 9), locked];
    // `newcomer` 不在参照里：它是这次新排进来的，没有"调整前"，不该被动。
    final proposed = [
      block('a', hour: 14),
      locked,
      block('newcomer', hour: 21),
    ];

    final result = minimizeChangedBlocks(
      problem: problem(reference: reference, locked: [locked]),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(result.blocks.firstWhere((b) => b.id == 'locked').startUtc, at(20));
    expect(
      result.blocks.firstWhere((b) => b.id == 'newcomer').startUtc,
      at(21),
      reason: '新排进来的块没有"调整前"，最小化改动这件事与它无关',
    );
  });

  test('块集合与 id 在结果里保持不变（这个步骤不改数量）', () {
    final reference = [block('a', hour: 9), block('b', hour: 11)];
    final proposed = [block('a', hour: 14), block('b', hour: 16)];

    final result = minimizeChangedBlocks(
      problem: problem(reference: reference),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(
      result.blocks.map((b) => b.id).toSet(),
      proposed.map((b) => b.id).toSet(),
    );
    expect(result.blocks, hasLength(proposed.length));
  });

  test('结果确定：同一次输入连算两次逐值相同', () {
    final reference = [block('a', hour: 9), block('b', hour: 11)];
    final proposed = [block('a', hour: 14), block('b', hour: 16)];

    List<String> run() => [
      for (final block in minimizeChangedBlocks(
        problem: problem(reference: reference),
        blocks: proposed,
        dayStartUtc: dayStart,
        dayEndUtc: dayEnd,
      ).blocks)
        '${block.id}@${block.startUtc}',
    ];

    expect(run(), run());
  });

  test('已经全在原位时逐值不变', () {
    final reference = [block('a', hour: 9), block('b', hour: 11)];
    final proposed = [block('a', hour: 9), block('b', hour: 11)];

    final result = minimizeChangedBlocks(
      problem: problem(reference: reference),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(result.movedBlockIds, isEmpty);
    expect(
      result.blocks.map((b) => '${b.id}@${b.startUtc}'),
      proposed.map((b) => '${b.id}@${b.startUtc}'),
    );
  });

  test('放回后登记进 movedBlockIds 的只有**真的不在原位**的块', () {
    final reference = [block('a', hour: 9), block('b', hour: 11)];
    // a 能回原位，b 的原位被 newcomer 占着 ⇒ 只有 b 算"被移动"。
    final proposed = [
      block('a', hour: 14),
      block('b', hour: 16),
      block('newcomer', hour: 11),
    ];

    final result = minimizeChangedBlocks(
      problem: problem(reference: reference, extraTaskIds: const ['newcomer']),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(result.movedBlockIds, {'b'});
  });

  test('**参照匹配不上任何块时，函数逐值返回输入**（生产路径上的实际情况）', () {
    // 生产装配里 `referenceBlocks` 的键是**确认计划的 uuid**，而引擎排出的块 id 是
    // `block:<taskId>:<开始微秒>:<时长>`——两者永远匹配不上。于是这个函数在真实路径上走的
    // 就是这一条：**什么都不做**。
    //
    // 把这一条写下来，是为了让"它被调用了"与"它起作用了"这两件事**不能互相冒充**。
    // 见 `engine_minimizes_changes_test.dart` 的「已知缺口」用例与验收文档 §1.11d。
    final proposed = [block('block:t-a:123:60', hour: 14)];

    final result = minimizeChangedBlocks(
      problem: problem(reference: [block('uuid-from-database', hour: 9)]),
      blocks: proposed,
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(
      result.blocks.map((b) => '${b.id}@${b.startUtc}'),
      proposed.map((b) => '${b.id}@${b.startUtc}'),
      reason: '没有一块有参照 ⇒ 逐值返回输入，不移动、不增删',
    );
    expect(result.movedBlockIds, isEmpty);
  });
}
