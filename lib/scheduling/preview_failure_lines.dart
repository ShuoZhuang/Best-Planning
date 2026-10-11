import 'package:personal_planner/scheduling/explanations.dart';
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
List<PreviewFailureLine> previewFailureLines({
  required ScheduleProposal proposal,
  required Map<String, String> titleByTaskId,
  int maximumLines = 3,
}) {
  if (maximumLines <= 0) return const [];
  final lines = <PreviewFailureLine>[
    // **先列缺口**：规范 §13.2 的例句就是"某某：目标之后最大连续空档只有 10 分钟"，
    // 而"还缺 30 分钟"是用户最需要先知道的一件事。
    for (final task in proposal.unscheduled)
      if (task.shortageMinutes > 0)
        (
          title: _titleOf(task.taskId, titleByTaskId),
          reason: unscheduledReasonLabel(task.primaryReason),
        ),
    // **再列冲突**：它们没有 `taskId` 归属到某一件任务上（冲突是"计划整体"的事实），
    // 因此用冲突自己的标签作为"标题"位置。
    for (final conflict in proposal.conflicts)
      (title: conflictLabel(conflict.code), reason: '这次调整与它冲突'),
  ];
  return lines.length <= maximumLines ? lines : lines.sublist(0, maximumLines);
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
