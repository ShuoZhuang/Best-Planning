import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/repositories/pending_plan_preview_repository.dart';

/// 通用持久预览仓储（计划 Task 3 Step 5）。
///
/// 周期预排与延后调整共用同一组表；"每个操作一条 active"由
/// `(kind, operation_id)` 的部分唯一索引 + 本类的事务内 supersede 共同保证。
final class DriftPendingPlanPreviewRepository
    implements PendingPlanPreviewRepository {
  DriftPendingPlanPreviewRepository(
    this.database, {
    this.clock = const SystemClock(),
  });

  final db.AppDatabase database;
  final Clock clock;

  static DateTime _utc(int micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

  @override
  Future<PendingPlanPreview?> byId(String previewId) async {
    final row = await (database.select(
      database.pendingPlanPreviews,
    )..where((table) => table.previewId.equals(previewId))).getSingleOrNull();
    return row == null ? null : _preview(row);
  }

  @override
  Future<List<PendingPlanPreviewBlock>> blocks(String previewId) async {
    final query = database.select(database.pendingPlanPreviewBlocks)
      ..where((table) => table.previewId.equals(previewId))
      ..orderBy([(table) => OrderingTerm.asc(table.startUtc)]);
    return [for (final row in await query.get()) _block(row)];
  }

  @override
  Future<PendingPreviewBundle?> active(
    PendingPreviewKind kind, {
    String? operationId,
  }) async {
    final query = database.select(database.pendingPlanPreviews)
      ..where(
        (table) =>
            table.kind.equals(kind.name) &
            table.status.equals(PendingPreviewStatus.active.name),
      )
      ..orderBy([(table) => OrderingTerm.desc(table.createdAtUtc)])
      ..limit(1);
    if (operationId != null) {
      query.where((table) => table.operationId.equals(operationId));
    }
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return PendingPreviewBundle(
      preview: _preview(row),
      blocks: await blocks(row.previewId),
    );
  }

  @override
  Future<void> saveActive(PendingPreviewBundle bundle) async {
    await database.transaction(() async {
      // 只 supersede **同一操作**的旧预览：两个独立调整互不影响（DFR-004）。
      await (database.update(database.pendingPlanPreviews)..where(
            (table) =>
                table.kind.equals(bundle.preview.kind.name) &
                table.operationId.equals(bundle.preview.operationId) &
                table.status.equals(PendingPreviewStatus.active.name),
          ))
          .write(
            db.PendingPlanPreviewsCompanion(
              status: Value(PendingPreviewStatus.superseded.name),
              revision: const Value(2),
            ),
          );
      await database
          .into(database.pendingPlanPreviews)
          .insert(
            db.PendingPlanPreviewsCompanion.insert(
              previewId: bundle.preview.previewId,
              kind: bundle.preview.kind.name,
              operationId: Value(bundle.preview.operationId),
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
              proposalJson: Value(bundle.preview.proposalJson),
              proposalSha256: Value(bundle.preview.proposalSha256),
              formatVersion: Value(bundle.preview.formatVersion),
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

  @override
  Future<void> updateStatus(
    String previewId,
    PendingPreviewStatus status,
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

  @override
  Future<void> expireBefore(DateTime nowUtc) async {
    await (database.update(database.pendingPlanPreviews)..where(
          (table) =>
              table.status.equals(PendingPreviewStatus.active.name) &
              table.expiresAtUtc.isSmallerOrEqualValue(
                nowUtc.microsecondsSinceEpoch,
              ),
        ))
        .write(
          db.PendingPlanPreviewsCompanion(
            status: Value(PendingPreviewStatus.stale.name),
            revision: const Value(2),
          ),
        );
  }

  @override
  Future<void> cleanup({
    required DateTime nowUtc,
    int retainDays = 30,
    int maxTerminalPerKind = 100,
  }) async {
    final cutoff = nowUtc.subtract(Duration(days: retainDays));
    await database.transaction(() async {
      // ① 先按时间清掉过期终态。
      await (database.delete(database.pendingPlanPreviews)..where(
            (table) =>
                table.status.isNotIn([
                  PendingPreviewStatus.active.name,
                  PendingPreviewStatus.accepted.name,
                ]) &
                table.createdAtUtc.isSmallerThanValue(
                  cutoff.microsecondsSinceEpoch,
                ),
          ))
          .go();
      // ② 每种终态最多保留最近 N 条，防止 100 条上限之后的新记录把库里塞满。
      for (final kind in PendingPreviewKind.values) {
        final terminal =
            await (database.select(database.pendingPlanPreviews)
                  ..where(
                    (table) =>
                        table.kind.equals(kind.name) &
                        table.status.isNotIn([
                          PendingPreviewStatus.active.name,
                          PendingPreviewStatus.accepted.name,
                        ]),
                  )
                  ..orderBy([(table) => OrderingTerm.desc(table.createdAtUtc)]))
                .get();
        final stale = terminal.skip(maxTerminalPerKind).toList();
        if (stale.isEmpty) continue;
        final ids = [for (final row in stale) row.previewId];
        await (database.delete(
          database.pendingPlanPreviews,
        )..where((table) => table.previewId.isIn(ids))).go();
      }
    });
  }

  PendingPlanPreview _preview(db.PendingPlanPreview row) => PendingPlanPreview(
    previewId: row.previewId,
    kind: PendingPreviewKind.values.byName(row.kind),
    operationId: row.operationId,
    basePlanVersionId: row.basePlanVersionId,
    inputHash: row.inputHash,
    algorithmVersion: row.algorithmVersion,
    windowStartUtc: _utc(row.windowStartUtc),
    windowEndUtc: _utc(row.windowEndUtc),
    timeZoneId: row.timeZoneId,
    status: PendingPreviewStatus.values.byName(row.status),
    createdAtUtc: _utc(row.createdAtUtc),
    expiresAtUtc: _utc(row.expiresAtUtc),
    summaryJson: row.summaryJson,
    diagnosticsJson: row.diagnosticsJson,
    revision: row.revision,
    proposalJson: row.proposalJson,
    proposalSha256: row.proposalSha256,
    formatVersion: row.formatVersion,
  );

  PendingPlanPreviewBlock _block(db.PendingPlanPreviewBlock row) =>
      PendingPlanPreviewBlock(
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
