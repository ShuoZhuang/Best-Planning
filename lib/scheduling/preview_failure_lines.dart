import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 一条**给用户看的**失败说明：事项标题 ＋ 结构化原因。
///
/// 1.8.0（设计规范 §13.2）：延后失败必须进入**现有的**标题解析与翻译链，
/// 显示成"贫困生材料提交：目标之后最大连续空档只有 10 分钟"，
/// **不能退回"可用时间不足"或内部 id**。
typedef PreviewFailureLine = ({String title, String reason});

/// 找不到标题时的占位文案。
///
/// 规范 §13.1：任何找不到标题的项使用**现有占位文案**，仍不得回退到 UUID。
/// 与预览页共用同一句，免得同一个任务在两处叫两个名字。
const String unnamedTaskLabel = '未命名任务';

/// 把一份提案的失败原因整理成"标题：原因"的行。
///
/// **它存在的理由**：生成路径有多条（普通"生成计划"、延后、自动修复），
/// 而"哪些事项没排进去、为什么"此前只有预览页一处会说。延后失败那条路径只报一句
/// 笼统的"提案不可行"，用户看到的是一句无法行动的话——规范 §2 第 7 条点名的正是这个。
///
/// **为什么是纯函数**：它要在四处被验证（没有裸 UUID、没有丢原因、顺序确定、上限生效），
/// 而纯函数可以用任意构造的提案把这些逐条钉住，不必启动整个生成流程。
///
/// **顺序与去重是定死的**（1.8.0，2026-10-12 故障；冻结决策 §1.5）：
/// 先每个 `unscheduled` 一条（去重后），再列**真正的**冲突。
/// 此前引擎会为每个缺口再补一条 `insufficientCapacity` 冲突，于是同一个任务在这里
/// 出现两次（"还缺 30 分钟"＋"可用时间不足"），用户以为有两个问题。
/// 现在容量缺口只有一个结构化来源，因此这里天然不会重复——
/// 但**去重仍然保留**：它是第二道防线（夹具与外层注入的提案不保证不重复）。
List<PreviewFailureLine> previewFailureLines({
  required ScheduleProposal proposal,
  required Map<String, String> titleByTaskId,
  int maximumLines = 3,
}) {
  if (maximumLines <= 0) return const [];
  // **无法解释的排程异常只由缺口行承载**（1.8.0 专项 §2.4）。
  //
  // 引擎为同一个任务同时给出缺口行与 `schedulingInvariantViolation` 冲突行，它们是
  // **同一件事**（前者给数字，后者给"不得应用"这个级别）。若两条都列，用户会看到
  // 同一句话两遍——其中一遍还多出一个「标题：」前缀，于是看起来像两个问题。
  // 与 `buildPreviewIssues` 用**同一个判据**，因此两条展示链不会各自漂移。
  final unexplainedTasks = proposal.unscheduled
      .where(
        (task) =>
            task.shortageMinutes > 0 &&
            (task.primaryReason.code ==
                    UnscheduledReasonCode.unexplainedSchedulingFailure ||
                proposal.conflicts.any(
                  (conflict) =>
                      conflict.code ==
                          ConflictCode.schedulingInvariantViolation &&
                      conflict.taskId == task.taskId,
                )),
      )
      .map((task) => task.taskId)
      .toSet();
  final lines = <PreviewFailureLine>[
    // **先列缺口**：规范 §13.2 的例句就是"某某：目标之后最大连续空档只有 10 分钟"，
    // 而"还缺 30 分钟"是用户最需要先知道的一件事。
    for (final task in proposal.unscheduled)
      if (task.shortageMinutes > 0)
        (
          title: _titleOf(task.taskId, titleByTaskId),
          reason: unscheduledReasonLabel(task.primaryReason),
        ),
    // **再列冲突**：它们可能没有 `taskId`（冲突是"计划整体"的事实），
    // 因此有归属时按任务标题显示，没有时退回冲突自己的标签位置。
    for (final conflict in proposal.conflicts)
      if (!(conflict.code == ConflictCode.schedulingInvariantViolation &&
          conflict.taskId != null &&
          unexplainedTasks.contains(conflict.taskId)))
        (
          title: conflict.taskId == null
              ? conflictLabel(conflict.code)
              : _titleOf(conflict.taskId!, titleByTaskId),
          // **同一句翻译**：与预览问题模型共用 `planningConflictMessage`，
          // 不再各写一个 switch（那样同一条原因会在两处显示成两句话）。
          reason: planningConflictMessage(
            conflict,
            taskTitle: _titleOf(conflict.taskId ?? '', titleByTaskId),
          ),
        ),
  ];
  // 去重：同一条（标题＋原因）只说一次。保留**首次出现**的顺序，
  // 因此结果仍然是确定的。
  final seen = <String>{};
  final unique = <PreviewFailureLine>[];
  for (final line in lines) {
    if (!seen.add('${line.title}\u0000${line.reason}')) continue;
    unique.add(line);
  }
  return unique.length <= maximumLines
      ? unique
      : unique.sublist(0, maximumLines);
}

/// 标题解析：**批量映射里查，查不到用占位文案，绝不回退成 id**。
String _titleOf(String taskId, Map<String, String> titleByTaskId) {
  final title = titleByTaskId[taskId]?.trim();
  return title == null || title.isEmpty ? unnamedTaskLabel : title;
}

/// 把一条失败行拼成一行可显示的文案：`标题：原因`。
///
/// **拼接而不是让调用方自己拼**：两处拼接就有两处可能忘了加标题——
/// 而那正是"退回裸 UUID"这类缺陷的温床。
String formatFailureLine(PreviewFailureLine line) =>
    '${line.title}：${line.reason}';
