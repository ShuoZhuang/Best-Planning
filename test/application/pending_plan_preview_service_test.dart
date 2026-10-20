import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_plan_preview_service.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import 'execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringExecutionRepository repository;
  late PendingPlanPreviewService service;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '20', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    service = PendingPlanPreviewService(
      repository: repository,
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
      applyProposal: (_) async => ApplyPlanResult.applied(
        ConfirmedPlan(
          id: 'plan-2',
          inputHash: 'hash',
          algorithmVersion: '20',
          blocks: const [],
        ),
      ),
      titleForTask: (_) async => '每周阅读',
    );
  });

  tearDown(() => harness.close());

  ScheduleProposal proposal() {
    final start = harness.clock.nowUtc().add(const Duration(days: 7));
    return ScheduleProposal(
      proposalId: 'preview-1',
      inputHash: 'hash',
      algorithmVersion: '20',
      planningWindow: TimeRange(
        startUtc: start,
        endUtc: start.add(const Duration(days: 7)),
      ),
      blocks: [
        PlannedBlock(
          id: 'block-1',
          taskId: 'task-1',
          range: TimeRange(
            startUtc: start,
            endUtc: start.add(const Duration(minutes: 45)),
          ),
        ),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 45,
        unscheduledMinutes: 0,
      ),
    );
  }

  Future<PendingPreviewBundle> save() => service.saveProposal(
    proposal: proposal(),
    basePlanVersionId: 'plan-1',
    window: proposal().planningWindow,
    timeZoneId: 'Asia/Shanghai',
  );

  test('预排保存后可跨仓储实例读取，块标题与时间保留', () async {
    await save();
    final reopened = PendingPlanPreviewService(
      repository: DriftRecurringExecutionRepository(
        harness.database,
        clock: harness.clock,
        idGenerator: harness.ids,
      ),
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final active = await reopened.active();
    expect(active, isNotNull);
    expect(active!.preview.previewId, 'preview-1');
    expect(active.blocks.single.title, '每周阅读');
    // 预排不得创建正式 occurrence / 提醒（设计 §4.4、Task 11/15）。
    for (final table in [
      'execution_occurrences',
      'execution_reminder_intents',
    ]) {
      final row = await harness.database
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle();
      expect(row.read<int>('c'), 0, reason: '$table must stay empty');
    }
  });

  test('令牌不匹配时标记 stale，不调用正式应用', () async {
    await save();
    var applied = false;
    service = PendingPlanPreviewService(
      repository: repository,
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
      applyProposal: (_) async {
        applied = true;
        return ApplyPlanResult.stale();
      },
    );
    final result = await service.confirm(
      previewId: 'preview-1',
      expectedBasePlanVersionId: 'plan-1',
      expectedInputHash: 'different',
      expectedAlgorithmVersion: '20',
      expectedPreviewRevision: 1,
    );
    expect(result.status, PreviewApplyStatus.stale);
    expect(applied, isFalse);
    final preview = await repository.previewById('preview-1');
    expect(preview!.status, PendingPreviewStatus.stale);
  });

  test('revision 不匹配也标记 stale，不调用正式应用', () async {
    await save();
    var applied = false;
    service = PendingPlanPreviewService(
      repository: repository,
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
      applyProposal: (_) async {
        applied = true;
        return ApplyPlanResult.stale();
      },
    );
    final result = await service.confirm(
      previewId: 'preview-1',
      expectedBasePlanVersionId: 'plan-1',
      expectedInputHash: 'hash',
      expectedAlgorithmVersion: '20',
      expectedPreviewRevision: 99,
    );
    expect(result.status, PreviewApplyStatus.stale);
    expect(applied, isFalse);
    final preview = await repository.previewById('preview-1');
    expect(preview!.status, PendingPreviewStatus.stale);
  });

  test('令牌匹配时应用正式计划并接受预排', () async {
    await save();
    final result = await service.confirm(
      previewId: 'preview-1',
      expectedBasePlanVersionId: 'plan-1',
      expectedInputHash: 'hash',
      expectedAlgorithmVersion: '20',
      expectedPreviewRevision: 1,
    );
    expect(result.status, PreviewApplyStatus.applied);
    expect(result.planVersionId, 'plan-2');
    final preview = await repository.previewById('preview-1');
    expect(preview!.status, PendingPreviewStatus.accepted);
  });

  test('拒绝后保留审计行，当前无 active 预排', () async {
    await save();
    await service.reject('preview-1', reason: '本周不想提前排');
    expect(await service.active(), isNull);
    final preview = await repository.previewById('preview-1');
    expect(preview!.status, PendingPreviewStatus.rejected);
  });
}
