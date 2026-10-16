// Task 10 Step 6（课程与保护时间管理修复计划）：**新界面的可访问性守卫**。
//
// 规范 §Global Constraints 要求"非空语义标签"。这一页最容易被漏掉的一处是
// **同一页上多行结构相同**：一个只有 `tooltip: '删除'` 的图标按钮，读屏用户听到的是
// 五个一模一样的"删除"，无从知道自己在删哪一段课。
//
// 本文件用**真实语义节点**断言，而不是 `find.byTooltip`：tooltip 不会自动成为语义
// label，因此用 tooltip 断言会给出"看起来通过了、读屏其实什么都读不到"的假绿。
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:personal_planner/features/calendar/courses/course_editor_page.dart';

void main() {
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);
  late _Courses courses;
  late _Gateway gateway;
  late _Calendar calendar;

  setUp(() {
    courses = _Courses();
    gateway = _Gateway();
    calendar = _Calendar();
  });

  CourseManagementService buildService() => CourseManagementService(
    courses: courses,
    calendar: CalendarService(
      repository: calendar,
      deletion: calendar,
      clock: _Clock(nowUtc),
      idGenerator: _Ids(),
      zones: TimeZoneDatabase(),
    ),
    deletion: calendar,
    gateway: gateway,
    zones: TimeZoneDatabase(),
    timeZoneId: 'Asia/Shanghai',
    clock: _Clock(nowUtc),
  );

  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: CourseEditorPage(
            service: buildService(),
            logicalCourseId: 'course-calc',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('**页面自己加的按钮都有名称**（删行入口带课程名与星期）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEditor(tester);

    final buttons = _collect(tester)
        .where((node) => node.isButton)
        .map((node) => node.label)
        .toList();

    // **逐条点名这一页自己造的按钮**，而不是"伞状断言整棵树一个空名都没有"。
    //
    // 理由是一次实测：整棵树上还剩一个无名按钮节点，但**它不是这一页的控件**——
    // 把行内删除按钮的 tooltip 换成别的字符串，那个节点的 label 不动；
    // 而这一页的 `IconButton`／`OutlinedButton`／`FilledButton`／`FilterChip`
    // 数量与位置都能对上。伞状断言会把这个未定位的节点算在这一页头上，
    // 于是要么误报、要么（更糟）为了让它变绿而放松判据。
    expect(
      buttons,
      contains('删除「高等数学(上)」的 周一 这一段'),
      reason: '删行入口必须带上课程名与星期：这一页可能有好几行结构相同的安排',
    );
    expect(buttons, contains('添加一段安排'));
    expect(buttons, contains('保存'));
    for (final day in const ['周一', '周二', '周三', '周四', '周五', '周六', '周日']) {
      expect(
        buttons,
        contains(day),
        reason: '星期切换项「$day」必须有名称，否则读屏用户只能听到七个"按钮"',
      );
    }

    handle.dispose();
  });

  testWidgets('**删除入口的语义带课程名与星期**（同页多行也能区分）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEditor(tester);

    final deletes = _collect(tester)
        .where((node) => node.isButton && node.label.contains('删除'))
        .toList();

    expect(deletes, isNotEmpty, reason: '前置条件：这一页必须有删除入口');
    for (final node in deletes) {
      expect(
        node.label,
        allOf(contains('高等数学(上)'), contains('周一')),
        reason:
            '只说"删除"的按钮，读屏用户不知道自己在删哪一条——'
            '而这一页上可能有好几行结构相同的安排',
      );
    }

    handle.dispose();
  });

  testWidgets('**资料字段可读且带名称**（不是只有输入框没有标签）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEditor(tester);

    // 三个资料字段都必须能被"读出来"，而它们的名字来自 `labelText`——
    // 用 `hintText` 或什么都不给，读屏用户只会听到"文本框"。
    final nodes = _collect(tester);
    for (final label in const ['课程名称', '教师', '地点']) {
      expect(
        nodes.where((node) => node.label.contains(label)).length,
        greaterThanOrEqualTo(1),
        reason: '字段「$label」必须在语义树里有一个带名称的节点',
      );
    }

    handle.dispose();
  });

  testWidgets('**主按钮有名称与角色**，不是裸图标', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEditor(tester);

    final save = _collect(tester)
        .where((node) => node.isButton && node.label.contains('保存'))
        .toList();

    expect(save, isNotEmpty, reason: '主按钮必须出现在语义树里且可激活');
    for (final node in save) {
      expect(node.label.trim(), isNotEmpty);
    }

    handle.dispose();
  });
}

/// 把当前语义树摊平成一组可断言的记录。
///
/// 用真实语义节点而不是 `find.byTooltip`／`matchesSemantics`：前者在"tooltip 存在但
/// label 为空"时会假绿，而这正是本文件要防的那一种缺陷。
List<({bool isButton, String label, String value, String hint})> _collect(
  WidgetTester tester,
) {
  // `binding.pipelineOwner` 在 3.10 之后被标记为弃用，但它**仍然是此处唯一能拿到
  // 当前测试树语义根的入口**——与 `accessibility_semantics_test.dart` 同一条理由。
  // ignore: deprecated_member_use
  final owner = tester.binding.pipelineOwner.semanticsOwner;
  final root = owner?.rootSemanticsNode;
  final result = <({bool isButton, String label, String value, String hint})>[];
  if (root == null) return result;

  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    result.add((
      isButton: data.flagsCollection.isButton,
      label: data.label,
      value: data.value,
      hint: data.hint,
    ));
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return result;
}

final class _Courses implements CourseSeriesRepository {
  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async {
    if (logicalCourseId != 'course-calc') return null;
    return CourseSeriesDetail(
      summary: CourseSeriesSummary(
        logicalCourseId: 'course-calc',
        title: '高等数学(上)',
        termId: 'term-autumn',
        anchorEventIds: const ['evt-a'],
        weekday: DateTime.monday,
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
      ),
      segments: [
        CourseSeriesSegment(
          eventId: 'evt-a',
          timeZoneId: 'Asia/Shanghai',
          title: '高等数学(上)',
          weekdays: const {DateTime.monday},
          startMinute: 8 * 60,
          endMinute: 8 * 60 + 45,
          intervalWeeks: 1,
          validFromLocalDate: DateTime(2026, 9, 7),
          validUntilLocalDate: DateTime(2026, 12, 20),
          location: 'D206',
          teacher: '赵敏',
          weekSpan: const WeekSpan(startWeek: 1, endWeek: 16),
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
      ],
    );
  }

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async =>
      const [];

  @override
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _Gateway implements CourseWriteGateway {
  @override
  Future<CourseDeletionResult> deleteSeriesWithExceptions({
    required Set<String> anchorEventIds,
    required DateTime deletedAtUtc,
  }) async => CourseDeletionResult.empty;

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
    required CourseSeriesProvenance provenance,
    required String expectedFingerprint,
  }) async {}
}

final class _Calendar implements CalendarRepository, CalendarEventDeletion {
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
    required DateTime updatedAtUtc,
    DateTime? updateExceptionsFromUtc,
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

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'generated-${++_count}';
}
