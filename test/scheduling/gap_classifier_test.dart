// 1.8.0（设计规范 §12.1／计划 Task 13 Step 1）：相邻占用之间的间隔**四类分类**。
//
// 规范原文：
//
// - `intentionalBreak`：用户保护时间或规则要求的休息；
// - `usableGap`：至少能放入一个当前未完成任务的合法最小片段；
// - `orphanGap`：大于所需过渡休息，但小于所有可候选任务的最小片段；
// - `freeTime`：没有任务需要填入，或用户日容量已达到上限。
//
// **只有 `orphanGap` 计入惩罚。系统不能为了"看起来紧凑"吞掉保护时间或排满所有自由时间。**
//
// 计划 Task 13 的 Interfaces 一栏点名要求 `GapKind { intentionalBreak, usable, orphan, freeTime }`
// 与 `lib/scheduling/gap_classifier.dart` —— 这两样此前**都不存在**（只有更窄的
// `unusable_gap.dart`，它只区分"坏／不坏"）。本文件与 `gap_classifier.dart` 补上这一段。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/gap_classifier.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final base = DateTime.utc(2026, 10, 12, 1); // 东八区 09:00
  DateTime at(int minute) => base.add(Duration(minutes: minute));

  PlannedBlock block(String id, int startMinute, int endMinute) => PlannedBlock(
    id: id,
    taskId: 't-1',
    range: TimeRange(startUtc: at(startMinute), endUtc: at(endMinute)),
  );

  SchedulableTask task({int minChunk = 30, int required = 60}) =>
      SchedulableTask(
        id: 't-1',
        requiredMinutes: required,
        minChunkMinutes: minChunk,
        maxChunkMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
      );

  List<ClassifiedGap> classify({
    required List<PlannedBlock> blocks,
    List<SchedulableTask> tasks = const [],
    List<TimeRange> protectedRanges = const [],
    int breakMinutes = 0,
    int? dailyCapacityMinutes,
  }) => classifyGaps(
    blocks: blocks,
    tasks: tasks,
    protectedRanges: protectedRanges,
    breakMinutes: breakMinutes,
    dailyCapacityMinutes: dailyCapacityMinutes,
  );

  test('放得下最小片段的空档是 usable，不是 orphan', () {
    final gaps = classify(
      // 09:00–09:30 / 10:00–10:30 ⇒ 中间 30 分钟，最小片段 30 ⇒ 放得下
      blocks: [block('a', 0, 30), block('b', 60, 90)],
      tasks: [task(minChunk: 30)],
    );

    expect(gaps, hasLength(1));
    expect(gaps.single.kind, GapKind.usable);
    expect(gaps.single.minutes, 30);
  });

  test('大于过渡休息但放不下任何任务的空档是 orphan（规范 §12.1 的核心情形）', () {
    final gaps = classify(
      // 09:00–09:30 / 09:50–10:20 ⇒ 中间 20 分钟；最小片段 30 ⇒ 放不下。
      blocks: [block('a', 0, 30), block('b', 50, 80)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 10,
    );

    expect(
      gaps.single.kind,
      GapKind.orphan,
      reason: '20 分钟 > 过渡休息 10 分钟，又放不下 30 分钟片段 ⇒ 这才是要惩罚的那一类',
    );
  });

  test('够不到过渡休息的空档是 intentionalBreak，不是 orphan', () {
    final gaps = classify(
      // 09:00–09:30 / 09:35–10:05 ⇒ 中间 5 分钟；休息间隔 10 ⇒ 属于规则休息。
      blocks: [block('a', 0, 30), block('b', 35, 65)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 10,
    );

    expect(
      gaps.single.kind,
      GapKind.intentionalBreak,
      reason: '短于休息间隔的空档是规则要求的休息，不计惩罚',
    );
  });

  test('被保护时间覆盖的空档是 intentionalBreak（"休息不是浪费"）', () {
    final gaps = classify(
      blocks: [block('a', 0, 30), block('b', 60, 90)],
      tasks: [task(minChunk: 45)],
      // 09:30–10:00 整段被保护时间覆盖；最小片段 45 ⇒ 本来会算 orphan。
      protectedRanges: [TimeRange(startUtc: at(30), endUtc: at(60))],
    );

    expect(
      gaps.single.kind,
      GapKind.intentionalBreak,
      reason: '用户明确建立保护的时间不是浪费；全局不变量第 6 条',
    );
  });

  test('**没有任务需要填入时空档是 freeTime，不进惩罚**（规范 §12.1 第四类）', () {
    final gaps = classify(
      blocks: [block('a', 0, 30), block('b', 50, 80)],
      // 没有可排任务。
      tasks: const [],
      breakMinutes: 10,
    );

    expect(
      gaps.single.kind,
      GapKind.freeTime,
      reason:
          '没有任务要填时，空档是"这一天到点了"而不是排程失败。'
          '把它算成 orphan 会让排程器为了看起来紧凑而硬塞',
    );
  });

  test('任务都已排满（剩余 0 分钟）时同样是 freeTime', () {
    final gaps = classify(
      blocks: [block('a', 0, 30), block('b', 50, 80)],
      tasks: [task(minChunk: 30, required: 0)],
      breakMinutes: 10,
    );

    expect(
      gaps.single.kind,
      GapKind.freeTime,
      reason: '已经排完的任务不需要空档，因此这段空档没有用途 —— 是自由时间',
    );
  });

  test('**日容量已达上限时空档是 freeTime**（规范 §12.1："用户日容量已达到上限"）', () {
    final gaps = classify(
      // 已排 60 分钟，日上限 60 分钟 ⇒ 已经排满。
      blocks: [block('a', 0, 30), block('b', 50, 80)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 10,
      dailyCapacityMinutes: 60,
    );

    expect(
      gaps.single.kind,
      GapKind.freeTime,
      reason:
          '日容量到顶之后剩下的空档不是"没能利用"，而是用户给自己设的上限；'
          '把它算成浪费会鼓励排程器忽视每日可排上限',
    );
  });

  test('日容量未达上限时照常按可放性分类（上限是唯一的分界）', () {
    final gaps = classify(
      blocks: [block('a', 0, 30), block('b', 50, 80)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 10,
      dailyCapacityMinutes: 61,
    );

    expect(
      gaps.single.kind,
      GapKind.orphan,
      reason: '只差一分钟没到上限 ⇒ 仍然要按"放不下"分类，不能提前变成 freeTime',
    );
  });

  test('首尾相接的块之间不产生空档（零长度段不出现在结果里）', () {
    final gaps = classify(
      blocks: [block('a', 0, 30), block('b', 30, 60)],
      tasks: [task()],
    );

    expect(gaps, isEmpty, reason: '零长度空档没有分类意义，不该出现');
  });

  test('重叠的块先合并，且合并后仍逐段分类', () {
    // a 与 b 重叠 ⇒ 合并成 09:00–09:50；c 在 10:00–10:30。
    final gaps = classify(
      blocks: [block('a', 0, 40), block('b', 20, 50), block('c', 60, 90)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 0,
    );

    expect(gaps, hasLength(1));
    expect(gaps.single.range.startUtc, at(50));
    expect(gaps.single.range.endUtc, at(60));
    expect(
      gaps.single.kind,
      GapKind.orphan,
      reason: '合并后空档只有 10 分钟，放不下 30 分钟的最小片段',
    );
  });

  test('一段空档只能归一类：四类的判据互斥且覆盖全部情形', () {
    // 同一个夹具、只改一个输入，四类各出现一次。
    expect(
      classify(
        blocks: [block('a', 0, 30), block('b', 60, 90)],
        tasks: [task(minChunk: 30)],
      ).single.kind,
      GapKind.usable,
    );
    expect(
      classify(
        blocks: [block('a', 0, 30), block('b', 50, 80)],
        tasks: [task(minChunk: 30)],
        breakMinutes: 10,
      ).single.kind,
      GapKind.orphan,
    );
    expect(
      classify(
        blocks: [block('a', 0, 30), block('b', 35, 65)],
        tasks: [task(minChunk: 30)],
        breakMinutes: 10,
      ).single.kind,
      GapKind.intentionalBreak,
    );
    expect(
      classify(
        blocks: [block('a', 0, 30), block('b', 50, 80)],
        tasks: const [],
      ).single.kind,
      GapKind.freeTime,
    );
  });
}
