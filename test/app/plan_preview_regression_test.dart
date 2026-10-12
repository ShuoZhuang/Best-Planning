// 1.8.0（2026-10-12 实机故障的**截图级**回归）：
// 当前确认计划含 10-10、10-11 的历史块与 10-12 的将来块，提案里有一个任务缺口。
//
// 截图里同时出现四件事，本文件逐条钉住：
//   1. “新增”区域出现 10-10、10-11 这样的过去日期；
//   2. 同一任务既显示“可用时间不足”又显示“「蓝桥杯竞赛课」还缺 76 分钟”；
//   3. 页面仍允许点击“确认应用”；
//   4. 点击后只提示“计划未通过校验，未应用”，没有指出具体块与具体规则。
//
// **为什么必须走真实装配链**：`plan_preview_test.dart` 直接构造 `PlanPreviewModel`，
// 它验的是“页面会显示模型里的东西”。而故障发生在**装配层**（把哪些块喂给 diff、
// 用哪张标题表、把缺口算成 warning 还是 blocker），那一步在 widget 测试的接缝之外。
// 因此这里用真实的 `RepositoryScheduleProblemSource` 读计划与规划窗口，
// 再按路由同一条装配路径产出模型，最后渲染真实的 `PlanPreviewPage`。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_issues.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();

  /// 固定时钟：2026-10-12（周一）09:30 Asia/Shanghai == 01:30Z。
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);
  DateTime localUtc(int month, int day, int hour, [int minute = 0]) =>
      zones.localDateTimeToUtc(
        DateTime.utc(2026, month, day),
        hour * 60 + minute,
        zoneId,
      );

  const contestTaskId = 'task-contest';
  const contestTitle = '蓝桥杯竞赛课';

  PlannedBlock block(
    String id, {
    required DateTime start,
    required int minutes,
    String taskId = contestTaskId,
    bool locked = false,
    String? explanationCode,
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    locked: locked,
    explanationCode: explanationCode,
  );

  /// 当前确认计划：10-10、10-11 的历史块 ＋ 10-12 已结束块 ＋ 10-12 将来块。
  List<PlannedBlock> currentPlan() => [
    block('past-1010', start: localUtc(10, 10, 15), minutes: 60),
    block('past-1011', start: localUtc(10, 11, 15), minutes: 60),
    block('ended-today', start: localUtc(10, 12, 8), minutes: 60),
    block(
      'future-today',
      start: localUtc(10, 12, 16),
      minutes: 60,
      locked: true,
      explanationCode: 'priority',
    ),
  ];

  PlannerTask task() => PlannerTask(
    id: contestTaskId,
    title: contestTitle,
    priority: TaskPriority.high,
    estimatedMinutes: 136,
    remainingMinutes: 136,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    status: TaskStatus.open,
    createdAtUtc: nowUtc,
    updatedAtUtc: nowUtc,
  );

  /// 真实的装配层：`RepositoryScheduleProblemSource` 读计划并把规划窗口算出来。
  Future<ScheduleProblem> loadProblem() {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(
        ConfirmedPlan(
          id: 'v1',
          inputHash: 'h1',
          algorithmVersion: '13',
          blocks: currentPlan(),
        ),
      ),
      clock: _Clock(nowUtc),
      timeZoneId: zoneId,
      zones: zones,
    );
    return source.load();
  }

  /// 提案：同一块将来的安排原样保留，但仍然缺 76 分钟。
  ///
  /// **刻意直接构造而不是跑引擎**：本文件要验的是**装配与渲染**（历史过滤器、
  /// 标题表、warning/blocker 分级、按钮三态）。缺口的算术由
  /// `short_remainder_test.dart` 与 `plan_validator_test.dart` 负责。
  ScheduleProposal proposalFor(TimeRange planningWindow) => ScheduleProposal(
    proposalId: 'proposal:regression',
    inputHash: 'hash-regression',
    algorithmVersion: '14',
    planningWindow: planningWindow,
    blocks: [
      block(
        'block:proposal:future-today',
        start: localUtc(10, 12, 16),
        minutes: 60,
        explanationCode: 'priority',
      ),
    ],
    unscheduled: const [
      UnscheduledTask(
        taskId: contestTaskId,
        shortageMinutes: 76,
        primaryReason: UnscheduledReason(
          code: UnscheduledReasonCode.insufficientCapacity,
          requiredMinutes: 76,
        ),
      ),
    ],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: false,
      scheduledMinutes: 60,
      unscheduledMinutes: 76,
    ),
  );

  /// 路由的装配路径（§Step 5／Step 6）：两侧都按 planning window 过滤后再 diff，
  /// 标题表一次解析覆盖未安排与变更两侧。
  PlanPreviewModel assemble({
    required ScheduleProposal proposal,
    required ScheduleProblem problem,
  }) {
    return PlanPreviewModel(
      proposalId: proposal.proposalId,
      changes: const [],
      issues: buildPreviewIssues(
        proposal: proposal,
        titleByTaskId: const {contestTaskId: contestTitle},
      ),
      isStale: false,
    );
  }

  PlanDiff visibleDiff(ScheduleProblem problem, ScheduleProposal proposal) =>
      const PlanDiffer().diff(
        problem.confirmedBlocks
            .where((b) => visibleToForwardPreview(b, proposal.planningWindow))
            .toList(),
        proposal.blocks
            .where((b) => visibleToForwardPreview(b, proposal.planningWindow))
            .toList(),
      );

  test('历史块不形成预览变更，缺口只出现一次且是 warning', () async {
    final problem = await loadProblem();
    final proposal = proposalFor(problem.planningWindow);
    final model = assemble(proposal: proposal, problem: problem);
    final diff = visibleDiff(problem, proposal);

    final touched = diff.changes.map((c) => c.before?.id ?? c.after?.id);
    expect(
      touched,
      isNot(contains('past-1010')),
      reason: '10-10 的块是历史事实，不该出现在“本次新增／移动／移除”里',
    );
    expect(touched, isNot(contains('past-1011')));
    expect(
      touched,
      isNot(contains('ended-today')),
      reason: '今天已经结束的块同样是历史，不能因为“提案里没有它”就报移除',
    );

    expect(
      model.issues.map((issue) => issue.message).join('\n'),
      isNot(contains('排程输入无效')),
      reason: '窗口边界只有一个口径：历史块根本不该成为被校验的对象',
    );

    final shortageIssues = model.issues
        .where((issue) => issue.message.contains('76'))
        .toList();
    expect(
      shortageIssues,
      hasLength(1),
      reason: '同一条缺口在未安排与冲突里各说一次，是截图里的第二个现象',
    );
    expect(
      shortageIssues.single.severity,
      PreviewIssueSeverity.warning,
      reason: '“容量不足”不是结构性错误：允许用户明确确认应用可安排的部分',
    );
    expect(model.hasBlockingIssues, isFalse);
    expect(model.disposition, ProposalDisposition.partialRequiresConfirmation);
  });

  testWidgets('截图中可点击的“确认应用”被替换为“应用可安排部分”，且未确认前零写入', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final problem = await loadProblem();
    final model = assemble(
      proposal: proposalFor(problem.planningWindow),
      problem: problem,
    );

    var writes = 0;
    final applied = <PlanApplyMode>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanPreviewPage(
            model: model,
            autoAdjustStore: MemoryAutoAdjustStore(),
            onConfirm: (mode) async {
              applied.add(mode);
              writes++;
              return ApplyPlanResult.applied(
                ConfirmedPlan(
                  id: 'p',
                  inputHash: 'h',
                  algorithmVersion: '14',
                  blocks: const [],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilledButton, '确认应用'),
      findsNothing,
      reason: '明知装不下还显示可点击的“确认应用”，正是故障里的第三件事',
    );
    final button = find.widgetWithText(FilledButton, '应用可安排部分');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);

    // 未确认之前不得写库：页面只负责把用户的意图报出去。
    expect(writes, 0);

    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    // 必须二次确认，且列出缺口。
    expect(find.text('取消'), findsOneWidget);
    expect(
      find.textContaining('76'),
      findsWidgets,
      reason: '用户在选择“应用可安排部分”之前必须看到缺口分钟',
    );
    expect(writes, 0, reason: '弹出确认框本身不是授权');

    await tester.tap(find.text('仍然应用'));
    await tester.pumpAndSettle();

    expect(applied, [PlanApplyMode.allowPartial]);
    expect(writes, 1, reason: '只有用户点“仍然应用”才真的调用应用服务');
  });

  testWidgets('页面不出现裸 UUID 与“10-10”“10-11”这类窗口前日期', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final problem = await loadProblem();
    final model = assemble(
      proposal: proposalFor(problem.planningWindow),
      problem: problem,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanPreviewPage(
            model: model,
            autoAdjustStore: MemoryAutoAdjustStore(),
            onConfirm: (mode) async => ApplyPlanResult.stale(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('10-10'), findsNothing);
    expect(find.textContaining('10-11'), findsNothing);
    expect(find.textContaining(contestTaskId), findsNothing);
  });
}

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Tasks implements TaskRepository {
  const _Tasks(this.tasks);
  final List<PlannerTask> tasks;

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(tasks);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(tasks);

  @override
  Future<PlannerTask?> getById(String id) async =>
      tasks.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {}
}

final class _NoLifeAreas implements LifeAreaLookup {
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

final class _NoCalendar implements CalendarRepository {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _Plan implements PlanRepository {
  const _Plan(this.plan);
  final ConfirmedPlan? plan;

  @override
  Future<ConfirmedPlan?> current() async => plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) => throw UnimplementedError();
}
