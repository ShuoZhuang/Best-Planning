import 'dart:convert';

import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

final class NotificationSyncResult {
  const NotificationSyncResult({
    required this.scheduledCount,
    required this.cancelledCount,
    required this.capability,
  });

  final int scheduledCount;
  final int cancelledCount;
  final NotificationCapability capability;
}

final class NotificationService {
  NotificationService({
    required this.plans,
    required this.settings,
    required this.notifications,
    required this.clock,
    required this.zones,
    this.timeZoneId = 'Asia/Shanghai',
    this.calendar,
    this.tasks,
    this.pendingConflicts,
  });

  static const _managedPrefix = 'planner.';
  static const _window = Duration(days: 7);

  final PlanRepository plans;
  final SettingsService settings;
  final NotificationPort notifications;
  final Clock clock;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  /// 固定日程来源，用于"固定日程即将开始"通知（FR-NOTIFY-01）。
  /// 为空时跳过该类通知，而不是伪造一条。
  final CalendarRepository? calendar;

  /// 开放任务来源，用于"截止临近"通知（FR-NOTIFY-01）。
  final TaskRepository? tasks;

  /// 当前待处理冲突的来源，用于"冲突待处理"通知（FR-NOTIFY-01）。
  ///
  /// 冲突不属于持久事实，而是每次排程的产物，因此由调用方提供读取方式。
  final Future<List<PlanningConflict>> Function()? pendingConflicts;

  Future<NotificationSyncResult> syncNextSevenDays() async {
    final capability = await notifications.capability();
    final now = clock.nowUtc();
    final horizon = now.add(_window);
    final localNow = zones.toLocal(now, timeZoneId);
    final resolved = await settings.resolveForDate(
      DateTime(localNow.year, localNow.month, localNow.day),
    );
    final preferences = resolved.notifications;
    final plan = await plans.current();
    final desired = <String, NotificationRequest>{};

    if (capability.canSchedule &&
        preferences.taskStartEnabled &&
        plan != null) {
      for (final block in plan.blocks) {
        if (!block.startUtc.isAfter(now) || block.startUtc.isAfter(horizon)) {
          continue;
        }
        var scheduledAt = block.startUtc.subtract(
          Duration(minutes: preferences.taskStartLeadMinutes),
        );
        scheduledAt = _clampToFuture(scheduledAt, now);
        scheduledAt = _delayPastQuietHours(scheduledAt, preferences.quietHours);
        if (scheduledAt.isAfter(horizon)) continue;

        final id =
            '$_managedPrefix'
            'task_start.${block.id}';
        desired[id] = NotificationRequest(
          id: id,
          scheduledAtUtc: scheduledAt,
          title: '日程提醒',
          body: '有一项安排即将开始',
          payload: jsonEncode({
            'schema': 1,
            'notificationId': id,
            'kind': 'taskStart',
            'entityId': block.taskId,
            'route': '/tasks/${block.taskId}',
          }),
        );
      }
    }

    if (capability.canSchedule && preferences.calendarStartEnabled) {
      final source = calendar;
      if (source != null) {
        for (final occurrence in await source.occurrencesBetween(now, horizon)) {
          // 已经开始的事件不再提醒"即将开始"。
          if (!occurrence.range.startUtc.isAfter(now)) continue;
          var scheduledAt = occurrence.range.startUtc.subtract(
            Duration(minutes: preferences.calendarStartLeadMinutes),
          );
          scheduledAt = _clampToFuture(scheduledAt, now);
          scheduledAt = _delayPastQuietHours(
            scheduledAt,
            preferences.quietHours,
          );
          if (scheduledAt.isAfter(horizon)) continue;
          final id = '$_managedPrefix' 'calendar_start.${occurrence.eventId}';
          desired[id] = NotificationRequest(
            id: id,
            scheduledAtUtc: scheduledAt,
            title: '日程提醒',
            body: '有一项固定日程即将开始',
            payload: jsonEncode({
              'schema': 1,
              'notificationId': id,
              'kind': 'calendarStart',
              'entityId': occurrence.eventId,
              'route': '/calendar',
            }),
          );
        }
      }
    }

    if (capability.canSchedule && preferences.deadlineEnabled) {
      final source = tasks;
      if (source != null) {
        for (final task in await source.watchOpenTasks().first) {
          final due = task.dueAtUtc;
          if (due == null) continue;
          // 已经超过截止时间的任务不再提醒"临近截止"。
          if (!due.isAfter(now)) continue;
          var scheduledAt = due.subtract(
            Duration(minutes: preferences.deadlineLeadMinutes),
          );
          scheduledAt = _clampToFuture(scheduledAt, now);
          if (scheduledAt.isAfter(horizon)) continue;
          scheduledAt = _delayPastQuietHours(
            scheduledAt,
            preferences.quietHours,
          );
          if (scheduledAt.isAfter(horizon)) continue;
          final id = '$_managedPrefix' 'deadline.${task.id}';
          desired[id] = NotificationRequest(
            id: id,
            scheduledAtUtc: scheduledAt,
            title: '截止提醒',
            body: '有任务临近截止时间',
            payload: jsonEncode({
              'schema': 1,
              'notificationId': id,
              'kind': 'deadline',
              'entityId': task.id,
              'route': '/tasks/${task.id}',
            }),
          );
        }
      }
    }

    if (capability.canSchedule && preferences.conflictEnabled) {
      final source = pendingConflicts;
      if (source != null) {
        final conflicts = await source();
        if (conflicts.isNotEmpty) {
          final scheduledAt = _delayPastQuietHours(
            now.add(Duration(minutes: preferences.conflictLeadMinutes)),
            preferences.quietHours,
          );
          if (!scheduledAt.isAfter(horizon)) {
            final id = '$_managedPrefix' 'conflict.pending';
            desired[id] = NotificationRequest(
              id: id,
              scheduledAtUtc: scheduledAt,
              title: '有冲突待处理',
              body: '当前计划中有 ${conflicts.length} 项冲突需要确认',
              payload: jsonEncode({
                'schema': 1,
                'notificationId': id,
                'kind': 'conflict',
                'entityId': conflicts.first.taskId ?? '',
                'route': '/calendar',
              }),
            );
          }
        }
      }
    }

    var cancelledCount = 0;
    final pending = await notifications.pendingNotifications();
    for (final item in pending) {
      if (item.id.startsWith(_managedPrefix) && !desired.containsKey(item.id)) {
        await notifications.cancel(item.id);
        cancelledCount++;
      }
    }
    for (final request in desired.values) {
      await notifications.scheduleOneShot(request);
    }

    return NotificationSyncResult(
      scheduledCount: desired.length,
      cancelledCount: cancelledCount,
      capability: capability,
    );
  }

  /// 提醒时刻若已过去，改为"尽快提醒"，而不是静默丢弃。
  ///
  /// 提前时间可能已经过去：默认的截止提前时间是 24 小时，因此一个 20 小时后到期
  /// 的任务，其提醒时刻落在过去；程序一段时间未运行也会造成同样情况。此时直接跳过
  /// 会让用户完全收不到提醒，与 FR-NOTIFY-01 相悖。
  ///
  /// 加一分钟是为了让时刻确实落在未来——不接受过去时刻的调度器会拒收。
  DateTime _clampToFuture(DateTime scheduledAtUtc, DateTime nowUtc) =>
      scheduledAtUtc.isBefore(nowUtc)
      ? nowUtc.add(const Duration(minutes: 1))
      : scheduledAtUtc;

  DateTime _delayPastQuietHours(
    DateTime instantUtc,
    LocalTimeRange quietHours,
  ) {
    final local = zones.toLocal(instantUtc, timeZoneId);
    final minute = local.hour * 60 + local.minute;
    final isQuiet = quietHours.crossesMidnight
        ? minute >= quietHours.startMinute || minute < quietHours.endMinute
        : minute >= quietHours.startMinute && minute < quietHours.endMinute;
    if (!isQuiet) return instantUtc;

    var dayOffset = 0;
    if (quietHours.crossesMidnight && minute >= quietHours.startMinute) {
      dayOffset = 1;
    }
    var endMinute = quietHours.endMinute;
    if (endMinute == LocalTimeRange.minutesPerDay) {
      dayOffset++;
      endMinute = 0;
    }
    final endDate = DateTime(local.year, local.month, local.day + dayOffset);
    return zones.localDateTimeToUtc(endDate, endMinute, timeZoneId);
  }
}
