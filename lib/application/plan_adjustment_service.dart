import 'dart:convert';

import 'package:personal_planner/application/defer_time_policy.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/pending_plan_preview_repository.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/schedule_proposal_codec.dart';

/// 调整专属的排程输入装配端口（计划 Task 5 Step 4）。
///
/// 装配必须**按 adjustment 读取它自己的基线**、把窗口扩到调整有效窗口，并且只给
/// 目标 lineage 加下界。把它做成端口而不是让服务直接拼 `ScheduleProblem`，
/// 是为了让"局部修复看到的输入"与"最终校验看到的输入"来自同一处。
abstract interface class AdjustmentProblemSource {
  Future<ScheduleProblem> loadForAdjustment({
    required PlanAdjustmentToken token,
    required DateTime windowEndUtc,
  });
}

/// 装配层判定"无法继续"的结构化原因；服务把它翻译成调整的终态，不向上抛业务异常。
final class AdjustmentSourceException implements Exception {
  const AdjustmentSourceException(this.code);

  final PlanAdjustmentFailureCode code;

  @override
  String toString() => 'AdjustmentSourceException(${code.name})';
}

/// 开始一次延后的结果（计划 Task 5 Step 2）。
enum BeginDeferStatus {
  created,
  targetMissing,
  targetChanged,
  targetIneligible,
  operationConflict,
  invalidAmount,
}

final class BeginDeferResult {
  const BeginDeferResult({
    required this.status,
    this.adjustment,
    this.failureCode,
  });

  final BeginDeferStatus status;
  final PlanAdjustment? adjustment;
  final PlanAdjustmentFailureCode? failureCode;

  bool get isCreated => status == BeginDeferStatus.created;
}

enum GenerateAdjustmentPreviewStatus {
  previewReady,
  failed,
  stale,
  notFound,
  terminal,
}

final class GenerateAdjustmentPreviewResult {
  const GenerateAdjustmentPreviewResult({
    required this.status,
    this.adjustment,
    this.previewId,
    this.failureCode,
  });

  final GenerateAdjustmentPreviewStatus status;
  final PlanAdjustment? adjustment;
  final String? previewId;
  final PlanAdjustmentFailureCode? failureCode;
}

/// 执行开始事实端口（计划 Task 5 Step 3 的"无执行开始事实"）。
///
/// 默认实现返回空集合，仅用于"确实没有执行事实"的装配（如单元测试）；
/// 生产组合根必须注入真实执行仓储，否则已开始的块仍可能被延后。
abstract interface class AdjustmentExecutionEvidence {
  Future<Set<String>> startedOrCompletedBlockIds(Iterable<String> blockIds);
}

final class NoAdjustmentExecutionEvidence implements AdjustmentExecutionEvidence {
  const NoAdjustmentExecutionEvidence();

  @override
  Future<Set<String>> startedOrCompletedBlockIds(Iterable<String> blockIds) async =>
      const {};
}

/// 「延后本次」的唯一应用服务（计划 Task 5）。
///
/// **它取代 `PendingMoveDrafts._adjustment`**：资格校验、目标快照、下界计算、
/// 生成、重生、取消与恢复都在这里，并且每次状态转换都经仓储 CAS。路由只持有
/// `adjustmentId`，不再缓存任何业务真相。
final class PlanAdjustmentService {
  PlanAdjustmentService({
    required this.plans,
    required this.tasks,
    required this.adjustments,
    required this.previews,
    required this.source,
    required this.engine,
    required this.policy,
    required this.clock,
    required this.ids,
    required this.granularityForDate,
    required this.zones,
    this.executionEvidence = const NoAdjustmentExecutionEvidence(),
    this.codec = const ScheduleProposalCodec(),
    this.previewTtl = const Duration(hours: 12),
    this.defaultWindowDays = 7,
    this.timeZoneId = 'Asia/Shanghai',
  });

  final PlanRepository plans;
  final TaskRepository tasks;
  final PlanAdjustmentRepository adjustments;
  final PendingPlanPreviewRepository previews;
  final AdjustmentProblemSource source;
  final ScheduleEngine engine;
  final DeferTimePolicy policy;
  final Clock clock;
  final IdGenerator ids;
  final Future<int> Function(DateTime localDate) granularityForDate;
  final TimeZoneDatabase zones;
  final AdjustmentExecutionEvidence executionEvidence;
  final ScheduleProposalCodec codec;
  final Duration previewTtl;
  final int defaultWindowDays;
  final String timeZoneId;

  /// 创建一次调整。输入**故意不接收** sourceStart、taskId 或 title：
  /// 这些事实必须从仓储的当前状态读出（DFR-005）。
  Future<BeginDeferResult> beginDefer({
    required String currentPlanVersionId,
    required String targetBlockId,
    required int amount,
    required DeferUnit unit,
  }) async {
    final validation = policy.validateAmount(amount, unit);
    if (!validation.isValid) {
      return BeginDeferResult(
        status: BeginDeferStatus.invalidAmount,
        failureCode: PlanAdjustmentFailureCode.invariantViolation,
      );
    }
    // ① 当前确认计划存在。
    final confirmed = await plans.current();
    if (confirmed == null) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetMissing,
        failureCode: PlanAdjustmentFailureCode.targetMissing,
      );
    }
    // ② 版本必须等于页面看到的版本。
    if (confirmed.id != currentPlanVersionId) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetChanged,
        failureCode: PlanAdjustmentFailureCode.basePlanChanged,
      );
    }
    // ③ 块存在。
    final block = confirmed.blocks
        .where((item) => item.id == targetBlockId)
        .firstOrNull;
    if (block == null) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetMissing,
        failureCode: PlanAdjustmentFailureCode.targetMissing,
      );
    }
    // ④ 任务存在且活跃（未完成、未删除）。
    final task = await tasks.getById(block.taskId);
    if (task == null) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetMissing,
        failureCode: PlanAdjustmentFailureCode.targetMissing,
      );
    }
    if (task.status != TaskStatus.open) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetIneligible,
        failureCode: PlanAdjustmentFailureCode.targetIneligible,
      );
    }
    // ⑤ 块未开始（严格晚于现在）。
    final now = clock.nowUtc();
    if (!block.startUtc.isAfter(now)) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetIneligible,
        failureCode: PlanAdjustmentFailureCode.targetIneligible,
      );
    }
    // ⑥ 没有执行开始事实。
    final started = await executionEvidence.startedOrCompletedBlockIds([
      block.id,
    ]);
    if (started.contains(block.id)) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetIneligible,
        failureCode: PlanAdjustmentFailureCode.targetIneligible,
      );
    }
    // ⑦ 未锁定。
    if (block.locked) {
      return const BeginDeferResult(
        status: BeginDeferStatus.targetIneligible,
        failureCode: PlanAdjustmentFailureCode.targetIneligible,
      );
    }
    // ⑧ 同一块上没有另一项进行中的调整。
    final conflicts = await adjustments.openForTargetBlock(block.id);
    if (conflicts.isNotEmpty) {
      return const BeginDeferResult(
        status: BeginDeferStatus.operationConflict,
        failureCode: PlanAdjustmentFailureCode.concurrentModification,
      );
    }

    final local = zones.toLocal(block.startUtc, timeZoneId);
    final notBefore = await policy.computeNotBefore(
      sourceStartUtc: block.startUtc,
      amount: amount,
      unit: unit,
      timeZoneId: timeZoneId,
      granularityForDate: granularityForDate,
    );
    final siblings = [
      for (final item in confirmed.blocks)
        if (item.taskId == block.taskId && item.id != block.id) item.id,
    ];
    final adjustment = PlanAdjustment(
      adjustmentId: ids.next(),
      kind: PlanAdjustmentKind.defer,
      targetBlockId: block.id,
      targetTaskId: block.taskId,
      targetTitleSnapshot: task.title,
      basePlanVersionId: confirmed.id,
      sourceStartUtc: block.startUtc,
      sourceEndUtc: block.endUtc,
      notBeforeUtc: notBefore,
      timeZoneId: timeZoneId,
      requestedAmount: amount,
      requestedUnit: unit,
      status: PlanAdjustmentStatus.active,
      createdAtUtc: now,
      expiresAtUtc: now.add(previewTtl),
      revision: 1,
      targetSiblingBlockIds: siblings,
    );
    assert(
      notBefore.isAfter(block.startUtc),
      '下界必须严格晚于源块开始（本地 ${local.hour}:${local.minute} 只是展示用）',
    );
    await adjustments.create(adjustment);
    return BeginDeferResult(
      status: BeginDeferStatus.created,
      adjustment: adjustment,
    );
  }

  /// 首次生成预览。
  Future<GenerateAdjustmentPreviewResult> generate(String adjustmentId) async {
    final adjustment = await adjustments.byId(adjustmentId);
    if (adjustment == null) {
      return const GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.notFound,
      );
    }
    if (!adjustment.status.isOpen && adjustment.status != PlanAdjustmentStatus.failed) {
      return GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.terminal,
        adjustment: adjustment,
        failureCode: adjustment.failureCode,
      );
    }
    final cas = await adjustments.compareAndSet(
      expected: adjustment.token,
      from: {
        PlanAdjustmentStatus.active,
        PlanAdjustmentStatus.failed,
        PlanAdjustmentStatus.previewReady,
      },
      to: PlanAdjustmentStatus.generating,
    );
    if (cas == null) {
      return GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.failed,
        adjustment: adjustment,
        failureCode: PlanAdjustmentFailureCode.concurrentModification,
      );
    }
    return _generateAfterCas(adjustmentId);
  }

  /// 重生：同一 adjustmentId、revision +1、复用原 amount/unit，并重新读取目标块。
  Future<GenerateAdjustmentPreviewResult> regenerate(String adjustmentId) async {
    final adjustment = await adjustments.byId(adjustmentId);
    if (adjustment == null) {
      return const GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.notFound,
      );
    }
    final confirmed = await plans.current();
    final target = confirmed?.blocks
        .where((item) => item.id == adjustment.targetBlockId)
        .firstOrNull;
    final changed =
        confirmed == null ||
        confirmed.id != adjustment.basePlanVersionId ||
        target == null ||
        target.startUtc != adjustment.sourceStartUtc ||
        target.endUtc != adjustment.sourceEndUtc;
    if (changed) {
      final stale = await adjustments.compareAndSet(
        expected: adjustment.token,
        from: {
          PlanAdjustmentStatus.active,
          PlanAdjustmentStatus.generating,
          PlanAdjustmentStatus.previewReady,
          PlanAdjustmentStatus.failed,
        },
        to: PlanAdjustmentStatus.stale,
      );
      return GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.stale,
        adjustment: stale ?? adjustment,
        failureCode: PlanAdjustmentFailureCode.targetChanged,
      );
    }
    final cas = await adjustments.compareAndSet(
      expected: adjustment.token,
      from: {PlanAdjustmentStatus.previewReady, PlanAdjustmentStatus.failed},
      to: PlanAdjustmentStatus.generating,
      incrementRevision: true,
    );
    if (cas == null) {
      return GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.failed,
        adjustment: adjustment,
        failureCode: PlanAdjustmentFailureCode.concurrentModification,
      );
    }
    return _generateAfterCas(adjustmentId);
  }

  /// 显式取消：只 CAS 自己的 adjustment，重复取消幂等。
  Future<bool> cancel(String adjustmentId) async {
    final adjustment = await adjustments.byId(adjustmentId);
    if (adjustment == null) return false;
    if (adjustment.status == PlanAdjustmentStatus.cancelled) return true;
    if (adjustment.status.isTerminal) return false;
    final cas = await adjustments.compareAndSet(
      expected: adjustment.token,
      from: {
        PlanAdjustmentStatus.active,
        PlanAdjustmentStatus.generating,
        PlanAdjustmentStatus.previewReady,
      },
      to: PlanAdjustmentStatus.cancelled,
    );
    return cas != null;
  }

  Future<List<PlanAdjustment>> recoverable() async {
    final now = clock.nowUtc();
    await adjustments.expireBefore(now);
    return adjustments.recoverable(now);
  }

  // ── 内部 ─────────────────────────────────────────────────────────────────

  Future<GenerateAdjustmentPreviewResult> _generateAfterCas(
    String adjustmentId,
  ) async {
    final adjustment = await adjustments.byId(adjustmentId);
    if (adjustment == null) {
      return const GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.notFound,
      );
    }
    try {
      return await _generate(adjustment);
    } on AdjustmentSourceException catch (error) {
      final target = switch (error.code) {
        PlanAdjustmentFailureCode.basePlanChanged ||
        PlanAdjustmentFailureCode.targetChanged => PlanAdjustmentStatus.stale,
        _ => PlanAdjustmentStatus.failed,
      };
      final failed = await adjustments.compareAndSet(
        expected: adjustment.token,
        from: {PlanAdjustmentStatus.generating},
        to: target,
        failureCode: error.code,
      );
      return GenerateAdjustmentPreviewResult(
        status: target == PlanAdjustmentStatus.stale
            ? GenerateAdjustmentPreviewStatus.stale
            : GenerateAdjustmentPreviewStatus.failed,
        adjustment: failed ?? adjustment,
        failureCode: error.code,
      );
    } catch (_) {
      // 内部异常：转成 failed + invariantViolation，保留脱敏诊断（计划 Task 5 Step 5）。
      final failed = await adjustments.compareAndSet(
        expected: adjustment.token,
        from: {PlanAdjustmentStatus.generating},
        to: PlanAdjustmentStatus.failed,
        failureCode: PlanAdjustmentFailureCode.invariantViolation,
      );
      return GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.failed,
        adjustment: failed ?? adjustment,
        failureCode: PlanAdjustmentFailureCode.invariantViolation,
      );
    }
  }

  Future<GenerateAdjustmentPreviewResult> _generate(
    PlanAdjustment adjustment,
  ) async {
    final defaultWindowEnd = clock
        .nowUtc()
        .add(Duration(days: defaultWindowDays));
    final windowEnd = policy.adjustmentWindowEnd(
      notBeforeUtc: adjustment.notBeforeUtc,
      defaultWindowEnd: defaultWindowEnd,
      timeZoneId: adjustment.timeZoneId,
    );
    final problem = await source.loadForAdjustment(
      token: adjustment.token,
      windowEndUtc: windowEnd,
    );
    final target = problem.confirmedBlocks
        .where((block) => block.id == adjustment.targetBlockId)
        .firstOrNull;
    if (target == null) {
      throw const AdjustmentSourceException(
        PlanAdjustmentFailureCode.targetMissing,
      );
    }
    if (target.startUtc != adjustment.sourceStartUtc ||
        target.endUtc != adjustment.sourceEndUtc) {
      throw const AdjustmentSourceException(
        PlanAdjustmentFailureCode.targetChanged,
      );
    }
    final raw = engine.generate(problem);
    final requirement = AdjustmentRequirement(
      targetBlockId: adjustment.targetBlockId,
      notBeforeUtc: adjustment.notBeforeUtc,
      requiredMinutes: adjustment.sourceDurationMinutes,
      originalStartUtc: adjustment.sourceStartUtc,
    );
    final proposal = raw.withAdjustmentRequirement(requirement);
    final fulfilment = evaluateAdjustmentFulfilment(
      requirement: requirement,
      proposalBlocks: proposal.blocks,
    );
    if (!fulfilment.isFulfilled) {
      final lineageMissing = !proposal.blocks.any(
        (block) =>
            block.id == adjustment.targetBlockId ||
            block.continuedFromId == adjustment.targetBlockId,
      );
      throw AdjustmentSourceException(
        lineageMissing
            ? PlanAdjustmentFailureCode.fulfilmentMissing
            : PlanAdjustmentFailureCode.fulfilmentDurationMismatch,
      );
    }
    final proposalJson = codec.encodeCanonical(proposal);
    final previewId = ids.next();
    final now = clock.nowUtc();
    int? targetStartMicros;
    for (final block in proposal.blocks) {
      if (block.id == adjustment.targetBlockId ||
          block.continuedFromId == adjustment.targetBlockId) {
        targetStartMicros = block.range.startUtc.microsecondsSinceEpoch;
        break;
      }
    }
    final bundle = PendingPreviewBundle(
      preview: PendingPlanPreview(
        previewId: previewId,
        kind: PendingPreviewKind.deferAdjustment,
        operationId: adjustment.adjustmentId,
        basePlanVersionId: adjustment.basePlanVersionId,
        inputHash: proposal.inputHash,
        algorithmVersion: proposal.algorithmVersion,
        windowStartUtc: problem.planningWindow.startUtc,
        windowEndUtc: problem.planningWindow.endUtc,
        timeZoneId: adjustment.timeZoneId,
        status: PendingPreviewStatus.active,
        createdAtUtc: now,
        expiresAtUtc: now.add(previewTtl),
        summaryJson: jsonEncode({
          'scheduledMinutes': proposal.metrics.scheduledMinutes,
          'unscheduledMinutes': proposal.metrics.unscheduledMinutes,
          'targetStartUtc': targetStartMicros,
        }),
        diagnosticsJson: jsonEncode({
          'conflicts': proposal.conflicts.length,
          'unscheduled': proposal.unscheduled.length,
          'outcome': proposal.outcome.name,
        }),
        revision: 1,
        proposalJson: proposalJson,
        proposalSha256: codec.sha256OfCanonical(proposal),
      ),
      blocks: await _previewBlocks(previewId, proposal, adjustment),
    );
    await previews.saveActive(bundle);
    final ready = await adjustments.compareAndSet(
      expected: adjustment.token,
      from: {PlanAdjustmentStatus.generating},
      to: PlanAdjustmentStatus.previewReady,
      previewId: previewId,
    );
    if (ready == null) {
      // 生成成功但状态已被并发改写（例如用户刚取消）：预览留在库里由清理策略回收，
      // 但绝不冒充"可确认"。
      return GenerateAdjustmentPreviewResult(
        status: GenerateAdjustmentPreviewStatus.stale,
        adjustment: adjustment,
        previewId: previewId,
        failureCode: PlanAdjustmentFailureCode.concurrentModification,
      );
    }
    return GenerateAdjustmentPreviewResult(
      status: GenerateAdjustmentPreviewStatus.previewReady,
      adjustment: ready,
      previewId: previewId,
    );
  }

  Future<List<PendingPlanPreviewBlock>> _previewBlocks(
    String previewId,
    ScheduleProposal proposal,
    PlanAdjustment adjustment,
  ) async {
    final titles = <String, String>{};
    for (final block in proposal.blocks) {
      if (titles.containsKey(block.taskId)) continue;
      if (block.taskId == adjustment.targetTaskId) {
        titles[block.taskId] = adjustment.targetTitleSnapshot;
        continue;
      }
      final task = await tasks.getById(block.taskId);
      titles[block.taskId] = (task != null && task.title.trim().isNotEmpty)
          ? task.title
          : unnamedTaskTitle;
    }
    return [
      for (final block in proposal.blocks)
        PendingPlanPreviewBlock(
          previewId: previewId,
          blockId: block.id,
          taskId: block.taskId,
          cycleId: null,
          title: titles[block.taskId] ?? unnamedTaskTitle,
          startUtc: block.range.startUtc,
          endUtc: block.range.endUtc,
          explanationCode: block.explanationCode ?? 'deferAdjustment',
          minutes: block.range.duration.inMinutes,
        ),
    ];
  }
}

