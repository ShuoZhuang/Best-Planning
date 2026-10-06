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
    await tester.enterText(
      find.byKey(const Key('event-start-date')),
      '2026-10-03',
    );
    await tester.enterText(find.byKey(const Key('event-start-time')), '18:30');
    await tester.enterText(
      find.byKey(const Key('event-end-date')),
      '2026-10-03',
    );
    await tester.enterText(find.byKey(const Key('event-end-time')), '20:00');
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(
      repository.saved.single.startAtUtc,
      DateTime.utc(2026, 10, 3, 16, 30),
    );
    expect(repository.saved.single.endAtUtc, DateTime.utc(2026, 10, 3, 18));
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
    await tester.enterText(
      find.byKey(const Key('event-recurrence-end-date')),
      '2026-12-28',
    );
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.rules.single.intervalWeeks, 2);
    expect(repository.rules.single.validUntilLocalDate, DateTime(2026, 12, 28));
  });

  testWidgets('固定日程可选所属领域与项目，并写进保存的日程', (tester) async {
    // 此前固定日程表单没有任何"归属"控件，`calendar_events.project_id` 也就没有写入路径：
    // 日程在日历上有颜色、在统计里却没有归属。
    final repository = _MemoryCalendarRepository();
    final workspace = _workspace();
    await tester.pumpWidget(
      MaterialApp(
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
