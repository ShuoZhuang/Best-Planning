import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/feedback_message.dart';

final class FeedbackService {
  const FeedbackService();

  List<FeedbackMessage> generate(
    AnalyticsReport current,
    AnalyticsReport previous,
  ) {
    final messages = <FeedbackMessage>[];

    void add(FeedbackMessage message) {
      if (messages.length < 3) messages.add(message);
    }

    final life = current.lifeQuota;
    if (life.targetMinutes > 0 && life.actualMinutes >= life.targetMinutes) {
      add(
        FeedbackMessage(
          code: FeedbackCode.lifeQuotaReached,
          tone: FeedbackTone.achievement,
          parameters: {
            'actualMinutes': life.actualMinutes,
            'targetMinutes': life.targetMinutes,
          },
          evidence: [
            FeedbackEvidence(
              code: 'lifeQuotaProgress',
              value: life.actualMinutes / life.targetMinutes,
            ),
          ],
        ),
      );
    }

    if (current.actualMinutes > previous.actualMinutes &&
        previous.actualMinutes > 0) {
      add(
        FeedbackMessage(
          code: FeedbackCode.actualInvestmentGrowth,
          tone: FeedbackTone.observation,
          parameters: {
            'currentMinutes': current.actualMinutes,
            'previousMinutes': previous.actualMinutes,
            'deltaMinutes': current.actualMinutes - previous.actualMinutes,
          },
          evidence: [
            FeedbackEvidence(
              code: 'actualMinutes',
              value: current.actualMinutes.toDouble(),
              referenceValue: previous.actualMinutes.toDouble(),
            ),
          ],
        ),
      );
    }

    _addImprovement(
      messages,
      code: FeedbackCode.completionImproved,
      metricCode: 'completionRate',
      current: current.completionRate,
      previous: previous.completionRate,
    );
    _addImprovement(
      messages,
      code: FeedbackCode.onTimeImproved,
      metricCode: 'onTimeCompletionRate',
      current: current.onTimeCompletionRate,
      previous: previous.onTimeCompletionRate,
    );

    final estimate = current.estimateVariance;
    if (messages.length < 3 &&
        estimate.isAvailable &&
        estimate.ratio!.abs() >= 0.25) {
      add(
        FeedbackMessage(
          code: FeedbackCode.estimateReviewSuggested,
          tone: FeedbackTone.suggestion,
          parameters: {
            'differencePercent': (estimate.ratio!.abs() * 100).round(),
          },
          evidence: [
            FeedbackEvidence(code: 'estimateVariance', value: estimate.ratio!),
          ],
        ),
      );
    }

    if (messages.length < 3 && current.commonInterruptions.isNotEmpty) {
      final common = current.commonInterruptions.first;
      if (common.count >= 3) {
        add(
          FeedbackMessage(
            code: FeedbackCode.interruptionPattern,
            tone: FeedbackTone.suggestion,
            parameters: {'count': common.count},
            evidence: [
              FeedbackEvidence(
                code: 'interruptionCount',
                value: common.count.toDouble(),
              ),
            ],
          ),
        );
      }
    }

    if (messages.length < 3 &&
        current.plannedMinutes > 0 &&
        current.actualMinutes > 0) {
      final difference =
          (current.actualMinutes - current.plannedMinutes).abs() /
          current.plannedMinutes;
      if (difference <= 0.15) {
        add(
          FeedbackMessage(
            code: FeedbackCode.planActualClose,
            tone: FeedbackTone.observation,
            parameters: {
              'plannedMinutes': current.plannedMinutes,
              'actualMinutes': current.actualMinutes,
            },
            evidence: [
              FeedbackEvidence(code: 'planActualDifference', value: difference),
            ],
          ),
        );
      }
    }

    return List.unmodifiable(messages);
  }

  void _addImprovement(
    List<FeedbackMessage> messages, {
    required FeedbackCode code,
    required String metricCode,
    required RatioMetric current,
    required RatioMetric previous,
  }) {
    if (messages.length >= 3 ||
        !current.isAvailable ||
        !previous.isAvailable ||
        current.ratio! <= previous.ratio!) {
      return;
    }
    messages.add(
      FeedbackMessage(
        code: code,
        tone: FeedbackTone.achievement,
        parameters: {
          'currentNumerator': current.numerator,
          'currentDenominator': current.denominator,
          'previousNumerator': previous.numerator,
          'previousDenominator': previous.denominator,
        },
        evidence: [
          FeedbackEvidence(
            code: metricCode,
            value: current.ratio!,
            referenceValue: previous.ratio,
          ),
        ],
      ),
    );
  }
}
