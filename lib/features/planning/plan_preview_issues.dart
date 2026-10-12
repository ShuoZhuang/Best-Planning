import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show unnamedTaskLabel;
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

// 预览问题模型与**延后失败行**共用同一句占位文案（规范 §13.1）：
// 同一个概念只能有一个名字，因此这里把定义转发出去，而不是另写一份常量。
export 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show unnamedTaskLabel;

/// 一条预览问题的**严重级别**（1.8.0，2026-10-12 故障；冻结决策 §1.6）。
///
/// **为什么必须分级**：截图里"容量不足"（可以明确确认后部分应用）与
/// "排程输入无效"（结构性错误，绝不能写入）被渲染成同一张卡片、同一种图标，
/// 于是页面只能给出同一个可点击的"确认应用"。
///
/// 分级之后按钮状态由它派生，而不是由页面临时判断。
enum PreviewIssueSeverity {
  /// **可以带着它应用**（在用户明确确认之后）：容量缺口属于这一级。
  warning,

  /// **不得应用**：重叠、越界、锁定块被移动、非法输入……都属这一级。
  blocking,
}

/// 预览里的一条问题：**标题 ＋ 缺口 ＋ 具体原因**（冻结决策 §1.6）。
///
/// **为什么不再用 `List<String> conflicts`**：字符串丢掉了任务、块、数值与 invalid 原因
/// （R7），于是页面既说不清"是哪一件事"，也说不出"为什么"。
/// [key] 是**去重键**（稳定、可断言），不是给用户看的。
final class PreviewIssue {
  const PreviewIssue({
    required this.key,
    required this.severity,
    required this.title,
    required this.message,
  });

  /// 稳定的去重键。同一件事只能产生一个键。
  final String key;
  final PreviewIssueSeverity severity;
  final String title;
  final String message;

  bool get isBlocking => severity == PreviewIssueSeverity.blocking;
}

/// 一个块是否**属于前向预览**（1.8.0，冻结决策 §1.3）。
///
/// **两侧都要过滤**：只看提案那一侧不够——当前计划里的历史块会因为"提案里没有它"
/// 被 `PlanDiffer` 报成**移除**，于是用户看到昨天与今天已结束的安排被"删除"。
///
/// 判据是"与规划窗口相交"（半开区间）：
/// - 已结束的块（`end <= window.start`）⇒ 不显示；
/// - **进行中的块**（跨过起点）⇒ 显示（它是当前承诺）；
/// - 恰好在起点开始的块 ⇒ 显示。
bool visibleToForwardPreview(PlannedBlock block, TimeRange planningWindow) =>
    block.endUtc.isAfter(planningWindow.startUtc) &&
    block.startUtc.isBefore(planningWindow.endUtc);

/// 把结构化冲突与缺口转成预览问题（冻结决策 §1.6）。
///
/// **职责边界**（计划 §2 的文件职责表）：
/// - 本函数是**纯函数**：不访问数据库、不读时钟、不依赖 Flutter；
/// - 批量标题表由调用方传入（一次 `TaskTitleLookup.titlesFor()` 的结果）；
/// - 找不到标题回落 [unnamedTaskLabel]（定义在 `preview_failure_lines.dart`），
///   **绝不回落成 UUID**。
///
/// **顺序与去重**：
/// 1. 每个 `unscheduled` 一条 warning（标题、缺口分钟、主原因三件都在）；
/// 2. 每个 `conflict` 一条 blocking；
/// 3. 相同 `taskId + shortage` 只出现一次。
///
/// **缺口与冲突不会互相重复**：容量缺口只有一个结构化来源（`unscheduled`），
/// 引擎不再补 `insufficientCapacity` 冲突。去重仍然保留为第二道防线。
List<PreviewIssue> buildPreviewIssues({
  required ScheduleProposal proposal,
  required Map<String, String> titleByTaskId,
}) {
  final issues = <PreviewIssue>[];
  final seen = <String>{};

  for (final task in proposal.unscheduled) {
    final title = titleOfTask(task.taskId, titleByTaskId);
    final key = 'unscheduled:${task.taskId}:${task.shortageMinutes}';
    if (!seen.add(key)) continue;
    issues.add(
      PreviewIssue(
        key: key,
        // **容量不足是 warning**：允许用户明确确认后应用可安排的部分。
        severity: PreviewIssueSeverity.warning,
        title: '$title 还缺 ${task.shortageMinutes} 分钟',
        // 原因只说引擎给的那一条，页面上不猜（与 `unscheduledReasonLabel` 同一条纪律）。
        message: unscheduledReasonLabel(task.primaryReason),
      ),
    );
  }

  for (var index = 0; index < proposal.conflicts.length; index++) {
    final conflict = proposal.conflicts[index];
    final taskId = conflict.taskId;
    final title = taskId == null ? null : titleOfTask(taskId, titleByTaskId);
    // 键里带下标是必要的：同一种冲突可能合法地出现多次（例如两个不同块各与固定日程重叠，
    // 而它们都没有 taskId）。用"内容"作键会把它们合并掉，那会**少报**问题。
    final key = 'conflict:$index:${conflict.code.name}';
    if (!seen.add(key)) continue;
    issues.add(
      PreviewIssue(
        key: key,
        severity: PreviewIssueSeverity.blocking,
        title: title ?? conflictLabel(conflict.code),
        // **唯一翻译链**：与 `previewFailureLines` 共用同一个函数，
        // 因此 invalid 原因会分别写成"时间块早于本次规划范围"等具体说法。
        message: planningConflictMessage(
          conflict,
          taskTitle: title ?? unnamedTaskLabel,
        ),
      ),
    );
  }

  return issues;
}

/// 标题解析：**批量映射里查，查不到用占位文案，绝不回退成 id**。
///
/// 与 `preview_failure_lines.dart` 的 `_titleOf` 是同一条规则，因此在这里**公开**一份，
/// 供预览问题模型与路由共用。
String titleOfTask(String taskId, Map<String, String> titleByTaskId) {
  final title = titleByTaskId[taskId]?.trim();
  return title == null || title.isEmpty ? unnamedTaskLabel : title;
}
