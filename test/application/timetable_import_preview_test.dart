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
