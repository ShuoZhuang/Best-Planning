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
import 'package:personal_planner/domain/repositories/task_correction_log.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
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
      clock: const _Clock(),
      idGenerator: _Ids(),
      correctionLog: corrections,
    );
  });

  Future<void> pumpDetail(WidgetTester tester, String taskId) async {
    await tester.pumpWidget(
      MaterialApp(
        // 真实运行时这一页被塞进外壳的 Scaffold（`Expanded(child: child)`），
        // Chip 与 TextField 都要求 Material 祖先，因此这里同样提供 Scaffold，
        // 否则测的是"脱离外壳时能否构建"，而不是页面本身。
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            taskId: taskId,
            nowUtc: _now,
          ),
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

  testWidgets('非正剩余时长被拒绝且不留下历史', (tester) async {
    await pumpDetail(tester, 'task-1');

    await tester.enterText(find.byKey(const Key('remaining-minutes')), '0');
    // 页面较长，必须先滚动到可见位置再点，否则 tap 落在视口外不会生效。
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.remainingMinutes, 90);
    expect(corrections.recorded, isEmpty);
    expect(find.textContaining('剩余时长必须大于 0'), findsOneWidget);
  });

  testWidgets('任务不存在时明确说明而不是空白页', (tester) async {
    await pumpDetail(tester, 'missing');

    expect(find.text('任务不存在或已被永久删除'), findsOneWidget);
  });
}
