import 'package:drift/drift.dart';
import 'package:personal_planner/application/plan_adjustment_service.dart';
import 'package:personal_planner/data/database/app_database.dart';

/// 真实的"执行已开始"证据（计划 Task 5 Step 3）。
///
/// 延后不得作用于已经开始的块。判断依据只有两处：
/// - `execution_occurrences.first_start_evidence_id` 非空（发生过的第一次开始证据）；
/// - `execution_fragments.state` 为 `started`/`completed`。
///
/// **不把"计划里存在块"当成证据**：那会让每个块都不可延后。
final class DriftAdjustmentExecutionEvidence
    implements AdjustmentExecutionEvidence {
  DriftAdjustmentExecutionEvidence(this.database);

  final AppDatabase database;

  @override
  Future<Set<String>> startedOrCompletedBlockIds(
    Iterable<String> blockIds,
  ) async {
    final ids = blockIds.toList();
    if (ids.isEmpty) return const {};
    final started = <String>{};
    final occurrences =
        await (database.select(database.executionOccurrences)..where(
              (row) =>
                  row.originBlockId.isIn(ids) &
                  row.firstStartEvidenceId.isNotNull(),
            ))
            .get();
    for (final row in occurrences) {
      final id = row.originBlockId;
      if (id != null) started.add(id);
    }
    final fragments =
        await (database.select(database.executionFragments)..where(
              (row) =>
                  row.blockId.isIn(ids) &
                  row.state.isIn(['started', 'completed']),
            ))
            .get();
    for (final row in fragments) {
      started.add(row.blockId);
    }
    return started;
  }
}
