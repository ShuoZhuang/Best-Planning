import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

void main() {
  // ─────────────────────────────────────────────────────────────────────────────
  // M4（路线图 §8）调整预览：**五类分组**与**原时间／目标时间**。
  // 规格见 `docs/superpowers/specs/2026-10-07-m4-today-execution.md` §4.5。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('M4 预览按五类分组，含「未安排」与「保护时间变化」', (tester) async {
    // §8 原文要求按"新增、移动、拆分、未安排、保护时间变化"分组。
    // 此前 `PreviewChangeKind` 只有四类，且第四类叫「移除」而不是「未安排」——
    // 用户看不懂"未排进去的任务"为什么被写成"移除"（它没有被移除，只是没排下）。
    final model = PlanPreviewModel(
      proposalId: 'proposal-groups',
      changes: const [
        PreviewChange(
          kind: PreviewChangeKind.added,
          title: '新增复习',
          reason: 'r',
        ),
        PreviewChange(
          kind: PreviewChangeKind.moved,
          title: '移动实验',
          reason: 'r',
        ),
        PreviewChange(
          kind: PreviewChangeKind.split,
          title: '拆分论文',
          reason: 'r',
        ),
        PreviewChange(
          kind: PreviewChangeKind.unplanned,
          title: '大物预习',
          reason: '缺 40 分钟',
        ),
        PreviewChange(
          kind: PreviewChangeKind.protectedTimeChanged,
          title: '午餐时间',
          reason: '规则调整',
        ),
      ],
      issues: const [],
      isStale: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in const ['新增', '移动', '拆分', '未安排', '保护时间变化']) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '五类分组里「$label」必须各自有一个分组标题',
      );
    }
    // 旧的「移除」标签在五类体系里已由「未安排」承担；不该两套并存。
    expect(find.text('移除'), findsNothing, reason: '不能同时留着旧标签，否则同一件事有两个说法');
    // 分组里的条目也要真的渲染出来。
    expect(find.text('大物预习'), findsOneWidget);
    expect(find.text('午餐时间'), findsOneWidget);
  });

  testWidgets('M4 移动类条目同时显示原时间与目标时间', (tester) async {
    // §8 要求"显示原时间、目标时间和原因"。只给原因，用户看不出**从哪挪到哪**。
    final model = PlanPreviewModel(
      proposalId: 'proposal-times',
      changes: const [
        PreviewChange(
          kind: PreviewChangeKind.moved,
          title: '实验',
          reason: '匹配高精力时段',
          fromLabel: '10-05 09:00–10:00',
          toLabel: '10-05 14:00–15:00',
        ),
        PreviewChange(
          kind: PreviewChangeKind.added,
          title: '新任务',
          reason: '临近截止',
          // 新增没有"原时间"——这是正常的，不显示即可。
          toLabel: '10-06 09:00–10:00',
        ),
        PreviewChange(
          kind: PreviewChangeKind.unplanned,
          title: '没排下的任务',
          reason: '缺 40 分钟',
          // 未安排没有"目标时间"。
          fromLabel: '10-07 09:00–10:00',
        ),
      ],
      issues: const [],
      isStale: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // **断言要限定在那一张卡内**：展开是叠加的（前一张不会自动收起），
    // 全页 `textContaining('原时间')` 会把上一张的内容也算进来，
    // 于是"新增没有原时间"这条会误报成失败。
    Finder inTile(String title, String text) => find.descendant(
      of: find.ancestor(
        of: find.text(title),
        matching: find.byType(ExpansionTile),
      ),
      matching: find.textContaining(text),
    );

    await tester.tap(find.text('实验'));
    await tester.pumpAndSettle();
    expect(inTile('实验', '10-05 09:00–10:00'), findsOneWidget, reason: '要显示原时间');
    expect(
      inTile('实验', '10-05 14:00–15:00'),
      findsOneWidget,
      reason: '要显示目标时间',
    );
    expect(inTile('实验', '匹配高精力时段'), findsOneWidget, reason: '原因不能丢');

    // 新增只显示目标时间。
    await tester.tap(find.text('新任务'));
    await tester.pumpAndSettle();
    expect(inTile('新任务', '10-06 09:00–10:00'), findsOneWidget);
    expect(inTile('新任务', '原时间'), findsNothing, reason: '新增没有原时间，不该硬编一个');

    // 未安排只显示原时间。
    // **先滚到它**：三张卡依次展开后它已经落到视口外，`tap` 会静默打空
    // （只留一句 "would not hit test" 警告），断言就会报"找不到"——很像产品缺陷的假象。
    await tester.ensureVisible(find.text('没排下的任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('没排下的任务'));
    await tester.pumpAndSettle();
    expect(inTile('没排下的任务', '10-07 09:00–10:00'), findsOneWidget);
    expect(inTile('没排下的任务', '目标时间'), findsNothing, reason: '未安排没有目标时间');
  });

  testWidgets('preview groups every change and expands reasons', (
    tester,
  ) async {
    final model = PlanPreviewModel(
      proposalId: 'proposal-1',
      changes: const [
        PreviewChange(
          kind: PreviewChangeKind.added,
          title: '新增复习',
          reason: '临近截止时间',
        ),
        PreviewChange(
          kind: PreviewChangeKind.moved,
          title: '移动实验',
          reason: '匹配高精力时段',
        ),
        PreviewChange(
          kind: PreviewChangeKind.split,
          title: '拆分论文',
          reason: '分成两个专注片段',
        ),
        PreviewChange(
          kind: PreviewChangeKind.unplanned,
          title: '没排下的游戏',
          reason: '当天容量不足',
        ),
      ],
      issues: const [
        PreviewIssue(
          key: 'conflict:0',
          severity: PreviewIssueSeverity.blocking,
          title: '任务时间块相互重叠',
          message: '周三缺少 30 分钟',
        ),
      ],
      isStale: true,
    );
    final store = MemoryAutoAdjustStore();
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: store,
          onConfirm: (mode) async => ApplyPlanResult.stale(),
          onRecalculate: () async {},
        ),
      ),
    );

    expect(find.text('新增'), findsOneWidget);
    expect(find.text('移动'), findsOneWidget);
    expect(find.text('拆分'), findsOneWidget);
    // M4：第四类从「移除」改称「未安排」——没排进去不等于被移除，任务还在列表里。
    expect(find.text('未安排'), findsOneWidget);
    // 1.8.0：这一组不再是字符串冲突列表，而是**分级的问题卡片**
    // （blocking 与 warning 用不同标题，见 `_IssueGroup`）。
    expect(find.text('无法应用的问题'), findsOneWidget);
    expect(find.text('周三缺少 30 分钟'), findsOneWidget);

    await tester.tap(find.text('移动实验'));
    await tester.pumpAndSettle();
    expect(find.text('匹配高精力时段'), findsOneWidget);

    // 过期 + 阻断 ⇒ **应用入口一个都不渲染**，主操作是可点的「重新生成计划」。
    //
    // 本轮断言被改写（计划 §2.8 三态表 / Task 6 Step 4）：修复前这里断言的是
    // `FilledButton('无法应用').onPressed == null`——"把按钮禁用"来伪装问题解决，
    // 正是计划 §6 明令禁止的捷径。现在阻断与过期**根本不渲染应用按钮**，
    // 屏幕上的主操作是那个真正该做的动作。
    expect(find.text('无法应用'), findsNothing, reason: '不许用禁用按钮伪装"已经处理"');
    expect(find.widgetWithText(FilledButton, '确认应用'), findsNothing);
    expect(find.widgetWithText(FilledButton, '应用可安排部分'), findsNothing);
    expect(find.text('提案已过期，请重新计算'), findsOneWidget);
    final recalculate = tester.widget<FilledButton>(
      find.byKey(const Key('recalculate-plan')),
    );
    expect(
      recalculate.onPressed,
      isNotNull,
      reason: '§2.8：无法解释／过期的**主操作**就是可点的"重新生成计划"',
    );
    // U3：预览页不再有"信任自动调整"开关（它只留在设置页）。
    expect(find.text('信任自动调整'), findsNothing);
    expect(store.enabled, isFalse);
  });

  testWidgets(
    'auto adjust switch lives in settings; preview still records history',
    (tester) async {
      // 本用例本轮被改写（计划 §1.2 U3 / Task 6 Step 5）：预览页的
      // `SwitchListTile('信任自动调整')` 已删除，因此"点开关"那一段不再存在。
      // 保留下来的是它真正要证明的那件事：**确认预览仍然记录历史**，
      // 以及那个开关不再出现在这一页。
      final store = MemoryAutoAdjustStore();
      var confirmations = 0;
      final model = PlanPreviewModel(
        proposalId: 'proposal-2',
        changes: const [
          PreviewChange(
            kind: PreviewChangeKind.added,
            title: '新增任务',
            reason: '优先级较高',
          ),
        ],
        issues: const [],
        isStale: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlanPreviewPage(
            model: model,
            autoAdjustStore: store,
            onConfirm: (mode) async {
              confirmations++;
              return ApplyPlanResult.stale();
            },
          ),
        ),
      );

      expect(
        find.byType(SwitchListTile),
        findsNothing,
        reason: 'U3：失败预览里不再有"信任自动调整"开关，开关只留在设置页',
      );
      expect(find.text('信任自动调整'), findsNothing);

      await tester.ensureVisible(find.text('确认应用'));
      await tester.tap(find.text('确认应用'));
      await tester.pumpAndSettle();

      expect(store.history, contains('proposal-2'));
      expect(confirmations, 1);
    },
  );
  // FR-REPLAN-08：撤销入口。两条用例分别钉住"确实撤销时给出已撤销"，以及"无可撤销时
  // 这是正常结局而不是故障"——后者若被当成异常，用户会看到一个错误提示。
  testWidgets('undo button reports the outcome it actually got', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        // **必须包一层 `Scaffold`**：`showPlannerMessage` 只在"能画出来"时才画
        // （`canShowPlannerMessage`：既要能拿到 `ScaffoldMessenger`，又要有 `Scaffold` 后代）。
        // 裸 `MaterialApp(home: Page)` 里 `MaterialApp` 自带 messenger 却没有 scaffold，
        // `showSnackBar` 会断言失败，因此那个守卫会选择**悄悄不发**。
        // 结果是"点击确实生效了、消息却没画"，测试失败信息看着像"撤销没生效"——很难查。
        home: Scaffold(
          body: PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: 'proposal-1',
              changes: const [],
              issues: const [],
              isStale: false,
            ),
            autoAdjustStore: MemoryAutoAdjustStore(),
            onConfirm: (mode) async => ApplyPlanResult.stale(),
            onUndoPlan: () async {
              calls++;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('undo-plan')));
    await tester.tap(find.byKey(const Key('undo-plan')));
    await tester.pumpAndSettle();

    expect(calls, 1);
    // 断言文案：只断言"点到了"无法区分"撤销成功"与"无可撤销"。
    expect(find.text('已撤销上一次计划'), findsOneWidget);
  });

  testWidgets('undo button says so when there is nothing to undo', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        // 同上：没有 `Scaffold` 时消息会被守卫丢弃，这条用例就永远看不到那句文案。
        home: Scaffold(
          body: PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: 'proposal-1',
              changes: const [],
              issues: const [],
              isStale: false,
            ),
            autoAdjustStore: MemoryAutoAdjustStore(),
            onConfirm: (mode) async => ApplyPlanResult.stale(),
            onUndoPlan: () async => false,
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('undo-plan')));
    await tester.tap(find.byKey(const Key('undo-plan')));
    await tester.pumpAndSettle();

    expect(find.text('没有可撤销的已执行计划'), findsOneWidget);
  });

  testWidgets('no undo button when nothing is wired', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: PlanPreviewModel(
            proposalId: 'proposal-1',
            changes: const [],
            issues: const [],
            isStale: false,
          ),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
        ),
      ),
    );

    // 宁可没有按钮，也不要一个点了不生效的图标。
    expect(find.byKey(const Key('undo-plan')), findsNothing);
  });

  // 技术设计时序图里 `else stale` 分支写的是 `staleProposal; request recalculation`。
  // 在补这个入口之前，过期时页面只显示「该调整提案已失效，请重新生成计划」而**确认按钮同时
  // 被禁用、卡片也不可点**——流程要求用户重新计算，界面上却没有任何地方能做这件事。而这条
  // 路真的会走到：提案只存在内存里，应用重启或重新生成后旧链接必然失效
  // （`router.dart` 的 `preview(proposalId) == null` 分支）。下面三条把这个入口钉住。
  PlanPreviewModel staleModel({required bool stale}) => PlanPreviewModel(
    proposalId: 'proposal-1',
    changes: const [],
    issues: const [],
    isStale: stale,
  );

  testWidgets('过期时给出「重新生成计划」入口，并真的调用回调', (tester) async {
    var recalculated = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: staleModel(stale: true),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
          onRecalculate: () async => recalculated++,
        ),
      ),
    );

    expect(find.text('提案已过期，请重新计算'), findsOneWidget);
    final button = find.byKey(const Key('recalculate-plan'));
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(recalculated, 1);
  });

  testWidgets('过期但未装配重新生成时，不给一个点了不生效的按钮', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: staleModel(stale: true),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
        ),
      ),
    );

    // 提示照旧要显示（用户得知道当前这份预览不能应用），但**不能**给一个无法生效的入口。
    expect(find.text('提案已过期，请重新计算'), findsOneWidget);
    expect(find.byKey(const Key('recalculate-plan')), findsNothing);
  });

  testWidgets('未过期时不显示重新生成入口（它是过期状态专用的）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: staleModel(stale: false),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
          onRecalculate: () async {},
        ),
      ),
    );

    expect(find.byKey(const Key('recalculate-plan')), findsNothing);
    // 未过期时确认按钮必须是可用的——否则"能重新生成"会掩盖"根本没能确认"。
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认应用'),
    );
    expect(confirm.onPressed, isNotNull);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 1.8.0（2026-10-12 故障；冻结决策 §1.6）：**三态按钮与二次确认**。
  //
  // 这一组直接复现截图里的第三、四件事：
  //   · 明知装不下，页面仍显示可点击的「确认应用」；
  //   · 点击后只提示"计划未通过校验，未应用"，之后还能继续点同一个必失败按钮。
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> pumpModel(
    WidgetTester tester,
    PlanPreviewModel model, {
    required Future<ApplyPlanResult> Function(PlanApplyMode mode) onConfirm,
    Future<void> Function()? onRecalculate,
    Future<void> Function(PreviewRecoveryAction action, PreviewIssue issue)?
    onRecover,
    Set<PreviewRecoveryAction> availableRecoveryActions = const {},
    TimeZoneDatabase? zones,
    String? timeZoneId,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanPreviewPage(
            model: model,
            autoAdjustStore: MemoryAutoAdjustStore(),
            onConfirm: onConfirm,
            onRecalculate: onRecalculate,
            onRecover: onRecover,
            availableRecoveryActions: availableRecoveryActions,
            zones: zones,
            timeZoneId: timeZoneId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  PlanPreviewModel modelWith({
    List<PreviewIssue> issues = const [],
    List<PreviewChange> changes = const [],
    bool stale = false,
  }) => PlanPreviewModel(
    proposalId: 'proposal-1',
    changes: changes,
    issues: issues,
    isStale: stale,
  );

  const warningIssue = PreviewIssue(
    key: 'unscheduled:t-a:30',
    severity: PreviewIssueSeverity.warning,
    title: '写报告 还缺 30 分钟',
    message: '可用时间不足：需要 30 分钟。',
  );

  const blockerIssue = PreviewIssue(
    key: 'conflict:0:invalidInput',
    severity: PreviewIssueSeverity.blocking,
    title: '写报告',
    message: '写报告：时间块早于本次规划范围（这一块 15 分钟）',
  );

  testWidgets('blocker ⇒ 不渲染应用入口，主操作是可点的"重新生成计划"', (tester) async {
    // **本用例本轮被改写**（计划 §2.8 / Task 6 Step 4）：它此前断言
    // `FilledButton('无法应用').onPressed == null`——那正是"用禁用按钮伪装问题解决"。
    // 现在阻断状态下应用按钮**不存在**，而主操作是真正该做的那件事。
    var calls = 0;
    var recalculated = 0;
    await pumpModel(
      tester,
      modelWith(issues: const [blockerIssue]),
      onConfirm: (mode) async {
        calls++;
        return ApplyPlanResult.stale();
      },
      onRecalculate: () async => recalculated++,
    );

    expect(find.text('无法应用'), findsNothing);
    expect(find.widgetWithText(FilledButton, '确认应用'), findsNothing);
    final main = tester.widget<FilledButton>(
      find.byKey(const Key('recalculate-plan')),
    );
    expect(main.onPressed, isNotNull, reason: '无法解释／结构错误的主操作必须**可点**');
    expect(calls, 0, reason: '阻断时不得调用应用服务');

    await tester.tap(find.byKey(const Key('recalculate-plan')));
    await tester.pumpAndSettle();
    expect(recalculated, 1, reason: '那个可点的主操作必须真的走到重新生成');
    expect(calls, 0);
  });

  testWidgets('warning ⇒ 次要的"仍应用可安排部分"；取消对话框调用 0 次，确认后传 allowPartial', (
    tester,
  ) async {
    final modes = <PlanApplyMode>[];
    await pumpModel(
      tester,
      modelWith(issues: const [warningIssue]),
      onConfirm: (mode) async {
        modes.add(mode);
        return ApplyPlanResult.applied(
          ConfirmedPlan(
            id: 'p',
            inputHash: 'h',
            algorithmVersion: '14',
            blocks: const [],
          ),
        );
      },
    );

    // **本轮改动**（§2.8 三态表 / §1.2 U2）：部分应用从全宽 `FilledButton`
    // 降级为次要的 `OutlinedButton`，文案也改成"仍应用可安排部分"。
    final button = find.widgetWithText(OutlinedButton, '仍应用可安排部分');
    expect(button, findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '确认应用'),
      findsNothing,
      reason: '可解释的真实缺口下，底部不得放误导性的全宽主按钮',
    );

    // 第一次：取消。
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
    // 对话框里必须列出**全部缺口**（标题＋原因），并说明未安排部分仍在待办中。
    expect(find.text('写报告 还缺 30 分钟'), findsWidgets);
    expect(find.textContaining('仍留在待办中'), findsOneWidget);
    expect(modes, isEmpty, reason: '弹出确认框本身不是授权');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(modes, isEmpty, reason: '取消之后不得写库');

    // 第二次：仍然应用。
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然应用'));
    await tester.pumpAndSettle();
    expect(modes, [PlanApplyMode.allowPartial]);
  });

  testWidgets('clean ⇒ 直接调用 completeOnly', (tester) async {
    final modes = <PlanApplyMode>[];
    await pumpModel(
      tester,
      modelWith(),
      onConfirm: (mode) async {
        modes.add(mode);
        return ApplyPlanResult.applied(
          ConfirmedPlan(
            id: 'p',
            inputHash: 'h',
            algorithmVersion: '14',
            blocks: const [],
          ),
        );
      },
    );

    await tester.tap(find.widgetWithText(FilledButton, '确认应用'));
    await tester.pumpAndSettle();
    expect(modes, [PlanApplyMode.completeOnly]);
  });

  testWidgets('stale ⇒ 主操作是可点的"重新生成计划"，且没有应用入口', (tester) async {
    // **本用例本轮被改写**（§2.8 三态表）：修复前这里断言的是
    // `FilledButton('无法应用').onPressed == null` + 一条次要的重新生成入口。
    // 现在过期状态的主操作**就是**那个可点的"重新生成计划"。
    var recalculated = 0;
    await pumpModel(
      tester,
      modelWith(stale: true),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      onRecalculate: () async => recalculated++,
    );

    expect(find.text('无法应用'), findsNothing);
    expect(find.widgetWithText(FilledButton, '确认应用'), findsNothing);
    final main = tester.widget<FilledButton>(
      find.byKey(const Key('recalculate-plan')),
    );
    expect(main.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('recalculate-plan')));
    await tester.pumpAndSettle();
    expect(recalculated, 1);
  });

  testWidgets('五类里只有有内容的组显示；全空时只给一句"没有计划时间变更"', (tester) async {
    await pumpModel(
      tester,
      modelWith(),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
    );

    for (final label in const ['新增', '移动', '拆分', '未安排', '保护时间变化']) {
      expect(
        find.text(label),
        findsNothing,
        reason: '空分组不再渲染，否则五张"无"卡片会把真正的问题挤出屏幕',
      );
    }
    expect(find.text('没有计划时间变更'), findsOneWidget);

    // 只有"新增"有内容时，其余四类仍然不渲染。
    await pumpModel(
      tester,
      modelWith(
        changes: const [
          PreviewChange(kind: PreviewChangeKind.added, title: 'A', reason: 'r'),
        ],
      ),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
    );
    expect(find.text('新增'), findsOneWidget);
    expect(find.text('移动'), findsNothing);
    expect(find.text('没有计划时间变更'), findsNothing);
  });

  testWidgets('应用返回 invalid ⇒ 显示具体原因，且不能继续点击同一个失败按钮', (tester) async {
    var calls = 0;
    var recalculated = 0;
    await pumpModel(
      tester,
      modelWith(),
      onConfirm: (mode) async {
        calls++;
        return ApplyPlanResult.invalid([
          PlanningConflict(
            code: ConflictCode.invalidInput,
            taskId: 't-a',
            invalidInputReason: InvalidInputReason.startsBeforePlanningWindow,
            details: const {'durationMinutes': 15},
          ),
        ]);
      },
      onRecalculate: () async => recalculated++,
    );

    await tester.tap(find.widgetWithText(FilledButton, '确认应用'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    // 具体原因可见（不是"计划未通过校验"）。
    expect(find.text('应用未完成'), findsOneWidget);
    expect(find.textContaining('早于本次规划范围'), findsWidgets);

    // 失败之后**应用入口消失**：不允许无限重复点击同一个必失败操作。
    // （本轮改动：此前是一个禁用的"无法应用"按钮 + 次要的重新生成入口，
    //  现在主操作直接就是可点的"重新生成计划"，见 §2.8 三态表。）
    expect(find.widgetWithText(FilledButton, '确认应用'), findsNothing);
    final main = tester.widget<FilledButton>(
      find.byKey(const Key('recalculate-plan')),
    );
    expect(main.onPressed, isNotNull);

    // 再点也不会触发新的应用调用：那个按钮已经不在页面上了。
    await tester.tap(find.byKey(const Key('recalculate-plan')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(recalculated, 1);
  });

  testWidgets('快速双击确认只发生一次写入', (tester) async {
    var calls = 0;
    await pumpModel(
      tester,
      modelWith(),
      onConfirm: (mode) async {
        calls++;
        // 模拟"写库还没回来"：在此期间第二次点击必须被 `_applying` 挡住。
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return ApplyPlanResult.applied(
          ConfirmedPlan(
            id: 'p',
            inputHash: 'h',
            algorithmVersion: '14',
            blocks: const [],
          ),
        );
      },
    );

    final button = find.widgetWithText(FilledButton, '确认应用');
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '`_applying` 期间所有应用入口都必须是禁用的');
  });

  testWidgets('页面不出现裸 UUID', (tester) async {
    const uuid = '3f1a9c62-7b04-4d1e-9a55-0c8e2b7d4f31';
    await pumpModel(
      tester,
      modelWith(
        issues: const [
          PreviewIssue(
            key: 'unscheduled:$uuid:30',
            severity: PreviewIssueSeverity.warning,
            title: '未命名任务 还缺 30 分钟',
            message: '可用时间不足：需要 30 分钟。',
          ),
        ],
      ),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
    );

    expect(find.textContaining(uuid), findsNothing);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 计划 §2.8 / Task 6 Step 1～3：**恢复动作**与**未使用空档证据**。
  //
  // 这一组验的是页面侧的三件事：
  //   ① 每条问题卡按 `issue.actions` 显示动作，并把（动作，问题）原样报给装配层；
  //   ② **不能做的动作不显示**（未装配、缺 taskId、阻断问题）——
  //      给一个点了没反应的按钮比不给更糟；
  //   ③ 空档证据默认收起，首屏最多 6 行，其余折叠成"另有 N 段"，且写的是**本地**时间。
  // ─────────────────────────────────────────────────────────────────────────────

  PreviewIssue warningWithActions({
    String? taskId = 't-a',
    List<PreviewRecoveryAction> actions = const [
      PreviewRecoveryAction.openPlanningRules,
    ],
  }) => PreviewIssue(
    key: 'unscheduled:t-a:30',
    severity: PreviewIssueSeverity.warning,
    title: '写报告 还缺 30 分钟',
    message: '每日上限已经用满。',
    taskId: taskId,
    actions: actions,
  );

  testWidgets('恢复动作按 issue.actions 显示，并把（动作，问题）交给装配层', (tester) async {
    final received = <String>[];
    final issue = warningWithActions(
      actions: const [
        PreviewRecoveryAction.openPlanningRules,
        PreviewRecoveryAction.editTask,
      ],
    );
    await pumpModel(
      tester,
      modelWith(issues: [issue]),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      onRecover: (action, recovered) async =>
          received.add('${action.name}:${recovered.key}'),
      availableRecoveryActions: const {
        PreviewRecoveryAction.openPlanningRules,
        PreviewRecoveryAction.editTask,
      },
    );

    // 文案是用户语言，不是枚举名。
    expect(find.text('调整规划规则'), findsOneWidget);
    expect(find.text('编辑任务'), findsOneWidget);
    expect(find.textContaining('openPlanningRules'), findsNothing);

    await tester.tap(find.byKey(Key('recovery-${issue.key}-editTask')));
    await tester.pumpAndSettle();

    expect(received, ['editTask:${issue.key}']);
  });

  testWidgets('未装配的动作、缺 taskId 的"编辑任务"都不显示', (tester) async {
    await pumpModel(
      tester,
      modelWith(
        issues: [
          warningWithActions(
            taskId: null,
            actions: const [
              PreviewRecoveryAction.editTask,
              PreviewRecoveryAction.openProtectedTimeManagement,
            ],
          ),
        ],
      ),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      onRecover: (action, issue) async {},
      // 保护时间管理这次没接线；editTask 虽在集合里，但这条问题没有 taskId。
      availableRecoveryActions: const {PreviewRecoveryAction.editTask},
    );

    expect(find.text('编辑任务'), findsNothing);
    expect(find.text('管理保护时间'), findsNothing);
  });

  testWidgets('完全没有装配恢复回调时，一条动作都不渲染', (tester) async {
    await pumpModel(
      tester,
      modelWith(issues: [warningWithActions()]),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      availableRecoveryActions: const {PreviewRecoveryAction.openPlanningRules},
    );

    expect(find.text('调整规划规则'), findsNothing);
  });

  testWidgets('阻断问题不给恢复动作：出路只在底部主操作上', (tester) async {
    final blocker = PreviewIssue(
      key: 'unscheduled:t-a:180',
      severity: PreviewIssueSeverity.blocking,
      title: '写报告 还缺 180 分钟',
      message: '排程没有使用仍可用的合法时段。',
      taskId: 't-a',
      // 引擎在"无法解释"这条原因上会给出 recalculate；它是阻断问题，
      // 因此卡片上**不显示**它（由底部那个可点的主操作承担），避免同一页两个同义按钮。
      actions: const [PreviewRecoveryAction.recalculate],
    );
    await pumpModel(
      tester,
      modelWith(issues: [blocker]),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      onRecover: (action, issue) async {},
      onRecalculate: () async {},
      availableRecoveryActions: const {PreviewRecoveryAction.recalculate},
    );

    expect(
      find.byKey(Key('recovery-${blocker.key}-recalculate')),
      findsNothing,
    );
    // 底部主操作仍然是那个可点的"重新生成计划"。
    final main = tester.widget<FilledButton>(
      find.byKey(const Key('recalculate-plan')),
    );
    expect(main.onPressed, isNotNull);
  });

  testWidgets('未使用空档：默认收起、首屏最多 6 行、其余折叠为"另有 N 段"，且写本地时间', (tester) async {
    final zones = TimeZoneDatabase();
    // 8 段空档：UTC 06:00 起每 5 分钟一段（东八区 = 本地 14:00 起）。
    // **8 > 6**：正好越过首屏上限，用来钉住"折叠但不截断"。
    final gaps = [
      for (var index = 0; index < 8; index++)
        ExcludedGapEvidence(
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 12, 6, index * 5),
            endUtc: DateTime.utc(2026, 10, 12, 6, index * 5 + 5),
          ),
          code: GapExclusionCode.shorterThanRequiredChunk,
          requiredMinutes: 30,
          availableMinutes: 5,
        ),
    ];
    final issue = PreviewIssue(
      key: 'unscheduled:t-a:30',
      severity: PreviewIssueSeverity.warning,
      title: '写报告 还缺 30 分钟',
      message: '这一天的任务每日上限已经用满。',
      taskId: 't-a',
      excludedGaps: gaps,
    );
    await pumpModel(
      tester,
      modelWith(issues: [issue]),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
    );

    // ① 默认**只显示主原因**：证据收在展开项里，首屏看不到那 8 行。
    expect(find.text('查看未使用空档'), findsOneWidget);
    expect(find.textContaining('每日上限'), findsWidgets);
    expect(
      find.textContaining('短于最短片段'),
      findsNothing,
      reason: '默认只显示主原因；展开项里才是每段空档的排除原因',
    );
    expect(find.textContaining('14:00'), findsNothing);

    await tester.tap(find.text('查看未使用空档'));
    await tester.pumpAndSettle();

    // ② 首屏 6 行 + "另有 2 段"；数据本身没有被截断（8 段都在 `excludedGaps` 里）。
    expect(gaps, hasLength(8));
    expect(find.textContaining('短于最短片段'), findsNWidgets(6));
    expect(find.text('另有 2 段'), findsOneWidget);

    // ③ 时间必须写成**本地**时间（UTC 06:00 ⇒ 东八区 14:00），不能印 UTC。
    expect(find.textContaining('14:00'), findsWidgets);
    expect(
      find.textContaining('06:00'),
      findsNothing,
      reason: '印 UTC 会让用户去日历上找一段时间，而那段时间其实是空的',
    );
    // ④ 绝不显示枚举名。
    expect(find.textContaining('shorterThanRequiredChunk'), findsNothing);

    // ⑤ 展开"另有 2 段"之后 8 段全在。
    await tester.tap(find.text('另有 2 段'));
    await tester.pumpAndSettle();
    expect(find.textContaining('短于最短片段'), findsNWidgets(8));
    expect(find.text('另有 2 段'), findsNothing);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 计划 Task 6 Step 2：**从"编辑任务／规划规则／保护时间"回来之后，旧提案作废**。
  //
  // 装配层（`router.dart` 的 `_PlanPreviewLoaderState`）在导航之前调用 `asStale()`；
  // 这里钉住那一步的语义：内容不变、状态变过期，页面因此只给"重新生成计划"。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('asStale：内容不变、不允许再应用，主操作只剩"重新生成计划"', (tester) async {
    final loaded = modelWith(
      issues: [warningWithActions()],
      changes: const [
        PreviewChange(
          kind: PreviewChangeKind.added,
          title: '新增任务',
          reason: 'r',
        ),
      ],
    );
    final stale = loaded.asStale();

    // ① 模型层：只换状态，不动内容。
    expect(stale.isStale, isTrue);
    expect(loaded.isStale, isFalse);
    expect(stale.proposalId, loaded.proposalId);
    expect(stale.changes, loaded.changes);
    expect(stale.issues, loaded.issues);

    // ② 页面层：过期 ⇒ 没有应用入口，主操作是可点的"重新生成计划"。
    var recalculated = 0;
    await pumpModel(
      tester,
      stale,
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      onRecalculate: () async => recalculated++,
    );

    expect(find.text('提案已过期，请重新计算'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '确认应用'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '仍应用可安排部分'), findsNothing);
    final main = tester.widget<FilledButton>(
      find.byKey(const Key('recalculate-plan')),
    );
    expect(main.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('recalculate-plan')));
    await tester.pumpAndSettle();
    expect(recalculated, 1);
  });
}
