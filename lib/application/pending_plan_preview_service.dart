import 'dart:convert';

import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 待确认预排的生成、持久化、拒绝与确认（1.11.0 周期预排 Task 11/12）。
///
/// 预排只写自己的表，不创建正式 occurrence、提醒或普通任务；确认时再走正式
/// [PlanApplicationService]，因此正式计划仍只有一条写入路径。
final class PendingPlanPreviewService {
  PendingPlanPreviewService({
    required this.repository,
    required this.plans,
    required this.clock,
    required this.idGenerator,
    this.application,
    this.titleForTask,
    this.applyProposal,
  });

  final DriftRecurringExecutionRepository repository;
  final PlanRepository plans;
  final Clock clock;
  final IdGenerator idGenerator;

  /// 生产组合根传入拥有真实 `ScheduleProblemSource` 的应用服务。
  final PlanApplicationService? application;

  /// 测试替身可在没有完整排程输入时只验证令牌/事务路径。
  final Future<ApplyPlanResult> Function(ScheduleProposal proposal)?
  applyProposal;
  final Future<String?> Function(String taskId)? titleForTask;

  Future<PendingPreviewBundle> saveProposal({
    required ScheduleProposal proposal,
    required String basePlanVersionId,
    required TimeRange window,
    required String timeZoneId,
  }) async {
    final now = clock.nowUtc();
    final previewId = proposal.proposalId;
    final blocks = <PendingPlanPreviewBlock>[];
    for (final block in proposal.blocks) {
      final title = await titleForTask?.call(block.taskId) ?? '周期安排';
      blocks.add(
        PendingPlanPreviewBlock(
          previewId: previewId,
          blockId: block.id,
          taskId: block.taskId,
          cycleId: null,
          title: title,
          startUtc: block.range.startUtc,
          endUtc: block.range.endUtc,
          explanationCode: block.explanationCode ?? 'recurringLookahead',
          minutes: block.range.duration.inMinutes,
        ),
      );
    }
    final bundle = PendingPreviewBundle(
      preview: PendingPlanPreview(
        previewId: previewId,
        kind: PendingPreviewKind.recurringLookahead,
        basePlanVersionId: basePlanVersionId,
        inputHash: proposal.inputHash,
        algorithmVersion: proposal.algorithmVersion,
        windowStartUtc: window.startUtc,
        windowEndUtc: window.endUtc,
        timeZoneId: timeZoneId,
        status: PendingPreviewStatus.active,
        createdAtUtc: now,
        expiresAtUtc: now.add(const Duration(hours: 12)),
        summaryJson: jsonEncode({
          'scheduledMinutes': proposal.metrics.scheduledMinutes,
          'unscheduledMinutes': proposal.metrics.unscheduledMinutes,
        }),
        diagnosticsJson: jsonEncode({
          'conflicts': proposal.conflicts.length,
          'unscheduled': proposal.unscheduled.length,
        }),
        revision: 1,
      ),
      blocks: blocks,
    );
    await repository.replaceActivePreview(bundle);
    return bundle;
  }

  Future<PendingPreviewBundle?> active() =>
      repository.activePreview(PendingPreviewKind.recurringLookahead);

  Future<void> reject(String previewId, {String? reason}) async {
    await repository.updatePreviewStatus(
      previewId,
      PendingPreviewStatus.rejected,
    );
  }

  Future<void> markStale(String previewId) async {
    await repository.updatePreviewStatus(previewId, PendingPreviewStatus.stale);
  }

  /// 确认整份预排。令牌必须逐项匹配；已过期或输入变化时标记 stale，绝不静默应用。
  Future<PreviewApplyResult> confirm({
    required String previewId,
    required String expectedBasePlanVersionId,
    required String expectedInputHash,
    required String expectedAlgorithmVersion,
    required int expectedPreviewRevision,
  }) async {
    final bundle = await _bundle(previewId);
    if (bundle == null) {
      return const PreviewApplyResult(
        status: PreviewApplyStatus.notFound,
        reason: 'previewNotFound',
      );
    }
    final preview = bundle.preview;
    if (!preview.isActive) {
      return PreviewApplyResult(
        status: PreviewApplyStatus.invalid,
        reason: 'preview${preview.status.name}',
      );
    }
    if (preview.basePlanVersionId != expectedBasePlanVersionId ||
        preview.inputHash != expectedInputHash ||
        preview.algorithmVersion != expectedAlgorithmVersion ||
        preview.revision != expectedPreviewRevision) {
      await markStale(previewId);
      return const PreviewApplyResult(
        status: PreviewApplyStatus.stale,
        reason: 'previewTokenMismatch',
      );
    }
    if (!preview.expiresAtUtc.isAfter(clock.nowUtc())) {
      await markStale(previewId);
      return const PreviewApplyResult(
        status: PreviewApplyStatus.stale,
        reason: 'previewExpired',
      );
    }
    final currentPlan = await plans.current();
    if (currentPlan == null || currentPlan.id != expectedBasePlanVersionId) {
      await markStale(previewId);
      return const PreviewApplyResult(
        status: PreviewApplyStatus.stale,
        reason: 'basePlanChanged',
      );
    }
    final proposal = _proposalFrom(bundle);
    final applied = applyProposal != null
        ? await applyProposal!(proposal)
        : await application!.apply(proposal);
    if (applied.status != ApplyPlanStatus.applied) {
      if (applied.status == ApplyPlanStatus.staleProposal) {
        await markStale(previewId);
        return const PreviewApplyResult(
          status: PreviewApplyStatus.stale,
          reason: 'inputChanged',
        );
      }
      return PreviewApplyResult(
        status: PreviewApplyStatus.invalid,
        reason: applied.status.name,
      );
    }
    await repository.updatePreviewStatus(
      previewId,
      PendingPreviewStatus.accepted,
    );
    return PreviewApplyResult(
      status: PreviewApplyStatus.applied,
      planVersionId: applied.plan?.id,
    );
  }

  Future<PendingPreviewBundle?> _bundle(String previewId) async {
    final current = await active();
    if (current != null && current.preview.previewId == previewId) {
      return current;
    }
    final blocks = await repository.previewBlocks(previewId);
    if (blocks.isEmpty) return null;
    final preview = await repository.previewById(previewId);
    if (preview == null) return null;
    return PendingPreviewBundle(preview: preview, blocks: blocks);
  }

  ScheduleProposal _proposalFrom(PendingPreviewBundle bundle) =>
      ScheduleProposal(
        proposalId: bundle.preview.previewId,
        inputHash: bundle.preview.inputHash,
        algorithmVersion: bundle.preview.algorithmVersion,
        planningWindow: TimeRange(
          startUtc: bundle.preview.windowStartUtc,
          endUtc: bundle.preview.windowEndUtc,
        ),
        blocks: [
          for (final block in bundle.blocks)
            if (block.taskId != null)
              PlannedBlock(
                id: block.blockId,
                taskId: block.taskId!,
                range: TimeRange(
                  startUtc: block.startUtc,
                  endUtc: block.endUtc,
                ),
              ),
        ],
        unscheduled: const [],
        conflicts: const [],
        explanations: const [],
        metrics: const ProposalMetrics(
          isFullyFeasible: true,
          scheduledMinutes: 0,
          unscheduledMinutes: 0,
        ),
      );
}
