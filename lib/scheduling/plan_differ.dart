import 'dart:collection';

import 'package:personal_planner/scheduling/schedule_problem.dart';

enum PlanChangeType { added, moved, split, removed }

final class PlanChange {
  const PlanChange({
    required this.type,
    required this.blockId,
    this.before,
    this.after,
    this.reason,
  });

  final PlanChangeType type;
  final String blockId;
  final PlannedBlock? before;
  final PlannedBlock? after;

  /// 变更原因（片段解释码），来自引擎为该块生成的 `explanationCode`。
  ///
  /// 需求 FR-REPLAN-02 要求预览列出"新增、移动、拆分、取消和可能逾期的事项**及原因**"。
  /// 这里保留稳定的解释码而不是中文文案：文案由界面层用 `explanationLabel` 渲染，
  /// 与引擎的既有约定一致。
  final String? reason;
}

final class PlanDiff {
  PlanDiff(List<PlanChange> changes)
    : changes = UnmodifiableListView(List.of(changes));

  final List<PlanChange> changes;
}

/// 比较当前已确认计划与提案，产出带原因的差异。
///
/// 变更类型：
/// - `removed`：当前存在、提案中已消失的块；
/// - `moved`：**同一块**仍在，但任务、时间或锁定状态发生变化；
/// - `added`：提案中新出现、且其任务在原计划里没有块的块；
/// - `split`：提案中新出现、但其任务在原计划里已有块、且该任务的块数变多的块
///   ——即这段工作被拆成了更多片段，与"新增一个任务"不是一回事。
///
/// **"同一块"怎么判**（1.8.0，裁定第 4 点；设计 §5.2）：
///
/// 1. **来源关联优先**：提案里的块带 `continuedFromId` 且它指向当前计划里的某个块
///    ⇒ 那两块是同一块；
/// 2. 否则退回 **id 相等**（旧行为，保留）。
///
/// **为什么不能靠"让 id 保持不变"**：`applyProposal` 落库时构造
/// `persistedId = '<提案 id>:<block.id>'` 并把 `PlannedBlock.id` 设成它，
/// 复用旧 id 会让每确认一次就套一层提案前缀。因此判据必须是**来源**，
/// 而不是主键。
final class PlanDiffer {
  const PlanDiffer();

  PlanDiff diff(List<PlannedBlock> current, List<PlannedBlock> proposed) {
    final proposedById = {for (final block in proposed) block.id: block};
    final currentIds = {for (final block in current) block.id};
    // 当前计划按 id 索引：来源关联指的就是"当前计划里的哪一块"。
    final currentById = {for (final block in current) block.id: block};
    // 提案里"由某个当前块延续而来"的那些块：来源 id → 提案块。
    // 同一来源只取第一块（来源匹配本来就是一对一的，见 `linkBlockProvenance`）。
    final proposedBySource = <String, PlannedBlock>{};
    for (final block in proposed) {
      final source = block.continuedFromId;
      if (source != null && currentById.containsKey(source)) {
        proposedBySource.putIfAbsent(source, () => block);
      }
    }
    final currentCountByTask = _countByTask(current);
    final proposedCountByTask = _countByTask(proposed);
    final changes = <PlanChange>[];

    for (final before in current) {
      // **来源关联优先，其次 id 相等**（裁定第 4 点）。
      //
      // 来源关联说的是"当前计划的这一块延续成了提案里的哪一块"，
      // 因此它比 id 相等更强：id 相等只是"恰好同名"，而来源是**明确的因果**。
      final after = proposedBySource[before.id] ?? proposedById[before.id];
      if (after == null) {
        changes.add(
          PlanChange(
            type: PlanChangeType.removed,
            blockId: before.id,
            before: before,
            reason: before.explanationCode,
          ),
        );
      } else if (before.taskId != after.taskId ||
          before.range != after.range ||
          before.locked != after.locked) {
        changes.add(
          PlanChange(
            type: PlanChangeType.moved,
            blockId: before.id,
            before: before,
            after: after,
            reason: after.explanationCode ?? before.explanationCode,
          ),
        );
      }
    }

    for (final after in proposed) {
      if (currentIds.contains(after.id)) continue;
      // **已被认作某一块的延续时不算新增**：否则同一块会既报 moved 又报 added。
      if (after.continuedFromId case final source?
          when currentById.containsKey(source)) {
        continue;
      }
      final hadBlocksBefore = (currentCountByTask[after.taskId] ?? 0) > 0;
      final gainedChunks =
          (proposedCountByTask[after.taskId] ?? 0) >
          (currentCountByTask[after.taskId] ?? 0);
      changes.add(
        PlanChange(
          type: hadBlocksBefore && gainedChunks
              ? PlanChangeType.split
              : PlanChangeType.added,
          blockId: after.id,
          after: after,
          reason: after.explanationCode,
        ),
      );
    }

    return PlanDiff(changes);
  }
}

Map<String, int> _countByTask(List<PlannedBlock> blocks) {
  final counts = <String, int>{};
  for (final block in blocks) {
    counts.update(block.taskId, (value) => value + 1, ifAbsent: () => 1);
  }
  return counts;
}
