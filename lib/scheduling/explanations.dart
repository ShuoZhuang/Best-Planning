import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

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
  // 用户第 72 轮要求的文案（原文）："无法按要求延后，当前计划未更改。"
  ConflictCode.requestedAdjustmentUnsatisfied => '无法按要求延后，当前计划未更改',
};

/// 一条 `invalidInput` 的**具体**说法（1.8.0，2026-10-12 故障；冻结决策 §1.4）。
///
/// **为什么必须有它**：截图里的第四件事是"点击确认后只提示『计划未通过校验，未应用』，
/// 没有指出具体块与具体规则"。用户看到的是**一句无法行动的话**。
/// 一个笼统的 `invalidInput` 至少对应五种完全不同的处置：
///
/// | 原因 | 用户该做什么 |
/// | --- | --- |
/// | [InvalidInputReason.startsBeforePlanningWindow] | 重新生成（历史块不该出现在这里） |
/// | [InvalidInputReason.endsAfterPlanningWindow] | 缩短片段或改规划范围 |
/// | [InvalidInputReason.unknownTask] | 任务已被删除 ⇒ 重新生成 |
/// | [InvalidInputReason.chunkBelowMinimum] | 调小"最小片段"设置或加长时间 |
/// | [InvalidInputReason.chunkAboveMaximum] | 调大"最大片段"设置 |
/// | [InvalidInputReason.offGranularity] | 时间块没有对齐排程粒度 |
///
/// **`reason` 为空时的回落**是 [conflictLabel] 的"排程输入无效"——
/// 但那只应发生在**旧提案**上（枚举是新增字段），不是正常路径。
String invalidInputLabel(InvalidInputReason? reason) => switch (reason) {
  InvalidInputReason.unknownTask => '任务已不存在',
  InvalidInputReason.startsBeforePlanningWindow => '时间块早于本次规划范围',
  InvalidInputReason.endsAfterPlanningWindow => '时间块晚于本次规划范围',
  InvalidInputReason.chunkBelowMinimum => '片段短于允许值',
  InvalidInputReason.chunkAboveMaximum => '片段长于允许值',
  InvalidInputReason.offGranularity => '时间块没有对齐排程粒度',
  null => '排程输入无效',
};

/// 把一条**完整冲突**翻成用户能据以行动的一句话（1.8.0，冻结决策 §1.4）。
///
/// **这里是唯一的翻译链**：`plan_preview_issues.dart` 与 `preview_failure_lines.dart`
/// 都调用它。此前两条路径各有一份 `conflictLabel(code)` 的 switch —— 抄一份就等于让
/// 同一条原因在两处显示成两句话（`explanations.dart` 的既有注释已经写明这条纪律）。
///
/// [taskTitle] 由调用方**批量解析后**传入（`TaskTitleLookup.titlesFor`），
/// 因此本函数只做字符串拼接，不查库、不知道任务长什么样。
/// **绝不显示 `relatedEntityIds`**（那是内部 id）。
String planningConflictMessage(
  PlanningConflict conflict, {
  required String taskTitle,
}) {
  final label = switch (conflict.code) {
    ConflictCode.invalidInput => invalidInputLabel(conflict.invalidInputReason),
    ConflictCode.insufficientCapacity =>
      conflict.shortageMinutes > 0
          ? '可用时间不足：还缺 ${conflict.shortageMinutes} 分钟'
          : '可用时间不足',
    _ => conflictLabel(conflict.code),
  };
  // 数字尽量带上：用户据此才知道"差多少"。
  final detail = switch (conflict.code) {
    ConflictCode.invalidInput => _chunkDetail(conflict.details),
    ConflictCode.scheduledDurationExceeded => _durationDetail(conflict.details),
    ConflictCode.dailyLimitExceeded => _dailyLimitDetail(conflict.details),
    _ => '',
  };
  // 有 taskId 时带上标题：同一条规则对不同任务意味着不同的下一步。
  final subject = conflict.taskId == null ? '' : '「$taskTitle」：';
  return '$subject$label$detail';
}

String _chunkDetail(Map<String, Object?> details) {
  final duration = details['durationMinutes'];
  final min = details['minChunkMinutes'];
  final max = details['maxChunkMinutes'];
  if (duration is! int) return '';
  if (min is int && max is int) {
    return '（这一块 $duration 分钟，允许 $min–$max 分钟）';
  }
  final granularity = details['granularityMinutes'];
  if (granularity is int) {
    return '（这一块 $duration 分钟，粒度 $granularity 分钟）';
  }
  return '（这一块 $duration 分钟）';
}

String _durationDetail(Map<String, Object?> details) {
  final scheduled = details['scheduledMinutes'];
  final required = details['requiredMinutes'];
  if (scheduled is! int || required is! int) return '';
  return '（已排 $scheduled 分钟，任务需要 $required 分钟）';
}

String _dailyLimitDetail(Map<String, Object?> details) {
  final scheduled = details['scheduledMinutes'];
  final limit = details['limitMinutes'];
  if (scheduled is! int || limit is! int) return '';
  return '（当天已排 $scheduled 分钟，上限 $limit 分钟）';
}

/// 把引擎给出的结构化原因翻译成一句用户能据以行动的话（Task 12A Step 6 第 5 条）。
///
/// **这里只翻译，不判断。** 归因由引擎负责（`UnscheduledReasonCode`），本函数不得据任务属性
/// 反过来猜原因——那正是这一步要消灭的东西。因此签名收的是 `UnscheduledReason`，
/// 而不是任务或提案。
///
/// 有 `requiredMinutes` / `availableMinutes` 的原因尽量把两个数写进句子里：用户据此才知道
/// "差多少"，而这决定了他是该调目标还是改截止时间。
///
/// **1.8.0 从 `features/planning/plan_preview_page.dart` 移到这里**（规范 §13.2）：
/// 延后失败也要走同一条翻译链，而那条链现在在 `scheduling/` 与 `app/router.dart` 里。
/// 留在 `features/` 会让 `scheduling/` 反过来 import 界面层——与 `MoveDraftSink`
/// 当初从 `features/` 挪进 `application/` 是同一个理由。
/// **不得出现第二份翻译**：抄一份就等于让同一条原因在两处显示成两句话。
String unscheduledReasonLabel(UnscheduledReason reason) =>
    switch (reason.code) {
      UnscheduledReasonCode.availableTimeNotReached =>
        reason.constraintLabel == null
            ? '还没到这件事可以开始的时间。'
            : '还没到这件事可以开始的时间（${reason.constraintLabel}）。',
      UnscheduledReasonCode.deadlineWindowTooShort => _withNumbers(
        '截止时间之前装不下一个片段',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '。',
      ),
      UnscheduledReasonCode.continuousGapTooShort => _withNumbers(
        '这件事需要一次做完',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '，但最长的一段空档不够长。',
      ),
      UnscheduledReasonCode.minimumChunkTooLarge => _withNumbers(
        '剩下的时间不够一个最短片段',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '。',
      ),
      UnscheduledReasonCode.dailyLimitReached => '已经达到这一天能安排的上限，剩下的时间排不进去了。',
      UnscheduledReasonCode.protectedTimeOccupied => '保护时间占住了这些时段，引擎不会挤占它。',
      UnscheduledReasonCode.fixedScheduleOccupied => '固定日程占住了这些时段。',
      UnscheduledReasonCode.lockedPlanOccupied =>
        reason.constraintLabel == null
            ? '这些时段已经被别的计划块占住了。'
            : '这些时段已经被${reason.constraintLabel}占住了。',
      UnscheduledReasonCode.requiredBreakUnavailable =>
        '排满就没有片段之间的休息时间，因此没有排进去。',
      UnscheduledReasonCode.insufficientCapacity => _withNumbers(
        '可用时间不足',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '。',
      ),
    };

String _withNumbers(
  String lead, {
  required int? required,
  required int? available,
  required String tail,
}) {
  if (required != null && available != null) {
    return '$lead：需要 $required 分钟，可用 $available 分钟$tail';
  }
  if (required != null) return '$lead：需要 $required 分钟$tail';
  return '$lead$tail';
}
