// 1.8.0（裁定第 1、2 点；设计 §5.1／§5.2）：**`id` 与来源身份必须分开**。
//
// 为什么这是一条必须由用例守住的规则，而不是"实现细节"：
//
//   `applyProposal` 落库时构造 `persistedId = '${proposal.proposalId}:${block.id}'`
//   （`drift_plan_repository.dart:267`），并且**把 `PlannedBlock.id` 设成这个 persistedId**
//   存回确认计划。因此如果新提案里让 `block.id` 去复用确认计划里的旧 id，
//   下一次确认就会得到 `'<新提案 id>:<旧提案 id>:<原引擎 id>'` ——
//   **每确认一次就再套一层提案前缀，id 无限增长**。
//
//   所以：`id` 永远是**引擎本次生成的新 id**；来源关联走**新字段** `continuedFromId`。
//
// 本文件先钉住数据层的语义（第 2 步），配对算法与引擎接线在后续步骤接上。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final start = DateTime.utc(2026, 10, 12, 1);
  TimeRange range(int hour, [int minutes = 60]) => TimeRange(
    startUtc: start.add(Duration(hours: hour)),
    endUtc: start.add(Duration(hours: hour, minutes: minutes)),
  );

  PlannedBlock block(
    String id, {
    String taskId = 'task-1',
    int hour = 0,
    String? continuedFromId,
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: range(hour),
    continuedFromId: continuedFromId,
  );

  test('**`continuedFromId` 与 `id` 是两个独立的字段**', () {
    final b = block(
      'block:task-1:123:60',
      continuedFromId: 'proposal-1:block:x',
    );

    expect(
      b.id,
      'block:task-1:123:60',
      reason: 'id 是引擎本次生成的新 id，**不得**被来源 id 覆盖',
    );
    expect(
      b.continuedFromId,
      'proposal-1:block:x',
      reason: '来源身份单独承载，指向当前确认计划里的块',
    );
    expect(
      b.id,
      isNot(b.continuedFromId),
      reason:
          '两者相等就意味着实现退回了"复用旧 id"的写法——那会让 persistedId '
          '每确认一次套一层提案前缀',
    );
  });

  test('新排进来的块没有来源（`continuedFromId` 为空）', () {
    expect(block('block:new').continuedFromId, isNull);
  });

  test('相等性包含来源字段：同一对 (id, continuedFromId) 才相等', () {
    // 相等性必须包含它，否则"同一 id 但来源不同"会被当成同一块，
    // 而配对与最小化都依赖这个区分。
    expect(
      block('same', continuedFromId: 'old-1'),
      block('same', continuedFromId: 'old-1'),
    );
    expect(
      block('same', continuedFromId: 'old-1'),
      isNot(block('same', continuedFromId: 'old-2')),
    );
    expect(
      block('same', continuedFromId: 'old-1'),
      isNot(block('same')),
      reason: '有来源与无来源不是同一块',
    );
  });

  test('`continueFrom` 复制出**新 id + 指向来源**，不修改原块', () {
    // 引擎需要「基于某块派生一个候选」的能力，而派生必须是**纯**的：
    // 原地改 id 会让同一份输入在不同阶段看到不同的块。
    //
    // **来源永远是被派生的那一块**，与新 id 无关——把 `continuedFromId` 设成新 id
    // 会让来源关联退化成"指向自己"，而查原位与判"移动"要的恰恰是指回**上一版**。
    final source = PlannedBlock(
      id: 'proposal-1:block:src',
      taskId: 'task-1',
      range: range(3),
      explanationCode: 'scheduled',
    );

    final derived = source.continueFrom(
      'block:task-1:999:60',
      newRange: range(5),
    );

    expect(derived.id, 'block:task-1:999:60', reason: '新提案给这块起的新名字');
    expect(
      derived.continuedFromId,
      'proposal-1:block:src',
      reason: '来源是**被派生的那一块**，不是新 id',
    );
    expect(derived.range, range(5), reason: '派生时可以给新位置');
    expect(derived.taskId, source.taskId);
    expect(derived.locked, source.locked, reason: '延续不等于锁定');
    expect(derived.explanationCode, 'scheduled', reason: '没有显式覆盖时沿用来源的解释码');
    expect(source.id, 'proposal-1:block:src', reason: '原块不得被修改——派生是纯操作');
    expect(source.continuedFromId, isNull);
  });

  test('`continueFrom` 不传新位置时沿用本块位置', () {
    final source = PlannedBlock(
      id: 'block:src',
      taskId: 'task-1',
      range: range(3),
    );

    expect(source.continueFrom('new-id').range, source.range);
  });

  test('`continueFrom` 保留原有的 `explanationCode`（除非显式覆盖）', () {
    final source = PlannedBlock(
      id: 'block:src',
      taskId: 'task-1',
      range: range(0),
      explanationCode: 'deferred',
    );

    expect(source.continueFrom('new-id').explanationCode, 'deferred');
    expect(
      source
          .continueFrom('new-id', explanationCode: 'scheduled')
          .explanationCode,
      'scheduled',
    );
  });
}
