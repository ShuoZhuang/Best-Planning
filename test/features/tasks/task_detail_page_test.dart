// 任务详情页：W3 缺失的"任务详情"路由 + R9 缺失的"修正剩余时长"界面入口。
//
// 关键断言不是"页面能渲染"，而是"从界面修正剩余时长之后，修正历史真的被写下来了"
// ——FR-TASK-05 要求的正是留下记录供统计使用，而这此前只有服务层与数据层、没有入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/task_correction_log.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';

final _now = DateTime.utc(2026, 10, 5, 2);

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
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;

  /// 全量监听：这里**刻意不过滤**，与生产 `TaskDao.watchAll` 同口径。
  @override
  Stream<List<PlannerTask>> watchAllTasks() async* {
    yield tasks.values.toList();
  }

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield tasks.values.where((task) => !task.status.isClosed).toList();
  }
}

final class _Corrections implements TaskCorrectionLog {
  final recorded = <RemainingMinutesCorrection>[];

  @override
  Future<void> record(RemainingMinutesCorrection correction) async =>
      recorded.add(correction);
}

final class _Workspace implements WorkspaceRepository {
  @override
  Future<List<PlannerArea>> listAreas() async => const [];

  @override
  Future<List<PlannerProject>> listProjects() async => const [];

  @override
  Future<void> saveArea(PlannerArea area) async {}

  @override
  Future<void> saveProject(PlannerProject project) async {}
}

PlannerTask _task({int remainingMinutes = 90}) => PlannerTask(
  id: 'task-1',
  title: '写方案',
  priority: TaskPriority.high,
  estimatedMinutes: 120,
  remainingMinutes: remainingMinutes,
  dueAtUtc: DateTime.utc(2026, 10, 20),
  energyLevel: TaskEnergyLevel.high,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  late _Tasks tasks;
  late _Corrections corrections;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({'task-1': _task()});
    corrections = _Corrections();
    service = TaskService(
      repository: tasks,
      workspace: _Workspace(),
      clock: const _Clock(),
      idGenerator: _Ids(),
      correctionLog: corrections,
    );
  });

  Future<void> pumpDetail(
    WidgetTester tester,
    String taskId, {
    bool dark = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? ThemeData.dark() : null,
        // 真实运行时这一页被塞进外壳的 Scaffold（`Expanded(child: child)`），
        // Chip 与 TextField 都要求 Material 祖先，因此这里同样提供 Scaffold，
        // 否则测的是"脱离外壳时能否构建"，而不是页面本身。
        home: Scaffold(
          body: TaskDetailPage(service: service, taskId: taskId, nowUtc: _now),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('展示任务事实与可用的修正入口', (tester) async {
    await pumpDetail(tester, 'task-1');

    expect(find.text('写方案'), findsOneWidget);
    expect(find.text('预计时长'), findsOneWidget);
    expect(find.text('120 分钟'), findsOneWidget);
    expect(find.text('剩余时长'), findsOneWidget);
    expect(find.text('90 分钟'), findsOneWidget);
    expect(find.text('修正剩余时长'), findsOneWidget);
    // 截止日期在 nowUtc 之后，不应显示逾期。
    expect(find.text('已逾期'), findsNothing);
  });

  testWidgets('深色主题下事实标签使用主题前景色而不是黑色', (tester) async {
    await pumpDetail(tester, 'task-1', dark: true);

    final label = find.text('预计时长');
    final text = tester.widget<Text>(label);
    final expected = Theme.of(tester.element(label))
        .colorScheme
        .onSurfaceVariant;
    expect(text.style?.color, expected);
    expect(text.style?.color, isNot(Colors.black54));
  });

  // FR-REPLAN-07：设置截止时间。页面把**本地**日期与"当天第几分钟"交回，换算由注入方完成
  // （真实装配里是持有 `zones` 的路由），因此这里注入一个记录用的回调，断言交回的正是用户
  // 挑的那一天、以及"当天 23:59"这个固定口径——口径若变，这条会失败。
  testWidgets('选定日期后把本地日期与当天 23:59 交给注入的设置入口', (tester) async {
    final recorded = <(DateTime, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: 'task-1',
            nowUtc: _now,
            onSetDueDate: (localDate, minute) async {
              recorded.add((localDate, minute));
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('set-due-date')));
    await tester.tap(find.byKey(const Key('set-due-date')));
    await tester.pumpAndSettle();
    // 该测试的 MaterialApp 未装配本地化代理，因此日期选择器用默认的英文标签。
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(recorded, hasLength(1));
    expect(recorded.single.$1.day, 20);
    expect(recorded.single.$2, 23 * 60 + 59);
  });

  // FR-REPLAN-07：处理入口之三——清除截止时间（"设置"那一半需先打通时区，见 §13.0 的 R9）。
  // 断言两半：存储里真的被置空，且入口随后消失（没有截止时间就不该再显示"清除"）。
  testWidgets('从界面清除截止时间会置空并隐藏该入口', (tester) async {
    await pumpDetail(tester, 'task-1');
    expect(tasks.tasks['task-1']!.dueAtUtc, isNotNull);
    expect(find.byKey(const Key('clear-due-date')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('clear-due-date')));
    await tester.tap(find.byKey(const Key('clear-due-date')));
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.dueAtUtc, isNull);
    expect(find.byKey(const Key('clear-due-date')), findsNothing);
    // 不断言界面上的"未设置"：期望时段为空时同一页也会显示该文案，全局计数会因无关字段
    // 而失败（我第一版就是这么写的，运行把它挡下了）。界面是否随之刷新由"入口消失"覆盖，
    // 存储是否真的被置空由上一行覆盖——两条都精确，胜过一次模糊的文案计数。
  });

  // FR-REPLAN-07：没有可行计划时，用户要能**就地**处置任务（这里是"取消事项"）。
  // 服务侧 `changeStatus` 早已存在，缺的只是入口，因此这条用例钉的正是"入口是否可达、
  // 点击是否真的落到存储"。
  testWidgets('从界面取消事项会把任务置为已取消，并隐藏该入口', (tester) async {
    await pumpDetail(tester, 'task-1');
    expect(find.byKey(const Key('cancel-task')), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-task')));
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.status, TaskStatus.cancelled);
    // 已取消之后不再显示入口：重复点击一个已经生效的动作没有意义。
    expect(find.byKey(const Key('cancel-task')), findsNothing);
  });

  // FR-REPLAN-07：处理入口之二——调整优先级。断言**按值**找到菜单项再点，因此不依赖
  // 界面文案；文案改动不该让这条用例失效，而"改变有没有落到存储"必须被钉住。
  testWidgets('从界面调整优先级会落到存储', (tester) async {
    await pumpDetail(tester, 'task-1');
    // fixture 里这一条是 high，因此这里切到 low——用"不等于当前值"的目标，
    // 否则即便入口根本没生效，断言也可能因为值本来就相同而通过。
    expect(tasks.tasks['task-1']!.priority, TaskPriority.high);

    await tester.tap(find.byKey(const Key('task-priority')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is DropdownMenuItem<TaskPriority> &&
            widget.value == TaskPriority.low,
      ),
    );
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.priority, TaskPriority.low);
  });

  testWidgets('从界面修正剩余时长会更新任务并留下修正历史', (tester) async {
    await pumpDetail(tester, 'task-1');

    await tester.enterText(find.byKey(const Key('remaining-minutes')), '150');
    // 页面较长，必须先滚动到可见位置再点，否则 tap 落在视口外不会生效。
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.remainingMinutes, 150);
    // 预计时长是原始估算，界面路径同样不得改写它。
    expect(tasks.tasks['task-1']!.estimatedMinutes, 120);

    expect(corrections.recorded, hasLength(1));
    expect(corrections.recorded.single.previousMinutes, 90);
    expect(corrections.recorded.single.correctedMinutes, 150);
    expect(corrections.recorded.single.correctedAtUtc, _now);

    expect(find.text('剩余时长已修正，并已记录修正历史'), findsOneWidget);
    expect(find.text('150 分钟'), findsOneWidget);
  });

  testWidgets('负剩余时长被拒绝且不留下历史', (tester) async {
    await pumpDetail(tester, 'task-1');

    // **0 现在是合法值**（见 §13.0 的 R9：剩余为 0 表示"没有剩余工作"，是"按专注重算"的
    // 合法结果），因此这里用负数验证拒绝路径——原来这条用例用 0，已随契约变更而更新。
    await tester.enterText(find.byKey(const Key('remaining-minutes')), '-5');
    // 页面较长，必须先滚动到可见位置再点，否则 tap 落在视口外不会生效。
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.remainingMinutes, 90);
    expect(corrections.recorded, isEmpty);
    expect(find.textContaining('剩余时长不能为负数'), findsOneWidget);
  });

  // FR-TASK-04：任务转固定日程。两条用例：交出的是**这条任务的标题**（转换的入口必须带上
  // 它，否则用户到了编辑器还要重新输入），以及**未接线时不显示按钮**（不留死控件）。
  testWidgets('转为固定日程把任务标题交给注入的入口，并提示任务仍在待办中', (tester) async {
    final titles = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: 'task-1',
            nowUtc: _now,
            onCreateEvent: titles.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('create-event-from-task')));
    await tester.tap(find.byKey(const Key('create-event-from-task')));
    await tester.pumpAndSettle();

    expect(titles, <String>[tasks.tasks['task-1']!.title]);
    // 提示不是装饰：默认选定"不动任务"，没有这句话用户就会把同一件事排两次。
    expect(find.textContaining('仍在待办中'), findsOneWidget);
  });

  testWidgets('未接线时不显示转为固定日程的入口', (tester) async {
    // 内联构造而不是复用 `pumpDetail`：这条用例要的正是"没有注入回调"的那种装配。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: 'task-1',
            nowUtc: _now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('create-event-from-task')), findsNothing);
  });

  testWidgets('任务不存在时明确说明而不是空白页', (tester) async {
    await pumpDetail(tester, 'missing');

    expect(find.text('任务不存在或已被永久删除'), findsOneWidget);
  });
  // FR-REPLAN-01 的"延期事项"（2026-10-04）：**延后**是独立入口，参数是"延后多久"。
  // 三条用例分别钉住：预设、**自定义时长**（用户要求"延后时间可自定义"）、以及零值当场被拦。
  testWidgets('延后：选预设 1 天后把 Duration(days: 1) 交给注入的入口', (tester) async {
    final recorded = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: 'task-1',
            nowUtc: _now,
            onDeferTask: (by) async {
              recorded.add(by);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('defer-task')));
    await tester.tap(find.byKey(const Key('defer-task')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('defer-1-days')));
    await tester.pumpAndSettle();

    expect(recorded, [const Duration(days: 1)]);
  });

  testWidgets('延后：自定义「5 天 6 小时」被原样交出', (tester) async {
    final recorded = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: 'task-1',
            nowUtc: _now,
            onDeferTask: (by) async {
              recorded.add(by);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('defer-task')));
    await tester.tap(find.byKey(const Key('defer-task')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('defer-days-input')), '5');
    await tester.enterText(find.byKey(const Key('defer-hours-input')), '6');
    await tester.tap(find.byKey(const Key('defer-confirm')));
    await tester.pumpAndSettle();

    expect(recorded, [
      const Duration(days: 5, hours: 6),
    ], reason: '自定义的天与小时必须原样交出，不能被四舍五入或只取天数');
  });

  testWidgets('延后：自定义填 0 时当场拦下，不调用入口', (tester) async {
    final recorded = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: 'task-1',
            nowUtc: _now,
            onDeferTask: (by) async {
              recorded.add(by);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('defer-task')));
    await tester.tap(find.byKey(const Key('defer-task')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('defer-days-input')), '0');
    await tester.enterText(find.byKey(const Key('defer-hours-input')), '0');
    await tester.tap(find.byKey(const Key('defer-confirm')));
    await tester.pumpAndSettle();

    expect(recorded, isEmpty, reason: '零延后什么都不该发生');
    expect(find.text('延后量必须大于 0'), findsOneWidget);
  });
}
