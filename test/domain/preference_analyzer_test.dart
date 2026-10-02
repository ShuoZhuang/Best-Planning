import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

void main() {
  const analyzer = RuleBasedPreferenceAnalyzer();

  test('19 条完成记录不生成建议', () {
    final evidence = _completionEvidence(19, activeDays: 14);

    expect(analyzer.analyze(evidence, const PreferenceProfile()), isEmpty);
  });

  test('20 条覆盖 14 个活跃日且效果差至少 15% 才建议时段', () {
    final evidence = _completionEvidence(20, activeDays: 14);

    final suggestions = analyzer.analyze(evidence, const PreferenceProfile());

    expect(suggestions, hasLength(1));
    final suggestion = suggestions.single;
    expect(suggestion.kind, PreferenceSuggestionKind.preferredTimeWindow);
    expect(suggestion.evidenceCount, 20);
    expect(suggestion.activeDayCount, 14);
    expect(suggestion.effectDifference, closeTo(0.2, 0.0001));
    expect(suggestion.suggestedStartMinute, 8 * 60);
    expect(suggestion.suggestedEndMinute, 12 * 60);
    expect(suggestion.explanationCode, 'time_bucket_effect_difference');
    expect(suggestion.observedFromUtc, DateTime.utc(2026, 9, 1, 9));
    expect(suggestion.observedToUtc, DateTime.utc(2026, 9, 14, 19));
  });

  test('效果差低于 15% 不下结论，特殊日证据全部排除', () {
    final smallDifference = _completionEvidence(
      20,
      activeDays: 14,
      highScore: 0.84,
      lowScore: 0.70,
    );
    final special = [
      for (final item in _completionEvidence(20, activeDays: 14))
        item.copyWith(specialDay: true),
      ..._completionEvidence(19, activeDays: 14),
    ];

    expect(
      analyzer.analyze(smallDifference, const PreferenceProfile()),
      isEmpty,
    );
    expect(analyzer.analyze(special, const PreferenceProfile()), isEmpty);
  });

  test('同一方向手动移动 5 次可建议对应时段偏好', () {
    final evidence = [
      for (var index = 0; index < 5; index++)
        PreferenceEvidence(
          id: 'move-$index',
          kind: PreferenceEvidenceKind.manualMove,
          subjectKey: 'area:research',
          observedAtUtc: DateTime.utc(2026, 9, index + 1, 16),
          numericValue: 16 * 60.0,
          metadata: const {'direction': 'later'},
        ),
    ];

    final suggestion = analyzer
        .analyze(evidence, const PreferenceProfile())
        .single;

    expect(suggestion.evidenceCount, 5);
    expect(suggestion.suggestedStartMinute, 16 * 60);
    expect(suggestion.explanationCode, 'repeated_manual_move');
  });
}

List<PreferenceEvidence> _completionEvidence(
  int count, {
  required int activeDays,
  double highScore = 0.9,
  double lowScore = 0.7,
}) => [
  for (var index = 0; index < count; index++)
    PreferenceEvidence(
      id: 'completion-$index',
      kind: PreferenceEvidenceKind.focusCompletion,
      subjectKey: 'area:study',
      observedAtUtc: DateTime.utc(
        2026,
        9,
        index % activeDays + 1,
        index.isEven ? 9 : 19,
      ),
      numericValue: index.isEven ? highScore : lowScore,
      metadata: {'timeBucket': index.isEven ? 'morning' : 'evening'},
    ),
];
