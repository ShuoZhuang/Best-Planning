// W3：专注计时的路由与入口。
//
// 页面、状态机、崩溃恢复与异常确认早已实现并有测试，但 `/focus/:taskId` 从来不是一条路由，
// 也没有任何界面指向它，因此计时在真实运行中完全不可达。这里验证的是**可达性**：从任务清单
// 到详情、再从详情进入专注；计时语义本身由 focus_service_test 与 recovery_dialog_test 覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/focus/focus_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 2);
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

/// 内存专注记录，与 drift 实现同语义（保存即覆盖当前那条）。
final class _MemoryFocus implements FocusEntryStore {
  FocusSession? _open;
  final List<FocusSession> finished = [];

  @override
  Future<FocusSession?> findOpen() async => _open;

  @override
  Future<void> save(FocusSession session) async {
    _open = session;
    if (session.phase == FocusPhase.finished) finished.add(session);
  }

  @override
  Future<List<FocusSession>> confirmedEntries() async => finished;
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);
  final Map<String, PlannerTask> tasks;

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield tasks.values.where((task) => !task.status.isClosed).toList();
  }
}

PlannerTask _task() => PlannerTask(
  id: 'task-1',
  title: '写方案',
  priority: TaskPriority.high,
  estimatedMinutes: 120,
  remainingMinutes: 120,
  energyLevel: TaskEnergyLevel.high,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  FocusService buildFocus() => FocusService(
    store: _MemoryFocus(),
    clock: const _Clock(),
    monotonicClock: CallbackMonotonicClock(() => Duration.zero),
    idGenerator: _Ids(),
  );

  TaskService buildTasks(Map<String, PlannerTask> tasks) => TaskService(
    repository: _Tasks(tasks),
    clock: const _Clock(),
    idGenerator: _Ids(),
  );

  Future<void> pumpApp(
    WidgetTester tester, {
    FocusService? focusService,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          settingsRepository: settings,
          taskRepository: _Tasks({'task-1': _task()}),
          focusService: focusService,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('从任务清单经详情进入专注计时', (tester) async {
    final focus = buildFocus();
    await pumpApp(tester, focusService: focus);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看详情'));
    await tester.pumpAndSettle();

    final startFocus = find.byKey(const Key('start-focus'));
    expect(startFocus, findsOneWidget);
    await tester.ensureVisible(startFocus);
    await tester.tap(startFocus);
    await tester.pumpAndSettle();

    expect(find.byType(FocusPage), findsOneWidget);
    // 专注页需要"任务身份"，因此路由器必须先把任务读出来。
    expect(find.text('写方案'), findsOneWidget);

    // 计时真的可用：点开始后进入 running。
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.textContaining('running'), findsOneWidget);
    expect(focus.current?.taskId, 'task-1');
  });

  testWidgets('未装配专注服务时详情页不显示入口', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看详情'));
    await tester.pumpAndSettle();

    // 宁可没有按钮，也不要一个点了没反应的控件。
    expect(find.byKey(const Key('start-focus')), findsNothing);
  });

  testWidgets('任务不存在时专注路由说明原因而不是空标题', (tester) async {
    // 直接构造路由器：任务不存在这条分支只能经 URL 到达（通知 payload 的 route 也会
    // 指向任务，而任务可能已被永久清除）。
    final router = createPlannerRouter(
      taskService: buildTasks(const {}),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: DateTime.utc(2026, 10, 5),
      zones: TimeZoneDatabase(),
      timeZoneId: 'UTC',
      focusService: buildFocus(),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    router.go('/focus/missing');
    await tester.pumpAndSettle();

    expect(find.text('该任务不存在或已被永久删除，无法计时。'), findsOneWidget);
    expect(find.byType(FocusPage), findsNothing);
  });

  testWidgets('未装配专注服务时专注路由说明原因', (tester) async {
    final router = createPlannerRouter(
      taskService: buildTasks({'task-1': _task()}),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: DateTime.utc(2026, 10, 5),
      zones: TimeZoneDatabase(),
      timeZoneId: 'UTC',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    router.go('/focus/task-1');
    await tester.pumpAndSettle();

    expect(find.text('专注服务未装配，暂无法计时。'), findsOneWidget);
    expect(find.byType(FocusPage), findsNothing);
  });
}
