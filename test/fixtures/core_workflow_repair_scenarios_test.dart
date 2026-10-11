import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

import '../fixtures/core_workflow_repair_scenarios.dart';

/// 共享场景夹具的**编译与形状检查**（计划 Task 1 Step 4）。
///
/// 夹具本身没有 `test()` 入口，`flutter test` 直接吃它会报"没有 main"。这个文件存在的
/// 唯一理由就是：让"夹具能构造成对象、且构造出来的形状与规范一致"成为一条可执行的门槛。
///
/// **这里刻意不测产品行为**。上海 12:00 的卡片位置、延后落在哪个块、orphan gap 是否
/// 被判成 orphan，分别属于 Task 2 / 12 / 13；提前在这里断言等于把那些任务的失败信息
/// 挪到一个名字对不上的文件里。这里只钉两件夹具自己的事实：
///
/// 1. 每个场景都能被构造成对象，且 UTC 时刻与本地分钟**互相自洽**；
/// 2. 夹具描述的排程输入确实能被引擎吃下去（不是"能编译但一跑就抛"）。
void main() {
  final scenarios = CoreWorkflowRepairScenarios();

  group('共享场景夹具可构造且自洽', () {
    test('上海午餐：UTC 04:00–05:00 对应本地 12:00–13:00', () {
      final lunch = scenarios.shanghaiLunch();

      expect(lunch.startMinute, 12 * 60);
      expect(lunch.endMinute, 13 * 60);
      expect(lunch.startUtc.isUtc, isTrue);
      // Asia/Shanghai 全年 +08:00，没有夏令时；这条是夹具自己的事实，
      // 不是时间轴的转换逻辑（那个在 Task 2）。
      expect(lunch.startUtc, DateTime.utc(2026, 10, 12, 4));
      expect(lunch.endUtc, DateTime.utc(2026, 10, 12, 5));
      expect(lunch.expectedLabel, '12:00–13:00');
    });

    test('跨午夜：切成两段，分段终点用 1440 而不是 0', () {
      final segments = scenarios.shanghaiCrossMidnight();

      expect(segments, hasLength(2));
      expect(segments.first.startMinute, 23 * 60 + 30);
      expect(segments.first.endMinute, LocalTimeRange.minutesPerDay);
      expect(segments.first.localDate, DateTime(2026, 10, 12));
      expect(segments.last.startMinute, 0);
      expect(segments.last.endMinute, 30);
      expect(segments.last.localDate, DateTime(2026, 10, 13));

      // 第二段的起点就是第一段的终点：两段拼接后不重叠、不留缝。
      expect(segments.last.startUtc, segments.first.endUtc);
    });

    test('柏林夏令时切换日与前一日的 (UTC - 本地钟点) 差不同', () {
      final before = scenarios.berlinBeforeSpringForward();
      final switchDay = scenarios.berlinSpringForward();

      // 两天的本地钟点都是 03:00，因此"本地分钟"必须相等，
      // 而 UTC 偏移必须不同——2026-03-29 02:00 本地时间柏林从 +01:00 跳到 +02:00。
      expect(before.startMinute, switchDay.startMinute);
      expect(before.startUtc, DateTime.utc(2026, 3, 28, 2));
      expect(switchDay.startUtc, DateTime.utc(2026, 3, 29, 1));
      expect(
        switchDay.startUtc.difference(before.startUtc).inHours,
        23,
        reason:
            '下一个本地 03:00 只比上一个晚 23 小时（那一天的本地时长为 23 小时）。'
            '这条断言存在的意义是：把"本地日历语义"与"加固定 24 小时"分开——'
            '规范 §11.2 的"延后 1 天遇 DST 保持本地钟点"正是靠这个差来判定的。',
      );
    });

    test('通知夹具是五类 planner.* 加一条外部通知', () {
      final items = scenarios.notificationCategories();

      expect(items, hasLength(6));
      expect(items.where((item) => item.isManagedByPlanner), hasLength(5));
      expect(
        items
            .where((item) => item.isManagedByPlanner)
            .map((item) => item.category)
            .toSet(),
        {'taskStart', 'calendarStart', 'deadline', 'conflict', 'recurringGoal'},
      );
      expect(
        items.singleWhere((item) => !item.isManagedByPlanner).id,
        RepairIds.foreignNotification,
      );
    });

    test('延后夹具：目标点确实被固定日程占住，且合法落点在其后', () {
      final defer = scenarios.deferredBlockWithOccupiedTarget();
      final problem = defer.problem;

      final block = problem.existingBlocks.singleWhere(
        (item) => item.id == defer.blockId,
      );
      expect(block.durationMinutes, 15);

      // "目标点被占"必须是**事实**，否则这条夹具在测一个不存在的冲突。
      final blocker = problem.fixedIntervals.single;
      expect(blocker.range.contains(defer.notBeforeUtc), isTrue);
      expect(defer.expectedStartUtc.isBefore(blocker.range.endUtc), isFalse);
      expect(defer.notBeforeUtc.isBefore(defer.expectedStartUtc), isTrue);
      expect(
        defer.notBeforeUtc.difference(block.startUtc).inMinutes,
        30,
        reason: '请求是"延后 30 分钟"，下界必须等于原开始时刻加 30 分钟',
      );
    });

    test('orphan gap 夹具：20 分钟空档放不下任何剩余任务的最小片段', () {
      final problem = scenarios.orphanGapBetweenFixedEvents();

      final fixed = [...problem.fixedIntervals]
        ..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
      final gapMinutes = fixed[1].range.startUtc
          .difference(fixed[0].range.endUtc)
          .inMinutes;
      expect(gapMinutes, 20);

      final smallestChunk = problem.tasks
          .map((task) => task.minChunkMinutes)
          .reduce((a, b) => a < b ? a : b);
      expect(
        smallestChunk,
        greaterThan(gapMinutes),
        reason: '夹具的前提就是"放不下"；若不成立，orphan 分类的用例会失去意义',
      );
    });

    test('同名不同 logicalCourseId 的课程分开列出', () {
      final courses = scenarios.sameNamedDifferentCourses();

      expect(courses, hasLength(3));
      final sameTitle = courses
          .where((course) => course.title == '高等数学(上)')
          .toList();
      expect(sameTitle, hasLength(2));
      expect(
        sameTitle.map((course) => course.logicalCourseId).toSet(),
        hasLength(2),
        reason: '同名不同 logicalCourseId 必须能被分开，这是"管理这门课"深链的前提',
      );
    });

    test('夹具描述的排程输入能被引擎接受（不抛异常）', () {
      final engine = DeterministicScheduleEngine(
        CoreWorkflowRepairScenarios().zones,
      );

      for (final problem in [
        scenarios.deferredBlockWithOccupiedTarget().problem,
        scenarios.orphanGapBetweenFixedEvents(),
      ]) {
        final proposal = engine.generate(problem);
        // 这里只断言"引擎能给出一个提案"，不断言块落在哪里：
        // 具体落点属于 Task 12 / 13 的验收内容。
        expect(proposal.blocks, isNotEmpty);
      }
    });
  });
}
