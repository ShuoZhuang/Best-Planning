import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class _FakeLifeAreas implements LifeAreaLookup {
  const _FakeLifeAreas([this.ids = const {}]);

  final Set<String> ids;

  @override
  Future<Set<String>> lifeTaskIds() async => ids;
}

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  // 2026-10-05 02:00Z == 2026-10-05 10:00 +08，周一。
  final clock = _FixedClock(DateTime.utc(2026, 10, 5, 2));
  final created = DateTime.utc(2026, 10, 1);

  PlannerTask task({
    required String id,
    required int minutes,
    TaskSplitMode splitMode = TaskSplitMode.splittable,
    DateTime? dueAtUtc,
  }) => PlannerTask(
    id: id,
    title: id,
    priority: TaskPriority.high,
    estimatedMinutes: minutes,
    remainingMinutes: minutes,
    dueAtUtc: dueAtUtc,
    energyLevel: TaskEnergyLevel.high,
    splitMode: splitMode,
    minChunkMinutes: splitMode == TaskSplitMode.continuous ? minutes : 30,
    maxChunkMinutes: splitMode == TaskSplitMode.continuous ? minutes : 90,
    status: TaskStatus.open,
    createdAtUtc: created,
    updatedAtUtc: created,
  );

  RepositoryScheduleProblemSource source({
    List<PlannerTask> tasks = const [],
    List<CalendarOccurrence> occurrences = const [],
    ConfirmedPlan? plan,
    Set<String> lifeTaskIds = const {},
  }) => RepositoryScheduleProblemSource(
    tasks: _FakeTasks(tasks),
    lifeAreas: _FakeLifeAreas(lifeTaskIds),
    calendar: _FakeCalendar(occurrences),
    settings: SettingsService(repository: MemorySettingsRepository()),
    plans: _FakePlans(plan),
    clock: clock,
    timeZoneId: zoneId,
    zones: zones,
  );

  test('生活标记来自领域推导并进入排程输入', () async {
    // 该字段此前从未被设置，导致生活配额因子恒为 0。
    final life = await source(
      tasks: [task(id: 'life-1', minutes: 60)],
      lifeTaskIds: {'life-1'},
    ).load();
    expect(life.tasks.single.isLifeTask, isTrue);

    final work = await source(tasks: [task(id: 'work-1', minutes: 60)]).load();
    expect(work.tasks.single.isLifeTask, isFalse);
  });

  test('按本机时区计算未来七天的规划窗口', () async {
    final problem = await source().load();

    // 东八区 2026-10-05 00:00 == 2026-10-04 16:00Z。
    expect(problem.planningWindow.startUtc, DateTime.utc(2026, 10, 4, 16));
    expect(problem.planningWindow.endUtc, DateTime.utc(2026, 10, 11, 16));
    expect(problem.timeZoneId, zoneId);
    expect(problem.inputHash, isNotEmpty);
  });

  test('把开放任务的剩余时长与固定日程映射进排程输入', () async {
    final problem = await source(
      tasks: [task(id: 'research', minutes: 180)],
      occurrences: [
        CalendarOccurrence(
          eventId: 'class-mon',
          title: '数据结构课',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5),
            endUtc: DateTime.utc(2026, 10, 5, 2),
          ),
          locked: true,
        ),
      ],
    ).load();

    expect(problem.tasks.length, 1);
    expect(problem.tasks.single.id, 'research');
    expect(problem.tasks.single.requiredMinutes, 180);
    expect(problem.fixedIntervals.length, 1);
    expect(problem.fixedIntervals.single.id, 'class-mon');
  });

  test('把保护时间逐日展开为窗口内的具体区间', () async {
    final problem = await source().load();

    // 默认午餐与晚餐各 7 天。
    expect(problem.protectedIntervals.length, 14);
    expect(
      problem.protectedIntervals.any(
        (item) => item.id.startsWith('protected:lunch:'),
      ),
      isTrue,
    );
  });

  test('只有已锁定的已确认计划块进入 lockedBlocks', () async {
    final problem = await source(
      tasks: [task(id: 'research', minutes: 180)],
      plan: ConfirmedPlan(
        id: 'plan-1',
        inputHash: 'hash',
        algorithmVersion: '2',
        blocks: [
          PlannedBlock(
            id: 'block-locked',
            taskId: 'research',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 10, 5, 2),
              endUtc: DateTime.utc(2026, 10, 5, 3, 30),
            ),
            locked: true,
          ),
          PlannedBlock(
            id: 'block-movable',
            taskId: 'research',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 10, 5, 4),
              endUtc: DateTime.utc(2026, 10, 5, 5),
            ),
          ),
        ],
      ),
    ).load();

    // 未锁定块不得冻结，否则重排无法移动任何内容。
    expect(problem.lockedBlocks.length, 1);
    expect(problem.lockedBlocks.single.id, 'block-locked');
  });

  test('装配出的输入可以直接交给排程引擎产出计划', () async {
    final problem = await source(
      tasks: [
        task(id: 'research', minutes: 180),
        task(
          id: 'paper',
          minutes: 120,
          splitMode: TaskSplitMode.continuous,
          dueAtUtc: DateTime.utc(2026, 10, 7, 2),
        ),
      ],
    ).load();

    final proposal = DeterministicScheduleEngine(zones).generate(problem);

    expect(proposal.algorithmVersion, DeterministicScheduleEngine.algorithmVersion);
    expect(proposal.metrics.scheduledMinutes, 300);
    expect(proposal.blocks, isNotEmpty);
    // 固定日程与保护时间不得被占用。
    for (final block in proposal.blocks) {
      expect(problem.planningWindow.contains(block.startUtc), isTrue);
    }
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime nowUtc() => instant;
}

final class _FakeTasks implements TaskRepository {
  _FakeTasks(this.items);
  final List<PlannerTask> items;
  @override
  Future<PlannerTask?> getById(String id) async =>
      items.where((item) => item.id == id).firstOrNull;
  @override
  Future<void> save(PlannerTask task) async {}
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(items);
}

final class _FakeCalendar implements CalendarRepository {
  _FakeCalendar(this.occurrences);
  final List<CalendarOccurrence> occurrences;
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => occurrences
      .where(
        (item) => item.range.overlaps(
          TimeRange(startUtc: startUtc, endUtc: endUtc),
        ),
      )
      .toList();
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _FakePlans implements PlanRepository {
  _FakePlans(this.plan);
  final ConfirmedPlan? plan;
  @override
  Future<ConfirmedPlan?> current() async => plan;
  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}
