import 'dart:collection';

import 'package:personal_planner/domain/models/task.dart';

final class AnalyticsFilter {
  AnalyticsFilter({
    required this.startUtc,
    required this.endUtc,
    Set<String> areaIds = const {},
    Set<String> projectIds = const {},
    Set<String> tags = const {},
    Set<TaskStatus> statuses = const {},
  }) : areaIds = UnmodifiableSetView(Set.of(areaIds)),
       projectIds = UnmodifiableSetView(Set.of(projectIds)),
       tags = UnmodifiableSetView(Set.of(tags)),
       statuses = UnmodifiableSetView(Set.of(statuses)) {
    if (!startUtc.isUtc || !endUtc.isUtc) {
      throw ArgumentError('Analytics range must use UTC instants.');
    }
    if (!startUtc.isBefore(endUtc)) {
      throw ArgumentError('Analytics range must have positive duration.');
    }
  }

  final DateTime startUtc;
  final DateTime endUtc;
  final Set<String> areaIds;
  final Set<String> projectIds;
  final Set<String> tags;
  final Set<TaskStatus> statuses;
}

final class RatioMetric {
  const RatioMetric({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;

  bool get isAvailable => denominator > 0;
  double? get ratio => isAvailable ? numerator / denominator : null;
}

final class LifeQuotaMetric {
  const LifeQuotaMetric({
    required this.targetMinutes,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final int targetMinutes;
  final int plannedMinutes;
  final int actualMinutes;

  RatioMetric get plannedProgress =>
      RatioMetric(numerator: plannedMinutes, denominator: targetMinutes);

  RatioMetric get actualProgress =>
      RatioMetric(numerator: actualMinutes, denominator: targetMinutes);
}

final class DomainTimeMetric {
  const DomainTimeMetric({
    required this.id,
    required this.label,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final String id;
  final String label;
  final int plannedMinutes;
  final int actualMinutes;
}

final class DailyTimeMetric {
  const DailyTimeMetric({
    required this.dayUtc,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final DateTime dayUtc;
  final int plannedMinutes;
  final int actualMinutes;
}

final class RankedMetric {
  const RankedMetric(this.code, this.count);

  final String code;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is RankedMetric && other.code == code && other.count == count;

  @override
  int get hashCode => Object.hash(code, count);
}

final class SuggestionBehaviorMetric {
  const SuggestionBehaviorMetric({
    required this.accepted,
    required this.modified,
    required this.rejected,
  });

  final int accepted;
  final int modified;
  final int rejected;

  RatioMetric get acceptanceRate => RatioMetric(
    numerator: accepted,
    denominator: accepted + modified + rejected,
  );
}

final class AnalyticsReport {
  AnalyticsReport({
    required this.filter,
    required this.plannedMinutes,
    required this.actualMinutes,
    required this.completionRate,
    required this.onTimeCompletionRate,
    required this.overdueRate,
    required this.estimateVariance,
    required this.lifeQuota,
    required List<DomainTimeMetric> domainDistribution,
    required List<DailyTimeMetric> trend,
    required List<RankedMetric> commonInterruptions,
    required List<RankedMetric> replanReasons,
    required this.suggestionBehavior,
  }) : domainDistribution = UnmodifiableListView(domainDistribution),
       trend = UnmodifiableListView(trend),
       commonInterruptions = UnmodifiableListView(commonInterruptions),
       replanReasons = UnmodifiableListView(replanReasons);

  final AnalyticsFilter filter;
  final int plannedMinutes;
  final int actualMinutes;
  final RatioMetric completionRate;
  final RatioMetric onTimeCompletionRate;
  final RatioMetric overdueRate;
  final RatioMetric estimateVariance;
  final LifeQuotaMetric lifeQuota;
  final List<DomainTimeMetric> domainDistribution;
  final List<DailyTimeMetric> trend;
  final List<RankedMetric> commonInterruptions;
  final List<RankedMetric> replanReasons;
  final SuggestionBehaviorMetric suggestionBehavior;
}

final class AnalyticsTaskFact {
  AnalyticsTaskFact({
    required this.id,
    required this.title,
    required this.areaId,
    required this.areaName,
    required this.projectId,
    Set<String> tags = const {},
    required this.status,
    required this.estimatedMinutes,
    required this.isLifeTask,
    this.dueAtUtc,
    this.completedAtUtc,
  }) : tags = UnmodifiableSetView(Set.of(tags));

  final String id;
  final String title;
  final String? areaId;
  final String? areaName;
  final String? projectId;
  final Set<String> tags;
  final TaskStatus status;
  final int estimatedMinutes;
  final DateTime? dueAtUtc;
  final DateTime? completedAtUtc;
  final bool isLifeTask;
}

final class AnalyticsPlannedFact {
  const AnalyticsPlannedFact({
    required this.taskId,
    required this.startUtc,
    required this.endUtc,
  });

  final String taskId;
  final DateTime startUtc;
  final DateTime endUtc;
}

final class AnalyticsActualFact {
  const AnalyticsActualFact({
    required this.taskId,
    required this.startUtc,
    required this.endUtc,
    required this.activeMinutes,
  });

  final String taskId;
  final DateTime startUtc;
  final DateTime endUtc;
  final int activeMinutes;
}

enum AnalyticsEventKind { interruption, replan, suggestion }

final class AnalyticsEventFact {
  const AnalyticsEventFact({
    required this.kind,
    required this.code,
    required this.observedAtUtc,
  });

  final AnalyticsEventKind kind;
  final String code;
  final DateTime observedAtUtc;
}

final class AnalyticsDataset {
  AnalyticsDataset({
    required this.weeklyLifeQuotaMinutes,
    List<AnalyticsTaskFact> tasks = const [],
    List<AnalyticsPlannedFact> plannedBlocks = const [],
    List<AnalyticsActualFact> actualEntries = const [],
    List<AnalyticsEventFact> events = const [],
  }) : tasks = UnmodifiableListView(tasks),
       plannedBlocks = UnmodifiableListView(plannedBlocks),
       actualEntries = UnmodifiableListView(actualEntries),
       events = UnmodifiableListView(events);

  final int weeklyLifeQuotaMinutes;
  final List<AnalyticsTaskFact> tasks;
  final List<AnalyticsPlannedFact> plannedBlocks;
  final List<AnalyticsActualFact> actualEntries;
  final List<AnalyticsEventFact> events;
}
