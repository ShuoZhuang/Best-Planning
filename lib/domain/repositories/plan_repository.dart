import 'dart:collection';

import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

enum ApplyPlanStatus { applied, staleProposal, invalidProposal }

final class ConfirmedPlan {
  ConfirmedPlan({
    required this.id,
    required this.inputHash,
    required this.algorithmVersion,
    required List<PlannedBlock> blocks,
  }) : blocks = UnmodifiableListView(List.of(blocks));

  final String id;
  final String inputHash;
  final String algorithmVersion;
  final List<PlannedBlock> blocks;
}

final class ApplyPlanResult {
  ApplyPlanResult._({
    required this.status,
    this.plan,
    List<PlanningConflict> conflicts = const [],
  }) : conflicts = UnmodifiableListView(List.of(conflicts));

  factory ApplyPlanResult.applied(ConfirmedPlan plan) =>
      ApplyPlanResult._(status: ApplyPlanStatus.applied, plan: plan);

  factory ApplyPlanResult.stale() =>
      ApplyPlanResult._(status: ApplyPlanStatus.staleProposal);

  factory ApplyPlanResult.invalid(List<PlanningConflict> conflicts) =>
      ApplyPlanResult._(
        status: ApplyPlanStatus.invalidProposal,
        conflicts: conflicts,
      );

  final ApplyPlanStatus status;
  final ConfirmedPlan? plan;
  final List<PlanningConflict> conflicts;
}

abstract interface class PlanRepository {
  Future<ConfirmedPlan?> current();

  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  );
}

abstract interface class PlanHistoryRepository {
  Future<ConfirmedPlan?> current();

  Future<ConfirmedPlan?> previous();

  Future<ConfirmedPlan> restoreAsNewVersion({
    required ConfirmedPlan source,
    required ConfirmedPlan replaced,
  });
}

/// 历史计划块，连同它所属版本的生成时刻。
///
/// **为什么必须带版本信息**：一版计划是对**那段时间**的完整声明。只拿到"块"却不知道它属于哪一版，
/// 调用方就只能把各版本求并集——那正是 2026-10-07 那次"已完成待办重复"的成因：`算法作业` 今天在
/// 当前版是 10:00、在旧版是 07:30，两版并起来就出现两次；`大物预习课` 昨天在两版里各有 50+90
/// 分钟，并起来就出现三四次。按版本挑出"当时在用的那一版"，才是正确的还原方式。
final class HistoricalPlanBlock {
  const HistoricalPlanBlock({
    required this.block,
    required this.versionId,
    required this.versionCreatedAtUtc,
  });

  final PlannedBlock block;
  final String versionId;
  final DateTime versionCreatedAtUtc;
}

/// 读取**历史计划块**：任何计划版本（含已被取代的）里落在窗口内的块。
///
/// **为什么需要它**：`PlanRepository.current()` 只给最新那一版计划，而重排会生成新版本。
/// 过去几天当时排了什么，只留在旧版本里——于是重排之后那些块从日历上消失。用户 2026-10-07 的
/// 反馈原话是"如果我后续的计划需要进行重排，已完成的计划在视图里就不需要改变了啊，像昨天已经
/// 完成计划在我刚才调整计划后就都不见了"。**已经发生的事不该被后来的计划改写。**
///
/// **为什么是新端口而不是把 `PlanRepository` 加宽**：与 `PlanHistoryRepository` 同一理由——
/// 全库有多个测试替身只实现 `current()`/`applyProposal`，把 `planRepository` 加宽会一次性牵动
/// 它们；而"提供不了历史"本身是合法状态（那就退回旧行为：只显示最新一版）。
abstract interface class PlanBlockHistory {
  /// 窗口内的块，来自**所有**计划版本，并带出所属版本与版本生成时刻。
  Future<List<HistoricalPlanBlock>> blocksInWindow(
    DateTime startUtc,
    DateTime endUtc,
  );
}

/// 同时具备"应用方案"与"计划历史"两种能力的计划仓储。
///
/// **为什么需要它**：撤销（FR-REPLAN-08）需要 `previous()` 与 `restoreAsNewVersion`，而"应用
/// 方案"需要 `applyProposal`，两者分属上面两个端口。真实的 `DriftPlanRepository` **本来就同时
/// 实现两者**，但在路由那一层静态类型被窄化成 `PlanRepository`，撤销于是拿不到 `previous()`。
/// 声明这个组合接口后，路由按它收取即可，**不必新增一条从 `main.dart` 穿过 `PlannerApp` 到页面
/// 的参数链**（那会多出 4 处装配）。
///
/// Dart **没有结构化子类型**：实现了这两个端口的类不会自动成为本接口的子类型，因此实现类必须
/// 显式把本接口写进 `implements`（`DriftPlanRepository` 已如此）。
abstract interface class PlanStore
    implements PlanRepository, PlanHistoryRepository {}
