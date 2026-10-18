import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 确认特殊日时一并提交的**恢复效果**（规范 §8.4 / ALG20-051）。
///
/// 四项走四条不同路径，绝不共用一个"写设置"的兜底：
/// - [RecoveryChoice.nextDayRest]：次日一段保护休息块；
/// - [RecoveryChoice.nextNightEarlierSleep]：次日晚间提前入睡；
/// - [RecoveryChoice.reduceNextDayLoad]：次日可移动负载上限降低；
/// - [RecoveryChoice.none]：不写任何恢复效果。
final class RecoveryCommitEffect {
  const RecoveryCommitEffect({
    required this.choice,
    required this.nextLocalDate,
    this.protectedRestUtc,
    this.nextNightSleepStartMinute,
    this.nextDayMovableLoadCapMinutes,
    this.timeZoneId = 'UTC',
    this.title = '恢复休息',
  });

  final RecoveryChoice choice;
  final DateTime nextLocalDate;
  final TimeRange? protectedRestUtc;
  final int? nextNightSleepStartMinute;
  final int? nextDayMovableLoadCapMinutes;
  final String timeZoneId;
  final String title;
}

/// 一次"计划 + 特殊日 + 恢复效果 + 审计"的统一提交请求（规范 §8.3）。
final class PlanningCommitRequest {
  const PlanningCommitRequest({
    required this.proposal,
    required this.expectedInputHash,
    this.confirmedDayException,
    this.recoveryEffect,
  });

  final ScheduleProposal proposal;
  final String expectedInputHash;
  final DayException? confirmedDayException;
  final RecoveryCommitEffect? recoveryEffect;
}

/// 唯一事务提交端口。普通应用与特殊日确认共用同一段数据库事务。
abstract interface class PlanningCommitRepository {
  Future<ApplyPlanResult> commit(PlanningCommitRequest request);
}
