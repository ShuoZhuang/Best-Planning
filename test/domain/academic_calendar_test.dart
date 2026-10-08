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

    // ── M6（路线图 §10 退出条件）：周数与第一周日期双向换算要有
    //    **跨年、学期中途和非法日期**测试。此前只有"第 5 周""周日""闰年"三个用例，
    //    跨年与学期中途这两种最容易算错的都没有。

    test('M6 跨年：秋季学期第一周在上一年，第 18 周落到次年', () {
      // 2026-09-07 是第 1 周周一 → 第 18 周是 2027-01-04（跨年）。
      final firstMonday = AcademicWeekCalculator.firstWeekMonday(
        referenceDate: DateTime(2027, 1, 4),
        weekNumber: 18,
      );
      expect(firstMonday, DateTime(2026, 9, 7), reason: '跨年换算必须仍然指回上一年的第一周周一');
      expect(
        AcademicWeekCalculator.weekNumber(
          firstWeekMonday: firstMonday,
          date: DateTime(2027, 1, 4),
        ),
        18,
      );
      // 反向：跨年那一周的第一天也要能算回来。
      expect(
        AcademicWeekCalculator.weekNumber(
          firstWeekMonday: firstMonday,
          date: DateTime(2026, 12, 28),
        ),
        17,
      );
    });

    test('M6 跨年：春季学期第一周在年初，末周落在年中', () {
      // 2027-02-22 是第 1 周周一 → 第 20 周是 2027-07-05。
      final firstMonday = AcademicWeekCalculator.firstWeekMonday(
        referenceDate: DateTime(2027, 7, 5),
        weekNumber: 20,
      );
      expect(firstMonday, DateTime(2027, 2, 22));
      expect(
        AcademicWeekCalculator.weekNumber(
          firstWeekMonday: firstMonday,
          date: DateTime(2027, 7, 5),
        ),
        20,
      );
    });

    test('M6 学期中途：任意一周的周一都能与周数互推（往返一致）', () {
      final firstMonday = DateTime(2026, 9, 7);
      // 逐个学期周检查往返：`firstWeekMonday(weekNumber(d)) == d 所在周的周一`。
      // 只抽查几个"好算"的周会掩盖错位——这里把整学期都走一遍。
      for (var week = 1; week <= 20; week++) {
        final monday = firstMonday.add(Duration(days: 7 * (week - 1)));
        expect(
          AcademicWeekCalculator.weekNumber(
            firstWeekMonday: firstMonday,
            date: monday,
          ),
          week,
          reason: '第 $week 周的周一应当算作第 $week 周',
        );
        expect(
          AcademicWeekCalculator.firstWeekMonday(
            referenceDate: monday,
            weekNumber: week,
          ),
          firstMonday,
          reason: '第 $week 周反推第一周必须回到同一天',
        );
        // 同周的周日也必须算作同一周（否则周末的课会被算到下一周）。
        for (var offset = 0; offset < 7; offset++) {
          final day = monday.add(Duration(days: offset));
          expect(
            AcademicWeekCalculator.weekNumber(
              firstWeekMonday: firstMonday,
              date: day,
            ),
            week,
            reason: '第 $week 周的第 ${offset + 1} 天应当仍是第 $week 周',
          );
        }
      }
    });

    test('M6 非法日期：非周一的第一周日期、非正周数、超范围总周数都被拒绝', () {
      // 第一周必须是周一。
      for (final weekday in [DateTime.tuesday, DateTime.sunday]) {
        expect(
          () => AcademicWeekCalculator.firstWeekMonday(
            referenceDate: DateTime(2026, 9, 7 + weekday - 1),
            weekNumber: 0,
          ),
          throwsArgumentError,
          reason: '非正周数必须拒绝',
        );
      }
      expect(
        () => AcademicWeekCalculator.firstWeekMonday(
          referenceDate: DateTime(2026, 10, 5),
          weekNumber: -3,
        ),
        throwsArgumentError,
      );
      // 第一周之前的日期不能算出周数（0 或负数都没有意义）。
      expect(
        () => AcademicWeekCalculator.weekNumber(
          firstWeekMonday: DateTime(2026, 9, 7),
          date: DateTime(2026, 9, 1),
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
