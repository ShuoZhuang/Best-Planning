// R2 的界面入口：在任务详情页把任务归属到项目。
//
// 这是任务通向领域的唯一路径，因此这个控件是"生活配额与统计『生活』分类能否生效"的
// 最后一环——其下每一层（schema、默认领域、三表推导、评分因子、归属服务）都已完成，
// 但在此之前没有任何界面能触发它。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';

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

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);
  final Map<String, PlannerTask> tasks;

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield tasks.values.toList();
  }
}

final class _Workspace implements WorkspaceRepository {
  _Workspace({required this.areas, required this.projects});

  final List<PlannerArea> areas;
  final List<PlannerProject> projects;

  @override
  Future<List<PlannerArea>> listAreas() async => areas;

  @override
  Future<List<PlannerProject>> listProjects() async => projects;

  @override
  Future<void> saveArea(PlannerArea area) async {}

  @override
  Future<void> saveProject(PlannerProject project) async =>
      projects.add(project);
}

PlannerArea _area(String id, String name, {bool isLife = false}) => PlannerArea(
  id: id,
  name: name,
  color: 0,
  sortOrder: 0,
  isLife: isLife,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

PlannerTask _task() => PlannerTask(
  id: 'task-1',
  areaId: 'area-life',
  title: '跑步',
  priority: TaskPriority.medium,
  estimatedMinutes: 60,
  remainingMinutes: 60,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

PlannerProject _project(String id, String name, {DateTime? archivedAtUtc}) =>
    PlannerProject(
      id: id,
      areaId: 'area-life',
      name: name,
      archivedAtUtc: archivedAtUtc,
      createdAtUtc: DateTime.utc(2026, 10, 1),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

void main() {
  late _Tasks tasks;
  late WorkspaceService workspace;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({'task-1': _task()});
    final workspaceRepository = _Workspace(
      areas: [_area('area-life', '生活', isLife: true)],
      projects: [
        _project('project-life', '健身'),
        _project(
          'project-old',
          '已归档项目',
          archivedAtUtc: DateTime.utc(2026, 10, 2),
        ),
      ],
    );
    workspace = WorkspaceService(
      repository: workspaceRepository,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
    service = TaskService(
      repository: tasks,
      workspace: workspaceRepository,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    WorkspaceService? withWorkspace,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: service,
            workspace: withWorkspace ?? workspace,
            taskId: 'task-1',
            nowUtc: _now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openProjectPicker(WidgetTester tester) async {
    final picker = find.byType(DropdownButton<String?>);
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
  }

  testWidgets('把任务归属到项目后立即写入，并说明由此生效的后果', (tester) async {
    await pump(tester);

    expect(find.text('归属项目'), findsOneWidget);
    // 未归属时列表里只有"不归属项目"。
    expect(find.text('健身'), findsNothing);

    await openProjectPicker(tester);
    await tester.tap(find.text('健身').last);
    await tester.pumpAndSettle();

    expect(tasks.tasks['task-1']!.projectId, 'project-life');
    expect(find.text('已归属到该项目，领域与生活标记随之生效'), findsOneWidget);
  });

  testWidgets('取消归属会清空项目，且不影响剩余时长', (tester) async {
    tasks.tasks['task-1'] = _task().copyWith(projectId: 'project-life');
    await pump(tester);

    await openProjectPicker(tester);
    await tester.tap(find.text('不归属项目').last);
    await tester.pumpAndSettle();

    final saved = tasks.tasks['task-1']!;
    expect(saved.projectId, isNull);
    expect(saved.remainingMinutes, 60);
    expect(find.text('已取消项目归属'), findsOneWidget);
  });

  testWidgets('可以直接新建项目并归属，无需先有项目', (tester) async {
    // 复现全新安装：默认初始化只建领域、不建任何项目，因此选择器里只有"不归属项目"。
    final fresh = WorkspaceService(
      repository: _Workspace(
        areas: [_area('area-life', '生活', isLife: true)],
        projects: [],
      ),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
    await pump(tester, withWorkspace: fresh);

    // 空列表必须说明原因，否则会被当成功能失效。
    expect(find.textContaining('尚无项目'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('new-project-name')), '读书');
    // 这一页会随功能增长而变长（本轮就新增了优先级控件），因此点击前先滚动到可见位置，
    // 而不是假设它在默认视口内——否则排布一变，点击会**静默失效**，表现为"功能坏了"。
    await tester.ensureVisible(find.text('新建并归属'));
    await tester.tap(find.text('新建并归属'));
    await tester.pumpAndSettle();

    final created = (await fresh.listProjects()).firstWhere(
      (item) => item.name == '读书',
    );
    expect(created.areaId, 'area-life');
    expect(tasks.tasks['task-1']!.projectId, created.id);
    expect(find.textContaining('已新建项目"读书"并归属'), findsOneWidget);
  });

  testWidgets('项目名为空时拒绝提交并说明原因', (tester) async {
    await pump(tester);

    // 这一页会随功能增长而变长（本轮就新增了优先级控件），因此点击前先滚动到可见位置，
    // 而不是假设它在默认视口内——否则排布一变，点击会**静默失效**，表现为"功能坏了"。
    await tester.ensureVisible(find.text('新建并归属'));
    await tester.tap(find.text('新建并归属'));
    await tester.pumpAndSettle();

    expect(find.text('请填写项目名称'), findsOneWidget);
    expect(tasks.tasks['task-1']!.projectId, isNull);
  });

  testWidgets('已归档项目不出现在可选项中', (tester) async {
    await pump(tester);

    await openProjectPicker(tester);

    // 归档表示"不再往里放新任务"，因此可选列表里没有它。
    expect(find.text('健身'), findsOneWidget);
    expect(find.text('已归档项目'), findsNothing);
  });
}
