// Task 12A Step 6（用户 2026-10-08 的接口决定）：预览显示标题与结构化原因，不显示裸 UUID。
//
// 这个文件钉住那五条实施约束里属于展示侧的三条：
//
// 1. 标题由 `TaskTitleLookup` 提供，**查不到时回落"未命名任务"，绝不回落裸 UUID**；
// 2. 预览只**翻译**引擎给的原因，不自己推测（`unscheduledReasonLabel` 的入参就是
//    `UnscheduledReason`，拿不到任务属性，因此"猜"在类型上就做不到）；
// 3. 一条缺口在整页只出现一次：标题、缺口分钟与主原因在同一处（1.8.0 更正，见下方用例）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_title_lookup.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 一个可编程的标题来源。`known` 里没有的 id 返回 `null`——模拟"任务已被删除"。
final class _Lookup implements TaskTitleLookup {
  _Lookup(this.known);

  final Map<String, String> known;
  final List<List<String>> batchCalls = [];

  @override
  Future<String?> titleFor(String taskId) async => known[taskId];

  @override
  Future<Map<String, String>> titlesFor(Iterable<String> taskIds) async {
    final ids = taskIds.toList();
    batchCalls.add(ids);
    return {
      for (final id in ids)
        if (known[id] != null) id: known[id]!,
    };
  }
}

void main() {
  group('标题解析：绝不回落裸 UUID', () {
    test('查得到就用真名', () async {
      final infos = await resolveTaskDisplayInfos(
        _Lookup({'task-1': '贫困生材料提交'}),
        ['task-1'],
      );

      expect(infos.single.title, '贫困生材料提交');
    });

    test('查不到 ⇒ 未命名任务（不是空串、更不是 id）', () async {
      final infos = await resolveTaskDisplayInfos(_Lookup(const {}), ['ghost']);

      expect(infos.single.title, unnamedTaskLabel);
      expect(
        infos.single.title,
        isNot(contains('ghost')),
        reason: '裸 UUID 对用户毫无意义，而空串会让他不知道那里本该有字',
      );
    });

    test('标题只有空白 ⇒ 同样回落到未命名任务', () async {
      final infos = await resolveTaskDisplayInfos(_Lookup({'task-1': '   '}), [
        'task-1',
      ]);

      expect(infos.single.title, unnamedTaskLabel);
    });

    test('标题两侧空白被去掉（用户很容易多打一个空格）', () async {
      final infos = await resolveTaskDisplayInfos(
        _Lookup({'task-1': '  每周英语  '}),
        ['task-1'],
      );

      expect(infos.single.title, '每周英语');
    });

    test('用批量接口，而且是**一次**调用（不是逐条查）', () async {
      final lookup = _Lookup({'a': 'A', 'b': 'B', 'c': 'C'});
      await resolveTaskDisplayInfos(lookup, ['a', 'b', 'c']);

      expect(
        lookup.batchCalls,
        hasLength(1),
        reason: '逐条查询在真实数据库上就是 N 次往返，列表长度由用户的任务数决定',
      );
      expect(lookup.batchCalls.single, hasLength(3));
    });

    test('空输入不发起查询', () async {
      final lookup = _Lookup(const {});
      expect(await resolveTaskDisplayInfos(lookup, const []), isEmpty);
      expect(lookup.batchCalls, isEmpty);
    });

    test('重复 id 只查一次', () async {
      final lookup = _Lookup({'a': 'A'});
      final infos = await resolveTaskDisplayInfos(lookup, ['a', 'a', 'a']);

      expect(infos, hasLength(1));
      expect(lookup.batchCalls.single, hasLength(1));
    });
  });

  group('原因翻译：只说引擎给的那一条，不推测', () {
    test('连续空档不足把约束口径的两个数字都说出来', () {
      final label = unscheduledReasonLabel(
        const UnscheduledReason(
          code: UnscheduledReasonCode.continuousGapTooShort,
          placementRemainingMinutes: 25,
          constraintRequiredMinutes: 30,
          constraintAvailableMinutes: 20,
        ),
      );

      expect(label, contains('30'));
      expect(label, contains('20'));
    });

    test('缺少数字时不编造数字', () {
      final label = unscheduledReasonLabel(
        const UnscheduledReason(
          code: UnscheduledReasonCode.dailyLimitReached,
          placementRemainingMinutes: 12,
        ),
      );

      expect(label, isNotEmpty);
      expect(
        RegExp(r'\d').hasMatch(label),
        isFalse,
        reason:
            '引擎没给约束数字时正文里不得出现任何数字：凭空写一个"上限"会让用户'
            '按一个不存在的额度去调设置',
      );
    });

    test('枚举里的每一个取值都能翻出一句非空的话', () {
      // 漏一个的后果是那种原因在界面上显示成空行，而用户看到的是"这里什么都没说"。
      for (final code in UnscheduledReasonCode.values) {
        final label = unscheduledReasonLabel(
          UnscheduledReason(code: code, placementRemainingMinutes: 10),
        );
        expect(label.trim(), isNotEmpty, reason: '$code 没有对应文案');
      }
    });
  });

  group('页面上不出现裸 UUID', () {
    Future<void> pump(WidgetTester tester, PlanPreviewModel model) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
    }

    testWidgets('未安排那一行显示标题与主原因，而不是 id', (tester) async {
      const uuid = '3f1c9a4e-7b2d-4c8f-9a11-0d5e6b7c8d9e';
      await pump(
        tester,
        PlanPreviewModel(
          proposalId: 'p1',
          changes: const [
            PreviewChange(
              kind: PreviewChangeKind.unplanned,
              title: '贫困生材料提交 还缺 15 分钟',
              reason: '这件事需要一次做完：需要 30 分钟，可用 20 分钟。',
            ),
          ],
          issues: const [
            PreviewIssue(
              key: 'unscheduled:$uuid',
              severity: PreviewIssueSeverity.warning,
              title: '贫困生材料提交 还缺 15 分钟',
              message: '这件事需要一次做完：需要 30 分钟，可用 20 分钟。',
            ),
          ],
          isStale: false,
        ),
      );

      expect(find.textContaining('贫困生材料提交'), findsWidgets);
      // 这一条是关键：整个渲染树里不得出现那串 UUID。
      expect(
        find.textContaining(uuid),
        findsNothing,
        reason: '裸 UUID 是这一步要消灭的东西',
      );
    });

    // **本用例的期待本轮被纠正**（1.8.0，2026-10-12 实机故障）。
    //
    // 它此前要求"同一条缺口必须同时出现在未安排与冲突两组里"。那是错的，而且正是用户看到的
    // 第二个现象：同一个任务既显示"可用时间不足"又显示"「蓝桥杯竞赛课」还缺 76 分钟"——
    // 两组文案把同一件事说了两遍，用户以为有两个问题。
    //
    // 缺口只有一个结构化来源（`UnscheduledTask`），因此页面上也只该出现一次：
    // **标题 ＋ 缺口分钟 ＋ 主原因**，三件都在同一条里。
    testWidgets('同一条缺口在整页只出现一次（标题＋缺口＋主原因在同一处）', (tester) async {
      await pump(
        tester,
        PlanPreviewModel(
          proposalId: 'p1',
          changes: const [],
          issues: const [
            PreviewIssue(
              key: 'unscheduled:ghost',
              severity: PreviewIssueSeverity.warning,
              title: '贫困生材料提交 还缺 15 分钟',
              message: '这件事需要一次做完：需要 30 分钟，可用 20 分钟。',
            ),
          ],
          isStale: false,
        ),
      );

      expect(
        find.textContaining('贫困生材料提交'),
        findsOneWidget,
        reason: '同一个缺口在两组里各说一次，用户会以为是两件事',
      );
      expect(find.textContaining('还缺 15 分钟'), findsOneWidget);
      expect(find.textContaining('需要 30 分钟'), findsOneWidget);
    });

    // 计划 §1.2 U4 / Task 6 Step 3：**默认只显示主原因**。
    //
    // 证据（每段空档为什么不能用）收在"查看未使用空档"的展开项里。若默认铺开，
    // 用户第一眼看到的是八行空档明细，而最该先处理的那一条主原因反而被挤到下面。
    testWidgets('未使用空档默认收起：首屏只有主原因', (tester) async {
      final issue = PreviewIssue(
        key: 'unscheduled:t-a:30',
        severity: PreviewIssueSeverity.warning,
        title: '写报告 还缺 30 分钟',
        message: '这一天的任务每日上限已经用满。',
        taskId: 't-a',
        excludedGaps: [
          ExcludedGapEvidence(
            range: TimeRange(
              startUtc: DateTime.utc(2026, 10, 12, 6),
              endUtc: DateTime.utc(2026, 10, 12, 6, 30),
            ),
            code: GapExclusionCode.shorterThanRequiredChunk,
          ),
        ],
      );
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanPreviewPage(
              model: PlanPreviewModel(
                proposalId: 'p1',
                changes: const [],
                issues: [issue],
                isStale: false,
              ),
              autoAdjustStore: MemoryAutoAdjustStore(),
              onConfirm: (mode) async => ApplyPlanResult.stale(),
              // 未传 `zones` 时**证据行不渲染**（拿不到时区就只能印 UTC，
              // 那行字会让用户去日历上找一段实际是空的时间）。这里断言的是
              // "收起状态"这一条，因此两种装配都要成立。
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('每日上限'), findsWidgets);
      expect(
        find.textContaining('短于最短片段'),
        findsNothing,
        reason: '默认只显示主原因；每段空档的原因在展开项里',
      );
      expect(find.text('查看未使用空档'), findsNothing, reason: '没有时区时不给出错误的本地时间');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // R7（Task 1 Step 4）：**标题的缺口分钟与正文的"还缺"必须是同一个数字**。
  //
  // 标题走 `UnscheduledTask.shortageMinutes`（"这件事总共还差多少"），
  // 而修复前的正文由 `unscheduledReasonLabel(UnscheduledTask.primaryReason)` 生成，
  // 其中 `_withNumbers()` 会**自己再算一遍**
  // `constraintRequiredMinutes - constraintAvailableMinutes` 并写成第二个"还缺"：
  //
  // ```dart
  // final shortage = required - available;
  // return '$lead：需要 $required 分钟，本次仍可安排 $available 分钟，还缺 $shortage 分钟$tail';
  // ```
  //
  // 而那两个数字**不是总缺口**：`constraintRequiredMinutes` 是某条约束要求的
  // 连续／最小／每日分钟，`constraintAvailableMinutes` 是同一约束口径下的可用分钟
  // （计划 §2.4）。于是同一条问题会出现两个"还缺"，而用户没有任何依据判断哪一个是真的。
  //
  // **Task 5 的处置**：`_withNumbers()` 已删除，每个 code 改用只描述约束的模板，
  // 标题成为**唯一**显示缺口的地方。本组两条用例因此红转绿。
  // ─────────────────────────────────────────────────────────────────────────────
  group('R7：标题缺口与正文数字必须算得通', () {
    ScheduleProposal proposalWith(UnscheduledTask task) => ScheduleProposal(
      proposalId: 'p1',
      inputHash: 'hash',
      algorithmVersion: '15',
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 8),
        endUtc: DateTime.utc(2026, 10, 5, 18),
      ),
      blocks: const [],
      unscheduled: [task],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: false,
        scheduledMinutes: 0,
        unscheduledMinutes: 25,
      ),
    );

    test('标题的缺口分钟等于 UnscheduledTask.shortageMinutes，正文不得再算第二个"还缺"', () {
      const shortageMinutes = 25;
      const constraintRequired = 150;
      const constraintAvailable = 20;
      final proposal = proposalWith(
        const UnscheduledTask(
          taskId: 'task-algo',
          shortageMinutes: shortageMinutes,
          primaryReason: UnscheduledReason(
            // constraint 口径的数字：最短片段要求 150 分钟，当前最长合法空档 20 分钟。
            // 它们**不是**总缺口 —— 25 分钟才是。
            code: UnscheduledReasonCode.minimumChunkTooLarge,
            placementRemainingMinutes: shortageMinutes,
            constraintRequiredMinutes: constraintRequired,
            constraintAvailableMinutes: constraintAvailable,
          ),
        ),
      );

      final issues = buildPreviewIssues(
        proposal: proposal,
        titleByTaskId: const {'task-algo': '算法作业'},
      );
      expect(
        issues,
        hasLength(1),
        reason: '一条缺口只该产生一条问题（缺口的唯一结构化来源是 unscheduled）',
      );
      final issue = issues.single;

      expect(
        issue.title,
        contains('还缺 $shortageMinutes 分钟'),
        reason: '标题里的缺口分钟必须就是 UnscheduledTask.shortageMinutes = 25',
      );
      expect(
        issue.message,
        contains('$constraintRequired'),
        reason: '原因正文仍要把约束口径的数字说出来（"要求 150 分钟"是有用的信息）',
      );
      expect(
        issue.message,
        contains('$constraintAvailable'),
        reason: '原因正文仍要把约束口径的可用量说出来（"当前最长空档 20 分钟"）',
      );

      // **R7 的核心**：正文不得出现由 constraint 数字另算出来的第二个"还缺"。
      expect(
        issue.message,
        isNot(contains('还缺')),
        reason:
            '**R7**：UI 不得再计算 `constraintRequiredMinutes - constraintAvailableMinutes` '
            '（此处 150 − 20 = 130）并称之为"还缺"。'
            '"还缺多少"只显示 `UnscheduledTask.shortageMinutes`（此处 25）。'
            '计划 §2.4：原因正文只描述约束，例如'
            '「最短片段要求 30 分钟，当前最长合法空档 20 分钟」',
      );

      // 把两个数字都摆出来，让失败信息本身就能核对。
      expect(
        issue.message,
        isNot(contains('还缺 ${constraintRequired - constraintAvailable} 分钟')),
        reason: '这一条是上一条的具体化：正文里那个"还缺"正是 130',
      );
    });

    test('真实引擎给出的一条缺口同样只出现一个缺口数字', () {
      // 与上面构造的输入同形：总缺口 25、约束口径 150/20。
      // 这里只断言"整页里 ≥ 两个不同的『还缺 N 』"这件事没有发生。
      final proposal = proposalWith(
        const UnscheduledTask(
          taskId: 'task-algo',
          shortageMinutes: 25,
          primaryReason: UnscheduledReason(
            code: UnscheduledReasonCode.deadlineWindowTooShort,
            placementRemainingMinutes: 25,
            constraintRequiredMinutes: 150,
            constraintAvailableMinutes: 20,
          ),
        ),
      );
      final issue = buildPreviewIssues(
        proposal: proposal,
        titleByTaskId: const {'task-algo': '算法作业'},
      ).single;

      final shortages = RegExp(r'还缺 (\d+) 分钟')
          .allMatches('${issue.title}\n${issue.message}')
          .map((m) => m.group(1));
      expect(
        shortages.toSet(),
        {'25'},
        reason:
            '整页关于这一条缺口只能有一个数字：`shortageMinutes`。'
            '实测修复前给出两个（标题 25、正文 130）',
      );
    });
  });
}
