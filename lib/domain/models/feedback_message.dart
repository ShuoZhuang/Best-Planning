import 'dart:collection';

enum FeedbackCode {
  lifeQuotaReached,
  actualInvestmentGrowth,
  completionImproved,
  onTimeImproved,
  estimateReviewSuggested,
  interruptionPattern,
  planActualClose,
}

enum FeedbackTone { achievement, suggestion, observation }

final class FeedbackEvidence {
  const FeedbackEvidence({
    required this.code,
    required this.value,
    this.referenceValue,
  });

  final String code;
  final double value;
  final double? referenceValue;
}

final class FeedbackMessage {
  FeedbackMessage({
    required this.code,
    required this.tone,
    required Map<String, num> parameters,
    required List<FeedbackEvidence> evidence,
  }) : parameters = UnmodifiableMapView(Map.of(parameters)),
       evidence = UnmodifiableListView(List.of(evidence));

  final FeedbackCode code;
  final FeedbackTone tone;
  final Map<String, num> parameters;
  final List<FeedbackEvidence> evidence;
}
