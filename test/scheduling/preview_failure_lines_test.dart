// 1.8.0（设计规范 §13.1／§13.2，计划 Task 14）：延后失败接入现有的标题与结构化解释链。
//
// 规范 §13.2 的要求不是"另造一套原因模型"，而是**复用**现有的
// `UnscheduledReason` / `UnscheduledReasonCode` 与标题解析，并让延后那条路径也走它们。
// §13.1 另有一条硬要求：**任何找不到标题的项使用占位文案，不得回退成 UUID**。
//
// 因此本文件钉三件事：
// 1. 失败行**带事项标题**（不是 id）；
// 2. 找不到标题时用占位文案——**任何一行里都不出现任务 id**；
// 3. 行数与顺序确定。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/preview_failure_lines.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  /// 一个**形如真实 UUID** 的 id：如果它出现在任何输出里，用例必须能认出来。
  const uuidA = '3f1a9c62-7b04-4d1e-9a55-0c8e2b7d4f31';
  const uuidB = 'b28d4e50-1c93-4a7f-8e21-5d6f9a0b3c47';

  UnscheduledTask unscheduled(
    String taskId, {
    int shortageMinutes = 30,
    UnscheduledReasonCode code = UnscheduledReasonCode.insufficientCapacity,
    int? requiredMinutes = 60,
    int? availableMinutes = 30,
    String? constraintLabel,
  }) => UnscheduledTask(
    taskId: taskId,
    shortageMinutes: shortageMinutes,
    primaryReason: UnscheduledReason(
      code: code,
      requiredMinutes: requiredMinutes,
      availableMinutes: availableMinutes,
      constraintLabel: constraintLabel,
    ),
  );

  ScheduleProposal proposal({
    List<UnscheduledTask> unscheduledTasks = const [],
    List<PlanningConflict> conflicts = const [],
  }) => ScheduleProposal(
    proposalId: 'p1',
    inputHash: 'h1',
    algorithmVersion: 'test',
    blocks: const [],
    conflicts: conflicts,
    unscheduled: unscheduledTasks,
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: false,
      scheduledMinutes: 0,
      unscheduledMinutes: 0,
    ),
  );

  test('失败行写的是**标题**，不是任务 id（规范 §13.1）', () {
    final lines = previewFailureLines(
      proposal: proposal(unscheduledTasks: [unscheduled(uuidA)]),
      titleByTaskId: const {uuidA: '贫困生材料提交'},
    );

    expect(lines, hasLength(1));
    expect(lines.single.title, '贫困生材料提交');
    expect(
      formatFailureLine(lines.single),
      isNot(contains('3f1a9c62')),
      reason: '规范 §13.1 与全局不变量第 7 条：绝不向用户显示任务 UUID',
    );
  });

  test('标题缺失时用占位文案，**仍不回退成 id**', () {
    final lines = previewFailureLines(
      proposal: proposal(unscheduledTasks: [unscheduled(uuidA)]),
      titleByTaskId: const {},
    );

    expect(lines.single.title, unnamedTaskLabel);
    expect(formatFailureLine(lines.single), isNot(contains(uuidA)));
  });

  test('空白标题按缺失处理（不是"标题是空格"）', () {
    final lines = previewFailureLines(
      proposal: proposal(unscheduledTasks: [unscheduled(uuidA)]),
      titleByTaskId: const {uuidA: '   '},
    );

    expect(lines.single.title, unnamedTaskLabel);
  });

  test('原因走既有的结构化翻译链，带得出差多少分钟', () {
    final lines = previewFailureLines(
      proposal: proposal(
        unscheduledTasks: [
          unscheduled(
            uuidA,
            code: UnscheduledReasonCode.continuousGapTooShort,
            requiredMinutes: 90,
            availableMinutes: 10,
          ),
        ],
      ),
      titleByTaskId: const {uuidA: '贫困生材料提交'},
    );

    final text = formatFailureLine(lines.single);
    expect(text, startsWith('贫困生材料提交：'));
    expect(
      text,
      contains('10'),
      reason: '规范 §13.2 要求带上证据数字；"可用时间不足"这种笼统话正是要消灭的',
    );
    expect(text, contains('90'));
  });

  test('冲突也出现在同一份清单里，且用冲突自己的标签作标题位', () {
    final lines = previewFailureLines(
      proposal: proposal(
        conflicts: [PlanningConflict(code: ConflictCode.protectedTimeOverlap)],
      ),
      titleByTaskId: const {},
    );

    expect(lines, hasLength(1));
    expect(lines.single.title, '占用了保护时间');
  });

  test('行数上限生效，且**优先保留缺口**（用户最需要先知道的）', () {
    final lines = previewFailureLines(
      proposal: proposal(
        unscheduledTasks: [
          unscheduled(uuidA, shortageMinutes: 90),
          unscheduled(uuidB, shortageMinutes: 60),
        ],
        conflicts: [PlanningConflict(code: ConflictCode.protectedTimeOverlap)],
      ),
      titleByTaskId: const {uuidA: '甲', uuidB: '乙'},
      maximumLines: 2,
    );

    expect(lines, hasLength(2));
    expect(lines.map((line) => line.title), ['甲', '乙']);
  });

  test('上限为零时返回空清单，而不是把上限当"不限"', () {
    final lines = previewFailureLines(
      proposal: proposal(unscheduledTasks: [unscheduled(uuidA)]),
      titleByTaskId: const {uuidA: '甲'},
      maximumLines: 0,
    );

    expect(lines, isEmpty);
  });

  test('顺序确定：同一次输入连算两次逐值相同', () {
    ScheduleProposal input() => proposal(
      unscheduledTasks: [
        unscheduled(uuidB, shortageMinutes: 60),
        unscheduled(uuidA, shortageMinutes: 90),
      ],
      conflicts: [PlanningConflict(code: ConflictCode.blockOverlap)],
    );

    final first = previewFailureLines(
      proposal: input(),
      titleByTaskId: const {uuidA: '甲', uuidB: '乙'},
    );
    final second = previewFailureLines(
      proposal: input(),
      titleByTaskId: const {uuidA: '甲', uuidB: '乙'},
    );

    expect(
      first.map(formatFailureLine),
      second.map(formatFailureLine),
      reason: '顺序不确定会让同一次失败两次显示不同的清单',
    );
  });

  test('缺口分钟为零的条目不再重复报一次', () {
    // `shortageMinutes == 0` 表示"其实排进去了"；把它当失败行会让用户看到
    // "某某：还缺 0 分钟"这种自相矛盾的话。
    final lines = previewFailureLines(
      proposal: proposal(
        unscheduledTasks: [unscheduled(uuidA, shortageMinutes: 0)],
      ),
      titleByTaskId: const {uuidA: '甲'},
    );

    expect(lines, isEmpty);
  });
}
