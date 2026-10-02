import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 生产用的排程输入来源：把持久化的事实数据装配成 `ScheduleProblem`。
///
/// 这是此前缺失的一环——`InputSnapshotBuilder` 只负责对已有的 `ScheduleProblem`
/// 求哈希，仓库层与排程引擎之间没有任何代码负责装配输入，因此引擎、提案与
/// 调整预览在真实运行中都不可达。
///
/// 装配规则：
/// - 规划窗口为从"本机当前时区的今天 00:00"起 [days] 天的半开区间；
/// - 固定日程取窗口内全部 `CalendarOccurrence`；
/// - 保护时间由 [ProtectedTimeExpander] 逐日展开；
/// - 仅有 `locked` 的已确认计划块进入 `lockedBlocks`，未锁定块不冻结，
///   以便重排可以移动它们；
/// - `rules` 的日间字段（精力区间、保护时间）同时保留工作日与周末两套，
///   由引擎按当天 `DayKind` 筛选；睡眠、每日上限、生活配额等"整窗口唯一"的
///   字段取窗口首日的解析结果——这是 `ScheduleProblem.rules` 单一对象的既有
///   限制，跨工作日与周末的窗口不会为周末单独取一份上限。
///
/// 已知缺口：`PreferenceProfile` 目前传入空值。学习偏好已由
/// `SettingsService.resolveForDate` 合并进 `rules`，但计划模型中的
/// `preferences` 字段（常用专注长度、偏好精力区间）尚无公开读取路径。
final class RepositoryScheduleProblemSource implements ScheduleProblemSource {
  RepositoryScheduleProblemSource({
    required this.tasks,
    required this.calendar,
    required this.settings,
    required this.plans,
    required this.clock,
    required this.timeZoneId,
    required this.zones,
    this.days = 7,
    this.snapshots = const InputSnapshotBuilder(),
  }) : protectedTimes = ProtectedTimeExpander(zones);

  final TaskRepository tasks;
  final CalendarRepository calendar;
  final SettingsService settings;
  final PlanRepository plans;
  final Clock clock;
  final String timeZoneId;
  final TimeZoneDatabase zones;
  final int days;
  final InputSnapshotBuilder snapshots;
  final ProtectedTimeExpander protectedTimes;

  @override
  Future<ScheduleProblem> load() async {
    final nowUtc = clock.nowUtc();
    final startLocalDate = _dateOnly(zones.toLocal(nowUtc, timeZoneId));
    final startUtc = zones.localMidnightToUtc(startLocalDate, timeZoneId);
    final endUtc = zones.localMidnightToUtc(
      startLocalDate.add(Duration(days: days)),
      timeZoneId,
    );

    final rules = await _windowRules(startLocalDate);
    final openTasks = await tasks.watchOpenTasks().first;
    final occurrences = await calendar.occurrencesBetween(startUtc, endUtc);
    final confirmed = await plans.current();

    final schedulable = <SchedulableTask>[
      for (final task in openTasks)
        SchedulableTask(
          id: task.id,
          requiredMinutes: task.schedulingRemainingMinutes,
          splitMode: task.splitMode,
          minChunkMinutes: task.minChunkMinutes,
          maxChunkMinutes: task.maxChunkMinutes,
          dueAtUtc: task.dueAtUtc,
          priority: task.priority,
          energyLevel: task.energyLevel,
        ),
    ];
    final schedulableIds = {for (final task in schedulable) task.id};

    final problem = ScheduleProblem(
      planningWindow: TimeRange(startUtc: startUtc, endUtc: endUtc),
      timeZoneId: timeZoneId,
      tasks: schedulable,
      fixedIntervals: [
        for (final occurrence in occurrences)
          BusyInterval(id: occurrence.eventId, range: occurrence.range),
      ],
      protectedIntervals: protectedTimes.expand(
        rules: rules,
        startUtc: startUtc,
        endUtc: endUtc,
        timeZoneId: timeZoneId,
      ),
      lockedBlocks: [
        for (final block in confirmed?.blocks ?? const <PlannedBlock>[])
          if (block.locked && schedulableIds.contains(block.taskId)) block,
      ],
      rules: rules,
      preferences: const PreferenceProfile(),
      inputHash: '',
    );

    return withCurrentInputHash(problem, snapshots);
  }

  Future<PlanningRules> _windowRules(DateTime startLocalDate) async {
    final startRules = (await settings.resolveForDate(startLocalDate)).rules;
    final weekendDate = _nextWeekend(startLocalDate);
    final weekendRules = (await settings.resolveForDate(weekendDate)).rules;

    // resolveForDate 会按当天 DayKind 过滤精力区间与保护时间，因此分别解析
    // 窗口首日与一个周末日，再取并集，让引擎能按当天类型自行筛选。
    return startRules.copyWith(
      energyWindows: _mergeDistinct(
        startRules.energyWindows,
        weekendRules.energyWindows,
        (window) =>
            '${window.dayKind.name}|${window.range.startMinute}|'
            '${window.range.endMinute}|${window.level.name}',
      ),
      protectedTimes: _mergeDistinct(
        startRules.protectedTimes,
        weekendRules.protectedTimes,
        (item) =>
            '${item.dayKind.name}|${item.kind.name}|'
            '${item.range.startMinute}|${item.range.endMinute}',
      ),
    );
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _nextWeekend(DateTime localDate) {
  if (localDate.weekday == DateTime.saturday ||
      localDate.weekday == DateTime.sunday) {
    return localDate;
  }
  return localDate.add(
    Duration(days: (DateTime.saturday - localDate.weekday + 7) % 7),
  );
}

List<T> _mergeDistinct<T>(
  List<T> first,
  List<T> second,
  String Function(T item) key,
) {
  final seen = <String>{};
  final merged = <T>[];
  for (final item in [...first, ...second]) {
    if (seen.add(key(item))) merged.add(item);
  }
  return merged;
}
