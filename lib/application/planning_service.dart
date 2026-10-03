import 'dart:isolate';

import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
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
  });

  final ScheduleProblemSource source;
  final ScheduleEngine engine;
  final InputSnapshotBuilder snapshots;

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
  Future<ScheduleProposal> createProposal({ScheduleRuleOverride? override}) async {
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
    final preview = proposal.withRuleOverride(override);
    _previews[preview.proposalId] = preview;
    onProposalCreated?.call(preview);
    return preview;
  }

  ScheduleProposal? preview(String proposalId) => _previews[proposalId];
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
    );
