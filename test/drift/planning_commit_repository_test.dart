import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/planning_commit_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final _window = TimeRange(
  startUtc: DateTime.utc(2026, 10, 17),
  endUtc: DateTime.utc(2026, 10, 18),
);

ScheduleProposal _proposal({String hash = 'hash-1'}) => ScheduleProposal(
  proposalId: 'proposal-1',
  inputHash: hash,
  algorithmVersion: '19',
  planningWindow: _window,
  blocks: [
    PlannedBlock(
      id: 'block-1',
      taskId: 'task-1',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 17, 9),
        endUtc: DateTime.utc(2026, 10, 17, 10),
      ),
    ),
  ],
  unscheduled: const [],
  conflicts: const [],
  explanations: const [],
  metrics: const ProposalMetrics(
    isFullyFeasible: true,
    scheduledMinutes: 60,
    unscheduledMinutes: 0,
  ),
);

DayException _exception() => DayException(
  id: 'day-1',
  localDate: DateTime(2026, 10, 17),
  kind: DayExceptionKind.userSpecialDay,
  status: DayExceptionStatus.draft,
  originalSleepStartOffsetMinutes: 23 * 60 + 30,
  temporarySleepStartOffsetMinutes: 24 * 60 + 30,
  fixedWakeOffsetMinutes: 31 * 60 + 30,
  absoluteMinimumSleepMinutes: 6 * 60,
  recoveryChoice: RecoveryChoice.nextDayRest,
  source: 'test',
  createdAtUtc: DateTime.utc(2026, 10, 17, 8),
  updatedAtUtc: DateTime.utc(2026, 10, 17, 8),
  recoveryLocalDate: DateTime(2026, 10, 18),
);

void main() {
  late AppDatabase database;
  late DriftPlanRepository repository;
  late DriftDayExceptionRepository dayExceptions;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftPlanRepository(database);
    dayExceptions = DriftDayExceptionRepository(database);
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-1',
            title: '测试任务',
            priority: 'medium',
            estimatedMinutes: 60,
            remainingMinutes: 60,
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            status: 'open',
            createdAtUtc: 1,
            updatedAtUtc: 1,
          ),
        );
  });

  tearDown(() => database.close());

  test('特殊日、恢复保护块、计划与审计在同一事务提交', () async {
    final result = await repository.commit(
      PlanningCommitRequest(
        proposal: _proposal(),
        expectedInputHash: 'hash-1',
        confirmedDayException: _exception(),
        recoveryEffect: RecoveryCommitEffect(
          choice: RecoveryChoice.nextDayRest,
          nextLocalDate: DateTime(2026, 10, 18),
          protectedRestUtc: TimeRange(
            startUtc: DateTime.utc(2026, 10, 18, 1),
            endUtc: DateTime.utc(2026, 10, 18, 3),
          ),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    expect(result.status, ApplyPlanStatus.applied);
    final exception = await dayExceptions.findConfirmed(DateTime(2026, 10, 17));
    expect(exception?.status, DayExceptionStatus.confirmed);
    final events = await database.select(database.calendarEvents).get();
    expect(events.single.kind, 'protected');
    expect(events.single.sourceKind, 'recovery');
    final logs = await database.select(database.changeLog).get();
    expect(logs.where((row) => row.entityType == 'dayException'), hasLength(1));
    expect(
      logs.where((row) => row.entityType == 'recoveryEffect'),
      hasLength(1),
    );
    expect(
      (await database.select(database.planVersions).get()).single.status,
      'confirmed',
    );
  });

  test('事务中途失败时特殊日、恢复块与计划全部回滚', () async {
    await expectLater(
      repository.commit(
        PlanningCommitRequest(
          proposal: _proposal(),
          expectedInputHash: 'hash-1',
          confirmedDayException: _exception(),
          // 缺少区间 ⇒ 写恢复块时抛错。
          recoveryEffect: RecoveryCommitEffect(
            choice: RecoveryChoice.nextDayRest,
            nextLocalDate: DateTime(2026, 10, 18),
          ),
        ),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await database.select(database.dayExceptions).get(), isEmpty);
    expect(await database.select(database.planVersions).get(), isEmpty);
    expect(await database.select(database.scheduleBlocks).get(), isEmpty);
  });

  test('次日提前入睡写日期覆盖，不新建第二条特殊日', () async {
    await repository.commit(
      PlanningCommitRequest(
        proposal: _proposal(),
        expectedInputHash: 'hash-1',
        confirmedDayException: _exception(),
        recoveryEffect: RecoveryCommitEffect(
          choice: RecoveryChoice.nextNightEarlierSleep,
          nextLocalDate: DateTime(2026, 10, 18),
          nextNightSleepStartMinute: 22 * 60 + 30,
        ),
      ),
    );
    final row =
        await (database.select(database.settings)..where(
              (item) => item.key.equals('planning.dateOverride.2026-10-18'),
            ))
            .getSingle();
    expect(row.jsonValue, contains('sleepRange'));
    expect(row.jsonValue, contains('1350'));
    expect(await database.select(database.dayExceptions).get(), hasLength(1));
  });

  test('降低次日负载写独立字段，不伪装成睡眠覆盖', () async {
    await repository.commit(
      PlanningCommitRequest(
        proposal: _proposal(),
        expectedInputHash: 'hash-1',
        confirmedDayException: _exception(),
        recoveryEffect: RecoveryCommitEffect(
          choice: RecoveryChoice.reduceNextDayLoad,
          nextLocalDate: DateTime(2026, 10, 18),
          nextDayMovableLoadCapMinutes: 120,
        ),
      ),
    );
    final row =
        await (database.select(database.settings)..where(
              (item) => item.key.equals('planning.dateOverride.2026-10-18'),
            ))
            .getSingle();
    expect(row.jsonValue, contains('dailyMovableTaskLimitMinutes'));
    expect(row.jsonValue, isNot(contains('sleepRange')));
  });

  test('哈希不符时零写入', () async {
    final result = await repository.commit(
      PlanningCommitRequest(
        proposal: _proposal(hash: 'old'),
        expectedInputHash: 'new',
      ),
    );
    expect(result.status, ApplyPlanStatus.staleProposal);
    expect(await database.select(database.planVersions).get(), isEmpty);
    expect(await database.select(database.dayExceptions).get(), isEmpty);
  });
}
