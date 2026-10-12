// 1.8.0（设计规范 §10.1／计划 Task 10）：课程管理的**路由与深链**。
//
// 计划 Task 10 的 Files 一栏声明了 `test/app/course_management_route_test.dart`，
// 而它此前不存在（第 40 轮的交付审计发现的四处之一）。
//
// 它要验的是规范 §10.1 最后一句："日历课程卡片的更多菜单包含「管理这门课」，
// **按 `logicalCourseId` 打开对应详情**。" —— 也就是说**同名课程不能打开错项**。
//
// 这一条只能在这一层验：页面用例注入的是"已经找到的那一门"，因此它对
// "深链取错了哪一门"一无所知。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

final _now = DateTime.utc(2026, 10, 12, 1);

void main() {
  /// **两门同名课**，用不同的 `logicalCourseId` 与不同的星期区分。
  ///
  /// 同名是关键：按标题找会打开错项，按 id 找才对（规范 §10.1 最后一句）。
  CourseSeriesSummary summary({
    required String id,
    required String title,
    required int weekday,
    int startMinute = 8 * 60,
  }) => CourseSeriesSummary(
    logicalCourseId: id,
    title: title,
    termId: 'term-autumn',
    anchorEventIds: [id],
    weekday: weekday,
    startMinute: startMinute,
    endMinute: startMinute + 45,
    weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
  );

  final courseA = summary(
    id: 'course-a',
    title: '高等数学(上)',
    weekday: DateTime.monday,
  );
  final courseB = summary(
    id: 'course-b',
    title: '高等数学(上)',
    weekday: DateTime.thursday,
    startMinute: 10 * 60,
  );

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    CourseManagementService? courses,
    String initialLocation = '/calendar/courses',
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = createPlannerRouter(
      taskService: TaskService(
        repository: _EmptyTasks(),
        clock: const _FixedClock(),
        idGenerator: _Ids(),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: _now,
      nowUtc: _now,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      courseManagement: courses,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go(initialLocation);
    await tester.pumpAndSettle();
    return router;
  }

  CourseManagementService service() => CourseManagementService(
    courses: _Courses([courseA, courseB]),
    calendar: CalendarService(
      repository: const _NoopCalendar(),
      deletion: const _NoopCalendar(),
      clock: const _FixedClock(),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    ),
    deletion: const _NoopCalendar(),
    gateway: const _NoopGateway(),
  );

  testWidgets('`/calendar/courses` 列出当前学期的课程', (tester) async {
    await pumpRouter(tester, courses: service());

    expect(find.text('管理课程'), findsOneWidget);
    // 两门同名课各占一行。
    expect(find.textContaining('高等数学(上)'), findsNWidgets(2));
  });

  testWidgets('**深链按 logicalCourseId 打开对应详情**：同名课不会打开错项', (tester) async {
    // 直接走 course-b 的深链。若实现按**标题**找，打开的就是先遇到的那一门
    // （course-a，周一），而用户点的是周四那一门。
    await pumpRouter(
      tester,
      courses: service(),
      initialLocation: '/calendar/courses/course-b',
    );

    expect(
      find.byKey(const Key('course-segment-course-b')),
      findsOneWidget,
      reason: '深链必须打开 course-b 自己的片段',
    );
    expect(
      find.byKey(const Key('course-segment-course-a')),
      findsNothing,
      reason:
          '打开 course-b 时不该出现 course-a 的片段——'
          '两门课同名，按标题找就会打开错项（规范 §10.1 最后一句）',
    );
  });

  testWidgets('未装配课程服务时给出装配说明，而不是空白页或崩溃', (tester) async {
    await pumpRouter(tester);

    expect(
      find.textContaining('未装配'),
      findsOneWidget,
      reason: '约定：不为"点了没反应"的入口留白；装配缺失要如实说出来',
    );
  });

  testWidgets('**不存在的 logicalCourseId 给"找不到"说明，而不是永远转圈**', (tester) async {
    // 深链 `/calendar/courses/<不存在的 id>` 会走到这里：旧链接，或那门课刚被删。
    //
    // **这条用例第一版是"pumpAndSettle 超时"**：页面把 `detail == null` 当成
    // "还在加载"，于是永远显示转圈 —— 既不报错也不给返回入口。
    // 那不是一个"渲染慢"的问题，而是一个**卡死的页面**。
    await pumpRouter(
      tester,
      courses: service(),
      initialLocation: '/calendar/courses/course-missing',
    );

    expect(
      find.byKey(const Key('course-detail-missing')),
      findsOneWidget,
      reason: '读完了没有这门课就必须说出来；继续转圈等于把"没找到"伪装成"还在加载"',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '已经读完了就不该还在转圈',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 1（课程与保护时间管理修复计划 §2.1／Task 5 Step 6）：**课程编辑路由**
  //
  // 详情页要能进 `/calendar/courses/<logicalCourseId>/edit`，
  // 保存或取消之后**回到同一门课的详情**（不是回到列表）。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**详情页点「编辑课程」进入编辑深链**', (tester) async {
    final router = await pumpRouter(
      tester,
      courses: service(),
      initialLocation: '/calendar/courses/course-b',
    );

    final entry = find.byKey(const Key('course-edit-course'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.path,
      '/calendar/courses/course-b/edit',
      reason: '编辑页要按 logicalCourseId 深链进去，同名课才不会打开错项',
    );
    expect(
      find.byKey(const Key('course-editor-page')),
      findsOneWidget,
      reason: '编辑页必须真的渲染出来，而不是只换了个 URL',
    );
  });

  testWidgets('**不存在的课程编辑深链给"已删除或链接过期"说明**', (tester) async {
    await pumpRouter(
      tester,
      courses: service(),
      initialLocation: '/calendar/courses/course-missing/edit',
    );

    expect(
      find.textContaining('已删除'),
      findsOneWidget,
      reason:
          '计划 Task 5 Step 6："直接深链不存在 id 时显示『课程已删除或链接过期』"。'
          '不加这一句，用户看到的是一个空白页，不知道是加载中还是真的没了',
    );
  });
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'id-${++_count}';
}

final class _EmptyTasks implements TaskRepository {
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);

  @override
  Future<PlannerTask?> getById(String id) async => null;

  @override
  Future<void> save(PlannerTask task) async {}
}

final class _Courses implements CourseSeriesRepository {
  const _Courses(this.summaries);
  final List<CourseSeriesSummary> summaries;

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async =>
      summaries;

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async {
    final found = summaries
        .where((item) => item.logicalCourseId == logicalCourseId)
        .firstOrNull;
    if (found == null) return null;
    return CourseSeriesDetail(
      summary: found,
      segments: [
        for (final eventId in found.anchorEventIds)
          CourseSeriesSegment(
            eventId: eventId,
            title: found.title,
            weekday: found.weekday,
            startMinute: found.startMinute,
            endMinute: found.endMinute,
            intervalWeeks: 1,
            validFromLocalDate: DateTime(2026, 9, 7),
            validUntilLocalDate: DateTime(2026, 12, 20),
            updatedAtUtc: DateTime.utc(2026, 10, 1),
          ),
      ],
    );
  }

  @override
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _NoopCalendar implements CalendarRepository, CalendarEventDeletion {
  const _NoopCalendar();

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}

  @override
  Future<void> deleteEvent(String eventId) async {}

  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventEditDraft event,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> setEventArea({
    required String eventId,
    required String? areaId,
    required DateTime updatedAtUtc,
  }) async {}
}

final class _NoopGateway implements CourseWriteGateway {
  const _NoopGateway();
  @override
  Future<void> deleteSeriesWithExceptions(Set<String> anchorEventIds) async {}
}
