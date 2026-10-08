// M6（路线图 §3.3 最后一条、§11 Task 8 Step 7）：**周视图／今日页数据源**上的周期进度徽标。
//
// 今日页那一侧由 `recurring_progress_test.dart` 用现成的条目数据驱动；这个文件补的是
// 上游那一半——**数据源真的把徽标挂上去了吗**。少了它，"页面画得对"与"数据永远为空"
// 可以同时成立，而那正是本仓库反复记录过的那类缺陷（结构就绪 ≠ 需求兑现）。
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';

final _now = DateTime.utc(2026, 10, 7, 4); // 本地 2026-10-07（周三）

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

void main() {
  late db.AppDatabase database;
  late DriftRecurringTaskRepository recurringRepository;
  late RecurringTaskService recurringTasks;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    recurringRepository = DriftRecurringTaskRepository(
      database,
      RecurringTaskDao(database),
    );
    recurringTasks = RecurringTaskService(
      repository: recurringRepository,
      clock: const _Clock(),
      idGenerator: UuidIdGenerator(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: DriftTaskRepository(database.taskDao),
    );
  });

  tearDown(() => database.close());

  /// 生成一个本周实例，并把它"排进"计划里（数据源只从**已确认计划块**里取条目）。
  Future<RecurringTaskCycleView> seedPlannedCycle({int recorded = 0}) async {
    final template = await recurringTasks.createTemplate(
      title: '每周英语',
      targetMinutes: 180,
      nowUtc: _now,
    );
    await recurringTasks.ensureCycles(
      TimeRange(startUtc: _now, endUtc: _now.add(const Duration(days: 7))),
      _now,
    );
    final cycle = await recurringRepository.findCycle(
      template.id,
      DateTime(2026, 10, 5),
    );
    if (recorded > 0) {
      await recurringTasks.recordManualMinutes(
        template.id,
        DateTime(2026, 10, 5),
        recorded,
      );
    }
    // 排进计划：数据源的条目来自 `plans.current()`，没有计划块就没有卡片。
    await database.customInsert(
      'INSERT INTO plan_versions ('
      'id, created_at_utc, input_hash, algorithm_version, status, summary_json'
      ") VALUES ('plan-1', ?, 'hash', '9', 'confirmed', '{}')",
      variables: [Variable<int>(_now.microsecondsSinceEpoch)],
    );
    await database.customInsert(
      'INSERT INTO schedule_blocks ('
      'id, plan_version_id, task_id, start_at_utc, end_at_utc, locked, '
      'explanation_code, created_at_utc, updated_at_utc'
      ") VALUES ('block-1', 'plan-1', ?, ?, ?, 0, 'priority', ?, ?)",
      variables: [
        Variable<String>(cycle!.taskId),
        Variable<int>(DateTime.utc(2026, 10, 7, 1).microsecondsSinceEpoch),
        Variable<int>(DateTime.utc(2026, 10, 7, 2).microsecondsSinceEpoch),
        Variable<int>(_now.microsecondsSinceEpoch),
        Variable<int>(_now.microsecondsSinceEpoch),
      ],
    );
    return RecurringTaskCycleView(cycle.taskId, template.id);
  }

  Future<List<ScheduleViewItem>> loadItems({bool withRecurring = true}) async {
    final settings = SettingsService(
      repository: DriftSettingsRepository(database, const _Clock()),
    );
    final source = RepositoryScheduleViewSource(
      tasks: DriftTaskRepository(database.taskDao),
      calendar: DriftCalendarRepository(database),
      plans: DriftPlanRepository(database, clock: const _Clock()),
      history: DriftPlanRepository(database, clock: const _Clock()),
      rules: PlanningRuleResolver(settings),
      colors: ScheduleColorService(
        settings: DriftSettingsRepository(database, const _Clock()),
        workspace: DriftWorkspaceRepository(database),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: const _Clock(),
      recurring: withRecurring ? recurringTasks : null,
    );
    return source
        .watch(DateTime.utc(2026, 10, 6, 16), DateTime.utc(2026, 10, 7, 16))
        .first;
  }

  test('本周实例的条目带上"本周已完成 x/y 分钟"徽标', () async {
    final seeded = await seedPlannedCycle(recorded: 80);

    final items = await loadItems();
    final item = items.singleWhere((entry) => entry.taskId == seeded.taskId);
    expect(item.recurringGoal, isNotNull);
    expect(item.recurringGoal!.targetMinutes, 180);
    expect(item.recurringGoal!.recordedMinutes, 80);
    expect(item.recurringGoal!.label, '本周已完成 80/180 分钟');
  });

  test('未装配周期服务时条目照常渲染，只是没有徽标', () async {
    final seeded = await seedPlannedCycle(recorded: 80);

    final items = await loadItems(withRecurring: false);
    final item = items.singleWhere((entry) => entry.taskId == seeded.taskId);
    expect(item.recurringGoal, isNull);
    expect(item.title, '每周英语', reason: '卡片本身不受影响');
  });

  test('徽标说的是"已完成"，不是"已安排"（§3.3）', () async {
    await seedPlannedCycle(recorded: 45);
    final items = await loadItems();
    final label = items
        .map((item) => item.recurringGoal?.label)
        .whereType<String>()
        .join();
    expect(label, contains('已完成'));
    expect(label, isNot(contains('已安排')));
  });
}

/// 播种结果：数据源用例只需要知道"哪条任务是这一周的实例"。
final class RecurringTaskCycleView {
  const RecurringTaskCycleView(this.taskId, this.templateId);
  final String taskId;
  final String templateId;
}
