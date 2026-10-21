import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/recurring_cycle_capacity.dart';

/// Task 18 性能门禁：容量计算必须在大量硬占用下保持线性可用。
void main() {
  test('一年硬占用下重复计算容量不会退化', () {
    final start = DateTime.utc(2026, 1, 1);
    final busy = [
      for (var day = 0; day < 365; day++)
        TimeRange(
          startUtc: start.add(Duration(days: day, hours: 9)),
          endUtc: start.add(Duration(days: day, hours: 12)),
        ),
    ];
    final window = TimeRange(
      startUtc: start,
      endUtc: start.add(const Duration(days: 365)),
    );
    final stopwatch = Stopwatch()..start();
    var total = 0;
    for (var i = 0; i < 200; i++) {
      total += recurringLegalCapacityMinutes(
        window: window,
        busyIntervals: busy,
        minChunkMinutes: 25,
      );
    }
    stopwatch.stop();
    expect(total, greaterThan(0));
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: '200 次 × 365 个占用区间应在 5 秒内完成，实际 ${stopwatch.elapsed}',
    );
  });
}
