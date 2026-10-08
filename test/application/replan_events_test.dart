// FR-STAT-06 的"重排原因"来源：任务排程输入变化时记一条 `replan:` 事件。
//
// 此前这一类事件**没有任何写入方**（W5 剩下的那一类），因此统计页的"重排原因"永远空着。
// 本文件钉住四类变化各自的原因码——原因码会**直接显示给用户**，所以它必须是人话而不是内部
// 枚举名；另外钉住"未装配回调时不报错"，因为任务服务不该依赖统计是否可用。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 9);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'id-${++_count}';
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);
  final Map<String, PlannerTask> tasks;
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

PlannerTask _task() => PlannerTask(
  id: 'task-1',
  title: '写方案',
  notes: '',
  priority: TaskPriority.medium,
  estimatedMinutes: 90,
  remainingMinutes: 90,
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
  late List<ScheduleInputChange> changes;
  late List<String> reasons;

  TaskService build({bool withCallback = true}) => TaskService(
    repository: tasks,
    clock: const _Clock(),
    idGenerator: _Ids(),
    onScheduleInputChanged: withCallback
        ? (change) {
            changes.add(change);
            reasons.add(change.label);
          }
        : null,
  );

  setUp(() {
    tasks = _Tasks({'task-1': _task()});
    changes = [];
    reasons = [];
  });

  test('改截止日期记一条"截止日期变化"', () async {
    await build().setDueDate('task-1', DateTime.utc(2026, 10, 20));

    expect(reasons, <String>['截止日期变化']);
  });

  test('改优先级记一条"优先级变化"', () async {
    await build().setPriority('task-1', TaskPriority.high);

    expect(reasons, <String>['优先级变化']);
  });

  test('改剩余时长记一条"剩余时长修正"', () async {
    await build().correctRemainingMinutes('task-1', 30);

    expect(reasons, <String>['剩余时长修正']);
  });

  test('改状态记一条"状态变化"', () async {
    await build().changeStatus('task-1', TaskStatus.completed);

    expect(reasons, <String>['状态变化']);
  });

  test('类别按新状态细分，而不是一律"排程字段变了"', () async {
    // 标签是给人看的（统计页"重排原因"），类别是给协调器用的。若这里只报一个笼统的
    // 类别，协调器就无从区分"完成了一个任务"与"改了一个截止日期"。
    await build().changeStatus('task-1', TaskStatus.completed);
    await build().changeStatus('task-1', TaskStatus.skipped);
    await build().changeStatus('task-1', TaskStatus.cancelled);
    await build().changeStatus('task-1', TaskStatus.open);

    expect(
      [for (final change in changes) change.kind],
      <DomainChangeKind>[
        DomainChangeKind.taskCompleted,
        DomainChangeKind.taskSkipped,
        DomainChangeKind.taskCancelled,
        DomainChangeKind.taskSchedulingChanged,
      ],
    );
  });

  test('三类排程字段变化都报 taskSchedulingChanged', () async {
    await build().setDueDate('task-1', DateTime.utc(2026, 10, 20));
    await build().setPriority('task-1', TaskPriority.high);
    await build().correctRemainingMinutes('task-1', 30);

    expect(changes, hasLength(3));
    expect([
      for (final change in changes) change.kind,
    ], everyElement(DomainChangeKind.taskSchedulingChanged));
  });

  test('失败的修改不记原因（改不动就没有重排）', () async {
    final service = build();

    await service.setDueDate('missing', DateTime.utc(2026, 10, 20));
    await service.correctRemainingMinutes('task-1', -1);

    expect(reasons, isEmpty);
  });

  group('新建任务（此前这个类别没有发出者）', () {
    // `DomainChangeKind.taskCreated` 曾在枚举里躺着而**没有任何代码发出它**，于是"新建任务
    // 即自动重算计划"不成立——只有改截止日期／优先级／剩余时长／状态这四类会触发。这三条把
    // 两个录入入口都钉住，否则它会悄悄退回去。
    test('完整新建记一条"新建任务"，类别是 taskCreated', () async {
      await build().saveDraft(
        const TaskDraft(
          title: '写方案',
          estimatedMinutes: 60,
          areaId: 'area-test',
        ),
      );

      expect(reasons, <String>['新建任务']);
      expect(changes.single.kind, DomainChangeKind.taskCreated);
    });

    test('完整草稿保存同样记一条"新建任务"', () async {
      final result = await build().saveDraft(
        const TaskDraft(
          title: '写方案',
          estimatedMinutes: 60,
          areaId: 'area-test',
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(changes.single.kind, DomainChangeKind.taskCreated);
    });

    test('校验不通过的草稿不记原因，也不落库', () async {
      final service = build();

      final result = await service.saveDraft(
        const TaskDraft(title: '  ', estimatedMinutes: 60, areaId: 'area-test'),
      );

      expect(result.isSuccess, isFalse);
      expect(reasons, isEmpty);
      // 与"失败的修改不记原因"同一口径：没写进去就没有重排。
      expect(tasks.tasks, hasLength(1));
    });
  });

  test('未装配回调时照常改任务，只是不留原因', () async {
    final service = build(withCallback: false);

    await service.setPriority('task-1', TaskPriority.high);

    expect(tasks.tasks['task-1']!.priority, TaskPriority.high);
    expect(reasons, isEmpty);
  });
  // **延后任务**（FR-REPLAN-01 的"延期事项"，2026-10-04）。此前 `DomainChangeKind.taskDeferred`
  // 没有任何动作能产生（§13.0 的 W12 行登记过），因此枚举里那个值不可达。这三条钉住：动作存在、
  // 发出的是**专属类别**（不是笼统的"截止日期变化"）、以及两条拒绝路径**不留下任何痕迹**。
  test('延后任务：截止日期整体后移，并记一条"延后任务"', () async {
    tasks.tasks['task-1'] = _task().copyWith(
      dueAtUtc: DateTime.utc(2026, 10, 20, 9),
    );

    await build().deferTask('task-1', by: const Duration(days: 1));

    expect(reasons, <String>['延后任务']);
    expect(
      changes.single.kind,
      DomainChangeKind.taskDeferred,
      reason: '必须发专属类别：统计页把标签直接显示给用户，笼统的"截止日期变化"会掩盖这是延后',
    );
    expect(
      (await tasks.getById('task-1'))!.dueAtUtc,
      DateTime.utc(2026, 10, 21, 9),
      reason: '延后＝整体后移，不是设成某一天',
    );
  });

  test('没有截止日期的任务不能延后，且不留下痕迹', () async {
    // `_task()` 默认没有截止日期：往后挪没有基准，应当拒绝而不是替用户编一个日期。
    await build().deferTask('task-1', by: const Duration(days: 1));

    expect(reasons, isEmpty, reason: '被拒绝的动作不该触发重排');
    expect(
      (await tasks.getById('task-1'))!.dueAtUtc,
      isNull,
      reason: '绝不能悄悄设一个用户没说过的截止时间',
    );
  });

  test('延后量为零或负值时拒绝', () async {
    tasks.tasks['task-1'] = _task().copyWith(
      dueAtUtc: DateTime.utc(2026, 10, 20, 9),
    );

    await build().deferTask('task-1', by: Duration.zero);
    await build().deferTask('task-1', by: const Duration(days: -1));

    expect(reasons, isEmpty);
    expect(
      (await tasks.getById('task-1'))!.dueAtUtc,
      DateTime.utc(2026, 10, 20, 9),
      reason: '提前/不动是另一个动作，不能借延后之名生效',
    );
  });
}
