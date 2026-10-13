import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  test('generates 30 to 90 minute chunks at five-minute steps', () {
    const generator = CandidateGenerator();
    final task = SchedulableTask(
      id: 'research',
      requiredMinutes: 360,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
    );
    final start = DateTime.utc(2026, 10, 2, 9);
    final candidates = generator.generate(task, [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(hours: 2)),
        ),
        localDate: DateTime(2026, 10, 2),
      ),
    ], remainingMinutes: task.requiredMinutes);

    // 候选数 = 每个合法时长 × 每个 5 分钟步长的起点（起点 + 时长不越出窗口）。
    // 此前这里写的是 `hasLength(169)`：那个数字本身没有含义，一旦枚举方式改变，没有人能判断
    // 它"仍然正确"还是"恰好当前如此"（§13.0 的 T3）。写成推导式之后，失败信息也能读懂。
    final expected = [
      for (var minutes = 30; minutes <= 90; minutes += 5)
        (120 - minutes) ~/ 5 + 1,
    ].fold<int>(0, (sum, count) => sum + count);
    expect(candidates, hasLength(expected));
    expect(candidates.map((item) => item.durationMinutes).toSet(), {
      for (var minutes = 30; minutes <= 90; minutes += 5) minutes,
    });
    expect(
      candidates.every(
        (item) =>
            item.durationMinutes % 5 == 0 &&
            item.startUtc.difference(start).inMinutes % 5 == 0,
      ),
      isTrue,
    );
  });

  test('continuous tasks only produce a whole-task candidate', () {
    const generator = CandidateGenerator();
    final task = SchedulableTask(
      id: 'movie',
      requiredMinutes: 120,
      splitMode: TaskSplitMode.continuous,
      minChunkMinutes: 30,
      maxChunkMinutes: 180,
    );
    final start = DateTime.utc(2026, 10, 2, 19);
    final candidates = generator.generate(task, [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(hours: 3)),
        ),
        localDate: DateTime(2026, 10, 2),
      ),
    ], remainingMinutes: 120);

    // 连续任务只产出整块（120 分钟），因此候选数 = 3 小时窗口里该块的合法起点数。
    // 同样把 `hasLength(13)` 换成推导式，理由见上一条用例。
    expect(candidates, hasLength((180 - 120) ~/ 5 + 1));
    expect(candidates.every((item) => item.durationMinutes == 120), isTrue);
  });

  test('available-from at 10:03 rounds upward to the 10:05 grid', () {
    const generator = CandidateGenerator();
    final day = DateTime.utc(2026, 10, 5);
    final task = SchedulableTask(
      id: 'bounded',
      requiredMinutes: 30,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 30,
      availableFromUtc: day.add(const Duration(hours: 10, minutes: 3)),
    );

    final candidates = generator.generate(task, [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 11)),
        ),
        localDate: DateTime(2026, 10, 5),
      ),
    ], remainingMinutes: 30);

    expect(
      candidates.first.startUtc,
      day.add(const Duration(hours: 10, minutes: 5)),
    );
    expect(
      candidates.every(
        (candidate) => !candidate.startUtc.isBefore(task.availableFromUtc!),
      ),
      isTrue,
    );
  });

  test('available-from excludes earlier slots for continuous tasks too', () {
    const generator = CandidateGenerator();
    final day = DateTime.utc(2026, 10, 5);
    final task = SchedulableTask(
      id: 'continuous-bounded',
      requiredMinutes: 60,
      splitMode: TaskSplitMode.continuous,
      minChunkMinutes: 60,
      maxChunkMinutes: 60,
      availableFromUtc: day.add(const Duration(hours: 14)),
    );
    final candidates = generator.generate(task, [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 11)),
        ),
        localDate: DateTime(2026, 10, 5),
      ),
      AvailabilitySlot(
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 14)),
          endUtc: day.add(const Duration(hours: 16)),
        ),
        localDate: DateTime(2026, 10, 5),
      ),
    ], remainingMinutes: 60);

    expect(candidates, isNotEmpty);
    expect(candidates.every((item) => item.startUtc.hour >= 14), isTrue);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 计划 §2.1 / Task 4 Step 2：候选的**唯一**输入是当前剩余量。
  //
  // 表里每一行的时长集合都能由 `minChunk=30 / maxChunk=90 / granularity=5` 手工推出，
  // 因此失败信息是可读的，而不是"枚举方式恰好如此"。
  // ───────────────────────────────────────────────────────────────────────────
  group('Task 4 Step 2：remainingMinutes 是候选时长上限的唯一来源', () {
    const generator = CandidateGenerator();
    final start = DateTime.utc(2026, 10, 12, 9);

    /// 一天的容量刻意给足（8 小时），于是"候选为空"只可能来自时长规则，
    /// 不可能是空档太短——这条前置条件让下面的断言各自只钉一件事。
    List<AvailabilitySlot> slots() => [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(hours: 8)),
        ),
        localDate: DateTime(2026, 10, 12),
      ),
    ];

    SchedulableTask splittable({
      int requiredMinutes = 100,
      int minChunk = 30,
      int maxChunk = 90,
    }) => SchedulableTask(
      id: 'remaining',
      requiredMinutes: requiredMinutes,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: minChunk,
      maxChunkMinutes: maxChunk,
    );

    Set<int> durationsFor(int remainingMinutes, {int required = 100}) =>
        generator
            .generate(
              splittable(requiredMinutes: required),
              slots(),
              remainingMinutes: remainingMinutes,
            )
            .map((item) => item.durationMinutes)
            .toSet();

    test('remaining 100 ⇒ 30..90 每个 5 分钟步长（上限是 maxChunk）', () {
      expect(durationsFor(100), {
        for (var minutes = 30; minutes <= 90; minutes += 5) minutes,
      });
    });

    test('remaining 40 ⇒ 30..40（上限被剩余量钳住）', () {
      expect(durationsFor(40), {30, 35, 40});
    });

    test('remaining 30 ⇒ 只有 30（剩余量等于最小片段）', () {
      expect(durationsFor(30), {30});
    });

    test('remaining 29 ⇒ 只有 25（短余量宽免：粒度下的剩余量）', () {
      expect(
        durationsFor(29),
        {25},
        reason:
            '29 < minChunk 30 ⇒ 唯一候选时长是 shortRemainderAllowance(29, 5) = 25；'
            '25 不再是"普通片段"，而是这块任务唯一的最终短尾',
      );
    });

    test('remaining 12 ⇒ 只有 10（向下取整，不越过剩余量）', () {
      expect(durationsFor(12), {10});
    });

    test('remaining 3 ⇒ 空（不足一个粒度，如实不排）', () {
      expect(durationsFor(3), isEmpty);
    });

    test('remaining 0 ⇒ 空', () {
      expect(durationsFor(0), isEmpty);
    });

    test('remaining 为负或大于 requiredMinutes ⇒ ArgumentError', () {
      expect(
        () => generator.generate(splittable(), slots(), remainingMinutes: -1),
        throwsArgumentError,
        reason: '负剩余量不是"没有剩余"，而是调用方算错了；必须当场炸，不能静默返回空',
      );
      expect(
        () => generator.generate(splittable(), slots(), remainingMinutes: 101),
        throwsArgumentError,
        reason: '超过 requiredMinutes 会排出超过任务的分钟数',
      );
      expect(
        () => generator.generate(
          splittable(requiredMinutes: 0),
          slots(),
          remainingMinutes: 1,
        ),
        throwsArgumentError,
      );
    });

    test('连续任务只在 remaining == required 时产出整块候选', () {
      SchedulableTask continuous(int requiredMinutes) => SchedulableTask(
        id: 'remaining',
        requiredMinutes: requiredMinutes,
        splitMode: TaskSplitMode.continuous,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      );

      final whole = generator.generate(
        continuous(60),
        slots(),
        remainingMinutes: 60,
      );
      expect(whole.map((item) => item.durationMinutes).toSet(), {60});

      // 已经排过一段的连续任务不再迭代：`remaining < required` ⇒ 空候选。
      expect(
        generator.generate(continuous(60), slots(), remainingMinutes: 30),
        isEmpty,
        reason: '连续任务不放宽、也不拆分：剩余量不等于整块时没有候选',
      );
      expect(
        generator.generate(continuous(60), slots(), remainingMinutes: 0),
        isEmpty,
      );
    });

    test('连续任务不受可拆分任务的 min/max 影响（既有冻结决定）', () {
      final candidates = generator.generate(
        const SchedulableTask(
          id: 'remaining',
          requiredMinutes: 15,
          splitMode: TaskSplitMode.continuous,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
        slots(),
        remainingMinutes: 15,
      );

      expect(candidates.map((item) => item.durationMinutes).toSet(), {15});
    });
  });
}
