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

  testWidgets('从界面修正剩余时长会更新任务并留下修正历史', (tester) async {
    await pumpDetail(tester, 'task-1');

    await tester.enterText(find.byType(TextField), '150');
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

    await tester.enterText(find.byType(TextField), '0');
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
