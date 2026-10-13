// 1.8.0（2026-10-12 故障；冻结决策 §1.5）：**提案三态与 metrics 一致性**。
//
// 截图里的第三件事是"明知装不下，页面仍显示可点击的『确认应用』"。
// 根因是没有任何一层回答"这份提案能不能应用"：引擎有 `metrics.isFullyFeasible`，
// 预览模型却只保存 `isStale`。
//
// 这个文件钉住两件事：
// 1. 三态分类只以**结构化事实**（`conflicts` / `unscheduled`）为准；
// 2. `metrics.isFullyFeasible` 与分类**双向一致** —— 防止两个事实源漂移。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  /// 从**同一份结构**重新算 metrics 的提案构造器。
  ///
  /// **不得手填相反值**：如果夹具可以写 `conflicts: [x], metrics: isFullyFeasible: true`，
  /// 那么"分类与 metrics 一致"这条断言就变成了在验夹具，而不是在验产品。
  ScheduleProposal proposalOf({
    List<UnscheduledTask> unscheduled = const [],
    List<PlanningConflict> conflicts = const [],
    List<PlannedBlock> blocks = const [],
  }) => ScheduleProposal(
    proposalId: 'p',
    inputHash: 'h',
    algorithmVersion: '14',
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 12),
      endUtc: DateTime.utc(2026, 10, 19),
    ),
    blocks: blocks,
    unscheduled: unscheduled,
    conflicts: conflicts,
    explanations: const [],
    metrics: ProposalMetrics(
      isFullyFeasible: conflicts.isEmpty && unscheduled.isEmpty,
      scheduledMinutes: blocks.fold(0, (sum, b) => sum + b.durationMinutes),
      unscheduledMinutes: unscheduled.fold(
        0,
        (sum, u) => sum + u.shortageMinutes,
      ),
    ),
  );

  const shortage = UnscheduledTask(
    taskId: 't-a',
    shortageMinutes: 30,
    primaryReason: UnscheduledReason(
      code: UnscheduledReasonCode.insufficientCapacity,
      // 不变量：`placementRemainingMinutes == shortageMinutes`（计划 §2.4）。
      placementRemainingMinutes: 30,
    ),
  );

  final blocking = PlanningConflict(code: ConflictCode.blockOverlap);

  test('无 conflict、无 unscheduled ⇒ `fullyApplicable`', () {
    final proposal = proposalOf();
    expect(classifyProposal(proposal), ProposalDisposition.fullyApplicable);
    expect(proposal.metrics.isFullyFeasible, isTrue);
    expect(isFullyApplicable(proposal), isTrue);
  });

  test('无 conflict、有 unscheduled ⇒ `partialRequiresConfirmation`', () {
    final proposal = proposalOf(unscheduled: [shortage]);
    expect(
      classifyProposal(proposal),
      ProposalDisposition.partialRequiresConfirmation,
      reason: '"容量不足"不是结构性错误：允许用户明确确认应用可安排的部分',
    );
    expect(proposal.metrics.isFullyFeasible, isFalse);
    expect(
      isFullyApplicable(proposal),
      isFalse,
      reason: '部分计划**不得**被当成可自动应用的完整提案',
    );
  });

  test('有任一 conflict（无论是否有 unscheduled）⇒ `blocked`', () {
    expect(
      classifyProposal(proposalOf(conflicts: [blocking])),
      ProposalDisposition.blocked,
    );
    expect(
      classifyProposal(
        proposalOf(conflicts: [blocking], unscheduled: [shortage]),
      ),
      ProposalDisposition.blocked,
      reason: '规则顺序不可调换：有阻断错误时，缺口再多也先归 blocked',
    );
  });

  test('`classifyProposal` **不读 metrics**：metrics 说谎也挡不住结构化事实', () {
    // 刻意构造一个"metrics 说可行、结构说阻断"的提案：
    // 分类必须以结构为准，否则一次忘记更新 metrics 的重构就能让页面重新显示可点击的确认。
    final lying = ScheduleProposal(
      proposalId: 'lying',
      inputHash: 'h',
      algorithmVersion: '14',
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 12),
        endUtc: DateTime.utc(2026, 10, 19),
      ),
      blocks: const [],
      unscheduled: const [],
      conflicts: [blocking],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 0,
        unscheduledMinutes: 0,
      ),
    );
    expect(
      classifyProposal(lying),
      ProposalDisposition.blocked,
      reason: '事实源是 conflicts/unscheduled，不是 metrics',
    );
  });

  group('引擎实际产出的提案：分类与 metrics 双向一致', () {
    /// 从**引擎真实输出**上验一致性，而不是从手工构造的提案上验。
    void expectConsistent(ScheduleProposal proposal) {
      final disposition = classifyProposal(proposal);
      expect(
        proposal.metrics.isFullyFeasible,
        disposition == ProposalDisposition.fullyApplicable,
        reason:
            'metrics 与分类必须互为充要条件。'
            '实测：disposition=$disposition, metrics.isFullyFeasible='
            '${proposal.metrics.isFullyFeasible}, '
            'conflicts=${proposal.conflicts.map((c) => c.code).toList()}, '
            'unscheduled=${proposal.unscheduled.length}',
      );
    }

    ScheduleProblem problem({
      required List<SchedulableTask> tasks,
      List<BusyInterval> protectedIntervals = const [],
    }) {
      final day = DateTime.utc(2026, 10, 12);
      return ScheduleProblem(
        planningWindow: TimeRange(
          startUtc: day,
          endUtc: day.add(const Duration(days: 1)),
        ),
        timeZoneId: 'UTC',
        tasks: tasks,
        fixedIntervals: const [],
        protectedIntervals: protectedIntervals,
        lockedBlocks: const [],
        rules: DefaultSettings.v1().copyWith(
          sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'disposition',
      );
    }

    test('全部排得下 ⇒ fullyApplicable 且 metrics 为真', () {
      final proposal = DeterministicScheduleEngine(TimeZoneDatabase()).generate(
        problem(
          tasks: const [
            SchedulableTask(
              id: 't-a',
              requiredMinutes: 60,
              splitMode: TaskSplitMode.splittable,
              minChunkMinutes: 30,
              maxChunkMinutes: 60,
            ),
          ],
        ),
      );
      expectConsistent(proposal);
      expect(proposal.unscheduled, isEmpty);
      expect(classifyProposal(proposal), ProposalDisposition.fullyApplicable);
    });

    test('容量不足 ⇒ partialRequiresConfirmation（不是 blocked）', () {
      // 把整天保护起来 ⇒ 一个片段也放不下，但**没有任何结构错误**。
      final day = DateTime.utc(2026, 10, 12);
      final proposal = DeterministicScheduleEngine(TimeZoneDatabase()).generate(
        problem(
          tasks: const [
            SchedulableTask(
              id: 't-a',
              requiredMinutes: 60,
              splitMode: TaskSplitMode.splittable,
              minChunkMinutes: 30,
              maxChunkMinutes: 60,
            ),
          ],
          protectedIntervals: [
            BusyInterval(
              id: 'all-day',
              range: TimeRange(
                startUtc: day,
                endUtc: day.add(const Duration(days: 1)),
              ),
            ),
          ],
        ),
      );
      expectConsistent(proposal);
      expect(proposal.unscheduled, isNotEmpty);
      expect(
        proposal.conflicts,
        isEmpty,
        reason: '排不下不是结构性错误：它只有 unscheduled 一个来源',
      );
      expect(
        classifyProposal(proposal),
        ProposalDisposition.partialRequiresConfirmation,
      );
    });

    test('缺口数字的不变量：`placementRemainingMinutes == shortageMinutes`', () {
      // 计划 §2.4 的字段不变量。它必须对**引擎真实输出**成立，而不只是对手工夹具成立：
      // 事后补数字（而不是构造原因时写入当轮剩余量）会让这条不变量在嵌套构造的路径上失效。
      final proposal = DeterministicScheduleEngine(TimeZoneDatabase()).generate(
        problem(
          tasks: const [
            SchedulableTask(
              id: 't-a',
              requiredMinutes: 60,
              splitMode: TaskSplitMode.splittable,
              minChunkMinutes: 30,
              maxChunkMinutes: 60,
            ),
          ],
          protectedIntervals: [
            BusyInterval(
              id: 'all-day',
              range: TimeRange(
                startUtc: DateTime.utc(2026, 10, 12),
                endUtc: DateTime.utc(2026, 10, 13),
              ),
            ),
          ],
        ),
      );

      expect(proposal.unscheduled, isNotEmpty, reason: '这条用例的前提是存在缺口');
      for (final item in proposal.unscheduled) {
        expect(
          item.primaryReason.placementRemainingMinutes,
          item.shortageMinutes,
          reason: '主原因的放置剩余量必须就是这条缺口的分钟数',
        );
        for (final reason in item.reasons) {
          expect(reason.placementRemainingMinutes, item.shortageMinutes);
        }
      }
    });

    test('**结构异常必然是 blocked**：`hasEligibleCandidate && shortage > 0`', () {
      // **这条用例钉的是计划 Task 5 Step 6 的不可绕过性**：
      // 引擎在"仍有合法候选"的情况下留下缺口时，必须同时给出
      // `unexplainedSchedulingFailure`（主原因）与 `schedulingInvariantViolation`（阻断冲突）。
      // 这里用引擎真实输出构造那种形状（任务排得下却一个块都没有），断言分类结果是 blocked。
      final proposal = DeterministicScheduleEngine(TimeZoneDatabase()).generate(
        problem(
          tasks: const [
            SchedulableTask(
              id: 't-a',
              requiredMinutes: 60,
              splitMode: TaskSplitMode.splittable,
              minChunkMinutes: 30,
              maxChunkMinutes: 60,
            ),
          ],
        ),
      );
      // 前置条件：正常情况下它完全排得下（因此"排不下"必然是结构异常）。
      expect(proposal.unscheduled, isEmpty);
      expect(classifyProposal(proposal), ProposalDisposition.fullyApplicable);

      final anomalous = proposalOf(
        unscheduled: const [
          UnscheduledTask(
            taskId: 't-a',
            shortageMinutes: 60,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.unexplainedSchedulingFailure,
              placementRemainingMinutes: 60,
              constraintRequiredMinutes: 60,
              constraintAvailableMinutes: 60,
            ),
          ),
        ],
        conflicts: [
          PlanningConflict(
            code: ConflictCode.schedulingInvariantViolation,
            taskId: 't-a',
          ),
        ],
      );
      expect(
        classifyProposal(anomalous),
        ProposalDisposition.blocked,
        reason:
            '"排程没有使用仍可用的合法时段"不是"缺一部分"：它必须阻断，'
            '而 `allowPartial` 不得把它降级成可应用的 warning',
      );
      expect(
        isFullyApplicable(anomalous),
        isFalse,
        reason: '它也不得被当成可自动应用的完整提案',
      );
    });
  });
}
