import 'package:personal_planner/core/ids.dart';

/// 领域（学业、科研、生活……）。
///
/// 需求 FR-TASK-02 要求任务可归属领域与项目；`isLife` 是用户决定的"生活标记放在领域上"
/// 的落点——任务经项目归属推导是否生活任务，因此**标记只有经领域与项目的写入路径才能
/// 产生**，这也是此前生活配额与统计"生活"分类一直不生效的原因。
final class PlannerArea {
  PlannerArea({
    required this.id,
    required String name,
    required this.color,
    required this.sortOrder,
    this.isLife = false,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : name = name.trim() {
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Cannot be empty.');
    }
    if (sortOrder < 0) {
      throw ArgumentError.value(
        sortOrder,
        'sortOrder',
        'Must not be negative.',
      );
    }
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final EntityId id;
  final String name;
  final int color;
  final int sortOrder;
  final bool isLife;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  PlannerArea copyWith({
    String? name,
    int? color,
    int? sortOrder,
    bool? isLife,
    DateTime? updatedAtUtc,
  }) => PlannerArea(
    id: id,
    name: name ?? this.name,
    color: color ?? this.color,
    sortOrder: sortOrder ?? this.sortOrder,
    isLife: isLife ?? this.isLife,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

/// 项目。必须有归属领域，因此不存在"没有领域的项目"。
final class PlannerProject {
  PlannerProject({
    required this.id,
    required this.areaId,
    required String name,
    this.archivedAtUtc,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : name = name.trim() {
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Cannot be empty.');
    }
    if (areaId.isEmpty) {
      throw ArgumentError.value(areaId, 'areaId', 'Cannot be empty.');
    }
    if (archivedAtUtc != null) _requireUtc(archivedAtUtc!, 'archivedAtUtc');
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final EntityId id;
  final EntityId areaId;
  final String name;
  final DateTime? archivedAtUtc;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  bool get isArchived => archivedAtUtc != null;

  PlannerProject copyWith({
    EntityId? areaId,
    String? name,
    Object? archivedAtUtc = _unset,
    DateTime? updatedAtUtc,
  }) => PlannerProject(
    id: id,
    areaId: areaId ?? this.areaId,
    name: name ?? this.name,
    archivedAtUtc: identical(archivedAtUtc, _unset)
        ? this.archivedAtUtc
        : archivedAtUtc as DateTime?,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

const Object _unset = Object();

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) throw ArgumentError.value(value, name, 'Must be UTC.');
}
