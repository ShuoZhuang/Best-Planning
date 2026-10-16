import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();

void main() {
  late AppDatabase database;
  late DriftPlanRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftPlanRepository(
      database,
      clock: _FixedClock(DateTime.utc(2026, 10, 5, 8)),
    );
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'task', 'Task', '', 'medium', 180, 180,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
  });

  tearDown(() => database.close());

  // ─────────────────────────────────────────────────────────────────────────────
  // 算法版本闸门（计划 Task 10「应用安全」）
  //
  // 提案携带 `algorithmVersion`，它记录"这份块集合是哪个排程算法算出来的"。
  // 输入哈希只能证明**输入**没变；算法本身升级之后，同一份输入会算出不同的
  // 块集合，而旧提案的块在新算法下可能已经违反新的硬约束。
  // 因此版本不符的提案必须与"输入已变"同样处理：**判为过期、零写入**。
  // ─────────────────────────────────────────────────────────────────────────────
  group('算法版本闸门（Task 10）', () {
    test('**算法版本不符 ⇒ 过期、零写入**', () async {
      // 先用真实哈希与合法块集合造一份提案：除了版本号，它一切正常。
      // 这样"被拒"只可能来自版本这一条判据。
      final problem = _applyProblem();
      const snapshots = InputSnapshotBuilder();
      final hash = snapshots.hash(InputSnapshot(problem: problem));
      final service = PlanApplicationService(
        source: _ProblemSource(problem),
        repository: repository,
        zones: TimeZoneDatabase(),
        snapshots: snapshots,
      );

      final proposal = _applyProposal(
        inputHash: hash,
        algorithmVersion: 'algorithm-from-an-older-release',
      );
      final result = await service.apply(proposal);

      expect(
        result.status,
        ApplyPlanStatus.staleProposal,
        reason: '算法版本不符必须判为过期，而不是尝试写入',
      );
      expect(
        await database.select(database.planVersions).get(),
        isEmpty,
        reason: '被判过期的提案不得留下任何计划版本（零写入）',
      );
    });

    test('版本相符时正常应用（闸门不能误伤合法提案）', () async {
      final problem = _applyProblem();
      const snapshots = InputSnapshotBuilder();
      final hash = snapshots.hash(InputSnapshot(problem: problem));
      final service = PlanApplicationService(
        source: _ProblemSource(problem),
        repository: repository,
        zones: TimeZoneDatabase(),
        snapshots: snapshots,
      );

      final result = await service.apply(
        _applyProposal(
          inputHash: hash,
          algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
        ),
      );

      expect(result.status, ApplyPlanStatus.applied);
    });
  });
  test(
    'third block failure rolls back plan, blocks, log and supersede',
    () async {
      await database.customInsert("""
      INSERT INTO plan_versions
        (id, created_at_utc, input_hash, algorithm_version, status, summary_json)
      VALUES ('existing', 1, 'old', '1', 'confirmed', '{}')
      """);
      await database.customStatement("""
      CREATE TRIGGER fail_third_block
      BEFORE INSERT ON schedule_blocks
      WHEN (
        SELECT COUNT(*) FROM schedule_blocks
        WHERE plan_version_id = NEW.plan_version_id
      ) = 2
      BEGIN
        SELECT RAISE(ABORT, 'simulated third block failure');
      END
      """);

      await expectLater(
        repository.applyProposal(_proposal(), 'snapshot-hash'),
        throwsA(anything),
      );

      expect(await database.select(database.planVersions).get(), hasLength(1));
      expect((await repository.current())?.id, 'existing');
      expect(await database.select(database.scheduleBlocks).get(), isEmpty);
      expect(await database.select(database.changeLog).get(), isEmpty);
    },
  );

  test(
    'successful apply stores one confirmed version, blocks and log',
    () async {
      final result = await repository.applyProposal(
        _proposal(),
        'snapshot-hash',
      );

      expect(result.status, ApplyPlanStatus.applied);
      expect(result.plan?.blocks, hasLength(3));
      expect(await database.select(database.planVersions).get(), hasLength(1));
      expect(
        await database.select(database.scheduleBlocks).get(),
        hasLength(3),
      );
      expect(await database.select(database.changeLog).get(), hasLength(4));
    },
  );

  test('application service revalidates blocks before transaction', () async {
    const snapshots = InputSnapshotBuilder();
    final problem = _validationProblem();
    final hash = snapshots.hash(InputSnapshot(problem: problem));
    final proposal = ScheduleProposal(
      proposalId: 'invalid-proposal',
      inputHash: hash,
      algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
      planningWindow: _dayWindow(DateTime.utc(2026, 10, 5)),
      blocks: [
        PlannedBlock(
          id: 'one',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 9),
            endUtc: DateTime.utc(2026, 10, 5, 10),
          ),
        ),
        PlannedBlock(
          id: 'two',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 9, 30),
            endUtc: DateTime.utc(2026, 10, 5, 10, 30),
          ),
        ),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 120,
        unscheduledMinutes: 0,
      ),
    );
    final service = PlanApplicationService(
      source: _ProblemSource(problem),
      repository: repository,
      zones: TimeZoneDatabase(),
      snapshots: snapshots,
    );

    final result = await service.apply(proposal);

    expect(result.status, ApplyPlanStatus.invalidProposal);
    expect(await database.select(database.planVersions).get(), isEmpty);
  });

  test('确认时必须重放生成提案时的一次性规则覆盖', () async {
    // 特殊日恢复的一次性例外只存在于生成提案的那一次输入里。如果确认阶段不把它
    // 重放出来，重新装配的规则与提案不一致，哈希必然不同，合法提案会被判为过期。
    const snapshots = InputSnapshotBuilder();
    final base = _overrideProblem();
    final override = ScheduleRuleOverride(
      localDate: DateTime(2026, 10, 5),
      patch: PlanningRulesPatch(
        sleepRange: LocalTimeRange(startMinute: 60, endMinute: 8 * 60),
      ),
    );
    final overridden = _withRules(base, override.patch.applyTo(base.rules));
    final overriddenHash = snapshots.hash(InputSnapshot(problem: overridden));
    expect(
      overriddenHash,
      isNot(snapshots.hash(InputSnapshot(problem: base))),
      reason: '例外必须改变输入哈希，否则"过期提案"检测形同虚设',
    );

    final source = _OverrideAwareSource(base);
    final service = PlanApplicationService(
      source: source,
      repository: repository,
      zones: TimeZoneDatabase(),
      snapshots: snapshots,
    );

    final replayed = await service.apply(
      _overrideProposal(inputHash: overriddenHash, override: override),
    );
    expect(source.received, same(override));
    expect(replayed.status, ApplyPlanStatus.applied);

    // 对照：哈希相同但不带覆盖，说明重放缺失会让提案永久无法应用。
    final withoutOverride = await service.apply(
      _overrideProposal(inputHash: overriddenHash, override: null),
    );
    expect(withoutOverride.status, ApplyPlanStatus.staleProposal);
  });

  test('引擎报告的阻断冲突先于 validator，且 `allowPartial` 也绕不过去', () async {
    // 计划 Task 5 Step 6：`PlanApplicationService.apply()` 必须在 **stale 检查之后、
    // validator 之前**先看 `proposal.conflicts`。
    //
    // 为什么不能只靠 validator：`schedulingInvariantViolation`（"排程没有使用仍可用的
    // 合法时段"）是在**块集合本身合法**的情况下出现的——validator 查不出来，而它恰恰是
    // 最不能写进用户计划的一类。`allowPartial` 只适用于"装不下"，不适用于"排程器自己没排好"。
    const snapshots = InputSnapshotBuilder();
    final problem = _validationProblem();
    final hash = snapshots.hash(InputSnapshot(problem: problem));
    final service = PlanApplicationService(
      source: _ProblemSource(problem),
      repository: repository,
      zones: TimeZoneDatabase(),
      snapshots: snapshots,
    );

    // 块集合本身**完全合法**（一个 60 分钟的块，任务需要 180 分钟）。
    final proposal = ScheduleProposal(
      proposalId: 'blocked-proposal',
      inputHash: hash,
      algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
      planningWindow: _dayWindow(DateTime.utc(2026, 10, 5)),
      blocks: [
        PlannedBlock(
          id: 'one',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 9),
            endUtc: DateTime.utc(2026, 10, 5, 10),
          ),
        ),
      ],
      unscheduled: const [
        UnscheduledTask(
          taskId: 'task',
          shortageMinutes: 120,
          primaryReason: UnscheduledReason(
            code: UnscheduledReasonCode.unexplainedSchedulingFailure,
            placementRemainingMinutes: 120,
          ),
        ),
      ],
      conflicts: [
        PlanningConflict(
          code: ConflictCode.schedulingInvariantViolation,
          taskId: 'task',
        ),
      ],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: false,
        scheduledMinutes: 60,
        unscheduledMinutes: 120,
      ),
    );

    // 两种模式都必须被拦下：`allowPartial` **不是**"忽略阻断冲突"的同义词。
    for (final mode in PlanApplyMode.values) {
      final result = await service.apply(proposal, mode: mode);
      expect(
        result.status,
        ApplyPlanStatus.invalidProposal,
        reason:
            'mode=$mode 时引擎已经报告的阻断冲突必须立即返回 invalidProposal；'
            '放宽部分应用不得把它降级成"缺一部分"',
      );
      expect(
        result.conflicts.single.code,
        ConflictCode.schedulingInvariantViolation,
        reason: '返回的必须是引擎报告的那条冲突，而不是重新校验出来的别的',
      );
      expect(
        await database.select(database.planVersions).get(),
        isEmpty,
        reason: '更不许写库',
      );
    }
  });

  // B5：通知此前**只在应用启动时同步一次**（`main.dart` 里那唯一一处调用），因此应用开着的
  // 时候确认新计划、改截止时间都不会重排提醒——已排的提醒会与当前计划不一致。这三条把
  // "只有真的改变了计划才重新同步"钉住：漏了会退化成"提醒永远不更新"，多调了会退化成
  // "每次确认失败也重排一遍"，还会掩盖失败。
  group('B5 计划被真的改变后才重新同步提醒', () {
    var calls = 0;
    setUp(() => calls = 0);

    PlanApplicationService serviceOver(ScheduleProblem problem) =>
        PlanApplicationService(
          source: _ProblemSource(problem),
          repository: repository,
          zones: TimeZoneDatabase(),
          snapshots: const InputSnapshotBuilder(),
          onPlanChanged: () async => calls++,
        );

    test('应用成功时回调恰好一次', () async {
      const snapshots = InputSnapshotBuilder();
      final problem = _validationProblem();
      final hash = snapshots.hash(InputSnapshot(problem: problem));

      final result = await serviceOver(problem)
          .apply(_overrideProposal(inputHash: hash, override: null));

      expect(result.status, ApplyPlanStatus.applied);
      expect(calls, 1);
    });

    test('过期提案不回调（计划没变，重排只会掩盖这次确认失败）', () async {
      final result = await serviceOver(_validationProblem())
          .apply(_overrideProposal(inputHash: 'stale-hash', override: null));

      expect(result.status, ApplyPlanStatus.staleProposal);
      expect(calls, 0);
    });

    test('非法提案不回调', () async {
      const snapshots = InputSnapshotBuilder();
      final problem = _validationProblem();
      final hash = snapshots.hash(InputSnapshot(problem: problem));

      // 两个互相重叠的块：校验器必须拦下它，因此计划没有被改变。
      final result = await serviceOver(problem).apply(
        ScheduleProposal(
          proposalId: 'overlapping',
          inputHash: hash,
          algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
          planningWindow: _dayWindow(DateTime.utc(2026, 10, 5)),
          blocks: [
            PlannedBlock(
              id: 'one',
              taskId: 'task',
              range: TimeRange(
                startUtc: DateTime.utc(2026, 10, 5, 9),
                endUtc: DateTime.utc(2026, 10, 5, 10),
              ),
            ),
            PlannedBlock(
              id: 'two',
              taskId: 'task',
              range: TimeRange(
                startUtc: DateTime.utc(2026, 10, 5, 9, 30),
                endUtc: DateTime.utc(2026, 10, 5, 10, 30),
              ),
            ),
          ],
          unscheduled: const [],
          conflicts: const [],
          explanations: const [],
          metrics: const ProposalMetrics(
            isFullyFeasible: true,
            scheduledMinutes: 120,
            unscheduledMinutes: 0,
          ),
        ),
      );

      expect(result.status, ApplyPlanStatus.invalidProposal);
      expect(calls, 0);
    });
  });
}

/// 一天的半开窗口。**每个夹具用自己 problem 的窗口**，不填任意假窗口。
TimeRange _dayWindow(DateTime day) =>
    TimeRange(startUtc: day, endUtc: day.add(const Duration(days: 1)));

ScheduleProposal _proposal() {
  final start = DateTime.utc(2026, 10, 5, 9);
  final blocks = [
    for (var index = 0; index < 3; index++)
      PlannedBlock(
        id: 'block-$index',
        taskId: 'task',
        range: TimeRange(
          startUtc: start.add(Duration(hours: index)),
          endUtc: start.add(Duration(hours: index + 1)),
        ),
        explanationCode: 'priority',
      ),
  ];
  return ScheduleProposal(
    proposalId: 'proposal-1',
    inputHash: 'snapshot-hash',
    algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
    planningWindow: _dayWindow(DateTime.utc(2026, 10, 5)),
    blocks: blocks,
    unscheduled: const [],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: true,
      scheduledMinutes: 180,
      unscheduledMinutes: 0,
    ),
  );
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

ScheduleProblem _validationProblem() {
  final day = DateTime.utc(2026, 10, 5);
  final window = TimeRange(
    startUtc: day,
    endUtc: day.add(const Duration(days: 1)),
  );
  final zoneId = 'UTC';
  final rules = DefaultSettings.v1();
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: zoneId,
    tasks: const [
      SchedulableTask(
        id: 'task',
        requiredMinutes: 180,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      ),
    ],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'ignored',
  );
}

final class _ProblemSource implements ScheduleProblemSource {
  const _ProblemSource(this.problem);
  final ScheduleProblem problem;
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;
}

/// 按传入的一次性覆盖重新装配规则，模拟生产用 `RepositoryScheduleProblemSource`
/// 在 `resolveForWindow(override: ...)` 下的行为。
final class _OverrideAwareSource implements ScheduleProblemSource {
  _OverrideAwareSource(this.base);
  final ScheduleProblem base;
  ScheduleRuleOverride? received;

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async {
    received = override;
    if (override == null) return base;
    return _withRules(base, override.patch.applyTo(base.rules));
  }
}

ScheduleProblem _withRules(ScheduleProblem problem, PlanningRules rules) {
  final window = problem.planningWindow;
  final zoneId = problem.timeZoneId;
  final resolvedRules = rules;
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: zoneId,
    tasks: problem.tasks,
    fixedIntervals: problem.fixedIntervals,
    protectedIntervals: problem.protectedIntervals,
    lockedBlocks: problem.lockedBlocks,
    existingBlocks: problem.existingBlocks,
    rules: resolvedRules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: resolvedRules,
      timeZoneId: zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: resolvedRules,
      timeZoneId: zoneId,
    ),
    preferences: problem.preferences,
    inputHash: problem.inputHash,
  );
}

/// 版本闸门用例用的输入：单任务 60 分钟、窗口恰好一天、UTC。
ScheduleProblem _applyProblem() => _overrideProblem();

/// 一份**除了版本号之外全部合法**的提案。
///
/// 之所以能这样构造：`_overrideProblem()` 的任务要 60 分钟，而这里给一个
/// 10:00–11:00 的块，正好满足；窗口是一整天，块落在窗口内；没有 unscheduled、
/// 没有 conflicts、没有 adjustment 请求。因此"被拒"只可能来自版本这一条判据。
ScheduleProposal _applyProposal({
  required String inputHash,
  required String algorithmVersion,
}) => ScheduleProposal(
  proposalId: 'apply-proposal',
  inputHash: inputHash,
  algorithmVersion: algorithmVersion,
  planningWindow: TimeRange(
    startUtc: DateTime.utc(2026, 10, 5),
    endUtc: DateTime.utc(2026, 10, 6),
  ),
  blocks: [
    PlannedBlock(
      id: 'block-0',
      taskId: 'task',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 10),
        endUtc: DateTime.utc(2026, 10, 5, 11),
      ),
      explanationCode: 'priority',
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

ScheduleProblem _overrideProblem() {
  final day = DateTime.utc(2026, 10, 5);
  final window = TimeRange(
    startUtc: day,
    endUtc: day.add(const Duration(days: 1)),
  );
  final zoneId = 'UTC';
  final rules = DefaultSettings.v1();
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: zoneId,
    tasks: const [
      SchedulableTask(
        id: 'task',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      ),
    ],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'ignored',
  );
}

ScheduleProposal _overrideProposal({
  required String inputHash,
  required ScheduleRuleOverride? override,
}) => ScheduleProposal(
  proposalId: 'recovery-proposal',
  inputHash: inputHash,
  algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
  planningWindow: _dayWindow(DateTime.utc(2026, 10, 5)),
  blocks: [
    PlannedBlock(
      id: 'block-0',
      taskId: 'task',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 9),
        endUtc: DateTime.utc(2026, 10, 5, 10),
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
  ruleOverride: override,
);
