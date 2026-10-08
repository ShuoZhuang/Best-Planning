// M4（路线图 §8）：今日页执行动作的**路由装配**。
//
// `today_page_test.dart` 是裸挂 `TodayPage` 并自己注入回调的，因此它证明不了
// "真实装配里回调接上了服务与路由"——那正是本文件要钉的：
//
//   · 「开始专注」是否真的跳到 `/focus/<taskId>`；
//   · 「完成」是否真的把任务状态改成 `completed`（而不是只调了个没人接的回调）；
//   · 「查看详情」是否真的跳到 `/tasks/<taskId>`。
//
// 这与 `task_list_route_test.dart`、`task_editor_route_test.dart` 存在的理由相同：
// 页面测试全绿、而路由那一行漏了参数，是这类缺陷最典型的样子。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/pending_skips.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/focus/focus_page.dart';
import 'package:personal_planner/features/today/today_page.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

/// 与路由的 `todayStartUtc` 同一个"今天"。
final _today = DateTime.utc(2026, 10, 7);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _today.add(const Duration(hours: 10, minutes: 30));
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

/// 内存任务仓储：`changeStatus` 会经 `TaskService` 落到这里，因此"点完成"是可观察的。
final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);

  final Map<String, PlannerTask> tasks;

  @override
  Stream<List<PlannerTask>> watchAllTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(
    tasks.values.where((task) => task.status == TaskStatus.open).toList(),
  );

  @override
  Future<PlannerTask?> getById(EntityId id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;
}

/// 给这一页喂一条**正在进行**的任务块（10:00–11:00，而"现在"是 10:30）。
final class _OngoingSource implements ScheduleViewSource {
  const _OngoingSource();

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value([
        ScheduleViewItem(
          id: 'block:b1',
          title: '算法作业',
          kind: ScheduleItemKind.task,
          range: TimeRange(
            startUtc: _today.add(const Duration(hours: 10)),
            endUtc: _today.add(const Duration(hours: 11)),
          ),
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: 0xff456789,
          categorySortOrder: 0,
          taskId: 't1',
        ),
      ]);
}

/// 专注服务的最小替身。
///
/// **必须装配它**：路由里 `onStartFocus` 是 `focusService == null ? null : ...`，
/// 因此不装配时「开始专注」**按设计不渲染**——那样就测不到这条入口了。
final class _MemoryFocus implements FocusEntryStore {
  FocusSession? _open;

  @override
  Future<FocusSession?> findOpen() async => _open;

  @override
  Future<void> save(FocusSession session) async => _open = session;

  @override
  Future<List<FocusSession>> confirmedEntries() async => const [];
}

PlannerTask _task(String id, String title) => PlannerTask(
  id: id,
  title: title,
  estimatedMinutes: 60,
  remainingMinutes: 60,
  priority: TaskPriority.medium,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  Future<({_Tasks repository, void Function() dispose})> pumpTodayRoute(
    WidgetTester tester, {
    PendingSkipDrafts? skips,
    PlanningService? planning,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = _Tasks({'t1': _task('t1', '算法作业')});
    final router = createPlannerRouter(
      taskService: TaskService(
        repository: repository,
        clock: const _Clock(),
        idGenerator: _Ids(),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const _OngoingSource(),
      focusService: FocusService(
        store: _MemoryFocus(),
        clock: const _Clock(),
        monotonicClock: CallbackMonotonicClock(() => Duration.zero),
        idGenerator: _Ids(),
      ),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      pendingSkips: skips,
      planningService: planning,
      todayStartUtc: _today,
      nowUtc: _today.add(const Duration(hours: 10, minutes: 30)),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/today');
    await tester.pumpAndSettle();
    return (repository: repository, dispose: () {});
  }

  testWidgets('M4 /today 装配后，「开始专注」与「完成」都在卡片上', (tester) async {
    await pumpTodayRoute(tester);

    expect(find.byType(TodayPage), findsOneWidget);
    expect(
      find.byKey(const Key('today-start-focus-block:b1')),
      findsOneWidget,
      reason: '真实装配里「开始专注」必须出现在当前安排卡片上',
    );
    expect(find.byKey(const Key('today-complete-block:b1')), findsOneWidget);
  });

  // M4 §8 退出条件第 1 条："从今日页开始专注**不超过两次点击**"。
  //
  // **为什么值得单独一条**：原来那条断言只说明「开始专注」这个按钮**在卡片上存在**，
  // 而"两次点击"是**计数**——存在按钮**不等于**计数满足（比如中间还夹着一个确认弹窗、
  // 或者按钮只展开了菜单）。这一条把计数**直接测出来**：进今日页（0 次点击，
  // 用 `router.go` 到达）→ 点 1 次 → 必须落到专注页。
  testWidgets('M4 从今日页点 1 次就进专注页（含进页面共 2 步，满足"不超过两次点击"）', (tester) async {
    await pumpTodayRoute(tester);

    // 前置：还没进专注页。
    expect(find.byType(FocusPage), findsNothing, reason: '前置条件：刚进今日页');

    await tester.tap(find.byKey(const Key('today-start-focus-block:b1')));
    await tester.pumpAndSettle();

    expect(
      find.byType(FocusPage),
      findsOneWidget,
      reason:
          '点「开始专注」必须**直接**到专注页。'
          '若这里红掉，说明中间多了一步（确认弹窗／二级菜单），'
          '"不超过两次点击"就不再成立',
    );
  });

  testWidgets('M4 点「完成」真的把任务状态改成 completed', (tester) async {
    final harness = await pumpTodayRoute(tester);
    expect(
      (await harness.repository.getById('t1'))!.status,
      TaskStatus.open,
      reason: '前置条件：点之前是未完成',
    );

    await tester.tap(find.byKey(const Key('today-complete-block:b1')));
    await tester.pumpAndSettle();

    // 这一条是"回调接上了服务"的证据：页面测试只证明回调被调用，
    // 证明不了路由那边真的把它接到了 `TaskService.changeStatus`。
    expect(
      (await harness.repository.getById('t1'))!.status,
      TaskStatus.completed,
    );
  });

  testWidgets('M4 点「查看详情」跳到该任务详情页', (tester) async {
    await pumpTodayRoute(tester);

    await tester.tap(find.byKey(const Key('today-more-block:b1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();

    // 详情页会渲染任务标题；断言它出现即可说明导航真的发生了。
    expect(find.text('算法作业'), findsWidgets);
    // 并且已经离开今日页。
    expect(find.byType(TodayPage), findsNothing);
  });

  testWidgets('M4 未装配跳过端口时，菜单里不出现「跳过本次」', (tester) async {
    // 与「开始专注」同一口径：端口为空就不显示入口，
    // 而不是给一个点了没反应的菜单项。
    await pumpTodayRoute(tester);

    await tester.tap(find.byKey(const Key('today-more-block:b1')));
    await tester.pumpAndSettle();
    expect(find.text('跳过本次'), findsNothing);
    expect(find.text('查看详情'), findsOneWidget);
  });

  testWidgets('M4 点「跳过本次」把**计划块 id** 记进 pendingSkips', (tester) async {
    // 这是"跳过本次"最关键的一环：页面交回的是**视图条目**（id 形如 `block:<块 id>`），
    // 而排程输入要认的是**计划块 id**。路由必须把前者翻译成后者——
    // 若直接塞视图 id，`pendingSkips.forBlock('<真实块 id>')` 永远匹配不上，
    // 症状是"点了跳过没反应"，而且不报错。这条测试专门挡它。
    final skips = PendingSkipDrafts();
    // `onSkipCurrent` 需要 `planningService` 非空才会渲染。给一个"输入恒定"的服务：
    // 它不会挂住，因为内部没有任何等待外部资源的异步操作。
    final planning = PlanningService(
      source: _EmptyProblemSource(),
      engine: DeterministicScheduleEngine(TimeZoneDatabase()),
    );
    await pumpTodayRoute(tester, skips: skips, planning: planning);

    await tester.tap(find.byKey(const Key('today-more-block:b1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过本次'));
    await tester.pump();
    await tester.pump();

    expect(skips.length, 1, reason: '跳过意图必须被记下');
    expect(
      skips.forBlock('b1'),
      isNotNull,
      reason:
          '记下的必须是**计划块 id**（`b1`），不是视图条目 id（`block:b1`）。'
          '实际记下的是：${skips.all.map((item) => item.blockId).toList()}',
    );
  });
}

/// 一个**立即返回**的排程问题来源：只要求 `planningService` 非空好让入口渲染，
/// 不关心排程结果。
///
/// **为什么不接真实的数据库装配**：第一版那么写了（真实 `RepositoryScheduleProblemSource`
/// + 内存数据库），结果这条用例**挂住**——widget 测试里驱动一整套真实排程与导航，
/// `pumpAndSettle` 永远等不到静止。这里改成"提交输入恒定、引擎自己算"，代价是这个替身
/// 要构造一个 `ScheduleProblem`。
///
/// **为什么这不是在编造领域对象**：`PlanningRules` / `PreferenceProfile` 都是
/// **值对象**，字段就是它们的全部含义；这里用与 `emergency_replan_flow_test.dart`
/// 同一套取值（默认作息 23:30–07:30、专注 50 分钟），而不是随便填。
/// 装配层的真实行为由 `test/application/pending_skips_test.dart` 覆盖，
/// 那条路径用的是**真实**的 `RepositoryScheduleProblemSource`。
final class _EmptyProblemSource implements ScheduleProblemSource {
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      ScheduleProblem(
        planningWindow: TimeRange(
          startUtc: _today,
          endUtc: _today.add(const Duration(days: 1)),
        ),
        timeZoneId: 'Asia/Shanghai',
        tasks: const [],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: PlanningRules(
          energyWindows: const [],
          sleepRange: LocalTimeRange(startMinute: 1410, endMinute: 450),
          minimumSleepMinutes: 420,
          defaultFocusMinutes: 50,
          breakMinutes: 10,
          dailyMovableTaskLimitMinutes: 300,
          weeklyLifeQuotaMinutes: 1200,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'empty',
      );
}
