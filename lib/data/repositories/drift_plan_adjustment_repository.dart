import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/defer_unit.dart' as d;
import 'package:personal_planner/domain/models/plan_adjustment.dart' as d;
import 'package:personal_planner/domain/repositories/plan_adjustment_repository.dart';

/// 调整操作的 Drift 实现（计划 Task 3）。
///
/// **CAS 是这里唯一的写入口**：`compareAndSet` 在一个事务里"读行 → 逐项比对
/// `adjustmentId + revision + basePlanVersionId + status∈from` → 条件 UPDATE →
/// 追加审计事件"。零行更新返回 `null`，让上层把并发当成正常结果而不是异常。
final class DriftPlanAdjustmentRepository
    implements PlanAdjustmentRepository {
  DriftPlanAdjustmentRepository(
    this.database, {
    this.clock = const SystemClock(),
  });

  final db.AppDatabase database;
  final Clock clock;

  static DateTime _utc(int micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

  static final Set<d.PlanAdjustmentStatus> _openStatuses = {
    d.PlanAdjustmentStatus.active,
    d.PlanAdjustmentStatus.generating,
    d.PlanAdjustmentStatus.previewReady,
    d.PlanAdjustmentStatus.applying,
  };

  @override
  Future<void> create(d.PlanAdjustment adjustment) async {
    await database.transaction(() async {
      await database
          .into(database.planAdjustments)
          .insert(_companion(adjustment));
      await _appendEvent(
        adjustment.adjustmentId,
        fromStatus: adjustment.status,
        toStatus: adjustment.status,
        revision: adjustment.revision,
        reasonCode: null,
      );
    });
  }

  @override
  Future<d.PlanAdjustment?> byId(String adjustmentId) async {
    final row = await _row(adjustmentId);
    return row == null ? null : _adjustment(row);
  }

  @override
  Future<List<d.PlanAdjustment>> recoverable(DateTime nowUtc) async {
    final query = database.select(database.planAdjustments)
      ..where(
        (table) =>
            table.status.isIn([for (final s in _openStatuses) s.name]) &
            table.expiresAtUtc.isBiggerThanValue(nowUtc.microsecondsSinceEpoch),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.expiresAtUtc)]);
    return [for (final row in await query.get()) _adjustment(row)];
  }

  @override
  Future<d.PlanAdjustment?> compareAndSet({
    required d.PlanAdjustmentToken expected,
    required Set<d.PlanAdjustmentStatus> from,
    required d.PlanAdjustmentStatus to,
    String? previewId,
    String? appliedPlanVersionId,
    d.PlanAdjustmentFailureCode? failureCode,
    bool incrementRevision = false,
  }) async {
    return database.transaction(() async {
      final row = await _row(expected.adjustmentId);
      if (row == null) return null;
      if (row.revision != expected.revision ||
          row.basePlanVersionId != expected.basePlanVersionId) {
        return null;
      }
      final current = d.PlanAdjustmentStatus.values.byName(row.status);
      if (!from.contains(current)) return null;
      final allowed =
          d.PlanAdjustment.allowedTransitions[current] ?? const {};
      if (!allowed.contains(to)) return null;

      final newRevision = incrementRevision
          ? row.revision + 1
          : row.revision;
      final companion = db.PlanAdjustmentsCompanion(
        status: Value(to.name),
        revision: Value(newRevision),
        previewId: to == d.PlanAdjustmentStatus.generating
            ? Value(previewId)
            : (previewId == null ? const Value.absent() : Value(previewId)),
        appliedPlanVersionId: appliedPlanVersionId == null
            ? const Value.absent()
            : Value(appliedPlanVersionId),
        failureCode: to == d.PlanAdjustmentStatus.failed
            ? Value(failureCode?.name)
            : (to.isTerminal ? const Value(null) : const Value.absent()),
      );
      final updated =
          await (database.update(database.planAdjustments)..where(
                (table) =>
                    table.adjustmentId.equals(expected.adjustmentId) &
                    table.revision.equals(expected.revision) &
                    table.basePlanVersionId.equals(
                      expected.basePlanVersionId,
                    ) &
                    table.status.isIn([for (final s in from) s.name]),
              ))
              .write(companion);
      if (updated != 1) return null;
      await _appendEvent(
        expected.adjustmentId,
        fromStatus: current,
        toStatus: to,
        revision: newRevision,
        reasonCode: failureCode,
      );
      return _readOrNull(expected.adjustmentId);
    });
  }

  @override
  Future<void> expireBefore(DateTime nowUtc) async {
    await database.transaction(() async {
      final rows =
          await (database.select(database.planAdjustments)..where(
                (table) =>
                    table.status.isNotIn(['expired', 'cancelled', 'stale']) &
                    table.status.isIn([for (final s in _openStatuses) s.name]) &
                    table.expiresAtUtc.isSmallerOrEqualValue(
                      nowUtc.microsecondsSinceEpoch,
                    ),
              ))
              .get();
      for (final row in rows) {
        final current = d.PlanAdjustmentStatus.values.byName(row.status);
        if (!current.isOpen) continue;
        final updated =
            await (database.update(database.planAdjustments)..where(
                  (table) =>
                      table.adjustmentId.equals(row.adjustmentId) &
                      table.revision.equals(row.revision) &
                      table.status.equals(row.status),
                ))
                .write(
                  db.PlanAdjustmentsCompanion(
                    status: Value(d.PlanAdjustmentStatus.expired.name),
                  ),
                );
        if (updated != 1) continue;
        await _appendEvent(
          row.adjustmentId,
          fromStatus: current,
          toStatus: d.PlanAdjustmentStatus.expired,
          revision: row.revision,
          reasonCode: d.PlanAdjustmentFailureCode.previewExpired,
        );
      }
    });
  }

  @override
  Future<List<d.PlanAdjustmentEvent>> events(String adjustmentId) async {
    final query = database.select(database.planAdjustmentEvents)
      ..where((table) => table.adjustmentId.equals(adjustmentId))
      ..orderBy([(table) => OrderingTerm.asc(table.sequence)]);
    return [
      for (final row in await query.get())
        d.PlanAdjustmentEvent(
          adjustmentId: row.adjustmentId,
          sequence: row.sequence,
          fromStatus: d.PlanAdjustmentStatus.values.byName(row.fromStatus),
          toStatus: d.PlanAdjustmentStatus.values.byName(row.toStatus),
          revision: row.revision,
          occurredAtUtc: _utc(row.occurredAtUtc),
          reasonCode: row.reasonCode == null
              ? null
              : d.PlanAdjustmentFailureCode.values.byName(row.reasonCode!),
        ),
    ];
  }

  @override
  Future<List<d.PlanAdjustment>> openForTargetBlock(String targetBlockId) async {
    final query = database.select(database.planAdjustments)
      ..where(
        (table) =>
            table.targetBlockId.equals(targetBlockId) &
            table.status.isIn([for (final s in _openStatuses) s.name]),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.createdAtUtc)]);
    return [for (final row in await query.get()) _adjustment(row)];
  }

  @override
  Future<List<d.PlanAdjustment>> byBasePlanVersion(
    String basePlanVersionId,
  ) async {
    final query = database.select(database.planAdjustments)
      ..where((table) => table.basePlanVersionId.equals(basePlanVersionId))
      ..orderBy([(table) => OrderingTerm.asc(table.createdAtUtc)]);
    return [for (final row in await query.get()) _adjustment(row)];
  }

  // ── 内部 ─────────────────────────────────────────────────────────────────

  Future<db.PlanAdjustment?> _row(String adjustmentId) =>
      (database.select(database.planAdjustments)
            ..where((table) => table.adjustmentId.equals(adjustmentId)))
          .getSingleOrNull();

  Future<d.PlanAdjustment> _readOrNull(String adjustmentId) async {
    final row = await _row(adjustmentId);
    if (row == null) {
      throw StateError('CAS 成功后读不到调整记录');
    }
    return _adjustment(row);
  }

  Future<void> _appendEvent(
    String adjustmentId, {
    required d.PlanAdjustmentStatus fromStatus,
    required d.PlanAdjustmentStatus toStatus,
    required int revision,
    required d.PlanAdjustmentFailureCode? reasonCode,
  }) async {
    final existing = await events(adjustmentId);
    final sequence = existing.isEmpty ? 1 : existing.last.sequence + 1;
    await database
        .into(database.planAdjustmentEvents)
        .insert(
          db.PlanAdjustmentEventsCompanion.insert(
            adjustmentId: adjustmentId,
            sequence: sequence,
            fromStatus: fromStatus.name,
            toStatus: toStatus.name,
            revision: revision,
            occurredAtUtc: clock.nowUtc().microsecondsSinceEpoch,
            reasonCode: Value(reasonCode?.name),
          ),
        );
  }

  db.PlanAdjustmentsCompanion _companion(d.PlanAdjustment adjustment) =>
      db.PlanAdjustmentsCompanion.insert(
        adjustmentId: adjustment.adjustmentId,
        kind: adjustment.kind.name,
        targetBlockId: adjustment.targetBlockId,
        targetTaskId: adjustment.targetTaskId,
        targetTitleSnapshot: adjustment.targetTitleSnapshot,
        basePlanVersionId: adjustment.basePlanVersionId,
        sourceStartUtc: adjustment.sourceStartUtc.microsecondsSinceEpoch,
        sourceEndUtc: adjustment.sourceEndUtc.microsecondsSinceEpoch,
        notBeforeUtc: adjustment.notBeforeUtc.microsecondsSinceEpoch,
        timeZoneId: adjustment.timeZoneId,
        requestedAmount: adjustment.requestedAmount,
        requestedUnit: adjustment.requestedUnit.name,
        status: adjustment.status.name,
        createdAtUtc: adjustment.createdAtUtc.microsecondsSinceEpoch,
        expiresAtUtc: adjustment.expiresAtUtc.microsecondsSinceEpoch,
        revision: Value(adjustment.revision),
        targetSiblingBlockIdsJson: Value(
          jsonEncode(adjustment.targetSiblingBlockIds.toList()..sort()),
        ),
        previewId: Value(adjustment.previewId),
        appliedPlanVersionId: Value(adjustment.appliedPlanVersionId),
        failureCode: Value(adjustment.failureCode?.name),
      );

  d.PlanAdjustment _adjustment(db.PlanAdjustment row) => d.PlanAdjustment(    adjustmentId: row.adjustmentId,
    kind: d.PlanAdjustmentKind.values.byName(row.kind),
    targetBlockId: row.targetBlockId,
    targetTaskId: row.targetTaskId,
    targetTitleSnapshot: row.targetTitleSnapshot,
    basePlanVersionId: row.basePlanVersionId,
    sourceStartUtc: _utc(row.sourceStartUtc),
    sourceEndUtc: _utc(row.sourceEndUtc),
    notBeforeUtc: _utc(row.notBeforeUtc),
    timeZoneId: row.timeZoneId,
    requestedAmount: row.requestedAmount,
    requestedUnit: d.DeferUnit.values.byName(row.requestedUnit),
    status: d.PlanAdjustmentStatus.values.byName(row.status),
    createdAtUtc: _utc(row.createdAtUtc),
    expiresAtUtc: _utc(row.expiresAtUtc),
    revision: row.revision,
    targetSiblingBlockIds: (jsonDecode(row.targetSiblingBlockIdsJson)
            as List<Object?>)
        .whereType<String>(),
    previewId: row.previewId,
    appliedPlanVersionId: row.appliedPlanVersionId,
    failureCode: row.failureCode == null
        ? null
        : d.PlanAdjustmentFailureCode.values.byName(row.failureCode!),
  );
}

