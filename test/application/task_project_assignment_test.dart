// R2：把任务归属到项目——任务通向领域的**唯一路径**。
//
// 此前领域与项目即使建得完整、生活标记写得正确，也没有任何任务能算作生活任务，因为
// `tasks.project_id` 没有赋值入口，而分类与生活标记都经它推导。这里既验证服务语义，
// 也验证"归属之后生活标记对该任务立即生效"，因为那才是这条链路真正要达成的结果。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 2);
final _later = DateTime.utc(2026, 10, 5, 3);

final class _Clock implements Clock {
  _Clock(this.value);
  DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

void main() {
  late AppDatabase database;
  late _Clock clock;
  late TaskService tasks;
  late WorkspaceService workspace;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    clock = _Clock(_now);
    tasks = TaskService(
      repository: DriftTaskRepository(database.taskDao),
      clock: clock,
      idGenerator: _Ids(),
    );
    workspace = WorkspaceService(
      repository: DriftWorkspaceRepository(database),
      clock: clock,
      idGenerator: _Ids(),
    );
  });

  tearDown(() => database.close());

  Future<String> newTask(String title) async {
    final created = await tasks.quickAdd(title, 60);
    return created.task!.id;
  }

  test('归属到生活领域下的项目后，生活标记立即对该任务生效', () async {
    final life = await workspace.createArea('生活', isLife: true);
    final project = await workspace.createProject(name: '健身', areaId: life.id);
    final taskId = await newTask('跑步');

    final lookup = DriftLifeAreaLookup(database);
    // 未归属：没有任何任务算作生活任务——这正是此前的常态。
    expect(await lookup.lifeTaskIds(), isEmpty);

    expect(await tasks.assignProject(taskId, project.id), isTrue);

    expect(await lookup.lifeTaskIds(), {taskId});
    expect((await tasks.findById(taskId))!.projectId, project.id);
  });

  test('取消归属同样立即生效', () async {
    final life = await workspace.createArea('生活', isLife: true);
    final project = await workspace.createProject(name: '健身', areaId: life.id);
    final taskId = await newTask('跑步');
    await tasks.assignProject(taskId, project.id);

    final lookup = DriftLifeAreaLookup(database);
    expect(await lookup.lifeTaskIds(), {taskId});

    expect(await tasks.assignProject(taskId, null), isTrue);
    expect((await tasks.findById(taskId))!.projectId, isNull);
    expect(await lookup.lifeTaskIds(), isEmpty);
  });

  test('归属未变化时不写入，避免"最近修改"被无谓推进', () async {
    final project = await workspace.createProject(
      name: '项目甲',
      areaId: (await workspace.createArea('工作')).id,
    );
    final taskId = await newTask('写方案');
    await tasks.assignProject(taskId, project.id);
    final afterFirst = (await tasks.findById(taskId))!.updatedAtUtc;

    clock.value = _later;
    expect(await tasks.assignProject(taskId, project.id), isTrue);

    expect((await tasks.findById(taskId))!.updatedAtUtc, afterFirst);
  });

  test('任务不存在时返回 false 而不是抛错', () async {
    expect(await tasks.assignProject('missing', null), isFalse);
  });

  test('不存在的项目由数据库外键拒绝，服务层不重复校验', () async {
    final taskId = await newTask('跑步');

    // 服务层不做存在性判断是有意为之：库里已有外键且连接时开启了 foreign_keys，
    // 重复实现一份校验只会与库结构脱节。
    await expectLater(
      tasks.assignProject(taskId, 'missing-project'),
      throwsA(anything),
    );
    expect((await tasks.findById(taskId))!.projectId, isNull);
  });
}
