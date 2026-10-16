// 1.8.0（设计规范 §11.4 第 3、4 条，计划 Task 12c）：调整前参照位置的装配。
//
// 规范要引擎按"少动块、少位移"排序，而这两项**天生是整体量**——必须是"与调整前相比"，
// 不可能从单块候选的分数里加出来。因此装配层要把**确认计划里每个块的开始时刻**交给引擎，
// 这就是 `ScheduleProblem.referenceBlocks`。
//
// 本文件钉三件事：
// 1. 已确认的块进参照；
// 2. **新排的块不进**——它没有"调整前"，塞进去会让位移恒为 0（等于免罚）；
// 3. 被跳过的块不进——它这一次不参与，谈不上移动。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
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
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/application/pending_skips.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  final clock = _FixedClock(DateTime.utc(2026, 10, 5, 2));
  final base = DateTime.utc(2026, 10, 5);

  PlannerTask task(String id) => PlannerTask(
    id: id,
    title: id,
    priority: TaskPriority.high,
    estimatedMinutes: 120,
    remainingMinutes: 120,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    status: TaskStatus.open,
    createdAtUtc: base,
    updatedAtUtc: base,
  );

  PlannedBlock block(String id, String taskId, {int hour = 9}) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: base.add(Duration(hours: hour)),
      endUtc: base.add(Duration(hours: hour + 1)),
    ),
  );

  Future<ScheduleProblem> load({
    List<PlannerTask> tasks = const [],
    ConfirmedPlan? plan,
    PendingSkipDrafts? skips,
  }) => RepositoryScheduleProblemSource(
    tasks: _Tasks(tasks),
    lifeAreas: _NoLifeAreas(),
    calendar: _NoCalendar(),
    settings: SettingsService(repository: MemorySettingsRepository()),
    plans: _Plan(plan),
    clock: clock,
    timeZoneId: zoneId,
    zones: zones,
    pendingSkips: skips,
  ).load();

  test('已确认的块进参考位置，值就是它当前的开始时刻', () async {
    final problem = await load(
      tasks: [task('t1')],
      plan: ConfirmedPlan(
        id: 'v1',
        inputHash: 'h1',
        algorithmVersion: 'test',
        blocks: [block('b1', 't1', hour: 9)],
      ),
    );
    expect(problem.referenceBlocks['b1'], base.add(const Duration(hours: 9)));
  });

  test('**新排的块不进参照**：它没有"调整前"', () async {
    // 计划里只有 b1；本次生成还会排 b2（概念上）。参照里不该出现任何没有确认记录的 id。
    final problem = await load(
      tasks: [task('t1')],
      plan: ConfirmedPlan(
        id: 'v1',
        inputHash: 'h1',
        algorithmVersion: 'test',
        blocks: [block('b1', 't1', hour: 9)],
      ),
    );

    expect(problem.referenceBlocks.keys, [
      'b1',
    ], reason: '把没有"调整前"的块塞进参照会让它的位移恒为 0，等于免罚');
  });

  test('被跳过的块不进参照：它这一次不参与', () async {
    final skips = PendingSkipDrafts()
      ..setRequestedSkip(const RequestedSkip(blockId: 'b2'));
    final problem = await load(
      tasks: [task('t1')],
      plan: ConfirmedPlan(
        id: 'v1',
        inputHash: 'h1',
        algorithmVersion: 'test',
        blocks: [block('b1', 't1', hour: 9), block('b2', 't1', hour: 11)],
      ),
      skips: skips,
    );

    expect(problem.referenceBlocks.containsKey('b1'), isTrue);
    expect(
      problem.referenceBlocks.containsKey('b2'),
      isFalse,
      reason: '被跳过的块这一次不参与排程，谈不上"被移动了多少"',
    );
  });

  test('没有已确认计划时参照为空，且不影响生成', () async {
    final problem = await load(tasks: [task('t1')]);

    expect(problem.referenceBlocks, isEmpty);
    expect(problem.inputHash, isNotEmpty);
  });

  test('参照**不进 inputHash**：两份只有参照不同的输入哈希相同', () async {
    // **这条断言的写法改过一次，原因值得记下来**：第一版拿"有确认计划"与"没有确认计划"
    // 两次装配做对比，但已确认的块会进 `existingBlocks`，而**那个集合本来就在哈希里**
    // （"移动代价"是排程事实）。两次的输入因此并不相同，哈希不同是**对的**。
    //
    // 要验的其实是更窄的一条：同一份排程输入、只有 `referenceBlocks` 不同时，
    // 哈希必须相同——否则"跟谁比"会变成排程事实，同一份输入会生成两份内容相同的提案。
    final fromSource = await load(
      tasks: [task('t1')],
      plan: ConfirmedPlan(
        id: 'v1',
        inputHash: 'h1',
        algorithmVersion: 'test',
        blocks: [block('b1', 't1', hour: 9)],
      ),
    );

    ScheduleProblem withReference(Map<String, DateTime> reference) {
      final window = fromSource.planningWindow;
      final problemTimeZoneId = fromSource.timeZoneId;
      final rules = fromSource.rules;
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: problemTimeZoneId,
        tasks: fromSource.tasks,
        fixedIntervals: fromSource.fixedIntervals,
        protectedIntervals: fromSource.protectedIntervals,
        lockedBlocks: fromSource.lockedBlocks,
        existingBlocks: fromSource.existingBlocks,
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: problemTimeZoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: problemTimeZoneId,
        ),
        preferences: fromSource.preferences,
        inputHash: fromSource.inputHash,
        referenceBlocks: reference,
      );
    }

    // 两次装配的其它字段**逐值相同**，只有参照不同。
    final withEmpty = withReference(const {});
    final withDifferent = withReference({
      'b1': DateTime.utc(2026, 10, 5, 3),
      'b2': DateTime.utc(2026, 10, 5, 5),
    });

    const builder = InputSnapshotBuilder();
    expect(
      builder.hash(InputSnapshot(problem: withDifferent)),
      builder.hash(InputSnapshot(problem: withEmpty)),
      reason: '参照是比较用的输入，不是排程事实；进哈希会制造出内容相同的两份提案',
    );
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Tasks implements TaskRepository {
  _Tasks(this.items);
  final List<PlannerTask> items;
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(items);
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(items);
  @override
  Future<PlannerTask?> getById(String id) async => null;
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

final class _Plan implements PlanRepository {
  _Plan(this.plan);
  final ConfirmedPlan? plan;
  @override
  Future<ConfirmedPlan?> current() async => plan;
  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}
