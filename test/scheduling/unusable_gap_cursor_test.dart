// 1.8.0（设计规范 §2.6／§11.4 第 6 条）：无法利用的短空档必须被**逐段**认出来。
//
// `findUnusableGaps` 用游标扫过已排序的块。这里钉住游标语义里最容易写错的一处：
//
//   **被排除掉的那一段空档，不能把它后面那一段也一起吃掉。**
//
// 实现原本在"判定排除"之前就把游标推到了当前块的结束时刻，于是
// 09:00–09:30 / 09:40–10:00 / 10:10–10:30 这种形状里：
//   · 第一段空档 09:30–09:40 只有 10 分钟，够不到休息间隔 ⇒ 被排除（这是对的）；
//   · 但游标已经被推到 10:00，于是第二段空档被算成 10:00–10:10（10 分钟），
//     而它其实是 09:40–10:10 **30 分钟** —— 一个完全可用、甚至放得下整片的空档。
//
// 后果是**双重的**：既漏报了真正的 30 分钟空档，又凭空造出一段 10 分钟的空档，
// 于是"浪费分钟数"这个数字既少算又多算，而它正是评分里的原料。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/unusable_gap.dart';

void main() {
  final base = DateTime.utc(2026, 10, 12, 1); // 东八区 09:00

  DateTime at(int minute) => base.add(Duration(minutes: minute));

  PlannedBlock block(String id, int startMinute, int endMinute) => PlannedBlock(
    id: id,
    taskId: 't-1',
    range: TimeRange(startUtc: at(startMinute), endUtc: at(endMinute)),
  );

  SchedulableTask task({String id = 't-1', int minChunk = 30}) =>
      SchedulableTask(
        id: id,
        requiredMinutes: 60,
        minChunkMinutes: minChunk,
        maxChunkMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
      );

  test('**被排除的空档不能吞掉后面那一段**：10 分钟空档之后是 30 分钟空档', () {
    final gaps = findUnusableGaps(
      // 09:00–09:30 · 09:40–10:00 · 10:10–10:30
      blocks: [block('a', 0, 30), block('b', 40, 60), block('c', 70, 90)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 15,
    );

    // 第一段 10 分钟 < 休息间隔 15 ⇒ 被排除。
    // 第二段是 09:40–10:10 共 **30 分钟**，放得下 30 分钟的最小片段 ⇒ 也不该报。
    expect(
      gaps,
      isEmpty,
      reason:
          '两段空档都不该被报：第一段够不到休息间隔，第二段（09:40–10:10，30 分钟）'
          '放得下最小片段。若这里报出一段 10 分钟的空档，说明游标被提前推进，'
          '把第二段算成了 10:00–10:10',
    );
  });

  test('对照：把休息间隔设为 10 分钟以内时，第一段也该被报出来', () {
    // breakMinutes = 9 ⇒ 10 >= 9，因此第一段 09:30–09:40 不再属于"规则休息"。
    //
    // **夹具必须是 09:00–09:30 / 09:40–10:00 / 10:00–10:30**：这样两段空档分别是
    // 10 分钟与 **30 分钟**。第一版我写的 `c` 是 `(70, 90)`（10:10 起），
    // 于是第二段只有 10 分钟——**夹具没构造出要验的那一段空档**，
    // 而用例却断言"第二段 30 分钟放得下"，红得让人以为实现有问题。
    final gaps = findUnusableGaps(
      blocks: [block('a', 0, 30), block('b', 40, 60), block('c', 60, 90)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 9,
    );

    expect(
      gaps.map((gap) => gap.minutes).toList(),
      [10],
      reason:
          '第一段 10 分钟放不下 30 分钟片段 ⇒ 报；第二段 30 分钟放得下 ⇒ 不报。'
          '这条对照同时钉住"报出来的那一段的**长度**是准确的"',
    );
  });

  test('两段都可利用时，一段都不报（相邻可用空档不互相吞）', () {
    // 09:00–09:00 起：空档 20 分钟、空档 40 分钟，最小片段 15 分钟 ⇒ 都可用。
    final gaps = findUnusableGaps(
      blocks: [block('a', 0, 30), block('b', 50, 60), block('c', 100, 110)],
      tasks: [task(minChunk: 15)],
      breakMinutes: 0,
    );

    expect(gaps, isEmpty, reason: '两段都放得下最小片段，没有浪费');
  });

  test('**被排除的中间块不影响后续空档的计算起点**', () {
    // 09:00–09:30 / 09:35–09:45 / 09:56–10:06
    //   · 第一段空档 09:30–09:35 只有 **5 分钟**，够不到休息间隔 10 ⇒ 被排除；
    //   · 第二段是 09:45–09:56 共 **11 分钟** ⇒ 太短放不下 30 分钟片段，报出来。
    //
    // 第二版的夹具是"空档 5 分钟 + 空档 5 分钟、休息间隔 10"，
    // 于是**两段都**落在"够不到休息间隔"里、都不该报——夹具没有把游标效应隔离出来。
    // 关键是第一段被排除，而第二段**不该**因它而改变长度（11 而不是被截短的 6）。
    final gaps = findUnusableGaps(
      blocks: [block('a', 0, 30), block('b', 35, 45), block('c', 56, 66)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 10,
    );

    expect(gaps.map((gap) => gap.minutes).toList(), [
      11,
    ], reason: '第二段从 09:45（前一块的结束）量起，而不是从 09:00 或 09:35 量起');
    expect(
      gaps.single.range.startUtc,
      at(45),
      reason:
          '起点必须是紧邻前一块的结束时刻 09:45；'
          '若游标被提前推进，这里会变成 09:45 之后的某个时刻或直接缺席',
    );
    expect(gaps.single.range.endUtc, at(56));
  });

  test('重叠的块先合并，且合并后仍逐段判定', () {
    // a 与 b 重叠，合并成 09:00–09:50；c 在 10:00–10:10。
    // 空档 = 09:50–10:00 共 10 分钟 < 最小片段 30 ⇒ 报。
    final gaps = findUnusableGaps(
      blocks: [block('a', 0, 40), block('b', 20, 50), block('c', 60, 70)],
      tasks: [task(minChunk: 30)],
      breakMinutes: 0,
    );

    expect(gaps, hasLength(1));
    expect(gaps.single.minutes, 10);
    expect(gaps.single.range.startUtc, at(50));
  });
}
