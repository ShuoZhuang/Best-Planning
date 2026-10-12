import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

    // 过期 + 阻断 ⇒ 按钮既不是"确认应用"，也不可点击。
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '无法应用'),
    );
    expect(confirm.onPressed, isNull);
    expect(find.text('提案已过期，请重新计算'), findsOneWidget);
    expect(store.enabled, isFalse);
  });

  testWidgets('auto adjust defaults off but retains preview history', (
    tester,
  ) async {
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

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.ensureVisible(find.text('确认应用'));
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();

    expect(store.enabled, isTrue);
    expect(store.history, contains('proposal-2'));
    expect(confirmations, 1);
  });
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

  testWidgets('blocker ⇒ 按钮禁用且 onConfirm 调用 0 次', (tester) async {
    var calls = 0;
    await pumpModel(
      tester,
      modelWith(issues: const [blockerIssue]),
      onConfirm: (mode) async {
        calls++;
        return ApplyPlanResult.stale();
      },
      onRecalculate: () async {},
    );

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '无法应用'),
    );
    expect(button.onPressed, isNull);
    expect(calls, 0);
    // 阻断时给出"重新生成计划"这条出路（否则用户被留在死路上）。
    expect(find.byKey(const Key('recalculate-after-block')), findsOneWidget);
  });

  testWidgets('warning ⇒ 按钮为"应用可安排部分"；取消对话框调用 0 次，确认后传 allowPartial', (
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

    final button = find.widgetWithText(FilledButton, '应用可安排部分');
    expect(button, findsOneWidget);

    // 第一次：取消。
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
    // 对话框里必须列出**全部缺口**（标题＋原因）。
    expect(find.text('写报告 还缺 30 分钟'), findsWidgets);
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

  testWidgets('stale ⇒ 重算入口可用，且主按钮禁用', (tester) async {
    var recalculated = 0;
    await pumpModel(
      tester,
      modelWith(stale: true),
      onConfirm: (mode) async => ApplyPlanResult.stale(),
      onRecalculate: () async => recalculated++,
    );

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '无法应用'),
    );
    expect(confirm.onPressed, isNull);
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
      onRecalculate: () async {},
    );

    await tester.tap(find.widgetWithText(FilledButton, '确认应用'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    // 具体原因可见（不是"计划未通过校验"）。
    expect(find.text('应用未完成'), findsOneWidget);
    expect(find.textContaining('早于本次规划范围'), findsWidgets);

    // 失败之后主按钮禁用：不允许无限重复点击同一个必失败操作。
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '无法应用'),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('recalculate-after-block')), findsOneWidget);

    // 再点也不会触发新的调用。
    await tester.tap(
      find.widgetWithText(FilledButton, '无法应用'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
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
}
