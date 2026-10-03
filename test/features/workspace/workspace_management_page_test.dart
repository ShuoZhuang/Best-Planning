// R2 的界面入口：领域与项目的管理（新建、改名、标记生活、归档）。
//
// 这些操作此前只有服务层与仓库，用户改不了名字、标记不了生活、也归档不了项目。
// 第二个用例不看"页面上有没有这个开关"，而是从界面点下去，再经真实数据库与真实读取端
// 确认生活标记真的生效——也就是把这条链路从"有服务入口"推到"需求兑现"：
// 生活配额与统计的「生活」分类，其数据来源正是这里。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/workspace/workspace_management_page.dart';

final _now = DateTime.utc(2026, 10, 5, 2);
final _created = DateTime.utc(2026, 10, 1);

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

/// 与 drift 仓库同语义的内存实现：`save` 是 upsert，改名与归档会真的覆盖旧值。
/// 只往列表里 append 的假仓库会让"改名"看起来成功、实际什么也没改。
final class _MemoryWorkspace implements WorkspaceRepository {
  _MemoryWorkspace({
    List<PlannerArea> areas = const [],
    List<PlannerProject> projects = const [],
  }) : _areas = [...areas],
       _projects = [...projects];

  final List<PlannerArea> _areas;
  final List<PlannerProject> _projects;

  @override
  Future<List<PlannerArea>> listAreas() async => List.of(_areas);

  @override
  Future<List<PlannerProject>> listProjects() async => List.of(_projects);

  @override
  Future<void> saveArea(PlannerArea area) async {
    final index = _areas.indexWhere((item) => item.id == area.id);
    if (index == -1) {
      _areas.add(area);
    } else {
      _areas[index] = area;
    }
  }

  @override
  Future<void> saveProject(PlannerProject project) async {
    final index = _projects.indexWhere((item) => item.id == project.id);
    if (index == -1) {
      _projects.add(project);
    } else {
      _projects[index] = project;
    }
  }
}

PlannerArea _area(
  String id,
  String name, {
  bool isLife = false,
  int sortOrder = 0,
}) => PlannerArea(
  id: id,
  name: name,
  color: 0,
  sortOrder: sortOrder,
  isLife: isLife,
  createdAtUtc: _created,
  updatedAtUtc: _created,
);

PlannerProject _project(String id, String areaId, String name) => PlannerProject(
  id: id,
  areaId: areaId,
  name: name,
  createdAtUtc: _created,
  updatedAtUtc: _created,
);

void main() {
  late WorkspaceService service;

  setUp(() {
    service = WorkspaceService(
      repository: _MemoryWorkspace(
        areas: [
          _area('area-study', '学业'),
          _area('area-life', '生活', isLife: true, sortOrder: 1),
        ],
        projects: [_project('project-1', 'area-study', '论文')],
      ),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  Future<void> pump(WidgetTester tester, {WorkspaceService? withService}) async {
    // 页面比默认的 800x600 测试视口高得多。`ListView` 只给已经布局的子项建立 element，
    // 因此视口外的控件连"找到"都做不到（`ensureVisible` 会报 Bad state: No element），
    // 更不用说点击。这里给一个足够高的视口，让整页都在布局范围内；`tapKey` 仍然保留
    // ensureVisible，以防将来页面再长高。
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceManagementPage(workspace: withService ?? service),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  String nameOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  testWidgets('领域改名写回存储，且只推进修改时间', (tester) async {
    await pump(tester);
    expect(nameOf(tester, 'area-name-area-study'), '学业');

    await tapKey(tester, 'area-rename-area-study');
    await tester.enterText(find.byKey(const Key('rename-field')), '本科课程');
    await tapKey(tester, 'rename-confirm');

    final renamed = (await service.listAreas()).firstWhere(
      (area) => area.id == 'area-study',
    );
    expect(renamed.name, '本科课程');
    // FR-DATA-08：改名只推进修改时间，创建时间保持不变。
    expect(renamed.createdAtUtc, _created);
    expect(renamed.updatedAtUtc, _now);
    // 按 `Key` 断言而不是按文本：同一个名字在页面上本来就出现多处（领域行、
    // 项目行显示的所属领域、新建项目的下拉项），按文本会让"改对了"看起来像失败。
    expect(nameOf(tester, 'area-name-area-study'), '本科课程');
  });

  testWidgets('从界面标记生活后，该领域下的任务立刻被读取端算作生活任务', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final real = WorkspaceService(
      repository: DriftWorkspaceRepository(database),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
    final area = await real.createArea('副业');
    final project = await real.createProject(name: '写作', areaId: area.id);
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-1',
            title: '写稿',
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
            projectId: Value(project.id),
          ),
        );
    final lookup = DriftLifeAreaLookup(database);
    expect(await lookup.lifeTaskIds(), isEmpty);

    await pump(tester, withService: real);
    // 有领域但一个都没标记生活时，界面必须说明后果，而不是留一片空白。
    expect(find.byKey(const Key('no-life-area-warning')), findsOneWidget);

    await tapKey(tester, 'area-life-${area.id}');

    expect(await lookup.lifeTaskIds(), {'task-1'});
    expect(find.byKey(const Key('no-life-area-warning')), findsNothing);
  });

  testWidgets('归档是可逆状态而不是删除', (tester) async {
    await pump(tester);

    await tapKey(tester, 'project-archive-project-1');
    expect((await service.listProjects()).single.isArchived, isTrue);
    expect(find.textContaining('已归档'), findsWidgets);

    // 往返：取消归档后项目仍在，且不再标记为已归档。
    await tapKey(tester, 'project-archive-project-1');
    final projects = await service.listProjects();
    expect(projects, hasLength(1));
    expect(projects.single.isArchived, isFalse);
  });

  testWidgets('新建领域可以同时标记为生活', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const Key('new-area-name')), '健身');
    await tapKey(tester, 'new-area-is-life');
    await tapKey(tester, 'create-area');

    final created = (await service.listAreas()).firstWhere(
      (area) => area.name == '健身',
    );
    expect(created.isLife, isTrue);
    expect(nameOf(tester, 'area-name-${created.id}'), '健身');
  });

  testWidgets('新建项目挂到所选领域下', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const Key('new-project-name')), '读书');
    await tapKey(tester, 'create-project');

    final created = (await service.listProjects()).firstWhere(
      (project) => project.name == '读书',
    );
    // 未改动选择时默认挂在第一个领域下。
    expect(created.areaId, 'area-study');
    expect(nameOf(tester, 'project-name-${created.id}'), '读书');
  });

  testWidgets('空名称被拒绝且不写入', (tester) async {
    await pump(tester);

    await tapKey(tester, 'create-area');

    expect(find.text('领域名称不能为空。'), findsOneWidget);
    expect(await service.listAreas(), hasLength(2));
  });

  testWidgets('没有任何领域时不给新建项目的入口，并说明原因', (tester) async {
    final empty = WorkspaceService(
      repository: _MemoryWorkspace(),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
    await pump(tester, withService: empty);

    expect(find.text('尚无领域。'), findsOneWidget);
    expect(find.text('项目必须挂在领域下：请先建立一个领域。'), findsOneWidget);
    expect(find.byKey(const Key('create-project')), findsNothing);
  });
}
