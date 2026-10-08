// §12.2/§12.3：任务清单的**路由装配**。
//
// 筛选逻辑与页面行为分别由 `task_list_filter_test.dart`（纯逻辑）与
// `task_list_status_filter_test.dart`（Widget）覆盖；这个文件只钉住一件在别处测不到的事：
// `/tasks` 这条路由**确实把既有的 `PlanRepository` 传给了 `TaskListPage`**。
//
// 为什么要单独测：Widget 测试是自己 `new` 出页面并注入替身的，因此即使路由那一行漏传了
// `plans`，那些用例照样全绿，而真实运行中"已安排"会永远是 0——这正是"测试通过但功能没接通"
// 的典型样子（本仓库在统计、专注等页面上已经吃过这个亏）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/tasks/task_list_filter.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 与路由的 `todayStartUtc`/`nowUtc` 同一个"现在"，让计划块与任务状态都可比。
final _now = DateTime.utc(2026, 10, 7, 12);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);

  final Map<String, PlannerTask> tasks;

  @override
  Stream<List<PlannerTask>> watchAllTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Stream<List<PlannerTask>> watchOpenTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;
}

/// 只回答"当前确认计划是什么"，与生产 `DriftPlanRepository.current()` 同型。
final class _Plans implements PlanRepository {
  _Plans(this.plan);
  final ConfirmedPlan? plan;

  @override
  Future<ConfirmedPlan?> current() async => plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

PlannerTask _task(String id, String title) => PlannerTask(
  id: id,
  title: title,
  notes: '',
  priority: TaskPriority.medium,
  estimatedMinutes: 30,
  remainingMinutes: 30,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  Future<void> pumpTasksRoute(
    WidgetTester tester, {
    PlanRepository? plans,
    Map<String, PlannerTask> tasks = const {},
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = createPlannerRouter(
      taskService: TaskService(
        repository: _Tasks({...tasks}),
        clock: const _Clock(),
        idGenerator: _Ids(),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: _now,
      nowUtc: _now,
      zones: TimeZoneDatabase(),
      timeZoneId: 'UTC',
      plans: plans,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/tasks');
    await tester.pumpAndSettle();
  }

  testWidgets('/tasks 把当前确认计划传给页面，"已安排"因此不是空的', (tester) async {
    await pumpTasksRoute(
      tester,
      tasks: {'t1': _task('t1', '算法作业'), 't2': _task('t2', '读书')},
      plans: _Plans(
        ConfirmedPlan(
          id: 'plan-1',
          inputHash: 'hash',
          algorithmVersion: 'v1',
          blocks: [
            PlannedBlock(
              id: 'b1',
              taskId: 't1',
              // 在"现在"之后结束，才算尚未结束。
              range: TimeRange(
                startUtc: DateTime.utc(2026, 10, 7, 13),
                endUtc: DateTime.utc(2026, 10, 7, 14, 30),
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.byType(TaskListPage), findsOneWidget);
    // 筛选栏现在是四个 `ChoiceChip`（M2 从 `SegmentedButton` 换过来：后者每个分段会在
    // 语义树里产生两个同名节点）。这里只确认四个筛选项都在。
    for (final filter in TaskListFilter.values) {
      expect(
        find.byKey(Key('task-filter-${filter.name}')),
        findsOneWidget,
        reason: '筛选项 ${filter.name} 应当在筛选栏里',
      );
    }

    // 计划真的被读到了：t1 已安排、t2 待安排。
    expect(
      tester
          .widget<Text>(find.byKey(const Key('task-filter-scheduled-label')))
          .data,
      '已安排 1',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('task-filter-unscheduled-label')))
          .data,
      '待安排 1',
    );
    expect(find.text('已安排 · 13:00–14:30'), findsOneWidget);
  });

  testWidgets('未装配计划仓储时 /tasks 仍然可用，全部归入待安排', (tester) async {
    await pumpTasksRoute(tester, tasks: {'t1': _task('t1', '算法作业')});

    expect(find.byType(TaskListPage), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('task-filter-scheduled-label')))
          .data,
      '已安排 0',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('task-filter-unscheduled-label')))
          .data,
      '待安排 1',
    );
  });

  testWidgets('子页面按 Esc 返回上一级（M2 §6：Esc 能返回上一级）', (tester) async {
    await pumpTasksRoute(tester, tasks: {'t1': _task('t1', '算法作业')});

    // 进入子页面：任务详情。此时外壳应当出现返回按钮（`_showsBackButton`）。
    tester.state<NavigatorState>(find.byType(Navigator).first);
    final context = tester.element(find.byType(TaskListPage));
    GoRouter.of(context).go('/tasks/t1');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('shell-back-button')),
      findsOneWidget,
      reason: '子页面应当有返回按钮（Esc 的接管条件与它一致）',
    );

    // 按 Esc —— 应当回到任务列表。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.byType(TaskListPage),
      findsOneWidget,
      reason: 'Esc 应当把子页面退回上一级',
    );
  });

  testWidgets('顶层页面按 Esc 不会被弹走（Esc 只在有返回按钮的页面生效）', (tester) async {
    await pumpTasksRoute(tester, tasks: {'t1': _task('t1', '算法作业')});
    expect(find.byKey(const Key('shell-back-button')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 仍在任务页：Esc 在顶层不该有副作用。
    expect(find.byType(TaskListPage), findsOneWidget);
  });
}
