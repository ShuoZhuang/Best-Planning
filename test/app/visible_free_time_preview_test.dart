// **无法解释的零安排**必须是阻断，且只能显示一条问题（1.8.0 专项 §2.4 / §5 A13）。
//
// ## 这条防线挡的是什么
//
// 用户报告的现象是"日历里明显还有空档，计划却把任务全部报成可用时间不足"。这类故障的
// 共同形状是**排程器自己没排好**：存在合法的可放置容量，最终却一个块都没落下。
//
// 把它说成"容量不足"有双重危害：
// 1. 用户会去腾时间——而腾时间解决不了排程器的缺陷；
// 2. 缺陷继续留在产品里，因为"容量不足"是**允许带着它确认应用**的 warning。
//
// 因此这一层要做三件事，本文件逐条钉住：
// - 它是 `blocking`（不得自动应用、不得"应用可安排部分"）；
// - 文案是**固定的一句**，与 `conflictLabel` 共用同一个常量；
// - **同一件事只显示一条问题**：引擎会同时给出缺口行与冲突行，预览层必须合并它们。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/planning/plan_preview_issues.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/preview_failure_lines.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  /// 一个**形如真实 UUID** 的 id：它出现在任何字段里都必须被认出来。
  const uuid = '3f1a9c62-7b04-4d1e-9a55-0c8e2b7d4f31';

  ScheduleProposal proposalOf({
    List<UnscheduledTask> unscheduled = const [],
    List<PlanningConflict> conflicts = const [],
  }) => ScheduleProposal(
    proposalId: 'p1',
    inputHash: 'h1',
    algorithmVersion: '15',
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 12, 1, 30),
      endUtc: DateTime.utc(2026, 10, 19),
    ),
    blocks: const [],
    unscheduled: unscheduled,
    conflicts: conflicts,
    explanations: const [],
    metrics: ProposalMetrics(
      isFullyFeasible: conflicts.isEmpty && unscheduled.isEmpty,
      scheduledMinutes: 0,
      unscheduledMinutes: unscheduled.fold(
        0,
        (sum, item) => sum + item.shortageMinutes,
      ),
    ),
  );

  const unexplained = UnscheduledTask(
    taskId: 't-a',
    shortageMinutes: 180,
    primaryReason: UnscheduledReason(
      code: UnscheduledReasonCode.unexplainedSchedulingFailure,
      placementRemainingMinutes: 180,
      constraintRequiredMinutes: 180,
      constraintAvailableMinutes: 240,
    ),
  );

  test('A13 合法候选存在但结果为 0 ⇒ 阻断，且不显示"可用时间不足"', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [unexplained],
        conflicts: [
          PlanningConflict(
            code: ConflictCode.schedulingInvariantViolation,
            taskId: 't-a',
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(
      issues,
      hasLength(1),
      reason:
          '引擎同时给出缺口行与冲突行，它们是**同一件事**；'
          '两条都显示＝同一件事说两遍（冻结决策 §1.5 禁止的形态）',
    );
    final issue = issues.single;
    expect(issue.severity, PreviewIssueSeverity.blocking);
    expect(issue.isBlocking, isTrue, reason: '不得自动应用，也不得"应用可安排部分"');
    expect(issue.title, '写报告 还缺 180 分钟');
    expect(
      issue.message,
      isNot(contains('可用时间不足')),
      reason: '真实原因是排程器没排好，不是没有容量；说成容量不足会让用户白腾时间',
    );
    expect(issue.message, schedulingInvariantViolationMessage);
  });

  test('固定文案逐字符合计划要求，且给出下一步', () {
    expect(
      schedulingInvariantViolationMessage,
      '排程没有使用仍可用的合法时段。本次计划未自动应用，请重新生成；若问题持续，请导出诊断信息。',
    );
    // 两条展示链共用同一个常量：冲突行与缺口行不可能各说一句。
    expect(
      conflictLabel(ConflictCode.schedulingInvariantViolation),
      schedulingInvariantViolationMessage,
    );
    expect(
      unscheduledReasonLabel(unexplained.primaryReason),
      schedulingInvariantViolationMessage,
    );
  });

  test('**不显示 UUID、task id、内部枚举名**', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: [
          const UnscheduledTask(
            taskId: uuid,
            shortageMinutes: 180,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.unexplainedSchedulingFailure,
              placementRemainingMinutes: 180,
            ),
          ),
        ],
        conflicts: [
          PlanningConflict(
            code: ConflictCode.schedulingInvariantViolation,
            taskId: uuid,
          ),
        ],
      ),
      titleByTaskId: const {},
    );

    expect(issues, hasLength(1));
    expect(issues.single.title, startsWith(unnamedTaskLabel));
    expect(issues.single.message, isNot(contains(uuid)));
    expect(issues.single.message, isNot(contains('unexplained')));
    expect(
      issues.single.message,
      isNot(contains('schedulingInvariantViolation')),
    );
  });

  test('**只有冲突、没有缺口行时仍然阻断**（注入的提案也不能绕过）', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        conflicts: [
          PlanningConflict(
            code: ConflictCode.schedulingInvariantViolation,
            taskId: 't-a',
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(issues, hasLength(1));
    expect(issues.single.isBlocking, isTrue);
    expect(
      issues.single.message,
      contains(schedulingInvariantViolationMessage),
      reason: '冲突行会带上「标题：」前缀，因此用 contains 而不是逐字相等',
    );
  });

  test('**真容量不足仍然是 warning**（两个约束数字带齐，缺口只在标题里）', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(
            taskId: 't-a',
            shortageMinutes: 25,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.insufficientCapacity,
              placementRemainingMinutes: 25,
              constraintRequiredMinutes: 180,
              constraintAvailableMinutes: 155,
            ),
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    final issue = issues.single;
    expect(issue.severity, PreviewIssueSeverity.warning);
    expect(issue.message, contains('180'));
    expect(issue.message, contains('155'));
    // **缺口分钟只在标题里**（计划 §2.4）：正文的两个数字属于"这件事需要的分钟数"
    // 与"同一口径下可用空档的分钟数"，从它们推总缺口正是 §6 禁止的捷径。
    expect(issue.title, '写报告 还缺 25 分钟');
  });

  test('延后失败链（previewFailureLines）也翻译同一条原因', () {
    final lines = previewFailureLines(
      proposal: proposalOf(
        unscheduled: const [unexplained],
        conflicts: [
          PlanningConflict(
            code: ConflictCode.schedulingInvariantViolation,
            taskId: 't-a',
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(lines, hasLength(1), reason: '两条链都要去重：同一件事只说一次');
    expect(lines.single.reason, schedulingInvariantViolationMessage);
    expect(formatFailureLine(lines.single), contains('写报告'));
  });
}
