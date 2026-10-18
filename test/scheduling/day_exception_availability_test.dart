import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zone = 'Asia/Shanghai';
  final rules = DefaultSettings.v1();

  DayException exceptionOn(DateTime date) => DayException(
    id: 'day-1',
    localDate: date,
    kind: DayExceptionKind.userSpecialDay,
    status: DayExceptionStatus.confirmed,
    originalSleepStartOffsetMinutes: 23 * 60 + 30,
    // 23:30 延到次日 01:00。
    temporarySleepStartOffsetMinutes: 25 * 60,
    fixedWakeOffsetMinutes: 31 * 60 + 30,
    absoluteMinimumSleepMinutes: 6 * 60,
    recoveryChoice: RecoveryChoice.none,
    source: 'test',
    createdAtUtc: DateTime.utc(2026, 10, 1),
    updatedAtUtc: DateTime.utc(2026, 10, 1),
  );

  test('特殊日只覆盖当天睡眠开始，固定起床不变', () {
    final date = DateTime(2026, 10, 17);
    final value = exceptionOn(date);
    final intervals = ProtectedTimeExpander(zones).sleepForDate(
      localDate: date,
      rules: rules,
      timeZoneId: zone,
      dayException: value,
    );
    expect(intervals, hasLength(1));
    expect(
      intervals.single.range.startUtc,
      zones.localDateTimeToUtc(DateTime(2026, 10, 18), 60, zone),
    );
    expect(
      intervals.single.range.endUtc,
      zones.localDateTimeToUtc(DateTime(2026, 10, 18), 7 * 60 + 30, zone),
    );
  });

  test('AvailabilityBuilder 按特殊日放宽当天 23:30–01:00 并保留次日固定起床', () {
    final first = DateTime(2026, 10, 17);
    final second = DateTime(2026, 10, 18);
    final window = TimeRange(
      startUtc: zones.localMidnightToUtc(first, zone),
      endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 19), zone),
    );
    final value = exceptionOn(first);
    final analysis = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: zone,
        rules: rules,
        dailyPolicies: {
          first: DailySchedulingPolicy(
            localDate: first,
            resolvedRules: rules,
            softReserveTargetMinutes: 0,
            dayException: value,
          ),
          second: DailySchedulingPolicy(
            localDate: second,
            resolvedRules: rules,
            softReserveTargetMinutes: 0,
          ),
        },
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        chargedMovableBlocks: const [],
      ),
    );

    bool hasSlot(DateTime startLocal, int minutes) {
      final start = zones.localDateTimeToUtc(
        startLocal,
        startLocal.hour * 60 + startLocal.minute,
        zone,
      );
      final end = start.add(Duration(minutes: minutes));
      return analysis.slots.any(
        (slot) =>
            !slot.range.startUtc.isAfter(start) &&
            !slot.range.endUtc.isBefore(end),
      );
    }

    // 默认作息从 23:30 开始睡，特殊日把它推到次日 01:00。
    expect(hasSlot(DateTime(2026, 10, 17, 23, 30), 30), isTrue);
    expect(hasSlot(DateTime(2026, 10, 18, 0, 30), 30), isTrue);
    // 01:00–07:30 仍然是睡眠。
    expect(hasSlot(DateTime(2026, 10, 18, 1, 0), 60), isFalse);
    // 次日恢复为默认作息：23:30 起不可用。
    expect(hasSlot(DateTime(2026, 10, 18, 23, 30), 30), isFalse);
  });
}
