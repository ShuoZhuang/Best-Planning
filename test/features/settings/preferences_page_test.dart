import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';

void main() {
  testWidgets('用户可查看依据并确认、拒绝、停用、清除和撤销自动更新', (tester) async {
    final store = MemoryPreferenceStore();
    final service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: store,
    );
    await service.refresh(_evidence());
    await tester.pumpWidget(
      MaterialApp(home: PreferencesPage(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('20 条记录'), findsOneWidget);
    expect(find.textContaining('14 个活跃日'), findsOneWidget);
    expect(find.textContaining('效果差 30%'), findsOneWidget);
    expect(find.text('确认采用'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('清除学习结果'), findsOneWidget);
    expect(find.text('撤销上次自动更新'), findsOneWidget);

    await tester.tap(find.text('确认采用'));
    await tester.pumpAndSettle();
    expect(find.text('已确认'), findsOneWidget);

    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(find.text('已停用'), findsOneWidget);
  });
}

List<PreferenceEvidence> _evidence() => [
  for (var index = 0; index < 20; index++)
    PreferenceEvidence(
      id: 'ui-$index',
      kind: PreferenceEvidenceKind.focusCompletion,
      subjectKey: 'area:study',
      observedAtUtc: DateTime.utc(
        2026,
        9,
        index % 14 + 1,
        index.isEven ? 9 : 19,
      ),
      numericValue: index.isEven ? 0.9 : 0.6,
      metadata: {'timeBucket': index.isEven ? 'morning' : 'evening'},
    ),
];
