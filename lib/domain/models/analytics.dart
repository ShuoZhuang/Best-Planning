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

/// 一个精力区间，用**本地时刻**的分钟数表示（0–1439）。
///
/// 与排程侧的 `EnergyWindow` 分开定义，而且这里只带**标签字符串**而不是 `EnergyLevel`：
/// 统计模型因此不必依赖排程规则模型，两个模块各自演进时不会互相牵动。
final class AnalyticsEnergyWindow {
  const AnalyticsEnergyWindow({
    required this.label,
    required this.startMinute,
    required this.endMinute,
    required this.isWeekend,
  });

  final String label;
  final int startMinute;
  final int endMinute;

  /// `true` 只适用于周末、`false` 只适用于工作日、**`null` 表示每天都适用**。
  ///
  /// 用三态而不是布尔：用户的默认区间是"不分工作日与周末"（`DayKind.any`），把它当成
  /// "只适用工作日"会让周末的投入全部落进"未标记"，看起来像数据丢了。
  final bool? isWeekend;
}

/// 某个精力时段里的**完成效果**（FR-STAT-05）。
///
/// 两个数字都按**本地时刻**归桶：实际投入按每段专注的开始时刻所在区间计入，完成数按任务
/// 完成时刻所在区间计入——因此"高精力时段"说的是用户自己的生活时间，与库里存的 UTC 无关。
final class EnergyPeriodMetric {
  const EnergyPeriodMetric({
    required this.label,
    required this.actualMinutes,
    required this.completedTasks,
  });

  final String label;
  final int actualMinutes;
  final int completedTasks;
}

/// 一段**保护时间**（睡眠／用餐／固定休息），用本地分钟区间表示。
///
/// 与精力区间同样只带标签字符串，统计模型因此不依赖排程规则模型。
final class AnalyticsProtectedWindow {
  const AnalyticsProtectedWindow({
    required this.label,
    required this.startMinute,
    required this.endMinute,
    required this.isWeekend,
  });

  final String label;
  final int startMinute;
  final int endMinute;

  /// 与 [AnalyticsEnergyWindow.isWeekend] 同为三态：`null` 表示每天都适用。
  final bool? isWeekend;
}

/// **休息保护情况**（FR-STAT-05 的第三项）。
///
/// 口径为**默认选定**并写在这里：`protectedMinutes` 是筛选范围内保护时段的总时长，
/// `overlappedMinutes` 是其中**被实际专注覆盖**的分钟数（按每段专注的实际占比折算）。
/// 之所以选这个口径：两项都由**既有数据**算出，不需要任何新采集。
final class RestProtectionMetric {
  const RestProtectionMetric({
    required this.protectedMinutes,
    required this.overlappedMinutes,
  });

  final int protectedMinutes;
  final int overlappedMinutes;

  int get preservedMinutes => protectedMinutes - overlappedMinutes;

  /// 保护时段中**未被占用**的比例。没有保护时段时不可用（而不是 0）。
  RatioMetric get preservedRate => RatioMetric(
    numerator: preservedMinutes,
    denominator: protectedMinutes,
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
    // 带默认值：**"没有精力区间这一节"是合法状态**（未设置时区或用户还没设过区间），
    // 因此不强制每个构造点都写出一个空列表。
    List<EnergyPeriodMetric> energyPeriods = const [],
    // 同样是可空带默认：**"用户没设过保护时段"是合法状态**，此时该节不显示。
    this.restProtection,
    required this.suggestionBehavior,
  }) : domainDistribution = UnmodifiableListView(domainDistribution),
       trend = UnmodifiableListView(trend),
       commonInterruptions = UnmodifiableListView(commonInterruptions),
       replanReasons = UnmodifiableListView(replanReasons),
       energyPeriods = UnmodifiableListView(energyPeriods);

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
  final List<EnergyPeriodMetric> energyPeriods;
  final RestProtectionMetric? restProtection;
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
    List<AnalyticsEnergyWindow> energyWindows = const [],
    List<AnalyticsProtectedWindow> protectedWindows = const [],
    List<AnalyticsTaskFact> tasks = const [],
    List<AnalyticsPlannedFact> plannedBlocks = const [],
    List<AnalyticsActualFact> actualEntries = const [],
    List<AnalyticsEventFact> events = const [],
  }) : energyWindows = UnmodifiableListView(energyWindows),
       protectedWindows = UnmodifiableListView(protectedWindows),
       tasks = UnmodifiableListView(tasks),
       plannedBlocks = UnmodifiableListView(plannedBlocks),
       actualEntries = UnmodifiableListView(actualEntries),
       events = UnmodifiableListView(events);

  final int weeklyLifeQuotaMinutes;

  /// 用户的精力区间（本地时刻）。为空时统计侧**不显示**该节，而不是显示一个空壳。
  final List<AnalyticsEnergyWindow> energyWindows;

  /// 用户的保护时间（睡眠／用餐／固定休息），本地时刻。为空时不显示"休息保护"一节。
  final List<AnalyticsProtectedWindow> protectedWindows;
  final List<AnalyticsTaskFact> tasks;
  final List<AnalyticsPlannedFact> plannedBlocks;
  final List<AnalyticsActualFact> actualEntries;
  final List<AnalyticsEventFact> events;
}
