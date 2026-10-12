import 'dart:isolate';

import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

abstract interface class ScheduleProblemSource {
  /// 装配排程输入。
  ///
  /// [override] 是一次性规则覆盖，用于"只影响本次生成、不写入设置"的场景
  /// （特殊日恢复）。为 null 时行为与不带该参数完全一致。
  Future<ScheduleProblem> load({ScheduleRuleOverride? override});
}

abstract interface class ProposalCreator {
  /// 生成提案。
  ///
  /// [override] 必须原样传给 [ScheduleProblemSource.load]，并随返回的提案一起携带，
  /// 否则确认阶段重放不出同一个输入哈希。
  Future<ScheduleProposal> createProposal({ScheduleRuleOverride? override});
}

final class PlanningService implements ProposalCreator {
  PlanningService({
    required this.source,
    required this.engine,
    this.snapshots = const InputSnapshotBuilder(),
    this.onProposalCreated,
    this.recurring,
    this.clock,
  });

  final ScheduleProblemSource source;
  final ScheduleEngine engine;
  final InputSnapshotBuilder snapshots;

  /// 周期目标的当前周期与进度（M6）。为空时 [shortfallsFor] 返回空表——
  /// 与"没有周期目标"是同一种结果，因此调用方不必分支。
  final RecurringTaskService? recurring;

  /// 判定"哪一周"用的时钟。为空时取系统当前时刻。
  final Clock? clock;

  /// 每次生成提案后的通知回调（与 `FocusService.onFinished` 同型）。
  ///
  /// 存在的理由是一件具体的事：**冲突不是持久事实，而是每次排程的产物**（只活在
  /// `ScheduleProposal` 里），因此"当前有哪些冲突待处理"此前**没有任何来源**——应用里
  /// 没有任何组件持有"最近一次生成的提案"，于是 R8 的"冲突待处理"通知只能被跳过而不是
  /// 伪造一条（见 §13.0 的 R8 ③ 与 W9）。组合根用这个回调把最近提案记下来，冲突通知的
  /// `pendingConflicts` 便有了真实来源；同一个落点将来也能产生 `replan:` 事件。
  final void Function(ScheduleProposal proposal)? onProposalCreated;

  final Map<String, ScheduleProposal> _previews = {};

  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
  }) async {
    final rawProblem = await source.load(override: override);
    final inputHash = snapshots.hash(InputSnapshot(problem: rawProblem));
    final problem = _withInputHash(rawProblem, inputHash);
    // Copy the engine into a local before creating the closure. Referencing the
    // instance field directly makes the closure capture this PlanningService,
    // including a production source that owns an unsendable SQLite connection.
    final scheduleEngine = engine;
    final proposal = await Isolate.run(() {
      TimeZoneDatabase();
      return scheduleEngine.generate(problem);
    });
    // 引擎只认排程输入，不认识"这次输入是怎么来的"；一次性覆盖由本层附加，
    // 好让确认阶段（PlanApplicationService）能用同一个覆盖重放出同样的输入哈希。
    //
    // **生成之后再建立来源关联**（1.8.0，裁定第 1、4 点；设计 §5.2）：
    // 引擎是"从零生成"，它排出的块与上一版确认计划**没有任何 id 上的联系**，
    // 于是 `PlanDiffer` 会把"同一块换了时间"报成删除＋新增。
    // 这一步为它们配对，`continuedFromId` 由此而来——**不改位置、不改 id**，纯后处理。
    final preview = proposal
        .withRuleOverride(override)
        .withLinkedBlocks(
          linkBlockProvenance(
            confirmed: problem.confirmedBlocks,
            generated: proposal.blocks,
          ),
        )
        // **把延后要求随提案带走**（用户第 72 轮）：应用前还要再校验一次
        // "这次延后到底兑现了没有"，而调整意图在生成结束后就被清掉
        // （规范 §11.3 最后一段），不带走就无从校验。
        .withAdjustmentRequirement(_adjustmentRequirementOf(problem));
    _previews[preview.proposalId] = preview;
    onProposalCreated?.call(preview);
    return preview;
  }

  ScheduleProposal? preview(String proposalId) => _previews[proposalId];

  /// **周期目标的容量缺口**（M6，路线图 §3.4 / §11 Task 8）。
  ///
  /// 缺口＝"这一周还差多少" − "不占用保护时间的前提下还能安排多少"。
  /// 两条纪律都在这个方法里兑现：
  ///
  /// - **不挤占保护时间**：`schedulableMinutes` 由 `problem.protectedIntervals`（以及固定
  ///   日程与已锁定块）**扣减**得出，而保护区间本身**只被读取**。缺口的处置交给用户
  ///   （§3.4 的四个动作），系统不会自己挪保护时间。
  /// - **数字必须精确**：容量 120、目标 180 ⇒ 缺口正好 60（§7.2）。因此这里用的是
  ///   "窗口内的空闲分钟"这个可复算的量，而不是"大概排不下"。
  ///
  /// 只有一个目标时报缺口；多个目标同时缺时**每个都报**，因为用户需要知道一共差多少——
  /// 把它们合并成一个数字会掩盖"单独一个就已经排不下"这件事。
  ///
  /// [nowUtc] 只影响"哪一周"的判定；为空时用 `clock` 的当前时刻。
  Future<List<CapacityShortfall>> shortfallsFor(
    ScheduleProposal proposal,
  ) async {
    final recurring = this.recurring;
    final now = clock?.nowUtc() ?? DateTime.now().toUtc();
    if (recurring == null) return const [];
    if (proposal.unscheduled.isEmpty) return const [];
    final problem = await source.load(override: proposal.ruleOverride);
    final period = recurring.periodContaining(now);
    final shortfalls = <CapacityShortfall>[];
    for (final task in proposal.unscheduled) {
      final cycle = await recurring.repository.findCycleByTaskId(task.taskId);
      if (cycle == null) continue;
      final template = await recurring.repository.findTemplate(
        cycle.templateId,
      );
      if (template == null) continue;
      // 只报**当前这一周**的缺口：上一周的目标已经结算，为它报缺口会让用户去改一件
      // 已经结束的事。
      if (cycle.periodStartLocalDate != period.startLocalDate) continue;
      final progress = await recurring.progressForCycle(
        cycle.templateId,
        cycle.periodStartLocalDate,
      );
      final shortfall = capacityShortfallForRecurringGoal(
        templateId: template.id,
        title: template.title,
        periodStartLocalDate: cycle.periodStartLocalDate,
        targetMinutes: progress.remainingMinutes,
        window: problem.planningWindow,
        fixedRanges: [for (final item in problem.fixedIntervals) item.range],
        protectedRanges: [
          for (final item in problem.protectedIntervals) item.range,
        ],
        lockedRanges: [for (final item in problem.lockedBlocks) item.range],
        protectedConstraint: problem.rules.protectedTimes
            .where((rule) => rule.enabled)
            .map((rule) => rule.kind)
            .firstOrNull,
      );
      if (shortfall != null) shortfalls.add(shortfall);
    }
    return List.unmodifiable(shortfalls);
  }
}

ScheduleProblem withCurrentInputHash(
  ScheduleProblem problem,
  InputSnapshotBuilder snapshots,
) => _withInputHash(problem, snapshots.hash(InputSnapshot(problem: problem)));

ScheduleProblem _withInputHash(ScheduleProblem problem, String inputHash) =>
    ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks,
      fixedIntervals: problem.fixedIntervals,
      protectedIntervals: problem.protectedIntervals,
      lockedBlocks: problem.lockedBlocks,
      existingBlocks: problem.existingBlocks,
      rules: problem.rules,
      preferences: problem.preferences,
      inputHash: inputHash,
      // 必须原样搬运：确认阶段会用同一个来源重新装配输入并比对哈希，丢掉这个集合会让
      // 手动拖动产生的提案被判为过期（C8 那次"重放不一致"是同型缺陷）。
      pinnedUnlockedBlockIds: problem.pinnedUnlockedBlockIds,
      // **同样必须原样搬运**（1.8.0，规范 §11.4 第 3、4 条）：它是"调整前的位置"，
      // 丢失之后"少动块／少位移"就没有参照，两项比较会退化成恒等。
      //
      // 这一行是补上的：`referenceBlocks` 加进 `ScheduleProblem` 之后我忘了改这里，
      // 于是装配层明明算出了参照，最终交到引擎手里的却是一个空 map——
      // 症状是 `schedule_reference_blocks_test.dart` 全红而 `analyze` 干净。
      // **新增 `ScheduleProblem` 字段时，这里是一处必须同步的复制点。**
      referenceBlocks: problem.referenceBlocks,
      // **同样必须原样搬运**（裁定第 3 点；设计 §5.3）：块级调整上下文是"这次生成的
      // 目标"，丢掉它会让延后**静默失效**——引擎按普通全量生成排一遍，用户看到的是
      // "点了延后但什么都没变"。
      //
      // 这一行是**又一处**补上的：`adjustment` 加进 `ScheduleProblem` 之后我同样忘了改
      // 这里，于是 `block_level_defer_test.dart` 两条用例当场报 `Actual: <null>`。
      // 与 `referenceBlocks` 那次是同一个陷阱——**新增字段时这里是必查的复制点**。
      adjustment: problem.adjustment,
      // **同样必须原样搬运**（裁定第 1、4 点）：来源关联要用它把新块与上一版配对。
      // 丢掉它的症状是"预览又把移动报成删除＋新增"——**不报错，只是说法错了**，
      // 因此只能靠用例发现（`defer_end_to_end_test.dart` 的"预览把延后报成移动"）。
      confirmedBlocks: problem.confirmedBlocks,
    );

/// 从排程输入里取出**本次延后要求**（用户第 72 轮）。
///
/// 三条信息各有来源：
/// - 目标块与下界来自 `problem.adjustment`（裁定第 3 点的块级上下文）；
/// - **原位置**与**要求的时长**来自确认计划里的那一块 ——
///   它们是"延后前"的事实，`adjustment` 里没有。
///
/// 目标块在确认计划里找不到时返回 null：那时无法表达"要延后的是哪一块"，
/// 也就没有可校验的要求（与装配层"不退回任务级模拟"同一口径）。
AdjustmentRequirement? _adjustmentRequirementOf(ScheduleProblem problem) {
  final adjustment = problem.adjustment;
  if (adjustment == null) return null;
  final target = problem.confirmedBlocks
      .where((block) => block.id == adjustment.targetBlockId)
      .firstOrNull;
  if (target == null) return null;
  return AdjustmentRequirement(
    targetBlockId: target.id,
    notBeforeUtc: adjustment.notBeforeUtc,
    requiredMinutes: target.durationMinutes,
    originalStartUtc: target.startUtc,
  );
}
