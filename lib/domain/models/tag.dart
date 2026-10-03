import 'package:personal_planner/core/ids.dart';

/// 自定义标签（FR-TASK-02「补充分类」、FR-STAT-02「按标签筛选统计」）。
///
/// 标签与领域／项目不同：它是**跨领域**的横切分类（"需要专注""等人回复"），一个任务可以
/// 同时有多个，彼此之间没有层次关系，因此不需要"必须挂在某个领域下"这类校验。
///
/// 名称是标签对用户的唯一标识：界面按名称增删。数据库层面没有唯一约束（那需要一次
/// schema 迁移），所以"同名只有一行"这条约定由 `TagService` 先查后建来保证。
final class PlannerTag {
  PlannerTag({
    required this.id,
    required String name,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : name = name.trim() {
    if (this.name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Cannot be empty.');
    }
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final EntityId id;
  final String name;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  /// 改名只推进修改时间；创建时间保持不变（FR-DATA-08）。
  PlannerTag copyWith({String? name, DateTime? updatedAtUtc}) => PlannerTag(
    id: id,
    name: name ?? this.name,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) throw ArgumentError.value(value, name, 'Must be UTC.');
}
