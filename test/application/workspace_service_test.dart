// R2 服务层：领域与项目的建立、编辑与默认初始化。
//
// 最重要的断言是"经服务建立的分类能让生活标记的读取端生效"——服务、仓库、读取端各自
// 完成是不够的，只有串起来才能说明生活配额与统计的"生活"分类真的会被点亮。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/area_palette.dart';
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

  Future<void> seedTask(String id, String projectId) async {
    final project = await (database.select(
      database.projects,
    )..where((row) => row.id.equals(projectId))).getSingle();
    await database
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
            areaId: Value(project.areaId),
          ),
        );
  }

  test('新建领域按建立顺序追加排序并带上时戳', () async {
    final first = await service.createArea('学业');
    final second = await service.createArea('科研');

    expect(first.sortOrder, 0);
    expect(second.sortOrder, 1);
    expect(first.createdAtUtc, _now);
    expect((await service.listAreas()).map((a) => a.name).toList(), [
      '学业',
      '科研',
    ]);
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
    final before = (await service.listAreas()).firstWhere(
      (a) => a.id == life.id,
    );
    await service.setAreaLife(before, false);
    expect(await lookup.lifeTaskIds(), isEmpty);
    final after = (await service.listAreas()).firstWhere(
      (a) => a.id == life.id,
    );
    expect(after.createdAtUtc, before.createdAtUtc);
  });

  test('项目不能挂到不存在的领域上', () async {
    await expectLater(
      service.createProject(name: '悬空项目', areaId: 'missing'),
      throwsArgumentError,
    );
    expect(await service.listProjects(), isEmpty);
  });

  test('项目改名只推进修改时间，归档状态不受影响', () async {
    final area = await service.createArea('科研');
    final project = await service.createProject(name: '论文', areaId: area.id);
    await service.archiveProject(project, archived: true);
    final archived = (await service.listProjects()).single;

    await service.renameProject(archived, '毕业论文');

    final renamed = (await service.listProjects()).single;
    expect(renamed.name, '毕业论文');
    expect(renamed.createdAtUtc, archived.createdAtUtc);
    expect(renamed.updatedAtUtc, _now);
    // 改名不应顺手取消归档：归档是项目自身的状态。
    expect(renamed.isArchived, isTrue);
    expect(renamed.archivedAtUtc, archived.archivedAtUtc);
  });

  test('空仓库会按约定顺序建立五个默认领域，重复调用不重复写入', () async {
    expect(await service.ensureDefaultAreas(), 5);

    final areas = await service.listAreas();
    expect(areas.map((a) => a.name).toList(), ['学业', '科研', '竞赛', '工作', '生活']);
    // 生活是唯一被标记为生活领域的默认领域，生活配额因此才有作用对象。
    expect(areas.where((a) => a.isLife).map((a) => a.name).toList(), ['生活']);

    expect(await service.ensureDefaultAreas(), 0);
    expect((await service.listAreas()).length, 5);
  });

  test('已有工作领域时只补齐其余默认领域并保持现有排序', () async {
    final existing = await service.createArea('  工作  ');

    expect(await service.ensureDefaultAreas(), 4);
    final areas = await service.listAreas();
    expect(areas.map((area) => area.id), contains(existing.id));
    expect(areas.map((area) => area.name).toList(), [
      '工作',
      '学业',
      '科研',
      '竞赛',
      '生活',
    ]);
    expect(await service.ensureDefaultAreas(), 0);
  });

  test('默认领域按现有排序保存前五种可区分颜色', () async {
    await service.ensureDefaultAreas();

    final areas = await service.listAreas();
    expect(
      areas.map((area) => area.color).toList(),
      areaPaletteArgb.take(5).toList(),
    );
  });

  test('新领域优先使用未占用色，色板耗尽后按排序循环', () async {
    final created = <int>[];
    for (var index = 0; index < areaPaletteArgb.length + 1; index++) {
      created.add((await service.createArea('领域 $index')).color);
    }

    expect(created.take(areaPaletteArgb.length), areaPaletteArgb);
    expect(created.last, areaPaletteArgb.first);
  });

  test('修改领域颜色只改变目标领域的颜色和修改时间', () async {
    final area = await service.createArea('学业', isLife: true);

    await service.setAreaColor(area.id, 0xff123456);

    final updated = (await service.listAreas()).single;
    expect(updated.color, 0xff123456);
    expect(updated.name, area.name);
    expect(updated.sortOrder, area.sortOrder);
    expect(updated.isLife, isTrue);
    expect(updated.createdAtUtc, area.createdAtUtc);
    expect(updated.updatedAtUtc, _now);
  });

  test('拒绝透明或越界的领域颜色且不修改存储', () async {
    final area = await service.createArea('学业');

    await expectLater(
      service.setAreaColor(area.id, 0x00123456),
      throwsArgumentError,
    );

    expect((await service.listAreas()).single.color, area.color);
  });
}
