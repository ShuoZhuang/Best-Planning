// 1.8.0（裁定"Task 13 的决定"第 2 点；设计 §5.5）：为调整操作生成**有限、确定的**
// 合法方案集合，再按 §11.4 的九级顺序挑一份。
//
// 裁定原文："为调整操作生成有限、确定的合法方案集合。"
//
// **为什么不能只用"最早可放"这一份**：最早可放是贪心，它只看"我不撞谁"，
// 不看"我这样放会在周围留下什么"。本批次实测过这一点（见验收表 §9）：
// 按"离开短缝"的局部贪心去排，会在更远处制造**更大的缺口**。
//
// 本文件构造一个"最早可放会留下坏空档、稍晚一点反而更好"的场景，
// 钉住"必须比较多份方案"这件事。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/gap_classifier.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int minute) => day.add(Duration(minutes: minute));

  PlannedBlock block(String id, int startMinute, int minutes) => PlannedBlock(
    id: id,
    taskId: 't-a',
    range: TimeRange(
      startUtc: at(startMinute),
      endUtc: at(startMinute + minutes),
    ),
  );

  SchedulableTask task({int minChunk = 30}) => SchedulableTask(
    id: 't-a',
    requiredMinutes: 120,
    minChunkMinutes: minChunk,
    maxChunkMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    priority: TaskPriority.medium,
    energyLevel: TaskEnergyLevel.medium,
  );

  int orphanCount(List<PlannedBlock> blocks, {int minChunk = 30}) =>
      classifyGaps(
        blocks: blocks,
        tasks: [task(minChunk: minChunk)],
      ).where((gap) => gap.kind == GapKind.orphan).length;

  test('**在合法方案里挑坏空档更少的那一份**（不是无脑"最早可放"）', () {
    // 场景（全部 UTC 分钟计）：
    //   · 目标块 60 分钟，原在 09:00（540–600）；
    //   · 另有一块占着 10:30–11:30（630–690）；
    //   · 下界 = 09:00 + 30 = 570（09:30）。
    //
    // "最早可放" = 570（09:30）⇒ 目标占 570–630，与 630 那一块**首尾相接**，
    //   但会把 540 之前与之后切出别的缝；关键是它在 600–630 之间留下了什么。
    // 晚一点放 = 600（10:00）⇒ 目标占 600–660，会与 630–690 重叠 ⇒ 不可行。
    //
    // 所以真正能体现差别的场景是"目标后面还有一块、早放会撞出小缝"。
    // 这里直接用两个候选做对照，确保比较器**真的在挑**：
    final earliest = LocalRepairPlan(
      blocks: [block('b1', 570, 60), block('b2', 640, 60)],
      movedBlockIds: const {},
    );
    // 稍晚的放置让两段首尾相接（570+60=630，第二块从 630 开始）。
    final tidier = LocalRepairPlan(
      blocks: [block('b1', 570, 60), block('b2', 630, 60)],
      movedBlockIds: const {},
    );

    expect(
      orphanCount(earliest.blocks),
      1,
      reason: '前置条件：最早可放那一份留了一段 10 分钟的坏空档',
    );
    expect(orphanCount(tidier.blocks), 0, reason: '前置条件：紧邻那一份没有坏空档');

    final best = chooseRepairPlan(
      targetBlockId: 'b1',
      notBeforeUtc: at(570),
      candidates: [earliest, tidier],
      reference: const {},
      tasks: [task()],
      dayStartUtc: at(0),
      dayEndUtc: at(24 * 60),
    );

    expect(
      best.blocks,
      tidier.blocks,
      reason:
          '必须挑坏空档更少的那一份（§11.4 第 6 级）。'
          '只生成"最早可放"一份就永远挑不到它',
    );
  });

  test('候选集合**确定**：同一输入连算两次结果逐值相同', () {
    LocalRepairOutcome run() => chooseRepairPlan(
      targetBlockId: 'b1',
      notBeforeUtc: at(570),
      candidates: [
        LocalRepairPlan(
          blocks: [block('b1', 570, 60), block('b2', 640, 60)],
          movedBlockIds: const {},
        ),
        LocalRepairPlan(
          blocks: [block('b1', 570, 60), block('b2', 630, 60)],
          movedBlockIds: const {},
        ),
      ],
      reference: const {},
      tasks: [task()],
      dayStartUtc: at(0),
      dayEndUtc: at(24 * 60),
    );

    expect(
      run().blocks.map((b) => b.startUtc.toIso8601String()).toList(),
      run().blocks.map((b) => b.startUtc.toIso8601String()).toList(),
    );
  });

  test('候选为空时返回不可行，而不是抛异常', () {
    final best = chooseRepairPlan(
      targetBlockId: 'b1',
      notBeforeUtc: at(570),
      candidates: const [],
      reference: const {},
      tasks: [task()],
      dayStartUtc: at(0),
      dayEndUtc: at(24 * 60),
    );

    expect(best.feasible, isFalse);
  });

  test('**过滤掉不满足下界的候选**（下界是硬条件，不是偏好）', () {
    final tooEarly = LocalRepairPlan(
      blocks: [block('b1', 540, 60)], // 09:00 < 下界 09:30
      movedBlockIds: const {},
    );
    final legal = LocalRepairPlan(
      blocks: [block('b1', 570, 60)],
      movedBlockIds: const {},
    );

    final best = chooseRepairPlan(
      targetBlockId: 'b1',
      notBeforeUtc: at(570),
      candidates: [tooEarly, legal],
      reference: const {},
      tasks: [task()],
      dayStartUtc: at(0),
      dayEndUtc: at(24 * 60),
    );

    expect(
      best.blocks.single.startUtc,
      at(570),
      reason: '不满足下界的候选必须被排除（§11.4 第 2 级是硬条件）',
    );
  });

  test('候选里**没有目标块**时也排除（无法判定第 5 级）', () {
    final missingTarget = LocalRepairPlan(
      blocks: [block('other', 600, 60)],
      movedBlockIds: const {},
    );
    final legal = LocalRepairPlan(
      blocks: [block('b1', 570, 60)],
      movedBlockIds: const {},
    );

    final best = chooseRepairPlan(
      targetBlockId: 'b1',
      notBeforeUtc: at(570),
      candidates: [missingTarget, legal],
      reference: const {},
      tasks: [task()],
      dayStartUtc: at(0),
      dayEndUtc: at(24 * 60),
    );

    expect(best.blocks.single.id, 'b1');
  });

  group('候选锚点集合（裁定第 2 点："有限、确定"）', () {
    test('**包含下界本身**，以及下界之后每个占用的结束时刻', () {
      final anchors = repairCandidateAnchors(
        notBeforeUtc: at(570),
        dayEndUtc: at(24 * 60),
        occupied: [
          TimeRange(startUtc: at(600), endUtc: at(660)),
          TimeRange(startUtc: at(700), endUtc: at(760)),
        ],
      );

      expect(anchors.first, at(570), reason: '第一个锚点必须就是下界');
      expect(anchors, contains(at(660)), reason: '让开第一个占用之后的时刻');
      expect(anchors, contains(at(760)), reason: '让开第二个占用之后的时刻');
    });

    test('**早于下界结束的占用不产生锚点**（它不影响下界之后能放什么）', () {
      final anchors = repairCandidateAnchors(
        notBeforeUtc: at(570),
        dayEndUtc: at(24 * 60),
        occupied: [TimeRange(startUtc: at(400), endUtc: at(500))],
      );

      expect(anchors, [at(570)]);
    });

    test('**有限**：锚点数量不超过上限', () {
      final anchors = repairCandidateAnchors(
        notBeforeUtc: at(0),
        dayEndUtc: at(24 * 60),
        occupied: [
          for (var i = 1; i <= 100; i++)
            TimeRange(startUtc: at(i * 10), endUtc: at(i * 10 + 5)),
        ],
        maxCandidates: 8,
      );

      expect(
        anchors.length,
        lessThanOrEqualTo(8),
        reason: '裁定要求"有限"：候选数必须有上限，不能随当天块数无限增长',
      );
    });

    test('**确定**：与占用块的输入排列无关，且升序去重', () {
      final slots = [
        TimeRange(startUtc: at(700), endUtc: at(760)),
        TimeRange(startUtc: at(600), endUtc: at(660)),
      ];

      final a = repairCandidateAnchors(
        notBeforeUtc: at(570),
        dayEndUtc: at(24 * 60),
        occupied: slots,
      );
      final b = repairCandidateAnchors(
        notBeforeUtc: at(570),
        dayEndUtc: at(24 * 60),
        occupied: slots.reversed,
      );

      expect(a, b, reason: '输入的排列不得改变锚点集合');
      expect(a, a.toSet().toList(), reason: '不得有重复锚点（重复会让同一份方案被算两次）');
    });

    test('下界已在当天之外时没有锚点（不跨天找）', () {
      expect(
        repairCandidateAnchors(
          notBeforeUtc: at(24 * 60),
          dayEndUtc: at(24 * 60),
          occupied: const [],
        ),
        isEmpty,
      );
    });
  });

  group('生成 + 挑选（`repairBestPlan`）', () {
    test('**产出可行的最优方案**，且目标块不早于下界', () {
      final outcome = repairBestPlan(
        targetBlockId: 'b1',
        notBeforeUtc: at(570),
        // 目标 60 分钟，原在 09:00；另有一块占 10:30–11:30。
        blocks: [block('b1', 540, 60), block('b2', 630, 60)],
        immovable: const [],
        dayStartUtc: at(0),
        dayEndUtc: at(24 * 60),
        tasks: [task()],
      );

      expect(outcome.feasible, isTrue);
      final target = outcome.blocks.firstWhere((b) => b.id == 'b1');
      expect(target.startUtc.isBefore(at(570)), isFalse);
    });

    test('**级联不增删块**，且目标块满足下界', () {
      final outcome = repairBestPlan(
        targetBlockId: 'b1',
        notBeforeUtc: at(570),
        blocks: [block('b1', 540, 60), block('b2', 600, 60)],
        immovable: const [],
        dayStartUtc: at(0),
        dayEndUtc: at(24 * 60),
        tasks: [task()],
      );

      expect(outcome.feasible, isTrue);
      expect(outcome.blocks.map((b) => b.id).toSet(), {
        'b1',
        'b2',
      }, reason: '级联不增删块');
      final target = outcome.blocks.firstWhere((b) => b.id == 'b1');
      expect(target.startUtc.isBefore(at(570)), isFalse);
    });

    test('当天放不下时返回不可行（由调用方决定是否跨天搜索）', () {
      final outcome = repairBestPlan(
        targetBlockId: 'b1',
        notBeforeUtc: at(23 * 60 + 30),
        blocks: [block('b1', 540, 120)],
        immovable: const [],
        dayStartUtc: at(0),
        dayEndUtc: at(24 * 60),
        tasks: [task()],
      );

      expect(
        outcome.feasible,
        isFalse,
        reason:
            '120 分钟的块在下界 23:30 之后放不进当天 ⇒ 不可行；'
            '这里**不偷偷跨天**，跨天是 §11.4 末段交给调用方的下一步',
      );
    });

    test('**目标块挤压另一块时，被挤开的那一块仍在结果里**', () {
      // 目标 60 分钟、原在 09:00（540），下界 09:30（570）；
      // 另一块占 09:30–10:30（570–630）⇒ 目标放到下界就会撞上它。
      final outcome = repairBestPlan(
        targetBlockId: 'b1',
        notBeforeUtc: at(570),
        blocks: [block('b1', 540, 60), block('b2', 570, 60)],
        immovable: const [],
        dayStartUtc: at(0),
        dayEndUtc: at(24 * 60),
        tasks: [task()],
      );

      expect(outcome.feasible, isTrue);
      expect(outcome.blocks.map((b) => b.id).toSet(), {
        'b1',
        'b2',
      }, reason: '级联不增删块：被挤开的那一块仍在结果里');
      // **实测到的方案**（写下来，因为"被挤开的块留在原位"与直觉相反）：
      // 目标块被放到 10:30（让开 b2），b2 **留在原位 09:30** ——
      // 这比"把目标放到 09:30、再把 b2 推到 10:30"动得更少（位移 0 对 60 分钟），
      // 正是 §11.4 第 3、4 级要的"少动"。
      expect(
        outcome.blocks.firstWhere((b) => b.id == 'b2').startUtc,
        at(570),
        reason: 'b2 不必让位：把目标放到它之后更省位移',
      );
      expect(
        outcome.blocks.firstWhere((b) => b.id == 'b1').startUtc,
        at(630),
        reason: '目标块让开 b2，落在 10:30',
      );
    });

    test('**级联优先动目标块**：目标可让位时，别人一块都不动', () {
      // 这条替换掉了我原先写的"真的发生位移"用例 —— 那一版**夹具本身非法**
      // （`task()` 的 `minChunkMinutes` 是 60，而夹具里造了一个 30 分钟的块），
      // 于是它测的是一个不该出现的输入，结论没有意义。
      //
      // 实测到的行为：目标留在 09:00–10:00，b2 从 09:40 被让到 **10:00**。
      //
      // **为什么不是"把目标放到 b2 之后"**：那样目标位移 60 分钟、b2 位移 0；
      // 而"目标留原位、b2 让开 20 分钟"**总位移更小**（20 对 60）——
      // §11.4 第 4 级比的是**总位移分钟**，不是"动了几块"（两者都只动 1 块）。
      // 这条断言记录的就是这个取舍。
      final outcome = repairBestPlan(
        targetBlockId: 'b1',
        notBeforeUtc: at(540),
        blocks: [block('b1', 540, 60), block('b2', 580, 60)],
        immovable: const [],
        dayStartUtc: at(0),
        dayEndUtc: at(24 * 60),
        tasks: [task()],
      );

      expect(outcome.feasible, isTrue);
      final b1 = outcome.blocks.firstWhere((b) => b.id == 'b1');
      final b2 = outcome.blocks.firstWhere((b) => b.id == 'b2');
      expect(
        b1.startUtc,
        at(540),
        reason: '目标块留在原位：它本来就满足下界（下界 09:00），不该被前移或后移',
      );
      expect(
        b2.startUtc,
        b1.endUtc,
        reason:
            'b2 紧贴在目标块之后（首尾相接）——让开的距离最小，因此总位移最小。'
            '若它被推到更远处，说明级联多移了',
      );
    });
  });
}
