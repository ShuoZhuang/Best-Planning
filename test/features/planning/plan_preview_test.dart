import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

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
      conflicts: const [],
      isStale: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
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
      conflicts: const [],
      isStale: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
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
      conflicts: const ['周三缺少 30 分钟'],
      isStale: true,
    );
    final store = MemoryAutoAdjustStore();
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: store,
          onConfirm: () async {},
        ),
      ),
    );

    expect(find.text('新增'), findsOneWidget);
    expect(find.text('移动'), findsOneWidget);
    expect(find.text('拆分'), findsOneWidget);
    // M4：第四类从「移除」改称「未安排」——没排进去不等于被移除，任务还在列表里。
    expect(find.text('未安排'), findsOneWidget);
    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('周三缺少 30 分钟'), findsOneWidget);

    await tester.tap(find.text('移动实验'));
    await tester.pumpAndSettle();
    expect(find.text('匹配高精力时段'), findsOneWidget);

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认应用'),
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
      conflicts: const [],
      isStale: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: store,
          onConfirm: () async => confirmations++,
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
        home: PlanPreviewPage(
          model: PlanPreviewModel(
            proposalId: 'proposal-1',
            changes: const [],
            conflicts: const [],
            isStale: false,
          ),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
          onUndoPlan: () async {
            calls++;
            return true;
          },
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
        home: PlanPreviewPage(
          model: PlanPreviewModel(
            proposalId: 'proposal-1',
            changes: const [],
            conflicts: const [],
            isStale: false,
          ),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
          onUndoPlan: () async => false,
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
            conflicts: const [],
            isStale: false,
          ),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
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
    conflicts: const [],
    isStale: stale,
  );

  testWidgets('过期时给出「重新生成计划」入口，并真的调用回调', (tester) async {
    var recalculated = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: staleModel(stale: true),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
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
          onConfirm: () async {},
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
          onConfirm: () async {},
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
}
