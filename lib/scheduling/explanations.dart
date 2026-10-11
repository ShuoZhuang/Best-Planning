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
};

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
