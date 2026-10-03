// W6/FR-PREF 的**触发端**：偏好页打开时按证据重新分析。
//
// 与 preference_evidence_loop_test 分工：那里验证"证据 → 建议"的分析链，这里验证
// **生产代码真的调用了 refresh**。此前它不仅没有证据输入，连 `refresh` 都没有任何生产
// 调用方（全库只有测试调用），因此无论积累多少证据，这一页都只会是一份空名单。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';

/// 与既有分析器测试同形：同一 subjectKey（`area:study`）20 条、跨 14 天、上下午差异明显。
List<PreferenceEvidence> _strongEvidence() => [
  for (var index = 0; index < 20; index++)
    PreferenceEvidence(
      id: 'e-$index',
      kind: PreferenceEvidenceKind.focusCompletion,
      subjectKey: 'area:study',
      observedAtUtc: DateTime.utc(2026, 9, index % 14 + 1, index.isEven ? 9 : 19),
      numericValue: index.isEven ? 0.9 : 0.6,
      metadata: {'timeBucket': index.isEven ? 'morning' : 'evening'},
    ),
];

void main() {
  late PreferenceService service;

  setUp(() {
    service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: MemoryPreferenceStore(),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    Future<List<PreferenceEvidence>> Function()? loadEvidence,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PreferencesPage(service: service, loadEvidence: loadEvidence),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('打开偏好页时按证据重新分析，建议因此出现', (tester) async {
    expect(await service.list(), isEmpty);

    await pump(tester, loadEvidence: () async => _strongEvidence());

    // 若这一页不调用 refresh，这里会一直是空的——这正是改动前的状态。
    final suggestions = await service.list();
    expect(suggestions, hasLength(1));
    expect(suggestions.single.id, 'time:area:study:morning');
  });

  testWidgets('没有证据来源时只列出已保存的建议，不报错', (tester) async {
    await pump(tester);

    expect(await service.list(), isEmpty);
    // 仍然渲染出页面本身，而不是抛错。
    expect(find.text('学习偏好'), findsOneWidget);
  });
}
