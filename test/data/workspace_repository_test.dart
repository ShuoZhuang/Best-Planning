// R2：领域与项目的**第一个写入方**。
//
// 此前 `areas` 与 `projects` 两张表建好了却没有任何写入路径，因此 `task.projectId` 恒为
// 空、领域统计退化为"未分类"，而 `areas.is_life` 永远为 false——生活配额与统计的"生活"
// 分类都不生效。这里既验证读写往返，也验证"经本仓库写入的数据能被生活标记的读取端认出来"，
// 因为这两端此前各自完成、从未在真实数据上碰过面。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/workspace.dart';

final _created = DateTime.utc(2026, 10, 1, 8);
final _edited = DateTime.utc(2026, 10, 5, 9);

void main() {
  late AppDatabase database;
  late DriftWorkspaceRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftWorkspaceRepository(database);
  });

  tearDown(() => database.close());

  PlannerArea area(String id, {bool isLife = false, int sortOrder = 0}) =>
      PlannerArea(
        id: id,
        name: id,
        color: 0,
        sortOrder: sortOrder,
        isLife: isLife,
        createdAtUtc: _created,
        updatedAtUtc: _created,
      );

  Future<void> seedTask(String id, String projectId, String areaId) => database
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

  test('保存并读回领域，生活标记与排序都保留', () async {
    await repository.saveArea(area('科研', sortOrder: 1));
    await repository.saveArea(area('生活', isLife: true));

    final areas = await repository.listAreas();
    expect(areas.map((item) => item.id).toList(), ['生活', '科研']);
    expect(areas.firstWhere((item) => item.id == '生活').isLife, isTrue);
    expect(areas.firstWhere((item) => item.id == '科研').isLife, isFalse);
  });

  test('改名保留创建时间，只推进修改时间', () async {
    await repository.saveArea(area('学业'));

    // FR-DATA-08：创建时间必须稳定，否则每次编辑都会让"这条记录何时建立"失真。
    await repository.saveArea(
      area('学业').copyWith(name: '学业任务', updatedAtUtc: _edited),
    );

    final saved = (await repository.listAreas()).single;
    expect(saved.name, '学业任务');
    expect(saved.createdAtUtc, _created);
    expect(saved.updatedAtUtc, _edited);
  });

  test('项目归属领域，归档与取消归档都能往返', () async {
    await repository.saveArea(area('生活', isLife: true));
    final project = PlannerProject(
      id: 'project-1',
      areaId: '生活',
      name: '健身',
      createdAtUtc: _created,
      updatedAtUtc: _created,
    );
    await repository.saveProject(project);

    expect((await repository.listProjects()).single.isArchived, isFalse);

    await repository.saveProject(
      project.copyWith(archivedAtUtc: _edited, updatedAtUtc: _edited),
    );
    expect((await repository.listProjects()).single.isArchived, isTrue);

    // 取消归档必须能真的写回 NULL，否则项目会永久留在归档态。
    await repository.saveProject(project.copyWith(updatedAtUtc: _edited));
    final restored = (await repository.listProjects()).single;
    expect(restored.isArchived, isFalse);
    expect(restored.createdAtUtc, _created);
  });

  test('经本仓库写入的分类能被生活标记的读取端认出来', () async {
    await repository.saveArea(area('生活', isLife: true));
    await repository.saveArea(area('工作'));
    await repository.saveProject(
      PlannerProject(
        id: 'project-life',
        areaId: '生活',
        name: '健身',
        createdAtUtc: _created,
        updatedAtUtc: _created,
      ),
    );
    await repository.saveProject(
      PlannerProject(
        id: 'project-work',
        areaId: '工作',
        name: '项目甲',
        createdAtUtc: _created,
        updatedAtUtc: _created,
      ),
    );
    await seedTask('task-life', 'project-life', '生活');
    await seedTask('task-work', 'project-work', '工作');

    final lifeTaskIds = await DriftLifeAreaLookup(database).lifeTaskIds();

    expect(lifeTaskIds, {'task-life'});
  });
}
