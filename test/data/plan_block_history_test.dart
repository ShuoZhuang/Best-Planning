// 1.8.0（2026-10-12 故障；冻结决策 §1.3）：**历史块不再进入前向提案，但历史读取必须仍在**。
//
// 这两件事必须**同时**成立，否则修复会走向另一个极端：
//   · 若为了防止"昨天出现在新增里"而把过去块删掉，用户重排一次就看不到昨天做了什么；
//   · 若为了保住历史而把过去块塞回提案，就回到 R1/R2（提案携带规划窗口之前的块）。
//
// 正确的分工：**过去日期的展示由 `PlanBlockHistory.blocksInWindow()` 从旧版本读出**，
// 而新提案只含进行中与未来的块。
//
// 本文件用**真实 Drift 仓储**（内存数据库）证明这条分工：
// 应用一个不含 past 块的新提案之后，旧版本的 past 块仍能查询到**一次且不重复**。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();

  DateTime localUtc(int month, int day, int hour, [int minute = 0]) =>
      zones.localDateTimeToUtc(
        DateTime.utc(2026, month, day),
        hour * 60 + minute,
        zoneId,
      );

  PlannedBlock block(
    String id, {
    required DateTime start,
    required int minutes,
    String taskId = 't-a',
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  ScheduleProposal proposalOf({
    required String id,
    required List<PlannedBlock> blocks,
  }) => ScheduleProposal(
    proposalId: id,
    inputHash: 'hash-$id',
    algorithmVersion: '14',
    planningWindow: TimeRange(
      startUtc: localUtc(10, 12, 9, 30),
      endUtc: localUtc(10, 19, 0),
    ),
    blocks: blocks,
    unscheduled: const [],
    conflicts: const [],
    explanations: const [],
    metrics: ProposalMetrics(
      isFullyFeasible: true,
      scheduledMinutes: blocks.fold(0, (sum, b) => sum + b.durationMinutes),
      unscheduledMinutes: 0,
    ),
  );

  Future<({DriftPlanRepository plans, AppDatabase database, String taskId})>
  harness() async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final plans = DriftPlanRepository(
      database,
      clock: _FixedClock(DateTime.utc(2026, 10, 12, 1, 30)),
    );
    // **必须先种一件真实任务**：`schedule_blocks.task_id` 有外键约束，
    // 随便编一个 't-a' 会在写库时报 FOREIGN KEY constraint failed。
    // 这条约束是产品语义的一部分（计划块必须属于存在的任务），因此不绕过它。
    final task = PlannerTask(
      id: 't-a',
      title: '蓝桥杯竞赛课',
      priority: TaskPriority.medium,
      estimatedMinutes: 120,
      remainingMinutes: 120,
      energyLevel: TaskEnergyLevel.medium,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      status: TaskStatus.open,
      createdAtUtc: DateTime.utc(2026, 10, 12, 1, 30),
      updatedAtUtc: DateTime.utc(2026, 10, 12, 1, 30),
    );
    await DriftTaskRepository(database.taskDao).save(task);
    return (plans: plans, database: database, taskId: task.id);
  }

  test('应用不含 past 块的新提案之后，旧版本的 past 块仍能被历史 API 读到一次', () async {
    final h = await harness();
    addTearDown(h.database.close);

    // ① 第一版：含 10-11 的历史块与 10-12 的将来块。
    final first = proposalOf(
      id: 'v1',
      blocks: [
        block('past-1011', start: localUtc(10, 11, 15), minutes: 60),
        block('future-1012', start: localUtc(10, 12, 14), minutes: 60),
      ],
    );
    expect(
      (await h.plans.applyProposal(first, first.inputHash)).status,
      ApplyPlanStatus.applied,
    );

    // ② 第二版：**不含** past 块（这正是修复后的装配层会产出的形状）。
    final second = proposalOf(
      id: 'v2',
      blocks: [block('future-1012b', start: localUtc(10, 12, 16), minutes: 60)],
    );
    expect(
      (await h.plans.applyProposal(second, second.inputHash)).status,
      ApplyPlanStatus.applied,
    );

    // ③ 当前计划里没有 past 块（前向输入干净）。
    final current = await h.plans.current();
    expect(current, isNotNull);
    expect(
      current!.blocks.map((b) => b.range.startUtc),
      isNot(contains(localUtc(10, 11, 15))),
      reason: '前向提案不得携带规划窗口之前的块——那是 R1/R2 的成因',
    );

    // ④ 但**历史 API 仍然读得到**它，而且只出现一次。
    final history = await h.plans.blocksInWindow(
      localUtc(10, 11, 0),
      localUtc(10, 12, 0),
    );
    final pastRows = history
        .where((row) => row.block.range.startUtc == localUtc(10, 11, 15))
        .toList();
    expect(
      pastRows,
      hasLength(1),
      reason:
          '**已经发生的事不该被后来的计划改写**（用户 2026-10-07 的原话）。'
          '出现 0 次说明历史链断了；出现两次说明把各版本求了并集（那正是历史端口'
          '带 `versionId`／`versionCreatedAtUtc` 要避免的"已完成待办重复"）。',
    );
    expect(pastRows.single.versionId, 'v1');
    expect(
      pastRows.single.versionCreatedAtUtc.isUtc,
      isTrue,
      reason: '版本时刻必须是 UTC：调用方要按它挑"当时在用的那一版"',
    );
  });

  test('再次生成（第三版）之后，历史仍然只有一份过去块', () async {
    final h = await harness();
    addTearDown(h.database.close);

    for (final version in [
      proposalOf(
        id: 'v1',
        blocks: [block('past-1011', start: localUtc(10, 11, 15), minutes: 60)],
      ),
      proposalOf(
        id: 'v2',
        blocks: [block('future-a', start: localUtc(10, 12, 14), minutes: 60)],
      ),
      proposalOf(
        id: 'v3',
        blocks: [block('future-b', start: localUtc(10, 12, 16), minutes: 60)],
      ),
    ]) {
      await h.plans.applyProposal(version, version.inputHash);
    }

    final history = await h.plans.blocksInWindow(
      localUtc(10, 11, 0),
      localUtc(10, 12, 0),
    );
    expect(
      history.where((row) => row.block.id.startsWith('v1:')).length,
      1,
      reason: '重排两次之后，那次历史安排仍然只出现一次',
    );
    // 当前计划里一个字都没有它。
    final current = await h.plans.current();
    expect(current!.blocks.where((b) => b.taskId == 't-a'), hasLength(1));
  });

  test('进行中的块既在前向计划里，也能被历史 API 还原（展示端去重）', () async {
    final h = await harness();
    addTearDown(h.database.close);

    final ongoing = block(
      'ongoing',
      start: localUtc(10, 12, 9, 15),
      minutes: 30,
    );
    final first = proposalOf(id: 'v1', blocks: [ongoing]);
    await h.plans.applyProposal(first, first.inputHash);

    // 前向计划里它在（原位保留）。
    final current = await h.plans.current();
    expect(
      current!.blocks.single.range.startUtc,
      localUtc(10, 12, 9, 15),
      reason: '进行中的块原位且不可移动（冻结决策 §1.3 的中间一行）',
    );

    // 历史 API 也能还原它 ⇒ **两边都能看到**，因此展示端必须去重
    // （它是由"进行中的块与历史窗口相交"决定的，不是缺陷）。
    final history = await h.plans.blocksInWindow(
      localUtc(10, 12, 9, 0),
      localUtc(10, 12, 10, 0),
    );
    expect(
      history.where(
        (row) => row.block.range.startUtc == localUtc(10, 12, 9, 15),
      ),
      hasLength(1),
    );
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}
