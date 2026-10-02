import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_undo_service.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  test('应用计划 B 后撤销会以新版本恢复 A，不删除历史', () async {
    final planA = _plan('A', 9);
    final planB = _plan('B', 11);
    final repository = _HistoryRepository([planA, planB]);
    final service = PlanUndoService(repository: repository);

    final result = await service.undoLastAppliedPlan();

    expect(result.restoredFromPlanId, 'A');
    expect(result.plan.blocks.single.range, planA.blocks.single.range);
    expect(result.plan.id, 'undo-1');
    expect(repository.versions.map((item) => item.id), ['A', 'B', 'undo-1']);
    expect(repository.audit, ['undo:B->A:undo-1']);
  });
}

ConfirmedPlan _plan(String id, int hour) => ConfirmedPlan(
  id: id,
  inputHash: 'hash-$id',
  algorithmVersion: '1',
  blocks: [
    PlannedBlock(
      id: '$id-block',
      taskId: 'task-1',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 3, hour),
        endUtc: DateTime.utc(2026, 10, 3, hour + 1),
      ),
    ),
  ],
);

final class _HistoryRepository implements PlanHistoryRepository {
  _HistoryRepository(this.versions);
  final List<ConfirmedPlan> versions;
  final List<String> audit = [];

  @override
  Future<ConfirmedPlan?> current() async => versions.lastOrNull;

  @override
  Future<ConfirmedPlan?> previous() async =>
      versions.length < 2 ? null : versions[versions.length - 2];

  @override
  Future<ConfirmedPlan> restoreAsNewVersion({
    required ConfirmedPlan source,
    required ConfirmedPlan replaced,
  }) async {
    final restored = ConfirmedPlan(
      id: 'undo-1',
      inputHash: source.inputHash,
      algorithmVersion: source.algorithmVersion,
      blocks: source.blocks,
    );
    versions.add(restored);
    audit.add('undo:${replaced.id}->${source.id}:${restored.id}');
    return restored;
  }
}
