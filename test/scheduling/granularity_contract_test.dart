// 1.8.0（2026-10-12 故障；冻结决策 §1.4）：**粒度只有一个事实源**。
//
// 修复前的分裂：
//   · `RepositoryScheduleProblemSource` 把窗口起点按**默认 5 分钟**向上取整；
//   · `DeterministicScheduleEngine` 用 `const CandidateGenerator()`（也是默认 5 分钟）；
//   · 而 `AvailabilityBuilder` 与 `ScheduleProblem.rules.granularityMinutes` 用的是**规则值**。
//
// 用户把排程粒度配成 10 分钟时，"现在"与"网格"在两处各算一遍：窗口起点可能落在 09:35
// 这种 5 分钟点上，而规则说的是 10 分钟。这个文件用**规则 10 分钟 + 09:33** 把三处钉在一起。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();

  /// 09:33 本地 —— **刻意落在 10 分钟网格之外**：若某处仍在用默认 5 分钟，
  /// 起点会变成 09:35（5 分钟网格），于是"10 分钟网格"这条断言立刻红。
  final nowUtc = zones.localDateTimeToUtc(
    DateTime.utc(2026, 10, 12),
    9 * 60 + 33,
    zoneId,
  );

  PlannerTask task() => PlannerTask(
    id: 't-grid',
    title: '网格任务',
    priority: TaskPriority.medium,
    estimatedMinutes: 60,
    remainingMinutes: 60,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 20,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: nowUtc,
    updatedAtUtc: nowUtc,
  );

  /// 规则把粒度改成 `granularityMinutes`（默认是 5）。
  ///
  /// **走真实设置链**（`saveUserRules` → `resolveForDate`）而不是假仓储：
  /// 粒度是"用户设置里的一项"，因此这条路径本身就是契约的一部分
  /// （顺带证明 `PlanningRulesPatch.granularityMinutes` 真的能落进规则）。
  Future<SettingsService> settingsWith(int granularityMinutes) async {
    final repository = MemorySettingsRepository();
    final service = SettingsService(repository: repository);
    await service.saveUserRules(
      UserPlanningRules(
        common: PlanningRulesPatch(granularityMinutes: granularityMinutes),
      ),
    );
    return service;
  }

  Future<RepositoryScheduleProblemSource> sourceWith(
    int granularityMinutes,
  ) async => RepositoryScheduleProblemSource(
    tasks: _Tasks([task()]),
    lifeAreas: _NoLifeAreas(),
    calendar: _NoCalendar(),
    settings: await settingsWith(granularityMinutes),
    plans: const _NoPlan(),
    clock: _Clock(nowUtc),
    timeZoneId: zoneId,
    zones: zones,
  );

  test('**规划窗口起点按规则粒度向上取整**：09:33 + 10 分钟 ⇒ 09:40', () async {
    final problem = await (await sourceWith(10)).load();
    final localStart = zones.toLocal(problem.planningWindow.startUtc, zoneId);

    expect(
      localStart.hour * 60 + localStart.minute,
      9 * 60 + 40,
      reason:
          '09:33 向上取整到 10 分钟网格是 09:40。'
          '若得到 09:35，说明这里仍在用默认 5 分钟（修复前的缺陷）。',
    );
    expect(problem.rules.granularityMinutes, 10);
  });

  test('**候选生成器的粒度来自规则**，不是默认 5 分钟', () {
    // 规则 10：候选起止与时长都落在 10 分钟网格上。
    final generator = CandidateGenerator(granularityMinutes: 10);
    final start = zones.localDateTimeToUtc(
      DateTime.utc(2026, 10, 12),
      9 * 60,
      zoneId,
    );
    final candidates = generator.generate(
      const SchedulableTask(
        id: 't-grid',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 20,
        maxChunkMinutes: 60,
      ),
      [
        AvailabilitySlot(
          range: TimeRange(
            startUtc: start,
            endUtc: start.add(const Duration(hours: 6)),
          ),
          localDate: DateTime(2026, 10, 12),
        ),
      ],
      remainingMinutes: 60,
    );

    expect(candidates, isNotEmpty);
    for (final candidate in candidates) {
      expect(
        candidate.durationMinutes % 10,
        0,
        reason: '规则 10 ⇒ 每个候选时长都是 10 的倍数',
      );
      expect(
        candidate.startUtc.difference(start).inMinutes % 10,
        0,
        reason: '规则 10 ⇒ 起点落在 10 分钟网格上',
      );
    }
    expect(candidates.map((c) => c.durationMinutes).toSet(), {
      20,
      30,
      40,
      50,
      60,
    }, reason: '最小片段 20 向上取整到 10 分钟网格仍是 20；上限 60');
  });

  test('**引擎产出的每个块都对齐规则粒度，且校验器接受它**', () async {
    final problem = await (await sourceWith(10)).load();
    final proposal = await PlanningService(
      source: _FixedSource(problem),
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();

    expect(proposal.blocks, isNotEmpty, reason: '前置条件：得真的排出东西来');
    final granularity = problem.rules.granularityMinutes;
    for (final block in proposal.blocks) {
      expect(
        block.startUtc.microsecondsSinceEpoch %
                Duration(minutes: granularity).inMicroseconds ==
            0,
        isTrue,
        reason: '块起点必须落在 $granularity 分钟网格上（UTC 纪元对齐）',
      );
      expect(
        block.durationMinutes % granularity,
        0,
        reason: '块时长必须是 $granularity 分钟的整数倍',
      );
    }

    // **生成器与校验器必须互相接受**：这正是 R4 的契约分裂所在。
    final conflicts = PlanValidator(zones).validate(problem, proposal.blocks);
    expect(
      conflicts.where((c) => c.code == ConflictCode.invalidInput),
      isEmpty,
      reason: '校验器不得拒绝生成器自己的产物',
    );
  });

  test('**切回规则 5 分钟时边界也跟着变**（不是把 10 写死）', () async {
    final problem = await (await sourceWith(5)).load();
    final localStart = zones.toLocal(problem.planningWindow.startUtc, zoneId);
    expect(localStart.hour * 60 + localStart.minute, 9 * 60 + 35);
  });

  test('**校验器按规则粒度判网格**：5 分钟块在 10 分钟规则下是 offGranularity', () {
    final start = zones.localDateTimeToUtc(
      DateTime.utc(2026, 10, 12),
      10 * 60,
      zoneId,
    );
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: start,
        endUtc: start.add(const Duration(hours: 8)),
      ),
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 't-grid',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 20,
          maxChunkMinutes: 60,
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: _rules(granularityMinutes: 10),
      preferences: const PreferenceProfile(),
      inputHash: 'grid',
    );
    final conflicts = PlanValidator(zones).validate(problem, [
      PlannedBlock(
        id: 'b-5min',
        taskId: 't-grid',
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 25)),
        ),
      ),
    ]);

    expect(
      conflicts.map((c) => c.invalidInputReason),
      contains(InvalidInputReason.offGranularity),
      reason: '25 分钟不是 10 的倍数 ⇒ 必须报网格错误，而不是笼统的"排程输入无效"',
    );
  });
}

PlanningRules _rules({required int granularityMinutes}) => PlanningRules(
  energyWindows: const [],
  sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
  minimumSleepMinutes: 420,
  defaultFocusMinutes: 50,
  breakMinutes: 10,
  dailyMovableTaskLimitMinutes: 600,
  weeklyLifeQuotaMinutes: 0,
  granularityMinutes: granularityMinutes,
);

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Tasks implements TaskRepository {
  const _Tasks(this.tasks);
  final List<PlannerTask> tasks;

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(tasks);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(tasks);

  @override
  Future<PlannerTask?> getById(String id) async =>
      tasks.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {}
}

final class _NoLifeAreas implements LifeAreaLookup {
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

final class _NoCalendar implements CalendarRepository {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoPlan implements PlanRepository {
  const _NoPlan();

  @override
  Future<ConfirmedPlan?> current() async => null;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) => throw UnimplementedError();
}

final class _FixedSource implements ScheduleProblemSource {
  const _FixedSource(this.problem);
  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;
}
