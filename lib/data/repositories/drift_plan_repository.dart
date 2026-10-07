import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class DriftPlanRepository implements PlanStore, PlanBlockHistory {
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
    return version == null ? null : _loadVersion(version);
  }

  @override
  Future<ConfirmedPlan?> previous() async {
    final query = _database.select(_database.planVersions)
      ..where((row) => row.status.equals('superseded'))
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAtUtc),
        (row) => OrderingTerm.desc(row.id),
      ])
      ..limit(1);
    final version = await query.getSingleOrNull();
    return version == null ? null : _loadVersion(version);
  }

  @override
  Future<ConfirmedPlan> restoreAsNewVersion({
    required ConfirmedPlan source,
    required ConfirmedPlan replaced,
  }) async {
    final now = clock.nowUtc();
    final restoredId =
        'undo-${now.microsecondsSinceEpoch}-${source.id.replaceAll(':', '-')}';
    return _database.transaction(() async {
      await (_database.update(_database.planVersions)
            ..where((row) => row.status.equals('confirmed')))
          .write(const PlanVersionsCompanion(status: Value('superseded')));
      await _database
          .into(_database.planVersions)
          .insert(
            PlanVersionsCompanion.insert(
              id: restoredId,
              createdAtUtc: now.microsecondsSinceEpoch,
              inputHash: source.inputHash,
              algorithmVersion: source.algorithmVersion,
              status: 'confirmed',
              summaryJson: jsonEncode({
                'operation': 'undo',
                'restoredFrom': source.id,
                'replaced': replaced.id,
              }),
            ),
          );
      final blocks = <PlannedBlock>[];
      for (var index = 0; index < source.blocks.length; index++) {
        final block = source.blocks[index];
        final id = '$restoredId:block:$index';
        await _database
            .into(_database.scheduleBlocks)
            .insert(
              ScheduleBlocksCompanion.insert(
                id: id,
                planVersionId: restoredId,
                taskId: block.taskId,
                startAtUtc: block.startUtc.microsecondsSinceEpoch,
                endAtUtc: block.endUtc.microsecondsSinceEpoch,
                locked: Value(block.locked),
                explanationCode: block.explanationCode ?? 'undoRestore',
                createdAtUtc: Value(now.microsecondsSinceEpoch),
                updatedAtUtc: Value(now.microsecondsSinceEpoch),
              ),
            );
        blocks.add(
          PlannedBlock(
            id: id,
            taskId: block.taskId,
            range: block.range,
            locked: block.locked,
            explanationCode: block.explanationCode ?? 'undoRestore',
          ),
        );
      }
      await _database
          .into(_database.changeLog)
          .insert(
            ChangeLogCompanion.insert(
              id: '$restoredId:change:0',
              entityType: 'planVersion',
              entityId: restoredId,
              operation: 'undo:${replaced.id}->${source.id}',
              changedAtUtc: now.microsecondsSinceEpoch,
              revision: 1,
            ),
          );
      return ConfirmedPlan(
        id: restoredId,
        inputHash: source.inputHash,
        algorithmVersion: source.algorithmVersion,
        blocks: blocks,
      );
    });
  }

  /// 窗口内的块，来自**所有**计划版本（含 `superseded`），并带出所属版本与版本生成时刻。
  ///
  /// **不按 `status` 过滤**是这里的关键：重排会把旧版本标成 `superseded`，而过去几天当时排了
  /// 什么只留在那些版本里。只读 `confirmed` 就是"重排一次、历史全没"——用户 2026-10-07 报的
  /// 正是这个。**已经发生的事不该被后来的计划改写。**
  ///
  /// **必须带出 `versionCreatedAtUtc`**：调用方要按版本挑出"那一天当时在用的那一版"，而不是把
  /// 各版本求并集——求并集就会重复，见 `HistoricalPlanBlock` 的注释。
  @override
  Future<List<HistoricalPlanBlock>> blocksInWindow(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    final blocks = _database.scheduleBlocks;
    final versions = _database.planVersions;
    final query =
        _database.select(blocks).join([
            innerJoin(versions, versions.id.equalsExp(blocks.planVersionId)),
          ])
          ..where(
            blocks.startAtUtc.isSmallerThanValue(
                  endUtc.microsecondsSinceEpoch,
                ) &
                blocks.endAtUtc.isBiggerThanValue(
                  startUtc.microsecondsSinceEpoch,
                ),
          )
          ..orderBy([
            OrderingTerm.desc(versions.createdAtUtc),
            OrderingTerm.asc(blocks.startAtUtc),
            OrderingTerm.asc(blocks.id),
          ]);
    final rows = await query.get();
    return [
      for (final row in rows)
        if (row.readTableOrNull(blocks) case final block?)
          if (row.readTableOrNull(versions) case final version?)
            HistoricalPlanBlock(
              versionId: version.id,
              versionCreatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                version.createdAtUtc,
                isUtc: true,
              ),
              block: PlannedBlock(
                id: block.id,
                taskId: block.taskId,
                range: TimeRange(
                  startUtc: DateTime.fromMicrosecondsSinceEpoch(
                    block.startAtUtc,
                    isUtc: true,
                  ),
                  endUtc: DateTime.fromMicrosecondsSinceEpoch(
                    block.endAtUtc,
                    isUtc: true,
                  ),
                ),
                explanationCode: block.explanationCode,
                locked: block.locked,
              ),
            ),
    ];
  }

  Future<ConfirmedPlan> _loadVersion(PlanVersion version) async {
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
                createdAtUtc: Value(now.microsecondsSinceEpoch),
                updatedAtUtc: Value(now.microsecondsSinceEpoch),
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
