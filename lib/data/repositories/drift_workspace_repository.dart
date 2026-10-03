import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';

/// `WorkspaceRepository` 的 drift 实现。
///
/// 两处 `onConflict` 都刻意保留 `createdAtUtc`：领域与项目都会被反复改名、改排序、
/// 改生活标记，若沿用"整体覆盖"式写入，每次编辑都会把创建时间一并改写，FR-DATA-08
/// 要求的"创建时间稳定"就不成立了。
final class DriftWorkspaceRepository implements WorkspaceRepository {
  const DriftWorkspaceRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<List<PlannerArea>> listAreas() async {
    final query = _database.select(_database.areas)
      ..orderBy([
        (row) => OrderingTerm.asc(row.sortOrder),
        (row) => OrderingTerm.asc(row.name),
      ]);
    return (await query.get()).map(_toArea).toList(growable: false);
  }

  @override
  Future<List<PlannerProject>> listProjects() async {
    final query = _database.select(_database.projects)
      ..orderBy([
        (row) => OrderingTerm.asc(row.areaId),
        (row) => OrderingTerm.asc(row.name),
      ]);
    return (await query.get()).map(_toProject).toList(growable: false);
  }

  @override
  Future<void> saveArea(PlannerArea area) => _database
      .into(_database.areas)
      .insert(
        db.AreasCompanion(
          id: Value(area.id),
          name: Value(area.name),
          color: Value(area.color),
          sortOrder: Value(area.sortOrder),
          isLife: Value(area.isLife),
          createdAtUtc: Value(area.createdAtUtc.microsecondsSinceEpoch),
          updatedAtUtc: Value(area.updatedAtUtc.microsecondsSinceEpoch),
        ),
        onConflict: DoUpdate(
          (old) => db.AreasCompanion(
            name: Value(area.name),
            color: Value(area.color),
            sortOrder: Value(area.sortOrder),
            isLife: Value(area.isLife),
            updatedAtUtc: Value(area.updatedAtUtc.microsecondsSinceEpoch),
          ),
        ),
      );

  @override
  Future<void> saveProject(PlannerProject project) => _database
      .into(_database.projects)
      .insert(
        db.ProjectsCompanion(
          id: Value(project.id),
          areaId: Value(project.areaId),
          name: Value(project.name),
          archivedAtUtc: Value(project.archivedAtUtc?.microsecondsSinceEpoch),
          createdAtUtc: Value(project.createdAtUtc.microsecondsSinceEpoch),
          updatedAtUtc: Value(project.updatedAtUtc.microsecondsSinceEpoch),
        ),
        onConflict: DoUpdate(
          (old) => db.ProjectsCompanion(
            areaId: Value(project.areaId),
            name: Value(project.name),
            // 显式写入（含 null）而不是省略：取消归档必须能把该列改回 NULL，
            // 省略字段的写法做不到这一点。
            archivedAtUtc: Value(project.archivedAtUtc?.microsecondsSinceEpoch),
            updatedAtUtc: Value(project.updatedAtUtc.microsecondsSinceEpoch),
          ),
        ),
      );

  PlannerArea _toArea(db.Area row) => PlannerArea(
    id: row.id,
    name: row.name,
    color: row.color,
    sortOrder: row.sortOrder,
    isLife: row.isLife,
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.createdAtUtc,
      isUtc: true,
    ),
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.updatedAtUtc,
      isUtc: true,
    ),
  );

  PlannerProject _toProject(db.Project row) => PlannerProject(
    id: row.id,
    areaId: row.areaId,
    name: row.name,
    archivedAtUtc: row.archivedAtUtc == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(row.archivedAtUtc!, isUtc: true),
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.createdAtUtc,
      isUtc: true,
    ),
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.updatedAtUtc,
      isUtc: true,
    ),
  );
}
