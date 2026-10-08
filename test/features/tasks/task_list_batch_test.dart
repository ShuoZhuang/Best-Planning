// FR-TASK-03：任务清单的**批量状态变更**。
//
// 此前清单页只能逐条勾选完成，没有任何多选入口，因此"批量调整和状态变更"这一半需求
// 无从完成（§13.0 的 R9）。本文件钉住三件事：多选语义确实切换（点行=选中，而不是完成）、
// 批量动作只作用于被选中的任务、以及空选择时按钮不可用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';

final _now = DateTime.utc(2026, 10, 2, 9);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'generated';
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);

  final Map<String, PlannerTask> tasks;

  /// 全量监听；这个替身没有数据库，因此"全部"与"未结束"共用一份数据。
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

PlannerTask _task(
  String id,
  String title, {
  TaskPriority priority = TaskPriority.medium,
}) => PlannerTask(
  id: id,
  title: title,
  notes: '',
  priority: priority,
  estimatedMinutes: 30,
  remainingMinutes: 30,
  dueAtUtc: null,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  late _Tasks tasks;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({
      'task-1': _task('task-1', '写方案'),
      'task-2': _task('task-2', '读论文'),
      'task-3': _task('task-3', '跑步'),
    });
    service = TaskService(
      repository: tasks,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListPage(service: service, nowUtc: _now),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('进入多选后点行是选中而不是完成，批量只作用于所选项', (tester) async {
    await pumpList(tester);
    expect(find.byKey(const Key('batch-cancel')), findsNothing);

    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写方案'));
    await tester.tap(find.text('读论文'));
    await tester.pumpAndSettle();

    // 选中不等于完成：真正的完成状态由批量动作之后才发生。
    expect(find.text('已选 2'), findsOneWidget);
    expect(tasks.tasks['task-1']!.status, TaskStatus.open);

    await tester.tap(find.byKey(const Key('batch-cancel')));
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.status, TaskStatus.cancelled);
    expect(tasks.tasks['task-2']!.status, TaskStatus.cancelled);
    // 未被选中的一条必须原样不动——这是"批量"最容易做错的地方。
    expect(tasks.tasks['task-3']!.status, TaskStatus.open);
    expect(find.text('已取消 2 项'), findsOneWidget);
  });

  testWidgets('批量改写优先级只作用于所选项', (tester) async {
    await pumpList(tester);
    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写方案'));
    await tester.tap(find.text('跑步'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('batch-priority')));
    await tester.pumpAndSettle();
    // 按**值**找到菜单项，文案改动不会让这条用例悄悄失效。
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is DropdownMenuItem<TaskPriority> &&
            widget.value == TaskPriority.urgent,
      ),
    );
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.priority, TaskPriority.urgent);
    expect(tasks.tasks['task-3']!.priority, TaskPriority.urgent);
    // 未选中的一条必须原样不动——与批量取消同理，这是"批量"最容易做错的地方。
    expect(tasks.tasks['task-2']!.priority, TaskPriority.medium);
    expect(find.text('已把 2 项设为该优先级'), findsOneWidget);
  });

  testWidgets('排序真的改变呈现顺序：默认序与按优先级序相反', (tester) async {
    // 让三条优先级不同，否则"按优先级排序"与默认序无法区分。
    tasks.tasks['task-2'] = _task(
      'task-2',
      '读论文',
      priority: TaskPriority.urgent,
    );
    tasks.tasks['task-3'] = _task('task-3', '跑步', priority: TaskPriority.low);
    await pumpList(tester);

    double y(String title) => tester.getTopLeft(find.text(title)).dy;

    // 默认是仓储顺序（录入顺序）：task-1 在最前。
    expect(y('写方案'), lessThan(y('读论文')));

    await tester.tap(find.byKey(const Key('task-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按优先级').last);
    await tester.pumpAndSettle();

    // 按优先级后顺序**反转**：urgent 在前、low 在最后。
    // 只断言"三条都还在"是不够的——那与顺序无关，排序坏掉也照样通过。
    expect(y('读论文'), lessThan(y('写方案')));
    expect(y('写方案'), lessThan(y('跑步')));
  });

  testWidgets('批量设截止日期把整批交给注入方一次，且只作用于所选项', (tester) async {
    final recorded = <(List<String>, DateTime, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListPage(
            service: service,
            nowUtc: _now,
            onSetDueDateForSelection: (ids, localDate, minute) async {
              recorded.add((ids, localDate, minute));
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写方案'));
    await tester.tap(find.text('跑步'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('batch-due-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // **一次**调用带整批 id：逐条回调会让换算重复做，且中途失败更难解释。
    expect(recorded, hasLength(1));
    expect(recorded.single.$1, hasLength(2));
    expect(recorded.single.$1, containsAll(<String>['task-1', 'task-3']));
    expect(recorded.single.$1, isNot(contains('task-2')));
    expect(recorded.single.$2.day, 20);
    // 当天本地 23:59：与单条"设置截止时间"同一口径。
    expect(recorded.single.$3, 1439);
    expect(find.text('已把 2 项设为该截止日期'), findsOneWidget);
  });

  testWidgets('空选择时批量取消不可用', (tester) async {
    await pumpList(tester);
    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('batch-cancel')),
    );
    // 给出一个作用不到任何对象的按钮，只会让人怀疑它坏了。
    expect(button.onPressed, isNull);
    expect(find.text('已选 0'), findsOneWidget);
  });

  testWidgets('退出多选会清空选择，避免残留', (tester) async {
    await pumpList(tester);
    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跑步'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toggle-batch-mode')));
    await tester.pumpAndSettle();

    // 重新进入多选时应是空选择：上一次的选择不该悄悄留到下一次。
    expect(find.text('已选 0'), findsOneWidget);
    expect(tasks.tasks['task-3']!.status, TaskStatus.open);
  });
}
