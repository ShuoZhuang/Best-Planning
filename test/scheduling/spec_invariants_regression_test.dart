// 1.8.0（设计规范 §3「全局不变量」，计划 Task 15）：**跨模块的回归**。
//
// §1 的表格按任务列证据，每条只钉自己那一处；本文件钉的是**不变量**——它们跨任务。
// 某一条被后来的改动破坏时，单个任务的用例可能全绿，这正是"全链路回归"与
// "各任务测试都过了"的区别。
//
// **只写会真的失败的断言。** 第一版这里放了三条"占位确认"（`expect(true, isTrue)`、
// 引用一个不存在的符号），它们永远不会红，只会让表格看起来更满——
// 那与本文件存在的理由正好相反，已全部删掉。
//
// 第 10 条（单实现代理、串行、不同时编辑 `router.dart`/排程核心/schema/组合根）
// 是**过程约束**，由提交记录体现（每任务一个提交、无并行代理），不写成测试。
// 第 1、4、5、8、9 条各自有专门文件逐值覆盖，见 §1 表格；本文件不重复它们。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/scheduling_weights.dart';

void main() {
  final zones = TimeZoneDatabase();
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int hour) => day.add(Duration(hours: hour));

  SchedulableTask task(String id) => SchedulableTask(
    id: id,
    requiredMinutes: 120,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    priority: TaskPriority.urgent,
    energyLevel: TaskEnergyLevel.high,
  );

  ScheduleProblem problem({
    required List<BusyInterval> fixed,
    required List<BusyInterval> protected,
    List<PlannedBlock> locked = const [],
  }) => ScheduleProblem(
    planningWindow: TimeRange(startUtc: at(0), endUtc: at(24)),
    timeZoneId: 'UTC',
    tasks: [task('t1')],
    fixedIntervals: fixed,
    protectedIntervals: protected,
    lockedBlocks: locked,
    rules: DefaultSettings.v1(),
    preferences: const PreferenceProfile(),
    inputHash: 'h',
  );

  group('不变量 2：固定日程、保护时间、锁定块不可被自动移动或覆盖', () {
    test('任务块不与固定日程重叠', () {
      final fixed = TimeRange(startUtc: at(9), endUtc: at(12));
      final proposal = DeterministicScheduleEngine(zones).generate(
        problem(
          fixed: [BusyInterval(id: 'class', range: fixed)],
          protected: const [],
        ),
      );

      expect(proposal.blocks, isNotEmpty, reason: '前置条件：这一天排得下东西');
      for (final block in proposal.blocks) {
        expect(
          block.range.overlaps(fixed),
          isFalse,
          reason: '固定日程是硬约束；把块排进它就是不可接受的',
        );
      }
    });

    test('整段窗口都被保护时间覆盖时**一个块都不排**（不变量 2）', () {
      // **这条用例的形状是刻意选的**：窗口与保护时间**逐值重合**。
      // 于是"排不出块"只有一个原因——保护时间被当成硬禁区；
      // 如果引擎忽略它，就一定会排出块来，用例立刻红。
      //
      // 第一版写的是"窗口 00:00–24:00、保护 09:00–12:00，断言块不与保护时间重叠"，
      // 那条**是空断言**：任务有 15 个小时可以放，引擎完全可以出于别的原因避开 9–12 点。
      // 它无法区分"尊重保护时间"与"碰巧没排到那里"。
      final wholeWindow = TimeRange(startUtc: at(9), endUtc: at(11));
      final engine = DeterministicScheduleEngine(zones);
      final proposal = engine.generate(
        ScheduleProblem(
          planningWindow: wholeWindow,
          timeZoneId: 'UTC',
          tasks: [task('t1')],
          fixedIntervals: const [],
          protectedIntervals: [
            BusyInterval(id: 'protected', range: wholeWindow),
          ],
          lockedBlocks: const [],
          rules: DefaultSettings.v1(),
          preferences: const PreferenceProfile(),
          inputHash: 'h',
        ),
      );

      expect(
        proposal.blocks,
        isEmpty,
        reason: '整段窗口都是禁区时排不出任何块；排出来了就说明保护时间没生效',
      );
      expect(proposal.unscheduled, isNotEmpty, reason: '排不下必须如实报告缺口，而不是静默少排');
    });

    test('窗口够大时保护时间**只是把那一段排除**，不是让整个任务消失', () {
      // 与上一条配对：证明"排不出"确实是因为禁区，而不是引擎根本不会排这个任务。
      final protectedRange = TimeRange(startUtc: at(9), endUtc: at(12));
      final proposal = DeterministicScheduleEngine(zones).generate(
        problem(
          fixed: const [],
          protected: [BusyInterval(id: 'lunch', range: protectedRange)],
        ),
      );

      expect(proposal.blocks, isNotEmpty);
      for (final block in proposal.blocks) {
        expect(block.range.overlaps(protectedRange), isFalse);
      }
    });

    test('锁定块原样出现在结果里，位置一字不改', () {
      final locked = PlannedBlock(
        id: 'locked-1',
        taskId: 't1',
        range: TimeRange(startUtc: at(14), endUtc: at(16)),
        locked: true,
      );
      final proposal = DeterministicScheduleEngine(zones).generate(
        problem(fixed: const [], protected: const [], locked: [locked]),
      );

      final placed = proposal.blocks.firstWhere((b) => b.id == 'locked-1');
      expect(placed.startUtc, at(14));
      expect(placed.endUtc, at(16));
    });

    test('三类硬约束同时存在时，一个都不被越过', () {
      final fixed = TimeRange(startUtc: at(8), endUtc: at(9));
      final protectedRange = TimeRange(startUtc: at(12), endUtc: at(13));
      final locked = PlannedBlock(
        id: 'locked-1',
        taskId: 't1',
        range: TimeRange(startUtc: at(15), endUtc: at(16)),
        locked: true,
      );

      final proposal = DeterministicScheduleEngine(zones).generate(
        problem(
          fixed: [BusyInterval(id: 'early', range: fixed)],
          protected: [BusyInterval(id: 'lunch', range: protectedRange)],
          locked: [locked],
        ),
      );

      for (final block in proposal.blocks) {
        if (block.id == 'locked-1') continue;
        expect(block.range.overlaps(fixed), isFalse, reason: '越过了固定日程');
        expect(
          block.range.overlaps(protectedRange),
          isFalse,
          reason: '越过了保护时间',
        );
        expect(block.range.overlaps(locked.range), isFalse, reason: '越过了锁定块');
      }
    });
  });

  group('不变量 6：休息不是"浪费"', () {
    test('坏空档惩罚项不是正值（正值会鼓励制造坏空档）', () {
      // 权重当前是 0（§1.12 记录了原因），但**符号**是一条不变量：
      // 收益方向写反过一次，`golden week` 当场把它抓出来。这里钉住符号。
      expect(
        SchedulingWeights.v1().maximumUnusableGapPenalty,
        lessThanOrEqualTo(0),
      );
      expect(
        const SchedulingWeights.testing(maximumUnusableGapPenalty: -600)
            .maximumUnusableGapPenalty,
        lessThan(0),
        reason: '测试用的那份权重必须真的能给负值，否则折算逻辑验不到',
      );
    });
  });

  group('不变量 3：任何调整先生成预览', () {
    test('引擎只产出提案，不落地——`generate` 是纯函数式的', () {
      // "先生成预览"的机制保证是：生成这一步**没有任何写入端口**。
      // 这里用"同一次输入两次生成逐值相同"来证明它没有依赖外部可变状态：
      // 若它偷偷写了库，第二次生成就会看到不同的输入。
      final input = problem(
        fixed: [
          BusyInterval(
            id: 'class',
            range: TimeRange(startUtc: at(9), endUtc: at(10)),
          ),
        ],
        protected: const [],
      );
      final engine = DeterministicScheduleEngine(zones);

      final first = engine.generate(input);
      final second = engine.generate(input);

      expect(
        first.blocks.map((b) => '${b.id}@${b.startUtc}'),
        second.blocks.map((b) => '${b.id}@${b.startUtc}'),
        reason: '生成必须无副作用且确定；否则"预览"就不代表将要落地的结果',
      );
    });
  });
}
