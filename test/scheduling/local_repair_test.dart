// 1.8.0（设计规范 §11.4，计划 Task 12）：最小改动局部修复的**选择顺序**。
//
// 规范 §11.4 要求排程器按字典序选方案：前一项相同时才比较后一项。
// 修复前引擎只有"单块贪心 + 单一总分"：一个 900 分的移动惩罚项把"少动"和"少走"揉在
// 一起，于是三次小改动（每次都略微提高总分）**整体上**可能比一次大改动动得更多。
// 规范第 3、4 条要的是整体量，不是单块增量。
//
// 本文件钉的是**比较器本身**：给定若干候选，谁更优、为什么。级联的可行域生成复用引擎
// 既有的可用时段与硬约束判定，不在这里重复实现。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final base = DateTime.utc(2026, 10, 12, 0);

  /// 造一个块：`hour` 是**开始**小时，`minutes` 是时长，[offsetMinutes] 在开始时刻上加偏移。
  ///
  /// **`offsetMinutes` 不是可有可无的**：第一版只有 `hour` ＋ `minutes`，而 `minutes` 同时
  /// 被当成"时长"和"从整点起的偏移"，于是 `block('a', hour: 9, offsetMinutes: 30)` 得到的是
  /// **09:30–10:00** 而不是想要的 **09:00–09:30**，位移算成 0 而不是 30——
  /// 测试因此红得莫名其妙（`Expected: <30> Actual: <0>`）。
  PlannedBlock block(
    String id, {
    required int hour,
    int minutes = 60,
    int offsetMinutes = 0,
  }) => PlannedBlock(
    id: id,
    taskId: 'task-$id',
    range: TimeRange(
      startUtc: base.add(Duration(hours: hour, minutes: offsetMinutes)),
      endUtc: base.add(Duration(hours: hour, minutes: offsetMinutes + minutes)),
    ),
  );

  /// 参照（＝"修复前"）位置：a 在 09:00、b 在 10:00、c 在 11:00。
  final reference = {
    'a': base.add(const Duration(hours: 9)),
    'b': base.add(const Duration(hours: 10)),
    'c': base.add(const Duration(hours: 11)),
  };

  LocalRepairPlan plan(List<PlannedBlock> blocks, Set<String> moved) =>
      LocalRepairPlan(blocks: blocks, movedBlockIds: moved);

  int compare(
    LocalRepairPlan a,
    LocalRepairPlan b, {
    String target = 'a',
    int notBeforeHour = 9,
  }) => LocalRepairPlan.compare(
    a,
    b,
    reference: reference,
    targetBlockId: target,
    notBeforeUtc: base.add(Duration(hours: notBeforeHour)),
  );

  test('先比"移动的块数"：少动优先，哪怕总位移更大', () {
    // 方案"少动"只把 a 挪到 09:30（1 块、30 分钟）；
    // 方案"多动"把 b、c 各挪 10 分钟（2 块、20 分钟）。
    // 总位移 20 < 30，但**块数 2 > 1**，因此"少动"胜——这正是规范第 3 条优先于第 4 条。
    final fewerBlocks = plan(
      [
        block('a', hour: 9, offsetMinutes: 30),
        block('b', hour: 10),
        block('c', hour: 11),
      ],
      {'a'},
    );
    final fewerMinutes = plan(
      [
        block('a', hour: 9),
        block('b', hour: 10, offsetMinutes: 10),
        block('c', hour: 11, offsetMinutes: 10),
      ],
      {'b', 'c'},
    );

    expect(
      compare(fewerBlocks, fewerMinutes),
      lessThan(0),
      reason: '第 3 条（块数）在第 4 条（分钟）之前',
    );
    expect(localRepairDisplacementMinutes(fewerBlocks, reference), 30);
    expect(localRepairDisplacementMinutes(fewerMinutes, reference), 20);
  });

  test('块数相同时比总位移分钟', () {
    final near = plan(
      [
        block('a', hour: 9, offsetMinutes: 10),
        block('b', hour: 10),
        block('c', hour: 11),
      ],
      {'a'},
    );
    final far = plan(
      [block('a', hour: 10), block('b', hour: 10), block('c', hour: 11)],
      {'a'},
    );

    expect(compare(near, far), lessThan(0));
    expect(localRepairDisplacementMinutes(near, reference), 10);
    expect(localRepairDisplacementMinutes(far, reference), 60);
  });

  test('块数与位移都相同时，目标块距下界更近者优先', () {
    // 两份候选都只动了 a，位移也都是 30 分钟——但一份在 09:30（下界 09:00 之后 30 分钟），
    // 一份在 08:30（**早于下界**）。
    final after = plan(
      [
        block('a', hour: 9, offsetMinutes: 30),
        block('b', hour: 10),
        block('c', hour: 11),
      ],
      {'a'},
    );
    final before = plan(
      [
        block('a', hour: 8, offsetMinutes: 30),
        block('b', hour: 10),
        block('c', hour: 11),
      ],
      {'a'},
    );

    expect(compare(after, before), lessThan(0));
    expect(
      compare(before, after),
      greaterThan(0),
      reason: '比较必须反对称，否则排序结果取决于传入顺序（会变成不确定的行为）',
    );
  });

  test('完全相同时候选顺序仍然确定（不是取决于哈希顺序）', () {
    final left = plan(
      [
        block('a', hour: 9, offsetMinutes: 30),
        block('b', hour: 10),
        block('c', hour: 11),
      ],
      {'a'},
    );
    final right = plan(
      [
        block('c', hour: 11),
        block('b', hour: 10),
        block('a', hour: 9, offsetMinutes: 30),
      ],
      {'a'},
    );

    expect(compare(left, right), 0, reason: '块集合逐值相同（只是列表顺序不同）时不得判出胜负');
  });

  test('没动任何块时位移为零且不算移动', () {
    final untouched = plan([
      block('a', hour: 9),
      block('b', hour: 10),
      block('c', hour: 11),
    ], const {});

    expect(untouched.movedBlockIds, isEmpty);
    expect(localRepairDisplacementMinutes(untouched, reference), 0);
  });

  test('目标块不在候选里时排到最后，而不是抛异常', () {
    // 这是实现缺陷的表现，不是用户能造成的输入：让它表现为"选了别的方案"，
    // 而不是让整个生成崩掉。
    final missing = plan([
      block('b', hour: 10),
      block('c', hour: 11),
    ], const {});
    final present = plan([
      block('a', hour: 9),
      block('b', hour: 10),
      block('c', hour: 11),
    ], const {});

    expect(compare(present, missing), lessThan(0));
  });
}
