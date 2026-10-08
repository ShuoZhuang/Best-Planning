// 用户 2026-10-08 实测报告（发布阻断）：**保存周期任务后重新规划，计划里不显示它。**
//
// ## 根因
//
// `ensureCycles`（生成"本周 + 下周"的周期实例）**只在启动时跑一次**（`main.dart` 的
// `unawaited(() async { … ensureCycles … })`）。而 `RepositoryScheduleProblemSource`
// 的 `_recurringInputs` 里写的是：
//
// ```dart
// final cycle = await service.repository.findCycle(template.id, period.startLocalDate);
// if (cycle == null) continue;   // ← 没有实例就**静默跳过**
// ```
//
// 于是**会话中途**新建的周期目标当周没有任何实例，`_recurringInputs` 把它跳过，计划里
// 自然不出现。用户必须重启程序才看得到——而界面上没有任何提示说"重启一下"。
//
// 这与"创建时立刻生成实例"是两回事：`recurring_task_service.dart` 的注释明确说明
// **不在创建时生成**（生成是一条独立、幂等的路径）。因此正确的修法是**让读路径先补齐**：
// 排程输入被读取之前，先把窗口内的实例生成出来。
//
// ## 这个文件测什么
//
// 钉的是**发生与顺序**：`load()` 之后周期目标必须出现在排程输入里。不断言生成的确切次数
// ——那是实现细节。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

final _now = DateTime.utc(2026, 10, 8, 4); // 东八区 2026-10-08 12:00（周四）

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'id-${++_n}';
}

final class _NoLifeAreas implements LifeAreaLookup {
  const _NoLifeAreas();
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

final class _NoCalendar implements CalendarRepository {
  const _NoCalendar();
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  Future<void> save(CalendarEvent event) async {}
}

/// 本文件不读也不写计划。用 `noSuchMethod` 而不是逐个实现方法：`PlanRepository` 的方法会随
/// 功能增长，逐条实现会让这个只关心排程输入的替身每次都要跟着改。
final class _NoPlans implements PlanRepository {
  const _NoPlans();
  @override
  Future<ConfirmedPlan?> current() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late db.AppDatabase database;
  late RecurringTaskService recurring;
  late RepositoryScheduleProblemSource source;

  setUp(() {
    database = db.AppDatabase.forTesting(
      NativeDatabase.memory(),
      enforceForeignKeys: false,
    );
    recurring = RecurringTaskService(
      repository: DriftRecurringTaskRepository(
        database,
        RecurringTaskDao(database),
      ),
      clock: const _Clock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: DriftTaskRepository(database.taskDao),
    );
    source = RepositoryScheduleProblemSource(
      tasks: DriftTaskRepository(database.taskDao),
      lifeAreas: const _NoLifeAreas(),
      calendar: const _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: const _NoPlans(),
      clock: const _Clock(),
      timeZoneId: 'Asia/Shanghai',
      zones: TimeZoneDatabase(),
      recurring: recurring,
    );
  });

  tearDown(() => database.close());

  /// 建一个周期目标并返回它的模板 id 与当周实例 id。
  Future<({String templateId, String taskId})> createWeeklyGoal() async {
    final template = await recurring.createTemplate(
      title: '每周英语',
      targetMinutes: 180,
      priority: TaskPriority.high,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 60,
      startsOnLocalDate: DateTime(2026, 10, 5), // 本周一
      nowUtc: _now,
    );
    return (
      templateId: template.id,
      taskId: 'recurring:${template.id}:2026-10-05',
    );
  }

  test('**会话中途新建的周期目标，下一次 load() 就能进排程**（用户报告的缺陷）', () async {
    final goal = await createWeeklyGoal();
    final period = recurring.periodContaining(_now);
    expect(
      await recurring.repository.findCycle(
        goal.templateId,
        period.startLocalDate,
      ),
      isNull,
      reason:
          '前置条件：创建模板本身**不**生成实例（刻意的，见 service 注释），'
          '而生成只在启动时跑过一次——这正是缺陷的土壤',
    );

    // 缺陷点：修好之前 `_recurringInputs` 会因为"没有实例"而静默跳过。
    final problem = await source.load();

    expect(
      problem.tasks.map((task) => task.id),
      contains(goal.taskId),
      reason:
          '保存周期目标之后生成计划，它必须出现在排程输入里；'
          '修好之前这里为空，用户必须重启程序才看得到',
    );
  });

  test('进排程的是**周期视角**那一份（只送剩余、带截止与单日配额）', () async {
    final goal = await createWeeklyGoal();
    final problem = await source.load();

    final task = problem.tasks.firstWhere((item) => item.id == goal.taskId);
    expect(task.requiredMinutes, 180, reason: '目标 180、已记录 0 ⇒ 送 180');
    expect(
      task.dueAtUtc,
      isNotNull,
      reason: '截止＝本周末，由 `RecurringPace.even` 的那份输入给出',
    );
    expect(task.maxMinutesPerLocalDay, isNotNull, reason: '均匀分布带单日配额');
  });

  test('**幂等**：连续两次 load() 不会把同一周生成两份实例', () async {
    final goal = await createWeeklyGoal();
    await source.load();
    await source.load();

    final cycles = await recurring.repository.listCyclesForTemplate(
      goal.templateId,
    );
    final period = recurring.periodContaining(_now);
    expect(
      cycles.where(
        (cycle) => cycle.periodStartLocalDate == period.startLocalDate,
      ),
      hasLength(1),
      reason: '读路径会重复触发生成，因此幂等必须由 (模板, 周) 主键保证',
    );
  });
}
