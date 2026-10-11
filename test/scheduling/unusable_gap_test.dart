// 1.8.0（设计规范 §11.4 第 6 条／§2.6，计划 Task 13）：识别无法利用的短空档。
//
// 规范 §2.6 的原话：候选评分包含截止风险、优先级、精力、期望时段、同任务连续性、类别切换、
// 碎片和移动旧块等因素，**但没有判断某个空档是否能容纳任何未完成任务**。于是 20 多分钟的
// 空白可能既不是用户设置的休息，也放不下任何任务。
//
// 修复前引擎里的 `_fragmentation` 惩罚的是"这一块比最大片段短多少"——那是**块的形状**，
// 不是**空档的可用性**。两者是不同的东西：一个 45 分钟的块完全正常，而它前后各留 20 分钟
// 的缝才是问题。
//
// **夹具的坑（第一版在这里连红四轮）**：`block(id, hour, minutes)` 把 `minutes` 当成
// "从整点起的偏移"用在了**结束时刻**上，于是每个块都变成零长度、块块相接、一段空档都算不出来
// （`Expected: length of <1>, Actual: []`）。现在开始时刻与时长的参数分开，且**每个用例的
// 夹具都逐值算过**。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/unusable_gap.dart';

void main() {
  final base = DateTime.utc(2026, 10, 12, 0);

  DateTime at(int hour, [int minute = 0]) =>
      base.add(Duration(hours: hour, minutes: minute));

  /// [startHour]:[startMinute] 开始、[minutes] 分钟后结束的块。
  PlannedBlock block(String id, int startHour, int startMinute, int minutes) =>
      PlannedBlock(
        id: id,
        taskId: 'task-$id',
        range: TimeRange(
          startUtc: at(startHour, startMinute),
          endUtc: at(startHour, startMinute).add(Duration(minutes: minutes)),
        ),
      );

  SchedulableTask task({
    required String id,
    int requiredMinutes = 60,
    int minChunkMinutes = 30,
  }) => SchedulableTask(
    id: id,
    requiredMinutes: requiredMinutes,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: minChunkMinutes,
    maxChunkMinutes: 90,
    priority: TaskPriority.medium,
    energyLevel: TaskEnergyLevel.medium,
  );

  test('首尾相接的块不产生空档', () {
    final gaps = findUnusableGaps(
      // 09:00–10:00 与 10:00–11:00：严格相接。
      blocks: [block('a', 9, 0, 60), block('b', 10, 0, 60)],
      tasks: [task(id: 't1', minChunkMinutes: 30)],
    );

    expect(gaps, isEmpty);
  });

  test('短于最小片段的空档被认出来，并报出当时的最小片段', () {
    final gaps = findUnusableGaps(
      // 09:00–10:00 与 10:20–11:20 ⇒ 空档 10:00–10:20（20 分钟）。
      blocks: [block('a', 9, 0, 60), block('b', 10, 20, 60)],
      tasks: [task(id: 't1', minChunkMinutes: 30)],
    );

    expect(gaps, hasLength(1));
    expect(gaps.single.range.startUtc, at(10));
    expect(gaps.single.range.endUtc, at(10, 20));
    expect(gaps.single.minutes, 20);
    expect(
      gaps.single.smallestChunkMinutes,
      30,
      reason: '坏空档要一起报出"当时最小的片段长度"，界面才好解释为什么放不下',
    );
  });

  test('放得下最小片段的空档不算坏空档', () {
    // 09:00–10:00 与 11:00–12:00 ⇒ 空档 60 分钟，而最小片段正好 60。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 11, 0, 60)],
      tasks: [task(id: 't1', minChunkMinutes: 60)],
    );

    expect(gaps, isEmpty, reason: '正好放得下一个最小片段');
  });

  test('只差一分钟的空档仍然是坏空档', () {
    // 空档 10:00–10:59（59 分钟），最小片段 60。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 59, 60)],
      tasks: [task(id: 't1', minChunkMinutes: 60)],
    );

    expect(gaps, hasLength(1));
    expect(gaps.single.minutes, 59);
  });

  test('用 min 而不是 max：只要有任意一件任务放得下，就不是浪费', () {
    // 空档 10:00–10:40（40 分钟）；60 分钟的任务放不下，25 分钟的放得下。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 40, 30)],
      tasks: [
        task(id: 'big', minChunkMinutes: 60),
        task(id: 'small', minChunkMinutes: 25),
      ],
    );

    expect(gaps, isEmpty);
  });

  test('判据用 minChunkMinutes 而不是剩余时长', () {
    // 空档 10:00–10:30（30 分钟），任务还剩 180 分钟但最小片段只有 30。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 30, 30)],
      tasks: [task(id: 't1', requiredMinutes: 180, minChunkMinutes: 30)],
    );

    expect(gaps, isEmpty, reason: '按剩余时长判断会把这种空档误判成坏空档，而它完全可用');
  });

  test('保护时间覆盖的空档不算坏空档（休息不是浪费）', () {
    // 空档 10:00–10:20，但用户为这段时间建了保护时间。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 20, 60)],
      tasks: [task(id: 't1', minChunkMinutes: 30)],
      protectedRanges: [TimeRange(startUtc: at(10), endUtc: at(10, 20))],
    );

    expect(gaps, isEmpty, reason: '规范全局不变量第 6 条：用户明确建立的保护时间不计为坏空档');
  });

  test('比休息间隔还短的空档不算坏空档', () {
    // 空档 10:00–10:10（10 分钟），而规则要求 15 分钟休息。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 10, 60)],
      tasks: [task(id: 't1', minChunkMinutes: 30)],
      breakMinutes: 15,
    );

    expect(gaps, isEmpty, reason: '规则要求的间隔也是休息');
  });

  test('重叠的块先合并：游标推到较晚的结束时刻', () {
    // a: 09:00–10:00，b: 09:30–10:30（**部分重叠**，不是同一起点），c: 12:00–12:30。
    //
    // 合并后游标在 10:30，唯一的空档是 10:30–12:00（90 分钟）。
    //
    // **这条用例最初的期望写错了**：我按"块数"直觉断言 `hasLength(1)`，但 90 分钟的空档
    // 对 30 分钟的最小片段**完全可用**，因此它**不该**出现在坏空档里。探针打印出
    // `PROBE gap=10:30..12:00 min=90 smallest=30` 之后才看清：代码是对的，夹具错了。
    // 现在用两个最小片段分别断言同一段空档的两种结论——这才是"游标推到了 10:30"的证据，
    // 因为如果游标停在 10:00，空档会变成 10:00–12:00 的 120 分钟（两种阈值下都可用）。
    final blocks = [
      block('a', 9, 0, 60),
      block('b', 9, 30, 60),
      block('c', 12, 0, 30),
    ];

    final usable = findUnusableGaps(
      blocks: blocks,
      tasks: [task(id: 't1', minChunkMinutes: 30)],
    );
    expect(usable, isEmpty, reason: '90 分钟放得下 30 分钟的最小片段');

    final unusable = findUnusableGaps(
      blocks: blocks,
      tasks: [task(id: 't1', minChunkMinutes: 120)],
    );
    expect(unusable, hasLength(1));
    expect(
      unusable.single.range.startUtc,
      at(10, 30),
      reason: '游标必须推到重叠块的**较晚**结束时刻；停在 10:00 会得到 10:00–12:00 的 120 分钟',
    );
    expect(unusable.single.range.endUtc, at(12));
    expect(unusable.single.minutes, 90);
  });

  test('没有可排任务时不报坏空档', () {
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 20, 60)],
      tasks: const [],
    );

    expect(gaps, isEmpty, reason: '没有待办时空档本来就该空着，"放不下任何任务"这个判据失去意义');
  });

  test('已经排满的任务不参与最小片段的计算', () {
    // 空档 10:00–10:40（40 分钟）。排满的任务最小片段 120，但它不需要空档。
    final gaps = findUnusableGaps(
      blocks: [block('a', 9, 0, 60), block('b', 10, 40, 30)],
      tasks: [
        task(id: 'done', requiredMinutes: 0, minChunkMinutes: 120),
        task(id: 'todo', requiredMinutes: 60, minChunkMinutes: 25),
      ],
    );

    expect(gaps, isEmpty, reason: '排满的任务不需要空档；把它算进来会把最小片段抬到 120，从而误判');
  });

  test('浪费分钟数是各段坏空档之和', () {
    // a 09:00–10:00、b 10:20–10:50、c 11:00–12:00、d 12:10–12:40。
    // 空档：10:00–10:20 = 20 分钟（坏）、10:50–11:00 = 10 分钟（坏）、12:00–12:10 = 10 分钟（坏）。
    expect(
      unusableGapMinutes(
        blocks: [
          block('a', 9, 0, 60),
          block('b', 10, 20, 30),
          block('c', 11, 0, 60),
          block('d', 12, 10, 30),
        ],
        tasks: [task(id: 't1', minChunkMinutes: 30)],
      ),
      40,
    );
  });

  test('同一次输入换一个最小片段，结论必须跟着变', () {
    final blocks = [block('a', 9, 0, 60), block('b', 11, 0, 60)];

    // 空档 10:00–11:00（60 分钟）。
    expect(
      unusableGapMinutes(
        blocks: blocks,
        tasks: [task(id: 't1', minChunkMinutes: 30)],
      ),
      0,
      reason: '30 分钟的最小片段放得进 60 分钟的空档',
    );
    expect(
      unusableGapMinutes(
        blocks: blocks,
        tasks: [task(id: 't1', minChunkMinutes: 90)],
      ),
      60,
      reason: '90 分钟的最小片段放不进 60 分钟的空档——这正是"能不能利用"的判据',
    );
  });
}
