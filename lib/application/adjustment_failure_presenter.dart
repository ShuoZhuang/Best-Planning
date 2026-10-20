import 'package:personal_planner/domain/models/adjustment_failure_evidence.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';

/// 面向用户的一条失败说明（计划 Task 12 Step 3）。
///
/// [retryable] 表示"重新生成可能成功"；`false` 表示需要用户改输入（截止、日期、上限），
/// 而不是反复点"重新生成"。
final class AdjustmentFailureMessage {
  const AdjustmentFailureMessage({
    required this.title,
    required this.explanation,
    required this.retryable,
  });

  final String title;
  final String explanation;
  final bool retryable;
}

/// 把结构化证据翻译成**可行动**的中文说明。
///
/// 优先级（计划 Task 12 Step 3）：计划已变化 → 硬时间边界（deadline/weekday）→
/// 固定/保护冲突 → 任务/全局上限 → 休息/片段要求 → 搜索预算 → 通用 invariant。
/// 同一份事实永远得到同一句话；**UI 与日志共用同一个 code**，文案只在展示层。
final class AdjustmentFailurePresenter {
  const AdjustmentFailurePresenter();

  AdjustmentFailureMessage present(AdjustmentFailureEvidence evidence) {
    final title = evidence.taskTitle.trim().isEmpty
        ? unnamedTaskTitle
        : evidence.taskTitle.trim();
    final shortage = evidence.shortageMinutes;
    final needMore = shortage != null && shortage > 0 ? '还差 $shortage 分钟。' : '';
    return switch (evidence.code) {
      PlanAdjustmentFailureCode.targetMissing => AdjustmentFailureMessage(
        title: '目标块已不存在',
        explanation: '这一块已经不在当前计划里，请刷新后重试。',
        retryable: false,
      ),
      PlanAdjustmentFailureCode.targetChanged ||
      PlanAdjustmentFailureCode.basePlanChanged => AdjustmentFailureMessage(
        title: '计划已变化',
        explanation: '当前计划或目标块已经改变，这次预览作废；请重新发起延后。',
        retryable: false,
      ),
      PlanAdjustmentFailureCode.targetIneligible => AdjustmentFailureMessage(
        title: '这一块不能延后',
        explanation: '它已经开始、完成、被锁定或所属任务已结束。',
        retryable: false,
      ),
      PlanAdjustmentFailureCode.deadlineExceeded => AdjustmentFailureMessage(
        title: '会超过截止时间',
        explanation:
            '“$title”的截止时间早于这次延后的最早可开始时间。'
            '请先调整截止时间，或选择更短的延后量。',
        retryable: false,
      ),
      PlanAdjustmentFailureCode.disallowedWeekday => AdjustmentFailureMessage(
        title: '目标日期不允许安排',
        explanation: '“$title”不允许排在目标日期；请换一天或修改任务的允许星期。',
        retryable: false,
      ),
      PlanAdjustmentFailureCode.fixedOrProtectedConflict =>
        AdjustmentFailureMessage(
          title: '与固定安排冲突',
          explanation:
              '目标时段被固定日程、课程或保护时间占用，且后续没有合法空档。'
              '$needMore',
          retryable: false,
        ),
      PlanAdjustmentFailureCode.taskDailyLimitReached =>
        AdjustmentFailureMessage(
          title: '超过任务单日上限',
          explanation: '“$title”在目标日已经达到每日可安排上限。$needMore',
          retryable: false,
        ),
      PlanAdjustmentFailureCode.globalDailyLimitReached =>
        AdjustmentFailureMessage(
          title: '超过全局单日上限',
          explanation: '目标日的总可安排时间已经用完。$needMore',
          retryable: false,
        ),
      PlanAdjustmentFailureCode.requiredBreakUnavailable =>
        AdjustmentFailureMessage(
          title: '缺少任务间休息',
          explanation: '目标日找不到同时满足休息间隔的位置。$needMore',
          retryable: false,
        ),
      PlanAdjustmentFailureCode.searchBudgetExhausted =>
        AdjustmentFailureMessage(
          title: '未在计算限制内找到方案',
          explanation: '搜索预算已经用完，**不能断言没有合法位置**。可以重新生成一次。',
          retryable: true,
        ),
      PlanAdjustmentFailureCode.fulfilmentMissing => AdjustmentFailureMessage(
        title: '延后没有兑现',
        explanation: '方案里找不到目标块的延续安排，因此不能应用。',
        retryable: true,
      ),
      PlanAdjustmentFailureCode.fulfilmentDurationMismatch =>
        AdjustmentFailureMessage(
          title: '时长不一致',
          explanation: '延后后的总时长与原来不一致，因此不能应用。',
          retryable: true,
        ),
      PlanAdjustmentFailureCode.tokenMismatch ||
      PlanAdjustmentFailureCode.previewExpired => AdjustmentFailureMessage(
        title: '预览已过期',
        explanation: '这次预览已经失效；请按原意重新生成。',
        retryable: true,
      ),
      PlanAdjustmentFailureCode.concurrentModification =>
        AdjustmentFailureMessage(
          title: '计划正在被修改',
          explanation: '另一个操作先修改了计划，请稍后重试。',
          retryable: true,
        ),
      PlanAdjustmentFailureCode.noLegalSlot => AdjustmentFailureMessage(
        title: '没有合法位置',
        explanation: '在允许的日期与硬约束下没有能放下这一块的位置。$needMore',
        retryable: false,
      ),
      // 兜底：**内部异常不得伪装成"时间不足"**，也不给"重试就好"的暗示。
      PlanAdjustmentFailureCode.invariantViolation => AdjustmentFailureMessage(
        title: '生成出现异常',
        explanation: '排程结果违反内部不变量，当前计划未改变。请记录时间并反馈此问题。',
        retryable: false,
      ),
    };
  }
}
