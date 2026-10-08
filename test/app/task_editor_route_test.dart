// M3（路线图 §7）：新建任务路由的**装配与固定底栏**。
//
// 为什么单独测这一层：`task_editor_page_test.dart` 是裸挂 `TaskEditorPage`
// （`Scaffold(body: TaskEditorPage(...))`），它证明不了"放进真实外壳后底栏还在"。
// 真实外壳是 `_PlannerShell`，页面被塞进 `Expanded(child: child)`
// （即 `NavigationRail` 右侧那一格）。M3 之后 `TaskEditorPage` 的根是
// `Column(Expanded(滚动区), 底栏)`——**这种布局只有在高度有界时才成立**，
// 一旦哪天外壳改成放它进 `SingleChildScrollView`，这里会立刻炸成
// "RenderFlex children have non-zero flex but incoming height constraints are unbounded"。
// 那就是这条测试要挡的回归。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
// `MemoryAutoAdjustStore` 住在计划预览页里（与 `task_list_route_test.dart` 同一处引用）。
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/tasks/task_editor_page.dart';

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

/// 只要够 `TaskService` 构造即可；这条测试不读任务。
///
/// 成员严格按 `lib/domain/repositories/task_repository.dart` 的实际接口写
/// （四个成员：`watchOpenTasks`／`watchAllTasks`／`getById`／`save`）。
/// 早先我凭记忆多写了 `listAll`、`delete` 之类，analyzer 立刻以
/// `override_on_non_overriding_member` 报出来——那正是这套静态检查存在的意义。
final class _EmptyTasks implements TaskRepository {
  const _EmptyTasks();

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);

  @override
  Future<PlannerTask?> getById(EntityId id) async => null;

  @override
  Future<void> save(PlannerTask task) async {}
}

void main() {
  Future<void> pumpNewTaskRoute(WidgetTester tester) async {
    // 1280×720 是外壳的默认窗口尺寸，也是最容易把底栏挤出视口的尺寸。
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = createPlannerRouter(
      taskService: TaskService(
        repository: _EmptyTasks(),
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
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/tasks/new');
    await tester.pumpAndSettle();
  }

  testWidgets('M3 新建任务页在真实外壳里挂载成功，固定底栏与保存按钮都在', (tester) async {
    await pumpNewTaskRoute(tester);

    // 挂载本身就会在高度无界时报错；能走到这里说明 `Column + Expanded` 拿到了有界高度。
    expect(find.byType(TaskEditorPage), findsOneWidget);

    // §7 的固定底栏与它的两个组成部分。
    expect(find.byKey(const Key('task-save-bar')), findsOneWidget);
    expect(find.byKey(const Key('save-task')), findsOneWidget);
    expect(find.byKey(const Key('task-missing-fields')), findsOneWidget);
    expect(find.byKey(const Key('task-constraint-summary')), findsOneWidget);

    // 保存按钮不在滚动区里——这是"始终可见"的实现前提。
    expect(
      find.ancestor(
        of: find.byKey(const Key('save-task')),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
      reason: '保存按钮必须在固定底栏里，不能随内容滚动',
    );

    // 首屏七个字段在真实外壳里也都在（§7「表单结构」）。
    for (final key in const [
      'task-title',
      'task-estimated-minutes',
      'task-area',
      'task-project',
      'task-available-from',
      'task-due-at',
      'task-split-mode',
    ]) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '真实外壳里「$key」属于首屏固定字段',
      );
    }

    // §3 全局约束：不出现"先进入收集箱再详细设置"的路径。
    expect(find.textContaining('收集箱'), findsNothing);
  });
}
