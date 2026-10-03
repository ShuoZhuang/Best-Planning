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
    ]);

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
    ]);

    // 连续任务只产出整块（120 分钟），因此候选数 = 3 小时窗口里该块的合法起点数。
    // 同样把 `hasLength(13)` 换成推导式，理由见上一条用例。
    expect(candidates, hasLength((180 - 120) ~/ 5 + 1));
    expect(candidates.every((item) => item.durationMinutes == 120), isTrue);
  });
}
