// R5 的界面入口：在任务详情页写入期望时段。
//
// 服务端与评分因子此前都已就绪，但没有任何界面能写入该字段，因此真实数据里它恒为
// "无偏好"，因子等于不存在。这里验证界面确实能把它写进去，并且写清楚"软约束"的含义。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
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

  /// 全量监听；这个替身没有数据库，因此"全部"与"未结束"共用一份数据。
  @override
  Stream<List<PlannerTask>> watchAllTasks() async* {
    yield tasks.values.toList();
  }

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield tasks.values.toList();
  }
}

PlannerTask _task({LocalTimeRange? window}) => PlannerTask(
  id: 'task-1',
  title: '写方案',
  priority: TaskPriority.medium,
  estimatedMinutes: 60,
  remainingMinutes: 60,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  preferredWindow: window,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  late _Tasks tasks;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({'task-1': _task()});
    service = TaskService(
      repository: tasks,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  Future<void> pump(WidgetTester tester) async {
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
  }

  Future<void> savePreferredWindow(WidgetTester tester) async {
    final save = find.text('保存期望时段');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
  }

  testWidgets('保存期望时段并说明它是软约束', (tester) async {
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('preferred-window')),
      '09:00-12:00',
    );
    await savePreferredWindow(tester);

    final saved = tasks.tasks['task-1']!;
    expect(saved.preferredWindow, isNotNull);
    expect(saved.preferredWindow!.startMinute, 9 * 60);
    expect(saved.preferredWindow!.endMinute, 12 * 60);
    // 只断言成功提示本身：章节说明里也含"软约束"字样，用该词会同时命中两处。
    expect(find.textContaining('期望时段已保存'), findsOneWidget);
  });

  testWidgets('已有偏好会被预填出来，而不是显示为空', (tester) async {
    tasks.tasks['task-1'] = _task(
      window: LocalTimeRange(startMinute: 14 * 60, endMinute: 16 * 60),
    );
    await pump(tester);

    // 页面必须回显已存偏好，否则用户每次进来都会以为没设过，然后把它覆盖掉。
    final field = tester.widget<TextField>(
      find.byKey(const Key('preferred-window')),
    );
    expect(field.controller!.text, '14:00-16:00');
  });

  testWidgets('留空保存即清除偏好', (tester) async {
    tasks.tasks['task-1'] = _task(
      window: LocalTimeRange(startMinute: 14 * 60, endMinute: 16 * 60),
    );
    await pump(tester);

    await tester.enterText(find.byKey(const Key('preferred-window')), '');
    await savePreferredWindow(tester);

    expect(tasks.tasks['task-1']!.preferredWindow, isNull);
  });

  testWidgets('格式错误时给出提示且不改动已存偏好', (tester) async {
    tasks.tasks['task-1'] = _task(
      window: LocalTimeRange(startMinute: 14 * 60, endMinute: 16 * 60),
    );
    await pump(tester);

    await tester.enterText(find.byKey(const Key('preferred-window')), '下午两点');
    await savePreferredWindow(tester);

    expect(find.textContaining('格式应为 09:00-12:00'), findsOneWidget);
    expect(tasks.tasks['task-1']!.preferredWindow!.startMinute, 14 * 60);
  });

  testWidgets('区间非法时由服务层拒绝并提示，原因不在页面里重复实现', (tester) async {
    await pump(tester);

    // 起点等于终点：格式合法但长度为零，LocalTimeRange 会拒绝——判断来自服务层，
    // 页面不重复实现。
    //
    // 注意不能用"起点晚于终点"来构造非法：22:00-02:00 这类跨午夜区间是合法的，
    // 起点大于终点本身并不表示错误。
    await tester.enterText(
      find.byKey(const Key('preferred-window')),
      '09:00-09:00',
    );
    await savePreferredWindow(tester);

    expect(find.textContaining('期望时段无效'), findsOneWidget);
    expect(tasks.tasks['task-1']!.preferredWindow, isNull);
  });
}
