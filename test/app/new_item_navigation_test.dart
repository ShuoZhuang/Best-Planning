// 1.8.0（设计规范 §7，计划 Task 5）：新建入口的归属与侧栏高亮。
//
// 两个缺陷一起钉在这里，因为它们同源——"新建"这个动作属于哪个模块，路由与侧栏
// 必须给出同一个答案（§2.9）：
//
// 1. `_PlannerShell._selectedIndex` 只精确识别 `/tasks`，于是 `/tasks/new`、
//    `/tasks/new/task` 与周期目标子路由都落进默认的「今日」——**新建普通任务时
//    侧栏高亮的是"今日"**，这就是"创建不同事项时侧栏看起来归属不同"的直接原因。
// 2. 全局入口是 `/tasks/new`：它把"保护时间"送去设置页（`/settings/rules`），于是
//    侧栏高亮"设置"，而用户以为自己新建的是日历里的一段时间（§2.8）。
//
// 第一个缺陷只能靠纯函数钉住：`NavigationRail.selectedIndex` 为 `null` 与为 `0`
// 在视觉上都能"看起来有个高亮"，只有把映射抽成返回值可空、可断言的纯函数才测得准。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/planner_rail_index.dart';
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
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/tasks/task_type_chooser.dart';

void main() {
  // ── 路由归属表（Step 1）──────────────────────────────────────────────────

  group('侧栏归属表', () {
    test('业务栏的前缀各自归位', () {
      expect(plannerRailIndexForLocation('/today'), 0);
      expect(plannerRailIndexForLocation('/tasks'), 1);
      expect(plannerRailIndexForLocation('/workspace'), 2);
      expect(plannerRailIndexForLocation('/calendar'), 3);
      expect(plannerRailIndexForLocation('/analytics'), 4);
      expect(plannerRailIndexForLocation('/settings'), 5);
    });

    test('子路由按前缀归到所属模块（修复前这些全落进"今日"）', () {
      // 这三条正是缺陷本身：`/tasks/new` 与 `/tasks/new/task` 修复前高亮「今日」。
      expect(plannerRailIndexForLocation('/tasks/new'), 1);
      expect(plannerRailIndexForLocation('/tasks/new/task'), 1);
      expect(plannerRailIndexForLocation('/tasks/recurring/new'), 1);
      expect(plannerRailIndexForLocation('/tasks/recurring/tpl-1/edit'), 1);
      expect(plannerRailIndexForLocation('/tasks/abc-123'), 1);

      expect(plannerRailIndexForLocation('/calendar/new'), 3);
      expect(plannerRailIndexForLocation('/calendar/protected/new'), 3);
      expect(plannerRailIndexForLocation('/calendar/day/1759536000000000'), 3);
      expect(plannerRailIndexForLocation('/calendar/courses'), 3);
      expect(
        plannerRailIndexForLocation('/calendar/courses/course-calc-a'),
        3,
        reason: '课程详情的深链带的是 logicalCourseId，前缀仍是 /calendar（规范 §10.1）',
      );

      expect(plannerRailIndexForLocation('/settings/rules'), 5);
    });

    test('/new 本身不高亮任何业务栏（规范 §7.1 默认取"不高亮"）', () {
      expect(plannerRailIndexForLocation('/new'), isNull);
    });

    test('未知路径不高亮，而不是默默回落到"今日"', () {
      // 回落成 0 会让用户在一个不存在的页面里看到"今日"被选中——那是一个谎。
      expect(plannerRailIndexForLocation('/wat'), isNull);
      expect(plannerRailIndexForLocation(''), isNull);
      expect(plannerRailIndexForLocation('/unknown/deep/link'), isNull);
    });

    test('前缀匹配的边界被明确接受：/tasksomething 也算"任务"', () {
      // 规范 §7.2 写的是 `startsWith('/tasks')`，因此这是一个**已知且被接受的**后果：
      // `/tasksomething` 会高亮"任务"。它落地在 404（那条路由不存在），所以用户看不到
      // 一个"高亮了但页面是错的"的状态；而改成"按路径段匹配"会让
      // `/tasks/new/task`、`/calendar/protected/new` 这些真实子路由的判定更绕。
      // 这条用例把取舍写下来，免得以后有人把它当缺陷去"修"。
      expect(plannerRailIndexForLocation('/tasksomething'), 1);
    });
  });

  // ── 选择器分组（Step 2）──────────────────────────────────────────────────

  group('新建事项选择器', () {
    Widget chooser(void Function(PlannerNewItemKind) onSelect) => MaterialApp(
      home: Scaffold(body: TaskTypeChooserPage(onSelect: onSelect)),
    );

    testWidgets('标题是"新建事项"，且分成任务与时间占用两组', (tester) async {
      await tester.pumpWidget(chooser((_) {}));
      await tester.pumpAndSettle();

      expect(find.text('新建事项'), findsOneWidget);
      expect(find.text('任务'), findsOneWidget);
      expect(find.text('时间占用'), findsOneWidget);
      // 分组之后不再有旧的单层说明。
      expect(find.text('新建'), findsNothing);
    });

    testWidgets('四张卡都在，且各自进入正确路径', (tester) async {
      final selected = <PlannerNewItemKind>[];
      await tester.pumpWidget(chooser(selected.add));
      await tester.pumpAndSettle();

      for (final entry in {
        PlannerNewItemKind.task: 'new-type-task',
        PlannerNewItemKind.recurringGoal: 'new-type-recurring',
        PlannerNewItemKind.fixedEvent: 'new-type-fixed-event',
        PlannerNewItemKind.protectedTime: 'new-type-protected-time',
      }.entries) {
        await tester.tap(find.byKey(Key(entry.value)));
        await tester.pumpAndSettle();
        expect(
          selected.last,
          entry.key,
          reason: '${entry.value} 必须选中 ${entry.key}',
        );
      }
    });

    testWidgets('保护时间的卡片属于"时间占用"，不再是设置页的入口', (tester) async {
      await tester.pumpWidget(chooser((_) {}));
      await tester.pumpAndSettle();

      final group = find.ancestor(
        of: find.byKey(const Key('new-type-protected-time')),
        matching: find.byType(Column),
      );
      expect(group, findsWidgets);
      // 保护时间的描述里不能再出现"设置"。
      expect(find.textContaining('设置'), findsNothing);
    });

    testWidgets('某一类不可达时那一张卡不渲染（不给死入口）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskTypeChooserPage(
              onSelect: (_) {},
              isAvailable: (kind) => kind != PlannerNewItemKind.recurringGoal,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('new-type-recurring')), findsNothing);
      expect(find.byKey(const Key('new-type-task')), findsOneWidget);
      // 整组都不可达时组标题也不该孤零零留着。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskTypeChooserPage(
              onSelect: (_) {},
              isAvailable: (kind) =>
                  kind == PlannerNewItemKind.task ||
                  kind == PlannerNewItemKind.recurringGoal,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('时间占用'), findsNothing);
      expect(find.text('任务'), findsOneWidget);
    });

    testWidgets('顶部的返回按钮回到发起入口（规范 §7.1）', (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskTypeChooserPage(onSelect: (_) {}, onBack: () => backs++),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('new-item-back')));
      await tester.pumpAndSettle();
      expect(backs, 1);
    });
  });

  // ── 真实外壳里的归属（Step 6）──────────────────────────────────────────
  //
  // 这一组**刻意用真实的 `createPlannerRouter`**，而不是直接构造页面：要测的正是
  // "路由算出来的位置"与"侧栏据此高亮的那一栏"是否一致。裸挂页面的话，被丢掉的那一环
  // 恰好就是缺陷所在。
  group('真实外壳里的侧栏高亮', () {
    Future<GoRouter> pumpRouter(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = createPlannerRouter(
        taskService: TaskService(
          repository: _EmptyTasks(),
          clock: const _FixedClock(),
          idGenerator: _Ids(),
        ),
        settingsService: SettingsService(
          repository: MemorySettingsRepository(),
        ),
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
      return router;
    }

    int? railIndex(WidgetTester tester) => tester
        .widget<NavigationRail>(find.byType(NavigationRail))
        .selectedIndex;

    testWidgets('/tasks 高亮"任务"', (tester) async {
      final router = await pumpRouter(tester);

      router.go('/tasks');
      await tester.pumpAndSettle();

      expect(railIndex(tester), 1);
    });

    testWidgets('/tasks/new/task 高亮"任务"，不再高亮"今日"', (tester) async {
      final router = await pumpRouter(tester);

      router.go('/tasks/new/task');
      await tester.pumpAndSettle();

      expect(railIndex(tester), 1, reason: '新建普通任务时侧栏必须高亮"任务"。修复前这里是 0（今日）');
    });

    testWidgets('/calendar 高亮"日历"（对照：确认这条本来就对）', (tester) async {
      final router = await pumpRouter(tester);

      router.go('/calendar');
      await tester.pumpAndSettle();

      expect(railIndex(tester), 3);
    });

    testWidgets('/new 不高亮任何业务栏（规范 §7.1）', (tester) async {
      final router = await pumpRouter(tester);

      router.go('/new');
      await tester.pumpAndSettle();

      expect(find.text('新建事项'), findsOneWidget);
      expect(
        railIndex(tester),
        isNull,
        reason: '§7.1：/new 本身不高亮任何业务栏，实现只能二选一，默认取"不高亮"',
      );
    });

    testWidgets('旧的 /tasks/new 深链重定向到 /new，不失效', (tester) async {
      final router = await pumpRouter(tester);

      router.go('/tasks/new');
      await tester.pumpAndSettle();

      expect(find.text('新建事项'), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/new',
        reason: '计划 Task 5 Step 4：保留旧深链的重定向',
      );
      expect(railIndex(tester), isNull);
    });
  });
}

final _now = DateTime.utc(2026, 10, 7, 12);

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

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
