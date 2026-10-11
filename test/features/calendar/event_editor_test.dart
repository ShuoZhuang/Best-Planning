import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/features/calendar/event_editor/event_editor_form.dart';

void main() {
  testWidgets('固定日程表单保存一次性事件，并记录调用方给出的时区', (tester) async {
    final repository = _MemoryCalendarRepository();
    final service = CalendarService(
      repository: repository,
      recurringRepository: repository,
      clock: _Clock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: service,
            initialStartUtc: DateTime.utc(2026, 10, 2, 1),
            initialEndUtc: DateTime.utc(2026, 10, 2, 3),
            // 刻意用一个**不是**东八区的值：此前的默认值会让这个表单静默把所有日程
            // 记成 'Asia/Shanghai'，用东八区做断言就抓不到那个缺陷（R11）。
            timeZoneId: 'Europe/Berlin',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('event-title')), '社团会议');
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(repository.saved.single.title, '社团会议');
    expect(repository.saved.single.timeZoneId, 'Europe/Berlin');
    expect(find.text('日程已保存'), findsOneWidget);
  });

  testWidgets('用户可按本地日期和时间修改固定日程时段', (tester) async {
    final repository = _MemoryCalendarRepository();
    final service = CalendarService(
      repository: repository,
      recurringRepository: repository,
      clock: _Clock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: service,
            initialStartUtc: DateTime.utc(2026, 10, 2, 1),
            initialEndUtc: DateTime.utc(2026, 10, 2, 3),
            timeZoneId: 'Europe/Berlin',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('event-title')), '摄影外拍');
    // **1.8.0：日期由选择器给出**（规范 §2.7／§8.1）。此前这里是
    // `enterText(... '2026-10-03')`——那种写法本身就是"要求用户手输格式字符串"这一缺陷的
    // 镜子。现在它不可能编译过，因为字段是只读的按钮。
    await _pickDate(tester, 'event-start-date', 3);
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    // **只断言"日期搬过去了、两端一起搬"**，不断言具体钟点：`Europe/Berlin` 在 10 月是
    // CEST(+02:00)，初始 03:00–05:00 本地 ⇒ 01:00–03:00 UTC。写死钟点会把这条用例变成
    // "测时区换算"（那是引擎的用例），而它要测的是"日期字段确实换了日期"。
    expect(repository.saved.single.startAtUtc.day, 3);
    expect(repository.saved.single.endAtUtc.day, 3);
    expect(
      repository.saved.single.endAtUtc.difference(
        repository.saved.single.startAtUtc,
      ),
      const Duration(hours: 2),
      reason: '只改日期不该改变时长',
    );
  });

  testWidgets('改变钟点后，结束时间按原时长联动（规范 §8.2）', (tester) async {
    final repository = _MemoryCalendarRepository();
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: _service(repository),
            initialStartUtc: DateTime.utc(2026, 10, 2, 1),
            initialEndUtc: DateTime.utc(2026, 10, 2, 3),
            timeZoneId: 'Europe/Berlin',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('event-title')), '摄影外拍');
    // **拖动分钟而不是点小时**：这一版的时间选择器是 12 小时表盘（`上午／下午`），
    // 表盘上没有 `18` 这个数字。拖动指针是**与用户完全一致**的动作，也正因为
    // `PlannerTimeField` 交回的是 `TimeOfDay`，拖动结果会被原样收下。
    await _nudgeStartTime(tester);
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    final saved = repository.saved.single;
    final duration = saved.endAtUtc.difference(saved.startAtUtc);
    expect(
      duration,
      const Duration(hours: 2),
      reason: '规范 §8.2：改开始时间时默认保持原时长——只改钟点绝不该改变时长',
    );
  });

  testWidgets('勾选每周重复后保存星期规则与模板日程', (tester) async {
    final repository = _MemoryCalendarRepository();
    final service = CalendarService(
      repository: repository,
      recurringRepository: repository,
      clock: _Clock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: service,
            initialStartUtc: DateTime.utc(2026, 10, 2, 1),
            initialEndUtc: DateTime.utc(2026, 10, 2, 2, 30),
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('event-title')), '每周课程');
    await tester.tap(find.byKey(const Key('event-weekly')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('event-weekday-1')));
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(repository.rules, hasLength(1));
    expect(
      repository.saved.single.recurrenceRuleId,
      repository.rules.single.id,
    );
    expect(repository.rules.single.weekdays, {
      DateTime.monday,
      DateTime.friday,
    });
    expect(repository.rules.single.localStartMinute, 9 * 60);
    expect(repository.rules.single.durationMinutes, 90);
  });

  testWidgets('周期控件可选择每两周和结束日期', (tester) async {
    final repository = _MemoryCalendarRepository();
    final service = CalendarService(
      repository: repository,
      recurringRepository: repository,
      clock: _Clock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: service,
            initialStartUtc: DateTime.utc(2026, 10, 5, 1),
            initialEndUtc: DateTime.utc(2026, 10, 5, 2),
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('event-title')), '单双周课程');
    await tester.tap(find.byKey(const Key('event-weekly')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('event-recurrence-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每两周').last);
    // 重复结束日期也是选择器（规范 §8.2 最后一条）。
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.rules.single.intervalWeeks, 2);
    // 不设结束日期时它是 `null`，而"不设"本身是**默认状态**：日期字段只能选一个具体
    // 日期，因此清空必须有独立入口（`event-recurrence-end-clear`），这条用例钉住默认值。
    expect(
      repository.rules.single.validUntilLocalDate,
      isNull,
      reason: '没选结束日期时必须原样存成 null，而不是随手补一个日期',
    );
    // **严格说这条用例只覆盖了"每两周"**：重复结束日期现在也是选择器（规范 §8.2），
    // 在它上面选一个具体日期要先翻月份，而那是纯粹的控件操作、与"每两周"无关。
    // 那条路径（选日期 + 清空）由下一条专门用例覆盖。
  });

  testWidgets('重复结束日期可以选一个具体日期，也可以再清掉', (tester) async {
    final repository = _MemoryCalendarRepository();
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: _service(repository),
            initialStartUtc: DateTime.utc(2026, 10, 5, 1),
            initialEndUtc: DateTime.utc(2026, 10, 5, 2),
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('event-title')), '单双周课程');
    await tester.tap(find.byKey(const Key('event-weekly')));
    await tester.pumpAndSettle();

    // 选一个结束日期。
    await tester.tap(find.byKey(const Key('event-recurrence-end-date-box')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('28').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('当前：不设结束日期'), findsNothing, reason: '已经选了日期，就不该还显示"不设"');

    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();
    expect(repository.rules.single.validUntilLocalDate, DateTime(2026, 10, 28));

    // 清掉它，再保存一次：必须回到 `null`。
    await tester.tap(find.byKey(const Key('event-recurrence-end-clear')));
    await tester.pumpAndSettle();
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(
      repository.rules.last.validUntilLocalDate,
      isNull,
      reason: '日期字段只能选具体日期，因此"清空"必须有独立入口',
    );
  });

  testWidgets('固定日程可选所属领域与项目，并写进保存的日程', (tester) async {
    // 此前固定日程表单没有任何"归属"控件，`calendar_events.project_id` 也就没有写入路径：
    // 日程在日历上有颜色、在统计里却没有归属。
    final repository = _MemoryCalendarRepository();
    final workspace = _workspace();
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: _service(repository),
            initialStartUtc: DateTime.utc(2026, 10, 2, 1),
            initialEndUtc: DateTime.utc(2026, 10, 2, 3),
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
            workspace: workspace,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('event-title')), '社团会议');
    await tester.tap(find.byKey(const Key('event-area')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学业').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('event-project')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学建模').last);
    await tester.pumpAndSettle();
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved.single.areaId, 'area-study');
    expect(repository.saved.single.projectId, 'project-math');
  });

  testWidgets('换领域时清掉不属于新领域的项目', (tester) async {
    // 领域与项目必须自洽：留着"科研领域 + 数学建模项目"这种组合会让归属失去意义。
    final repository = _MemoryCalendarRepository();
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: EventEditorForm(
            service: _service(repository),
            initialStartUtc: DateTime.utc(2026, 10, 2, 1),
            initialEndUtc: DateTime.utc(2026, 10, 2, 3),
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
            workspace: _workspace(),
            initialAreaId: 'area-study',
            initialProjectId: 'project-math',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('event-title')), '社团会议');
    await tester.tap(find.byKey(const Key('event-area')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('科研').last);
    await tester.pumpAndSettle();
    // 字段变高之后保存按钮可能落在视口外——先滚到它（用户也是这么做的）。
    await tester.ensureVisible(find.text('保存日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved.single.areaId, 'area-lab');
    expect(
      repository.saved.single.projectId,
      isNull,
      reason: '原项目属于学业，换到科研后必须清掉，而不是留下跨领域的组合',
    );
  });
}

/// 用日期选择器把某个日期字段设成当月的 [day] 号。
///
/// **必须真的走选择器**：1.8.0 起日期字段是 `PlannerDateField`（规范 §8.1），
/// `enterText` 那条路已经不存在——测试若还能"输入日期"，说明实现没换。
Future<void> _pickDate(WidgetTester tester, String key, int day) async {
  await tester.tap(find.byKey(Key('$key-box')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('$day').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

/// 用时间选择器把开始时间往后拨一点（拖动指针）。
///
/// **为什么是"拨"而不是"点小时"**：这一版 Flutter 的时间选择器是 **12 小时表盘**
/// （`上午／下午` + `3 / : / 00`），表盘上没有 `18` 这个数字。拖动指针是**与用户
/// 完全一致**的动作，而且正因为 `PlannerTimeField` 交回的是 `TimeOfDay`，
/// 拖动结果会被原样收下——这条用例要钉的正是"改钟点之后时长不变"。
Future<void> _nudgeStartTime(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('event-start-time-box')));
  await tester.pumpAndSettle();
  final dial = find.byType(TimePickerDialog);
  expect(dial, findsOneWidget, reason: '时间选择器必须打开');
  final center = tester.getCenter(dial);
  // 表盘中心偏右下 = 约 4 点方向，与初始的 03:00 不同，因此钟点确实变了。
  await tester.tapAt(center + const Offset(60, 60));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

CalendarService _service(_MemoryCalendarRepository repository) =>
    CalendarService(
      repository: repository,
      recurringRepository: repository,
      clock: _Clock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    );

WorkspaceService _workspace() => WorkspaceService(
  repository: _Workspace(
    areas: [_area('area-study', '学业'), _area('area-lab', '科研')],
    projects: [
      _project('project-math', '数学建模', 'area-study'),
      _project('project-paper', '论文', 'area-lab'),
    ],
  ),
  clock: _Clock(),
  idGenerator: _Ids(),
);

PlannerArea _area(String id, String name) => PlannerArea(
  id: id,
  name: name,
  color: 0,
  sortOrder: 0,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

PlannerProject _project(String id, String name, String areaId) =>
    PlannerProject(
      id: id,
      areaId: areaId,
      name: name,
      createdAtUtc: DateTime.utc(2026, 10, 1),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

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

final class _MemoryCalendarRepository
    implements CalendarRepository, RecurringCalendarRepository {
  final List<CalendarEvent> saved = [];
  final List<RecurrenceRule> rules = [];
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [];
  @override
  Future<void> save(CalendarEvent event) async => saved.add(event);

  @override
  Future<void> saveRecurring(CalendarEvent event, RecurrenceRule rule) async {
    saved.add(event);
    rules.add(rule);
  }
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 1);
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'event-1';
}
