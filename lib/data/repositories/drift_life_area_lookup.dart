import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';

/// 用任务的直接领域回答 `LifeAreaLookup`。
///
/// 项目只是领域下的可选分组，不能覆盖任务自己的领域；没有直接领域的旧任务仍保持
/// 未分类，内连接会自然排除它们。
final class DriftLifeAreaLookup implements LifeAreaLookup {
  const DriftLifeAreaLookup(this._database);

  final db.AppDatabase _database;

  @override
  Future<Set<String>> lifeTaskIds() async {
    final query = _database.selectOnly(_database.tasks)
      ..addColumns([_database.tasks.id])
      ..join([
        innerJoin(
          _database.areas,
          _database.areas.id.equalsExp(_database.tasks.areaId),
        ),
      ])
      ..where(_database.areas.isLife.equals(true));

    final rows = await query.get();
    return {for (final row in rows) row.read(_database.tasks.id)!};
  }
}
