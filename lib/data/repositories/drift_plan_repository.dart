import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class DriftPlanRepository
    implements
        PlanStore,
        PlanBlockHistory,
        PlanTransactionApplier,
        PlanAdjustmentTransactionApplier {
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
    final allVersions = await _database.select(versions).get();
    final versionTimes = {
      for (final version in allVersions) version.id: version.createdAtUtc,
    };
    final frozen = <String>{};
    for (final fragment
        in await _database.select(_database.executionFragments).get()) {
      if (fragment.state == 'started' || fragment.state == 'completed') {
        frozen.add('${fragment.planVersionId}|${fragment.blockId}');
      }
    }
    DateTime? nextVersionInstant(String versionId) {
      final current = versionTimes[versionId];
      if (current == null) return null;
      int? next;
      for (final value in versionTimes.values) {
        if (value > current && (next == null || value < next)) next = value;
      }
      return next == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(next, isUtc: true);
    }

    return [
      for (final row in rows)
        if (row.readTableOrNull(blocks) case final block?)
          if (row.readTableOrNull(versions) case final version?)
            if (_keepHistoricalBlock(
              block: block,
              nextVersionUtc: nextVersionInstant(version.id),
              frozen: frozen.contains('${version.id}|${block.id}'),
            ))
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

  bool _keepHistoricalBlock({
    required ScheduleBlock block,
    required DateTime? nextVersionUtc,
    required bool frozen,
  }) {
    if (frozen || nextVersionUtc == null) return true;
    final endUtc = DateTime.fromMicrosecondsSinceEpoch(
      block.endAtUtc,
      isUtc: true,
    );
    // 新版本生效前已经结束的块是当时的历史事实；生效后才发生的旧块不保留。
    return !endUtc.isAfter(nextVersionUtc);
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
  ) => applyProposalWithSideEffects(
    proposal,
    expectedInputHash,
    onApplied: (_) async {},
  );

  @override
  Future<ApplyPlanResult> applyProposalWithSideEffects(
    ScheduleProposal proposal,
    String expectedInputHash, {
    required Future<void> Function(ConfirmedPlan plan) onApplied,
  }) async {
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
      // 执行来源关联与计划写入同事务：关联失败时计划也必须回滚（规范 §19.4）。
      await onApplied(plan);
      return ApplyPlanResult.applied(plan);
    });
  }

  // ── 调整的原子应用与精确撤销（计划 Task 10/11）──────────────────────────────

  /// 单事务应用一份调整提案。
  ///
  /// 固定顺序（计划 Task 10 Step 4）：读回执 → 读 adjustment/preview/当前计划 →
  /// 校验完整令牌与 TTL → CAS `previewReady -> applying` → 旧计划 supersede →
  /// 新计划 + 块 + 变更日志 → preview `accepted` → adjustment `applied` + 事件 →
  /// 应用回执 + 撤销快照 + outbox。任一步失败整体回滚。
  @override
  Future<AdjustmentApplyReceipt> applyAdjustmentProposal({
    required AdjustmentApplyCommand command,
    required ScheduleProposal proposal,
    required DateTime nowUtc,
  }) async {
    final tokenHash = _applyTokenHash(command);
    final nowMicros = nowUtc.microsecondsSinceEpoch;
    return _database.transaction(() async {
      final existingReceipt = await _applyReceiptByToken(tokenHash);
      if (existingReceipt != null) {
        return AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.alreadyApplied,
          planVersionId: existingReceipt.planVersionId,
          undoReceiptId: existingReceipt.undoReceiptId,
        );
      }
      final adjustmentRow = await _adjustmentRow(command.adjustmentId);
      if (adjustmentRow == null) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.notFound,
          reasonCode: 'adjustmentNotFound',
        );
      }
      final receiptByAdjustment = await _applyReceiptByAdjustment(
        command.adjustmentId,
      );
      if (receiptByAdjustment != null) {
        return AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.alreadyApplied,
          planVersionId: receiptByAdjustment.planVersionId,
          undoReceiptId: receiptByAdjustment.undoReceiptId,
        );
      }
      if (adjustmentRow.status != 'previewReady' ||
          adjustmentRow.revision != command.adjustmentRevision ||
          adjustmentRow.basePlanVersionId != command.basePlanVersionId ||
          adjustmentRow.previewId != command.previewId) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.concurrentModification,
          reasonCode: 'adjustmentTokenMismatch',
        );
      }
      final previewRow = await _previewRow(command.previewId);
      if (previewRow == null) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.stale,
          reasonCode: 'previewMissing',
        );
      }
      if (previewRow.status != 'active') {
        return AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.stale,
          reasonCode: 'preview${previewRow.status}',
        );
      }
      if (previewRow.operationId != command.adjustmentId ||
          previewRow.proposalSha256 != command.contentHash ||
          previewRow.basePlanVersionId != command.basePlanVersionId ||
          previewRow.revision != command.previewRevision) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.stale,
          reasonCode: 'previewTokenMismatch',
        );
      }
      if (previewRow.expiresAtUtc <= nowMicros) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.stale,
          reasonCode: 'previewExpired',
        );
      }
      if (proposal.proposalId != command.proposalId ||
          proposal.inputHash != command.inputHash ||
          proposal.algorithmVersion != command.algorithmVersion) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.stale,
          reasonCode: 'proposalTokenMismatch',
        );
      }
      final base = await current();
      if (base == null || base.id != command.basePlanVersionId) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.stale,
          reasonCode: 'basePlanChanged',
        );
      }
      // CAS `previewReady -> applying`：条件更新交给 SQLite，两个连接只有一个能写。
      final claimed =
          await (_database.update(_database.planAdjustments)..where(
                (row) =>
                    row.adjustmentId.equals(command.adjustmentId) &
                    row.revision.equals(command.adjustmentRevision) &
                    row.basePlanVersionId.equals(command.basePlanVersionId) &
                    row.status.equals('previewReady'),
              ))
              .write(const PlanAdjustmentsCompanion(status: Value('applying')));
      if (claimed != 1) {
        return const AdjustmentApplyReceipt(
          status: AdjustmentApplyStatus.concurrentModification,
          reasonCode: 'casLost',
        );
      }
      final baselineBlocksJson = _encodeBlocks(base.blocks);
      final plan = await _writePlanVersion(
        id: proposal.proposalId,
        inputHash: proposal.inputHash,
        algorithmVersion: proposal.algorithmVersion,
        blocks: proposal.blocks,
        nowUtc: nowUtc,
        summaryJson: jsonEncode({
          'operation': 'deferAdjustment',
          'adjustmentId': command.adjustmentId,
          'basePlanVersionId': command.basePlanVersionId,
        }),
        changePrefix: 'adjustment',
      );
      await (_database.update(_database.pendingPlanPreviews)
            ..where((row) => row.previewId.equals(command.previewId)))
          .write(const PendingPlanPreviewsCompanion(status: Value('accepted')));
      final appliedCount =
          await (_database.update(_database.planAdjustments)..where(
                (row) =>
                    row.adjustmentId.equals(command.adjustmentId) &
                    row.status.equals('applying'),
              ))
              .write(
                PlanAdjustmentsCompanion(
                  status: const Value('applied'),
                  appliedPlanVersionId: Value(plan.id),
                  failureCode: const Value(null),
                ),
              );
      if (appliedCount != 1) {
        throw StateError('调整在 applying 期间被并发改写；整个应用事务回滚。');
      }
      await _appendAdjustmentEvent(
        adjustmentId: command.adjustmentId,
        fromStatus: 'applying',
        toStatus: 'applied',
        revision: command.adjustmentRevision,
        occurredAtUtc: nowUtc,
        reasonCode: null,
      );
      final receiptId = '${command.adjustmentId}:apply';
      final undoReceiptId = '${command.adjustmentId}:undo';
      await _database
          .into(_database.planAdjustmentApplyReceipts)
          .insert(
            PlanAdjustmentApplyReceiptsCompanion.insert(
              receiptId: receiptId,
              adjustmentId: command.adjustmentId,
              tokenHash: tokenHash,
              planVersionId: plan.id,
              undoReceiptId: undoReceiptId,
              createdAtUtc: nowMicros,
            ),
          );
      await _database
          .into(_database.planAdjustmentUndoReceipts)
          .insert(
            PlanAdjustmentUndoReceiptsCompanion.insert(
              receiptId: undoReceiptId,
              adjustmentId: command.adjustmentId,
              baselinePlanVersionId: command.basePlanVersionId,
              appliedPlanVersionId: plan.id,
              state: 'available',
              baselineBlocksJson: baselineBlocksJson,
              appliedBlockIdsJson: jsonEncode([
                for (final block in plan.blocks) block.id,
              ]),
              createdAtUtc: nowMicros,
            ),
          );
      await _enqueueOutbox(
        planVersionId: plan.id,
        nowUtc: nowUtc,
        operation: 'deferAdjustment',
      );
      return AdjustmentApplyReceipt(
        status: AdjustmentApplyStatus.applied,
        planVersionId: plan.id,
        undoReceiptId: undoReceiptId,
      );
    });
  }

  /// 精确撤销：只有"当前 confirmed 计划正好是本次 applied 版本"且没有任何块开始
  /// 执行时才允许自动恢复（DFR-017/021）。
  @override
  Future<PlanUndoResult> undoAdjustment({
    required String adjustmentId,
    required DateTime nowUtc,
  }) async {
    final nowMicros = nowUtc.microsecondsSinceEpoch;
    return _database.transaction(() async {
      final undoRow =
          await (_database.select(_database.planAdjustmentUndoReceipts)
                ..where((row) => row.adjustmentId.equals(adjustmentId)))
              .getSingleOrNull();
      if (undoRow == null) {
        return const PlanUndoResult(status: PlanUndoStatus.notFound);
      }
      if (undoRow.state == 'completed') {
        return const PlanUndoResult(status: PlanUndoStatus.alreadyUndone);
      }
      final confirmed = await current();
      if (confirmed == null || confirmed.id != undoRow.appliedPlanVersionId) {
        return const PlanUndoResult(
          status: PlanUndoStatus.supersededByAnotherPlan,
          reasonCode: 'currentPlanChanged',
        );
      }
      // 执行证据：已开始的实例或已开始/完成的片段都不允许自动撤销。
      final startedOccurrences =
          await (_database.select(_database.executionOccurrences)..where(
                (row) =>
                    (row.originPlanVersionId.equals(
                          undoRow.appliedPlanVersionId,
                        ) |
                        row.currentPlanVersionId.equals(
                          undoRow.appliedPlanVersionId,
                        )) &
                    row.firstStartEvidenceId.isNotNull(),
              ))
              .get();
      final startedFragments =
          await (_database.select(_database.executionFragments)..where(
                (row) =>
                    row.planVersionId.equals(undoRow.appliedPlanVersionId) &
                    row.state.isIn(['started', 'completed']),
              ))
              .get();
      if (startedOccurrences.isNotEmpty || startedFragments.isNotEmpty) {
        await (_database.update(
          _database.planAdjustmentUndoReceipts,
        )..where((row) => row.receiptId.equals(undoRow.receiptId))).write(
          const PlanAdjustmentUndoReceiptsCompanion(state: Value('blocked')),
        );
        return const PlanUndoResult(
          status: PlanUndoStatus.executionAlreadyStarted,
          reasonCode: 'executionStarted',
        );
      }
      final baselineVersion =
          await (_database.select(_database.planVersions)
                ..where((row) => row.id.equals(undoRow.baselinePlanVersionId)))
              .getSingleOrNull();
      final restoreId = 'undo-$nowMicros-${adjustmentId.replaceAll(':', '-')}';
      final baselineBlocks = _decodeBlocks(undoRow.baselineBlocksJson);
      final restored = await _writePlanVersion(
        id: restoreId,
        inputHash: baselineVersion?.inputHash ?? confirmed.inputHash,
        algorithmVersion:
            baselineVersion?.algorithmVersion ?? confirmed.algorithmVersion,
        blocks: baselineBlocks,
        nowUtc: nowUtc,
        summaryJson: jsonEncode({
          'operation': 'undoAdjustment',
          'adjustmentId': adjustmentId,
          'restoredFrom': undoRow.baselinePlanVersionId,
          'replaced': undoRow.appliedPlanVersionId,
        }),
        changePrefix: 'undo',
      );
      // 未开始的当前关联重新指向恢复版本；执行证据只重定向，不删除。
      await (_database.update(_database.executionOccurrences)..where(
            (row) =>
                row.currentPlanVersionId.equals(undoRow.appliedPlanVersionId),
          ))
          .write(
            ExecutionOccurrencesCompanion(
              currentPlanVersionId: Value(restored.id),
            ),
          );
      await (_database.update(_database.executionFragments)..where(
            (row) =>
                row.planVersionId.equals(undoRow.appliedPlanVersionId) &
                row.state.equals('planned'),
          ))
          .write(
            ExecutionFragmentsCompanion(planVersionId: Value(restored.id)),
          );
      await (_database.update(
        _database.planAdjustmentUndoReceipts,
      )..where((row) => row.receiptId.equals(undoRow.receiptId))).write(
        PlanAdjustmentUndoReceiptsCompanion(
          state: const Value('completed'),
          completedAtUtc: Value(nowMicros),
        ),
      );
      await _enqueueOutbox(
        planVersionId: restored.id,
        nowUtc: nowUtc,
        operation: 'undoAdjustment',
      );
      return PlanUndoResult(
        status: PlanUndoStatus.undone,
        planVersionId: restored.id,
      );
    });
  }

  // ── 内部：调整事务 ────────────────────────────────────────────────────────

  Future<PlanAdjustment?> _adjustmentRow(String adjustmentId) =>
      (_database.select(_database.planAdjustments)
            ..where((row) => row.adjustmentId.equals(adjustmentId)))
          .getSingleOrNull();

  Future<PendingPlanPreview?> _previewRow(String previewId) =>
      (_database.select(
        _database.pendingPlanPreviews,
      )..where((row) => row.previewId.equals(previewId))).getSingleOrNull();

  Future<PlanAdjustmentApplyReceipt?> _applyReceiptByToken(String tokenHash) =>
      (_database.select(
        _database.planAdjustmentApplyReceipts,
      )..where((row) => row.tokenHash.equals(tokenHash))).getSingleOrNull();

  Future<PlanAdjustmentApplyReceipt?> _applyReceiptByAdjustment(
    String adjustmentId,
  ) => (_database.select(
    _database.planAdjustmentApplyReceipts,
  )..where((row) => row.adjustmentId.equals(adjustmentId))).getSingleOrNull();

  String _applyTokenHash(AdjustmentApplyCommand command) => sha256
      .convert(
        utf8.encode(
          [
            command.adjustmentId,
            command.adjustmentRevision,
            command.previewId,
            command.previewRevision,
            command.proposalId,
            command.contentHash,
            command.basePlanVersionId,
            command.inputHash,
            command.algorithmVersion,
          ].join('|'),
        ),
      )
      .toString();

  Future<void> _appendAdjustmentEvent({
    required String adjustmentId,
    required String fromStatus,
    required String toStatus,
    required int revision,
    required DateTime occurredAtUtc,
    required String? reasonCode,
  }) async {
    final last =
        await (_database.select(_database.planAdjustmentEvents)
              ..where((row) => row.adjustmentId.equals(adjustmentId))
              ..orderBy([(row) => OrderingTerm.desc(row.sequence)])
              ..limit(1))
            .getSingleOrNull();
    await _database
        .into(_database.planAdjustmentEvents)
        .insert(
          PlanAdjustmentEventsCompanion.insert(
            adjustmentId: adjustmentId,
            sequence: (last?.sequence ?? 0) + 1,
            fromStatus: fromStatus,
            toStatus: toStatus,
            revision: revision,
            occurredAtUtc: occurredAtUtc.microsecondsSinceEpoch,
            reasonCode: Value(reasonCode),
          ),
        );
  }

  Future<ConfirmedPlan> _writePlanVersion({
    required String id,
    required String inputHash,
    required String algorithmVersion,
    required List<PlannedBlock> blocks,
    required DateTime nowUtc,
    required String summaryJson,
    required String changePrefix,
  }) async {
    final nowMicros = nowUtc.microsecondsSinceEpoch;
    await (_database.update(_database.planVersions)
          ..where((row) => row.status.equals('confirmed')))
        .write(const PlanVersionsCompanion(status: Value('superseded')));
    await _database
        .into(_database.planVersions)
        .insert(
          PlanVersionsCompanion.insert(
            id: id,
            createdAtUtc: nowMicros,
            inputHash: inputHash,
            algorithmVersion: algorithmVersion,
            status: 'confirmed',
            summaryJson: summaryJson,
          ),
        );
    final persisted = <PlannedBlock>[];
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      final persistedId = '$id:${block.id}';
      await _database
          .into(_database.scheduleBlocks)
          .insert(
            ScheduleBlocksCompanion.insert(
              id: persistedId,
              planVersionId: id,
              taskId: block.taskId,
              startAtUtc: block.startUtc.microsecondsSinceEpoch,
              endAtUtc: block.endUtc.microsecondsSinceEpoch,
              locked: Value(block.locked),
              explanationCode: block.explanationCode ?? 'scheduled',
              createdAtUtc: Value(nowMicros),
              updatedAtUtc: Value(nowMicros),
            ),
          );
      await _database
          .into(_database.changeLog)
          .insert(
            ChangeLogCompanion.insert(
              id: '$id:change:${index + 1}',
              entityType: 'scheduleBlock',
              entityId: persistedId,
              operation: '$changePrefix:create',
              changedAtUtc: nowMicros,
              revision: 1,
            ),
          );
      persisted.add(
        PlannedBlock(
          id: persistedId,
          taskId: block.taskId,
          range: block.range,
          locked: block.locked,
          explanationCode: block.explanationCode ?? 'scheduled',
        ),
      );
    }
    await _database
        .into(_database.changeLog)
        .insert(
          ChangeLogCompanion.insert(
            id: '$id:change:0',
            entityType: 'planVersion',
            entityId: id,
            operation: changePrefix,
            changedAtUtc: nowMicros,
            revision: 1,
          ),
        );
    return ConfirmedPlan(
      id: id,
      inputHash: inputHash,
      algorithmVersion: algorithmVersion,
      blocks: persisted,
    );
  }

  Future<void> _enqueueOutbox({
    required String planVersionId,
    required DateTime nowUtc,
    required String operation,
  }) async {
    final micros = nowUtc.microsecondsSinceEpoch;
    await _database
        .into(_database.planChangeOutbox)
        .insert(
          PlanChangeOutboxCompanion.insert(
            id: 'planChanged:$planVersionId',
            dedupeKey: 'planChanged:$planVersionId',
            kind: 'planChanged',
            payloadJson: Value(
              jsonEncode({
                'planVersionId': planVersionId,
                'operation': operation,
              }),
            ),
            nextAttemptAtUtc: micros,
            createdAtUtc: micros,
          ),
        );
  }

  String _encodeBlocks(List<PlannedBlock> blocks) => jsonEncode([
    for (final block in blocks)
      {
        'taskId': block.taskId,
        'start': block.startUtc.microsecondsSinceEpoch,
        'end': block.endUtc.microsecondsSinceEpoch,
        'locked': block.locked,
        'explanationCode': block.explanationCode,
      },
  ]);

  List<PlannedBlock> _decodeBlocks(String json) {
    final raw = jsonDecode(json);
    if (raw is! List) return const [];
    return [
      for (final item in raw.whereType<Map<String, Object?>>())
        PlannedBlock(
          id: 'restored:${item['taskId']}:${item['start']}',
          taskId: item['taskId']! as String,
          range: TimeRange(
            startUtc: DateTime.fromMicrosecondsSinceEpoch(
              (item['start']! as num).toInt(),
              isUtc: true,
            ),
            endUtc: DateTime.fromMicrosecondsSinceEpoch(
              (item['end']! as num).toInt(),
              isUtc: true,
            ),
          ),
          locked: item['locked'] == true,
          explanationCode: item['explanationCode'] as String?,
        ),
    ];
  }
}
