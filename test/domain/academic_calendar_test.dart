import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';

void main() {
  group('AcademicWeekCalculator', () {
    test('2026-10-05 是第 5 周时，第一周周一为 2026-09-07', () {
      final firstMonday = AcademicWeekCalculator.firstWeekMonday(
        referenceDate: DateTime(2026, 10, 5),
        weekNumber: 5,
      );

      expect(firstMonday, DateTime(2026, 9, 7));
      expect(
        AcademicWeekCalculator.weekNumber(
          firstWeekMonday: firstMonday,
          date: DateTime(2026, 10, 5),
        ),
        5,
      );
    });

    test('参考日期是周日时仍按它所在的本地周换算', () {
      expect(
        AcademicWeekCalculator.firstWeekMonday(
          referenceDate: DateTime(2026, 10, 11),
          weekNumber: 5,
        ),
        DateTime(2026, 9, 7),
      );
    });

    test('闰年日期按本地日历周计算', () {
      final first = DateTime(2024, 2, 26);
      expect(
        AcademicWeekCalculator.weekNumber(
          firstWeekMonday: first,
          date: DateTime(2024, 3, 3),
        ),
        1,
      );
      expect(
        AcademicWeekCalculator.weekNumber(
          firstWeekMonday: first,
          date: DateTime(2024, 3, 4),
        ),
        2,
      );
    });

    test('第一周之前的日期和非正周数会被拒绝', () {
      expect(
        () => AcademicWeekCalculator.weekNumber(
          firstWeekMonday: DateTime(2026, 9, 7),
          date: DateTime(2026, 9, 6),
        ),
        throwsArgumentError,
      );
      expect(
        () => AcademicWeekCalculator.firstWeekMonday(
          referenceDate: DateTime(2026, 10, 5),
          weekNumber: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('academic models', () {
    final instant = DateTime.utc(2026, 10, 5);

    AcademicTerm term({String name = '秋季学期', int totalWeeks = 16}) =>
        AcademicTerm(
          id: 'term-1',
          name: name,
          firstWeekMonday: DateTime(2026, 9, 7),
          totalWeeks: totalWeeks,
          timeZoneId: 'Asia/Shanghai',
          createdAtUtc: instant,
          updatedAtUtc: instant,
        );

    test('学期名不能为空且总周数只允许 1 到 60', () {
      expect(() => term(name: '  '), throwsArgumentError);
      expect(() => term(totalWeeks: 0), throwsArgumentError);
      expect(() => term(totalWeeks: 61), throwsArgumentError);
      expect(term(totalWeeks: 1).totalWeeks, 1);
      expect(term(totalWeeks: 60).totalWeeks, 60);
    });

    test('第一周日期必须是本地周一', () {
      expect(
        () => AcademicTerm(
          id: 'term-1',
          name: '秋季学期',
          firstWeekMonday: DateTime(2026, 9, 8),
          totalWeeks: 16,
          timeZoneId: 'Asia/Shanghai',
          createdAtUtc: instant,
          updatedAtUtc: instant,
        ),
        throwsArgumentError,
      );
    });

    test('节次模板拒绝重复编号、倒置时间和相邻节次重叠', () {
      PeriodTemplate template(List<PeriodEntry> entries) => PeriodTemplate(
        id: 'template-1',
        name: '主校区',
        isDefault: false,
        entries: entries,
        createdAtUtc: instant,
        updatedAtUtc: instant,
      );

      expect(
        () => template([
          PeriodEntry(periodNumber: 1, startMinute: 480, endMinute: 525),
          PeriodEntry(periodNumber: 1, startMinute: 535, endMinute: 580),
        ]),
        throwsArgumentError,
      );
      expect(
        () => PeriodEntry(periodNumber: 1, startMinute: 525, endMinute: 480),
        throwsArgumentError,
      );
      expect(
        () => template([
          PeriodEntry(periodNumber: 1, startMinute: 480, endMinute: 525),
          PeriodEntry(periodNumber: 2, startMinute: 520, endMinute: 565),
        ]),
        throwsArgumentError,
      );
    });
  });
}
