// R13：生活标记取自领域列 `areas.is_life`，经 项目 → 领域 归属推导到任务。
//
// 此前没有代码读取该列：统计侧用领域名是否包含"生活/娱乐/休息/life"来猜，排程侧
// 根本不设置该字段。这里的用例刻意给领域起名 `area-life`、`area-work`——名字里
// 没有任何中文关键词——因此只有读真实标记列才能通过，靠名字匹配必然失败。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';

void main() {
  late AppDatabase database;
  late DriftLifeAreaLookup lookup;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    lookup = DriftLifeAreaLookup(database);
  });

  tearDown(() => database.close());

  Future<void> seedArea(String id, {required bool isLife}) => database
      .into(database.areas)
      .insert(
        AreasCompanion.insert(
          id: id,
          name: id,
          color: 0,
          sortOrder: 0,
          isLife: Value(isLife),
        ),
      );

  Future<void> seedProject(String id, String areaId) => database
      .into(database.projects)
      .insert(ProjectsCompanion.insert(id: id, areaId: areaId, name: id));

  Future<void> seedTask(String id, {String? areaId, String? projectId}) =>
      database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: id,
              title: '任务 $id',
              priority: 'medium',
              estimatedMinutes: 60,
              remainingMinutes: 60,
              energyLevel: 'medium',
              splitMode: 'splittable',
              minChunkMinutes: 30,
              maxChunkMinutes: 60,
              status: 'inbox',
              createdAtUtc: 1,
              updatedAtUtc: 1,
              projectId: Value(projectId),
              areaId: Value(areaId),
            ),
          );

  test('任务直接领域决定是否计入个人生活时间', () async {
    await seedArea('area-life', isLife: true);
    await seedArea('area-work', isLife: false);
    await seedProject('project-life', 'area-life');
    await seedProject('project-work', 'area-work');
    await seedTask('task-life', areaId: 'area-life', projectId: 'project-life');
    await seedTask('task-work', areaId: 'area-work', projectId: 'project-work');

    expect(await lookup.lifeTaskIds(), {'task-life'});
  });

  test('没有项目但有直接领域的任务仍计入，旧的未分类任务保持排除', () async {
    await seedArea('area-life', isLife: true);
    await seedProject('project-life', 'area-life');
    await seedTask('task-life', areaId: 'area-life');
    await seedTask('task-inbox');

    expect(await lookup.lifeTaskIds(), {'task-life'});
  });

  test('领域标记变更后结果随之变更，不需要改任务行', () async {
    await seedArea('area-home', isLife: false);
    await seedProject('project-home', 'area-home');
    await seedTask('task-home', areaId: 'area-home');
    expect(await lookup.lifeTaskIds(), isEmpty);

    // 只改领域这一行：任务经项目推导，因此标记立即生效。
    await (database.update(database.areas)
          ..where((row) => row.id.equals('area-home')))
        .write(const AreasCompanion(isLife: Value(true)));
    expect(await lookup.lifeTaskIds(), {'task-home'});
  });

  test('项目领域与任务直接领域冲突时以任务领域为准', () async {
    await seedArea('area-life', isLife: true);
    await seedArea('area-work', isLife: false);
    await seedProject('project-work', 'area-work');
    await seedTask(
      'task-direct-life',
      areaId: 'area-life',
      projectId: 'project-work',
    );

    expect(await lookup.lifeTaskIds(), {'task-direct-life'});
  });

  test('没有数据时返回空集', () async {
    expect(await lookup.lifeTaskIds(), isEmpty);
  });
}
