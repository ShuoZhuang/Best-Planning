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
    expect(find.text('修改'), findsOneWidget);
    expect(find.text('清除学习结果'), findsOneWidget);
    expect(find.text('撤销上次自动更新'), findsOneWidget);

    await tester.tap(find.text('确认采用'));
    await tester.pumpAndSettle();
    expect(find.text('已确认'), findsOneWidget);

    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(find.text('已停用'), findsOneWidget);
  });

  testWidgets('修改学习建议后保持待确认且新值可见', (tester) async {
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

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('preference-edit-start')),
      '10:00',
    );
    await tester.enterText(
      find.byKey(const Key('preference-edit-end')),
      '12:30',
    );
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(find.textContaining('10:00—12:30'), findsOneWidget);
    expect(find.text('等待你的决定'), findsOneWidget);
    final updated = (await service.list()).single;
    expect(updated.suggestedStartMinute, 10 * 60);
    expect(updated.suggestedEndMinute, 12 * 60 + 30);
    expect(updated.status, PreferenceSuggestionStatus.suggested);
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
