import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/special_day_planning_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();
const _zone = 'Asia/Shanghai';
final _date = DateTime(2026, 10, 17);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 17, 12);
}

/// 组装一个尊重 `ScheduleRuleOverride.dayException` 的问题，模拟生产装配层。
final class _Source implements ScheduleProblemSource {
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async {
    final rules = DefaultSettings.v1();
    final window = TimeRange(
      startUtc: _zones.localMidnightToUtc(_date, _zone),
      endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 19), _zone),
    );
    final exception = override?.dayException;
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: _zone,
      tasks: const [],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: {
        for (final entry in dailyPoliciesForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: _zone,
        ).entries)
          entry.key: DailySchedulingPolicy(
            localDate: entry.key,
            resolvedRules: entry.value.resolvedRules,
            softReserveTargetMinutes: 0,
            dayException: exception != null && exception.localDate == entry.key
                ? exception
                : null,
          ),
      },
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: _zones,
        window: window,
        rules: rules,
        timeZoneId: _zone,
      ),
      preferences: const PreferenceProfile(),
      inputHash: '',
      dayExceptions: [?exception],
    );
  }
}

void main() {
  late AppDatabase database;
  late DriftPlanRepository plans;
  late DriftDayExceptionRepository exceptions;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    plans = DriftPlanRepository(database, clock: const _Clock());
    exceptions = DriftDayExceptionRepository(database);
  });

  tearDown(() => database.close());

  test('特殊日确认与计划在同一提交中落库', () async {
    final settings = SettingsService(repository: MemorySettingsRepository());
    final planning = PlanningService(
      source: _Source(),
      engine: DeterministicScheduleEngine(_zones),
    );
    final application = PlanApplicationService(
      source: _Source(),
      repository: plans,
      zones: _zones,
    );
    final service = SpecialDayPlanningService(
      planning: planning,
      application: application,
      settings: settings,
      zones: _zones,
      timeZoneId: _zone,
      clock: const _Clock(),
    );

    final result = await service.confirm(
      localDate: _date,
      originalSleepStartOffsetMinutes: 1410,
      // 23:30 → 次日 01:00。
      temporarySleepStartOffsetMinutes: 1500,
      fixedWakeOffsetMinutes: 1890,
      recoveryChoice: RecoveryChoice.none,
    );

    expect(result.status, ApplyPlanStatus.applied);
    final saved = await exceptions.findConfirmed(_date);
    expect(saved, isNotNull);
    expect(saved!.status, DayExceptionStatus.confirmed);
    expect(saved.temporarySleepStartOffsetMinutes, 1500);
    final versions = await database.select(database.planVersions).get();
    expect(versions, hasLength(1));
    expect(versions.single.algorithmVersion, '20');
  });

  test('恢复选择 nextDayRest 在同一事务里写保护休息块', () async {
    final settings = SettingsService(repository: MemorySettingsRepository());
    final planning = PlanningService(
      source: _Source(),
      engine: DeterministicScheduleEngine(_zones),
    );
    final application = PlanApplicationService(
      source: _Source(),
      repository: plans,
      zones: _zones,
    );
    final service = SpecialDayPlanningService(
      planning: planning,
      application: application,
      settings: settings,
      zones: _zones,
      timeZoneId: _zone,
      clock: const _Clock(),
    );

    final result = await service.confirm(
      localDate: _date,
      originalSleepStartOffsetMinutes: 1410,
      temporarySleepStartOffsetMinutes: 1500,
      fixedWakeOffsetMinutes: 1890,
      recoveryChoice: RecoveryChoice.nextDayRest,
    );
    expect(result.status, ApplyPlanStatus.applied);
    final events = await database.select(database.calendarEvents).get();
    expect(events, hasLength(1));
    expect(events.single.kind, 'protected');
    expect(events.single.sourceKind, 'recovery');
    expect(events.single.title, '恢复休息');
  });

  test('低于绝对最低睡眠时不生成提案、不写任何行', () async {
    final settings = SettingsService(repository: MemorySettingsRepository());
    final planning = PlanningService(
      source: _Source(),
      engine: DeterministicScheduleEngine(_zones),
    );
    final application = PlanApplicationService(
      source: _Source(),
      repository: plans,
      zones: _zones,
    );
    final service = SpecialDayPlanningService(
      planning: planning,
      application: application,
      settings: settings,
      zones: _zones,
      timeZoneId: _zone,
      clock: const _Clock(),
    );

    await expectLater(
      service.confirm(
        localDate: _date,
        originalSleepStartOffsetMinutes: 1410,
        temporarySleepStartOffsetMinutes: 1800,
        fixedWakeOffsetMinutes: 1890,
        recoveryChoice: RecoveryChoice.none,
      ),
      throwsArgumentError,
    );
    expect(await database.select(database.dayExceptions).get(), isEmpty);
    expect(await database.select(database.planVersions).get(), isEmpty);
  });
}
