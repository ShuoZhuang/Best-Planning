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
  const AnalyticsService({required this.source, this.zones, this.timeZoneId});

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
      dataset.fixedEvents,
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
        (dataset.weeklyLifeQuotaMinutes * rangeMinutes / (7 * 24 * 60)).round();

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
      // ── 2026-10-06 统计复盘改版：按用户确认的清单新增的四项 ──
      // 全部**只依赖计划侧数据**（计划块、固定日程、保护时间设置）。用户明确要求把"实际投入"
      // 从统计里拿掉，因此这里一条都不读 `actualByEntry`。
      restSummary: _restSummary(
        windows: dataset.protectedWindows,
        planned: planned,
        fixed: dataset.fixedEvents,
        filter: filter,
        zones: zones,
        timeZoneId: timeZoneId,
      ),
      routine: _routine(
        planned: planned,
        fixed: dataset.fixedEvents,
        filter: filter,
        zones: zones,
        timeZoneId: timeZoneId,
      ),
      workRest: _workRest(
        protectedMinutes: _protectedMinutes(
          windows: dataset.protectedWindows,
          filter: filter,
          zones: zones,
          timeZoneId: timeZoneId,
        ),
        workedMinutes: _workedMinutes(
          taskById: taskById,
          planned: planned,
          fixed: dataset.fixedEvents,
          life: false,
          filter: filter,
        ),
        lifeMinutes: _workedMinutes(
          taskById: taskById,
          planned: planned,
          fixed: dataset.fixedEvents,
          life: true,
          filter: filter,
        ),
        scheduleMinutes: _scheduledIntersectingProtected(
          windows: dataset.protectedWindows,
          taskById: taskById,
          planned: planned,
          fixed: dataset.fixedEvents,
          filter: filter,
          zones: zones,
          timeZoneId: timeZoneId,
        ),
        filter: filter,
      ),
      areaCoverage: _areaCoverage(dataset.areas, domain),
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
  List<AnalyticsFixedFact> fixed,
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

  _MutableDomain domainForArea(String? areaId, String? areaName) =>
      values.putIfAbsent(
        areaId ?? 'unassigned',
        () => _MutableDomain(areaId ?? 'unassigned', areaName ?? '未分类'),
      );

  for (final item in planned) {
    domainFor(item.taskId).planned += _intersectionMinutes(
      item.startUtc,
      item.endUtc,
      filter,
    );
  }
  // 固定日程按**它自己的领域**归集，不经过任务表——课表本来就不挂在任务上。这也是"领域时间分配
  // 必须包含固定日程"那条反馈的落点。
  for (final item in fixed) {
    final minutes = _intersectionMinutes(item.startUtc, item.endUtc, filter);
    if (minutes <= 0) continue;
    domainForArea(item.areaId, item.areaName).fixed += minutes;
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
          fixedMinutes: item.fixed,
        ),
      )
      .toList();
  // 排序用**总占用**（计划块 + 固定日程）：领域时间分配看的是总时间，用实际投入排会让"有课表但
  // 还没记实际投入"的领域沉到底部——那正是用户库里发生的事（实际投入只有 1 条）。
  result.sort((a, b) {
    final byTotal = b.totalMinutes.compareTo(a.totalMinutes);
    if (byTotal != 0) return byTotal;
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
  int fixed = 0;
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
/// 范围内**每一条**保护时段实例：已按天展开、已裁到筛选范围、已处理跨午夜与 `endMinute == 1440`。
///
/// **抽出来给三处共用**：旧的"休息保护情况"、新的"休息时长（A）"、以及"工作与休息比例（D）"里的
/// 侵占计算。这段展开逻辑踩过两个坑——`endMinute == 1440` 直接传给 `localDateTimeToUtc` 会抛参数
/// 错误让整个查询失败（§13.0 的 C11），跨午夜则必须用**日历加法**（`day + 1`）而不是
/// `add(Duration(days: 1))`（夏令时回拨日会让日期不变）。**只应有一份实现**：抄第二份就等于给下一个
/// 改代码的人准备了一个"只修好一半"的机会。
List<({String label, DateTime startUtc, DateTime endUtc})> _protectedInstances({
  required List<AnalyticsProtectedWindow> windows,
  required AnalyticsFilter filter,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  final localStart = zones.toLocal(filter.startUtc, timeZoneId);
  final localEnd = zones.toLocal(filter.endUtc, timeZoneId);

  /// 把"锚定日在 [anchor]、本地第 [minute] 分钟"换算成 UTC。
  ///
  /// **`minute == 1440` 必须走次日零点**：`LocalTimeRange` 明确允许 `endMinute == 1440`
  /// （09:00–24:00 是合法且不跨午夜的区间），而 `localDateTimeToUtc` 只接受 [0, 1439]。
  DateTime boundaryUtc(DateTime anchor, int minute) {
    if (minute >= LocalTimeRange.minutesPerDay) {
      return zones.localMidnightToUtc(
        DateTime.utc(anchor.year, anchor.month, anchor.day + 1),
        timeZoneId,
      );
    }
    return zones.localDateTimeToUtc(anchor, minute, timeZoneId);
  }

  final instances = <({String label, DateTime startUtc, DateTime endUtc})>[];
  // **从范围首日的「前一天」开始走**：跨午夜的保护段（睡眠默认 23:00–07:00）锚定在**前一天**，
  // 而它的后半段（首日 00:00–07:00）落在范围之内。此前从首日本身开始，那一夜的后半段就被整个
  // 漏掉——7 天范围只报 2940 分钟而不是 3360，界面上一除便成"平均每天只睡 6 小时"。这是
  // 2026-10-06 把"休息时长"提到显眼位置时才暴露出来的旧缺陷（旧口径下它被淹没在长句里）。
  for (
    var day = DateTime.utc(
      localStart.year,
      localStart.month,
      localStart.day - 1,
    );
    !day.isAfter(DateTime.utc(localEnd.year, localEnd.month, localEnd.day));
    day = DateTime.utc(day.year, day.month, day.day + 1)
  ) {
    final isWeekend = day.weekday >= DateTime.saturday;
    for (final window in windows) {
      if (window.isWeekend != null && window.isWeekend != isWeekend) continue;
      final crossesMidnight = window.endMinute <= window.startMinute;
      final rawStart = boundaryUtc(day, window.startMinute);
      final rawEnd = crossesMidnight
          ? boundaryUtc(
              DateTime.utc(day.year, day.month, day.day + 1),
              window.endMinute,
            )
          : boundaryUtc(day, window.endMinute);
      final start = rawStart.isBefore(filter.startUtc)
          ? filter.startUtc
          : rawStart;
      final end = rawEnd.isAfter(filter.endUtc) ? filter.endUtc : rawEnd;
      if (!start.isBefore(end)) continue;
      instances.add((label: window.label, startUtc: start, endUtc: end));
    }
  }
  return instances;
}

/// 保护时段在范围内的**总容量**（A 与 D 的分母）。
int _protectedMinutes({
  required List<AnalyticsProtectedWindow> windows,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (windows.isEmpty || zones == null || timeZoneId == null) return 0;
  return _protectedInstances(
    windows: windows,
    filter: filter,
    zones: zones,
    timeZoneId: timeZoneId,
  ).fold<int>(
    0,
    (sum, item) => sum + item.endUtc.difference(item.startUtc).inMinutes,
  );
}

/// 范围内的**本地日数**（含首尾）。按本地日界数，而不是把 UTC 时长除 24——夏令时那一天不是 24 小时。
///
/// **末日取 `endUtc - 1µs` 所在的本地日**：`endUtc` 是**排他**上界，若它正好是本地零点，
/// 那一天的 00:00 并不在范围内。直接用它的日期会多算一天（7 天范围报成 8 天），而"平均每天
/// 休息多少"正是用这个数当分母的。
int _localDayCount(
  AnalyticsFilter filter,
  TimeZoneDatabase zones,
  String timeZoneId,
) {
  final localStart = zones.toLocal(filter.startUtc, timeZoneId);
  final localLast = zones.toLocal(
    filter.endUtc.subtract(const Duration(microseconds: 1)),
    timeZoneId,
  );
  final first = DateTime.utc(localStart.year, localStart.month, localStart.day);
  final last = DateTime.utc(localLast.year, localLast.month, localLast.day);
  return last.difference(first).inDays + 1;
}

/// 把一条安排裁到筛选范围，返回分钟数；完全在范围外返回 0。
int _scheduledMinutes(DateTime start, DateTime end, AnalyticsFilter filter) {
  final clippedStart = start.isBefore(filter.startUtc)
      ? filter.startUtc
      : start;
  final clippedEnd = end.isAfter(filter.endUtc) ? filter.endUtc : end;
  if (!clippedStart.isBefore(clippedEnd)) return 0;
  return clippedEnd.difference(clippedStart).inMinutes;
}

/// **休息时长（A）**：每类保护窗口的容量，以及其中被安排侵占的分钟数。
///
/// 口径与旧的"休息保护情况"**不同**，这是刻意的：旧口径按"实际专注有没有落进保护时间"算，
/// 而用户明确要求把实际投入从统计里全部拿掉，并把"有没有好好休息"改成看**自己的规划**——
/// 计划块/固定日程排进睡眠或午晚餐，就是规划层面的"没给自己留休息"。
RestSummaryMetric? _restSummary({
  required List<AnalyticsProtectedWindow> windows,
  required List<AnalyticsPlannedFact> planned,
  required List<AnalyticsFixedFact> fixed,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (windows.isEmpty || zones == null || timeZoneId == null) return null;
  final instances = _protectedInstances(
    windows: windows,
    filter: filter,
    zones: zones,
    timeZoneId: timeZoneId,
  );
  if (instances.isEmpty) return null;

  final scheduled = <(DateTime, DateTime)>[
    for (final item in planned)
      if (_scheduledMinutes(item.startUtc, item.endUtc, filter) > 0)
        (item.startUtc, item.endUtc),
    for (final item in fixed)
      if (_scheduledMinutes(item.startUtc, item.endUtc, filter) > 0)
        (item.startUtc, item.endUtc),
  ];

  /// 一条安排与**某一类窗口**的重叠分钟数，按该安排自身的长度封顶。
  ///
  /// 封顶是必要的：同一类的多条窗口可能彼此重叠（例如把固定休息设在睡眠里），不封顶会让
  /// "被侵占"超过"总容量"，界面上立刻出现一眼就像 bug 的数字（旧代码在 `_restProtection`
  /// 里也做了同样的 clamp，理由相同）。
  int invadedFor(
    Iterable<({String label, DateTime startUtc, DateTime endUtc})> subset,
    DateTime start,
    DateTime end,
  ) {
    var total = 0;
    for (final instance in subset) {
      final s = start.isAfter(instance.startUtc) ? start : instance.startUtc;
      final e = end.isBefore(instance.endUtc) ? end : instance.endUtc;
      if (s.isBefore(e)) total += e.difference(s).inMinutes;
    }
    final length = _scheduledMinutes(start, end, filter);
    return total > length ? length : total;
  }

  // 按标签分组，保持 windows 里第一次出现的顺序（用户设置里的顺序就是界面顺序）。
  final labels = <String>[];
  for (final window in windows) {
    if (!labels.contains(window.label)) labels.add(window.label);
  }

  final metrics = <RestWindowMetric>[];
  for (final label in labels) {
    final subset = instances.where((item) => item.label == label).toList();
    if (subset.isEmpty) continue;
    final minutes = subset.fold<int>(
      0,
      (sum, item) => sum + item.endUtc.difference(item.startUtc).inMinutes,
    );
    var invaded = 0;
    for (final (start, end) in scheduled) {
      invaded += invadedFor(subset, start, end);
    }
    metrics.add(
      RestWindowMetric(
        label: label,
        minutes: minutes,
        invadedMinutes: invaded.clamp(0, minutes),
      ),
    );
  }
  if (metrics.isEmpty) return null;

  return RestSummaryMetric(
    windows: metrics,
    days: _localDayCount(filter, zones, timeZoneId),
  );
}

/// 所有**已安排**的区间（计划块 + 固定日程），裁掉完全在范围外的。
List<(DateTime, DateTime)> _scheduledIntervals({
  required List<AnalyticsPlannedFact> planned,
  required List<AnalyticsFixedFact> fixed,
  required AnalyticsFilter filter,
}) => [
  for (final item in planned)
    if (_scheduledMinutes(item.startUtc, item.endUtc, filter) > 0)
      (item.startUtc, item.endUtc),
  for (final item in fixed)
    if (_scheduledMinutes(item.startUtc, item.endUtc, filter) > 0)
      (item.startUtc, item.endUtc),
];

/// **作息规律性（C）**：每天开工/收工时刻的散布。
///
/// 没有时区时返回空——本地时刻没有时区就无从谈起，按 UTC 算出来的"开工时刻"是错的，
/// 那比不显示更糟。
RoutineMetric _routine({
  required List<AnalyticsPlannedFact> planned,
  required List<AnalyticsFixedFact> fixed,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (zones == null || timeZoneId == null) {
    return const RoutineMetric(perDay: []);
  }
  final perDay = <DateTime, List<(int, int)>>{};
  for (final (start, end) in _scheduledIntervals(
    planned: planned,
    fixed: fixed,
    filter: filter,
  )) {
    final clippedStart = start.isBefore(filter.startUtc)
        ? filter.startUtc
        : start;
    final clippedEnd = end.isAfter(filter.endUtc) ? filter.endUtc : end;
    final localStart = zones.toLocal(clippedStart, timeZoneId);
    final localEnd = zones.toLocal(clippedEnd, timeZoneId);
    final day = DateTime.utc(localStart.year, localStart.month, localStart.day);
    final endDay = DateTime.utc(localEnd.year, localEnd.month, localEnd.day);
    final startMinute = localStart.hour * 60 + localStart.minute;
    // 跨到次日就记作当天 24:00 —— "收工"不该因为跨过一次午夜就变成一个更小的数。
    final endMinute = endDay.isAfter(day)
        ? LocalTimeRange.minutesPerDay
        : localEnd.hour * 60 + localEnd.minute;
    perDay.putIfAbsent(day, () => []).add((startMinute, endMinute));
  }
  if (perDay.isEmpty) return const RoutineMetric(perDay: []);

  final days = perDay.keys.toList()..sort();
  return RoutineMetric(
    perDay: [
      for (final day in days)
        DailyRoutineMetric(
          localDate: day,
          firstMinute: perDay[day]!
              .map((item) => item.$1)
              .reduce((a, b) => a < b ? a : b),
          lastMinute: perDay[day]!
              .map((item) => item.$2)
              .reduce((a, b) => a > b ? a : b),
        ),
    ],
  );
}

/// 按"是不是生活领域"把计划块与固定日程的分钟数分成两堆（D 的两段）。
int _workedMinutes({
  required Map<String, AnalyticsTaskFact> taskById,
  required List<AnalyticsPlannedFact> planned,
  required List<AnalyticsFixedFact> fixed,
  required bool life,
  required AnalyticsFilter filter,
}) {
  var total = 0;
  for (final item in planned) {
    final task = taskById[item.taskId];
    if (task == null || task.isLifeTask != life) continue;
    total += _scheduledMinutes(item.startUtc, item.endUtc, filter);
  }
  for (final item in fixed) {
    if (item.isLife != life) continue;
    total += _scheduledMinutes(item.startUtc, item.endUtc, filter);
  }
  return total;
}

/// 已安排的区间与保护时段的重叠分钟数（按每条安排自身长度封顶，理由同 `_restSummary`）。
int _scheduledIntersectingProtected({
  required List<AnalyticsProtectedWindow> windows,
  required Map<String, AnalyticsTaskFact> taskById,
  required List<AnalyticsPlannedFact> planned,
  required List<AnalyticsFixedFact> fixed,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (windows.isEmpty || zones == null || timeZoneId == null) return 0;
  final instances = _protectedInstances(
    windows: windows,
    filter: filter,
    zones: zones,
    timeZoneId: timeZoneId,
  );
  if (instances.isEmpty) return 0;

  var total = 0;
  for (final (start, end) in _scheduledIntervals(
    planned: planned,
    fixed: fixed,
    filter: filter,
  )) {
    var overlap = 0;
    for (final instance in instances) {
      final s = start.isAfter(instance.startUtc) ? start : instance.startUtc;
      final e = end.isBefore(instance.endUtc) ? end : instance.endUtc;
      if (s.isBefore(e)) overlap += e.difference(s).inMinutes;
    }
    final length = _scheduledMinutes(start, end, filter);
    total += overlap > length ? length : overlap;
  }
  return total;
}

/// **工作与休息的比例（D）**：四段划分，不重不漏。
WorkRestMetric? _workRest({
  required int protectedMinutes,
  required int workedMinutes,
  required int lifeMinutes,
  required int scheduleMinutes,
  required AnalyticsFilter filter,
}) {
  if (protectedMinutes <= 0) return null;
  final total = filter.endUtc.difference(filter.startUtc).inMinutes;
  if (total <= 0) return null;
  // **真正空着的休息** = 保护容量 − 被安排侵占的部分。用"容量减侵占"而不是直接把
  // 保护容量整段算成休息：把任务排进睡眠时段的人，不该因此在报表上看到"休息很充足"。
  final free = (protectedMinutes - scheduleMinutes).clamp(0, protectedMinutes);
  final idle = (total - workedMinutes - lifeMinutes - free).clamp(0, total);
  return WorkRestMetric(
    workMinutes: workedMinutes,
    lifeMinutes: lifeMinutes,
    restMinutes: free,
    idleMinutes: idle,
  );
}

/// **领域覆盖（#2）**：把"全部领域"与"有占用的领域"对起来，算出零占用的那些。
AreaCoverageMetric? _areaCoverage(
  List<AnalyticsAreaFact> areas,
  List<DomainTimeMetric> distribution,
) {
  if (areas.isEmpty) return null;
  final busy = {
    for (final item in distribution)
      if (item.totalMinutes > 0) item.id,
  };
  final covered = <String>[];
  final uncovered = <String>[];
  for (final area in areas) {
    (busy.contains(area.id) ? covered : uncovered).add(area.name);
  }
  covered.sort();
  uncovered.sort();
  return AreaCoverageMetric(
    covered: covered,
    uncovered: uncovered,
    totalAreas: areas.length,
  );
}

RestProtectionMetric? _restProtection({
  required List<AnalyticsProtectedWindow> windows,
  required List<DateTime> relaxedLocalDates,
  required Map<AnalyticsActualFact, int> actualByEntry,
  required AnalyticsFilter filter,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
}) {
  if (windows.isEmpty || zones == null || timeZoneId == null) return null;
  final instances = _protectedInstances(
    windows: windows,
    filter: filter,
    zones: zones,
    timeZoneId: timeZoneId,
  );

  var protectedMinutes = 0;
  var overlappedMinutes = 0;
  for (final instance in instances) {
    protectedMinutes += instance.endUtc.difference(instance.startUtc).inMinutes;
    overlappedMinutes += _actualOverlapScaled(
      actualByEntry,
      instance.startUtc,
      instance.endUtc,
    );
  }
  if (protectedMinutes <= 0) return null;

  final localStart = zones.toLocal(filter.startUtc, timeZoneId);
  final localEnd = zones.toLocal(filter.endUtc, timeZoneId);

  // "哪几天被临时放宽过"：日期由数据层原样交出，落在筛选范围哪一个本地日之间由这里判断
  // （时区只有服务层有）。范围按**本地日**而非 UTC 瞬时比较：键里写的就是本地日期，
  // 用 UTC 瞬时去比会在时区偏移下把边界那天算错。
  final firstLocalDay = DateTime.utc(
    localStart.year,
    localStart.month,
    localStart.day,
  );
  final lastLocalDay = DateTime.utc(
    localEnd.year,
    localEnd.month,
    localEnd.day,
  );
  final relaxedDays = relaxedLocalDates
      .where(
        (date) => !date.isBefore(firstLocalDay) && !date.isAfter(lastLocalDay),
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

/// 实际投入落在 `[start, end)` 里的分钟数，**按每段专注的实际占比折算**（暂停期间不算占用）。
///
/// 从 `_restProtection` 里抽出来，供保护时段展开后的逐段调用。
int _actualOverlapScaled(
  Map<AnalyticsActualFact, int> actualByEntry,
  DateTime start,
  DateTime end,
) {
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
