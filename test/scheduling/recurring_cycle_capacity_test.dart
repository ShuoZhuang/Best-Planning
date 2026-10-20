import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/recurring_cycle_capacity.dart';
import 'package:personal_planner/scheduling/recurring_pace_curve.dart';

void main() {
  final cycle = TimeRange(
    startUtc: DateTime.utc(2026, 10, 19),
    endUtc: DateTime.utc(2026, 10, 26),
  );

  test('工作日被占满、周末空闲时，容量只算周末', () {
    final busy = [
      for (var day = 19; day <= 23; day++)
        TimeRange(
          startUtc: DateTime.utc(2026, 10, day, 0),
          endUtc: DateTime.utc(2026, 10, day + 1),
        ),
    ];
    expect(
      recurringLegalCapacityMinutes(
        window: cycle,
        busyIntervals: busy,
        minChunkMinutes: 25,
      ),
      2 * 24 * 60,
    );
  });

  test('短于最短片段的空档不计入合法容量', () {
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 19, 8),
      endUtc: DateTime.utc(2026, 10, 19, 10),
    );
    final busy = [
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 19, 8),
        endUtc: DateTime.utc(2026, 10, 19, 8, 50),
      ),
    ];
    expect(
      recurringLegalCapacityMinutes(
        window: window,
        busyIntervals: busy,
        minChunkMinutes: 30,
      ),
      70,
    );
    expect(
      recurringLegalCapacityMinutes(
        window: window,
        busyIntervals: busy,
        minChunkMinutes: 90,
      ),
      0,
    );
  });

  test('窗口剩余容量不足时 requiredNow 提前安排', () {
    final visible = TimeRange(
      startUtc: DateTime.utc(2026, 10, 24),
      endUtc: DateTime.utc(2026, 10, 26),
    );
    final decision = recurringPaceForCycle(
      remainingMinutes: 180,
      cycleRange: cycle,
      visibleWindow: visible,
      busyIntervals: const [],
      minChunkMinutes: 25,
      curve: RecurringPaceCurve.even,
    );
    expect(decision.capacityRatio, closeTo(1, 0.001));
    expect(decision.requiredNowMinutes, 180);
    expect(decision.targetNowMinutes, 180);
  });

  test('整周窗口内剩余量被容量上限约束，不超发', () {
    final decision = recurringPaceForCycle(
      remainingMinutes: 120,
      cycleRange: cycle,
      visibleWindow: cycle,
      busyIntervals: [
        TimeRange(
          startUtc: DateTime.utc(2026, 10, 19),
          endUtc: DateTime.utc(2026, 10, 20),
        ),
      ],
      minChunkMinutes: 25,
      curve: RecurringPaceCurve.even,
    );
    expect(decision.targetNowMinutes, 120);
  });

  test('每日可移动上限按本地日截断容量', () {
    final zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: zones.localMidnightToUtc(
        DateTime(2026, 10, 19),
        'Asia/Shanghai',
      ),
      endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 26), 'Asia/Shanghai'),
    );
    final total = recurringLegalCapacityMinutesWithDailyCap(
      window: window,
      busyIntervals: const [],
      minChunkMinutes: 25,
      maxMinutesPerDay: 60,
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
    );
    expect(total, 7 * 60);
  });
}
