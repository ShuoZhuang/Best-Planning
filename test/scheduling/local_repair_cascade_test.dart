// 1.8.0（设计规范 §11.4，计划 Task 12b）：**当天向后级联**。
//
// `local_repair_test.dart` 钉的是"两份候选怎么比"；本文件钉的是"级联会产出什么样的候选"。
// 规范 §11.4 的三条硬要求逐条对应用例：
// - 目标块不早于 `notBeforeUtc`；
// - 先在**当天**做向后级联，当天放不下就如实失败（不擅自跨天）；
// - **只有未锁定可移动块能被级联**：固定日程、保护时间、锁定块保持原位。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final dayStart = DateTime.utc(2026, 10, 12, 0);
  final dayEnd = DateTime.utc(2026, 10, 12, 24);

  DateTime at(int hour, [int minute = 0]) =>
      dayStart.add(Duration(hours: hour, minutes: minute));

  PlannedBlock block(
    String id, {
    required int hour,
    int minute = 0,
    int minutes = 60,
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: 'task-$id',
    range: TimeRange(
      startUtc: at(hour, minute),
      endUtc: at(hour, minute).add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  LocalRepairOutcome cascade({
    required String target,
    required int notBeforeHour,
    int notBeforeMinute = 0,
    required List<PlannedBlock> blocks,
    List<PlannedBlock> immovable = const [],
  }) => localRepairCascade(
    targetBlockId: target,
    notBeforeUtc: at(notBeforeHour, notBeforeMinute),
    blocks: blocks,
    immovable: immovable,
    dayStartUtc: dayStart,
    dayEndUtc: dayEnd,
  );

  DateTime startOf(LocalRepairOutcome outcome, String id) =>
      outcome.blocks.firstWhere((block) => block.id == id).startUtc;

  test('目标块落在下界上，别的块一个都不动', () {
    final blocks = [
      block('a', hour: 9, minutes: 60),
      block('b', hour: 14, minutes: 60),
    ];

    final outcome = cascade(target: 'b', notBeforeHour: 15, blocks: blocks);

    expect(outcome.feasible, isTrue);
    expect(startOf(outcome, 'b'), at(15), reason: '下界处正好空着，就该放在那里');
    expect(startOf(outcome, 'a'), at(9), reason: '没有任何理由动 a——"少动"是规范第 3 条');
  });

  test('下界处被另一个可移动块占着时，把那个块往后让（当天）', () {
    // a 在 15:00–16:00，而目标 b 的下界是 15:00。
    final blocks = [
      block('a', hour: 15, minutes: 60),
      block('b', hour: 9, minutes: 60),
    ];

    final outcome = cascade(target: 'b', notBeforeHour: 15, blocks: blocks);

    expect(outcome.feasible, isTrue);
    expect(startOf(outcome, 'b'), at(15), reason: '目标块优先拿到下界处的位置');
    expect(
      startOf(outcome, 'a'),
      at(16),
      reason: 'a 往后让**恰好一个身位**——这就是"级联"，而不是把 a 随手丢到别处',
    );
  });

  test('让位时**绝不前移**：先来的块不会被推到更早的时间', () {
    // b 目标是 10:00 起；b 本来在 11:00。级联只允许"保持或后移"。
    final blocks = [
      block('a', hour: 12, minutes: 60),
      block('b', hour: 11, minutes: 60),
    ];

    final outcome = cascade(target: 'b', notBeforeHour: 10, blocks: blocks);

    expect(outcome.feasible, isTrue);
    expect(
      startOf(outcome, 'b'),
      at(11),
      reason: '原位（11:00）已经满足下界 10:00，因此留原位——不是"尽量靠下界"',
    );
    expect(startOf(outcome, 'a'), at(12));
  });

  test('锁定块是硬边界：级联绕过它，绝不把它移走', () {
    final locked = block('locked', hour: 15, minutes: 60, locked: true);
    final blocks = [
      block('a', hour: 9, minutes: 60),
      block('b', hour: 9, minute: 30, minutes: 60),
    ];

    final outcome = cascade(
      target: 'b',
      notBeforeHour: 15,
      blocks: [...blocks, locked],
      immovable: [locked],
    );

    expect(outcome.feasible, isTrue);
    expect(
      startOf(outcome, 'locked'),
      at(15),
      reason: '锁定块保持原位（规范 §11.4：固定日程、保护时间、锁定块保持原位）',
    );
    expect(startOf(outcome, 'b'), at(16), reason: '目标块被锁定块挡住，因此落到它之后');
  });

  test('保护时间同样是硬边界', () {
    final protectedRange = block('protected', hour: 15, minutes: 45);
    final blocks = [block('b', hour: 9, minutes: 60)];

    final outcome = cascade(
      target: 'b',
      notBeforeHour: 15,
      blocks: [...blocks, protectedRange],
      immovable: [protectedRange],
    );

    expect(startOf(outcome, 'b'), at(15, 45));
  });

  test('当天放不下时**如实失败**，不擅自跨天', () {
    // 目标 60 分钟，下界 23:30——当天只剩 30 分钟。
    final blocks = [block('b', hour: 9, minutes: 60)];

    final outcome = cascade(
      target: 'b',
      notBeforeHour: 23,
      notBeforeMinute: 30,
      blocks: blocks,
    );

    expect(
      outcome.feasible,
      isFalse,
      reason: '规范 §11.4："当天放不下时才考虑后续日期"——跨天由调用方决定',
    );
    expect(
      outcome.blocks,
      same(blocks),
      reason: '不可行时**原样返回输入**，绝不能交出一份半改的结果去覆盖已确认计划',
    );
  });

  test('目标块不存在时不可行', () {
    final outcome = cascade(
      target: 'nope',
      notBeforeHour: 10,
      blocks: [block('a', hour: 9, minutes: 60)],
    );

    expect(outcome.feasible, isFalse);
  });

  test('下界早于当天开始时，块留在原位而不被拉到当天开头', () {
    // **这条期望改过一次，值得记下来**：第一版写的是"从当天开始找"，
    // 于是断言块落在 00:00。但下界只是"不早于"，不是"尽早"——
    // 把 09:00 的块拉到 00:00 是**提前**，而规范 §11.2 明确说"提前属于独立操作，不在本批次"。
    // 正确的行为是：下界早于当天开始时，它不构成任何约束，块留在原位。
    final outcome = localRepairCascade(
      targetBlockId: 'b',
      notBeforeUtc: dayStart.subtract(const Duration(hours: 5)),
      blocks: [block('b', hour: 9, minutes: 60)],
      immovable: const [],
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    expect(outcome.feasible, isTrue);
    expect(startOf(outcome, 'b'), at(9), reason: '下界不是"尽早"；把它当尽早会让延后变成提前');
  });

  test('级联结果能被 LocalRepairPlan.compare 数出块数与位移', () {
    final blocks = [
      block('a', hour: 15, minutes: 60),
      block('b', hour: 9, minutes: 60),
    ];

    final outcome = cascade(target: 'b', notBeforeHour: 15, blocks: blocks);

    final plan = LocalRepairPlan(
      blocks: outcome.blocks,
      movedBlockIds: {
        for (final block in outcome.blocks)
          if (outcome.reference[block.id] != block.startUtc) block.id,
      },
    );

    expect(plan.movedBlockIds, {
      'a',
      'b',
    }, reason: 'b 从 09:00 到了 15:00、a 从 15:00 让到 16:00，两块都动了');
    expect(
      localRepairDisplacementMinutes(plan, outcome.reference),
      420,
      reason: 'b 从 09:00 让到 15:00（360 分钟）＋ a 从 15:00 让到 16:00（60 分钟）',
    );
  });

  test('目标块带上"被延后"的解释码', () {
    final outcome = cascade(
      target: 'b',
      notBeforeHour: 15,
      blocks: [block('b', hour: 9, minutes: 60)],
    );

    expect(
      outcome.blocks.firstWhere((block) => block.id == 'b').explanationCode,
      'deferred',
      reason: '预览里要能说清这一个是"延后"造成的，别的块是"被让位"',
    );
  });

  test('不可移动块在结果里只出现一次', () {
    // 传进来的 `blocks` 已经包含不可移动块（这是正常装配方式），
    // 结果里不能因为它既"参与占用"又被"原样带回"而出现两份——两份会让预览显示重复项。
    final locked = block('locked', hour: 20, minutes: 60, locked: true);
    final outcome = cascade(
      target: 'b',
      notBeforeHour: 15,
      blocks: [block('b', hour: 9, minutes: 60), locked],
      immovable: [locked],
    );

    expect(outcome.blocks.where((block) => block.id == 'locked'), hasLength(1));
    expect(
      outcome.blocks.map((block) => block.id).toSet(),
      hasLength(outcome.blocks.length),
      reason: '同一个 id 出现两次会让预览与验证器给出互相矛盾的结论',
    );
  });
}
