// R2 服务层：领域与项目的建立、编辑与默认初始化。
//
// 最重要的断言是"经服务建立的分类能让生活标记的读取端生效"——服务、仓库、读取端各自
// 完成是不够的，只有串起来才能说明生活配额与统计的"生活"分类真的会被点亮。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 2);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

void main() {
  late AppDatabase database;
  late WorkspaceService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = WorkspaceService(
      repository: DriftWorkspaceRepository(database),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  tearDown(() => database.close());

  Future<void> seedTask(String id, String projectId) => database
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
        ),
      );

  test('新建领域按建立顺序追加排序并带上时戳', () async {
    final first = await service.createArea('学业');
    final second = await service.createArea('科研');

    expect(first.sortOrder, 0);
    expect(second.sortOrder, 1);
    expect(first.createdAtUtc, _now);
    expect((await service.listAreas()).map((a) => a.name).toList(), ['学业', '科研']);
  });

  test('生活标记只能由这一处设置，设置后读取端立即生效', () async {
    final life = await service.createArea('生活');
    final work = await service.createArea('工作');
    final lifeProject = await service.createProject(
      name: '健身',
      areaId: life.id,
    );
    final workProject = await service.createProject(
      name: '项目甲',
      areaId: work.id,
    );
    await seedTask('task-life', lifeProject.id);
    await seedTask('task-work', workProject.id);

    // 未标记前：没有人是生活任务。
    final lookup = DriftLifeAreaLookup(database);
    expect(await lookup.lifeTaskIds(), isEmpty);

    await service.setAreaLife(life, true);

    expect(await lookup.lifeTaskIds(), {'task-life'});

    // 取消标记同样立即生效，且不改动创建时间。
    final before = (await service.listAreas()).firstWhere((a) => a.id == life.id);
    await service.setAreaLife(before, false);
    expect(await lookup.lifeTaskIds(), isEmpty);
    final after = (await service.listAreas()).firstWhere((a) => a.id == life.id);
    expect(after.createdAtUtc, before.createdAtUtc);
  });

  test('项目不能挂到不存在的领域上', () async {
    await expectLater(
      service.createProject(name: '悬空项目', areaId: 'missing'),
      throwsArgumentError,
    );
    expect(await service.listProjects(), isEmpty);
  });

  test('默认领域只在全新安装时建立，重复调用不重复写入', () async {
    expect(await service.ensureDefaultAreas(), 3);

    final areas = await service.listAreas();
    expect(areas.map((a) => a.name).toList(), ['学业', '科研', '生活']);
    // 生活是唯一被标记为生活领域的默认领域，生活配额因此才有作用对象。
    expect(areas.where((a) => a.isLife).map((a) => a.name).toList(), ['生活']);

    expect(await service.ensureDefaultAreas(), 0);
    expect((await service.listAreas()).length, 3);
  });

  test('用户删除默认领域后不会被自动加回来', () async {
    await service.ensureDefaultAreas();
    await service.createArea('副业');

    // 已有领域即视为已初始化：初始化不该覆盖用户的整理结果。
    expect(await service.ensureDefaultAreas(), 0);
    expect((await service.listAreas()).length, 4);
  });
}
