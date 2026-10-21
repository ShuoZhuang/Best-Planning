// 1.11.0（计划 Task 5 Step 3、DFR-034）：延后只移动目标 lineage，
// **同任务兄弟块**不得被任务级下界牵连。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/defer_time_policy.dart';
import 'package:personal_planner/application/plan_adjustment_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_pending_plan_preview_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_adjustment_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../application/execution/execution_test_support.dart';

final class _NoCalendar implements CalendarRepository {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoLifeAreas implements LifeAreaLookup {
  const _NoLifeAreas();

  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';

  test('同任务兄弟块保持原位，目标块快照记录兄弟身份', () async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final planRepository = DriftPlanRepository(
      harness.database,
      clock: harness.clock,
    );
    final adjustments = DriftPlanAdjustmentRepository(
      harness.database,
      clock: harness.clock,
    );
    final previews = DriftPendingPlanPreviewRepository(
      harness.database,
      clock: harness.clock,
    );

    // 任务共 90 分钟：目标 45 + 兄弟 45，必须两块都在。
    final task = await harness.taskRepository.getById('task-1');
    await harness.taskRepository.save(
      PlannerTask(
        id: task!.id,
        areaId: task.areaId,
        title: task.title,
        priority: task.priority,
        estimatedMinutes: 90,
        remainingMinutes: 90,
        energyLevel: task.energyLevel,
        splitMode: task.splitMode,
        minChunkMinutes: 15,
        maxChunkMinutes: 60,
        status: TaskStatus.open,
        createdAtUtc: task.createdAtUtc,
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );

    final targetStart = DateTime.utc(2026, 10, 19, 7);
    final siblingStart = DateTime.utc(2026, 10, 19, 9);
    final base = ScheduleProposal(
      proposalId: 'base-1',
      inputHash: 'hash-base',
      algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 19),
        endUtc: DateTime.utc(2026, 10, 26),
      ),
      blocks: [
        PlannedBlock(
          id: 'block-target',
          taskId: 'task-1',
          range: TimeRange(
            startUtc: targetStart,
            endUtc: targetStart.add(const Duration(minutes: 45)),
          ),
        ),
        PlannedBlock(
          id: 'block-sibling',
          taskId: 'task-1',
          range: TimeRange(
            startUtc: siblingStart,
            endUtc: siblingStart.add(const Duration(minutes: 45)),
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
    expect(
      (await planRepository.applyProposal(base, 'hash-base')).status,
      ApplyPlanStatus.applied,
    );

    final source = RepositoryScheduleProblemSource(
      tasks: harness.taskRepository,
      lifeAreas: const _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: planRepository,
      clock: harness.clock,
      timeZoneId: zoneId,
      zones: zones,
      adjustments: adjustments,
    );
    final service = PlanAdjustmentService(
      plans: planRepository,
      tasks: harness.taskRepository,
      adjustments: adjustments,
      previews: previews,
      source: source,
      engine: DeterministicScheduleEngine(zones),
      policy: DeferTimePolicy(zones),
      clock: harness.clock,
      ids: harness.ids,
      granularityForDate: (_) async => 5,
      zones: zones,
      timeZoneId: zoneId,
      applier: planRepository,
    );

    final begun = await service.beginDefer(
      currentPlanVersionId: 'base-1',
      targetBlockId: 'base-1:block-target',
      amount: 10,
      unit: DeferUnit.minutes,
    );
    expect(begun.status, BeginDeferStatus.created);
    expect(begun.adjustment!.targetSiblingBlockIds, {
      'base-1:block-sibling',
    }, reason: '快照必须记录同任务兄弟块');

    final generated = await service.generate(begun.adjustment!.adjustmentId);
    expect(
      generated.status,
      GenerateAdjustmentPreviewStatus.previewReady,
      reason: generated.failureCode?.name,
    );
    final bundle = await previews.active(
      PendingPreviewKind.deferAdjustment,
      operationId: begun.adjustment!.adjustmentId,
    );
    expect(bundle, isNotNull);
    final sibling = bundle!.blocks.firstWhere(
      (block) => block.blockId.contains('block-sibling'),
    );
    expect(sibling.startUtc, siblingStart, reason: '兄弟块不在本次调整范围内，不得被任务级下界推后');
    final target = bundle.blocks.firstWhere(
      (block) => block.blockId.contains('block-target'),
    );
    expect(target.startUtc.isBefore(targetStart), isFalse);
  });
}
