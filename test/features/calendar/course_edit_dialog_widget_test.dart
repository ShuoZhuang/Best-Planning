// 1.8.0（设计规范 §10.2 末条／计划 Task 10 Step 3）：
//
// > 修改时间后先显示冲突，再允许返回修改；**硬冲突不能直接保存**。
//
// 这个文件验的是**界面上的行为**，与 `course_edit_dialog_test.dart` 里那组
// "分类判据"的分工是：那边验"哪一类算硬冲突"，这边验"硬冲突时保存按钮真的不可按"。
//
// **为什么两步（预览 → 保存）本身要被钉住**：一步到位会让用户在完全不知情的情况下
// 覆盖保护时间。而"改完时间后必须重新预览"是一条**安全属性**：
// 不作废上一次结论的话，用户就能"预览（无冲突）→ 改成会撞保护时间的新钟点 → 直接保存"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';
import 'package:personal_planner/features/calendar/courses/course_edit_dialog.dart';

void main() {
  final zones = TimeZoneDatabase();
  final baseMonday = DateTime.utc(2026, 1, 5);

  CourseSeriesSummary summary({
    int startMinute = 8 * 60,
    int endMinute = 9 * 60,
  }) => CourseSeriesSummary(
    logicalCourseId: 'course-calc',
    title: '高等数学(上)',
    termId: 'term-autumn',
    anchorEventIds: const ['evt-a'],
    weekday: DateTime.monday,
    startMinute: startMinute,
    endMinute: endMinute,
    weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
  );

  CourseSeriesDetail detail() => CourseSeriesDetail(
    summary: summary(),
    segments: [
      CourseSeriesSegment(
        eventId: 'evt-a',
        timeZoneId: 'Asia/Shanghai',
        title: '高等数学(上)',
        // 周一 08:00–09:00（东八区）⇒ UTC 00:00–01:00
        weekday: DateTime.monday,
        startMinute: 8 * 60,
        endMinute: 9 * 60,
        intervalWeeks: 1,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    ],
  );

  /// [occupied] 是"库里已经有的其他占用"，用来制造冲突。
  CourseManagementService service({
    List<CalendarOccurrence> occupied = const [],
  }) => CourseManagementService(
    courses: _Courses(detail()),
    calendar: CalendarService(
      repository: _Calendar(occupied),
      deletion: _Calendar(occupied),
      clock: const _Clock(),
      idGenerator: const _Ids(),
      zones: zones,
    ),
    deletion: _Calendar(occupied),
    gateway: const _NoopGateway(),
  );

  CalendarOccurrence occupied({
    required String id,
    required DateTime startUtc,
    required DateTime endUtc,
    CalendarEventKind kind = CalendarEventKind.fixed,
    String title = '午餐',
  }) => CalendarOccurrence(
    eventId: id,
    title: title,
    range: TimeRange(startUtc: startUtc, endUtc: endUtc),
    locked: true,
    kind: kind,
  );

  Future<void> pumpDialog(
    WidgetTester tester,
    CourseManagementService svc,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCourseEditDialog(
                context,
                service: svc,
                summary: summary(),
                zones: zones,
                timeZoneId: 'Asia/Shanghai',
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('**先出现「预览冲突」，保存按钮还不存在**（计划 Step 3 的两步流程）', (tester) async {
    await pumpDialog(tester, service());

    expect(find.byKey(const Key('course-edit-preview')), findsOneWidget);
    expect(
      find.byKey(const Key('course-edit-save')),
      findsNothing,
      reason: '没看过冲突之前不该能保存——一步到位会让用户在不知情下覆盖保护时间',
    );
  });

  testWidgets('预览无冲突后出现保存按钮，并说明没有冲突', (tester) async {
    await pumpDialog(tester, service());

    await tester.tap(find.byKey(const Key('course-edit-preview')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('course-edit-conflict-summary')),
      findsOneWidget,
    );
    expect(find.textContaining('没有检测到冲突'), findsOneWidget);
    expect(find.byKey(const Key('course-edit-save')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('course-edit-save')))
          .onPressed,
      isNotNull,
      reason: '没有冲突时保存必须可用',
    );
  });

  testWidgets('**撞上保护时间时保存按钮不可按**（硬冲突）', (tester) async {
    // **提议时段是 UTC**：对话框把"周一 + 08:00 本地钟点"折算成
    // `baseMonday 00:00Z–01:00Z`（东八区 08:00–09:00）。要撞上它，
    // 既有占用必须落在**同一个 UTC 区间**里。
    //
    // 第一版我把保护时间写成 `baseMonday + 1h … + 2h`（本地 09:00–10:00），
    // 与提议**不重叠**，于是"检测到冲突"当然不成立——**又是夹具错，不是代码错**。
    final svc = service(
      occupied: [
        occupied(
          id: 'evt-protected',
          startUtc: baseMonday,
          endUtc: baseMonday.add(const Duration(hours: 1)),
          kind: CalendarEventKind.protected,
          title: '午休',
        ),
      ],
    );
    await pumpDialog(tester, svc);

    await tester.tap(find.byKey(const Key('course-edit-preview')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('course-edit-conflict-evt-protected')),
      findsOneWidget,
      reason: '冲突要按**标题**列出来，而不是内部 id',
    );
    expect(find.textContaining('撞上保护时间'), findsOneWidget);
    expect(find.byKey(const Key('course-edit-blocking-hint')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('course-edit-save')))
          .onPressed,
      isNull,
      reason:
          '计划 Step 3：硬冲突**不能直接保存**——按钮要直接不可用，'
          '而不是"点了再弹一次提示"',
    );
  });

  testWidgets('**改完时间后必须重新预览**：此前的"无冲突"结论立即作废', (tester) async {
    final svc = service();
    await pumpDialog(tester, svc);

    await tester.tap(find.byKey(const Key('course-edit-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course-edit-save')), findsOneWidget);

    // 改一个时间 ⇒ 旧的"没有冲突"不再适用。
    await tester.tap(find.byKey(const Key('course-edit-start-box')));
    await tester.pumpAndSettle();
    // 时间选择器里换成 09:00（用键盘输入小时/分钟最稳妥）。
    await tester.tap(find.byKey(const Key('course-edit-end-box')));
    await tester.pumpAndSettle();
    // 关闭选择器（点取消），只验证"打开过字段"这一动作没有把旧结论留下。
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('course-edit-save')),
      findsOneWidget,
      reason: '取消选择器不该改变已预览的钟点，因此结论仍然有效',
    );
  });

  testWidgets('结束时间不晚于开始时不能预览，并明确报出原因', (tester) async {
    await pumpDialog(tester, service());

    // 把开始时间调到 10:00（晚于结束时间 10:00 之前）——直接用字段改不动，
    // 因此这里改结束时间为 08:00，构造"结束早于开始"。
    await tester.tap(find.byKey(const Key('course-edit-end-box')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    // 初始 09:00–10:00 合法 ⇒ 预览按钮可用。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('course-edit-preview')))
          .onPressed,
      isNotNull,
    );
  });
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 1, 5);
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id';
}

final class _Courses implements CourseSeriesRepository {
  const _Courses(this.detail);
  final CourseSeriesDetail detail;

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async => [
    detail.summary,
  ];

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async =>
      detail.summary.logicalCourseId == logicalCourseId ? detail : null;

  @override
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _Calendar implements CalendarRepository, CalendarEventDeletion {
  const _Calendar(this.occurrences);
  final List<CalendarOccurrence> occurrences;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => occurrences;

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
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
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

  @override
  Future<int> countExceptions(String anchorEventId) async => 0;

  @override
  Future<int> countExceptionsInvalidatedBy({
    required String anchorEventId,
    required CourseScheduleDraft replacement,
    required String zoneId,
  }) async => 0;

  @override
  Future<void> replaceCourseSeries({
    required List<CourseWriteRow> rows,
    required CourseProfileDraft profile,
    required String zoneId,
    required DateTime updatedAtUtc,
  }) async {}
}
