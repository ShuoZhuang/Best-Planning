// **六项人工验收的界面呈现**（计划 Task 12 Step 4–9）——改由自动化覆盖。
//
// ## 为什么换成自动化
//
// 原来的做法要求人工在可交互的 Windows 构建里操作六遍，其中**场景 F 还得改产品代码**
// （把 `main.dart:642` 的 `maxAllocationStates` 压到 1 才能触发"搜索预算耗尽"）。
// 那是一条坏路径，理由有两条：
//
// 1. **`maxAllocationStates = 10000` 对真实用户不可达。** `visited` 每"尝试在某天放
//    一份"加一，量级约为 **任务数 × 参与天数**：普通用户约 35、重度用户约 280，
//    要耗尽 10000 大约需要 **700 个任务**。所以"未能确认完整方案"这条文案在真实
//    使用中永远不会出现——它是防御性保险丝，不是用户会走到的路径。
// 2. **需要改代码才能验的验收项，本身就该被自动化。** 让验收人改产品代码既危险
//    （容易忘记改回）又不可重复。
//
// ## 这些测试断言什么
//
// 人工原本要看的**界面呈现**，正是这些测试钉住的：
// 文案真的渲染出来、按钮真的禁用、缺口真的显示、变更真的逐项列出。
//
// 算法**结论**早已由单元/组件测试覆盖（见 `capacity-aware-acceptance-audit.md`
// 的 #6、#9、#16、#19）。两者合起来才是完整验收，谁也不替代谁。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

void main() {
  AutoAdjustStore store() => MemoryAutoAdjustStore();

  Future<void> pumpPreview(
    WidgetTester tester,
    PlanPreviewModel model, {
    List<PlanApplyMode>? applied,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanPreviewPage(
            model: model,
            autoAdjustStore: store(),
            onConfirm: (mode) async {
              applied?.add(mode);
              return ApplyPlanResult.stale();
            },
            // 生产装配必传：不传时页面按约定**一条恢复动作都不渲染**，
            // 于是"过期后该点哪里"在这个用例里就无从验证。
            onRecalculate: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 页面上是否存在**一个可点击的应用入口**。
  ///
  /// 不能只查 `Key('apply-plan')`：页面按 `ProposalDisposition` **分流渲染**
  /// 三种底部动作（过期 →「重新生成计划」；部分可行 → `apply-partial`；
  /// 完整可行 → `apply-plan`）。所以"不能应用"有两种真实形态：
  /// 按钮被禁用，或者**根本没有应用按钮**。两者都必须算"不能应用"。
  bool hasEnabledApply(WidgetTester tester) {
    for (final key in ['apply-plan', 'apply-partial']) {
      final finder = find.byKey(Key(key));
      if (finder.evaluate().isEmpty) continue;
      final widget = tester.widget(finder);
      if (widget is FilledButton && widget.onPressed != null) return true;
      if (widget is OutlinedButton && widget.onPressed != null) return true;
    }
    return false;
  }

  group('场景 E：预览过期', () {
    testWidgets('**过期时明确说"请重新计算"，且不能应用**', (tester) async {
      final applied = <PlanApplyMode>[];
      await pumpPreview(
        tester,
        PlanPreviewModel(
          proposalId: 'p-stale',
          changes: const [],
          issues: const [],
          isStale: true,
        ),
        applied: applied,
      );

      // ① 文案必须出现（这正是人工要"看到"的那一句）。
      expect(
        find.text('提案已过期，请重新计算'),
        findsOneWidget,
        reason: '过期是"这份提案已经作废"，页面必须说清并指向重新计算',
      );
      // ② 应用按钮必须禁用。
      expect(
        hasEnabledApply(tester),
        isFalse,
        reason: '过期提案不得被应用——这是 Task 10 的应用安全要求',
      );
      // ③ 过期时底部动作是**「重新生成计划」**，不是应用——这才是页面给出的正确出路。
      expect(
        find.text('重新生成计划'),
        findsWidgets,
        reason: '过期后用户唯一的正确动作是重新生成，页面必须给出这个入口',
      );
      expect(applied, isEmpty, reason: '过期状态下不得触发任何确认');
    });
  });

  group('场景 F：搜索预算耗尽诊断', () {
    testWidgets('**显示"未能确认完整方案"，不显示"可用时间不足"，且不能应用**', (tester) async {
      // **文案与生产同源**：直接取 `searchOutcomeLabel(budgetExhausted)`，
      // 而不是在测试里抄一遍字符串——抄一遍就等于允许两边各说一套。
      final label = searchOutcomeLabel(SearchOutcomeKind.budgetExhausted);
      expect(
        label,
        contains('未能确认完整方案'),
        reason: '这是 ALG-42 定下的文案，用户据此决定"重新生成"而不是"腾时间"',
      );

      await pumpPreview(
        tester,
        PlanPreviewModel(
          proposalId: 'p-budget',
          changes: const [],
          issues: [
            PreviewIssue(
              key: 'search-budget-exhausted',
              severity: PreviewIssueSeverity.blocking,
              title: label,
              message:
                  '搜索在这次预算内没有得出完整结论。可以重新生成，'
                  '或先调整任务与规则后重试。',
            ),
          ],
          isStale: false,
        ),
      );

      // ① 必须显示"未能确认完整方案"。
      expect(find.textContaining('未能确认完整方案'), findsWidgets);
      // ② **不得**说成"可用时间不足"——那是真的无解才允许用的说法。
      expect(
        find.textContaining('可用时间不足'),
        findsNothing,
        reason: '把"没算完"说成"时间不够"会把用户引向错误的自救方向',
      );
      // ③ 应用按钮禁用。
      expect(hasEnabledApply(tester), isFalse);
    });

    testWidgets('**对照：真的无解时才说"可用时间不足"**', (tester) async {
      // 这条是判别性对照：如果上一条的断言恒真（页面什么都不渲染），
      // 这里也会"通过"。所以必须有一条正例证明文案确实按 kind 分流。
      final label = searchOutcomeLabel(SearchOutcomeKind.hardInfeasible);
      await pumpPreview(
        tester,
        PlanPreviewModel(
          proposalId: 'p-infeasible',
          changes: const [],
          issues: [
            PreviewIssue(
              key: 'hard-infeasible',
              severity: PreviewIssueSeverity.blocking,
              title: label,
              message: '窗口内的合法容量不足以放下这些任务。',
            ),
          ],
          isStale: false,
        ),
      );

      expect(
        find.textContaining(label),
        findsWidgets,
        reason: '真的无解时页面必须如实说"容量不足"，与预算耗尽区分开',
      );
      expect(hasEnabledApply(tester), isFalse);
    });
  });

  group('场景 D：延后 10 分钟的预览', () {
    testWidgets('**逐项列出被移动的块，而不是笼统一句"计划已更新"**', (tester) async {
      // 人工要确认的是"预览有没有逐项列出移动"。数据层（`PlanDiffer` 把
      // 延后报成「移动」而非删除＋新增）已由 `defer_end_to_end_test` 覆盖；
      // 这里补的是**渲染这一层**：每一项真的出现在屏幕上、带原时间与目标时间。
      await pumpPreview(
        tester,
        PlanPreviewModel(
          proposalId: 'p-defer',
          changes: const [
            PreviewChange(
              kind: PreviewChangeKind.moved,
              title: '完成课程论文',
              reason: '延后 10 分钟',
              fromLabel: '14:00–15:00',
              toLabel: '14:10–15:10',
            ),
            PreviewChange(
              kind: PreviewChangeKind.moved,
              title: '复习线性代数',
              reason: '被上一块挤开',
              fromLabel: '15:00–16:00',
              toLabel: '15:10–16:10',
            ),
          ],
          issues: const [],
          isStale: false,
        ),
      );

      // ① 分组标题用的是「移动」，不是「删除」或「新增」。
      expect(
        find.text('移动'),
        findsWidgets,
        reason: '延后是"同一块换了时间"，必须报成移动（裁定第 4 点）',
      );
      // ② 两块都要逐项列出——这正是"只移动必要块"的可视证据。
      expect(find.text('完成课程论文'), findsWidgets);
      expect(find.text('复习线性代数'), findsWidgets);
      // ③ 每项都带原时间与目标时间，用户才能判断"它被挪到哪了"。
      //
      // 时间放在 `ExpansionTile` 的折叠内容里（默认不渲染），所以要先展开。
      // 这不是测试的取巧：真实用户也要点一下才看得到细节。
      await tester.tap(find.text('完成课程论文'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('14:00–15:00'),
        findsWidgets,
        reason: '展开后必须显示**原时间**，用户才知道它原来在哪',
      );
      expect(
        find.textContaining('14:10–15:10'),
        findsWidgets,
        reason: '展开后必须显示**目标时间**，用户才知道它被挪到哪',
      );
    });
  });

  group('场景 C：高精力只是偏好', () {
    test('**精力对不上时，解释说的是"偏离精力偏好"而不是"优先级较高"**', () {
      // 这条是**自动化验收抓出来的真缺口**：修复前 `_explanationCode` 在精力
      // 不匹配时返回 `'priority'`，页面于是显示「优先级较高」——一个与事实无关、
      // 用户也无法据以行动的理由。真实原因是高精力窗口已满，只能凑合放到普通时段。
      //
      // 计划场景 C 的验收判据是「解释"偏离精力偏好"」，所以这是判据缺失。
      expect(
        explanationLabel('energy_offpeak'),
        '偏离精力偏好',
        reason: '精力偏离必须如实说明，用户才能据此调整精力区间或挪开课程',
      );
      // **判别性**：不能靠着把 priority 也改成这句话来"通过"——
      // 两种理由必须能区分，因为它们的可行动性完全不同。
      expect(
        explanationLabel('priority'),
        isNot('偏离精力偏好'),
        reason: '「优先级较高」与「偏离精力偏好」是两个不同的理由，不得合并',
      );
      // 旧数据里的 `'priority'` 必须仍有映射，否则历史计划退化成兜底文案。
      expect(explanationLabel('priority'), isNotEmpty);
    });
  });

  group('场景 B：容量缺口的界面呈现', () {
    testWidgets('**有周期目标缺口时渲染缺口组**', (tester) async {
      await pumpPreview(
        tester,
        PlanPreviewModel(
          proposalId: 'p-shortfall',
          changes: const [],
          issues: const [],
          isStale: false,
          shortfalls: [
            CapacityShortfall(
              templateId: 'template-1',
              title: '每周跑步',
              periodStartLocalDate: DateTime(2026, 10, 5),
              targetMinutes: 180,
              schedulableMinutes: 120,
              shortfallMinutes: 60,
              protectedConstraint: null,
              window: TimeRange(
                startUtc: DateTime.utc(2026, 10, 5),
                endUtc: DateTime.utc(2026, 10, 12),
              ),
            ),
          ],
        ),
      );

      // 缺口组必须渲染：人工要确认的正是"精确缺口有没有显示出来"，
      // 而不是只给一句笼统错误。
      expect(
        find.byKey(const Key('shortfall-group')),
        findsOneWidget,
        reason: '容量不足时必须显示**精确缺口**，不能只给笼统错误',
      );
      // 缺口组存在时，应用按钮仍可用（缺口是 warning 级，不是 blocking）。
      expect(
        hasEnabledApply(tester),
        isTrue,
        reason: '容量缺口属于可带着确认应用的情形，不该禁用按钮',
      );
    });
  });
}
