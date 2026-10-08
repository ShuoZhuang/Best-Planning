// M6（路线图 §11 Task 7 Step 2）：周期目标编辑器的**默认值**与**领域/项目依赖**。
//
// 这个文件钉住三件在纯逻辑测试里测不到的事：
//   1. 默认值就是路线图写的三条——周一至周日、均匀分布、不结转；
//   2. 领域先于项目，且项目按领域过滤（§7"项目必须属于所选领域"在界面上的唯一落点）；
//   3. 保存把界面上看到的东西**逐字段**写进模板（而不是"看起来保存了"）。
//
// 用真实的 `RecurringTaskService` + 内存 Drift 库：模板要真的落库才能断言"保存了什么"，
// 而一个内存假仓储会让"字段漏传"这类缺陷看起来通过。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_editor_page.dart';

final _now = DateTime.utc(2026, 10, 7, 4); // 本地 2026-10-07（周三）

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _MemoryWorkspace implements WorkspaceRepository {
  _MemoryWorkspace({List<PlannerArea>? areas, List<PlannerProject>? projects})
    : areas = areas ?? const [],
      projects = projects ?? const [];

  final List<PlannerArea> areas;
  final List<PlannerProject> projects;

  @override
  Future<List<PlannerArea>> listAreas() async =>
      [...areas]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  @override
  Future<List<PlannerProject>> listProjects() async => projects;

  @override
  Future<void> saveArea(PlannerArea area) async => areas.add(area);

  @override
  Future<void> saveProject(PlannerProject project) async =>
      projects.add(project);
}

PlannerArea _area(String id, String name, int order) => PlannerArea(
  id: id,
  name: name,
  color: 0,
  sortOrder: order,
  isLife: false,
  createdAtUtc: _now,
  updatedAtUtc: _now,
);

PlannerProject _project(String id, String areaId, String name) =>
    PlannerProject(
      id: id,
      areaId: areaId,
      name: name,
      createdAtUtc: _now,
      updatedAtUtc: _now,
    );

void main() {
  late db.AppDatabase database;
  late RecurringTaskService service;
  late WorkspaceService workspace;

  /// 点"保存"并等待。
  ///
  /// `ensureVisible` 是必须的：保存栏固定在底部，而 150%/200% 缩放下表单会把
  /// **新填的那个字段**推到当前视口之外，`tap` 因此落在窗口外面（实测：Flutter 报
  /// "The finder ... derived an Offset that would not hit test on the specified widget"，
  /// 而点击被静默丢弃——断言保存回调解雇就会失败，且失败原因看起来像是"保存没生效"）。
  Future<void> tapSave(WidgetTester tester) async {
    final finder = find.byKey(const Key('save-recurring'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  setUp(() {
    // **外键在这里被刻意关掉**：本文件注入的是内存里的假工作区（领域 'area-study' 等），
    // 而模板的 `area_id` 是指向真 `areas` 表的外键。开着它，"选了一个领域"这条正常路径
    // 会以 `FOREIGN KEY constraint failed` 失败，看起来像"保存坏了"——实际只是领域没有
    // 写进真库。外键本身由 `test/data/recurring_task_dao_test.dart` 与
    // `schema_migration_test.dart` 在真库上守着，两边分工明确。
    database = db.AppDatabase.forTesting(
      NativeDatabase.memory(),
      enforceForeignKeys: false,
    );
    service = RecurringTaskService(
      repository: DriftRecurringTaskRepository(
        database,
        RecurringTaskDao(database),
      ),
      clock: const _Clock(),
      idGenerator: UuidIdGenerator(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: DriftTaskRepository(database.taskDao),
    );
    workspace = WorkspaceService(
      repository: _MemoryWorkspace(
        areas: [_area('area-study', '学业', 0), _area('area-life', '生活', 1)],
        projects: [
          _project('proj-algo', 'area-study', '算法课'),
          _project('proj-gym', 'area-life', '健身'),
        ],
      ),
      clock: const _Clock(),
      idGenerator: const _Ids(),
    );
  });

  tearDown(() => database.close());

  Future<RecurringTaskTemplate?> pump(
    WidgetTester tester, {
    String? templateId,
    List<RecurringTaskTemplate> saved = const [],
  }) async {
    RecurringTaskTemplate? result;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringTaskEditorPage(
            service: service,
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: _now,
            templateId: templateId,
            onSaved: (template) => result = template,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('新建时的默认值：均匀分布、不结转、允许周一至周日', (tester) async {
    await pump(tester);

    // 目标分钟预填一个可用的值，用户不必先猜一个数字。
    expect(
      (tester.widget<TextField>(
        find.byKey(const Key('recurring-target-minutes')),
      )).controller!.text,
      '180',
    );
    // 节奏默认"均匀分布（默认）"。
    expect(find.text('均匀分布（默认）'), findsOneWidget);
    // 不结转的开关默认关，并且**写明默认口径**。
    final carry = tester.widget<SwitchListTile>(
      find.byKey(const Key('recurring-carry-over')),
    );
    expect(carry.value, isFalse);
    expect(find.textContaining('默认关闭'), findsOneWidget);
    // 允许星期只在"仅指定星期"时出现——默认节奏下它是隐藏的。
    expect(find.byKey(const Key('recurring-weekdays')), findsNothing);
  });

  testWidgets('切到"仅指定星期"才出现星期选择，且默认七天全选', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('recurring-pace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅指定星期').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recurring-weekdays')), findsOneWidget);
    for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++) {
      final chip = tester.widget<FilterChip>(
        find.byKey(Key('recurring-weekday-$weekday')),
      );
      expect(chip.selected, isTrue, reason: '默认周一至周日全选');
    }
  });

  testWidgets('领域先于项目出现，且项目按领域过滤', (tester) async {
    await pump(tester);

    final areaField = find.byKey(const Key('recurring-area'));
    final projectField = find.byKey(
      const ValueKey('recurring-project-area-study-null'),
    );
    expect(areaField, findsOneWidget);
    expect(projectField, findsOneWidget);
    // 领域在项目上方：这是"先领域、再项目"的视觉顺序。
    expect(
      tester.getTopLeft(areaField).dy,
      lessThan(tester.getTopLeft(projectField).dy),
    );

    // 默认选中第一个领域（学业），因此项目列表只有该领域的项目。
    await tester.tap(projectField);
    await tester.pumpAndSettle();
    expect(find.text('算法课'), findsWidgets);
    expect(find.text('健身'), findsNothing);
    await tester.tap(find.text('不归属项目').last);
    await tester.pumpAndSettle();
  });

  testWidgets('换领域后项目列表随之改变，且旧选择被清空', (tester) async {
    await pump(tester);

    // 先选一个学业项目。
    await tester.tap(
      find.byKey(const ValueKey('recurring-project-area-study-null')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('算法课').last);
    await tester.pumpAndSettle();

    // 换到生活领域。
    await tester.tap(find.byKey(const Key('recurring-area')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生活').last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('recurring-project-area-life-null')),
    );
    await tester.pumpAndSettle();
    expect(find.text('健身'), findsWidgets);
    expect(find.text('算法课'), findsNothing);
    await tester.tap(find.text('不归属项目').last);
    await tester.pumpAndSettle();
  });

  testWidgets('保存把界面上看到的东西逐字段写进模板', (tester) async {
    RecurringTaskTemplate? saved;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringTaskEditorPage(
            service: service,
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: _now,
            onSaved: (template) => saved = template,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('recurring-title')), '每周英语');
    await tester.enterText(
      find.byKey(const Key('recurring-target-minutes')),
      '240',
    );
    await tester.enterText(
      find.byKey(const Key('recurring-preferred-window')),
      '20:00-22:00',
    );
    await tester.ensureVisible(find.byKey(const Key('recurring-carry-over')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('recurring-carry-over')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tapSave(tester);

    expect(saved, isNotNull, reason: _formErrorText(tester));
    final stored = await service.repository.findTemplate(saved!.id);
    expect(stored, isNotNull, reason: '保存必须真的落库，而不只是回调一次');
    expect(stored!.title, '每周英语');
    expect(stored.targetMinutes, 240);
    expect(stored.carryOverUnfinished, isTrue);
    expect(stored.pace, RecurringPace.even);
    expect(stored.allowedWeekdaysMask, recurringAllWeekdaysMask);
    expect(stored.preferredWindow?.startMinute, 20 * 60);
    expect(stored.preferredWindow?.endMinute, 22 * 60);
    expect(stored.areaId, 'area-study');
    // 起始日默认是**本周一**（本地），不是"今天"——周期以整周为单位。
    expect(stored.startsOnLocalDate, DateTime(2026, 10, 5));
  });

  testWidgets('目标为 0 时拒绝保存并给出可读的错误', (tester) async {
    var savedCount = 0;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringTaskEditorPage(
            service: service,
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: _now,
            onSaved: (_) => savedCount++,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('recurring-title')), '每周英语');
    await tester.enterText(
      find.byKey(const Key('recurring-target-minutes')),
      '0',
    );
    await tapSave(tester);

    expect(savedCount, 0, reason: '非法目标不能落库');
    expect(find.textContaining('每周目标必须大于 0'), findsOneWidget);
    expect(await service.repository.listTemplates(), isEmpty);
  });

  testWidgets('期望时段格式错误时给出可读提示，且不落库', (tester) async {
    var savedCount = 0;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringTaskEditorPage(
            service: service,
            workspace: workspace,
            zones: TimeZoneDatabase(),
            timeZoneId: 'Asia/Shanghai',
            nowUtc: _now,
            onSaved: (_) => savedCount++,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('recurring-title')), '每周英语');
    await tester.enterText(
      find.byKey(const Key('recurring-preferred-window')),
      '晚上八点',
    );
    await tapSave(tester);

    expect(savedCount, 0);
    expect(find.textContaining('09:00-12:00'), findsOneWidget);
  });

  testWidgets('编辑已有模板时预填它的值', (tester) async {
    final created = await service.createTemplate(
      title: '每周跑步',
      targetMinutes: 90,
      carryOverUnfinished: true,
      pace: RecurringPace.early,
      minChunkMinutes: 30,
      maxChunkMinutes: 45,
      nowUtc: _now,
    );
    await pump(tester, templateId: created.id);

    expect(
      (tester.widget<TextField>(find.byKey(const Key('recurring-title'))))
          .controller!
          .text,
      '每周跑步',
    );
    expect(
      (tester.widget<TextField>(
        find.byKey(const Key('recurring-target-minutes')),
      )).controller!.text,
      '90',
    );
    expect(
      (tester.widget<SwitchListTile>(
        find.byKey(const Key('recurring-carry-over')),
      )).value,
      isTrue,
    );
    // 标题栏也要说明这是编辑而不是新建。
    expect(find.text('编辑周期目标'), findsOneWidget);
  });

  testWidgets('150% 与 200% 文字缩放下表单与保存栏都在，且能完成保存', (tester) async {
    for (final scale in const [1.5, 2.0]) {
      var savedCount = 0;
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: RecurringTaskEditorPage(
                service: service,
                workspace: workspace,
                zones: TimeZoneDatabase(),
                timeZoneId: 'Asia/Shanghai',
                nowUtc: _now,
                onSaved: (_) => savedCount++,
                onCancel: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '$scale 倍缩放下不应有布局异常');
      // 保存栏固定在底部，缩放下仍然可见（与任务编辑器同一条验收要求）。
      expect(find.byKey(const Key('recurring-save-bar')), findsOneWidget);
      expect(find.byKey(const Key('save-recurring')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('recurring-title')),
        '缩放下标-$scale',
      );
      await tapSave(tester);
      expect(savedCount, 1, reason: '$scale 倍缩放下必须能保存');
    }
  });
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id-${DateTime.now().microsecondsSinceEpoch}';
}

/// 保存失败时把**界面上能读到的全部错误文本**拼成一句原因，供断言使用。
String _formErrorText(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(find.byType(Text)))
    if (text.data != null && text.data!.isNotEmpty) text.data!,
].join(' | ');
