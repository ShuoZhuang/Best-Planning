import 'dart:collection';

import 'package:personal_planner/scheduling/schedule_problem.dart';

enum PlanChangeType { added, moved, removed }

final class PlanChange {
  const PlanChange({
    required this.type,
    required this.blockId,
    this.before,
    this.after,
  });

  final PlanChangeType type;
  final String blockId;
  final PlannedBlock? before;
  final PlannedBlock? after;
}

final class PlanDiff {
  PlanDiff(List<PlanChange> changes)
    : changes = UnmodifiableListView(List.of(changes));

  final List<PlanChange> changes;
}

final class PlanDiffer {
  const PlanDiffer();

  PlanDiff diff(List<PlannedBlock> current, List<PlannedBlock> proposed) {
    final proposedById = {for (final block in proposed) block.id: block};
    final currentIds = {for (final block in current) block.id};
    final changes = <PlanChange>[];

    for (final before in current) {
      final after = proposedById[before.id];
      if (after == null) {
        changes.add(
          PlanChange(
            type: PlanChangeType.removed,
            blockId: before.id,
            before: before,
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
          ),
        );
      }
    }

    for (final after in proposed) {
      if (!currentIds.contains(after.id)) {
        changes.add(
          PlanChange(
            type: PlanChangeType.added,
            blockId: after.id,
            after: after,
          ),
        );
      }
    }
    return PlanDiff(changes);
  }
}
