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
  const PlanUndoService({required this.repository, this.onPlanChanged});

  final PlanHistoryRepository repository;

  /// 撤销**真的换掉了当前计划**之后的回调（B5，与 `PlanApplicationService.onPlanChanged`
  /// 同型）。撤销同样改变"当前计划"，因此同样要让通知重新同步——否则撤销之后提醒还停在
  /// 被撤销的那一版计划上。
  final Future<void> Function()? onPlanChanged;

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
    // 放在成功之后：上面两处 throw 与仓储失败都没有改变当前计划。
    await onPlanChanged?.call();
    return PlanUndoResult(
      plan: restored,
      restoredFromPlanId: previous.id,
      replacedPlanId: current.id,
    );
  }
}
