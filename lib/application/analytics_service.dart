import 'dart:math' as math;

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

abstract interface class AnalyticsDataSource {
  Future<AnalyticsDataset> load(AnalyticsFilter filter);
}

abstract interface class AnalyticsQuery {
  Future<AnalyticsReport> query(AnalyticsFilter filter);
}

final class AnalyticsService implements AnalyticsQuery {
  const AnalyticsService({
    required this.source,
    this.zones,
    this.timeZoneId,
  });

  final AnalyticsDataSource source;

  /// 精力分桶要按**本地时刻**（精力区间是本地时间），因此需要时区。
  ///
  /// 未装配时**不显示该节**，而不是按 UTC 归桶——那会把"高精力时段"算成用户从未设置过的
  /// 时刻，看起来像数据，实际是错的。
  final TimeZoneDatabase? zones;
  final String? timeZoneId;

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
      // FR-STAT-05 的"不同精力时段的完成效果"。窗口来自数据集（用户设置），归桶在这里做：
      // 只有服务层同时握有"按筛选条件选出的任务"与"每条实际投入的分钟数"。
      energyPeriods: _energyPeriods(
        windows: dataset.energyWindows,
        actualByEntry: actualByEntry,
        tasks: tasks,
        filter: filter,
        zones: zones,
        timeZoneId: timeZoneId,
      ),
      // FR-STAT-05 的"休息保护情况"。与精力分桶同理：只有服务层同时握有筛选后的任务、
      // 实际投入与那次查询的时区。
      restProtection: _restProtection(
        windows: dataset.protectedWindows,
        relaxedLocalDates: dataset.relaxedLocalDates,
        actualByEntry: actualByEntry,
        filter: filter,
        zones: zones,
        timeZoneId: timeZoneId,
      ),
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

/// 把实际投入与完成数按**本地时刻**归入用户的精力区间（FR-STAT-05）。
///
/// 三条口径，写下来是因为它们决定了页面上的数字：
/// ① **一段专注算在它开始的那个区间**——按开始时刻归属，而不是把一段跨区间的专注切成两半，
///    否则两个区间各拿一部分、两边都不代表用户实际做了什么；
/// ② **完成数按任务的完成时刻**归属，而不是按任务的计划时刻——"完成效果"问的是结果发生在
///    哪个精力时段；
/// ③ **区间之外（含未标记时段）的投入不计入任何一行**，因为没有一行能诚实地代表它。
List<EnergyPeriodMetric> _energyPeriods({
  required List<AnalyticsEnergyWindow> windows,
  required Map<AnalyticsActualFact, int> actualByEntry,
  required List<AnalyticsTaskFact> tasks,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (windows.isEmpty || zones == null || timeZoneId == null) return const [];

  String? labelOf(DateTime instantUtc) {
    final local = zones.toLocal(instantUtc, timeZoneId);
    final minuteOfDay = local.hour * 60 + local.minute;
    final isWeekend = local.weekday >= DateTime.saturday;
    for (final window in windows) {
      if (window.isWeekend != null && window.isWeekend != isWeekend) continue;
      if (minuteOfDay >= window.startMinute && minuteOfDay < window.endMinute) {
        return window.label;
      }
    }
    return null;
  }

  final minutes = <String, int>{};
  for (final entry in actualByEntry.entries) {
    final label = labelOf(entry.key.startUtc);
    if (label == null) continue;
    minutes.update(
      label,
      (value) => value + entry.value,
      ifAbsent: () => entry.value,
    );
  }

  final completed = <String, int>{};
  for (final task in tasks) {
    final completedAt = task.completedAtUtc;
    if (completedAt == null || !_inside(completedAt, filter)) continue;
    final label = labelOf(completedAt);
    if (label == null) continue;
    completed.update(label, (value) => value + 1, ifAbsent: () => 1);
  }

  final labels = <String>{for (final window in windows) window.label};
  final result = [
    for (final label in labels)
      EnergyPeriodMetric(
        label: label,
        actualMinutes: minutes[label] ?? 0,
        completedTasks: completed[label] ?? 0,
      ),
  ];
  result.sort((a, b) {
    final byMinutes = b.actualMinutes.compareTo(a.actualMinutes);
    return byMinutes != 0 ? byMinutes : a.label.compareTo(b.label);
  });
  return result;
}

/// 休息保护情况（FR-STAT-05 的第三项）。
///
/// **口径（默认选定，写在此备查）**：把筛选范围内每一天的每一段保护时间换算成 UTC 区间，
/// **保护总时长**是这些区间与筛选范围的交集之和；**被占用时长**是这些区间与实际专注的重叠，
/// 并按每段专注的**实际占比**折算——与 `_actualIntersectionMinutes` 同一口径，否则"休息被
/// 占用"会按挂钟时长虚高（一段暂停很久的专注会把整段保护时间算成被占用）。
///
/// 逐"本地日 × 保护段"生成区间，而不是逐分钟扫描：一年的范围有几十万分钟，而这里的规模是
/// "天数 × 保护段数"，即便再乘以专注条数也仍然很小。
///
/// **跨午夜的保护段（`endMinute <= startMinute`）是被支持的**：睡眠默认就是 23:30–07:30，
/// 而"休息保护"少了它就没有意义（数据层 `analytics_dao.dart` 的 `_protectedWindows()` 会把
/// 睡眠**始终**加入窗口，那里有同样的说明）。实现方式是把终点锚在**次日**的同名分钟上。
///
/// **此处曾有一句反过来的旧注释**（原文："跨午夜的保护段被跳过……因此这里不猜跨午夜语义"），
/// 它描述的是更早的实现，与本方法下文的 `crossesMidnight` 处理**直接矛盾**，已删除——
/// 留着它会让下一个读代码的人以为睡眠没被算进去，从而去修一个不存在的问题。
///
/// **口径经产品侧确认（2026-10-04）：休息保护按"实际发生"计算**——保护窗口被**实际专注**占用
/// 即算被牺牲，空着即算被保护；**不是**看计划块有没有排进保护窗口（"排程器尊不尊重休息"是另一种
/// 定义，会给出不同数字，本轮未采用）。
RestProtectionMetric? _restProtection({
  required List<AnalyticsProtectedWindow> windows,
  required List<DateTime> relaxedLocalDates,
  required Map<AnalyticsActualFact, int> actualByEntry,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (windows.isEmpty || zones == null || timeZoneId == null) return null;

  int overlapScaled(DateTime start, DateTime end) {
    var total = 0;
    for (final entry in actualByEntry.entries) {
      final entryStart = entry.key.startUtc;
      final entryEnd = entry.key.endUtc;
      final overlapStart = entryStart.isAfter(start) ? entryStart : start;
      final overlapEnd = entryEnd.isBefore(end) ? entryEnd : end;
      if (!overlapStart.isBefore(overlapEnd)) continue;
      final entryMicros = entryEnd.difference(entryStart).inMicroseconds;
      if (entryMicros <= 0) continue;
      total +=
          (entry.value *
                  overlapEnd.difference(overlapStart).inMicroseconds /
                  entryMicros)
              .round();
    }
    return total;
  }

  final localStart = zones.toLocal(filter.startUtc, timeZoneId);
  final localEnd = zones.toLocal(filter.endUtc, timeZoneId);

  /// 把"锚定日在 [anchor]、本地第 [minute] 分钟"换算成 UTC。
  ///
  /// **`minute == 1440` 必须走次日零点**：`LocalTimeRange` 明确允许 `endMinute == 1440`
  /// （09:00–24:00 是合法且不跨午夜的区间），而 `localDateTimeToUtc` 只接受 [0, 1439]，
  /// 直接传会抛参数错误、让整个统计查询失败。这正是 §13.0 的 C11 在保护时间展开器上记过的
  /// 那个"类型允许、运行必炸"——统计侧此前有同一处，只是从未被触发（用户没设过 24:00 的
  /// 保护段）。**日期推进用日历加法**（`day + 1`）而不是 `add(Duration(days: 1))`：后者是
  /// 绝对时间加法，在夏令时回拨日会让日期不变（C11 的第二半）。
  DateTime boundaryUtc(DateTime anchor, int minute) {
    // 1440 必须换成"次日本地零点"这**一个**调用，而不是把 1440 传给 `localDateTimeToUtc`
    // ——后者只接受 [0, 1439]。（第一版就是只改了锚点日、仍把 1440 传下去，用例当场报
    // `Invalid argument (minuteOfDay): 1440`。）
    if (minute >= LocalTimeRange.minutesPerDay) {
      return zones.localMidnightToUtc(
        DateTime.utc(anchor.year, anchor.month, anchor.day + 1),
        timeZoneId,
      );
    }
    return zones.localDateTimeToUtc(anchor, minute, timeZoneId);
  }

  var protectedMinutes = 0;
  var overlappedMinutes = 0;
  for (
    var day = DateTime.utc(localStart.year, localStart.month, localStart.day);
    !day.isAfter(DateTime.utc(localEnd.year, localEnd.month, localEnd.day));
    day = DateTime.utc(day.year, day.month, day.day + 1)
  ) {
    final isWeekend = day.weekday >= DateTime.saturday;
    for (final window in windows) {
      if (window.isWeekend != null && window.isWeekend != isWeekend) continue;
      // **跨午夜的保护段现在被支持**：睡眠默认就是 23:00–07:00。此前这里直接 `continue`
      // 跳过——理由是"`protectedTimes` 里只有午餐、晚餐与固定休息"，那句话对当时的数据是
      // 对的，但睡眠正是最该被算进"休息保护"的那一段。`endMinute <= startMinute` 因此改判为
      // "跨到次日"，终点锚在**次日**的同名分钟上。
      final crossesMidnight = window.endMinute <= window.startMinute;
      final rawStart = boundaryUtc(day, window.startMinute);
      final rawEnd = crossesMidnight
          ? boundaryUtc(DateTime.utc(day.year, day.month, day.day + 1),
              window.endMinute)
          : boundaryUtc(day, window.endMinute);
      final start = rawStart.isBefore(filter.startUtc)
          ? filter.startUtc
          : rawStart;
      final end = rawEnd.isAfter(filter.endUtc) ? filter.endUtc : rawEnd;
      if (!start.isBefore(end)) continue;
      protectedMinutes += end.difference(start).inMinutes;
      overlappedMinutes += overlapScaled(start, end);
    }
  }

  // "哪几天被临时放宽过"：日期由数据层原样交出，落在筛选范围哪一个本地日之间由这里判断
  // （时区只有服务层有）。范围按**本地日**而非 UTC 瞬时比较：键里写的就是本地日期，
  // 用 UTC 瞬时去比会在时区偏移下把边界那天算错。
  final firstLocalDay = DateTime.utc(
    localStart.year,
    localStart.month,
    localStart.day,
  );
  final lastLocalDay = DateTime.utc(localEnd.year, localEnd.month, localEnd.day);
  final relaxedDays = relaxedLocalDates
      .where(
        (date) =>
            !date.isBefore(firstLocalDay) && !date.isAfter(lastLocalDay),
      )
      .length;

  return RestProtectionMetric(
    protectedMinutes: protectedMinutes,
    // 逐段四舍五入可能让被占用比保护总时长多出一两分钟；夹住它，避免出现"占用 61 / 保护 60"
    // 这种界面上一眼就像 bug 的数字。
    overlappedMinutes: overlappedMinutes.clamp(0, protectedMinutes),
    relaxedDays: relaxedDays,
  );
}
