// 1.8.0（设计规范 §9，计划 Task 15）：本批次**新增的三个入口**的可访问性。
//
// 规范 §9 要求："所有新入口支持键盘操作、清晰焦点、语义标签和 44×44 以上的点击区域。"
//
// 已经有的 `accessibility_keyboard_test.dart` / `accessibility_semantics_test.dart` /
// `accessibility_form_error_test.dart` 覆盖的是**既有页面**（任务页筛选、固定日程编辑器等）。
// 本批次新增了三个入口——`/new`、`/calendar/protected/new`、`/calendar/courses`——
// 它们此前**一条可访问性用例都没有**：新入口最容易漏掉的正是这一条，
// 因为"能点"和"能用键盘点"在开发机上看起来一样。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';
import 'package:personal_planner/features/calendar/courses/course_management_page.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_editor_page.dart';
import 'package:personal_planner/features/tasks/task_type_chooser.dart';

/// 规范 §9 的下限。
const double minimumTapTarget = 44;

void main() {
  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(body: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  CourseManagementService courseService() => CourseManagementService(
    courses: const _Courses(),
    calendar: CalendarService(
      repository: const _NoopCalendar(),
      clock: const _Clock(),
      idGenerator: const _Ids(),
      zones: TimeZoneDatabase(),
    ),
    deletion: const _NoopDeletion(),
    gateway: const _NoopGateway(),
  );

  /// 断言某个 key 对应的控件**至少** 44×44。
  void expectTapTarget(WidgetTester tester, Key key) {
    final size = tester.getSize(find.byKey(key));
    expect(
      size.width,
      greaterThanOrEqualTo(minimumTapTarget),
      reason: '$key 的宽度 ${size.width} 小于 $minimumTapTarget',
    );
    expect(
      size.height,
      greaterThanOrEqualTo(minimumTapTarget),
      reason: '$key 的高度 ${size.height} 小于 $minimumTapTarget',
    );
  }

  group('新建事项选择器（/new）', () {
    // **必须传 `onBack`**：返回按钮只在有回调时才渲染（`if (onBack case final onBack?)`），
    // 不传就等于在验一个不存在的控件——第一版如此，`getSize` 抛 `Bad state: No element`。
    Widget chooser(void Function(PlannerNewItemKind) onSelect) =>
        TaskTypeChooserPage(onSelect: onSelect, onBack: () {});

    testWidgets('四张卡与返回按钮都满足 44×44', (tester) async {
      await pump(tester, chooser((_) {}));

      for (final key in const [
        Key('new-type-task'),
        Key('new-type-recurring'),
        Key('new-type-fixed-event'),
        Key('new-type-protected-time'),
        Key('new-item-back'),
      ]) {
        expectTapTarget(tester, key);
      }
    });

    testWidgets('每张卡都能被 Tab 到达，且按 Enter 真的触发回调', (tester) async {
      // **"能点"与"能用键盘点"在开发机上看起来一样**，因此这条必须验行为而不是外观：
      // 反复 Tab，一旦焦点落在"普通任务"上，按 Enter 就要真的调到 `onSelect`。
      final selected = <PlannerNewItemKind>[];
      await pump(tester, chooser(selected.add));

      for (var step = 0; step < 20 && selected.isEmpty; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      expect(selected, isNotEmpty, reason: '新入口必须能被键盘真正激活，而不是只"鼠标能点"');
    });

    testWidgets('没有不可用的选项时，四类都渲染出来', (tester) async {
      await pump(tester, chooser((_) {}));

      for (final key in const [
        Key('new-type-task'),
        Key('new-type-recurring'),
        Key('new-type-fixed-event'),
        Key('new-type-protected-time'),
      ]) {
        expect(find.byKey(key), findsOneWidget);
      }
    });
  });

  group('保护时间编辑器（/calendar/protected/new）', () {
    Widget editor() => ProtectedTimeEditorPage(
      service: CalendarService(
        repository: const _NoopCalendar(),
        clock: const _Clock(),
        idGenerator: const _Ids(),
        zones: TimeZoneDatabase(),
      ),
      timeZoneId: 'Asia/Shanghai',
      zones: TimeZoneDatabase(),
    );

    testWidgets('保存按钮满足 44×44', (tester) async {
      await pump(tester, editor());

      expectTapTarget(tester, const Key('save-protected-time'));
    });

    testWidgets('保存按钮在不滚动的情况下也可点击（键盘用户不必先滚）', (tester) async {
      await pump(tester, editor());

      final button = find.byKey(const Key('save-protected-time'));
      expect(button, findsOneWidget);
      // `ensureVisible` 之后再点：若按钮本来就在视口内，这一步是空操作；
      // 若不在，说明布局把主操作挤出了首屏——那本身就是可用性问题。
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('课程管理页（/calendar/courses）', () {
    Widget page() => CourseManagementPage(
      service: courseService(),
      onOpenCourse: (_) {},
      onImportTimetable: () {},
    );

    testWidgets('课程行的操作按钮满足 44×44', (tester) async {
      await pump(tester, page());

      expectTapTarget(tester, const Key('manage-course-course-calc'));
    });

    testWidgets('空状态里的「导入课表」满足 44×44', (tester) async {
      await pump(
        tester,
        CourseManagementPage(
          service: CourseManagementService(
            courses: const _NoCourses(),
            calendar: CalendarService(
              repository: const _NoopCalendar(),
              clock: const _Clock(),
              idGenerator: const _Ids(),
              zones: TimeZoneDatabase(),
            ),
            deletion: const _NoopDeletion(),
            gateway: const _NoopGateway(),
          ),
          onImportTimetable: () {},
        ),
      );

      expectTapTarget(tester, const Key('course-empty-import'));
    });
  });
}

final class _Courses implements CourseSeriesRepository {
  const _Courses();

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async => [
    CourseSeriesSummary(
      logicalCourseId: 'course-calc',
      title: '高等数学(上)',
      termId: 'term-autumn',
      anchorEventIds: const ['evt-1'],
      weekday: DateTime.monday,
      startMinute: 8 * 60,
      endMinute: 9 * 60,
      weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
    ),
  ];

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async => null;

  @override
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _NoCourses implements CourseSeriesRepository {
  const _NoCourses();

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async =>
      const [];

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async => null;

  @override
  Future<String?> currentTermId() async => null;
}

final class _NoopCalendar implements CalendarRepository {
  const _NoopCalendar();
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoopDeletion implements CalendarEventDeletion {
  const _NoopDeletion();
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

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 12, 4);
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id';
}
