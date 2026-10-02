import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  test('活动延长到 01:00 后保护 7 小时睡眠且不移动早课', () async {
    final settings = SettingsService(repository: MemorySettingsRepository());
    final planning = _ProposalCreator();
    final service = RecoveryPlanningService(
      settings: settings,
      planning: planning,
      zones: TimeZoneDatabase(),
    );
    final earlyClass = CalendarOccurrence(
      eventId: 'class-1',
      title: '早课',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 23, 30),
        endUtc: DateTime.utc(2026, 10, 3, 1),
      ),
      locked: true,
    );

    final result = await service.createOverride(
      SpecialDayDraft(
        recoveryDate: DateTime(2026, 10, 3),
        actualEndUtc: DateTime.utc(2026, 10, 2, 17),
        timeZoneId: 'Asia/Shanghai',
        rules: DefaultSettings.v1(),
        fixedEvents: [earlyClass],
        resolution: RecoveryResolution.scheduleRecoverySleep,
      ),
    );

    expect(result.earliestSchedulableUtc, DateTime.utc(2026, 10, 3));
    expect(result.sleepProtection.durationMinutes, 420);
    expect(result.conflicts, hasLength(1));
    expect(result.conflicts.single.code, ConflictCode.minimumSleepConflict);
    expect(result.conflicts.single.relatedEntityIds, contains('class-1'));
    expect(result.fixedEventsToKeep, contains(earlyClass));
    expect(planning.calls, 1);

    final recoveryDay = await settings.resolveForDate(DateTime(2026, 10, 3));
    expect(
      recoveryDay.rules.sleepRange,
      LocalTimeRange(startMinute: 60, endMinute: 8 * 60),
    );
    final normalDay = await settings.resolveForDate(DateTime(2026, 10, 4));
    expect(normalDay.rules.sleepRange, DefaultSettings.v1().sleepRange);
  });

  test('明确单次接受较短睡眠只缩短当日恢复窗口', () async {
    final settings = SettingsService(repository: MemorySettingsRepository());
    final service = RecoveryPlanningService(
      settings: settings,
      planning: _ProposalCreator(),
      zones: TimeZoneDatabase(),
    );

    final result = await service.createOverride(
      SpecialDayDraft(
        recoveryDate: DateTime(2026, 10, 3),
        actualEndUtc: DateTime.utc(2026, 10, 2, 17),
        timeZoneId: 'Asia/Shanghai',
        rules: DefaultSettings.v1(),
        fixedEvents: const [],
        resolution: RecoveryResolution.acceptShorterSleep,
        acceptedSleepMinutes: 360,
      ),
    );

    expect(result.earliestSchedulableUtc, DateTime.utc(2026, 10, 2, 23));
    expect(result.sleepProtection.durationMinutes, 360);
    expect(result.conflicts, isEmpty);
    expect(
      (await settings.resolveForDate(DateTime(2026, 10, 4)))
          .rules
          .minimumSleepMinutes,
      420,
    );
  });
}

final class _ProposalCreator implements ProposalCreator {
  int calls = 0;

  @override
  Future<ScheduleProposal> createProposal() async {
    calls++;
    return ScheduleProposal(
      proposalId: 'recovery-proposal',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: const [],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 0,
        unscheduledMinutes: 0,
      ),
    );
  }
}
