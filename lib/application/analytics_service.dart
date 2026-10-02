import 'dart:math' as math;

import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';

abstract interface class AnalyticsDataSource {
  Future<AnalyticsDataset> load(AnalyticsFilter filter);
}

abstract interface class AnalyticsQuery {
  Future<AnalyticsReport> query(AnalyticsFilter filter);
}

final class AnalyticsService implements AnalyticsQuery {
  const AnalyticsService({required this.source});

  final AnalyticsDataSource source;

  @override
  Future<AnalyticsReport> query(AnalyticsFilter filter) async {
    final dataset = await source.load(filter);
    final tasks = dataset.tasks
        .where((task) => _matches(task, filter))
        .toList();
    final taskById = {for (final task in tasks) task.id: task};

    final planned = dataset.plannedBlocks
        .where(
          (item) =>
              taskById.containsKey(item.taskId) &&
              _overlaps(item.startUtc, item.endUtc, filter),
        )
        .toList(growable: false);
    final actual = dataset.actualEntries
        .where(
          (item) =>
              taskById.containsKey(item.taskId) &&
              _overlaps(item.startUtc, item.endUtc, filter),
        )
        .toList(growable: false);

    final plannedMinutes = planned.fold<int>(
      0,
      (sum, item) =>
          sum + _intersectionMinutes(item.startUtc, item.endUtc, filter),
    );
    final actualByEntry = {
      for (final item in actual) item: _actualIntersectionMinutes(item, filter),
    };
    final actualMinutes = actualByEntry.values.fold<int>(0, (a, b) => a + b);

    final completionCandidates = tasks
        .where(
          (task) =>
              _inside(task.dueAtUtc, filter) ||
              _inside(task.completedAtUtc, filter),
        )
        .toList(growable: false);
    final completed = completionCandidates
        .where(
          (task) =>
              task.status == TaskStatus.completed &&
              task.completedAtUtc != null,
        )
        .toList(growable: false);
    final onTimeCandidates = completed
        .where((task) => task.dueAtUtc != null)
        .toList(growable: false);
    final dueCandidates = completionCandidates
        .where((task) => _inside(task.dueAtUtc, filter))
        .toList(growable: false);

    var estimateActual = 0;
    var estimateTotal = 0;
    final actualByTask = <String, int>{};
    for (final entry in actual) {
      actualByTask.update(
        entry.taskId,
        (value) => value + actualByEntry[entry]!,
        ifAbsent: () => actualByEntry[entry]!,
      );
    }
    for (final entry in actualByTask.entries) {
      final task = taskById[entry.key]!;
      if (task.estimatedMinutes <= 0) continue;
      estimateTotal += task.estimatedMinutes;
      estimateActual += entry.value;
    }

    final domain = _domainDistribution(
      taskById,
      planned,
      actualByEntry,
      filter,
    );
    final trend = _trend(planned, actualByEntry, filter);
    final lifeTaskIds = tasks
        .where((task) => task.isLifeTask)
        .map((task) => task.id)
        .toSet();
    final lifePlanned = planned
        .where((item) => lifeTaskIds.contains(item.taskId))
        .fold<int>(
          0,
          (sum, item) =>
              sum + _intersectionMinutes(item.startUtc, item.endUtc, filter),
        );
    final lifeActual = actualByEntry.entries
        .where((entry) => lifeTaskIds.contains(entry.key.taskId))
        .fold<int>(0, (sum, entry) => sum + entry.value);
    final rangeMinutes = filter.endUtc.difference(filter.startUtc).inMinutes;
    final target =
        (dataset.weeklyLifeQuotaMinutes *
                rangeMinutes /
                (7 * 24 * 60))
            .round();

    final events = dataset.events
        .where((event) => _inside(event.observedAtUtc, filter))
        .toList(growable: false);
    final suggestionCodes = events
        .where((event) => event.kind == AnalyticsEventKind.suggestion)
        .map((event) => event.code);

    return AnalyticsReport(
      filter: filter,
      plannedMinutes: plannedMinutes,
      actualMinutes: actualMinutes,
      completionRate: RatioMetric(
        numerator: completed.length,
        denominator: completionCandidates.length,
      ),
      onTimeCompletionRate: RatioMetric(
        numerator: onTimeCandidates
            .where((task) => !task.completedAtUtc!.isAfter(task.dueAtUtc!))
            .length,
        denominator: onTimeCandidates.length,
      ),
      overdueRate: RatioMetric(
        numerator: dueCandidates
            .where(
              (task) =>
                  task.completedAtUtc == null ||
                  task.completedAtUtc!.isAfter(task.dueAtUtc!),
            )
            .length,
        denominator: dueCandidates.length,
      ),
      estimateVariance: RatioMetric(
        numerator: estimateTotal == 0 ? 0 : estimateActual - estimateTotal,
        denominator: estimateTotal,
      ),
      lifeQuota: LifeQuotaMetric(
        targetMinutes: target,
        plannedMinutes: lifePlanned,
        actualMinutes: lifeActual,
      ),
      domainDistribution: domain,
      trend: trend,
      commonInterruptions: _ranked(events, AnalyticsEventKind.interruption),
      replanReasons: _ranked(events, AnalyticsEventKind.replan),
      suggestionBehavior: SuggestionBehaviorMetric(
        accepted: suggestionCodes.where((code) => code == 'accepted').length,
        modified: suggestionCodes.where((code) => code == 'modified').length,
        rejected: suggestionCodes.where((code) => code == 'rejected').length,
      ),
    );
  }
}

bool _matches(AnalyticsTaskFact task, AnalyticsFilter filter) {
  if (filter.areaIds.isNotEmpty && !filter.areaIds.contains(task.areaId)) {
    return false;
  }
  if (filter.projectIds.isNotEmpty &&
      !filter.projectIds.contains(task.projectId)) {
    return false;
  }
  if (filter.tags.isNotEmpty && !task.tags.containsAll(filter.tags)) {
    return false;
  }
  if (filter.statuses.isNotEmpty && !filter.statuses.contains(task.status)) {
    return false;
  }
  return true;
}

bool _overlaps(DateTime start, DateTime end, AnalyticsFilter filter) =>
    start.isBefore(filter.endUtc) && end.isAfter(filter.startUtc);

bool _inside(DateTime? instant, AnalyticsFilter filter) =>
    instant != null &&
    !instant.isBefore(filter.startUtc) &&
    instant.isBefore(filter.endUtc);

int _intersectionMinutes(DateTime start, DateTime end, AnalyticsFilter filter) {
  final clippedStart = start.isBefore(filter.startUtc)
      ? filter.startUtc
      : start;
  final clippedEnd = end.isAfter(filter.endUtc) ? filter.endUtc : end;
  if (!clippedStart.isBefore(clippedEnd)) return 0;
  return clippedEnd.difference(clippedStart).inMinutes;
}

int _actualIntersectionMinutes(
  AnalyticsActualFact entry,
  AnalyticsFilter filter,
) {
  final totalMicros = entry.endUtc.difference(entry.startUtc).inMicroseconds;
  if (totalMicros <= 0 || entry.activeMinutes <= 0) return 0;
  final clippedStart = entry.startUtc.isBefore(filter.startUtc)
      ? filter.startUtc
      : entry.startUtc;
  final clippedEnd = entry.endUtc.isAfter(filter.endUtc)
      ? filter.endUtc
      : entry.endUtc;
  if (!clippedStart.isBefore(clippedEnd)) return 0;
  final overlapMicros = clippedEnd.difference(clippedStart).inMicroseconds;
  return (entry.activeMinutes * overlapMicros / totalMicros).round();
}

List<DomainTimeMetric> _domainDistribution(
  Map<String, AnalyticsTaskFact> taskById,
  List<AnalyticsPlannedFact> planned,
  Map<AnalyticsActualFact, int> actual,
  AnalyticsFilter filter,
) {
  final values = <String, _MutableDomain>{};
  _MutableDomain domainFor(String taskId) {
    final task = taskById[taskId]!;
    final id = task.areaId ?? 'unassigned';
    return values.putIfAbsent(
      id,
      () => _MutableDomain(id, task.areaName ?? '未分类'),
    );
  }

  for (final item in planned) {
    domainFor(item.taskId).planned += _intersectionMinutes(
      item.startUtc,
      item.endUtc,
      filter,
    );
  }
  for (final item in actual.entries) {
    domainFor(item.key.taskId).actual += item.value;
  }
  final result = values.values
      .map(
        (item) => DomainTimeMetric(
          id: item.id,
          label: item.label,
          plannedMinutes: item.planned,
          actualMinutes: item.actual,
        ),
      )
      .toList();
  result.sort((a, b) {
    final byActual = b.actualMinutes.compareTo(a.actualMinutes);
    return byActual != 0 ? byActual : a.label.compareTo(b.label);
  });
  return result;
}

List<DailyTimeMetric> _trend(
  List<AnalyticsPlannedFact> planned,
  Map<AnalyticsActualFact, int> actual,
  AnalyticsFilter filter,
) {
  final days = <DateTime, _MutableDay>{};
  DateTime dayOf(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
  for (
    var day = dayOf(filter.startUtc);
    day.isBefore(filter.endUtc);
    day = day.add(const Duration(days: 1))
  ) {
    days[day] = _MutableDay();
  }
  for (final item in planned) {
    _allocate(
      start: item.startUtc,
      end: item.endUtc,
      totalMinutes: _intersectionMinutes(item.startUtc, item.endUtc, filter),
      filter: filter,
      add: (day, value) => days[day]!.planned += value,
    );
  }
  for (final item in actual.entries) {
    _allocate(
      start: item.key.startUtc,
      end: item.key.endUtc,
      totalMinutes: item.value,
      filter: filter,
      add: (day, value) => days[day]!.actual += value,
    );
  }
  return [
    for (final entry in days.entries)
      DailyTimeMetric(
        dayUtc: entry.key,
        plannedMinutes: entry.value.planned,
        actualMinutes: entry.value.actual,
      ),
  ];
}

void _allocate({
  required DateTime start,
  required DateTime end,
  required int totalMinutes,
  required AnalyticsFilter filter,
  required void Function(DateTime day, int value) add,
}) {
  if (totalMinutes <= 0) return;
  final clippedStart = start.isBefore(filter.startUtc)
      ? filter.startUtc
      : start;
  final clippedEnd = end.isAfter(filter.endUtc) ? filter.endUtc : end;
  final totalMicros = clippedEnd.difference(clippedStart).inMicroseconds;
  if (totalMicros <= 0) return;
  var cursor = clippedStart;
  var remaining = totalMinutes;
  while (cursor.isBefore(clippedEnd)) {
    final day = DateTime.utc(cursor.year, cursor.month, cursor.day);
    final nextDay = day.add(const Duration(days: 1));
    final segmentEnd = nextDay.isBefore(clippedEnd) ? nextDay : clippedEnd;
    final isLast = !segmentEnd.isBefore(clippedEnd);
    final value = isLast
        ? remaining
        : math.min(
            remaining,
            (totalMinutes *
                    segmentEnd.difference(cursor).inMicroseconds /
                    totalMicros)
                .round(),
          );
    add(day, value);
    remaining -= value;
    cursor = segmentEnd;
  }
}

List<RankedMetric> _ranked(
  List<AnalyticsEventFact> events,
  AnalyticsEventKind kind,
) {
  final counts = <String, int>{};
  for (final event in events.where((event) => event.kind == kind)) {
    counts.update(event.code, (value) => value + 1, ifAbsent: () => 1);
  }
  final result = counts.entries
      .map((entry) => RankedMetric(entry.key, entry.value))
      .toList();
  result.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.code.compareTo(b.code);
  });
  return result;
}

final class _MutableDomain {
  _MutableDomain(this.id, this.label);
  final String id;
  final String label;
  int planned = 0;
  int actual = 0;
}

final class _MutableDay {
  int planned = 0;
  int actual = 0;
}
