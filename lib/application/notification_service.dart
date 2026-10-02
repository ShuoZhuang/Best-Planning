import 'dart:convert';

import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';

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
  });

  static const _managedPrefix = 'planner.';
  static const _window = Duration(days: 7);

  final PlanRepository plans;
  final SettingsService settings;
  final NotificationPort notifications;
  final Clock clock;
  final TimeZoneDatabase zones;
  final String timeZoneId;

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
        if (!scheduledAt.isAfter(now)) continue;
        scheduledAt = _delayPastQuietHours(scheduledAt, preferences.quietHours);
        if (!scheduledAt.isAfter(now) || scheduledAt.isAfter(horizon)) continue;

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
