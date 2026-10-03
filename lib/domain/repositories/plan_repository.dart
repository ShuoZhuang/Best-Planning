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

