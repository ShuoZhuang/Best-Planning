import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/tasks/task_editor_page.dart';

void main() {
  testWidgets('新建显示个人默认值，修改后一次保存连续任务并进入待安排', (tester) async {
    tester.view.physicalSize = const Size(1100, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final settings = SettingsService(repository: MemorySettingsRepository());
    await settings.saveUserRules(
      const UserPlanningRules(
        common: PlanningRulesPatch(
          defaultFocusMinutes: 55,
          minChunkMinutes: 20,
          maxChunkMinutes: 65,
        ),
      ),
    );
    var changes = 0;
    final workspaceRepository = DriftWorkspaceRepository(database);
    final workspace = WorkspaceService(
      repository: workspaceRepository,
      clock: _Clock(),
      idGenerator: _AreaIds(),
    );
    await workspace.ensureDefaultAreas();
    final studyArea = (await workspace.listAreas()).firstWhere(
      (area) => area.name == '学业',
    );
    final service = TaskService(
      repository: DriftTaskRepository(database.taskDao),
      workspace: workspaceRepository,
      clock: _Clock(),
      idGenerator: _Ids(),
      onScheduleInputChanged: (_) => changes++,
    );
    PlannerTask? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskEditorPage(
            service: service,
            settings: settings,
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: DateTime.utc(2026, 10, 5),
            onSaved: (task) => saved = task,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-area')), findsOneWidget);
    expect(find.byKey(const Key('task-project')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('task-area'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('task-project'))).dy),
    );
    expect(
      tester
          .state<FormFieldState<String>>(find.byKey(const Key('task-area')))
          .value,
      studyArea.id,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('task-estimated-minutes')))
          .controller!
          .text,
      '55',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('task-min-chunk')))
          .controller!
          .text,
      '20',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('task-max-chunk')))
          .controller!
          .text,
      '65',
    );
    expect(await service.findById('new-task'), isNull);
    await tester.enterText(find.byKey(const Key('task-title')), '一次做完实验');
    await tester.enterText(
      find.byKey(const Key('task-estimated-minutes')),
      '95',
    );
    await tester.enterText(
      find.byKey(const Key('task-preferred-window')),
      '09:00-12:00',
    );
    await tester.ensureVisible(find.byKey(const Key('task-split-mode')));
    await tester.tap(find.byKey(const Key('task-split-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('必须连续').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-task')));
    await tester.tap(find.byKey(const Key('save-task')));
    await tester.pumpAndSettle();
    final persisted = await service.findById('new-task');
    expect(saved?.id, 'new-task');
    expect(persisted?.status, TaskStatus.open);
    expect(persisted?.areaId, studyArea.id);
    expect(persisted?.splitMode, TaskSplitMode.continuous);
    expect(persisted?.minChunkMinutes, 95);
    expect(persisted?.maxChunkMinutes, 95);
    expect(persisted?.preferredWindow?.startMinute, 540);
    expect(persisted?.preferredWindow?.endMinute, 720);
    expect(changes, 1);
    final edited = await service.updateDraft(
      'new-task',
      TaskDraft(
        title: '修改后的实验',
        estimatedMinutes: 95,
        areaId: studyArea.id,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 20,
        maxChunkMinutes: 40,
      ),
    );
    expect(edited.isSuccess, isTrue);
    expect(
      (await service.findById('new-task'))?.splitMode,
      TaskSplitMode.splittable,
    );
    expect((await service.findById('new-task'))?.maxChunkMinutes, 40);
  });

  testWidgets('项目跟随领域过滤，切换领域清空旧项目，并可在当前领域新建', (tester) async {
    tester.view.physicalSize = const Size(700, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final workspace = WorkspaceService(
      repository: workspaceRepository,
      clock: _Clock(),
      idGenerator: _AreaIds(),
    );
    final study = await workspace.createArea('学业');
    final work = await workspace.createArea('工作');
    final studyProject = await workspace.createProject(
      name: '算法课',
      areaId: study.id,
    );
    await workspace.createProject(name: '学生会', areaId: work.id);
    final service = TaskService(
      repository: DriftTaskRepository(database.taskDao),
      workspace: workspaceRepository,
      clock: _Clock(),
      idGenerator: _Ids(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskEditorPage(
            service: service,
            settings: SettingsService(repository: MemorySettingsRepository()),
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: DateTime.utc(2026, 10, 5),
            onSaved: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('task-project')));
    await tester.pumpAndSettle();
    expect(find.text('算法课'), findsOneWidget);
    expect(find.text('学生会'), findsNothing);
    await tester.tap(find.text('算法课').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .state<FormFieldState<String>>(
            find.descendant(
              of: find.byKey(const Key('task-project')),
              matching: find.byType(DropdownButtonFormField<String>),
            ),
          )
          .value,
      studyProject.id,
    );

    await tester.tap(find.byKey(const Key('task-area')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .state<FormFieldState<String>>(
            find.descendant(
              of: find.byKey(const Key('task-project')),
              matching: find.byType(DropdownButtonFormField<String>),
            ),
          )
          .value,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('task-new-project-name')),
      '实习求职',
    );
    await tester.tap(find.byKey(const Key('task-create-project')));
    await tester.pumpAndSettle();
    final created = (await workspace.listProjects()).firstWhere(
      (project) => project.name == '实习求职',
    );
    expect(created.areaId, work.id);
    expect(
      tester
          .state<FormFieldState<String>>(
            find.descendant(
              of: find.byKey(const Key('task-project')),
              matching: find.byType(DropdownButtonFormField<String>),
            ),
          )
          .value,
      created.id,
    );
  });

  testWidgets('编辑时保留最早开始时间并可再次保存', (tester) async {
    tester.view.physicalSize = const Size(700, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final workspace = WorkspaceService(
      repository: workspaceRepository,
      clock: _Clock(),
      idGenerator: _AreaIds(),
    );
    final area = await workspace.createArea('学业');
    final repository = DriftTaskRepository(database.taskDao);
    final available = DateTime.utc(2026, 10, 6, 1, 15);
    await repository.save(
      PlannerTask(
        id: 'existing-task',
        areaId: area.id,
        title: '复习',
        priority: TaskPriority.medium,
        estimatedMinutes: 60,
        remainingMinutes: 60,
        dueAtUtc: DateTime.utc(2026, 10, 8),
        availableFromUtc: available,
        energyLevel: TaskEnergyLevel.medium,
        splitMode: TaskSplitMode.continuous,
        minChunkMinutes: 60,
        maxChunkMinutes: 60,
        status: TaskStatus.open,
        createdAtUtc: DateTime.utc(2026, 10, 1),
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    );
    final service = TaskService(
      repository: repository,
      workspace: workspaceRepository,
      clock: _Clock(),
      idGenerator: _Ids(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskEditorPage(
            taskId: 'existing-task',
            service: service,
            settings: SettingsService(repository: MemorySettingsRepository()),
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: DateTime.utc(2026, 10, 5),
            onSaved: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('2026-10-06 09:15'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('save-task')));
    await tester.tap(find.byKey(const Key('save-task')));
    await tester.pumpAndSettle();
    expect(
      (await repository.getById('existing-task'))!.availableFromUtc,
      available,
    );
  });
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5);
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'new-task';
}

final class _AreaIds implements IdGenerator {
  var value = 0;

  @override
  String next() => 'area-or-project-${++value}';
}
