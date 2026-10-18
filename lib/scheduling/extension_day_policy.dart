import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一个**稳定排序**的临时延长日候选（规范 §8.2 / ALG20-047）。
final class ExtensionDayCandidate {
  const ExtensionDayCandidate({
    required this.localDate,
    required this.temporarySleepStartOffsetMinutes,
    required this.fixedWakeOffsetMinutes,
    required this.addedPlaceableMinutes,
    required this.sleepLossMinutes,
    required this.triggeringTaskIds,
    required this.stableKey,
    this.originalSleepStartOffsetMinutes,
  });

  final DateTime localDate;
  final int temporarySleepStartOffsetMinutes;
  final int fixedWakeOffsetMinutes;

  /// 原入睡偏移；页面确认时用它校验 `original <= temporary`。为空时服务会推导。
  final int? originalSleepStartOffsetMinutes;
  final int addedPlaceableMinutes;
  final int sleepLossMinutes;
  final List<String> triggeringTaskIds;
  final String stableKey;
}

/// 建议/接受/拒绝共用的稳定建议 ID（算法 20）。
String extensionSuggestionId(ExtensionDayCandidate candidate) =>
    'extension:${formatLocalDate(candidate.localDate)}:'
    '${candidate.temporarySleepStartOffsetMinutes}:'
    '${candidate.fixedWakeOffsetMinutes}';

/// 从已确认的特殊日事实得到同一个稳定建议 ID。
String dayExceptionSuggestionId(DayException exception) =>
    'extension:${formatLocalDate(exception.localDate)}:'
    '${exception.temporarySleepStartOffsetMinutes}:'
    '${exception.fixedWakeOffsetMinutes}';

/// 临时延长日的纯规则：硬边界、候选排序与拒绝记忆键（规范 §8.2）。
///
/// **它不写库**：提出候选与确认是两件事；确认走 `DayExceptionService` 与
/// `PlanningCommitRepository` 的同一事务。
final class ExtensionDayPolicy {
  const ExtensionDayPolicy({this.stepMinutes = 30, this.maxCandidates = 3});

  final int stepMinutes;
  final int maxCandidates;

  List<ExtensionDayCandidate> buildCandidates({
    required ScheduleProblem problem,
    required List<SchedulableTask> triggeringTasks,
    required Set<DateTime> allowedDates,
    required int absoluteMinimumSleepMinutes,
    required TimeZoneDatabase zones,
    required DateTime nowUtc,
  }) {
    if (triggeringTasks.isEmpty) return const [];
    if (stepMinutes < 5 || maxCandidates <= 0) return const [];

    final byDate = <DateTime, ExtensionDayCandidate>{};
    final today = _localDateOf(nowUtc, problem, zones);
    for (final date in problem.dailyPolicies.keys.toList()..sort()) {
      if (date.isBefore(today)) continue;
      if (!allowedDates.contains(date)) continue;
      final policy = problem.policyForLocalDate(date);
      final sleep = policy.resolvedRules.sleepRange;
      final original = sleep.startMinute;
      final wake = sleep.crossesMidnight
          ? sleep.endMinute + 24 * 60
          : sleep.endMinute;
      final maxTemporary = wake - absoluteMinimumSleepMinutes;
      if (maxTemporary <= original || maxTemporary > 48 * 60) continue;

      for (
        var temporary = _roundUp(original + stepMinutes, stepMinutes);
        temporary <= maxTemporary;
        temporary += stepMinutes
      ) {
        final window = _window(
          date: date,
          startOffsetMinutes: original,
          endOffsetMinutes: temporary,
          zones: zones,
          timeZoneId: problem.timeZoneId,
        );
        if (_overlapsHardOccupancy(problem, window)) continue;
        final triggering = <String>[];
        var added = 0;
        for (final task in triggeringTasks) {
          if (!_canUse(task: task, window: window)) continue;
          final gain = _gainFor(
            task,
            window,
            policy.resolvedRules.granularityMinutes,
          );
          if (gain <= 0) continue;
          triggering.add(task.id);
          if (gain > added) added = gain;
        }
        if (triggering.isEmpty || added <= 0) continue;
        final candidate = ExtensionDayCandidate(
          localDate: date,
          originalSleepStartOffsetMinutes: original,
          temporarySleepStartOffsetMinutes: temporary,
          fixedWakeOffsetMinutes: wake,
          addedPlaceableMinutes: added,
          sleepLossMinutes: temporary - original,
          triggeringTaskIds: triggering..sort(),
          stableKey: _stableKey(date, temporary, wake, triggering),
        );
        final existing = byDate[date];
        if (existing == null || _isBetter(candidate, existing)) {
          byDate[date] = candidate;
        }
      }
    }

    final ordered = byDate.values.toList()
      ..sort((a, b) {
        final added = b.addedPlaceableMinutes.compareTo(
          a.addedPlaceableMinutes,
        );
        if (added != 0) return added;
        final loss = a.sleepLossMinutes.compareTo(b.sleepLossMinutes);
        if (loss != 0) return loss;
        final date = a.localDate.compareTo(b.localDate);
        return date != 0 ? date : a.stableKey.compareTo(b.stableKey);
      });
    return List.unmodifiable(ordered.take(maxCandidates));
  }

  bool _isBetter(ExtensionDayCandidate a, ExtensionDayCandidate b) {
    if (a.addedPlaceableMinutes != b.addedPlaceableMinutes) {
      return a.addedPlaceableMinutes > b.addedPlaceableMinutes;
    }
    return a.sleepLossMinutes < b.sleepLossMinutes;
  }

  TimeRange _window({
    required DateTime date,
    required int startOffsetMinutes,
    required int endOffsetMinutes,
    required TimeZoneDatabase zones,
    required String timeZoneId,
  }) => TimeRange(
    startUtc: _offsetToUtc(zones, timeZoneId, date, startOffsetMinutes),
    endUtc: _offsetToUtc(zones, timeZoneId, date, endOffsetMinutes),
  );

  DateTime _offsetToUtc(
    TimeZoneDatabase zones,
    String timeZoneId,
    DateTime date,
    int offset,
  ) {
    final dayOffset = offset ~/ (24 * 60);
    final minute = offset % (24 * 60);
    return zones.localDateTimeToUtc(
      DateTime(date.year, date.month, date.day + dayOffset),
      minute,
      timeZoneId,
    );
  }

  bool _overlapsHardOccupancy(ScheduleProblem problem, TimeRange window) {
    bool overlaps(TimeRange other) =>
        window.startUtc.isBefore(other.endUtc) &&
        other.startUtc.isBefore(window.endUtc);
    return problem.fixedIntervals.any((item) => overlaps(item.range)) ||
        problem.protectedIntervals.any((item) => overlaps(item.range)) ||
        problem.lockedBlocks.any((item) => overlaps(item.range));
  }

  bool _canUse({required SchedulableTask task, required TimeRange window}) {
    final from = task.availableFromUtc;
    if (from != null && !from.isBefore(window.endUtc)) return false;
    final due = task.dueAtUtc;
    if (due != null && !due.isAfter(window.startUtc)) return false;
    return true;
  }

  int _gainFor(SchedulableTask task, TimeRange window, int granularity) {
    final due = task.dueAtUtc;
    var end = window.endUtc;
    if (due != null && due.isBefore(end)) end = due;
    final minutes = end.difference(window.startUtc).inMinutes;
    if (minutes <= 0) return 0;
    final usable = (minutes ~/ granularity) * granularity;
    if (task.splitMode == TaskSplitMode.continuous) {
      return usable >= task.requiredMinutes ? task.requiredMinutes : 0;
    }
    final minChunk = task.minChunkMinutes <= 0
        ? granularity
        : task.minChunkMinutes;
    if (usable < minChunk) return 0;
    return usable < task.requiredMinutes ? usable : task.requiredMinutes;
  }

  String _stableKey(
    DateTime date,
    int temporary,
    int wake,
    List<String> taskIds,
  ) {
    final ordered = [...taskIds]..sort();
    return '${formatLocalDate(date)}|$temporary|$wake|${ordered.join(',')}';
  }

  DateTime _localDateOf(
    DateTime instantUtc,
    ScheduleProblem problem,
    TimeZoneDatabase zones,
  ) {
    final local = zones.toLocal(instantUtc, problem.timeZoneId);
    return DateTime(local.year, local.month, local.day);
  }

  int _roundUp(int value, int step) => ((value + step - 1) ~/ step) * step;
}

/// 拒绝记忆：相同输入哈希 + 相同候选键不再重复弹出（ALG20-049）。
abstract interface class ExtensionRejectionStore {
  Future<bool> isRejected(String key);

  Future<void> rememberRejected(String key);
}

final class MemoryExtensionRejectionStore implements ExtensionRejectionStore {
  final Set<String> _keys = {};

  @override
  Future<bool> isRejected(String key) async => _keys.contains(key);

  @override
  Future<void> rememberRejected(String key) async {
    _keys.add(key);
  }
}
