import 'dart:collection';

import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

enum RecoveryResolution {
  rescheduleMovableTasks,
  cancelMovableTasks,
  scheduleRecoverySleep,
  acceptShorterSleep,
}

final class SpecialDayDraft {
  SpecialDayDraft({
    required this.recoveryDate,
    required this.actualEndUtc,
    required this.timeZoneId,
    required this.rules,
    required List<CalendarOccurrence> fixedEvents,
    required this.resolution,
    this.acceptedSleepMinutes,
  }) : fixedEvents = UnmodifiableListView(List.of(fixedEvents)) {
    if (actualEndUtc.isUtc == false) {
      throw ArgumentError.value(actualEndUtc, 'actualEndUtc', 'Must be UTC.');
    }
    if (timeZoneId.trim().isEmpty) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId');
    }
    if (resolution == RecoveryResolution.acceptShorterSleep &&
        (acceptedSleepMinutes == null || acceptedSleepMinutes! <= 0)) {
      throw ArgumentError.value(
        acceptedSleepMinutes,
        'acceptedSleepMinutes',
        'Required when accepting shorter sleep.',
      );
    }
  }

  final DateTime recoveryDate;
  final DateTime actualEndUtc;
  final String timeZoneId;
  final PlanningRules rules;
  final List<CalendarOccurrence> fixedEvents;
  final RecoveryResolution resolution;
  final int? acceptedSleepMinutes;
}

final class RecoveryPlan {
  RecoveryPlan({
    required this.recoveryDate,
    required this.earliestSchedulableUtc,
    required this.sleepProtection,
    required List<PlanningConflict> conflicts,
    required List<CalendarOccurrence> fixedEventsToKeep,
    required this.proposalId,
  }) : conflicts = UnmodifiableListView(List.of(conflicts)),
       fixedEventsToKeep = UnmodifiableListView(List.of(fixedEventsToKeep));

  final DateTime recoveryDate;
  final DateTime earliestSchedulableUtc;
  final TimeRange sleepProtection;
  final List<PlanningConflict> conflicts;
  final List<CalendarOccurrence> fixedEventsToKeep;
  final String proposalId;
}

final class RecoveryPlanningService {
  const RecoveryPlanningService({required this.planning, required this.zones});

  final ProposalCreator planning;
  final TimeZoneDatabase zones;

  Future<RecoveryPlan> createOverride(SpecialDayDraft draft) async {
    final effectiveSleepMinutes = switch (draft.resolution) {
      RecoveryResolution.acceptShorterSleep => draft.acceptedSleepMinutes!,
      _ => draft.rules.minimumSleepMinutes,
    };
    if (effectiveSleepMinutes > draft.rules.minimumSleepMinutes &&
        draft.resolution == RecoveryResolution.acceptShorterSleep) {
      throw const SettingsValidationException({
        'acceptedSleepMinutes': '单次睡眠时长不应高于常规最低值',
      });
    }

    final earliest = draft.actualEndUtc.add(
      Duration(minutes: effectiveSleepMinutes),
    );
    final sleepProtection = TimeRange(
      startUtc: draft.actualEndUtc,
      endUtc: earliest,
    );
    final overlappingFixed = draft.fixedEvents
        .where((event) => event.locked && event.range.overlaps(sleepProtection))
        .toList(growable: false);
    final conflicts = overlappingFixed
        .map(
          (event) => PlanningConflict(
            code: ConflictCode.minimumSleepConflict,
            shortageMinutes: event.range.endUtc.isBefore(earliest)
                ? event.range.durationMinutes
                : earliest.difference(event.range.startUtc).inMinutes,
            relatedEntityIds: [event.eventId],
            details: {
              'title': event.title,
              'earliestSchedulableUtc': earliest.toIso8601String(),
              'fixedEventKept': true,
            },
          ),
        )
        .toList(growable: false);

    final localStart = zones.toLocal(draft.actualEndUtc, draft.timeZoneId);
    final localEnd = zones.toLocal(earliest, draft.timeZoneId);
    // 例外是**提案输入**，不是持久设置。
    //
    // 此前这里调用 `settings.saveDateOverride` 先把例外写进设置再生成提案，理由是
    // `SettingsService.resolveForDate` 会读取该例外，不先写入则提案不含当次恢复保护。
    // 但那样做等于"预览即落库"：用户只要生成过一次恢复方案（哪怕随后取消、从未应用），
    // 该日期的睡眠例外就会永久生效，而全库没有任何清除路径。需求 FR-RECOVERY-05 要求
    // 针对**单次事件**处理、FR-RECOVERY-06 要求特殊日数据不直接更新长期作息偏好，
    // 技术设计 §12 也要求"取消编辑不会污染数据库"，因此改为把例外作为一次性覆盖传入。
    final override = ScheduleRuleOverride(
      localDate: draft.recoveryDate,
      patch: PlanningRulesPatch(
        sleepRange: LocalTimeRange(
          startMinute: localStart.hour * 60 + localStart.minute,
          endMinute: localEnd.hour * 60 + localEnd.minute,
        ),
        minimumSleepMinutes:
            draft.resolution == RecoveryResolution.acceptShorterSleep
            ? effectiveSleepMinutes
            : null,
      ),
    );

    final proposal = await planning.createProposal(override: override);
    return RecoveryPlan(
      recoveryDate: draft.recoveryDate,
      earliestSchedulableUtc: earliest,
      sleepProtection: sleepProtection,
      conflicts: conflicts,
      fixedEventsToKeep: overlappingFixed,
      proposalId: proposal.proposalId,
    );
  }
}
