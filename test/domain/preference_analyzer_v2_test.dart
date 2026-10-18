import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/preference_evidence_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

PreferenceEvidence _evidence({
  required String id,
  required int effect,
  required String bucket,
  required int day,
  required bool morning,
  int actualFocus = 40,
  bool specialDay = false,
  String? excludedReason,
}) => PreferenceEvidence(
  id: id,
  kind: PreferenceEvidenceKind.focusCompletion,
  subjectKey: 'area:study',
  observedAtUtc: DateTime.utc(2026, 9, day, morning ? 9 : 19),
  numericValue: actualFocus.toDouble(),
  specialDay: specialDay,
  metadata: {
    'evidenceVersion': 2,
    'effectScorePermille': effect,
    'timeBucket': bucket,
    'observedLocalDate': '2026-09-${day.toString().padLeft(2, '0')}',
    'actualFocusMinutes': actualFocus,
    'plannedMinutes': 45,
    'excludedReason': excludedReason,
  },
);

List<PreferenceEvidence> _completionSet({
  int count = 20,
  int activeDays = 14,
  int high = 900,
  int low = 750,
}) => [
  for (var index = 0; index < count; index++)
    _evidence(
      id: 'e-$index',
      effect: index.isEven ? high : low,
      bucket: index.isEven ? 'morning' : 'evening',
      day: index % activeDays + 1,
      morning: index.isEven,
    ),
];

void main() {
  group('整数效果分', () {
    test('完成、专注、偏差与中断都按固定整数权重合成', () {
      expect(
        focusEffectScore(
          plannedMinutes: 60,
          actualFocusMinutes: 60,
          completedMinutes: 60,
          interruptionCount: 0,
        ),
        1000,
      );
      expect(
        focusEffectScore(
          plannedMinutes: 60,
          actualFocusMinutes: 30,
          completedMinutes: 30,
          interruptionCount: 2,
        ),
        530,
      );
      expect(
        focusEffectScore(
          plannedMinutes: 60,
          actualFocusMinutes: 0,
          completedMinutes: 0,
          interruptionCount: 10,
        ),
        0,
      );
    });

    test('原始分钟不会被当成百分比：60 分钟完整专注与 600 分钟都封顶 1000', () {
      final a = focusEffectScore(
        plannedMinutes: 60,
        actualFocusMinutes: 60,
        completedMinutes: 60,
        interruptionCount: 0,
      );
      final b = focusEffectScore(
        plannedMinutes: 600,
        actualFocusMinutes: 600,
        completedMinutes: 600,
        interruptionCount: 0,
      );
      expect(a, 1000);
      expect(b, 1000);
    });
  });

  group('时段桶', () {
    final zones = TimeZoneDatabase();

    test(
      '04:59 是 night，05:00 是 morning；11:59/12:00、17:59/18:00、22:59/23:00 同理',
      () {
        expect(bucketForMinuteOfDay(4 * 60 + 59), TimeBucket.night);
        expect(bucketForMinuteOfDay(5 * 60), TimeBucket.morning);
        expect(bucketForMinuteOfDay(11 * 60 + 59), TimeBucket.morning);
        expect(bucketForMinuteOfDay(12 * 60), TimeBucket.afternoon);
        expect(bucketForMinuteOfDay(17 * 60 + 59), TimeBucket.afternoon);
        expect(bucketForMinuteOfDay(18 * 60), TimeBucket.evening);
        expect(bucketForMinuteOfDay(22 * 60 + 59), TimeBucket.evening);
        expect(bucketForMinuteOfDay(23 * 60), TimeBucket.night);
      },
    );

    test('跨午夜会话按实际分钟拆分，占比最大的桶胜出', () {
      final start = DateTime.utc(2026, 9, 1, 14, 0); // 上海 22:00
      final end = DateTime.utc(2026, 9, 1, 15, 30); // 上海 23:30
      final result = dominantBucket(
        startedAtUtc: start,
        endedAtUtc: end,
        zones: zones,
        timeZoneId: 'Asia/Shanghai',
      );
      expect(result.bucket, TimeBucket.evening);
      expect(result.minutes['evening'], 60);
      expect(result.minutes['night'], 30);
    });
  });

  group('v2 时段建议', () {
    const analyzer = RuleBasedPreferenceAnalyzer();

    test('20 条、14 日、两个桶各 5 条且中位数差 150 才建议', () {
      final suggestions = analyzer
          .analyze(_completionSet(), const PreferenceProfile())
          .where(
            (item) => item.kind == PreferenceSuggestionKind.preferredTimeWindow,
          )
          .toList();
      expect(suggestions, hasLength(1));
      final suggestion = suggestions.single;
      expect(suggestion.suggestedStartMinute, 5 * 60);
      expect(suggestion.suggestedEndMinute, 12 * 60);
      expect(suggestion.effectDifference, closeTo(0.15, 1e-9));
      expect(suggestion.explanationCode, 'v2_time_bucket_median_difference');
    });

    test('差 149 不建议', () {
      final suggestions = analyzer
          .analyze(
            _completionSet(high: 899, low: 750),
            const PreferenceProfile(),
          )
          .where(
            (item) => item.kind == PreferenceSuggestionKind.preferredTimeWindow,
          );
      expect(suggestions, isEmpty);
    });

    test('只有 19 条或 13 个活跃日不建议', () {
      expect(
        analyzer.analyze(_completionSet(count: 19), const PreferenceProfile()),
        isEmpty,
      );
      expect(
        analyzer.analyze(
          _completionSet(activeDays: 13),
          const PreferenceProfile(),
        ),
        isEmpty,
      );
    });

    test('特殊日与恢复日证据被排除', () {
      final evidence = [
        for (final item in _completionSet())
          if (item.metadata['timeBucket'] == 'morning')
            item.copyWith(specialDay: true)
          else
            item,
      ];
      expect(analyzer.analyze(evidence, const PreferenceProfile()), isEmpty);
    });

    test('旧证据不参与 v2 分数，只有 v2 证据存在时旧建议不生成', () {
      final legacy = [
        for (var index = 0; index < 5; index++)
          PreferenceEvidence(
            id: 'legacy-$index',
            kind: PreferenceEvidenceKind.manualMove,
            subjectKey: 'area:study',
            observedAtUtc: DateTime.utc(2026, 9, index + 1, 16),
            numericValue: 960,
            metadata: const {'direction': 'later'},
          ),
      ];
      final suggestions = analyzer
          .analyze([...legacy, ..._completionSet()], const PreferenceProfile())
          .where(
            (item) => item.kind == PreferenceSuggestionKind.preferredTimeWindow,
          )
          .toList();
      expect(suggestions, hasLength(1));
      expect(
        suggestions.single.explanationCode,
        'v2_time_bucket_median_difference',
      );
    });
  });

  group('v2 片段建议', () {
    const analyzer = RuleBasedPreferenceAnalyzer();

    test('20 条、14 日取五分钟粒度稳健中位数并夹在合法范围', () {
      final evidence = [
        for (var index = 0; index < 20; index++)
          _evidence(
            id: 'f-$index',
            effect: 800,
            bucket: 'morning',
            day: index % 14 + 1,
            morning: true,
            actualFocus: index == 0 ? 300 : 42,
          ),
      ];
      final suggestion = analyzer
          .analyze(evidence, const PreferenceProfile())
          .singleWhere(
            (item) =>
                item.kind == PreferenceSuggestionKind.preferredFocusMinutes,
          );
      expect(suggestion.suggestedFocusMinutes, 40);
      expect(suggestion.explanationCode, 'v2_focus_length_median');
    });

    test('少于 14 个活跃日不建议片段', () {
      final evidence = [
        for (var index = 0; index < 20; index++)
          _evidence(
            id: 'f-$index',
            effect: 800,
            bucket: 'morning',
            day: index % 10 + 1,
            morning: true,
          ),
      ];
      expect(
        analyzer
            .analyze(evidence, const PreferenceProfile())
            .where(
              (item) =>
                  item.kind == PreferenceSuggestionKind.preferredFocusMinutes,
            ),
        isEmpty,
      );
    });
  });
}
