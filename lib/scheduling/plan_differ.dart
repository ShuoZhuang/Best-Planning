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
/// - `moved`：同一块 ID 仍在，但任务、时间或锁定状态发生变化；
/// - `added`：提案中新出现、且其任务在原计划里没有块的块；
/// - `split`：提案中新出现、但其任务在原计划里已有块、且该任务的块数变多的块
///   ——即这段工作被拆成了更多片段，与"新增一个任务"不是一回事。
final class PlanDiffer {
  const PlanDiffer();

  PlanDiff diff(List<PlannedBlock> current, List<PlannedBlock> proposed) {
    final proposedById = {for (final block in proposed) block.id: block};
    final currentIds = {for (final block in current) block.id};
    final currentCountByTask = _countByTask(current);
    final proposedCountByTask = _countByTask(proposed);
    final changes = <PlanChange>[];

    for (final before in current) {
      final after = proposedById[before.id];
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
