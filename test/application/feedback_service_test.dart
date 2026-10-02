import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/feedback_service.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/feedback_message.dart';

void main() {
  test('反馈最多三条且每条都携带真实证据和参数', () {
    const service = FeedbackService();
    final current = _report(
      actualMinutes: 300,
      completion: const RatioMetric(numerator: 3, denominator: 4),
      onTime: const RatioMetric(numerator: 3, denominator: 3),
      estimate: const RatioMetric(numerator: 60, denominator: 120),
      lifeTarget: 360,
      lifeActual: 400,
      interruptions: const [RankedMetric('phone', 4)],
    );
    final previous = _report(
      actualMinutes: 200,
      completion: const RatioMetric(numerator: 1, denominator: 2),
      onTime: const RatioMetric(numerator: 1, denominator: 2),
      estimate: const RatioMetric(numerator: 0, denominator: 120),
      lifeTarget: 360,
      lifeActual: 240,
    );

    final messages = service.generate(current, previous);

    expect(messages, hasLength(3));
    expect(messages.map((item) => item.code), [
      FeedbackCode.lifeQuotaReached,
      FeedbackCode.actualInvestmentGrowth,
      FeedbackCode.completionImproved,
    ]);
    for (final message in messages) {
      expect(message.parameters, isNotEmpty);
      expect(message.evidence, isNotEmpty);
      expect(message.evidence.every((item) => item.value.isFinite), isTrue);
    }
    expect(messages[0].parameters['actualMinutes'], 400);
    expect(messages[0].parameters['targetMinutes'], 360);
    expect(messages[1].parameters['deltaMinutes'], 100);
    expect(messages[2].evidence.single.value, closeTo(0.75, 0.0001));
  });

  test('指标没有分母或真实记录时不生成推断反馈', () {
    const unavailable = RatioMetric(numerator: 0, denominator: 0);
    final messages = const FeedbackService().generate(
      _report(
        actualMinutes: 0,
        completion: unavailable,
        onTime: unavailable,
        estimate: unavailable,
        lifeTarget: 0,
        lifeActual: 0,
      ),
      _report(
        actualMinutes: 0,
        completion: unavailable,
        onTime: unavailable,
        estimate: unavailable,
        lifeTarget: 0,
        lifeActual: 0,
      ),
    );

    expect(messages, isEmpty);
  });

  test('延期或低完成率不会生成惩罚型消息代码', () {
    final messages = const FeedbackService().generate(
      _report(
        actualMinutes: 260,
        completion: const RatioMetric(numerator: 1, denominator: 5),
        onTime: const RatioMetric(numerator: 0, denominator: 1),
        estimate: const RatioMetric(numerator: 0, denominator: 0),
        lifeTarget: 360,
        lifeActual: 400,
        overdue: const RatioMetric(numerator: 4, denominator: 5),
      ),
      _report(
        actualMinutes: 200,
        completion: const RatioMetric(numerator: 4, denominator: 5),
        onTime: const RatioMetric(numerator: 4, denominator: 4),
        estimate: const RatioMetric(numerator: 0, denominator: 0),
        lifeTarget: 360,
        lifeActual: 180,
        overdue: const RatioMetric(numerator: 0, denominator: 5),
      ),
    );

    final codes = messages.map((item) => item.code).toSet();
    expect(
      codes,
      containsAll({
        FeedbackCode.lifeQuotaReached,
        FeedbackCode.actualInvestmentGrowth,
      }),
    );
    expect(codes, isNot(contains(FeedbackCode.completionImproved)));
    expect(codes, isNot(contains(FeedbackCode.onTimeImproved)));
    expect(
      messages.every(
        (item) => const {
          FeedbackTone.achievement,
          FeedbackTone.suggestion,
          FeedbackTone.observation,
        }.contains(item.tone),
      ),
      isTrue,
    );
  });
}

AnalyticsReport _report({
  required int actualMinutes,
  required RatioMetric completion,
  required RatioMetric onTime,
  required RatioMetric estimate,
  required int lifeTarget,
  required int lifeActual,
  RatioMetric overdue = const RatioMetric(numerator: 0, denominator: 0),
  List<RankedMetric> interruptions = const [],
}) => AnalyticsReport(
  filter: AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 1),
    endUtc: DateTime.utc(2026, 10, 8),
  ),
  plannedMinutes: 240,
  actualMinutes: actualMinutes,
  completionRate: completion,
  onTimeCompletionRate: onTime,
  overdueRate: overdue,
  estimateVariance: estimate,
  lifeQuota: LifeQuotaMetric(
    targetMinutes: lifeTarget,
    plannedMinutes: 300,
    actualMinutes: lifeActual,
  ),
  domainDistribution: const [],
  trend: const [],
  commonInterruptions: interruptions,
  replanReasons: const [],
  suggestionBehavior: const SuggestionBehaviorMetric(
    accepted: 0,
    modified: 0,
    rejected: 0,
  ),
);
