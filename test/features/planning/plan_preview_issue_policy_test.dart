// 1.8.0（2026-10-12 故障；冻结决策 §1.6）：**预览问题模型只翻译结构化事实**。
//
// 截图里的第二个现象是"同一任务既显示『可用时间不足』又显示『「蓝桥杯竞赛课」还缺 76 分钟』"。
// 根因是预览模型把冲突存成 `List<String>`：任务、块、数值与 invalid 原因全部丢失（R7），
// 于是页面既说不清"是哪一件事"，也说不出"为什么"。
//
// 这个文件钉住六条：每个缺口一条 warning、每个冲突一条 blocking、同缺口不重复、
// 标题回落、任何字段不含 UUID、invalid 原因分别翻译。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/planning/plan_preview_issues.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/task_capacity_analyzer.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';

void main() {
  /// 一个**形如真实 UUID** 的 id：它出现在任何字段里都必须被认出来。
  const uuid = '3f1a9c62-7b04-4d1e-9a55-0c8e2b7d4f31';

  ScheduleProposal proposalOf({
    List<UnscheduledTask> unscheduled = const [],
    List<PlanningConflict> conflicts = const [],
    Map<String, TaskPlacementDiagnostics> placementDiagnostics = const {},
  }) => ScheduleProposal(
    proposalId: 'p1',
    inputHash: 'h1',
    algorithmVersion: '14',
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 12, 1, 30),
      endUtc: DateTime.utc(2026, 10, 19),
    ),
    blocks: const [],
    unscheduled: unscheduled,
    conflicts: conflicts,
    placementDiagnostics: placementDiagnostics,
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

  test('每个 unscheduled 产生一条 warning，标题、缺口与主原因都在', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: [
          const UnscheduledTask(
            taskId: 't-contest',
            shortageMinutes: 76,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.continuousGapTooShort,
              placementRemainingMinutes: 76,
              constraintRequiredMinutes: 76,
              constraintAvailableMinutes: 20,
            ),
          ),
        ],
      ),
      titleByTaskId: const {'t-contest': '蓝桥杯竞赛课'},
    );

    expect(issues, hasLength(1));
    final issue = issues.single;
    expect(issue.severity, PreviewIssueSeverity.warning);
    expect(issue.isBlocking, isFalse);
    expect(issue.title, '蓝桥杯竞赛课 还缺 76 分钟');
    // 主原因是**引擎给的那一条**，翻成一句带数字的人话。
    expect(issue.message, contains('76'));
    expect(issue.message, contains('20'));
    expect(issue.message, contains('一次做完'), reason: '不能退回笼统的"可用时间不足"');
  });

  test('每个 conflict 产生一条 blocking', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        conflicts: [
          PlanningConflict(
            code: ConflictCode.protectedTimeOverlap,
            taskId: 't-contest',
          ),
        ],
      ),
      titleByTaskId: const {'t-contest': '蓝桥杯竞赛课'},
    );

    expect(issues, hasLength(1));
    expect(issues.single.severity, PreviewIssueSeverity.blocking);
    expect(issues.single.isBlocking, isTrue);
    expect(issues.single.title, '蓝桥杯竞赛课');
    expect(issues.single.message, contains('保护时间'));
  });

  test('**相同 taskId + shortage 不重复**', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(issues, hasLength(1), reason: '同一条缺口说两遍，用户会以为是两件事（截图里的第二个现象）');
  });

  test('**标题缺失回落 `未命名任务`，不是空串、更不是 id**', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [UnscheduledTask(taskId: uuid, shortageMinutes: 15)],
      ),
      titleByTaskId: const {},
    );

    expect(issues.single.title, startsWith(unnamedTaskLabel));
    expect(issues.single.title, isNot(contains(uuid)));
  });

  test('**任何字段都不含 UUID**（标题、原因、key 之外的可见文本）', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [UnscheduledTask(taskId: uuid, shortageMinutes: 15)],
        conflicts: [
          PlanningConflict(
            code: ConflictCode.invalidInput,
            taskId: uuid,
            invalidInputReason: InvalidInputReason.startsBeforePlanningWindow,
            relatedEntityIds: [uuid],
          ),
          PlanningConflict(
            code: ConflictCode.blockOverlap,
            relatedEntityIds: [uuid],
          ),
        ],
      ),
      // **刻意不给标题**：查不到时必须回落占位文案，而不是把 id 拿出来顶替。
      titleByTaskId: const {},
    );

    expect(issues, hasLength(3));
    for (final issue in issues) {
      expect(
        issue.title,
        isNot(contains(uuid)),
        reason: '标题里出现 UUID 就是 §13.1 禁止的那条',
      );
      expect(
        issue.message,
        isNot(contains(uuid)),
        reason: 'relatedEntityIds 绝不能出现在用户可见文案里',
      );
    }
  });

  test('**invalid 原因分别翻译**，不再只有"排程输入无效"', () {
    final labels = {
      InvalidInputReason.startsBeforePlanningWindow: buildPreviewIssues(
        proposal: proposalOf(
          conflicts: [
            PlanningConflict(
              code: ConflictCode.invalidInput,
              invalidInputReason: InvalidInputReason.startsBeforePlanningWindow,
            ),
          ],
        ),
        titleByTaskId: const {},
      ).single.message,
      InvalidInputReason.endsAfterPlanningWindow: buildPreviewIssues(
        proposal: proposalOf(
          conflicts: [
            PlanningConflict(
              code: ConflictCode.invalidInput,
              invalidInputReason: InvalidInputReason.endsAfterPlanningWindow,
            ),
          ],
        ),
        titleByTaskId: const {},
      ).single.message,
      InvalidInputReason.unknownTask: buildPreviewIssues(
        proposal: proposalOf(
          conflicts: [
            PlanningConflict(
              code: ConflictCode.invalidInput,
              invalidInputReason: InvalidInputReason.unknownTask,
            ),
          ],
        ),
        titleByTaskId: const {},
      ).single.message,
      InvalidInputReason.chunkBelowMinimum: buildPreviewIssues(
        proposal: proposalOf(
          conflicts: [
            PlanningConflict(
              code: ConflictCode.invalidInput,
              invalidInputReason: InvalidInputReason.chunkBelowMinimum,
            ),
          ],
        ),
        titleByTaskId: const {},
      ).single.message,
    };

    expect(
      labels[InvalidInputReason.startsBeforePlanningWindow],
      contains('规划范围'),
    );
    expect(
      labels[InvalidInputReason.endsAfterPlanningWindow],
      contains('规划范围'),
    );
    expect(labels[InvalidInputReason.unknownTask], contains('不存在'));
    expect(labels[InvalidInputReason.chunkBelowMinimum], contains('片段'));
    expect(labels.values.toSet(), hasLength(4), reason: '四种原因的处置完全不同，文案不能是同一句');
    for (final message in labels.values) {
      expect(message, isNot('排程输入无效'), reason: '一句"排程输入无效"是截图里的第四件事：用户不知道该改什么');
    }
  });

  test('invalid 原因带上片段数字（用户据此才知道差多少）', () {
    final issue = buildPreviewIssues(
      proposal: proposalOf(
        conflicts: [
          PlanningConflict(
            code: ConflictCode.invalidInput,
            taskId: 't-a',
            invalidInputReason: InvalidInputReason.chunkBelowMinimum,
            details: {
              'durationMinutes': 15,
              'minChunkMinutes': 30,
              'maxChunkMinutes': 90,
            },
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    ).single;

    expect(issue.message, contains('15'));
    expect(issue.message, contains('30'));
    expect(issue.title, '写报告');
  });

  test('**顺序稳定**：先缺口、后冲突；同类型按输入顺序', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-b', shortageMinutes: 10),
          UnscheduledTask(taskId: 't-a', shortageMinutes: 20),
        ],
        conflicts: [
          PlanningConflict(code: ConflictCode.blockOverlap),
          PlanningConflict(code: ConflictCode.lockedBlockMoved, taskId: 't-a'),
        ],
      ),
      titleByTaskId: const {'t-a': 'A', 't-b': 'B'},
    );

    expect(issues.map((issue) => issue.title).toList(), [
      'B 还缺 10 分钟',
      'A 还缺 20 分钟',
      '任务时间块相互重叠',
      'A',
    ]);
  });

  test('**没有重复 key**：同一条问题不可能产生两个键', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
        ],
        conflicts: [
          PlanningConflict(code: ConflictCode.blockOverlap),
          PlanningConflict(code: ConflictCode.blockOverlap),
        ],
      ),
      titleByTaskId: const {'t-a': 'A'},
    );

    final keys = issues.map((issue) => issue.key).toList();
    expect(
      keys.toSet(),
      hasLength(keys.length),
      reason: '两个块各自重叠是两件事，键里必须能区分（下标），但同一件事不能有两个键',
    );
    expect(issues, hasLength(3));
  });

  test('空提案 ⇒ 没有问题', () {
    expect(
      buildPreviewIssues(proposal: proposalOf(), titleByTaskId: const {}),
      isEmpty,
    );
  });

  // ── 1.8.0 专项：结构化原因的数字与严重级别（§2.4 / §5 A09/A10/A13/A14）──────────
  //
  // 四条各自对应一种**处置完全不同**的原因。把它们说成同一句"可用时间不足"会让用户
  // 白做动作：真容量不足要腾时间，连续空档不足要改拆分或截止，每日上限要调上限或换日期，
  // 而"无法解释"要重新生成并报诊断。

  test('A14 真容量不足：warning，且两个约束数字都在（缺口数字在标题）', () {
    final issue = buildPreviewIssues(
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
    ).single;

    expect(issue.severity, PreviewIssueSeverity.warning);
    expect(issue.title, '写报告 还缺 25 分钟');
    expect(issue.message, contains('180'));
    expect(issue.message, contains('155'));
    // **`25` 只在标题里**：正文的两个数字是 constraint 口径的（计划 §2.4），
    // 从它们推不出总缺口，因此正文里也不该出现它（R7）。
  });

  test('A10 连续空档不足：显示"要求连续 X 分钟，最长只有 Y 分钟"', () {
    final issue = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(
            taskId: 't-a',
            shortageMinutes: 60,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.continuousGapTooShort,
              placementRemainingMinutes: 60,
              constraintRequiredMinutes: 120,
              constraintAvailableMinutes: 90,
            ),
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    ).single;

    expect(issue.severity, PreviewIssueSeverity.warning);
    expect(issue.message, contains('120'));
    expect(issue.message, contains('90'));
    expect(issue.message, isNot(contains('可用时间不足')));
  });

  test('A09 每日上限：显示剩余上限分钟', () {
    final issue = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(
            taskId: 't-a',
            shortageMinutes: 60,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.dailyLimitReached,
              placementRemainingMinutes: 60,
              constraintRequiredMinutes: 60,
              constraintAvailableMinutes: 0,
              constraintLabel: '每日上限',
            ),
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    ).single;

    expect(issue.severity, PreviewIssueSeverity.warning);
    expect(issue.message, contains('上限'));
  });

  test('A13 无法解释：blocking，只一条，且不出现"可用时间不足"', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(
            taskId: 't-a',
            shortageMinutes: 180,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.unexplainedSchedulingFailure,
              placementRemainingMinutes: 180,
              constraintRequiredMinutes: 180,
              constraintAvailableMinutes: 240,
            ),
          ),
        ],
        conflicts: [
          PlanningConflict(
            code: ConflictCode.schedulingInvariantViolation,
            taskId: 't-a',
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(issues, hasLength(1), reason: '同一件事不得显示两遍（warning ＋ blocker）');
    expect(issues.single.isBlocking, isTrue);
    expect(issues.single.message, isNot(contains('可用时间不足')));
    expect(issues.single.message, contains('本次计划未自动应用'));
  });

  test('**同名不同 id 的两个周期实例不能按标题合并**（去重键必须是身份）', () {
    // §7 禁止的捷径之一："不用标题去重周期实例；标题不是身份"。
    //
    // 正确行为是**上游排除未来实例**（见 `visible_free_time_shortage_regression_test.dart`）。
    // 预览层的去重键因此必须包含 task id：两个同名实例是两件事，合并会少报一条；
    // 而把它们按标题合成一条"还缺 420 分钟"则更糟——那个数字不对应任何一件真实的事。
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 'cycle-current', shortageMinutes: 210),
          UnscheduledTask(taskId: 'cycle-next', shortageMinutes: 210),
        ],
      ),
      titleByTaskId: const {'cycle-current': '每周英语', 'cycle-next': '每周英语'},
    );

    expect(issues, hasLength(2), reason: '同名不是同一件事：去重若按标题，用户会以为只缺一份 210 分钟');
    expect(issues.map((issue) => issue.title).toSet(), {'每周英语 还缺 210 分钟'});
  });

  // ── 计划 §2.8 / Task 6 Step 1：**恢复动作的映射表**逐条钉住 ───────────────────
  //
  // 这张表的每一行都对应一种**处置完全不同**的原因：改任务、改规则、管保护时间、
  // 重新生成。映射只读 reason code——因此"按任务属性猜原因"在类型上就做不到。

  test('映射表逐条符合 §2.8（含三张表没规定的三种原因）', () {
    expect(recoveryActionsFor(UnscheduledReasonCode.deadlineWindowTooShort), [
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.continuousGapTooShort), [
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.minimumChunkTooLarge), [
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.availableTimeNotReached), [
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.dailyLimitReached), [
      PreviewRecoveryAction.openPlanningRules,
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.protectedTimeOccupied), [
      PreviewRecoveryAction.openProtectedTimeManagement,
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.insufficientCapacity), [
      PreviewRecoveryAction.editTask,
      PreviewRecoveryAction.openPlanningRules,
    ]);
    expect(
      recoveryActionsFor(UnscheduledReasonCode.unexplainedSchedulingFailure),
      [PreviewRecoveryAction.recalculate],
    );
    // §2.8 没有规定的三种：按"能改任务／规则"的最近一条补齐。
    // 被固定日程或被锁定块占住时，可动的只有任务本身（改时段／改截止／换拆分方式）；
    // 片段间休息是规划规则里的一个数（"片段间休息（分钟）"与每日上限同一张卡），
    // 因此沿用 `dailyLimitReached` 那一行。
    expect(recoveryActionsFor(UnscheduledReasonCode.fixedScheduleOccupied), [
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.lockedPlanOccupied), [
      PreviewRecoveryAction.editTask,
    ]);
    expect(recoveryActionsFor(UnscheduledReasonCode.requiredBreakUnavailable), [
      PreviewRecoveryAction.openPlanningRules,
      PreviewRecoveryAction.editTask,
    ]);
  });

  test('**枚举里的每个原因都有动作**：漏一个就是"读完了不知道去哪"', () {
    for (final code in UnscheduledReasonCode.values) {
      expect(
        recoveryActionsFor(code),
        isNotEmpty,
        reason: '$code 没有任何恢复动作，用户读到的就只是一句无法行动的话',
      );
    }
  });

  test('**证据来自提案的最终诊断**，动作只由主原因决定', () {
    final gap = ExcludedGapEvidence(
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 12, 6),
        endUtc: DateTime.utc(2026, 10, 12, 6, 20),
      ),
      code: GapExclusionCode.shorterThanRequiredChunk,
    );
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(
            taskId: 't-a',
            shortageMinutes: 30,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.dailyLimitReached,
              placementRemainingMinutes: 30,
            ),
          ),
        ],
        placementDiagnostics: {
          't-a': TaskPlacementDiagnostics(
            remainingMinutes: 30,
            capacity: const TaskCapacityEvidence(
              calendarGapMinutes: 0,
              taskWindowMinutes: 0,
              taskPlaceableMinutes: 0,
              remainingPlaceableMinutes: 0,
              largestTaskWindowGapMinutes: 0,
              largestRemainingGapMinutes: 0,
              dailyLimitRemainingMinutes: 0,
            ),
            reasons: const [
              UnscheduledReason(
                code: UnscheduledReasonCode.dailyLimitReached,
                placementRemainingMinutes: 30,
              ),
            ],
            excludedGaps: [gap],
            hasEligibleCandidate: false,
          ),
        },
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(issues.single.taskId, 't-a');
    expect(issues.single.excludedGaps, [gap]);
    expect(issues.single.actions, [
      PreviewRecoveryAction.openPlanningRules,
      PreviewRecoveryAction.editTask,
    ]);
  });

  test('**诊断缺失时证据为空**，而不是编一段空档出来', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(issues.single.excludedGaps, isEmpty);
  });

  test('**冲突行不给恢复动作**，但仍带上任务 id 供卡片显示', () {
    final issues = buildPreviewIssues(
      proposal: proposalOf(
        conflicts: [
          PlanningConflict(
            code: ConflictCode.protectedTimeOverlap,
            taskId: 't-a',
          ),
        ],
      ),
      titleByTaskId: const {'t-a': '写报告'},
    );

    expect(issues.single.isBlocking, isTrue);
    expect(issues.single.taskId, 't-a');
    expect(issues.single.actions, isEmpty);
  });

  test('**空档文案：每个 code 一句能行动的中文，且不出现枚举名**', () {
    for (final code in GapExclusionCode.values) {
      final reason = gapExclusionReason(code);
      expect(reason.trim(), isNotEmpty, reason: '$code 没有对应文案');
      expect(
        reason,
        isNot(contains(code.name)),
        reason: '用户看到的必须是中文句子，不是枚举成员名',
      );
    }
    expect(
      gapExclusionReason(GapExclusionCode.shorterThanRequiredChunk),
      '这段空档短于最短片段',
    );
  });

  test('**空档行写本地日期时间**（UTC 区间 → 东八区），跨午夜要带结束日期', () {
    final zones = TimeZoneDatabase();
    final sameDay = excludedGapLabel(
      ExcludedGapEvidence(
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 12, 6),
          endUtc: DateTime.utc(2026, 10, 12, 6, 30),
        ),
        code: GapExclusionCode.occupiedByProtectedTime,
      ),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
    );

    // 东八区 14:00–14:30（UTC 06:00–06:30）。
    expect(sameDay, contains('10-12 14:00–14:30'));
    expect(sameDay, contains('被保护时间占住'));
    expect(sameDay, isNot(contains('06:00')), reason: '印 UTC 会让用户去找一段不存在的空档');

    // 跨午夜：本地 10-12 23:30 → 10-13 00:30。
    final acrossMidnight = excludedGapLabel(
      ExcludedGapEvidence(
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 12, 15, 30),
          endUtc: DateTime.utc(2026, 10, 12, 16, 30),
        ),
        code: GapExclusionCode.requiredBreakUnavailable,
      ),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
    );
    expect(
      acrossMidnight,
      contains('10-12 23:30–10-13 00:30'),
      reason: '只写 23:30–00:30 会被读成同一天的倒退区间',
    );
  });
}
