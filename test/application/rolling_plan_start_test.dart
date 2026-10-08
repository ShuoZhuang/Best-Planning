// Task 12A Step 5（用户 2026-10-08 追加的发布阻断项）：当天滚动规划的起点不得早于"现在"。
//
// 与 `repository_schedule_problem_source_test.dart` 里那条的区别：那条钉的是**窗口**（问题的
// 输入端），这条钉的是**结果**（引擎真的没把块放进过去）。只钉输入端是不够的——窗口对了但引擎
// 用了别的"现在"，症状完全一样，而且更难查。
//
// 实测过的现象：窗口起点原先是当天本地午夜，而引擎判断"现在"用的正是
// `planningWindow.startUtc`（`_targetFor` 里 `nowUtc: problem.planningWindow.startUtc`）。
// 于是下午生成计划时，日程里会冒出当天上午的块——它们已经过去了。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

/// 本地 2026-10-05 15:30（东八区）== 07:30Z。**下午**，不是凌晨——这是本条用例的关键。
final _afternoonUtc = DateTime.utc(2026, 10, 5, 7, 30);
const _zoneId = 'Asia/Shanghai';

final class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

final class _Tasks implements TaskRepository {
  _Tasks(this.items);
  final List<PlannerTask> items;
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(items);
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(items);
  @override
  Future<PlannerTask?> getById(String id) async =>
      items.where((item) => item.id == id).firstOrNull;
  @override
  Future<void> save(PlannerTask task) async {}
}

final class _LifeAreas implements LifeAreaLookup {
  const _LifeAreas();
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

final class _Calendar implements CalendarRepository {
  const _Calendar();
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Plans implements PlanRepository {
  const _Plans();
  @override
  Future<ConfirmedPlan?> current() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final zones = TimeZoneDatabase();
  final created = DateTime.utc(2026, 10, 1);

  PlannerTask task() => PlannerTask(
    id: 'research',
    title: 'research',
    priority: TaskPriority.high,
    estimatedMinutes: 60,
    remainingMinutes: 60,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: created,
    updatedAtUtc: created,
  );

  Future<List<DateTime>> plannedStarts() async {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: const _LifeAreas(),
      calendar: const _Calendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: const _Plans(),
      clock: _Clock(_afternoonUtc),
      timeZoneId: _zoneId,
      zones: zones,
    );
    final problem = await source.load();
    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    return [for (final block in proposal.blocks) block.startUtc];
  }

  test('下午 15:30 生成计划 ⇒ 没有任何新增块落在 15:30 之前', () async {
    final starts = await plannedStarts();

    expect(starts, isNotEmpty, reason: '一整天都空着，60 分钟任务必须排得进去');
    for (final start in starts) {
      expect(
        start.isBefore(_afternoonUtc),
        isFalse,
        reason:
            '排出了 ${start.toIso8601String()}，而"现在"是 '
            '${_afternoonUtc.toIso8601String()}——已经过去的时段不是可用容量',
      );
    }
  });

  test('起点对齐到排程粒度（5 分钟网格），不是任意毫秒', () async {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: const _LifeAreas(),
      calendar: const _Calendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: const _Plans(),
      clock: _Clock(DateTime.utc(2026, 10, 5, 7, 32)), // 本地 15:32
      timeZoneId: _zoneId,
      zones: zones,
    );
    final problem = await source.load();

    // 15:32 → 15:35，向上取整（就近取整会变成 15:30，那又放回了 2 分钟过去时段）。
    expect(problem.planningWindow.startUtc, DateTime.utc(2026, 10, 5, 7, 35));
    expect(
      problem.planningWindow.startUtc.minute % 5,
      0,
      reason: '引擎只在 5 分钟网格上放置片段，起点必须落在同一网格上',
    );
  });

  test('窗口终点仍是"本地日边界 + 七天"，长度语义没被改动', () async {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: const _LifeAreas(),
      calendar: const _Calendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: const _Plans(),
      clock: _Clock(_afternoonUtc),
      timeZoneId: _zoneId,
      zones: zones,
    );
    final problem = await source.load();

    // 本地 10-12 00:00 == 10-11 16:00Z。
    expect(problem.planningWindow.endUtc, DateTime.utc(2026, 10, 11, 16));
  });
}
