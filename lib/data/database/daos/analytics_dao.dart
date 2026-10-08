import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';

final class AnalyticsDao implements AnalyticsDataSource {
  const AnalyticsDao(this.database, {required this.calendar});

  final AppDatabase database;

  /// 固定日程的**展开与例外处理**从这里来。
  ///
  /// **刻意复用日历仓储而不是在统计层重算**：重复规则展开、跨午夜的例外行、"这一次被删除"的
  /// 零长度标记，这套约定已经由 `DriftCalendarRepository.occurrencesBetween` 实现并被日历页使用
  /// （`RecurrenceExpander` + 例外替换）。统计层再写一遍就是第二份约定，迟早两边不一致——本项目
  /// 在"存储键两端约定不一致"上已经吃过一次亏（技术设计 §13.0 的 W5）。
  ///
  /// **必填而不是可选**：可选会让"忘了注入"表现为"固定日程静默不计入领域占比"，而那正是本轮要修的
  /// 缺陷本身。宁可让调用点多传一个参数。
  final CalendarRepository calendar;

  @override
  Future<AnalyticsDataset> load(AnalyticsFilter filter) async {
    // 领域表**只查一次**：固定日程要领域名与生活标记，「领域覆盖缺口」要知道**全部**领域
    // （零占用的那些在任何分布里都不会出现）。
    final areaRows = await database.select(database.areas).get();
    final tasks = await _tasks(filter);
    final planned = await _planned(filter);
    final actual = await _actual(filter);
    final fixed = await _fixedEvents(filter, areaRows);
    final events = await _events(filter);
    return AnalyticsDataset(
      weeklyLifeQuotaMinutes: await _weeklyLifeQuota(),
      energyWindows: await _energyWindows(),
      protectedWindows: await _protectedWindows(),
      relaxedLocalDates: await _relaxedLocalDates(),
      tasks: tasks,
      plannedBlocks: planned,
      actualEntries: actual,
      fixedEvents: fixed,
      events: events,
      areas: [
        for (final row in areaRows)
          AnalyticsAreaFact(
            id: row.id,
            name: row.name,
            isLife: row.isLife,
            // M7（§11）：把颜色与排序位带进统计数据集，好让「领域占比」用**同一个**
            // `resolveAreaColorArgb` 取色，而不是按下标另编一套（那会让同一领域在
            // 统计页与今日页、日历页显示成不同颜色）。
            storedColorArgb: row.color,
            sortOrder: row.sortOrder,
          ),
      ],
    );
  }

  /// 读筛选范围内的固定日程，并带上所属领域名与生活标记。
  ///
  /// 领域名与生活标记由调用方**一次查全表**后传进来（`areas` 只有个位数行），避免每条日程各查
  /// 一次变成 N+1。与 `_taskFact` 同一判据：生活标记读领域上的 `is_life`，不按名字猜。
  Future<List<AnalyticsFixedFact>> _fixedEvents(
    AnalyticsFilter filter,
    List<Area> areaRows,
  ) async {
    final occurrences = await calendar.occurrencesBetween(
      filter.startUtc,
      filter.endUtc,
    );
    if (occurrences.isEmpty) return const [];

    final byId = {
      for (final row in areaRows) row.id: (name: row.name, isLife: row.isLife),
    };

    return [
      for (final occurrence in occurrences)
        AnalyticsFixedFact(
          title: occurrence.title,
          areaId: occurrence.areaId,
          areaName: byId[occurrence.areaId]?.name,
          isLife: byId[occurrence.areaId]?.isLife ?? false,
          startUtc: occurrence.range.startUtc,
          endUtc: occurrence.range.endUtc,
        ),
    ];
  }

  Future<List<AnalyticsTaskFact>> _tasks(AnalyticsFilter filter) async {
    final query = database.select(database.tasks).join([
      leftOuterJoin(
        database.projects,
        database.projects.id.equalsExp(database.tasks.projectId),
      ),
      leftOuterJoin(
        database.areas,
        database.areas.id.equalsExp(database.tasks.areaId),
      ),
    ]);
    if (filter.areaIds.isNotEmpty) {
      query.where(database.areas.id.isIn(filter.areaIds));
    }
    if (filter.projectIds.isNotEmpty) {
      query.where(database.tasks.projectId.isIn(filter.projectIds));
    }
    if (filter.statuses.isNotEmpty) {
      query.where(
        database.tasks.status.isIn(filter.statuses.map((item) => item.name)),
      );
    }
    final rows = await query.get();
    final tagsByTask = await _tagNamesByTask([
      for (final row in rows) row.readTable(database.tasks).id,
    ]);
    return [
      for (final row in rows)
        _taskFact(
          row.readTable(database.tasks),
          row.readTableOrNull(database.projects),
          row.readTableOrNull(database.areas),
          tagsByTask[row.readTable(database.tasks).id] ?? const {},
        ),
    ];
  }

  /// 一次查出这批任务的标签名，按任务分组。
  ///
  /// 逐任务查询会变成 N+1；这里与 `_tasks` 同样是单条 join 查询。返回的是**名称**而不是
  /// id，因为 `AnalyticsFilter.tags` 与界面用的都是名称。
  Future<Map<String, Set<String>>> _tagNamesByTask(List<String> taskIds) async {
    if (taskIds.isEmpty) return const {};
    final query = database.select(database.taskTags).join([
      innerJoin(
        database.tags,
        database.tags.id.equalsExp(database.taskTags.tagId),
      ),
    ])..where(database.taskTags.taskId.isIn(taskIds));
    final result = <String, Set<String>>{};
    for (final row in await query.get()) {
      final taskId = row.readTable(database.taskTags).taskId;
      final name = row.readTable(database.tags).name;
      (result[taskId] ??= <String>{}).add(name);
    }
    return result;
  }

  AnalyticsTaskFact _taskFact(
    Task task,
    Project? project,
    Area? area,
    Set<String> tags,
  ) {
    final status = TaskStatus.values.byName(task.status);
    final completedAt = status == TaskStatus.completed
        ? _instant(task.updatedAtUtc)
        : null;
    final areaName = area?.name;
    return AnalyticsTaskFact(
      id: task.id,
      title: task.title,
      areaId: area?.id,
      areaName: areaName,
      projectId: project?.id,
      // 标签此前从未填充，因此标签筛选恒返回空集——见 R1。
      tags: tags,
      status: status,
      estimatedMinutes: task.estimatedMinutes,
      dueAtUtc: task.dueAtUtc == null ? null : _instant(task.dueAtUtc!),
      completedAtUtc: completedAt,
      // 读领域上的生活标记，而不是猜领域名：名字匹配既漏（"家庭""健身"不是生活）
      // 又错（"生活服务业项目"会被算成生活）。见 `LifeAreaLookup`。
      isLifeTask: area?.isLife ?? false,
    );
  }

  Future<List<AnalyticsPlannedFact>> _planned(AnalyticsFilter filter) async {
    final query =
        database.select(database.scheduleBlocks).join([
            innerJoin(
              database.planVersions,
              database.planVersions.id.equalsExp(
                database.scheduleBlocks.planVersionId,
              ),
            ),
          ])
          ..where(database.planVersions.status.equals('confirmed'))
          ..where(
            database.scheduleBlocks.startAtUtc.isSmallerThanValue(
                  filter.endUtc.microsecondsSinceEpoch,
                ) &
                database.scheduleBlocks.endAtUtc.isBiggerThanValue(
                  filter.startUtc.microsecondsSinceEpoch,
                ),
          );
    return [
      for (final row in await query.get())
        AnalyticsPlannedFact(
          taskId: row.readTable(database.scheduleBlocks).taskId,
          startUtc: _instant(row.readTable(database.scheduleBlocks).startAtUtc),
          endUtc: _instant(row.readTable(database.scheduleBlocks).endAtUtc),
        ),
    ];
  }

  Future<List<AnalyticsActualFact>> _actual(AnalyticsFilter filter) async {
    final query = database.select(database.timeEntries)
      ..where(
        (row) =>
            row.recoveryState.equals('confirmed') &
            row.endedAtUtc.isNotNull() &
            row.startedAtUtc.isSmallerThanValue(
              filter.endUtc.microsecondsSinceEpoch,
            ) &
            row.endedAtUtc.isBiggerThanValue(
              filter.startUtc.microsecondsSinceEpoch,
            ),
      );
    return [
      for (final row in await query.get())
        AnalyticsActualFact(
          taskId: row.taskId,
          startUtc: _instant(row.startedAtUtc),
          endUtc: _instant(row.endedAtUtc!),
          activeMinutes: _activeMinutes(row),
        ),
    ];
  }

  int _activeMinutes(TimeEntry row) {
    try {
      final metadata = jsonDecode(row.source) as Map<String, Object?>;
      final microseconds = metadata['activeMicroseconds'];
      if (microseconds is int) {
        return Duration(microseconds: microseconds).inMinutes;
      }
    } on FormatException {
      // Older manually recorded entries may keep a plain source label.
    }
    final elapsed = row.endedAtUtc! - row.startedAtUtc;
    return ((elapsed ~/ Duration.microsecondsPerMinute) - row.pausedMinutes)
        .clamp(0, 1 << 31);
  }

  Future<List<AnalyticsEventFact>> _events(AnalyticsFilter filter) async {
    final query = database.select(database.changeLog)
      ..where(
        (row) =>
            row.changedAtUtc.isBiggerOrEqualValue(
              filter.startUtc.microsecondsSinceEpoch,
            ) &
            row.changedAtUtc.isSmallerThanValue(
              filter.endUtc.microsecondsSinceEpoch,
            ),
      );
    final result = <AnalyticsEventFact>[];
    for (final row in await query.get()) {
      final separator = row.operation.indexOf(':');
      if (separator <= 0 || separator == row.operation.length - 1) continue;
      final prefix = row.operation.substring(0, separator);
      final code = row.operation.substring(separator + 1);
      final kind = switch (prefix) {
        'interruption' => AnalyticsEventKind.interruption,
        'replan' => AnalyticsEventKind.replan,
        'suggestion' => AnalyticsEventKind.suggestion,
        _ => null,
      };
      if (kind == null) continue;
      result.add(
        AnalyticsEventFact(
          kind: kind,
          code: code,
          observedAtUtc: _instant(row.changedAtUtc),
        ),
      );
    }
    return result;
  }

  /// 读取用户的**保护时间**（睡眠／用餐／固定休息），供统计侧算"休息保护情况"（FR-STAT-05）。
  ///
  /// **`enabled=false` 的条目被跳过**——用户关掉的那段保护不该出现在"被占用"的统计里，
  /// 否则关闭保护反而让数字变差，读起来像惩罚。
  ///
  /// **两处此前会让这一节事实上不显示的问题，本轮一并修掉**：
  /// 1. **以默认值为底**。此前只读用户**已保存**的规则，而全新安装下这个键根本不存在，
  ///    于是 `protectedWindows` 为空、`_restProtection` 返回 `null`、整节不显示——尽管
  ///    默认值里午餐与晚餐本来就是受保护的。这与精力区间当初"区间不在数据集里"是同一类
  ///    失效：功能各层都在，只是**数据永远拿不到**。现在先取 `DefaultSettings.v1()`，
  ///    再用用户保存的列表**整体替换**（与 `PlanningRulesPatch.applyTo` 的语义一致：
  ///    非空列表是替换而不是合并）。
  /// 2. **把睡眠算进来**。"休息保护"里最主要的一段就是睡眠，而 `protectedTimes` 里只有
  ///    午餐／晚餐／固定休息——睡眠在 `sleepRange`。此前它完全不在这一节里，于是"休息保护"
  ///    只覆盖了三顿饭。睡眠**允许跨午夜**（默认 23:00–07:00），跨午夜的处理在服务侧。
  Future<List<AnalyticsProtectedWindow>> _protectedWindows() async {
    final defaults = DefaultSettings.v1();
    Map<String, Object?>? common;
    final query = database.select(database.settings)
      ..where((row) => row.key.equals('planning.userRules.v1'))
      ..limit(1);
    final setting = await query.getSingleOrNull();
    if (setting != null) {
      try {
        final json = jsonDecode(setting.jsonValue) as Map<String, Object?>;
        common = json['common'] as Map<String, Object?>?;
      } on FormatException {
        // 设置损坏时退回默认值，而不是让整节消失：默认的午餐与晚餐确实存在。
        common = null;
      }
    }

    final raw = common?['protectedTimes'] as List<Object?>?;
    final windows = <AnalyticsProtectedWindow>[];
    if (raw == null) {
      for (final rule in defaults.protectedTimes) {
        if (!rule.enabled) continue;
        windows.add(
          AnalyticsProtectedWindow(
            label: _protectedLabel(rule.kind),
            startMinute: rule.range.startMinute,
            endMinute: rule.range.endMinute,
            isWeekend: switch (rule.dayKind) {
              DayKind.weekend => true,
              DayKind.weekday => false,
              DayKind.any => null,
            },
          ),
        );
      }
    } else {
      for (final item in raw) {
        if (item is! Map<String, Object?> || item['enabled'] == false) continue;
        windows.add(
          AnalyticsProtectedWindow(
            label: switch (item['kind']) {
              'lunch' => '午餐',
              'dinner' => '晚餐',
              'fixedRest' => '固定休息',
              _ => '保护时间',
            },
            startMinute: _minuteOf(item['range'], 'startMinute'),
            endMinute: _minuteOf(item['range'], 'endMinute'),
            isWeekend: switch (item['dayKind']) {
              'weekend' => true,
              'weekday' => false,
              _ => null,
            },
          ),
        );
      }
    }

    // 睡眠始终加入：它不在 `protectedTimes` 里，而"休息保护"少了它就没有意义。
    final sleep = _rangeOf(common?['sleepRange']) ?? defaults.sleepRange;
    windows.add(
      AnalyticsProtectedWindow(
        label: '睡眠',
        startMinute: sleep.startMinute,
        endMinute: sleep.endMinute,
        // 睡眠不区分工作日与周末（默认区间是同一段），因此 `null` 表示两者都适用。
        isWeekend: null,
      ),
    );
    return windows;
  }

  static String _protectedLabel(ProtectedTimeKind kind) => switch (kind) {
    ProtectedTimeKind.lunch => '午餐',
    ProtectedTimeKind.dinner => '晚餐',
    ProtectedTimeKind.fixedRest => '固定休息',
  };

  /// 读出存在**按日临时例外**的本地日期（FR-REPLAN-07 的"临时放宽每日上限"）。
  ///
  /// 依据是设置键 `planning.dateOverride.<yyyy-MM-dd>`（`SettingsService` 写入的形状）。
  /// **键里本来就写着本地日期**，因此数据层不需要时区就能解析；至于这些日期是否落在筛选
  /// 范围内，由服务层按本地日判断（时区只有它有）。
  ///
  /// 读出来的日期本身不携带"放宽了什么"——本轮只关心"这一天被放宽过"。将来若要区分放宽的
  /// 字段（上限／睡眠／保护时间），需要把 JSON 一并解析出来。
  Future<List<DateTime>> _relaxedLocalDates() async {
    const prefix = 'planning.dateOverride.';
    final query = database.select(database.settings)
      ..where((row) => row.key.like('$prefix%'));
    final rows = await query.get();
    final dates = <DateTime>[];
    for (final row in rows) {
      final suffix = row.key.substring(prefix.length);
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(suffix);
      if (match == null) continue;
      final year = int.tryParse(match.group(1)!);
      final month = int.tryParse(match.group(2)!);
      final day = int.tryParse(match.group(3)!);
      if (year == null || month == null || day == null) continue;
      // 形状对但日期非法（如 2026-13-40）时跳过：`DateTime` 会把它规范化成另一天，
      // 那样会凭空造出一个不存在的"放宽日"。
      if (month < 1 || month > 12 || day < 1 || day > 31) continue;
      final date = DateTime.utc(year, month, day);
      if (date.month != month || date.day != day) continue;
      dates.add(date);
    }
    return dates;
  }

  LocalTimeRange? _rangeOf(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final start = value['startMinute'];
    final end = value['endMinute'];
    if (start is! int || end is! int) return null;
    return LocalTimeRange(
      startMinute: start.clamp(0, 24 * 60),
      endMinute: end.clamp(0, 24 * 60),
    );
  }

  /// 读取用户的精力区间（**本地时刻**），供统计侧把实际投入分桶（FR-STAT-05）。
  ///
  /// 与 `_weeklyLifeQuota` 走同一个设置键与同一条 `common` 路径。**缺设置或格式异常时返回
  /// 空列表**：统计侧据此**不显示**该节，而不是显示一个空壳区间——"没有数据"与"有区间但
  /// 没人投入"是两回事，不该长得一样。
  Future<List<AnalyticsEnergyWindow>> _energyWindows() async {
    final query = database.select(database.settings)
      ..where((row) => row.key.equals('planning.userRules.v1'))
      ..limit(1);
    final setting = await query.getSingleOrNull();
    if (setting == null) return const [];
    try {
      final json = jsonDecode(setting.jsonValue) as Map<String, Object?>;
      final common = json['common'] as Map<String, Object?>?;
      final raw = common?['energyWindows'] as List<Object?>?;
      if (raw == null) return const [];
      return [
        for (final item in raw)
          if (item is Map<String, Object?>)
            AnalyticsEnergyWindow(
              // 标签在这里定，统计模型因此不必依赖排程的 `EnergyLevel`。
              label: switch (item['level']) {
                'high' => '高精力',
                'medium' => '中精力',
                'low' => '低精力',
                _ => '未标记精力',
              },
              startMinute: _minuteOf(item['range'], 'startMinute'),
              endMinute: _minuteOf(item['range'], 'endMinute'),
              isWeekend: switch (item['dayKind']) {
                'weekend' => true,
                'weekday' => false,
                _ => null,
              },
            ),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// 取本地区间的分钟数；缺字段或类型不对时按 0 处理（宁可这一段不参与分桶，也不抛给界面）。
  int _minuteOf(Object? range, String key) {
    if (range is Map<String, Object?>) {
      final value = range[key];
      if (value is int) return value.clamp(0, 24 * 60);
    }
    return 0;
  }

  Future<int> _weeklyLifeQuota() async {
    final query = database.select(database.settings)
      ..where((row) => row.key.equals('planning.userRules.v1'))
      ..limit(1);
    final setting = await query.getSingleOrNull();
    if (setting == null) return DefaultSettings.v1().weeklyLifeQuotaMinutes;
    try {
      final json = jsonDecode(setting.jsonValue) as Map<String, Object?>;
      final common = json['common'] as Map<String, Object?>?;
      return common?['weeklyLifeQuotaMinutes'] as int? ??
          DefaultSettings.v1().weeklyLifeQuotaMinutes;
    } on FormatException {
      return DefaultSettings.v1().weeklyLifeQuotaMinutes;
    }
  }

  static DateTime _instant(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
}
