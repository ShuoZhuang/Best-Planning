// 1.8.0（裁定第 4 点；设计 §5.2／§5.6）：预览的「移动」必须**根据来源关联**判断，
// **不能通过复用数据库主键实现**。
//
// 现状：`PlanDiffer` 按**块 id 相等**判"同一块"，而引擎每次生成都起新 id
// （`block:<taskId>:<微秒>:<时长>`），确认计划里的 id 是 `<提案 id>:<引擎块 id>`。
// 两族永不相交 ⇒ 同一块换了时间被报成 **`removed` ＋ `added`**，而不是 `moved`。
//
// 而且**不能靠"让块 id 保持不变"来解决**：`applyProposal` 会构造
// `persistedId = '<提案 id>:<block.id>'`，复用旧 id 每确认一次就套一层前缀。
// 所以判据必须是**来源关联**（`continuedFromId`），见裁定第 1 点。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final day = DateTime.utc(2026, 10, 12);
  TimeRange at(int hour) => TimeRange(
    startUtc: day.add(Duration(hours: hour)),
    endUtc: day.add(Duration(hours: hour + 1)),
  );

  PlannedBlock block(
    String id, {
    int hour = 9,
    String task = 't-a',
    String? continuedFromId,
  }) => PlannedBlock(
    id: id,
    taskId: task,
    range: at(hour),
    continuedFromId: continuedFromId,
  );

  test('**来源相连但 id 不同 ⇒ 报「移动」**（裁定第 4 点的核心）', () {
    // 当前确认计划里的块：`<提案 id>:<引擎块 id>` 形状。
    final current = [block('plan-1:block:t-a:100:60', hour: 9)];
    // 新提案里的同一块：**新 id**，但来源指向上面那一块。位置变了。
    final proposed = [
      block(
        'block:t-a:200:60',
        hour: 14,
        continuedFromId: 'plan-1:block:t-a:100:60',
      ),
    ];

    final diff = const PlanDiffer().diff(current, proposed);

    expect(
      diff.changes,
      hasLength(1),
      reason:
          '同一块只该产生一条变更。按 id 判会得到 removed + added 两条'
          '（当前 id 不见了、新 id 是新的）',
    );
    expect(
      diff.changes.single.type,
      PlanChangeType.moved,
      reason:
          '来源关联说明这是同一块换了时间 ⇒ 必须报「移动」；'
          '用户看到"删了一项、又加了一项"会以为自己的待办被动过两次',
    );
    expect(diff.changes.single.before?.range, at(9));
    expect(diff.changes.single.after?.range, at(14));
  });

  test('来源相连且位置未变 ⇒ **不产生变更**', () {
    final current = [block('plan-1:block:t-a:100:60', hour: 9)];
    final proposed = [
      block(
        'block:t-a:100:60',
        hour: 9,
        continuedFromId: 'plan-1:block:t-a:100:60',
      ),
    ];

    expect(
      const PlanDiffer().diff(current, proposed).changes,
      isEmpty,
      reason: '位置与任务都没变，只是 id 换了 ⇒ 这不是用户可见的变更',
    );
  });

  test('来源相连但**任务变了** ⇒ 报「移动」（任务归属变化也是变更）', () {
    final current = [block('plan-1:old', hour: 9, task: 't-a')];
    final proposed = [
      block('new-id', hour: 9, task: 't-b', continuedFromId: 'plan-1:old'),
    ];

    final diff = const PlanDiffer().diff(current, proposed);
    expect(diff.changes.single.type, PlanChangeType.moved);
  });

  test('**没有来源的新块仍是「新增」**，不会被误当成移动', () {
    final current = [block('plan-1:old', hour: 9)];
    final proposed = [block('brand-new', hour: 14)];

    final diff = const PlanDiffer().diff(current, proposed);

    final types = diff.changes.map((c) => c.type).toSet();
    expect(
      types,
      contains(PlanChangeType.added),
      reason: '新排进来的块（来源为空、id 也是新的）就是「新增」',
    );
    expect(types, isNot(contains(PlanChangeType.moved)), reason: '没有来源关联就不是移动');
  });

  test('id 相等（旧行为）仍然被认作同一块——不能为了来源而丢掉这条路径', () {
    final current = [block('same-id', hour: 9)];
    final proposed = [block('same-id', hour: 14)];

    final diff = const PlanDiffer().diff(current, proposed);
    expect(diff.changes.single.type, PlanChangeType.moved);
  });

  test('来源指向的块**不在当前计划里**时不算移动（不猜）', () {
    final current = [block('plan-1:other', hour: 9)];
    final proposed = [
      block('new-id', hour: 14, continuedFromId: 'plan-1:missing'),
    ];

    final types = const PlanDiffer()
        .diff(current, proposed)
        .changes
        .map((c) => c.type)
        .toSet();
    expect(
      types,
      isNot(contains(PlanChangeType.moved)),
      reason: '来源指向一个不存在的块时无法说"从哪里移动过来"，不得猜',
    );
  });
}
