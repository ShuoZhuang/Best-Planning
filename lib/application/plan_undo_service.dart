import 'package:personal_planner/domain/repositories/plan_repository.dart';

final class PlanUndoResult {
  const PlanUndoResult({
    required this.plan,
    required this.restoredFromPlanId,
    required this.replacedPlanId,
  });

  final ConfirmedPlan plan;
  final String restoredFromPlanId;
  final String replacedPlanId;
}

final class PlanUndoService {
  const PlanUndoService({required this.repository});

  final PlanHistoryRepository repository;

  Future<PlanUndoResult> undoLastAppliedPlan() async {
    final current = await repository.current();
    final previous = await repository.previous();
    if (current == null || previous == null) {
      throw StateError('没有可撤销的已确认计划');
    }
    final restored = await repository.restoreAsNewVersion(
      source: previous,
      replaced: current,
    );
    return PlanUndoResult(
      plan: restored,
      restoredFromPlanId: previous.id,
      replacedPlanId: current.id,
    );
  }
}
