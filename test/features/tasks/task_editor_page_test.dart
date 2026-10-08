import 'package:drift/native.dart';

import 'dart:ui' show Tristate;

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
    expect(await service.findById('new-task'), isNull);

    // M3（路线图 §7）：最短/最长片段、期望时段现在归入「更多设置」，默认收起。
    // 因此要先展开再断言，不能像以前那样直接读——这个变化本身就是本里程碑的产物。
    await tester.tap(find.byKey(const Key('task-more-options')));
    await tester.pumpAndSettle();
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
    await tester.enterText(
      find.byKey(const Key('task-preferred-window')),
      '09:00-12:00',
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('task-title')), '一次做完实验');
    await tester.enterText(
      find.byKey(const Key('task-estimated-minutes')),
      '95',
    );
    await tester.ensureVisible(find.byKey(const Key('task-split-mode')));
    await tester.tap(find.byKey(const Key('task-split-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('必须连续').last);
    await tester.pumpAndSettle();
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

    // 只数**最早开始字段自己**的文本：M3 之后底栏的约束摘要也会写出同一个时间，
    // 全页 `textContaining` 会命中两处（这正是"摘要确实在写关键约束"的副作用）。
    expect(
      find.descendant(
        of: find.byKey(const Key('task-available-from')),
        matching: find.textContaining('2026-10-06 09:15'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('save-task')));
    await tester.pumpAndSettle();
    expect(
      (await repository.getById('existing-task'))!.availableFromUtc,
      available,
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // M3（路线图 §7）信息层级与操作距离。规格见
  // `docs/superpowers/specs/2026-10-07-m3-task-editor-hierarchy.md`。
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('M3 首屏七个字段无需展开「更多设置」即可见，其余字段默认收起', (tester) async {
    final harness = await _pumpEditor(tester);

    // §7「表单结构」首屏固定显示这七项。
    for (final key in _firstScreenKeys) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '「$key」属于首屏固定字段，不应要求展开「更多设置」',
      );
    }

    // §7 把优先级、精力、片段长度、期望时段、备注归入「更多设置」。
    // **注意**：这里断言的是"收起状态下不存在"，而不是"不可见"——`ExpansionTile`
    // 收起时不构建子树，用 `findsNothing` 才能钉住这一点；若哪天有人改成
    // `Visibility(maintainState: true)`，子树会留在树里，这些断言会立刻变红。
    for (final key in _moreOptionsKeys) {
      expect(
        find.byKey(Key(key)),
        findsNothing,
        reason: '「$key」应藏在「更多设置」里，默认收起时不应出现在树中',
      );
    }

    // 展开后全部可见。
    // **必须先滚动到它**：「更多设置」是滚动区的最后一块，在 1280×720 下中心落在 y≈1361，
    // 直接 `tap` 会打在视口外（`tap` 会警告"would not hit test"并静默什么都不做，
    // 于是下面的断言会报"控件不存在"——一个很像产品缺陷的假象）。
    await tester.ensureVisible(find.byKey(const Key('task-more-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-more-options')));
    await tester.pumpAndSettle();
    for (final key in _moreOptionsKeys) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '展开「更多设置」后「$key」应当可见',
      );
    }
    // 首屏字段在展开前后都在（展开不应把它们挪走）。
    for (final key in _firstScreenKeys) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '首屏字段「$key」不应因展开而消失',
      );
    }
    harness.dispose();
  });

  testWidgets('M3 保存按钮位于固定底栏、不在滚动区内，并显示缺失字段与约束摘要', (tester) async {
    final harness = await _pumpEditor(tester);

    // §7「保存区使用固定底栏」：按钮必须**不在**任何滚动视图的后代里，
    // 否则用户滚到别处时就看不到它了。
    expect(
      find.ancestor(
        of: find.byKey(const Key('save-task')),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
      reason: '保存按钮必须在固定底栏里，不能随内容滚动',
    );
    expect(find.byKey(const Key('task-save-bar')), findsOneWidget);

    // §7 底栏同时显示"缺失字段"：标题为空是新建时的初始状态。
    expect(find.byKey(const Key('task-missing-fields')), findsOneWidget);
    expect(find.textContaining('标题'), findsWidgets);
    // 与 M2 一致：缺失提示要能被动播报，不能只靠红色。
    // 用 `flagsCollection` 而不是已弃用的 `hasFlag`；`isLiveRegion` 是普通 bool。
    expect(
      tester
          .getSemantics(find.byKey(const Key('task-missing-fields')))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
      reason: '缺失字段提示必须进 live region，屏幕阅读器才会主动念',
    );

    // 填上标题后缺失提示消失。
    await tester.enterText(find.byKey(const Key('task-title')), '写实验报告');
    await tester.pumpAndSettle();

    // §7 底栏同时显示"当前关键约束摘要"。
    final summary = find.byKey(const Key('task-constraint-summary'));
    expect(summary, findsOneWidget);
    final summaryText = tester.widget<Text>(summary);
    expect(
      summaryText.data,
      anyOf(contains('可拆分'), contains('必须连续')),
      reason: '约束摘要应当写出当前的拆分方式',
    );
    harness.dispose();
  });

  testWidgets('M3 领域切换清空不匹配的项目时给出明确说明', (tester) async {
    // 视口尺寸与上面那条同类用例保持一致（700×1800）。这条测试要钉子的是**清空与说明**
    // 这条规则，不是布局；视口一紧，两次下拉展开就会互相干扰，把问题变成装置问题。
    final harness = await _makeEditorHarness(tester);
    final workspace = harness.workspace;
    final study = (await workspace.listAreas()).firstWhere(
      (area) => area.name == '学业',
    );
    // 「工作」由 `ensureDefaultAreas()` 建好；这里不再重复创建，否则会出现两个同名选项，
    // `find.text('工作').last` 点到哪一个就成了不确定的事。
    final work = (await workspace.listAreas()).firstWhere(
      (area) => area.name == '工作',
    );
    // **项目必须在 pump 之前建好**：`TaskEditorPage` 只在 `initState` 里加载一次项目列表，
    // pump 之后再 `createProject` 不会反映到下拉里，于是 `find.text('算法课')` 找不到候选，
    // 报一个很像产品缺陷的 "Bad state: No element"。
    final studyProject = await workspace.createProject(
      name: '算法课',
      areaId: study.id,
    );
    expect(work.id, isNot(study.id));

    await harness.pumpPage(tester, physicalSize: const Size(700, 1800));

    // 先选中学业下的项目。
    await tester.tap(find.byKey(const Key('task-project')));
    await tester.pumpAndSettle();
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

    // 切到「工作」——算法课不属于它，因此项目必须被清空，而且**要说出来**。
    // §7：「切换领域后，如果原项目不属于新领域，清空项目并给出明确说明。」
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
      reason: '原项目不属于新领域时必须清空',
    );
    expect(
      find.byKey(const Key('task-project-cleared-notice')),
      findsOneWidget,
      reason: '清空项目必须给出明确说明，不能静默丢掉用户的选择',
    );
    expect(find.textContaining('算法课'), findsWidgets);
    harness.dispose();
  });

  testWidgets('M3 保存按钮在 100% 与 150% 缩放下都可见且在视口内', (tester) async {
    // §7 退出条件："保存按钮在 100% 和 150% Windows 缩放下始终可见"。
    // 这里用 devicePixelRatio 作**自动化近似**：它能钉住"底栏没被挤出视口"，
    // 但不等价于真实 DPI 感知，因此人工验收仍要在真实 150% 下看一眼。
    //
    // **每条用例重设一次物理尺寸**：`tester.view.physicalSize` 与
    // `devicePixelRatio` 变化后必须重新 pump 才生效，否则逻辑视口还是上一次的值，
    // 断言就会在错误的坐标系里比较（实测会得到"按钮在视口外"的假失败）。
    for (final ratio in <double>[1.0, 1.5]) {
      final logicalHeight = 720 / ratio;
      final harness = await _pumpEditor(
        tester,
        physicalSize: const Size(1280, 720),
        devicePixelRatio: ratio,
      );

      final save = find.byKey(const Key('save-task'));
      expect(save, findsOneWidget, reason: 'devicePixelRatio=$ratio 时保存按钮必须存在');
      final rect = tester.getRect(save);
      expect(
        rect.top >= 0 && rect.bottom <= logicalHeight,
        isTrue,
        reason:
            'devicePixelRatio=$ratio（逻辑高 $logicalHeight）时保存按钮必须落在视口内，'
            '实际 rect=$rect',
      );
      expect(
        tester.getSemantics(save).getSemanticsData().flagsCollection.isEnabled,
        Tristate.isTrue,
        reason: 'devicePixelRatio=$ratio 时保存按钮必须可点',
      );
      harness.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}

/// §7「首屏固定显示」的七个字段 key。
const _firstScreenKeys = <String>[
  'task-title',
  'task-estimated-minutes',
  'task-area',
  'task-project',
  'task-available-from',
  'task-due-at',
  'task-split-mode',
];

/// §7 归入「更多设置」的字段 key。
const _moreOptionsKeys = <String>[
  'task-editor-priority',
  'task-energy-level',
  'task-min-chunk',
  'task-max-chunk',
  'task-preferred-window',
  'task-notes',
];

/// 起一个最小可用的编辑器，供 M3 的层级测试复用。
///
/// 返回的 `workspace` 让调用方自己建领域/项目；`dispose` 交给调用方，
/// 因为 `tester.view` 的清理要和每个测试自己的节奏对齐。
Future<({WorkspaceService workspace, void Function() dispose})> _pumpEditor(
  WidgetTester tester, {
  Size physicalSize = const Size(1280, 720),
  double devicePixelRatio = 1,
}) async {
  final harness = await _makeEditorHarness(tester);
  await harness.pumpPage(
    tester,
    physicalSize: physicalSize,
    devicePixelRatio: devicePixelRatio,
  );
  return (workspace: harness.workspace, dispose: harness.dispose);
}

/// 建好编辑器需要的一切（数据库、领域、项目），但**先不 pump**。
///
/// **为什么要拆成两步**：`TaskEditorPage` 只在 `initState` 里加载一次项目列表，
/// 因此"先建项目、再 pump"才能让下拉里出现新项目。早先把两件事合在 `_pumpEditor` 里，
/// 于是"先 pump 再 `createProject`"的用例永远看不到候选，报出的
/// `Bad state: No element` 看起来像产品缺陷，其实是装置时序问题。
Future<
  ({
    WorkspaceService workspace,
    Future<void> Function(
      WidgetTester tester, {
      Size physicalSize,
      double devicePixelRatio,
    })
    pumpPage,
    void Function() dispose,
  })
>
_makeEditorHarness(WidgetTester tester) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  final workspaceRepository = DriftWorkspaceRepository(database);
  final workspace = WorkspaceService(
    repository: workspaceRepository,
    clock: _Clock(),
    idGenerator: _AreaIds(),
  );
  await workspace.ensureDefaultAreas();
  final service = TaskService(
    repository: DriftTaskRepository(database.taskDao),
    workspace: workspaceRepository,
    clock: _Clock(),
    idGenerator: _Ids(),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    Size physicalSize = const Size(1280, 720),
    double devicePixelRatio = 1,
  }) async {
    // **参数化尺寸**：缩放那条用例要自己指定 DPR。早先这里写死 1，
    // 于是用例设的 1.5 被它覆盖，断言在错误的坐标系里比较，报出"按钮在视口外"的假失败。
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.reset);
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
  }

  return (workspace: workspace, pumpPage: pumpPage, dispose: () {});
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
