// 用户 2026-10-08 人工验收报告（**发布阻断**）：
// 「看不到新建的周期目标，也无法正常管理周期目标。」
//
// ## 根因
//
// `TaskListPage` 只订阅 `TaskService.watchAllTasks()`——**普通任务**。周期目标存的是
// `recurring_task_templates`（另一张表），因此它**从头到尾没有出现在任何列表里**。
//
// 后果不只是"看不到"：周期目标有编辑、暂停、跳过本周、停止以后生成这些管理动作，
// 而它们的入口全在**周期详情页**，详情页的路由是 `/tasks/recurring/:templateId`——
// 没有列表就没有入口，于是用户建完之后**再也回不到那个页面**。这是"创建即失联"。
//
// 这与新建入口无关：类型选择器、编辑器、详情页、历史列表都在，路由也在；
// 缺的只是**从列表进详情**这一步。
//
// ## 这个文件测什么
//
// ① 列表页出现"周期目标"分组，且列出已建的模板（标题与目标时长）；
// ② 点其中一条会带着它的 templateId 请求打开详情——入口必须真的通到那个页面；
// ③ 端口未装配时整组不渲染（不给死入口，与本应用其它端口同一口径）；
// ④ 一个周期目标都没有时，整组不渲染（空壳分组只是噪音）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';

final _now = DateTime.utc(2026, 10, 8, 4); // 东八区 2026-10-08 12:00

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
  late RecurringTaskService recurring;

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
  });

  tearDown(() => database.close());

  Future<RecurringTaskTemplate> createGoal({
    String title = '每周英语',
    int target = 180,
  }) => recurring.createTemplate(
    title: title,
    targetMinutes: target,
    priority: TaskPriority.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    startsOnLocalDate: DateTime(2026, 10, 5),
    nowUtc: _now,
  );

  Future<void> pump(
    WidgetTester tester, {
    RecurringTaskService? service,
    void Function(String templateId)? onOpenRecurring,
    // **默认取一个偏窄偏矮的窗口**：分组在小窗口里被挤到看不见，正是"看不到周期目标"
    // 最可能的解释。用 1100×900 那种宽裕画布去测，等于把这个风险测没了。
    Size size = const Size(900, 600),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListPage(
            service: TaskService(
              repository: const _EmptyTasks(),
              clock: const _Clock(),
              idGenerator: _Ids(),
            ),
            nowUtc: _now,
            recurringTasks: service,
            onOpenRecurringTask: onOpenRecurring,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('**列表里能看到周期目标**，且显示标题与目标时长', (tester) async {
    await createGoal();
    await pump(tester, service: recurring, onOpenRecurring: (_) {});

    expect(find.text('周期目标'), findsWidgets, reason: '没有这个分组，用户建完就再也找不到它');
    expect(find.text('每周英语'), findsOneWidget);
    expect(find.textContaining('180'), findsWidgets, reason: '目标时长要露出来');
  });

  testWidgets('**点一条会请求打开它的详情页**（这是"能管理"的前提）', (tester) async {
    final goal = await createGoal();
    String? opened;
    await pump(
      tester,
      service: recurring,
      onOpenRecurring: (templateId) => opened = templateId,
    );

    await tester.tap(find.text('每周英语'));
    await tester.pumpAndSettle();

    expect(opened, goal.id, reason: '不带 templateId 就打不开详情页，用户仍然无法管理它');
  });

  testWidgets('端口未装配时整组不渲染（不给死入口）', (tester) async {
    await createGoal();
    await pump(tester); // 不传 service

    expect(find.text('周期目标'), findsNothing);
  });

  testWidgets('一个周期目标都没有时整组不渲染（空壳分组只是噪音）', (tester) async {
    await pump(tester, service: recurring, onOpenRecurring: (_) {});

    expect(find.text('周期目标'), findsNothing);
  });
}
