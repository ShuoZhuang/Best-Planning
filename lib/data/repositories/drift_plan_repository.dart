import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class DriftPlanRepository implements PlanRepository {
  DriftPlanRepository(this._database, {this.clock = const SystemClock()});

  final AppDatabase _database;
  final Clock clock;

  @override
  Future<ConfirmedPlan?> current() async {
    final query = _database.select(_database.planVersions)
      ..where((row) => row.status.equals('confirmed'))
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAtUtc),
        (row) => OrderingTerm.desc(row.id),
      ])
      ..limit(1);
    final version = await query.getSingleOrNull();
    if (version == null) return null;

    final blockQuery = _database.select(_database.scheduleBlocks)
      ..where((row) => row.planVersionId.equals(version.id))
      ..orderBy([
        (row) => OrderingTerm.asc(row.startAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    final rows = await blockQuery.get();
    return ConfirmedPlan(
      id: version.id,
      inputHash: version.inputHash,
      algorithmVersion: version.algorithmVersion,
      blocks: [
        for (final row in rows)
          PlannedBlock(
            id: row.id,
            taskId: row.taskId,
            range: TimeRange(
              startUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.startAtUtc,
                isUtc: true,
              ),
              endUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.endAtUtc,
                isUtc: true,
              ),
            ),
            locked: row.locked,
            explanationCode: row.explanationCode,
          ),
      ],
    );
  }

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    if (proposal.inputHash != expectedInputHash) {
      return ApplyPlanResult.stale();
    }
    final now = clock.nowUtc();
    if (!now.isUtc) {
      throw StateError('Plan repository clock must return UTC.');
    }

    return _database.transaction(() async {
      await (_database.update(_database.planVersions)
            ..where((row) => row.status.equals('confirmed')))
          .write(const PlanVersionsCompanion(status: Value('superseded')));
      await _database
          .into(_database.planVersions)
          .insert(
            PlanVersionsCompanion.insert(
              id: proposal.proposalId,
              createdAtUtc: now.microsecondsSinceEpoch,
              inputHash: proposal.inputHash,
              algorithmVersion: proposal.algorithmVersion,
              status: 'confirmed',
              summaryJson: jsonEncode({
                'isFullyFeasible': proposal.metrics.isFullyFeasible,
                'scheduledMinutes': proposal.metrics.scheduledMinutes,
                'unscheduledMinutes': proposal.metrics.unscheduledMinutes,
              }),
            ),
          );
      await _database
          .into(_database.changeLog)
          .insert(
            ChangeLogCompanion.insert(
              id: '${proposal.proposalId}:change:0',
              entityType: 'planVersion',
              entityId: proposal.proposalId,
              operation: 'confirm',
              changedAtUtc: now.microsecondsSinceEpoch,
              revision: 1,
            ),
          );

      final persistedBlocks = <PlannedBlock>[];
      for (var index = 0; index < proposal.blocks.length; index++) {
        final block = proposal.blocks[index];
        final persistedId = '${proposal.proposalId}:${block.id}';
        await _database
            .into(_database.scheduleBlocks)
            .insert(
              ScheduleBlocksCompanion.insert(
                id: persistedId,
                planVersionId: proposal.proposalId,
                taskId: block.taskId,
                startAtUtc: block.startUtc.microsecondsSinceEpoch,
                endAtUtc: block.endUtc.microsecondsSinceEpoch,
                locked: Value(block.locked),
                explanationCode: block.explanationCode ?? 'scheduled',
              ),
            );
        await _database
            .into(_database.changeLog)
            .insert(
              ChangeLogCompanion.insert(
                id: '${proposal.proposalId}:change:${index + 1}',
                entityType: 'scheduleBlock',
                entityId: persistedId,
                operation: 'create',
                changedAtUtc: now.microsecondsSinceEpoch,
                revision: 1,
              ),
            );
        persistedBlocks.add(
          PlannedBlock(
            id: persistedId,
            taskId: block.taskId,
            range: block.range,
            locked: block.locked,
            explanationCode: block.explanationCode ?? 'scheduled',
          ),
        );
      }
      final plan = ConfirmedPlan(
        id: proposal.proposalId,
        inputHash: proposal.inputHash,
        algorithmVersion: proposal.algorithmVersion,
        blocks: persistedBlocks,
      );
      return ApplyPlanResult.applied(plan);
    });
  }
}
