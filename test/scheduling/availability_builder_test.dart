import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';

void main() {
  test('扣除睡眠、午餐、课程和锁定块后应用每日六小时上限', () {
    final zones = TimeZoneDatabase();
    const zoneId = 'Asia/Shanghai';
    final localDate = DateTime(2026, 10, 2);
    DateTime at(int hour, [int minute = 0]) =>
        zones.localDateTimeToUtc(localDate, hour * 60 + minute, zoneId);

    final fixed = [TimeRange(startUtc: at(9), endUtc: at(11))];
    final protected = [TimeRange(startUtc: at(12), endUtc: at(13))];
    final locked = [TimeRange(startUtc: at(15), endUtc: at(16))];
    final slots = AvailabilityBuilder(zones).build(
      AvailabilityInput(
        planningWindow: TimeRange(
          startUtc: zones.localMidnightToUtc(localDate, zoneId),
          endUtc: zones.localMidnightToUtc(
            localDate.add(const Duration(days: 1)),
            zoneId,
          ),
        ),
        timeZoneId: zoneId,
        rules: DefaultSettings.v1(),
        fixedIntervals: fixed,
        protectedIntervals: protected,
        lockedBlocks: locked,
      ),
    );

    expect(slots.fold<int>(0, (sum, slot) => sum + slot.durationMinutes), 360);
    expect(slots.first.startUtc, at(7, 30));
    expect(slots.last.endUtc, at(17, 30));

    final allBusy = [...fixed, ...protected, ...locked];
    for (var index = 0; index < slots.length; index++) {
      expect(allBusy.any((busy) => slots[index].range.overlaps(busy)), isFalse);
      if (index > 0) {
        expect(slots[index - 1].range.overlaps(slots[index].range), isFalse);
      }
    }
  });

  test('合并重叠忙碌区间并保持半开边界可相邻', () {
    final zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 2, 8),
      endUtc: DateTime.utc(2026, 10, 2, 12),
    );
    final rules = DefaultSettings.v1().copyWith(
      sleepRange: LocalTimeRange(startMinute: 12 * 60, endMinute: 8 * 60),
      dailyMovableTaskLimitMinutes: 240,
    );

    final slots = AvailabilityBuilder(zones).build(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: 'UTC',
        rules: rules,
        fixedIntervals: [
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 9),
            endUtc: DateTime.utc(2026, 10, 2, 10),
          ),
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 9, 30),
            endUtc: DateTime.utc(2026, 10, 2, 11),
          ),
        ],
      ),
    );

    expect(slots.map((slot) => slot.range).toList(), [
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 8),
        endUtc: DateTime.utc(2026, 10, 2, 9),
      ),
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 11),
        endUtc: DateTime.utc(2026, 10, 2, 12),
      ),
    ]);
  });
}
