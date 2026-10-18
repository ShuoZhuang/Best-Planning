import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/extension_day_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final _zones = TimeZoneDatabase();
const _zone = 'Asia/Shanghai';
final _date = DateTime(2026, 10, 17);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _zones.localDateTimeToUtc(_date, 12 * 60, _zone);
}

ScheduleProblem _problem({List<BusyInterval> fixed = const []}) {
  final rules = DefaultSettings.v1().copyWith(
    sleepRange: LocalTimeRange(
      startMinute: 23 * 60 + 30,
      endMinute: 7 * 60 + 30,
    ),
  );
  final window = TimeRange(
    startUtc: _zones.localMidnightToUtc(_date, _zone),
    endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 19), _zone),
  );
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: _zone,
    tasks: [
      SchedulableTask(
        id: 'trigger',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
        dueAtUtc: _zones.localDateTimeToUtc(
          DateTime(2026, 10, 18),
          2 * 60,
          _zone,
        ),
      ),
    ],
    fixedIntervals: fixed,
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: {
      for (var index = 0; index < 2; index++)
        DateTime(2026, 10, 17 + index): DailySchedulingPolicy(
          localDate: DateTime(2026, 10, 17 + index),
          resolvedRules: rules,
          softReserveTargetMinutes: 0,
        ),
    },
    weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
    preferences: const PreferenceProfile(),
    inputHash: 'custom',
  );
}

void main() {
  late AppDatabase database;
  late ExtensionDayService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final dayService = DayExceptionService(
      repository: DriftDayExceptionRepository(database),
      settings: SettingsService(repository: MemorySettingsRepository()),
      clock: const _Clock(),
      zones: _zones,
      timeZoneId: _zone,
    );
    service = ExtensionDayService(
      settings: SettingsService(repository: MemorySettingsRepository()),
      dayExceptions: dayService,
      zones: _zones,
      clock: const _Clock(),
    );
  });

  tearDown(() => database.close());

  test('合法自定义时间返回候选并给出可增加分钟', () async {
    final candidate = await service.customCandidate(
      problem: _problem(),
      localDate: _date,
      temporarySleepStartOffsetMinutes: 1500,
      triggeringTaskIds: const ['trigger'],
    );
    expect(candidate.temporarySleepStartOffsetMinutes, 1500);
    expect(candidate.addedPlaceableMinutes, 60);
    expect(candidate.originalSleepStartOffsetMinutes, 1410);
  });

  test('与固定行程重叠时返回具体字段错误', () async {
    await expectLater(
      service.customCandidate(
        problem: _problem(
          fixed: [
            BusyInterval(
              id: 'late',
              range: TimeRange(
                startUtc: _zones.localDateTimeToUtc(
                  DateTime(2026, 10, 17),
                  23 * 60 + 45,
                  _zone,
                ),
                endUtc: _zones.localDateTimeToUtc(
                  DateTime(2026, 10, 18),
                  15,
                  _zone,
                ),
              ),
            ),
          ],
        ),
        localDate: _date,
        temporarySleepStartOffsetMinutes: 1500,
        triggeringTaskIds: const ['trigger'],
      ),
      throwsA(
        isA<DayExceptionValidationException>().having(
          (error) => error.fieldErrors.keys,
          'fields',
          contains('temporarySleepStartOffsetMinutes'),
        ),
      ),
    );
  });

  test('突破绝对最低睡眠时拒绝', () async {
    await expectLater(
      service.customCandidate(
        problem: _problem(),
        localDate: _date,
        temporarySleepStartOffsetMinutes: 1800,
        triggeringTaskIds: const ['trigger'],
      ),
      throwsA(isA<DayExceptionValidationException>()),
    );
  });

  test('窗口外日期与空触发任务都拒绝', () async {
    await expectLater(
      service.customCandidate(
        problem: _problem(),
        localDate: DateTime(2026, 10, 25),
        temporarySleepStartOffsetMinutes: 1500,
        triggeringTaskIds: const ['trigger'],
      ),
      throwsA(isA<DayExceptionValidationException>()),
    );
    await expectLater(
      service.customCandidate(
        problem: _problem(),
        localDate: _date,
        temporarySleepStartOffsetMinutes: 1500,
        triggeringTaskIds: const [],
      ),
      throwsA(isA<DayExceptionValidationException>()),
    );
  });
}
