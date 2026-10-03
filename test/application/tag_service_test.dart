// R1 的仓库与服务层：标签此前只有两张表和迁移测试，没有任何读写方。
//
// 最重要的一条是"精确匹配而不是子串"：`tags`/`task_tags` 之所以用两张表而不是一个分隔
// 字符串列，就是为了让筛选和统计能按整词匹配。若实现退化成子串匹配，"论文"会连
// "论文修改"一起命中，而这正是当初建表的理由。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_tag_repository.dart';

final class _Clock implements Clock {
  _Clock(this.value);
  DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'tag-${++_value}';
}

void main() {
  late AppDatabase database;
  late _Clock clock;
  late TagService service;

  Future<void> seedTask(String id) => database
      .into(database.tasks)
      .insert(
        TasksCompanion.insert(
          id: id,
          title: '任务 $id',
          priority: 'medium',
          estimatedMinutes: 120,
          remainingMinutes: 120,
          energyLevel: 'medium',
          splitMode: 'splittable',
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          status: 'open',
          createdAtUtc: 1,
          updatedAtUtc: 1,
        ),
      );

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    clock = _Clock(DateTime.utc(2026, 10, 5, 2));
    service = TagService(
      repository: DriftTagRepository(database),
      clock: clock,
      idGenerator: _Ids(),
    );
    await seedTask('task-1');
    await seedTask('task-2');
  });

  tearDown(() => database.close());

  Future<int> linkCount() async =>
      (await database.select(database.taskTags).get()).length;

  test('同名标签只建一行，名称两端空白被归一', () async {
    final first = await service.ensureTag('论文');
    final again = await service.ensureTag('  论文  ');

    expect(again.id, first.id);
    expect((await service.listTags()).map((tag) => tag.name).toList(), ['论文']);
  });

  test('标签按整词匹配：有"论文修改"不影响只打"论文"的任务', () async {
    // 建两个前缀相同的标签，只给任务打其中一个。
    await service.ensureTag('论文修改');
    await service.setTaskTags('task-1', ['论文']);

    final tags = await service.tagsForTask('task-1');

    // 子串实现会连"论文修改"一起返回，这里必须只有"论文"。
    expect(tags.map((tag) => tag.name).toList(), ['论文']);
    expect(await linkCount(), 1);
  });

  test('设置任务标签是差量更新，重复保存同一组不产生多余关联', () async {
    await service.setTaskTags('task-1', ['论文', '深度工作']);
    expect(await linkCount(), 2);

    // 同一组再存一次：关联数不变，也不该重建行。
    await service.setTaskTags('task-1', ['深度工作', '论文']);
    expect(await linkCount(), 2);

    // 去掉一个：对应关联被删除，另一个保留。
    await service.setTaskTags('task-1', ['深度工作']);
    expect(
      (await service.tagsForTask('task-1')).map((tag) => tag.name).toList(),
      ['深度工作'],
    );
    expect(await linkCount(), 1);

    // 清空即全部解除。
    await service.setTaskTags('task-1', const []);
    expect(await service.tagsForTask('task-1'), isEmpty);
    expect(await linkCount(), 0);
  });

  test('标签是任务级的：给一个任务打标签不影响另一个', () async {
    await service.setTaskTags('task-1', ['论文']);

    expect((await service.tagsForTask('task-1')).single.name, '论文');
    expect(await service.tagsForTask('task-2'), isEmpty);
  });

  test('空名称被拒绝，不写入任何标签', () async {
    await expectLater(service.ensureTag('   '), throwsArgumentError);

    await service.setTaskTags('task-1', ['  ', '论文']);
    // 空白被忽略而不是建成一个空名标签。
    expect((await service.listTags()).map((tag) => tag.name).toList(), ['论文']);
  });

  test('allTagNames 返回去重后的名称集合，供统计筛选列出可选项', () async {
    await service.setTaskTags('task-1', ['论文', '深度工作']);
    await service.setTaskTags('task-2', ['论文']);

    expect(await service.allTagNames(), {'论文', '深度工作'});
  });
}
