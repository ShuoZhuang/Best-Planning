// 1.8.0（裁定"Task 13 的决定"；设计 §5.5）：方案级比较的**第 6、7 级** ——
// 坏空档数量与坏空档总分钟。
//
// `LocalRepairPlan.compare` 此前止步于第 5 级（目标块距下界），随后直接落到
// "稳定签名"。也就是说规范 §11.4 的第 6 条（不制造无法利用的短空档）
// **在方案级也没有被执行**——候选级实测不可行（任何负权重都吃掉休息，见验收表 §9），
// 方案级又缺这两级，于是第 6 条**两头都空**。
//
// 裁定明确不接受"本架构下不强制执行"：用户已提出"二十多分钟的碎片无法使用"，
// 那是产品行为要求。本文件把第 6、7 级钉住。
//
// 排序依据（§11.4）：
//   3. 移动的其他块数量   4. 总位移分钟   5. 目标块距下界
//   6. **坏空档数量**     7. **坏空档总分钟**   8. 其他软偏好   9. 稳定签名
//
// 分类复用 `gap_classifier.dart`：`intentionalBreak`（保护时间／规则休息）与
// `freeTime`（没有任务可填、或日容量已达上限）**永远不计为坏空档**——
// 这是"不得为了减少坏空档缩短休息或覆盖保护时间"这条硬边界在比较层的体现。
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

  /// 坏空档统计：数量与总分钟。`intentionalBreak` 与 `freeTime` 不计。
  ///
  /// **不默认塞一个任务**：传 `tasks: const []` 就是"没有可排任务"，
  /// 而那正是 `freeTime` 的一条来源。第一版这里写成"空就用默认任务"，
  /// 于是"没有任务"那条用例**永远验不到它想验的事**（夹具把输入改掉了）。
  ({int count, int minutes}) orphanGaps(
    List<PlannedBlock> blocks, {
    Iterable<SchedulableTask> tasks = const [],
    List<TimeRange> protectedRanges = const [],
    int breakMinutes = 0,
  }) {
    final gaps = classifyGaps(
      blocks: blocks,
      tasks: tasks,
      protectedRanges: protectedRanges,
      breakMinutes: breakMinutes,
    );
    var count = 0;
    var minutes = 0;
    for (final gap in gaps) {
      if (gap.kind != GapKind.orphan) continue;
      count++;
      minutes += gap.minutes;
    }
    return (count: count, minutes: minutes);
  }

  test('留下一段 20 分钟坏空档的方案被判为更差（**第 6 级：数量**）', () {
    // 两个方案的前 5 级完全一致：都只移动了目标块、位移相同、目标距下界相同。
    //
    // A：`09:00–10:00` 与 `10:20–11:20` ⇒ 中间 20 分钟，放不下 30 分钟最小片段
    //    ⇒ 1 段坏空档。
    // B：`09:00–10:00` 与 `10:00–11:00` ⇒ **首尾相接，没有空档** ⇒ 0 段。
    final crowded = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 80, 60)],
      movedBlockIds: const {},
    );
    final tidy = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 60, 60)],
      movedBlockIds: const {},
    );

    expect(
      orphanGaps(crowded.blocks, tasks: [task()]).count,
      1,
      reason: '前置条件：A 有一段坏空档',
    );
    expect(
      orphanGaps(tidy.blocks, tasks: [task()]).count,
      0,
      reason: '前置条件：B 没有坏空档',
    );

    final winner = LocalRepairPlan.compare(
      crowded,
      tidy,
      reference: const {},
      targetBlockId: 'b1',
      notBeforeUtc: at(0),
      tasks: [task()],
    );

    expect(winner, greaterThan(0), reason: '留坏空档的方案必须排在后面（规范 §11.4 第 6 条）');
  });

  test('数量相同时比**总分钟**（第 7 级）', () {
    // 两方案都是 1 段坏空档；A 的那段 25 分钟，B 的 10 分钟。
    final longer = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 85, 60)],
      movedBlockIds: const {},
    );
    final shorter = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 70, 60)],
      movedBlockIds: const {},
    );

    final a = orphanGaps(longer.blocks, tasks: [task()]);
    final b = orphanGaps(shorter.blocks, tasks: [task()]);
    expect(a.count, b.count, reason: '前置条件：两者坏空档数量相同');
    expect(a.minutes, greaterThan(b.minutes), reason: '前置条件：A 的更长');

    expect(
      LocalRepairPlan.compare(
        longer,
        shorter,
        reference: const {},
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
        tasks: [task()],
      ),
      greaterThan(0),
    );
  });

  test('**保护时间覆盖的空档不算坏空档**（硬边界：不得靠覆盖休息取胜）', () {
    // A 的那段 20 分钟被保护时间覆盖 ⇒ 归 `intentionalBreak` ⇒ 不计惩罚。
    // B 首尾相接、没有空档。两者坏空档数都是 0 ⇒ 落到第 9 级稳定签名。
    final protected = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 80, 60)],
      movedBlockIds: const {},
    );
    final tidy = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 60, 60)],
      movedBlockIds: const {},
    );

    expect(
      orphanGaps(
        protected.blocks,
        tasks: [task()],
        protectedRanges: [TimeRange(startUtc: at(60), endUtc: at(80))],
      ).count,
      0,
      reason: '被保护时间覆盖 ⇒ 归 intentionalBreak，不是坏空档',
    );

    // 因此比较时不能因为它"看起来有缝"而扣分：两者在第 6 级上打平。
    final byOrphanOnly = LocalRepairPlan.compare(
      protected,
      tidy,
      reference: const {},
      targetBlockId: 'b1',
      notBeforeUtc: at(0),
      tasks: [task()],
      protectedRanges: [TimeRange(startUtc: at(60), endUtc: at(80))],
    );
    expect(byOrphanOnly, isNot(0), reason: '第 6 级打平后由稳定签名分胜负（签名必然不同）');
  });

  test('**没有可排任务时任何空档都是 freeTime**，不算坏空档', () {
    final gappy = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 80, 60)],
      movedBlockIds: const {},
    );

    expect(
      orphanGaps(gappy.blocks, tasks: const []).count,
      0,
      reason:
          '`classifyGaps` 在没有可排任务时把间隔归 freeTime——'
          '"这一天到点了"不是排程失败',
    );
  });

  test('**日容量已达上限时空档归 freeTime**，不算坏空档', () {
    final gappy = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 80, 60)],
      movedBlockIds: const {},
    );

    final gaps = classifyGaps(
      blocks: gappy.blocks,
      tasks: [task()],
      // 已排 120 分钟，上限 120 ⇒ 到顶。
      dailyCapacityMinutes: 120,
    );

    expect(
      gaps.every((gap) => gap.kind != GapKind.orphan),
      isTrue,
      reason: '容量到顶之后剩下的空白是用户设的上限，不是浪费',
    );
  });

  test('第 3 级（移动块数）**优先于**第 6 级：少动但留坏空档仍然更优', () {
    // 这是级别顺序的关键：规范 §11.4 把"移动的其他块数量"排在第 6 条之前。
    final fewerMovesWithGap = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 80, 60)],
      // 只动了目标块（空集合表示没有"其他块"被移动）。
      movedBlockIds: const {},
    );
    final moreMovesNoGap = LocalRepairPlan(
      blocks: [block('b1', 0, 60), block('b2', 60, 60)],
      // 多动了一块。
      movedBlockIds: const {'b2'},
    );

    final winner = LocalRepairPlan.compare(
      fewerMovesWithGap,
      moreMovesNoGap,
      reference: const {},
      targetBlockId: 'b1',
      notBeforeUtc: at(0),
      tasks: [task()],
    );

    expect(
      winner,
      lessThan(0),
      reason:
          '少动一块的方案更优，**哪怕它留下一段坏空档**——'
          '§11.4 的字典序把"移动块数"排在第 6 条之前',
    );
  });
}
