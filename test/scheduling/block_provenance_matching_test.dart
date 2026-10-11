// 1.8.0（裁定第 2 点；设计 §5.2）：从零生成之后，为**新旧块建立一对一来源关联**。
//
// 裁定明确否掉了"把 `existingBlocks` 塞进 `blocks`"的做法：那会让旧块成为占用、
// 却不自动扣除任务待排时长，**同一件工作可能被安排两次**。
// 正确做法是：从零生成**不变**，生成之后再做一次确定性的**代价匹配**。
//
// 代价键（顺序即优先级，全部同分时用 id 作最终排序键）：
//
//   1. 同一 `taskId`；
//   2. 时长差最小；
//   3. 开始时间位移最小；
//   4. 原块 id 与新块 id 作为最终排序键。
//
// **不是"同任务先到先得"**：同一任务的多个块之间没有可比较依据，
// 结果会取决于遍历顺序；而规范 §11.4 第 3、4 条要的正是"少动"，
// 那要求配对本身是**代价最优**的。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final day = DateTime.utc(2026, 10, 12);
  TimeRange at(int startHour, [int minutes = 60]) => TimeRange(
    startUtc: day.add(Duration(hours: startHour)),
    endUtc: day.add(Duration(hours: startHour, minutes: minutes)),
  );

  PlannedBlock b(
    String id, {
    String task = 't1',
    int hour = 0,
    int minutes = 60,
  }) => PlannedBlock(id: id, taskId: task, range: at(hour, minutes));

  /// 把结果整理成「新块 id → 来源 id」便于逐值断言。
  Map<String, String?> provenanceOf(List<PlannedBlock> result) => {
    for (final block in result) block.id: block.continuedFromId,
  };

  test('时长相同、位置最接近的一对匹配上', () {
    final result = linkBlockProvenance(
      confirmed: [b('old-09', hour: 9), b('old-15', hour: 15)],
      generated: [b('new-15', hour: 15), b('new-09', hour: 9)],
    );

    expect(provenanceOf(result), {'new-09': 'old-09', 'new-15': 'old-15'});
  });

  test('**时长差优先于位移**：时长更接近者胜，哪怕位移更大', () {
    // 新块 60 分钟、09:00。旧块 A 是 30 分钟但在 09:00（位移 0）；
    // 旧块 B 是 60 分钟但在 12:00（位移 3 小时）。
    // 按代价键，**先比时长差**：B 的时长差 0 < A 的 30 ⇒ B 胜。
    final result = linkBlockProvenance(
      confirmed: [
        b('old-a', hour: 9, minutes: 30),
        b('old-b', hour: 12, minutes: 60),
      ],
      generated: [b('new-x', hour: 9, minutes: 60)],
    );

    expect(
      provenanceOf(result),
      {'new-x': 'old-b'},
      reason:
          '代价键的第 2 条是"时长差最小"，它**优先于**第 3 条"位移最小"；'
          '若这里匹配到 old-a，说明键的顺序被写反了',
    );
    expect(result.single.range, at(9), reason: '配对只决定来源，**不改动新块自己的位置**');
  });

  test('时长差相同时才比位移', () {
    final result = linkBlockProvenance(
      confirmed: [b('old-far', hour: 20), b('old-near', hour: 10)],
      generated: [b('new-10', hour: 10)],
    );

    expect(provenanceOf(result), {'new-10': 'old-near'});
  });

  test('**不同任务永不配对**', () {
    final result = linkBlockProvenance(
      confirmed: [b('old-other', task: 't2', hour: 9)],
      generated: [b('new-t1', task: 't1', hour: 9)],
    );

    expect(provenanceOf(result), {
      'new-t1': null,
    }, reason: '任务不同就不是"同一件事"，配对会让用户看到错误的来源');
  });

  test('多出来的新块没有来源；未被匹配的旧块视为删除', () {
    final result = linkBlockProvenance(
      // 旧块两个，新块三个 ⇒ 两个配上、一个无来源；旧块全部被用掉。
      confirmed: [b('old-1', hour: 9), b('old-2', hour: 11)],
      generated: [
        b('new-1', hour: 9),
        b('new-2', hour: 11),
        b('new-3', hour: 15),
      ],
    );

    final map = provenanceOf(result);
    expect(map['new-1'], 'old-1');
    expect(map['new-2'], 'old-2');
    expect(map['new-3'], isNull, reason: '多出来的新块是新排进来的');
  });

  test('旧块多于新块时，只有最匹配的那些被认领', () {
    final result = linkBlockProvenance(
      confirmed: [
        b('old-1', hour: 9),
        b('old-2', hour: 11),
        b('old-3', hour: 20),
      ],
      generated: [b('new-1', hour: 9), b('new-2', hour: 11)],
    );

    expect(provenanceOf(result), {'new-1': 'old-1', 'new-2': 'old-2'});
  });

  test('**一对一**：多个新块不会认领同一个旧块', () {
    // 两个新块都在 09:00，只有一个旧块 ⇒ 只有一个能认领它。
    final result = linkBlockProvenance(
      confirmed: [b('old-only', hour: 9)],
      generated: [b('new-a', hour: 9), b('new-b', hour: 9, minutes: 30)],
    );

    final sources = result
        .map((block) => block.continuedFromId)
        .where((id) => id != null)
        .toList();
    expect(sources, hasLength(1), reason: '每个旧块只能被认领一次');
    expect(result, hasLength(2), reason: '不增删块');
  });

  test('**顺序确定**：同一输入连算两次逐值相同，且与输入排列无关', () {
    List<PlannedBlock> run({required bool reversed}) {
      final confirmed = [b('old-1', hour: 9), b('old-2', hour: 11)];
      final generated = [b('new-1', hour: 9), b('new-2', hour: 11)];
      return linkBlockProvenance(
        confirmed: reversed ? confirmed.reversed.toList() : confirmed,
        generated: reversed ? generated.reversed.toList() : generated,
      );
    }

    final a = run(reversed: false);
    final c = run(reversed: false);
    final d = run(reversed: true);

    expect(
      a.map((x) => '${x.id}:${x.continuedFromId}').toList(),
      c.map((x) => '${x.id}:${x.continuedFromId}').toList(),
      reason: '同一次输入连算两次必须相同',
    );
    expect(
      provenanceOf(d),
      provenanceOf(a),
      reason:
          '输入的排列不该改变配对结果——否则 id 分配会随遍历顺序漂，'
          '而 id 会落库',
    );
  });

  test('已经带来源的块不被覆盖（只处理 `continuedFromId` 为空的块）', () {
    // 引擎或调整路径可能已经设好来源；这一步不得把它改掉。
    final preset = PlannedBlock(
      id: 'new-preset',
      taskId: 't1',
      range: at(9),
      continuedFromId: 'old-explicit',
    );

    final result = linkBlockProvenance(
      confirmed: [b('old-1', hour: 9)],
      generated: [preset],
    );

    expect(provenanceOf(result), {
      'new-preset': 'old-explicit',
    }, reason: '已有的显式来源优先于代价匹配');
  });

  test('旧块为空时结果逐值等于输入（全部视为新排）', () {
    final generated = [b('new-1', hour: 9)];

    final result = linkBlockProvenance(
      confirmed: const [],
      generated: generated,
    );

    expect(result, generated);
    expect(result.single.continuedFromId, isNull);
  });

  test('新块为空时返回空列表（不崩）', () {
    expect(
      linkBlockProvenance(confirmed: [b('old-1')], generated: const []),
      isEmpty,
    );
  });
}
