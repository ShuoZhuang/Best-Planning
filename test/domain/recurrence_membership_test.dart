// Task 8（课程编辑完整性修复计划 §2.4）：**规则成员判定的纯函数边界矩阵**。
//
// 这个函数是"这一次会不会发生"的**唯一**判据：展开器与课程编辑的例外清理都必须调用它。
// 它此前存在两份不同步的实现（展开器内联一份、清理另一套条件），而两份漂开的后果是
// "预览说保留、保存却删了"——用户按下确认的唯一依据就是预览（计划 §2.5）。
//
// 纯函数测试的价值在于**边界可以逐格钉住**，不受数据库、时钟或界面影响。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/services/recurrence_membership.dart';

void main() {
  RecurrenceRule rule({
    Set<int> weekdays = const {DateTime.monday},
    int intervalWeeks = 1,
    required DateTime from,
    DateTime? until,
    String timeZoneId = 'Asia/Shanghai',
  }) => RecurrenceRule(
    id: 'rule',
    weekdays: weekdays,
    localStartMinute: 8 * 60,
    durationMinutes: 45,
    intervalWeeks: intervalWeeks,
    validFromLocalDate: from,
    validUntilLocalDate: until,
    timeZoneId: timeZoneId,
  );

  group('有效期两端（闭区间）', () {
    final subject = rule(
      from: DateTime(2026, 9, 7),
      // 2026-12-14 是周一（09-07 之后的第 14 周），因此"结束日"本身就是一个正常发生日。
      until: DateTime(2026, 12, 14),
    );

    test('起始日本身是成员', () {
      expect(recurrenceIncludesLocalDate(subject, DateTime(2026, 9, 7)), isTrue);
    });

    test('结束日本身是成员（闭区间，不是半开区间）', () {
      expect(
        recurrenceIncludesLocalDate(subject, DateTime(2026, 12, 14)),
        isTrue,
        reason: '日期有效期是 [validFrom, validUntil]——把结束日排除会让最后一节课消失',
      );
    });

    test('结束日的次日不是成员', () {
      expect(
        recurrenceIncludesLocalDate(subject, DateTime(2026, 12, 21)),
        isFalse,
      );
    });

    test('起始日的前一天不是成员', () {
      expect(
        recurrenceIncludesLocalDate(subject, DateTime(2026, 9, 6)),
        isFalse,
      );
    });

    test('无 validUntil 时只看起始日与星期', () {
      final open = rule(from: DateTime(2026, 9, 7));
      expect(recurrenceIncludesLocalDate(open, DateTime(2030, 1, 7)), isTrue);
    });

    test('带时刻的输入按日历日判定（取 date-only）', () {
      expect(
        recurrenceIncludesLocalDate(subject, DateTime(2026, 9, 7, 23, 59)),
        isTrue,
        reason: '规则只按日历日生效；把时刻也参与比较会让"当天晚上"落选',
      );
    });
  });

  group('星期', () {
    test('错误星期不是成员', () {
      final monday = rule(from: DateTime(2026, 9, 7));
      expect(recurrenceIncludesLocalDate(monday, DateTime(2026, 9, 8)), isFalse);
    });

    test('规则可以同时覆盖多天', () {
      final both = rule(
        weekdays: const {DateTime.monday, DateTime.thursday},
        from: DateTime(2026, 9, 7),
      );
      expect(recurrenceIncludesLocalDate(both, DateTime(2026, 9, 7)), isTrue);
      expect(recurrenceIncludesLocalDate(both, DateTime(2026, 9, 10)), isTrue);
      expect(recurrenceIncludesLocalDate(both, DateTime(2026, 9, 11)), isFalse);
    });

    test('周日也是正常的一天（weekday == 7）', () {
      final sunday = rule(
        weekdays: const {DateTime.sunday},
        from: DateTime(2026, 9, 6),
      );
      expect(recurrenceIncludesLocalDate(sunday, DateTime(2026, 9, 6)), isTrue);
      expect(recurrenceIncludesLocalDate(sunday, DateTime(2026, 9, 7)), isFalse);
    });
  });

  group('单双周（周偏移）', () {
    final biweekly = rule(
      intervalWeeks: 2,
      from: DateTime(2026, 9, 7),
    );

    test('起始周是成员，间隔周不是，再下一周又是', () {
      expect(recurrenceIncludesLocalDate(biweekly, DateTime(2026, 9, 7)), isTrue);
      expect(
        recurrenceIncludesLocalDate(biweekly, DateTime(2026, 9, 14)),
        isFalse,
        reason: '间隔周',
      );
      expect(
        recurrenceIncludesLocalDate(biweekly, DateTime(2026, 9, 21)),
        isTrue,
      );
    });

    test('起始日之前的那一周不是成员（周偏移为负）', () {
      expect(
        recurrenceIncludesLocalDate(biweekly, DateTime(2026, 8, 31)),
        isFalse,
      );
    });

    test('每 3 周：第 1、4、7 周是成员', () {
      final everyThird = rule(
        intervalWeeks: 3,
        from: DateTime(2026, 9, 7),
      );
      expect(recurrenceIncludesLocalDate(everyThird, DateTime(2026, 9, 7)), isTrue);
      expect(
        recurrenceIncludesLocalDate(everyThird, DateTime(2026, 9, 14)),
        isFalse,
      );
      expect(
        recurrenceIncludesLocalDate(everyThird, DateTime(2026, 9, 21)),
        isFalse,
      );
      expect(
        recurrenceIncludesLocalDate(everyThird, DateTime(2026, 9, 28)),
        isTrue,
      );
    });

    test('跨年不重置周偏移', () {
      final acrossYear = rule(from: DateTime(2026, 12, 21), intervalWeeks: 2);
      // 12-21 是周一；+2 周 = 2027-01-04。
      expect(
        recurrenceIncludesLocalDate(acrossYear, DateTime(2026, 12, 28)),
        isFalse,
      );
      expect(
        recurrenceIncludesLocalDate(acrossYear, DateTime(2027, 1, 4)),
        isTrue,
      );
    });
  });

  group('夏令时（小时数不等于 24 的那一周）', () {
    test('America/New_York 切换周里，隔一周仍然算作"隔了一周"', () {
      // 2026-03-08 是美东夏令时切换日（当地 02:00 → 03:00）。
      // 本地零点相减在那一周只有 167 小时，`difference().inDays` 会得到 6——
      // 于是"隔一周"被算成"同一周"，第 3 周的那次课凭空消失。
      final dst = rule(
        intervalWeeks: 2,
        from: DateTime(2026, 3, 2),
        timeZoneId: 'America/New_York',
      );
      expect(recurrenceIncludesLocalDate(dst, DateTime(2026, 3, 2)), isTrue);
      expect(recurrenceIncludesLocalDate(dst, DateTime(2026, 3, 9)), isFalse);
      expect(
        recurrenceIncludesLocalDate(dst, DateTime(2026, 3, 16)),
        isTrue,
        reason: '切换之后的第二周必须仍被算作"隔了一周"',
      );
    });

    test('weekMondayUtc 对同一周的任意一天给出同一个周一', () {
      final monday = weekMondayUtc(DateTime(2026, 3, 2));
      expect(weekMondayUtc(DateTime(2026, 3, 8)), monday);
      expect(weekMondayUtc(DateTime(2026, 3, 9)), isNot(monday));
      expect(monday.weekday, DateTime.monday);
    });
  });
}
