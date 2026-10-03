import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// C8 的验证分两层。
///
/// 本文件验证**服务契约**：恢复例外以一次性输入交给提案生成器，而不是先写进设置。
/// 服务已不再持有 `SettingsService`（技术设计 Task 11 声明的依赖里本就没有它），
/// 因此"预览不落库"由编译器保证，而不是靠一条容易被绕过的断言。
///
/// "例外确实改变了排程输入、且真的没有在设置里留下痕迹"由
/// `repository_schedule_problem_source_test.dart` 在真实装配链路（真实
/// `SettingsService` + 真实 `RepositoryScheduleProblemSource`）上验证。
void main() {
  test('活动延长到 01:00 后保护 7 小时睡眠且不移动早课', () async {
    final planning = _ProposalCreator();
    final service = RecoveryPlanningService(
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

    // 例外以一次性输入的形式进入提案：01:00–08:00，只作用于恢复当日。
    final override = planning.receivedOverride;
    expect(override, isNotNull);
    expect(override!.localDate, DateTime(2026, 10, 3));
    expect(
      override.patch.sleepRange,
      LocalTimeRange(startMinute: 60, endMinute: 480),
    );
    expect(override.patch.minimumSleepMinutes, isNull);
  });

  test('明确单次接受较短睡眠只缩短当日恢复窗口', () async {
    final planning = _ProposalCreator();
    final service = RecoveryPlanningService(
      planning: planning,
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

    // 较短睡眠只写进本次提案输入，不写长期作息。
    final override = planning.receivedOverride;
    expect(override, isNotNull);
    expect(override!.patch.minimumSleepMinutes, 360);
    expect(
      override.patch.sleepRange,
      LocalTimeRange(startMinute: 60, endMinute: 7 * 60),
    );
  });

  test('接受的睡眠时长高于常规最低值被拒绝且不生成提案', () async {
    final planning = _ProposalCreator();
    final service = RecoveryPlanningService(
      planning: planning,
      zones: TimeZoneDatabase(),
    );

    await expectLater(
      service.createOverride(
        SpecialDayDraft(
          recoveryDate: DateTime(2026, 10, 3),
          actualEndUtc: DateTime.utc(2026, 10, 2, 17),
          timeZoneId: 'Asia/Shanghai',
          rules: DefaultSettings.v1(),
          fixedEvents: const [],
          resolution: RecoveryResolution.acceptShorterSleep,
          acceptedSleepMinutes: 480,
        ),
      ),
      throwsA(isA<SettingsValidationException>()),
    );
    expect(planning.calls, 0);
  });
}

final class _ProposalCreator implements ProposalCreator {
  int calls = 0;
  ScheduleRuleOverride? receivedOverride;

  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
  }) async {
    calls++;
    receivedOverride = override;
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
      ruleOverride: override,
    );
  }
}
