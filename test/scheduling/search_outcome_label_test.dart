// 计划 Task 9（诊断）／Task 12 人工场景 F：**搜索结果种类必须各有各的说法**。
//
// ## 缺口
//
// `SearchOutcomeKind` 已经把五种处境分开（`search_outcome.dart`），
// `isApplicableOutcome` 也已经回答了"能不能应用"。但**用户看到的那句话**
// 一直没有对应的映射：`budgetExhausted` 与 `invariantViolation` 在
// `explanations.dart` 的 `ConflictCode` 里根本没有条目。
//
// 后果正是计划反复点名的那一件事（§1.2 第 9 条、ALG-47、人工场景 F）：
//
// > 达到预算但没有证明无解时返回 `budgetExhausted`，**不得**返回 `insufficientCapacity`。
//
// 没有映射时，预算耗尽的诊断只能落回 `insufficientCapacity` →「可用时间不足」，
// 于是**搜索超时伪装成无解**——用户被引导去腾时间，而正确处置是重新生成
// （很可能就成功了）。人工场景 F 明确要求显示「未能确认完整方案」。
//
// 因此这里钉住两件事：
// 1. 每个 `SearchOutcomeKind` 都有**非空且互不相同**的用户文案；
// 2. `budgetExhausted` 与 `invariantViolation` 的文案**不得**出现"可用时间不足"，
//    而 `hardInfeasible` 的文案必须是它（那是它唯一的正确说法）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

void main() {
  group('搜索结果种类的用户文案（Task 9 / 场景 F）', () {
    test('**每一种都有非空且互不相同的文案**', () {
      final labels = <SearchOutcomeKind, String>{
        for (final kind in SearchOutcomeKind.values)
          kind: searchOutcomeLabel(kind),
      };

      for (final entry in labels.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '${entry.key} 没有用户文案 ⇒ 界面上会出现空白或内部枚举名',
        );
        expect(
          entry.value,
          isNot(contains('SearchOutcomeKind')),
          reason: '${entry.key} 的文案泄漏了内部枚举名',
        );
      }

      expect(
        labels.values.toSet(),
        hasLength(SearchOutcomeKind.values.length),
        reason: '不同处境必须说不同的话；实测 $labels',
      );
    });

    test('**预算耗尽不得说成"可用时间不足"**（ALG-47 / 场景 F）', () {
      final budget = searchOutcomeLabel(SearchOutcomeKind.budgetExhausted);
      expect(
        budget,
        isNot(contains('可用时间不足')),
        reason: '搜索超时伪装成无解会把用户引向"腾时间"，而正确处置是重新生成',
      );
      expect(
        budget,
        contains('未能确认完整方案'),
        reason: '计划对 `budgetExhausted` 指定了这个措辞；实测「$budget」',
      );
    });

    test('**内部不变量被破坏时也不得说成"可用时间不足"**（ALG-42）', () {
      final invariant = searchOutcomeLabel(
        SearchOutcomeKind.invariantViolation,
      );
      expect(
        invariant,
        isNot(contains('可用时间不足')),
        reason: '"排程器自己没排好"不是"装不下"，用户要做的不是腾时间',
      );
      expect(invariant, contains('未自动应用'), reason: '必须说清后果；实测「$invariant」');
    });

    test('`hardInfeasible` 才说"可用时间不足"', () {
      expect(
        searchOutcomeLabel(SearchOutcomeKind.hardInfeasible),
        contains('可用时间不足'),
      );
    });

    test('"软偏好放宽"不算失败，文案不得暗示装不下', () {
      final relaxed = searchOutcomeLabel(
        SearchOutcomeKind.solvedWithSoftRelaxation,
      );
      expect(relaxed, isNot(contains('可用时间不足')));
      expect(
        isApplicableOutcome(
          SearchOutcomeKind.solvedWithSoftRelaxation,
          allowPartial: false,
        ),
        isTrue,
        reason: '计划 §3.7 明确精力与期望时段只是软偏好',
      );
    });

    test('**两种未决／异常状态在任何模式下都不可应用**（ALG-42）', () {
      for (final kind in [
        SearchOutcomeKind.budgetExhausted,
        SearchOutcomeKind.invariantViolation,
      ]) {
        expect(
          isApplicableOutcome(kind, allowPartial: false),
          isFalse,
          reason: '$kind 在完整模式下必须禁止应用',
        );
        expect(
          isApplicableOutcome(kind, allowPartial: true),
          isFalse,
          reason: '$kind 连 `allowPartial` 也不能绕过',
        );
      }
    });
  });
}
