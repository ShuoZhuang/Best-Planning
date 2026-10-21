import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/application/execution/execution_notification_settings.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';

/// 复用既有通知设置与免打扰规则（规范 §8、§13、§21.2）。
///
/// **不新增通知类别**：执行提醒属于"任务开始"类别；关闭总开关或该类别时，稍后提醒入口
/// 明确不可用，而不是假装已设置。
final class SettingsExecutionNotifications
    implements ExecutionNotificationSettingsPort {
  SettingsExecutionNotifications({
    required this.settings,
    required this.zones,
    required this.timeZoneId,
  });

  final SettingsService settings;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  @override
  Future<ExecutionNotificationSettingsSnapshot> snapshot({
    required DateTime targetAtUtc,
  }) async {
    final preferences = await settings.loadNotificationPreferences();
    final local = zones.toLocal(targetAtUtc, timeZoneId);
    final minute = local.hour * 60 + local.minute;
    final quiet = preferences.quietHours;
    final suppressed = quiet.crossesMidnight
        ? minute >= quiet.startMinute || minute < quiet.endMinute
        : minute >= quiet.startMinute && minute < quiet.endMinute;
    final hash = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'enabled': preferences.enabled,
              'taskStartEnabled': preferences.taskStartEnabled,
              'quietStart': quiet.startMinute,
              'quietEnd': quiet.endMinute,
            }),
          ),
        )
        .toString();
    return ExecutionNotificationSettingsSnapshot(
      enabled: preferences.enabled,
      taskStartEnabled: preferences.taskStartEnabled,
      suppressedByQuietHours: suppressed,
      settingsHash: hash,
    );
  }
}
