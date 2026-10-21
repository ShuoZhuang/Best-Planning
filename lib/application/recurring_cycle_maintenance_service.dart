import 'package:personal_planner/application/pending_plan_preview_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/recurring_task.dart'
    show shiftLocalDate;
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart'
    show PlannedBlock;

/// 尾部合并：保留 [nextWindow] 之外已确认的块，窗口内用 [nextBlocks] 替换。
List<PlannedBlock> mergePreviewTailBlocks({
  required Iterable<PlannedBlock> baseBlocks,
  required Iterable<PlannedBlock> nextBlocks,
  required TimeRange nextWindow,
}) => [
  for (final block in baseBlocks)
    if (!block.range.endUtc.isAfter(nextWindow.startUtc) ||
        !block.range.startUtc.isBefore(nextWindow.endUtc))
      block,
  ...nextBlocks,
];

/// 滚动维护结果：本次是否真的创建/改动了预排。
final class RecurringMaintenanceResult {
  const RecurringMaintenanceResult({
    required this.preview,
    required this.createdCycles,
    required this.reusedFlight,
  });

  final PendingPreviewBundle preview;
  final int createdCycles;
  final bool reusedFlight;
}

/// 正式执行窗口 + 下一完整周预排的滚动维护（1.11.0 周期预排 Task 11）。
///
/// 相同 workspace + 本地周 + 窗口的并发维护共享同一个 Future；维护结束后预排已持久化，
/// 页面重开或应用重启读取的是同一份，不会“重开就消失”。
final class RecurringCycleMaintenanceService {
  RecurringCycleMaintenanceService({
    required this.cycles,
    required this.previews,
    required this.plans,
    required this.creator,
    required this.zones,
    required this.timeZoneId,
    required this.clock,
    this.workspaceId = 'default',
    this.trustAutoAdjust,
  });

  final RecurringTaskService cycles;
  final PendingPlanPreviewService previews;
  final PlanRepository plans;
  final ProposalCreator creator;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final Clock clock;
  final String workspaceId;

  /// “信任自动调整”开关。仅完整可行、无冲突/未安排的预排才允许自动应用。
  final bool Function()? trustAutoAdjust;

  final Map<String, Future<RecurringMaintenanceResult>> _inFlight = {};

  Future<RecurringMaintenanceResult> maintain({DateTime? nowUtc}) {
    final now = nowUtc ?? clock.nowUtc();
    final current = WeeklyPeriod.forInstant(now, timeZoneId, zones);
    final key = '$workspaceId:${current.startLocalDate.toIso8601String()}';
    final existing = _inFlight[key];
    if (existing != null) {
      return existing.then(
        (result) => RecurringMaintenanceResult(
          preview: result.preview,
          createdCycles: result.createdCycles,
          reusedFlight: true,
        ),
      );
    }
    final future = _run(now, current);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<RecurringMaintenanceResult> _run(
    DateTime now,
    WeeklyPeriod current,
  ) async {
    final next = WeeklyPeriod.startingAt(
      shiftLocalDate(current.startLocalDate, 7),
      timeZoneId,
      zones,
    );
    final executionWindow = TimeRange(
      startUtc: now,
      endUtc: zones.localMidnightToUtc(
        shiftLocalDate(localDateOf(now), 7),
        timeZoneId,
      ),
    );
    final run = await cycles.ensureCycles(executionWindow, now);
    await cycles.ensureCycles(next.range, now);
    final proposal = await creator.createProposal(window: next.range);
    final nextBlocks = [
      for (final block in proposal.blocks)
        if (!block.range.startUtc.isBefore(next.startUtc) &&
            block.range.startUtc.isBefore(next.endUtc))
          block,
    ];
    final base = await plans.current();
    final mergedBlocks = mergePreviewTailBlocks(
      baseBlocks: base?.blocks ?? const <PlannedBlock>[],
      nextBlocks: nextBlocks,
      nextWindow: next.range,
    );
    final bundle = await previews.saveProposal(
      proposal: proposal.withBlocks(mergedBlocks),
      basePlanVersionId: base?.id ?? '',
      window: next.range,
      timeZoneId: timeZoneId,
    );
    final trusted = trustAutoAdjust?.call() ?? false;
    if (trusted &&
        proposal.metrics.isFullyFeasible &&
        proposal.unscheduled.isEmpty &&
        proposal.conflicts.isEmpty) {
      await previews.confirm(
        previewId: bundle.preview.previewId,
        expectedBasePlanVersionId: bundle.preview.basePlanVersionId,
        expectedInputHash: bundle.preview.inputHash,
        expectedAlgorithmVersion: bundle.preview.algorithmVersion,
        expectedPreviewRevision: bundle.preview.revision,
      );
    }
    return RecurringMaintenanceResult(
      preview: bundle,
      createdCycles: run.createdCount,
      reusedFlight: false,
    );
  }

  DateTime localDateOf(DateTime utc) {
    final local = zones.toLocal(utc, timeZoneId);
    return DateTime(local.year, local.month, local.day);
  }
}
