import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  group('TimeRange', () {
    final start = DateTime.utc(2026, 10, 1, 9);
    final end = DateTime.utc(2026, 10, 1, 10);

    test('使用包含开始、不包含结束的半开区间', () {
      final range = TimeRange(startUtc: start, endUtc: end);

      expect(range.contains(start), isTrue);
      expect(range.contains(end), isFalse);
      expect(
        range.overlaps(
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 1, 9, 30),
            endUtc: DateTime.utc(2026, 10, 1, 10, 30),
          ),
        ),
        isTrue,
      );
      expect(
        range.overlaps(
          TimeRange(startUtc: end, endUtc: DateTime.utc(2026, 10, 1, 11)),
        ),
        isFalse,
      );
    });

    test('拒绝零时长、负时长和非 UTC 瞬时时间', () {
      expect(
        () => TimeRange(startUtc: start, endUtc: start),
        throwsArgumentError,
      );
      expect(
        () => TimeRange(startUtc: end, endUtc: start),
        throwsArgumentError,
      );
      expect(
        () => TimeRange(
          startUtc: DateTime(2026, 10, 1, 9),
          endUtc: DateTime(2026, 10, 1, 10),
        ),
        throwsArgumentError,
      );
    });
  });

  group('LocalTimeRange', () {
    test('把跨午夜范围拆为相邻两个本地日期片段', () {
      final range = LocalTimeRange(
        startMinute: 23 * 60 + 30,
        endMinute: 7 * 60 + 30,
      );

      expect(range.splitAtMidnight(), const [
        LocalDaySegment(dayOffset: 0, startMinute: 1410, endMinute: 1440),
        LocalDaySegment(dayOffset: 1, startMinute: 0, endMinute: 450),
      ]);
    });

    test('拒绝零长度和超出本地日边界的分钟数', () {
      expect(
        () => LocalTimeRange(startMinute: 60, endMinute: 60),
        throwsArgumentError,
      );
      expect(
        () => LocalTimeRange(startMinute: -1, endMinute: 60),
        throwsArgumentError,
      );
      expect(
        () => LocalTimeRange(startMinute: 60, endMinute: 1441),
        throwsArgumentError,
      );
    });
  });
}
