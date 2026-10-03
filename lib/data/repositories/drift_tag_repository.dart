import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/tag.dart';
import 'package:personal_planner/domain/repositories/tag_repository.dart';

/// `TagRepository` 的 drift 实现。
///
/// 关联的写入用 `insertOrIgnore` 而不是 upsert：`task_tags` 的复合主键就是行身份，
/// 一条关联只有"建立"和"删除"两个动作，重复建立时既不该报错，也不该把创建时间改写掉。
final class DriftTagRepository implements TagRepository {
  const DriftTagRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<List<PlannerTag>> listTags() async {
    final query = _database.select(_database.tags)
      ..orderBy([(row) => OrderingTerm.asc(row.name)]);
    return (await query.get()).map(_toTag).toList(growable: false);
  }

  @override
  Future<void> saveTag(PlannerTag tag) => _database
      .into(_database.tags)
      .insert(
        db.TagsCompanion(
          id: Value(tag.id),
          name: Value(tag.name),
          createdAtUtc: Value(tag.createdAtUtc.microsecondsSinceEpoch),
          updatedAtUtc: Value(tag.updatedAtUtc.microsecondsSinceEpoch),
        ),
        // 与领域／项目同口径：改名只推进修改时间，创建时间由首次写入决定。
        onConflict: DoUpdate(
          (old) => db.TagsCompanion(
            name: Value(tag.name),
            updatedAtUtc: Value(tag.updatedAtUtc.microsecondsSinceEpoch),
          ),
        ),
      );

  @override
  Future<List<PlannerTag>> tagsForTask(String taskId) async {
    final query = _database.select(_database.tags).join([
      innerJoin(
        _database.taskTags,
        _database.taskTags.tagId.equalsExp(_database.tags.id),
      ),
    ])..where(_database.taskTags.taskId.equals(taskId));
    query.orderBy([OrderingTerm.asc(_database.tags.name)]);
    return (await query.get())
        .map((row) => _toTag(row.readTable(_database.tags)))
        .toList(growable: false);
  }

  @override
  Future<void> linkTag(String taskId, String tagId, DateTime linkedAtUtc) =>
      _database
          .into(_database.taskTags)
          .insert(
            db.TaskTagsCompanion(
              taskId: Value(taskId),
              tagId: Value(tagId),
              createdAtUtc: Value(linkedAtUtc.microsecondsSinceEpoch),
            ),
            mode: InsertMode.insertOrIgnore,
          );

  @override
  Future<void> unlinkTag(String taskId, String tagId) => (_database.delete(
    _database.taskTags,
  )..where((row) => row.taskId.equals(taskId) & row.tagId.equals(tagId))).go();

  PlannerTag _toTag(db.Tag row) => PlannerTag(
    id: row.id,
    name: row.name,
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
