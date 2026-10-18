import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/extension_day_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/planning_commit_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 特殊日 / 临时延长日的**确认编排**（规范 §8.3）。
///
/// 它把三件事按固定顺序串起来，且**确认前零写入**：
/// 1. 在内存里构造 `confirmed` 特殊日事实；
/// 2. 用同一个事实作为一次性 `ScheduleRuleOverride.dayException` 生成提案；
/// 3. 调用 `PlanApplicationService.applySpecialDay`，由一个事务写入
///    特殊日、恢复效果、计划版本、块与审计。
final class SpecialDayPlanningService {
  const SpecialDayPlanningService({
    required this.planning,
    required this.application,
    required this.settings,
    required this.zones,
    required this.timeZoneId,
    required this.clock,
    this.dayExceptionService,
    this.problemSource,
    this.extensionDays,
  });

  final ProposalCreator planning;
  final PlanApplicationService application;
  final SettingsService settings;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final Clock clock;

  /// 配额 / 连续日 / 最低睡眠的**纯校验**端口；为空时只做模型校验（测试与轻装）。
  final DayExceptionService? dayExceptionService;

  /// 自定义延长日需要读取当前排程输入做硬边界校验；为空时不支持自定义。
  final ScheduleProblemSource? problemSource;

  final ExtensionDayService? extensionDays;

  /// 校验用户自选的日期与结束时间，并生成一份**带特殊日事实的预览提案**。
  ///
  /// **不写任何表**：提案只存在 `PlanningService` 的内存预览里；用户在预览页确认后，
  /// `PlanApplicationService.apply` 会看到 `confirmedDayException` 并走同一个事务。
  Future<ScheduleProposal> prepareCustom({
    required DateTime localDate,
    required int endMinute,
    required List<String> triggeringTaskIds,
    RecoveryChoice recoveryChoice = RecoveryChoice.none,
    DateTime? recoveryLocalDate,
    String source = 'extensionCustom',
  }) async {
    final sourcePort = problemSource;
    final extensionService = extensionDays;
    if (sourcePort == null || extensionService == null) {
      throw const DayExceptionValidationException({'custom': '自定义延长日未装配输入来源'});
    }
    if (endMinute < 0 || endMinute >= 24 * 60) {
      throw const DayExceptionValidationException({
        'endMinute': '结束时间必须在同一天 00:00–23:59 之间',
      });
    }
    final problem = await sourcePort.load();
    final date = normalize(localDate);
    if (!problem.dailyPolicies.containsKey(date)) {
      throw const DayExceptionValidationException({
        'localDate': '该日期不在本次规划窗口内',
      });
    }
    final rules = problem.policyForLocalDate(date).resolvedRules;
    final sleep = rules.sleepRange;
    final original = sleep.startMinute;
    // 凌晨结束属于**次日**的入睡时刻（例如 01:00 ⇒ 1500），与页面口径一致。
    final temporary = endMinute < 12 * 60 ? endMinute + 24 * 60 : endMinute;
    final fixedWake = sleep.endMinute + (sleep.crossesMidnight ? 24 * 60 : 0);
    final candidate = await extensionService.customCandidate(
      problem: problem,
      localDate: date,
      temporarySleepStartOffsetMinutes: temporary,
      triggeringTaskIds: triggeringTaskIds,
    );
    final now = clock.nowUtc();
    final exception = DayException(
      id:
          'day:${formatLocalDate(date)}:temporaryExtensionDay:'
          '${now.microsecondsSinceEpoch}',
      localDate: date,
      kind: DayExceptionKind.temporaryExtensionDay,
      status: DayExceptionStatus.confirmed,
      originalSleepStartOffsetMinutes: original,
      temporarySleepStartOffsetMinutes: temporary,
      fixedWakeOffsetMinutes: fixedWake,
      absoluteMinimumSleepMinutes: await settings
          .loadAbsoluteMinimumSleepMinutes(),
      recoveryChoice: recoveryChoice,
      source: source,
      createdAtUtc: now,
      updatedAtUtc: now,
      triggeringProposalId: null,
      recoveryLocalDate: recoveryChoice == RecoveryChoice.none
          ? null
          : normalize(
              recoveryLocalDate ??
                  DateTime(date.year, date.month, date.day + 1),
            ),
      auditNote: 'customCandidate.added=${candidate.addedPlaceableMinutes}',
    );
    await dayExceptionService?.validateForConfirmation(exception);
    final proposal = await planning.createProposal(
      override: ScheduleRuleOverride(
        localDate: date,
        patch: const PlanningRulesPatch(),
        dayException: exception,
      ),
    );
    RecoveryCommitEffect? effect;
    if (recoveryChoice != RecoveryChoice.none) {
      final nextDate = DateTime(date.year, date.month, date.day + 1);
      final nextRules = (await settings.resolveForDate(nextDate)).rules;
      effect = RecoveryPlanningService(planning: planning, zones: zones)
          .planRecoveryEffect(
            choice: recoveryChoice,
            nextLocalDate: nextDate,
            rules: nextRules,
            timeZoneId: timeZoneId,
          );
    }
    return proposal.withDayException(exception, recoveryEffect: effect);
  }

  Future<ApplyPlanResult> confirm({
    required DateTime localDate,
    required int temporarySleepStartOffsetMinutes,
    required int fixedWakeOffsetMinutes,
    int? originalSleepStartOffsetMinutes,
    RecoveryChoice recoveryChoice = RecoveryChoice.none,
    DateTime? recoveryLocalDate,
    RecoveryCommitEffect? recoveryEffect,
    String source = 'specialDayPage',
    String? triggeringProposalId,
    String auditNote = '',
  }) async {
    final date = normalize(localDate);
    final minimumSleep = await settings.loadAbsoluteMinimumSleepMinutes();
    final now = clock.nowUtc();
    final original =
        originalSleepStartOffsetMinutes ??
        // 没有显式原入睡时间时退化到"临时时间 − 1 小时"，仍保持有序；
        // 页面应当传真实值，测试与快速确认可用这个兜底。
        (temporarySleepStartOffsetMinutes - 60).clamp(0, 48 * 60);
    final exception = DayException(
      id:
          'day:${formatLocalDate(date)}:temporaryExtensionDay:'
          '${now.microsecondsSinceEpoch}',
      localDate: date,
      kind: DayExceptionKind.temporaryExtensionDay,
      status: DayExceptionStatus.confirmed,
      originalSleepStartOffsetMinutes: original,
      temporarySleepStartOffsetMinutes: temporarySleepStartOffsetMinutes,
      fixedWakeOffsetMinutes: fixedWakeOffsetMinutes,
      absoluteMinimumSleepMinutes: minimumSleep,
      recoveryChoice: recoveryChoice,
      source: source,
      createdAtUtc: now,
      updatedAtUtc: now,
      triggeringProposalId: triggeringProposalId,
      recoveryLocalDate: recoveryChoice == RecoveryChoice.none
          ? null
          : normalize(
              recoveryLocalDate ??
                  DateTime(date.year, date.month, date.day + 1),
            ),
      auditNote: auditNote,
    );
    exception.requireMinimumSleep(zones, timeZoneId);
    await dayExceptionService?.validateForConfirmation(exception);

    final proposal = await planning.createProposal(
      override: ScheduleRuleOverride(
        localDate: date,
        patch: const PlanningRulesPatch(),
        dayException: exception,
      ),
    );
    var effect = recoveryEffect;
    if (effect == null && recoveryChoice != RecoveryChoice.none) {
      final nextDate = DateTime(date.year, date.month, date.day + 1);
      final nextRules = (await settings.resolveForDate(nextDate)).rules;
      effect = RecoveryPlanningService(planning: planning, zones: zones)
          .planRecoveryEffect(
            choice: recoveryChoice,
            nextLocalDate: nextDate,
            rules: nextRules,
            timeZoneId: timeZoneId,
          );
    }
    return application.applySpecialDay(
      proposal,
      dayException: exception,
      recoveryEffect: effect,
      // 特殊日是用户显式确认的动作；"部分计划"仍需用户在预览里另行授权，
      // 因此这里保持最保守的完整模式。
    );
  }
}
