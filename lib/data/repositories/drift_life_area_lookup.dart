import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';

/// 用一次三表内连接回答 `LifeAreaLookup`：只取经项目落到生活领域的任务。
///
/// 用内连接而不是左连接是刻意的：没有项目、或项目没有领域的任务本就不属于任何
/// 领域，内连接天然把它们排除，不需要额外判空。
final class DriftLifeAreaLookup implements LifeAreaLookup {
  const DriftLifeAreaLookup(this._database);

  final db.AppDatabase _database;

  @override
  Future<Set<String>> lifeTaskIds() async {
    final query = _database.selectOnly(_database.tasks)
      ..addColumns([_database.tasks.id])
      ..join([
        innerJoin(
          _database.projects,
          _database.projects.id.equalsExp(_database.tasks.projectId),
        ),
        innerJoin(
          _database.areas,
          _database.areas.id.equalsExp(_database.projects.areaId),
        ),
      ])
      ..where(_database.areas.isLife.equals(true));

    final rows = await query.get();
    return {
      for (final row in rows) row.read(_database.tasks.id)!,
    };
  }
}
