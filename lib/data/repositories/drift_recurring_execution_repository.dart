import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/execution/execution_fragment.dart' as d;
import 'package:personal_planner/domain/models/pending_plan_preview.dart' as d;
import 'package:personal_planner/domain/models/recurring_completion_evidence.dart'
    as d;
import 'package:personal_planner/domain/models/recurring_cycle_snapshot.dart'
    as d;
import 'package:personal_planner/domain/models/recurring_task.dart' as r;
import 'package:personal_planner/domain/models/task.dart' as t;

/// 1.12.0 周期执行片段、证据、周快照与持久预排的仓储。
///
/// 所有写方法假定调用方已开启事务；`replaceActivePreview` 自己负责多表原子替换。
final class DriftRecurringExecutionRepository {
  DriftRecurringExecutionRepository(
    this.database, {
    this.clock = const SystemClock(),
    required this.idGenerator,
  });

  final db.AppDatabase database;
  final Clock clock;
  final IdGenerator idGenerator;

  Future<T> transaction<T>(Future<T> Function() action) =>
      database.transaction(action);

  // ── 周实例快照 ───────────────────────────────────────────────────────────

  Future<d.RecurringCycleSnapshot?> findCycleSnapshot(String cycleId) async {
    final row = await (database.select(
      database.recurringCycleSnapshots,
    )..where((table) => table.cycleId.equals(cycleId))).getSingleOrNull();
    return row == null ? null : _snapshot(row);
  }

  Future<d.RecurringCycleSnapshot?> findCycleSnapshotForPeriod(
    String templateId,
    String periodStartLocalDate,
  ) async {
    final row =
        await (database.select(database.recurringCycleSnapshots)..where(
              (table) =>
                  table.templateId.equals(templateId) &
                  table.periodStartLocalDate.equals(periodStartLocalDate),
            ))
            .getSingleOrNull();
    return row == null ? null : _snapshot(row);
  }

  Future<void> upsertCycleSnapshot(d.RecurringCycleSnapshot snapshot) async {
    await database
        .into(database.recurringCycleSnapshots)
        .insertOnConflictUpdate(
          db.RecurringCycleSnapshotsCompanion.insert(
            cycleId: snapshot.cycleId,
            templateId: snapshot.templateId,
            transportTaskId: snapshot.transportTaskId,
            periodStartLocalDate: r.formatLocalDate(
              snapshot.periodStartLocalDate,
            ),
            periodStartUtc: snapshot.periodStartUtc.microsecondsSinceEpoch,
            periodEndUtc: snapshot.periodEndUtc.microsecondsSinceEpoch,
            effectiveStartUtc:
                snapshot.effectiveStartUtc.microsecondsSinceEpoch,
            effectiveEndUtc: snapshot.effectiveEndUtc.microsecondsSinceEpoch,
            timeZoneId: snapshot.timeZoneId,
            templateRevision: snapshot.templateRevision,
            title: snapshot.title,
            notes: Value(snapshot.notes),
            areaId: Value(snapshot.areaId),
            projectId: Value(snapshot.projectId),
            priority: snapshot.priority.name,
            energyLevel: snapshot.energyLevel.name,
            splitMode: snapshot.splitMode.name,
            minChunkMinutes: snapshot.minChunkMinutes,
            maxChunkMinutes: snapshot.maxChunkMinutes,
            preferredStartMinute: Value(snapshot.preferredStartMinute),
            preferredEndMinute: Value(snapshot.preferredEndMinute),
            pace: snapshot.pace.name,
            allowedWeekdaysMask: snapshot.allowedWeekdaysMask,
            targetMinutes: snapshot.targetMinutes,
            carryInMinutes: Value(snapshot.carryInMinutes),
            state: snapshot.state.name,
            revision: Value(snapshot.revision),
            createdAtUtc: snapshot.createdAtUtc.microsecondsSinceEpoch,
            updatedAtUtc: snapshot.updatedAtUtc.microsecondsSinceEpoch,
            settledAtUtc: Value(snapshot.settledAtUtc?.microsecondsSinceEpoch),
          ),
        );
  }

  Future<List<d.RecurringCycleSnapshot>> cycleSnapshotsIntersecting(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    final query = database.select(database.recurringCycleSnapshots)
      ..where(
        (table) =>
            table.effectiveStartUtc.isSmallerThanValue(
              endUtc.microsecondsSinceEpoch,
            ) &
            table.effectiveEndUtc.isBiggerThanValue(
              startUtc.microsecondsSinceEpoch,
            ),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.effectiveStartUtc)]);
    return [for (final row in await query.get()) _snapshot(row)];
  }

  Future<bool> carryInProvisional(String cycleId) async {
    final row = await (database.select(
      database.recurringCarryInStates,
    )..where((table) => table.cycleId.equals(cycleId))).getSingleOrNull();
    return row?.provisional ?? false;
  }

  Future<void> setCarryInProvisional(String cycleId, bool provisional) async {
    await database
        .into(database.recurringCarryInStates)
        .insertOnConflictUpdate(
          db.RecurringCarryInStatesCompanion.insert(
            cycleId: cycleId,
            provisional: Value(provisional),
            revision: const Value(2),
            updatedAtUtc: clock.nowUtc().microsecondsSinceEpoch,
          ),
        );
  }

  // ── 执行片段 ─────────────────────────────────────────────────────────────
  Future<d.ExecutionFragment?> findFragment(String fragmentId) async {
    final row = await (database.select(
      database.executionFragments,
    )..where((table) => table.fragmentId.equals(fragmentId))).getSingleOrNull();
    return row == null ? null : _fragment(row);
  }

  Future<d.ExecutionFragment?> findFragmentForBlock({
    required String planVersionId,
    required String blockId,
  }) async {
    final row =
        await (database.select(database.executionFragments)..where(
              (table) =>
                  table.planVersionId.equals(planVersionId) &
                  table.blockId.equals(blockId),
            ))
            .getSingleOrNull();
    return row == null ? null : _fragment(row);
  }

  /// 按可见块定位最近一次计划的片段；UI 只有 blockId 时用它取强身份。
  Future<d.ExecutionFragment?> findLatestFragmentForBlock(
    String blockId,
  ) async {
    final row =
        await (database.select(database.executionFragments)
              ..where((table) => table.blockId.equals(blockId))
              ..orderBy([(table) => OrderingTerm.desc(table.createdAtUtc)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _fragment(row);
  }

  Future<List<d.ExecutionFragment>> fragmentsForOccurrence(
    String occurrenceId,
  ) async {
    final query = database.select(database.executionFragments)
      ..where((table) => table.occurrenceId.equals(occurrenceId))
      ..orderBy([(table) => OrderingTerm.asc(table.createdAtUtc)]);
    return [for (final row in await query.get()) _fragment(row)];
  }

  Future<List<d.ExecutionFragment>> fragmentsForCycle(String cycleId) async {
    final query = database.select(database.executionFragments)
      ..where((table) => table.cycleId.equals(cycleId))
      ..orderBy([(table) => OrderingTerm.asc(table.plannedStartUtc)]);
    return [for (final row in await query.get()) _fragment(row)];
  }

  Future<void> insertFragment(d.ExecutionFragment fragment) async {
    await database
        .into(database.executionFragments)
        .insert(
          db.ExecutionFragmentsCompanion.insert(
            fragmentId: fragment.fragmentId,
            dataEpoch: fragment.dataEpoch,
            occurrenceId: fragment.occurrenceId,
            cycleId: Value(fragment.cycleId),
            rootFragmentId: fragment.rootFragmentId,
            sourceFragmentId: Value(fragment.sourceFragmentId),
            planVersionId: fragment.planVersionId,
            blockId: fragment.blockId,
            plannedStartUtc: fragment.plannedStartUtc.microsecondsSinceEpoch,
            plannedEndUtc: fragment.plannedEndUtc.microsecondsSinceEpoch,
            plannedMinutes: fragment.plannedMinutes,
            allocatedMicros: fragment.allocatedMicros,
            completedMicros: Value(fragment.completedMicros),
            state: fragment.state.name,
            createdAtUtc: fragment.createdAtUtc.microsecondsSinceEpoch,
            completedAtUtc: Value(
              fragment.completedAtUtc?.microsecondsSinceEpoch,
            ),
            revision: Value(fragment.revision),
          ),
        );
  }

  Future<void> updateFragment(d.ExecutionFragment fragment) async {
    await (database.update(
      database.executionFragments,
    )..where((table) => table.fragmentId.equals(fragment.fragmentId))).write(
      db.ExecutionFragmentsCompanion(
        cycleId: Value(fragment.cycleId),
        completedMicros: Value(fragment.completedMicros),
        state: Value(fragment.state.name),
        completedAtUtc: Value(fragment.completedAtUtc?.microsecondsSinceEpoch),
        revision: Value(fragment.revision),
      ),
    );
  }

  // ── 周期证据 ─────────────────────────────────────────────────────────────

  Future<void> insertEvidence(d.RecurringCompletionEvidence evidence) async {
    await database
        .into(database.recurringCompletionEvidence)
        .insert(
          db.RecurringCompletionEvidenceCompanion.insert(
            evidenceId: evidence.evidenceId,
            dataEpoch: evidence.dataEpoch,
            operationId: evidence.operationId,
            cycleId: evidence.cycleId,
            fragmentId: Value(evidence.fragmentId),
            amountMicros: evidence.amountMicros,
            kind: evidence.kind.name,
            reversesEvidenceId: Value(evidence.reversesEvidenceId),
            recordedAtUtc: evidence.recordedAtUtc.microsecondsSinceEpoch,
            effectiveAtUtc: evidence.effectiveAtUtc.microsecondsSinceEpoch,
            sequence: evidence.sequence,
            reason: Value(evidence.reason),
            idempotencyKey: evidence.idempotencyKey,
            revision: Value(evidence.revision),
          ),
        );
  }

  Future<List<d.RecurringCompletionEvidence>> evidenceForCycle(
    String cycleId,
  ) async {
    final query = database.select(database.recurringCompletionEvidence)
      ..where((table) => table.cycleId.equals(cycleId))
      ..orderBy([
        (table) => OrderingTerm.asc(table.sequence),
        (table) => OrderingTerm.asc(table.evidenceId),
      ]);
    return [for (final row in await query.get()) _evidence(row)];
  }

  Future<List<d.RecurringCompletionEvidence>> evidenceForFragment(
    String fragmentId,
  ) async {
    final query = database.select(database.recurringCompletionEvidence)
      ..where((table) => table.fragmentId.equals(fragmentId))
      ..orderBy([(table) => OrderingTerm.asc(table.sequence)]);
    return [for (final row in await query.get()) _evidence(row)];
  }

  Future<d.RecurringCompletionEvidence?> evidenceByOperation(
    String dataEpoch,
    String operationId,
  ) async {
    final row =
        await (database.select(database.recurringCompletionEvidence)..where(
              (table) =>
                  table.dataEpoch.equals(dataEpoch) &
                  table.operationId.equals(operationId),
            ))
            .getSingleOrNull();
    return row == null ? null : _evidence(row);
  }

  Future<d.RecurringCompletionEvidence?> evidenceByIdempotencyKey(
    String key,
  ) async {
    final row = await (database.select(
      database.recurringCompletionEvidence,
    )..where((table) => table.idempotencyKey.equals(key))).getSingleOrNull();
    return row == null ? null : _evidence(row);
  }

  Future<int> effectiveMicrosForCycle(String cycleId) async =>
      d.effectiveEvidenceMicros(await evidenceForCycle(cycleId));

  // ── 持久预排 ─────────────────────────────────────────────────────────────

  Future<d.PendingPlanPreview?> previewById(String previewId) async {
    final row = await (database.select(
      database.pendingPlanPreviews,
    )..where((table) => table.previewId.equals(previewId))).getSingleOrNull();
    return row == null ? null : _preview(row);
  }

  Future<d.PendingPreviewBundle?> activePreview(
    d.PendingPreviewKind kind,
  ) async {
    final row =
        await (database.select(database.pendingPlanPreviews)
              ..where(
                (table) =>
                    table.kind.equals(kind.name) &
                    table.status.equals(d.PendingPreviewStatus.active.name),
              )
              ..orderBy([(table) => OrderingTerm.desc(table.createdAtUtc)])
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;
    return d.PendingPreviewBundle(
      preview: _preview(row),
      blocks: await previewBlocks(row.previewId),
    );
  }

  Future<List<d.PendingPlanPreviewBlock>> previewBlocks(
    String previewId,
  ) async {
    final query = database.select(database.pendingPlanPreviewBlocks)
      ..where((table) => table.previewId.equals(previewId))
      ..orderBy([(table) => OrderingTerm.asc(table.startUtc)]);
    return [for (final row in await query.get()) _previewBlock(row)];
  }

  /// 原子替换同一种类当前预排：旧 active 变 superseded，再写新头与块。
  Future<void> replaceActivePreview(d.PendingPreviewBundle bundle) async {
    await database.transaction(() async {
      final now = clock.nowUtc().microsecondsSinceEpoch;
      await (database.update(database.pendingPlanPreviews)..where(
            (table) =>
                table.kind.equals(bundle.preview.kind.name) &
                table.status.equals(d.PendingPreviewStatus.active.name),
          ))
          .write(
            db.PendingPlanPreviewsCompanion(
              status: Value(d.PendingPreviewStatus.superseded.name),
              revision: const Value(2),
              summaryJson: Value(jsonEncode({'supersededAtUtc': now})),
            ),
          );
      await database
          .into(database.pendingPlanPreviews)
          .insert(
            db.PendingPlanPreviewsCompanion.insert(
              previewId: bundle.preview.previewId,
              kind: bundle.preview.kind.name,
              basePlanVersionId: bundle.preview.basePlanVersionId,
              inputHash: bundle.preview.inputHash,
              algorithmVersion: bundle.preview.algorithmVersion,
              windowStartUtc:
                  bundle.preview.windowStartUtc.microsecondsSinceEpoch,
              windowEndUtc: bundle.preview.windowEndUtc.microsecondsSinceEpoch,
              timeZoneId: bundle.preview.timeZoneId,
              status: bundle.preview.status.name,
              createdAtUtc: bundle.preview.createdAtUtc.microsecondsSinceEpoch,
              expiresAtUtc: bundle.preview.expiresAtUtc.microsecondsSinceEpoch,
              summaryJson: Value(bundle.preview.summaryJson),
              diagnosticsJson: Value(bundle.preview.diagnosticsJson),
              revision: Value(bundle.preview.revision),
            ),
          );
      for (final block in bundle.blocks) {
        await database
            .into(database.pendingPlanPreviewBlocks)
            .insert(
              db.PendingPlanPreviewBlocksCompanion.insert(
                previewId: block.previewId,
                blockId: block.blockId,
                taskId: Value(block.taskId),
                cycleId: Value(block.cycleId),
                title: block.title,
                startUtc: block.startUtc.microsecondsSinceEpoch,
                endUtc: block.endUtc.microsecondsSinceEpoch,
                minutes: block.minutes,
                explanationCode: block.explanationCode,
              ),
            );
      }
    });
  }

  Future<void> updatePreviewStatus(
    String previewId,
    d.PendingPreviewStatus status,
  ) async {
    await (database.update(
      database.pendingPlanPreviews,
    )..where((table) => table.previewId.equals(previewId))).write(
      db.PendingPlanPreviewsCompanion(
        status: Value(status.name),
        revision: const Value(2),
      ),
    );
  }

  // ── 映射 ─────────────────────────────────────────────────────────────────

  static DateTime _utc(int micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

  d.RecurringCycleSnapshot _snapshot(db.RecurringCycleSnapshot row) =>
      d.RecurringCycleSnapshot(
        cycleId: row.cycleId,
        templateId: row.templateId,
        transportTaskId: row.transportTaskId,
        periodStartLocalDate: r.parseLocalDate(row.periodStartLocalDate),
        periodStartUtc: _utc(row.periodStartUtc),
        periodEndUtc: _utc(row.periodEndUtc),
        effectiveStartUtc: _utc(row.effectiveStartUtc),
        effectiveEndUtc: _utc(row.effectiveEndUtc),
        timeZoneId: row.timeZoneId,
        templateRevision: row.templateRevision,
        title: row.title,
        notes: row.notes,
        areaId: row.areaId,
        projectId: row.projectId,
        priority: t.TaskPriority.values.byName(row.priority),
        energyLevel: t.TaskEnergyLevel.values.byName(row.energyLevel),
        splitMode: t.TaskSplitMode.values.byName(row.splitMode),
        minChunkMinutes: row.minChunkMinutes,
        maxChunkMinutes: row.maxChunkMinutes,
        preferredStartMinute: row.preferredStartMinute,
        preferredEndMinute: row.preferredEndMinute,
        pace: r.RecurringPace.values.byName(row.pace),
        allowedWeekdaysMask: row.allowedWeekdaysMask,
        targetMinutes: row.targetMinutes,
        carryInMinutes: row.carryInMinutes,
        state: r.RecurringCycleStatus.values.byName(row.state),
        revision: row.revision,
        createdAtUtc: _utc(row.createdAtUtc),
        updatedAtUtc: _utc(row.updatedAtUtc),
        settledAtUtc: row.settledAtUtc == null ? null : _utc(row.settledAtUtc!),
      );

  d.ExecutionFragment _fragment(db.ExecutionFragment row) =>
      d.ExecutionFragment(
        fragmentId: row.fragmentId,
        dataEpoch: row.dataEpoch,
        occurrenceId: row.occurrenceId,
        cycleId: row.cycleId,
        rootFragmentId: row.rootFragmentId,
        sourceFragmentId: row.sourceFragmentId,
        planVersionId: row.planVersionId,
        blockId: row.blockId,
        plannedStartUtc: _utc(row.plannedStartUtc),
        plannedEndUtc: _utc(row.plannedEndUtc),
        plannedMinutes: row.plannedMinutes,
        allocatedMicros: row.allocatedMicros,
        completedMicros: row.completedMicros,
        state: d.ExecutionFragmentState.values.byName(row.state),
        createdAtUtc: _utc(row.createdAtUtc),
        completedAtUtc: row.completedAtUtc == null
            ? null
            : _utc(row.completedAtUtc!),
        revision: row.revision,
      );

  d.RecurringCompletionEvidence _evidence(
    db.RecurringCompletionEvidenceData row,
  ) => d.RecurringCompletionEvidence(
    evidenceId: row.evidenceId,
    dataEpoch: row.dataEpoch,
    operationId: row.operationId,
    cycleId: row.cycleId,
    fragmentId: row.fragmentId,
    amountMicros: row.amountMicros,
    kind: d.RecurringEvidenceKind.values.byName(row.kind),
    reversesEvidenceId: row.reversesEvidenceId,
    recordedAtUtc: _utc(row.recordedAtUtc),
    effectiveAtUtc: _utc(row.effectiveAtUtc),
    sequence: row.sequence,
    reason: row.reason,
    idempotencyKey: row.idempotencyKey,
    revision: row.revision,
  );

  d.PendingPlanPreview _preview(db.PendingPlanPreview row) =>
      d.PendingPlanPreview(
        previewId: row.previewId,
        kind: d.PendingPreviewKind.values.byName(row.kind),
        basePlanVersionId: row.basePlanVersionId,
        inputHash: row.inputHash,
        algorithmVersion: row.algorithmVersion,
        windowStartUtc: _utc(row.windowStartUtc),
        windowEndUtc: _utc(row.windowEndUtc),
        timeZoneId: row.timeZoneId,
        status: d.PendingPreviewStatus.values.byName(row.status),
        createdAtUtc: _utc(row.createdAtUtc),
        expiresAtUtc: _utc(row.expiresAtUtc),
        summaryJson: row.summaryJson,
        diagnosticsJson: row.diagnosticsJson,
        revision: row.revision,
      );

  d.PendingPlanPreviewBlock _previewBlock(db.PendingPlanPreviewBlock row) =>
      d.PendingPlanPreviewBlock(
        previewId: row.previewId,
        blockId: row.blockId,
        taskId: row.taskId,
        cycleId: row.cycleId,
        title: row.title,
        startUtc: _utc(row.startUtc),
        endUtc: _utc(row.endUtc),
        explanationCode: row.explanationCode,
        minutes: row.minutes,
      );
}
