import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

void main() {
  final term = AcademicTerm(
    id: 'term-autumn',
    name: '2026 秋季学期',
    firstWeekMonday: DateTime(2026, 9, 7),
    totalWeeks: 16,
    timeZoneId: 'Asia/Shanghai',
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 1),
  );
  final periods = PeriodTemplate(
    id: 'periods',
    name: '主校区',
    isDefault: true,
    entries: [
      PeriodEntry(periodNumber: 1, startMinute: 8 * 60, endMinute: 8 * 60 + 45),
      PeriodEntry(
        periodNumber: 2,
        startMinute: 8 * 60 + 55,
        endMinute: 9 * 60 + 40,
      ),
      PeriodEntry(
        periodNumber: 3,
        startMinute: 9 * 60 + 55,
        endMinute: 10 * 60 + 40,
      ),
      PeriodEntry(
        periodNumber: 4,
        startMinute: 10 * 60 + 50,
        endMinute: 11 * 60 + 35,
      ),
    ],
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 1),
  );

  test('expands weekly, even-week and consecutive-period courses', () async {
    final repository = _SpyCalendar();
    final service = TimetableImportService(
      calendarRepository: repository,
      zones: TimeZoneDatabase(),
    );
    final draft = TimetableDraft(
      courses: [
        _course(
          id: 'weekly',
          name: '大学物理',
          weekday: DateTime.monday,
          startPeriod: 1,
          endPeriod: 2,
          spans: const [WeekSpan(startWeek: 1, endWeek: 16)],
        ),
        _course(
          id: 'even',
          name: '创业基础',
          weekday: DateTime.wednesday,
          startPeriod: 3,
          endPeriod: 4,
          spans: const [
            WeekSpan(startWeek: 2, endWeek: 6, parity: WeekParity.even),
          ],
        ),
      ],
    );

    final preview = await service.preview(draft, term, periods);

    expect(preview.series, hasLength(2));
    expect(
      preview.occurrences.where((item) => item.courseId == 'weekly'),
      hasLength(16),
    );
    expect(
      preview.occurrences
          .where((item) => item.courseId == 'even')
          .map((item) => item.weekNumber),
      [2, 4, 6],
    );
    expect(preview.series.first.event.range.durationMinutes, 100);
    expect(repository.saveCalls, 0, reason: '预览阶段不得写入');
  });

  test('non-contiguous spans become separate series', () async {
    final service = TimetableImportService(
      calendarRepository: _SpyCalendar(),
      zones: TimeZoneDatabase(),
    );
    final preview = await service.preview(
      TimetableDraft(
        courses: [
          _course(
            id: 'split',
            name: '分段课程',
            weekday: DateTime.tuesday,
            startPeriod: 1,
            endPeriod: 1,
            spans: const [
              WeekSpan(startWeek: 1, endWeek: 4),
              WeekSpan(startWeek: 8, endWeek: 16),
            ],
          ),
        ],
      ),
      term,
      periods,
    );

    expect(preview.series, hasLength(2));
    expect(preview.occurrences, hasLength(13));
  });

  test('detects conflicts and defaults exact duplicates to skip', () async {
    final zones = TimeZoneDatabase();
    final firstStart = zones.localDateTimeToUtc(
      DateTime(2026, 9, 7),
      8 * 60,
      'Asia/Shanghai',
    );
    final existing = [
      CalendarOccurrence(
        eventId: 'existing-course',
        title: '大学物理',
        range: TimeRange(
          startUtc: firstStart,
          endUtc: firstStart.add(const Duration(minutes: 100)),
        ),
        locked: true,
        location: 'A402',
        notes: '张震',
        sourceKind: CalendarEventSourceKind.timetableImport,
        logicalCourseId: 'existing-logical',
      ),
      CalendarOccurrence(
        eventId: 'meeting',
        title: '班会',
        range: TimeRange(
          startUtc: firstStart.add(const Duration(minutes: 20)),
          endUtc: firstStart.add(const Duration(minutes: 40)),
        ),
        locked: true,
      ),
    ];
    final repository = _SpyCalendar(existing: existing);
    final service = TimetableImportService(
      calendarRepository: repository,
      zones: zones,
    );
    final preview = await service.preview(
      TimetableDraft(
        courses: [
          _course(
            id: 'physics',
            name: '大学物理',
            weekday: DateTime.monday,
            startPeriod: 1,
            endPeriod: 2,
            teacher: '张震',
            location: 'A402',
            spans: const [WeekSpan(startWeek: 1, endWeek: 1)],
          ),
        ],
      ),
      term,
      periods,
    );

    expect(preview.conflicts, hasLength(2));
    expect(preview.duplicates.single.kind, TimetableDuplicateKind.exact);
    expect(
      preview.duplicates.single.resolution,
      TimetableDuplicateResolution.skip,
    );
    expect(repository.saveCalls, 0);
  });

  test('teacher or location changes are possible updates', () async {
    final zones = TimeZoneDatabase();
    final start = zones.localDateTimeToUtc(
      DateTime(2026, 9, 7),
      8 * 60,
      'Asia/Shanghai',
    );
    final repository = _SpyCalendar(
      existing: [
        CalendarOccurrence(
          eventId: 'existing-course',
          title: '大学物理',
          range: TimeRange(
            startUtc: start,
            endUtc: start.add(const Duration(minutes: 100)),
          ),
          locked: true,
          location: 'A401',
          notes: '旧教师',
          sourceKind: CalendarEventSourceKind.timetableImport,
          logicalCourseId: 'existing-logical',
        ),
      ],
    );
    final preview =
        await TimetableImportService(
          calendarRepository: repository,
          zones: zones,
        ).preview(
          TimetableDraft(
            courses: [
              _course(
                id: 'physics',
                name: '大学物理',
                weekday: DateTime.monday,
                startPeriod: 1,
                endPeriod: 2,
                teacher: '新教师',
                location: 'A402',
                spans: const [WeekSpan(startWeek: 1, endWeek: 1)],
              ),
            ],
          ),
          term,
          periods,
        );

    expect(
      preview.duplicates.single.kind,
      TimetableDuplicateKind.possibleUpdate,
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 9 Step 4（计划 §3.4）：**"只剩一部分片段"必须被标为需要人工确认**
  // ───────────────────────────────────────────────────────────────────────────

  test('库里只剩这门课的一部分片段 ⇒ partiallyPresent，且默认保留现有课程', () async {
    final zones = TimeZoneDatabase();
    // 幸存的那一段：周三 8:00（用户在日历上把周一那段删掉了，或历史缺陷留下的一半）。
    final survivingStart = zones.localDateTimeToUtc(
      DateTime(2026, 9, 9),
      8 * 60,
      'Asia/Shanghai',
    );
    final repository = _SpyCalendar(
      existing: [
        CalendarOccurrence(
          eventId: 'surviving-anchor',
          title: '高等数学(上)',
          range: TimeRange(
            startUtc: survivingStart,
            endUtc: survivingStart.add(const Duration(minutes: 100)),
          ),
          locked: true,
          sourceKind: CalendarEventSourceKind.timetableImport,
          logicalCourseId: 'course-calc',
        ),
      ],
    );

    final preview =
        await TimetableImportService(
          calendarRepository: repository,
          zones: zones,
        ).preview(
          TimetableDraft(
            courses: [
              _course(
                id: 'course-calc',
                name: '高等数学(上)',
                weekday: DateTime.monday,
                startPeriod: 1,
                endPeriod: 2,
                spans: const [WeekSpan(startWeek: 1, endWeek: 1)],
              ),
            ],
          ),
          term,
          periods,
        );

    final duplicate = preview.duplicates.single;
    expect(
      duplicate.kind,
      TimetableDuplicateKind.partiallyPresent,
      reason:
          '周一那一段在库里找不到对应的时间，但**这个名字的导入课程已经存在**——'
          '说明它只剩一部分片段（或课表本身变了）。整套创建会与幸存的那几段重复',
    );
    expect(
      duplicate.resolution,
      TimetableDuplicateResolution.skip,
      reason: '默认必须是"保留现有课程"，否则剩下的片段会被复制一份',
    );
    expect(duplicate.existingEventIds, {
      'surviving-anchor',
    }, reason: '要告诉调用方"现有的是哪几条"，回滚与保护判定都要用它');
    expect(
      preview.reviewReasons['course-calc'],
      contains(TimetableReviewReason.partiallyDeletedCourse),
      reason: '审阅步骤也要看到这条警告，而不是只在预览卡片上出现一次',
    );
  });

  test('判据用**标题**而不是草稿里按顺序生成的 id —— 序号错位也能认出来', () async {
    final zones = TimeZoneDatabase();
    final survivingStart = zones.localDateTimeToUtc(
      DateTime(2026, 9, 9),
      8 * 60,
      'Asia/Shanghai',
    );
    final repository = _SpyCalendar(
      existing: [
        CalendarOccurrence(
          eventId: 'surviving-anchor',
          title: '高等数学(上)',
          range: TimeRange(
            startUtc: survivingStart,
            endUtc: survivingStart.add(const Duration(minutes: 100)),
          ),
          locked: true,
          sourceKind: CalendarEventSourceKind.timetableImport,
          // **库里的 id 与草稿的 id 不同**：解析器按出现顺序生成 `course-N`，
          // 新图多一门课就会整体错位。按 id 匹配会静默失效，按标题才不会。
          logicalCourseId: 'course-7',
        ),
      ],
    );

    final preview =
        await TimetableImportService(
          calendarRepository: repository,
          zones: zones,
        ).preview(
          TimetableDraft(
            courses: [
              _course(
                id: 'course-2',
                name: '高等数学(上)',
                weekday: DateTime.monday,
                startPeriod: 1,
                endPeriod: 2,
                spans: const [WeekSpan(startWeek: 1, endWeek: 1)],
              ),
            ],
          ),
          term,
          periods,
        );

    expect(
      preview.duplicates.single.kind,
      TimetableDuplicateKind.partiallyPresent,
    );
  });

  test('库里完全没有这门课 ⇒ 不报重复（新课程正常整套创建）', () async {
    final zones = TimeZoneDatabase();
    final otherStart = zones.localDateTimeToUtc(
      DateTime(2026, 9, 7),
      8 * 60,
      'Asia/Shanghai',
    );
    final repository = _SpyCalendar(
      existing: [
        CalendarOccurrence(
          eventId: 'other-course',
          title: '另一门课',
          range: TimeRange(
            startUtc: otherStart,
            endUtc: otherStart.add(const Duration(minutes: 100)),
          ),
          locked: true,
          sourceKind: CalendarEventSourceKind.timetableImport,
          logicalCourseId: 'course-other',
        ),
      ],
    );

    final preview =
        await TimetableImportService(
          calendarRepository: repository,
          zones: zones,
        ).preview(
          TimetableDraft(
            courses: [
              _course(
                id: 'course-calc',
                name: '高等数学(上)',
                weekday: DateTime.monday,
                startPeriod: 1,
                endPeriod: 2,
                spans: const [WeekSpan(startWeek: 1, endWeek: 2)],
              ),
            ],
          ),
          term,
          periods,
        );

    expect(
      preview.duplicates,
      isEmpty,
      reason: '这门课在库里一条锚点都没有 ⇒ 它是新课程，应当正常整套创建',
    );
    expect(
      preview.reviewReasons['course-calc'],
      isNot(contains(TimetableReviewReason.partiallyDeletedCourse)),
    );
  });
}

CourseDraft _course({
  required String id,
  required String name,
  required int weekday,
  required int startPeriod,
  required int endPeriod,
  required List<WeekSpan> spans,
  String teacher = '',
  String location = '',
}) => CourseDraft(
  id: id,
  name: name,
  teacher: teacher,
  location: location,
  weekday: weekday,
  startPeriod: startPeriod,
  endPeriod: endPeriod,
  weekSpans: spans,
  areaId: 'area-study',
  originalText: name,
);

final class _SpyCalendar implements CalendarRepository {
  _SpyCalendar({this.existing = const []});

  final List<CalendarOccurrence> existing;
  int saveCalls = 0;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => existing;

  @override
  Future<void> save(CalendarEvent event) async {
    saveCalls++;
  }
}
