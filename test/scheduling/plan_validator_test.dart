import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final validator = PlanValidator(TimeZoneDatabase());
  final day = DateTime.utc(2026, 10, 2);
  TimeRange at(int startHour, int endHour) => TimeRange(
    startUtc: day.add(Duration(hours: startHour)),
    endUtc: day.add(Duration(hours: endHour)),
  );

  ScheduleProblem problem({
    List<SchedulableTask>? tasks,
    List<BusyInterval> fixed = const [],
    List<BusyInterval> protected = const [],
    List<PlannedBlock> locked = const [],
    int? dailyLimit,
  }) => ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    ),
    timeZoneId: 'UTC',
    tasks:
        tasks ??
        [
          const SchedulableTask(
            id: 'task-1',
            requiredMinutes: 60,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 25,
            maxChunkMinutes: 90,
          ),
        ],
    fixedIntervals: fixed,
    protectedIntervals: protected,
    lockedBlocks: locked,
    rules: DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: dailyLimit ?? 360,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'hash-1',
  );

  test('报告固定日程和保护时间重叠', () {
    final blocks = [
      PlannedBlock(id: 'block-1', taskId: 'task-1', range: at(9, 10)),
    ];

    expect(
      validator
          .validate(
            problem(
              fixed: [BusyInterval(id: 'class', range: at(9, 11))],
              protected: [BusyInterval(id: 'sleep', range: at(8, 10))],
            ),
            blocks,
          )
          .map((conflict) => conflict.code),
      containsAll([
        ConflictCode.fixedEventOverlap,
        ConflictCode.protectedTimeOverlap,
      ]),
    );
  });

  test('报告锁定块被移动', () {
    final locked = PlannedBlock(
      id: 'locked-1',
      taskId: 'task-1',
      range: at(9, 10),
      locked: true,
    );
    final moved = PlannedBlock(
      id: 'locked-1',
      taskId: 'task-1',
      range: at(10, 11),
      locked: true,
    );

    final conflicts = validator.validate(problem(locked: [locked]), [moved]);

    expect(
      conflicts.map((item) => item.code),
      contains(ConflictCode.lockedBlockMoved),
    );
  });

  test('报告连续任务被拆分', () {
    final continuous = const SchedulableTask(
      id: 'task-1',
      requiredMinutes: 60,
      splitMode: TaskSplitMode.continuous,
      minChunkMinutes: 60,
      maxChunkMinutes: 60,
    );

    final conflicts = validator.validate(problem(tasks: [continuous]), [
      PlannedBlock(
        id: 'a',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 9, minutes: 30)),
        ),
      ),
      PlannedBlock(
        id: 'b',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 10)),
          endUtc: day.add(const Duration(hours: 10, minutes: 30)),
        ),
      ),
    ]);

    expect(
      conflicts.map((item) => item.code),
      contains(ConflictCode.continuousBlockUnavailable),
    );
  });

  test('报告每日上限和任务片段总量超出', () {
    final blocks = [PlannedBlock(id: 'a', taskId: 'task-1', range: at(8, 10))];

    final conflicts = validator.validate(problem(dailyLimit: 60), blocks);

    expect(
      conflicts.map((item) => item.code),
      containsAll([
        ConflictCode.dailyLimitExceeded,
        ConflictCode.scheduledDurationExceeded,
      ]),
    );
  });

  test('已锁定块不计入每日可移动任务上限', () {
    const task = SchedulableTask(
      id: 'task-1',
      requiredMinutes: 480,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 25,
      maxChunkMinutes: 480,
    );
    final locked = PlannedBlock(
      id: 'locked-1',
      taskId: 'task-1',
      range: at(0, 6),
      locked: true,
    );

    // 锁定 360 分钟 + 新排 120 分钟：可移动部分未超过 180 分钟上限。
    // 锁定块必须被排除，否则同一段时长被重复计算并产生虚假冲突。
    expect(
      validator
          .validate(problem(tasks: [task], locked: [locked], dailyLimit: 180), [
            locked,
            PlannedBlock(id: 'movable-1', taskId: 'task-1', range: at(8, 10)),
          ])
          .map((conflict) => conflict.code),
      isNot(contains(ConflictCode.dailyLimitExceeded)),
    );

    // 可移动部分自身超过上限时仍必须报告。
    expect(
      validator
          .validate(problem(tasks: [task], locked: [locked], dailyLimit: 180), [
            locked,
            PlannedBlock(id: 'movable-2', taskId: 'task-1', range: at(8, 12)),
          ])
          .map((conflict) => conflict.code),
      contains(ConflictCode.dailyLimitExceeded),
    );
  });

  test('排程问题复制输入列表而不是保留可变引用', () {
    final tasks = <SchedulableTask>[];
    final value = problem(tasks: tasks);

    tasks.add(
      const SchedulableTask(
        id: 'late',
        requiredMinutes: 30,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 25,
        maxChunkMinutes: 90,
      ),
    );

    expect(value.tasks, isEmpty);
    expect(() => value.tasks.add(tasks.single), throwsUnsupportedError);
  });
}
