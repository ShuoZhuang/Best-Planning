import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const snapshots = InputSnapshotBuilder();

  test('snapshot hash ignores UI state and normalizes input list order', () {
    final problem = _problem(requiredMinutes: 60);
    final reversed = ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks.reversed.toList(),
      fixedIntervals: problem.fixedIntervals.reversed.toList(),
      protectedIntervals: problem.protectedIntervals.reversed.toList(),
      lockedBlocks: problem.lockedBlocks.reversed.toList(),
      rules: problem.rules,
      preferences: problem.preferences,
      inputHash: 'ignored-too',
    );

    final first = snapshots.hash(
      InputSnapshot(problem: problem, uiState: const {'selectedTab': 0}),
    );
    final second = snapshots.hash(
      InputSnapshot(problem: reversed, uiState: const {'selectedTab': 3}),
    );

    expect(first, second);
    expect(first, hasLength(64));
  });

  test('保护时间或默认片段变化会使已有提案过期', () {
    final original = _problem(requiredMinutes: 60);
    final changed = ScheduleProblem(
      planningWindow: original.planningWindow,
      timeZoneId: original.timeZoneId,
      tasks: original.tasks,
      fixedIntervals: original.fixedIntervals,
      protectedIntervals: original.protectedIntervals,
      lockedBlocks: original.lockedBlocks,
      rules: original.rules.copyWith(
        protectedTimes: const [],
        minChunkMinutes: 35,
      ),
      preferences: original.preferences,
      inputHash: original.inputHash,
    );

    expect(
      snapshots.hash(InputSnapshot(problem: changed)),
      isNot(snapshots.hash(InputSnapshot(problem: original))),
    );
  });

  test(
    'changed task makes a preview stale without changing current plan',
    () async {
      final source = _MutableProblemSource(_problem(requiredMinutes: 60));
      final repository = _MemoryPlanRepository(currentId: 'existing-plan');
      final planning = PlanningService(
        source: source,
        engine: DeterministicScheduleEngine(TimeZoneDatabase()),
        snapshots: snapshots,
      );
      final application = PlanApplicationService(
        source: source,
        repository: repository,
        snapshots: snapshots,
        zones: TimeZoneDatabase(),
      );
      final proposal = await planning.createProposal();
      source.problem = _problem(requiredMinutes: 120);

      final result = await application.apply(proposal);

      expect(result.status, ApplyPlanStatus.staleProposal);
      expect(repository.applyCalls, 0);
      expect((await repository.current())?.id, 'existing-plan');
    },
  );

  test('后台排程不会把问题数据源中的本地资源传入 isolate', () async {
    final source = _UnsendableProblemSource(_problem(requiredMinutes: 60));
    addTearDown(source.dispose);
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(TimeZoneDatabase()),
      snapshots: snapshots,
    );

    final proposal = await planning.createProposal();

    expect(proposal.blocks, isNotEmpty);
  });

  test('一次性覆盖同时进入输入装配并被附在提案上', () async {
    // 两件事都必须发生：装配时用它（否则提案不含恢复保护），随提案带走
    // （否则确认阶段重放不出同一个哈希）。
    final source = _MutableProblemSource(_problem(requiredMinutes: 60));
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(TimeZoneDatabase()),
      snapshots: snapshots,
    );
    final override = ScheduleRuleOverride(
      localDate: DateTime(2026, 10, 5),
      patch: PlanningRulesPatch(
        sleepRange: LocalTimeRange(startMinute: 60, endMinute: 8 * 60),
      ),
    );

    final proposal = await planning.createProposal(override: override);

    expect(source.lastOverride, same(override));
    expect(proposal.ruleOverride, same(override));
    expect(planning.preview(proposal.proposalId)?.ruleOverride, same(override));

    // 普通生成路径不得凭空带出一个覆盖。
    final plain = await planning.createProposal();
    expect(source.lastOverride, isNull);
    expect(plain.ruleOverride, isNull);
  });
}

ScheduleProblem _problem({required int requiredMinutes}) {
  final day = DateTime.utc(2026, 10, 5);
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    ),
    timeZoneId: 'UTC',
    tasks: [
      SchedulableTask(
        id: 'task',
        requiredMinutes: requiredMinutes,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
    ],
    fixedIntervals: [
      BusyInterval(
        id: 'class',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 10)),
          endUtc: day.add(const Duration(hours: 11)),
        ),
      ),
    ],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: DefaultSettings.v1(),
    preferences: const PreferenceProfile(),
    inputHash: 'not-part-of-snapshot',
  );
}

final class _MutableProblemSource implements ScheduleProblemSource {
  _MutableProblemSource(this.problem);
  ScheduleProblem problem;
  ScheduleRuleOverride? lastOverride;
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async {
    lastOverride = override;
    return problem;
  }
}

final class _UnsendableProblemSource implements ScheduleProblemSource {
  _UnsendableProblemSource(this.problem);

  final ScheduleProblem problem;
  final ReceivePort _localResource = ReceivePort();

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;

  void dispose() => _localResource.close();
}

final class _MemoryPlanRepository implements PlanRepository {
  _MemoryPlanRepository({String? currentId})
    : _current = currentId == null
          ? null
          : ConfirmedPlan(
              id: currentId,
              inputHash: 'old-hash',
              algorithmVersion: '1',
              blocks: const [],
            );

  ConfirmedPlan? _current;
  int applyCalls = 0;

  @override
  Future<ConfirmedPlan?> current() async => _current;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    applyCalls++;
    _current = ConfirmedPlan(
      id: proposal.proposalId,
      inputHash: proposal.inputHash,
      algorithmVersion: proposal.algorithmVersion,
      blocks: proposal.blocks,
    );
    return ApplyPlanResult.applied(_current!);
  }
}
