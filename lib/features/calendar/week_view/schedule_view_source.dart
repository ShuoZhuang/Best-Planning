import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';

/// 生产用的今日页与周视图数据源：把固定日程、保护时间和已确认计划块读成
/// `ScheduleViewItem`。
///
/// 此前这两个页面注入的是 `EmptyScheduleViewSource`，恒返回空列表，因此今日页
/// 与周视图在真实运行中永远不显示任何安排。
///
/// 已知限制：
/// - 只在订阅时读取一次。任务流是实时的，但固定日程与已确认计划只提供 `Future`
///   接口，因此数据变化后需要重新订阅才能看到；要做到实时刷新需要仓储层提供
///   变更流。
/// - `ScheduleItemKind.life` 尚无法产生：`PlannerTask` 没有生活事项标记（见 R1、R2
///   关于标签与项目缺失的登记），生活配额目前只在统计服务里按领域名推断。
final class RepositoryScheduleViewSource implements ScheduleViewSource {
  RepositoryScheduleViewSource({
    required this.tasks,
    required this.calendar,
    required this.plans,
    required this.rules,
    required this.zones,
    required this.timeZoneId,
  }) : protectedTimes = ProtectedTimeExpander(zones);

  final TaskRepository tasks;
  final CalendarRepository calendar;
  final PlanRepository plans;
  final PlanningRuleResolver rules;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final ProtectedTimeExpander protectedTimes;

  @override
  Stream<List<ScheduleViewItem>> watch(
    DateTime startUtc,
    DateTime endUtc,
  ) async* {
    yield await _load(startUtc, endUtc);
  }

  Future<List<ScheduleViewItem>> _load(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    final items = <ScheduleViewItem>[];

    for (final occurrence in await calendar.occurrencesBetween(
      startUtc,
      endUtc,
    )) {
      items.add(
        ScheduleViewItem(
          id: 'fixed:${occurrence.eventId}',
          title: occurrence.title,
          kind: ScheduleItemKind.fixed,
          range: occurrence.range,
        ),
      );
    }

    final localDate = _dateOnly(zones.toLocal(startUtc, timeZoneId));
    final resolved = await rules.resolveForWindow(localDate);
    for (final interval in protectedTimes.expand(
      rules: resolved,
      startUtc: startUtc,
      endUtc: endUtc,
      timeZoneId: timeZoneId,
    )) {
      items.add(
        ScheduleViewItem(
          id: interval.id,
          title: _protectedLabel(interval.id),
          kind: ScheduleItemKind.protectedTime,
          range: interval.range,
        ),
      );
    }

    final confirmed = await plans.current();
    if (confirmed != null) {
      final titles = {
        for (final task in await tasks.watchOpenTasks().first)
          task.id: task.title,
      };
      for (final block in confirmed.blocks) {
        items.add(
          ScheduleViewItem(
            id: 'block:${block.id}',
            title: titles[block.taskId] ?? '已安排任务',
            kind: ScheduleItemKind.task,
            range: block.range,
            explanation: block.explanationCode,
          ),
        );
      }
    }

    items.sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    return List.unmodifiable(items);
  }
}

/// 保护时间区间的 id 形如 `protected:<kind>:<yyyy-MM-dd>:<minute>`。
String _protectedLabel(String intervalId) {
  final parts = intervalId.split(':');
  if (parts.length < 2) return '保护时间';
  return switch (parts[1]) {
    'lunch' => '午餐时间',
    'dinner' => '晚餐时间',
    'fixedRest' => '固定休息',
    _ => '保护时间',
  };
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
