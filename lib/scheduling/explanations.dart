import 'package:personal_planner/scheduling/plan_validator.dart';

/// 片段解释码对应的中文说明。
///
/// 引擎只输出稳定的 `explanationCode`，用户可见文案集中在这里维护，避免把
/// 不可测试的自由文本写进引擎。
String explanationLabel(String code) => switch (code) {
  'deadline_and_progress' => '截止压力与推进进度',
  'life_quota_gap' => '生活娱乐配额不足',
  'energy_match' => '与精力区间匹配',
  'priority' => '优先级较高',
  _ => '排程调整',
};

String conflictLabel(ConflictCode code) => switch (code) {
  ConflictCode.insufficientCapacity => '可用时间不足',
  ConflictCode.fixedEventOverlap => '与固定日程重叠',
  ConflictCode.protectedTimeOverlap => '占用了保护时间',
  ConflictCode.lockedBlockMoved => '锁定时间块被移动',
  ConflictCode.blockOverlap => '任务时间块相互重叠',
  ConflictCode.continuousBlockUnavailable => '连续任务被拆分',
  ConflictCode.dailyLimitExceeded => '超过每日任务上限',
  ConflictCode.scheduledDurationExceeded => '安排时长超过任务所需时长',
  ConflictCode.minimumSleepConflict => '最低睡眠与固定安排冲突',
  ConflictCode.staleProposal => '计划已过期，需要重新计算',
  ConflictCode.invalidInput => '排程输入无效',
};
