// §12.1：任务清单筛选的**纯逻辑测试**。
//
// 这里钉住的是一份口径，而不是一堆界面：`待安排／已安排／已完成` 的分组同时依赖
// **任务自身的持久化状态**与**当前确认计划里尚未结束的时间块**，两条依据来自不同的
// 数据源。把判断留在 Widget 的 `build()` 里，测试就只能靠"列表里出现了哪个标题"
// 间接推断；而这个文件直接断言分组结果与卡片文案，因此"已完成任务残留时间块"
// 这类边界可以在不搭界面的情况下被钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/features/tasks/task_list_filter.dart';

/// 固定"现在"，让"未来块／过去块"成为确定的事实而不是随运行时刻漂移的猜谜。
final _now = DateTime.utc(2026, 10, 7, 12);

PlannerTask _task(
  String id, {
  String? title,
  TaskStatus status = TaskStatus.open,
  TaskPriority priority = TaskPriority.medium,
  int estimatedMinutes = 30,
  int? remainingMinutes,
  DateTime? dueAtUtc,
}) => PlannerTask(
  id: id,
  title: title ?? id,
  notes: '',
  priority: priority,
  estimatedMinutes: estimatedMinutes,
  remainingMinutes: remainingMinutes ?? estimatedMinutes,
  dueAtUtc: dueAtUtc,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

({String taskId, DateTime startUtc, DateTime endUtc}) _block(
  String taskId,
  DateTime startUtc,
  DateTime endUtc,
) => (taskId: taskId, startUtc: startUtc, endUtc: endUtc);

/// 一个只含 [taskIds] 的"已安排"视图，块的时间取 [start] 起一小时。
TaskScheduleWindow _scheduled(Iterable<String> taskIds, {DateTime? start}) {
  final from = start ?? _now.add(const Duration(hours: 1));
  return TaskScheduleWindow.fromBlocks([
    for (final id in taskIds)
      _block(id, from, from.add(const Duration(hours: 1))),
  ], nowUtc: _now);
}

String _range(DateTime startUtc, DateTime endUtc) =>
    '${startUtc.toIso8601String()}|${endUtc.toIso8601String()}';

String _due(DateTime dueAtUtc) => dueAtUtc.toIso8601String();

void main() {
  group('classifyTaskForList', () {
    test('1. 普通未完成任务且无计划块，归入待安排', () {
      final task = _task('t1');
      expect(
        classifyTaskForList(task, schedule: _scheduled(const [])),
        TaskListBucket.unscheduled,
      );
    });

    test('2. 普通未完成任务且有未来计划块，归入已安排', () {
      final task = _task('t1');
      expect(
        classifyTaskForList(task, schedule: _scheduled(const ['t1'])),
        TaskListBucket.scheduled,
      );
    });

    test('3. 只有过去计划块，归入待安排', () {
      // "过去块"在视图里根本不出现——这正是它由"尚未结束的块"生成的意义：
      // 安排过一次不等于现在还安排着。
      final schedule = TaskScheduleWindow.fromBlocks([
        _block('t1', _now.subtract(const Duration(hours: 2)), _now),
        _block(
          't1',
          _now.subtract(const Duration(hours: 5)),
          _now.subtract(const Duration(minutes: 1)),
        ),
      ], nowUtc: _now);

      expect(schedule.taskIds, isEmpty);
      expect(
        classifyTaskForList(_task('t1'), schedule: schedule),
        TaskListBucket.unscheduled,
      );
    });

    test('4. 已完成任务即使有未来计划块，仍归入已完成', () {
      final task = _task('t1', status: TaskStatus.completed);
      final schedule = _scheduled(const ['t1']);
      expect(
        classifyTaskForList(task, schedule: schedule),
        TaskListBucket.completed,
      );
      // 数量统计同样只落一栏，不会同时被算进"已安排"。
      final counts = countTaskListBuckets([task], schedule: schedule);
      expect(counts[TaskListFilter.completed], 1);
      expect(counts[TaskListFilter.scheduled], 0);
      expect(counts[TaskListFilter.all], 1);
    });

    test('5. 跳过任务归入 excluded', () {
      expect(
        classifyTaskForList(
          _task('t1', status: TaskStatus.skipped),
          schedule: _scheduled(const ['t1']),
        ),
        TaskListBucket.excluded,
      );
    });

    test('6. 取消任务归入 excluded', () {
      expect(
        classifyTaskForList(
          _task('t1', status: TaskStatus.cancelled),
          schedule: _scheduled(const []),
        ),
        TaskListBucket.excluded,
      );
    });

    test('7. 逾期任务有未来补排，归入已安排', () {
      // 逾期只是提醒信息，不是筛选类别：补排之后它必须回到"已安排"。
      final overdue = _task('t1', dueAtUtc: DateTime.utc(2026, 10, 6, 23, 59));
      expect(overdue.statusAt(nowUtc: _now), TaskStatus.overdue);
      expect(
        classifyTaskForList(overdue, schedule: _scheduled(const ['t1'])),
        TaskListBucket.scheduled,
      );
    });

    test('8. 逾期任务无未来补排，归入待安排', () {
      final overdue = _task('t1', dueAtUtc: DateTime.utc(2026, 10, 6, 23, 59));
      expect(
        classifyTaskForList(overdue, schedule: _scheduled(const [])),
        TaskListBucket.unscheduled,
      );
    });

    test('9. 进行中任务有有效时间块，归入已安排', () {
      final running = _task('t1', status: TaskStatus.inProgress);
      expect(
        classifyTaskForList(running, schedule: _scheduled(const ['t1'])),
        TaskListBucket.scheduled,
      );
    });

    test('9b. 进行中任务没有任何有效时间块，归入待安排（异常但可达）', () {
      final running = _task('t1', status: TaskStatus.inProgress);
      expect(
        classifyTaskForList(running, schedule: _scheduled(const [])),
        TaskListBucket.unscheduled,
      );
    });
  });

  group('TaskScheduleWindow', () {
    test('只收尚未结束的块，正在进行的块也算', () {
      final window = TaskScheduleWindow.fromBlocks([
        // 结束时间恰好等于"现在"：不算尚未结束，因为差值不是正数。
        _block('ended', _now.subtract(const Duration(hours: 1)), _now),
        _block(
          'past',
          _now.subtract(const Duration(hours: 3)),
          _now.subtract(const Duration(hours: 1)),
        ),
        // 跨过"现在"、尚未结束的块：用户正在做的事仍然是"已安排"。
        _block(
          'running',
          _now.subtract(const Duration(minutes: 10)),
          _now.add(const Duration(minutes: 30)),
        ),
        _block(
          'future',
          _now.add(const Duration(days: 1)),
          _now.add(const Duration(days: 1, hours: 1)),
        ),
      ], nowUtc: _now);

      expect(window.taskIds, {'running', 'future'});
    });

    test('多个片段取最早开始的未结束块（拆分的任务只算一条）', () {
      final window = TaskScheduleWindow.fromBlocks([
        _block(
          't1',
          _now.add(const Duration(hours: 5)),
          _now.add(const Duration(hours: 6)),
        ),
        _block(
          't1',
          _now.add(const Duration(hours: 2)),
          _now.add(const Duration(hours: 3)),
        ),
        _block(
          't1',
          _now.subtract(const Duration(hours: 4)),
          _now.subtract(const Duration(hours: 3)),
        ),
      ], nowUtc: _now);

      expect(window.taskIds, {'t1'});
      expect(
        window.windowFor('t1')!.startUtc,
        _now.add(const Duration(hours: 2)),
      );
    });

    test('空视图表示"一个任务都没有安排"', () {
      expect(TaskScheduleWindow.empty().taskIds, isEmpty);
      expect(TaskScheduleWindow.empty().windowFor('t1'), isNull);
    });
  });

  group('countTaskListBuckets', () {
    test('10. 全部数量等于三个可见分组数量之和，且落选项不进任何一栏', () {
      final tasks = [
        _task('u1'),
        _task('u2'),
        _task('s1'),
        _task('s2'),
        _task('s3'),
        _task('c1', status: TaskStatus.completed),
        _task('c2', status: TaskStatus.completed),
        _task('x1', status: TaskStatus.skipped),
        _task('x2', status: TaskStatus.cancelled),
      ];
      final counts = countTaskListBuckets(
        tasks,
        schedule: _scheduled(const ['s1', 's2', 's3', 'x1', 'x2']),
      );

      expect(counts[TaskListFilter.unscheduled], 2);
      expect(counts[TaskListFilter.scheduled], 3);
      expect(counts[TaskListFilter.completed], 2);
      expect(counts[TaskListFilter.all], 7);
      expect(
        counts[TaskListFilter.all],
        counts[TaskListFilter.unscheduled]! +
            counts[TaskListFilter.scheduled]! +
            counts[TaskListFilter.completed]!,
      );
    });

    test('每个筛选项都在分布里有一格，因此界面可以按序遍历', () {
      final counts = countTaskListBuckets(
        const [],
        schedule: TaskScheduleWindow.empty(),
      );
      for (final filter in TaskListFilter.values) {
        expect(counts[filter], 0, reason: '${filter.name} 应当有一格且为 0');
      }
    });
  });

  group('filterTaskList', () {
    late List<PlannerTask> tasks;
    late TaskScheduleWindow schedule;

    setUp(() {
      tasks = [
        _task(
          'u1',
          title: '算法作业',
          estimatedMinutes: 50,
          priority: TaskPriority.low,
        ),
        _task(
          'u2',
          title: '大物作业',
          estimatedMinutes: 20,
          priority: TaskPriority.urgent,
        ),
        _task(
          's1',
          title: '大物预习课',
          estimatedMinutes: 90,
          priority: TaskPriority.high,
          dueAtUtc: DateTime.utc(2026, 10, 9),
        ),
        _task('c1', title: '竞赛报名', status: TaskStatus.completed),
        _task('x1', title: '旧任务', status: TaskStatus.cancelled),
      ];
      schedule = _scheduled(const ['s1', 'x1']);
    });

    List<PlannerTask> run({
      TaskListFilter filter = TaskListFilter.all,
      String query = '',
      TaskSort sort = TaskSort.none,
    }) => filterTaskList(
      tasks,
      filter: filter,
      schedule: schedule,
      query: query,
      sort: sort,
    );

    test('全部＝待安排＋已安排＋已完成，取消的任务不出现', () {
      expect(run().map((task) => task.id), ['u1', 'u2', 's1', 'c1']);
    });

    test('四个筛选项各自只给出对应分组的任务', () {
      expect(run(filter: TaskListFilter.unscheduled).map((t) => t.id), [
        'u1',
        'u2',
      ]);
      expect(run(filter: TaskListFilter.scheduled).map((t) => t.id), ['s1']);
      expect(run(filter: TaskListFilter.completed).map((t) => t.id), ['c1']);
    });

    test('搜索在筛选之后执行，因此"已完成"里搜不到待安排的任务', () {
      expect(
        run(filter: TaskListFilter.unscheduled, query: '算法'),
        hasLength(1),
      );
      // 同一个关键词在"已完成"里必须是空的——否则说明搜索先于筛选生效。
      expect(run(filter: TaskListFilter.completed, query: '算法'), isEmpty);
    });

    test('搜索只比较标题且忽略大小写与首尾空白', () {
      expect(run(query: '  算法  ').map((t) => t.id), ['u1']);
      expect(run(query: '不存在的关键词'), isEmpty);
    });

    test('搜索输入为空时不做任何标题过滤', () {
      expect(run(query: '   '), hasLength(4));
    });

    test('排序只作用于当前筛选结果', () {
      // 在"待安排"里按优先级：urgent 的 u2 在前。
      expect(
        run(
          filter: TaskListFilter.unscheduled,
          sort: TaskSort.priority,
        ).map((t) => t.id),
        ['u2', 'u1'],
      );
      // 在"全部"里按预计时长：20 → 50 → 90 → 30（已完成同样参与排序）。
      expect(run(sort: TaskSort.estimatedMinutes).map((t) => t.id), [
        'u2',
        'c1',
        'u1',
        's1',
      ]);
    });

    test('按截止时间排序时没有截止时间的排最后', () {
      // 在"全部"里只有 s1 有截止时间，因此它必须排第一；其余三条都没有截止时间，
      // 彼此之间的相对顺序没有语义（Dart 的排序不保证稳定），所以只断言"s1 在最前"
      // 与"另外三条跟在后面"，不断言它们内部的次序。
      final ordered = run(sort: TaskSort.dueDate).map((t) => t.id).toList();
      expect(ordered.first, 's1');
      expect(ordered.sublist(1), containsAll(<String>['u1', 'u2', 'c1']));
    });

    test('默认顺序保持仓储给出的顺序，一个也不重排', () {
      expect(
        run().map((t) => t.id),
        tasks.map((t) => t.id).where((id) => id != 'x1').toList(),
      );
    });
  });

  group('卡片文案（§4）', () {
    // 注入固定格式器，让断言只针对"文案怎么拼"，不针对本地时区与日历换算——
    // 那两项分别由 core/time_zone.dart 与已有测试负责。
    String subtitleOf(PlannerTask task, TaskScheduleWindow schedule) =>
        taskListSubtitle(
          task,
          schedule: schedule,
          nowUtc: _now,
          formatRange: _range,
          formatDue: _due,
        );

    test('待安排显示分组与预计时长', () {
      expect(
        subtitleOf(_task('t1', estimatedMinutes: 50), _scheduled(const [])),
        '待安排 · 预计 50 分钟',
      );
    });

    test('已安排显示真实时间区间', () {
      // 区间必须在"现在"之后，否则它就不是一个"尚未结束"的块（见前面的分类用例）。
      final start = DateTime.utc(2026, 10, 7, 13);
      final end = DateTime.utc(2026, 10, 7, 14, 30);
      final schedule = TaskScheduleWindow.fromBlocks([
        _block('t1', start, end),
      ], nowUtc: _now);

      expect(subtitleOf(_task('t1'), schedule), '已安排 · ${_range(start, end)}');
    });

    test('已完成显示实际投入（预计 − 剩余）', () {
      final done = _task(
        't1',
        status: TaskStatus.completed,
        estimatedMinutes: 60,
        remainingMinutes: 35,
      );
      expect(subtitleOf(done, _scheduled(const ['t1'])), '已完成 · 实际投入 25 分钟');
    });

    test('实际投入不会被算成负数', () {
      // 专注时长超过了预计时长时，"剩余"被钳到 0，这里也必须跟它一致。
      final done = _task(
        't1',
        status: TaskStatus.completed,
        estimatedMinutes: 30,
        remainingMinutes: 0,
      );
      expect(subtitleOf(done, _scheduled(const [])), '已完成 · 实际投入 30 分钟');
    });

    test('逾期提示排在最前，后面仍是真实分组与截止时间', () {
      final overdue = _task(
        't1',
        estimatedMinutes: 50,
        dueAtUtc: DateTime.utc(2026, 10, 6, 15, 59),
      );
      expect(
        subtitleOf(overdue, _scheduled(const [])),
        '已逾期 · 待安排 · 预计 50 分钟 · 截止于 ${_due(overdue.dueAtUtc!)}',
      );
    });

    test('逾期但已补排的任务同时显示"已逾期"与"已安排"', () {
      final overdue = _task('t1', dueAtUtc: DateTime.utc(2026, 10, 6, 15, 59));
      final start = DateTime.utc(2026, 10, 8, 2);
      final end = DateTime.utc(2026, 10, 8, 3);
      final schedule = TaskScheduleWindow.fromBlocks([
        _block('t1', start, end),
      ], nowUtc: _now);

      expect(
        subtitleOf(overdue, schedule),
        '已逾期 · 已安排 · ${_range(start, end)} · 截止于 ${_due(overdue.dueAtUtc!)}',
      );
    });

    test('已完成的逾期任务只显示已完成，不再提示逾期', () {
      // 结束即结束：`statusAt` 对已结束状态直接返回它本身，所以这里不会出现"已逾期"。
      final done = _task(
        't1',
        status: TaskStatus.completed,
        estimatedMinutes: 40,
        remainingMinutes: 15,
        dueAtUtc: DateTime.utc(2026, 10, 1),
      );
      expect(subtitleOf(done, _scheduled(const [])), '已完成 · 实际投入 25 分钟');
    });

    test('状态标签只取三个分组名，不拿项目名冒充', () {
      expect(
        taskStatusLabelForList(_task('a'), schedule: _scheduled(const [])),
        '待安排',
      );
      expect(
        taskStatusLabelForList(_task('a'), schedule: _scheduled(const ['a'])),
        '已安排',
      );
      expect(
        taskStatusLabelForList(
          _task('a', status: TaskStatus.completed),
          schedule: _scheduled(const []),
        ),
        '已完成',
      );
    });
  });
}
