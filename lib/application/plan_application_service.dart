import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class PlanApplicationService {
  PlanApplicationService({
    required this.source,
    required this.repository,
    required TimeZoneDatabase zones,
    this.snapshots = const InputSnapshotBuilder(),
  }) : _validator = PlanValidator(zones);

  final ScheduleProblemSource source;
  final PlanRepository repository;
  final PlanValidator _validator;
  final InputSnapshotBuilder snapshots;

  Future<ApplyPlanResult> apply(ScheduleProposal proposal) async {
    // 必须重放生成该提案时用过的同一个一次性规则覆盖（如特殊日恢复的睡眠例外），
    // 否则重新装配出的规则与提案不一致，哈希必然不同，合法提案会被误判为过期。
    final current = withCurrentInputHash(
      await source.load(override: proposal.ruleOverride),
      snapshots,
    );
    if (current.inputHash != proposal.inputHash) {
      return ApplyPlanResult.stale();
    }
    final conflicts = _validator.validate(current, proposal.blocks);
    if (conflicts.isNotEmpty) return ApplyPlanResult.invalid(conflicts);
    return repository.applyProposal(proposal, current.inputHash);
  }
}
