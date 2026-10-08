// M6（路线图 §11 Task 7 Step 1／Route）：新建类型选择器与三条周期路由的**真实装配**。
//
// Widget 测试是自己 new 出页面并注入回调的，因此即使 `router.dart` 里漏了一条路由、
// 或者把 `/tasks/new` 又指回了任务表单，那些用例照样全绿，而真实运行中点"周期目标"会
// 落到错误的地方——这正是"测试通过但功能没接通"的典型样子。
//
// 这个文件因此只钉**路由层**：进去哪一页、URL 是什么、缺服务时入口是否消失。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_detail_page.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_editor_page.dart';
import 'package:personal_planner/features/tasks/task_editor_page.dart';
import 'package:personal_planner/features/tasks/task_type_chooser.dart';

final _now = DateTime.utc(2026, 10, 7, 4); // 本地 2026-10-07（周三）

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

/// 只要够 `TaskService` 构造即可；本文件不读任务。
final class _EmptyTasks implements TaskRepository {
  const _EmptyTasks();

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);

  @override
  Future<PlannerTask?> getById(String id) async => null;

  @override
  Future<void> save(PlannerTask task) async {}
}

void main() {
  late db.AppDatabase database;
  late RecurringTaskService recurringTasks;
  late GoRouter routerRef;

  setUp(() {
    database = db.AppDatabase.forTesting(
      NativeDatabase.memory(),
      enforceForeignKeys: false,
    );
    recurringTasks = RecurringTaskService(
      repository: DriftRecurringTaskRepository(
        database,
        RecurringTaskDao(database),
      ),
      clock: const _Clock(),
      idGenerator: UuidIdGenerator(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: DriftTaskRepository(database.taskDao),
    );
  });

  tearDown(() => database.close());

  Future<void> pumpRouter(
    WidgetTester tester, {
    bool withRecurring = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = createPlannerRouter(
      taskService: TaskService(
        repository: const _EmptyTasks(),
        clock: const _Clock(),
        idGenerator: const _Ids(),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: _now,
      nowUtc: _now,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      recurringTasks: withRecurring ? recurringTasks : null,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    routerRef = router;
  }

  testWidgets('/tasks/new 是类型选择器，四条去向都在', (tester) async {
    await pumpRouter(tester);
    routerRef.go('/tasks/new');
    await tester.pumpAndSettle();

    expect(find.byType(TaskTypeChooserPage), findsOneWidget);
    // 这一条最容易被改回去：`/tasks/new` 曾经直接就是任务表单。
    expect(find.byType(TaskEditorPage), findsNothing);
    for (final label in const ['普通任务', '周期目标', '固定日程', '保护时间']) {
      expect(find.text(label), findsOneWidget, reason: '「$label」这条去向必须可见');
    }
  });

  testWidgets('点「普通任务」进任务表单', (tester) async {
    await pumpRouter(tester);
    routerRef.go('/tasks/new');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-type-task')));
    await tester.pumpAndSettle();

    expect(find.byType(TaskEditorPage), findsOneWidget);
  });

  testWidgets('点「周期目标」进周期编辑器', (tester) async {
    await pumpRouter(tester);
    routerRef.go('/tasks/new');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-type-recurring')));
    await tester.pumpAndSettle();

    expect(find.byType(RecurringTaskEditorPage), findsOneWidget);
    expect(find.text('新建周期目标'), findsOneWidget);
  });

  testWidgets('没有周期服务时不显示「周期目标」，也不注册那三条路由', (tester) async {
    await pumpRouter(tester, withRecurring: false);
    routerRef.go('/tasks/new');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-type-recurring')), findsNothing);
    expect(find.text('普通任务'), findsOneWidget);

    // 直达也该落到"没有这一页"，而不是渲染一个半成品编辑器。
    routerRef.go('/tasks/recurring/new');
    await tester.pumpAndSettle();
    expect(find.byType(RecurringTaskEditorPage), findsNothing);
  });

  testWidgets('保存后进详情页，URL 是 /tasks/recurring/:templateId', (tester) async {
    await pumpRouter(tester);
    routerRef.go('/tasks/recurring/new');
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('recurring-title')), '每周英语');
    final saveFinder = find.byKey(const Key('save-recurring'));
    await tester.ensureVisible(saveFinder);
    await tester.pumpAndSettle();
    await tester.tap(saveFinder, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(RecurringTaskDetailPage), findsOneWidget);
    expect(find.text('每周英语'), findsWidgets);
    final templates = await recurringTasks.repository.listTemplates();
    expect(templates, hasLength(1));
    expect(
      routerRef.routeInformationProvider.value.uri.path,
      '/tasks/recurring/${templates.single.id}',
      reason: '详情页的 URL 必须由模板 id 组成，刷新与深链才可用',
    );
  });

  testWidgets('/tasks/recurring/:id 直达详情页，且不被 /tasks/:taskId 截走', (
    tester,
  ) async {
    final template = await recurringTasks.createTemplate(
      title: '每周跑步',
      targetMinutes: 120,
      nowUtc: _now,
    );
    await pumpRouter(tester);

    routerRef.go('/tasks/recurring/${template.id}');
    await tester.pumpAndSettle();

    // 若 `/tasks/:taskId` 先匹配，这里会变成任务详情（它拿 'recurring' 当任务 id）。
    expect(find.byType(RecurringTaskDetailPage), findsOneWidget);
    expect(find.text('每周跑步'), findsWidgets);
  });

  testWidgets('不存在的模板 id 给出说明页，而不是崩溃或空白', (tester) async {
    await pumpRouter(tester);
    routerRef.go('/tasks/recurring/nobody');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recurring-detail-missing')), findsOneWidget);
  });

  testWidgets('周期编辑器可取消回到类型选择器', (tester) async {
    await pumpRouter(tester);
    routerRef.go('/tasks/recurring/new');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cancel-recurring')));
    await tester.pumpAndSettle();

    expect(find.byType(TaskTypeChooserPage), findsOneWidget);
  });
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id-${DateTime.now().microsecondsSinceEpoch}';
}
