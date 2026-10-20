// 1.11.0（计划 Task 10/11）：调整的单事务应用、幂等回执与精确撤销。
//
// 这些用例在**真实内存 Drift 库**上运行：回执、预览状态、计划版本、块、outbox 与
// 撤销快照都必须在同一个事务里出现或一起消失。
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/repositories/drift_pending_plan_preview_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_adjustment_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/schedule_proposal_codec.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftPlanRepository plans;
  late DriftPlanAdjustmentRepository adjustments;
  late DriftPendingPlanPreviewRepository previews;
  const codec = ScheduleProposalCodec();

  final start = DateTime.utc(2026, 10, 19, 2);
  final shifted = DateTime.utc(2026, 10, 19, 2, 10);

  ScheduleProposal proposal({
    required String id,
    required String inputHash,
    required DateTime blockStart,
  }) => ScheduleProposal(
    proposalId: id,
    inputHash: inputHash,
    algorithmVersion: '20',
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 19),
      endUtc: DateTime.utc(2026, 10, 26),
    ),
    blocks: [
      PlannedBlock(
        id: 'block-1',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: blockStart,
          endUtc: blockStart.add(const Duration(minutes: 90)),
        ),
      ),
    ],
    unscheduled: const [],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: true,
      scheduledMinutes: 90,
      unscheduledMinutes: 0,
    ),
  );

  final baseProposal = proposal(
    id: 'base-1',
    inputHash: 'hash-base',
    blockStart: start,
  );
  final adjustedProposal = proposal(
    id: 'adj-prop-1',
    inputHash: 'hash-adj',
    blockStart: shifted,
  );

  Future<int> count(String table) async {
    final row = await harness.database
        .customSelect('SELECT COUNT(*) AS c FROM $table')
        .getSingle();
    return row.read<int>('c');
  }

  AdjustmentApplyCommand command({String? contentHash}) =>
      AdjustmentApplyCommand(
        adjustmentId: 'adj-1',
        adjustmentRevision: 1,
        previewId: 'preview-1',
        previewRevision: 1,
        proposalId: 'adj-prop-1',
        contentHash: contentHash ?? codec.sha256OfCanonical(adjustedProposal),
        basePlanVersionId: 'base-1',
        inputHash: 'hash-adj',
        algorithmVersion: '20',
      );

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    plans = DriftPlanRepository(harness.database, clock: harness.clock);
    adjustments = DriftPlanAdjustmentRepository(
      harness.database,
      clock: harness.clock,
    );
    previews = DriftPendingPlanPreviewRepository(
      harness.database,
      clock: harness.clock,
    );
    final applied = await plans.applyProposal(baseProposal, 'hash-base');
    expect(applied.status, ApplyPlanStatus.applied);

    final now = harness.clock.nowUtc();
    await adjustments.create(
      PlanAdjustment(
        adjustmentId: 'adj-1',
        kind: PlanAdjustmentKind.defer,
        targetBlockId: 'block-1',
        targetTaskId: 'task-1',
        targetTitleSnapshot: '写周报',
        basePlanVersionId: 'base-1',
        sourceStartUtc: start,
        sourceEndUtc: start.add(const Duration(minutes: 90)),
        notBeforeUtc: shifted,
        timeZoneId: 'Asia/Shanghai',
        requestedAmount: 10,
        requestedUnit: DeferUnit.minutes,
        status: PlanAdjustmentStatus.previewReady,
        createdAtUtc: now,
        expiresAtUtc: now.add(const Duration(hours: 12)),
        revision: 1,
        previewId: 'preview-1',
      ),
    );
    await previews.saveActive(
      PendingPreviewBundle(
        preview: PendingPlanPreview(
          previewId: 'preview-1',
          kind: PendingPreviewKind.deferAdjustment,
          operationId: 'adj-1',
          basePlanVersionId: 'base-1',
          inputHash: 'hash-adj',
          algorithmVersion: '20',
          windowStartUtc: DateTime.utc(2026, 10, 19),
          windowEndUtc: DateTime.utc(2026, 10, 26),
          timeZoneId: 'Asia/Shanghai',
          status: PendingPreviewStatus.active,
          createdAtUtc: now,
          expiresAtUtc: now.add(const Duration(hours: 12)),
          summaryJson: '{}',
          diagnosticsJson: '{}',
          revision: 1,
          proposalJson: codec.encodeCanonical(adjustedProposal),
          proposalSha256: codec.sha256OfCanonical(adjustedProposal),
        ),
        blocks: [
          PendingPlanPreviewBlock(
            previewId: 'preview-1',
            blockId: 'block-1',
            taskId: 'task-1',
            cycleId: null,
            title: '写周报',
            startUtc: shifted,
            endUtc: shifted.add(const Duration(minutes: 90)),
            explanationCode: 'deferAdjustment',
            minutes: 90,
          ),
        ],
      ),
    );
  });

  tearDown(() => harness.close());

  group('原子应用', () {
    test('应用后计划、预览、调整、回执、撤销快照与 outbox 同时落库', () async {
      final receipt = await plans.applyAdjustmentProposal(
        command: command(),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );

      expect(receipt.status, AdjustmentApplyStatus.applied);
      expect(receipt.planVersionId, 'adj-prop-1');
      final current = await plans.current();
      expect(current!.id, 'adj-prop-1');
      final block = current.blocks.single;
      expect(block.startUtc, shifted);
      expect(block.id, 'adj-prop-1:block-1');

      final adjustment = await adjustments.byId('adj-1');
      expect(adjustment!.status, PlanAdjustmentStatus.applied);
      expect(adjustment.appliedPlanVersionId, 'adj-prop-1');
      expect(
        (await previews.byId('preview-1'))!.status,
        PendingPreviewStatus.accepted,
      );

      expect(await count('plan_adjustment_apply_receipts'), 1);
      expect(await count('plan_adjustment_undo_receipts'), 1);
      expect(await count('plan_change_outbox'), 1);
      final events = await adjustments.events('adj-1');
      expect(events.last.toStatus, PlanAdjustmentStatus.applied);
    });

    test('同一完整令牌重复确认返回 alreadyApplied 与同一计划，不建第二个版本', () async {
      final first = await plans.applyAdjustmentProposal(
        command: command(),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );
      final second = await plans.applyAdjustmentProposal(
        command: command(),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );

      expect(second.status, AdjustmentApplyStatus.alreadyApplied);
      expect(second.planVersionId, first.planVersionId);
      expect(second.undoReceiptId, first.undoReceiptId);
      expect(await count('plan_versions'), 2);
      expect(await count('plan_adjustment_apply_receipts'), 1);
    });

    test('contentHash 不匹配返回 stale，计划与调整逐值不变', () async {
      final receipt = await plans.applyAdjustmentProposal(
        command: command(contentHash: List.filled(64, 'f').join()),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );

      expect(receipt.status, AdjustmentApplyStatus.stale);
      expect((await plans.current())!.id, 'base-1');
      expect(
        (await adjustments.byId('adj-1'))!.status,
        PlanAdjustmentStatus.previewReady,
      );
      expect(await count('plan_adjustment_apply_receipts'), 0);
      expect(await count('plan_change_outbox'), 0);
    });

    test('调整 revision 不匹配返回 concurrentModification 且零写入', () async {
      final receipt = await plans.applyAdjustmentProposal(
        command: AdjustmentApplyCommand(
          adjustmentId: 'adj-1',
          adjustmentRevision: 2,
          previewId: 'preview-1',
          previewRevision: 1,
          proposalId: 'adj-prop-1',
          contentHash: codec.sha256OfCanonical(adjustedProposal),
          basePlanVersionId: 'base-1',
          inputHash: 'hash-adj',
          algorithmVersion: '20',
        ),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );

      expect(receipt.status, AdjustmentApplyStatus.concurrentModification);
      expect((await plans.current())!.id, 'base-1');
      expect(await count('plan_adjustment_apply_receipts'), 0);
    });

    test('基线已变返回 stale', () async {
      await plans.applyProposal(
        proposal(id: 'other-1', inputHash: 'hash-other', blockStart: start),
        'hash-other',
      );

      final receipt = await plans.applyAdjustmentProposal(
        command: command(),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );

      expect(receipt.status, AdjustmentApplyStatus.stale);
      expect((await plans.current())!.id, 'other-1');
    });
  });

  group('精确撤销', () {
    Future<void> apply() async {
      final receipt = await plans.applyAdjustmentProposal(
        command: command(),
        proposal: adjustedProposal,
        nowUtc: harness.clock.nowUtc(),
      );
      expect(receipt.status, AdjustmentApplyStatus.applied);
    }

    test('未开始时撤销恢复基线块、关联与历史版本', () async {
      await apply();
      // 一个**未开始**的 occurrence 及其块关联：撤销后应新增指向恢复版本的行，
      // 旧行保留（历史证据不删除）。
      await harness.database.customInsert(
        "INSERT INTO execution_occurrences ("
        "id, task_id, origin_plan_version_id, baseline_start_utc, "
        "baseline_end_utc, baseline_time_zone_id, baseline_local_date, "
        "baseline_planned_duration_micros, current_plan_version_id, "
        "allocated_micros, remaining_allocation_micros, lifecycle_state, "
        "privacy_state, created_at_utc) VALUES ('occ-2', 'task-1', "
        "'adj-prop-1', 0, 1, 'UTC', '2026-10-19', 5400000000, 'adj-prop-1', "
        "5400000000, 5400000000, 'planned', 'linked', 0)",
      );
      await harness.database.customInsert(
        "INSERT INTO execution_block_links (data_epoch, plan_version_id, "
        "block_id, occurrence_id, source_block_id, reserved_micros, "
        "created_at_utc) VALUES ('e1', 'adj-prop-1', 'adj-prop-1:block-1', "
        "'occ-2', NULL, 5400000000, 0)",
      );

      final undo = await plans.undoAdjustment(
        adjustmentId: 'adj-1',
        nowUtc: harness.clock.nowUtc(),
      );

      expect(undo.status, PlanUndoStatus.undone);
      final restored = await plans.current();
      expect(restored!.id, undo.planVersionId);
      expect(restored.blocks.single.startUtc, start);
      expect(restored.blocks.single.taskId, 'task-1');
      expect(await count('plan_versions'), 3);
      final undoRow = await harness.database
          .customSelect(
            "SELECT state FROM plan_adjustment_undo_receipts WHERE adjustment_id = 'adj-1'",
          )
          .getSingle();
      expect(undoRow.read<String>('state'), 'completed');
      final restoredLinks = await harness.database
          .customSelect(
            'SELECT COUNT(*) AS c FROM execution_block_links '
            'WHERE plan_version_id = ?',
            variables: [Variable.withString(restored.id)],
          )
          .getSingle();
      expect(restoredLinks.read<int>('c'), 1, reason: '未开始的关联要指向恢复版本');
      final appliedLinks = await harness.database
          .customSelect(
            "SELECT COUNT(*) AS c FROM execution_block_links "
            "WHERE plan_version_id = 'adj-prop-1'",
          )
          .getSingle();
      expect(appliedLinks.read<int>('c'), 1, reason: '旧版本的关联行保留，不删除执行证据');
    });

    test('重复撤销返回 alreadyUndone，不创建第二个恢复版本', () async {
      await apply();
      await plans.undoAdjustment(
        adjustmentId: 'adj-1',
        nowUtc: harness.clock.nowUtc(),
      );

      final second = await plans.undoAdjustment(
        adjustmentId: 'adj-1',
        nowUtc: harness.clock.nowUtc(),
      );

      expect(second.status, PlanUndoStatus.alreadyUndone);
      expect(await count('plan_versions'), 3);
    });

    test('已有执行开始事实时阻断撤销，计划与证据零变化', () async {
      await apply();
      await harness.database.customInsert(
        "INSERT INTO execution_occurrences ("
        "id, origin_plan_version_id, baseline_start_utc, baseline_end_utc, "
        "baseline_time_zone_id, baseline_local_date, "
        "baseline_planned_duration_micros, current_plan_version_id, "
        "allocated_micros, remaining_allocation_micros, "
        "first_start_evidence_id, lifecycle_state, privacy_state, "
        "created_at_utc) VALUES ('occ-1', 'adj-prop-1', 0, 1, "
        "'Asia/Shanghai', '2026-10-19', 5400000000, 'adj-prop-1', "
        "5400000000, 5400000000, 'ev-1', 'started', 'linked', 0)",
      );

      final undo = await plans.undoAdjustment(
        adjustmentId: 'adj-1',
        nowUtc: harness.clock.nowUtc(),
      );

      expect(undo.status, PlanUndoStatus.executionAlreadyStarted);
      expect((await plans.current())!.id, 'adj-prop-1');
      expect(await count('plan_versions'), 2);
      final undoRow = await harness.database
          .customSelect(
            "SELECT state FROM plan_adjustment_undo_receipts WHERE adjustment_id = 'adj-1'",
          )
          .getSingle();
      expect(undoRow.read<String>('state'), 'blocked');
    });

    test('应用之后又应用了另一份计划时拒绝跨版本撤销', () async {
      await apply();
      await plans.applyProposal(
        proposal(id: 'other-2', inputHash: 'hash-other-2', blockStart: start),
        'hash-other-2',
      );

      final undo = await plans.undoAdjustment(
        adjustmentId: 'adj-1',
        nowUtc: harness.clock.nowUtc(),
      );

      expect(undo.status, PlanUndoStatus.supersededByAnotherPlan);
      expect((await plans.current())!.id, 'other-2');
    });
  });
}
