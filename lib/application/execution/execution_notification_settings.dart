/// 执行提醒所需的通知设置快照（规范 §8、§13、§21）。
///
/// 生产适配器读 `SettingsService.loadNotificationPreferences()`，并把免打扰判定放在
/// 时区里做；本接口只暴露已经解释好的结果，避免执行服务再实现一套免打扰规则。
final class ExecutionNotificationSettingsSnapshot {
  const ExecutionNotificationSettingsSnapshot({
    required this.enabled,
    required this.taskStartEnabled,
    required this.suppressedByQuietHours,
    required this.settingsHash,
  });

  final bool enabled;
  final bool taskStartEnabled;
  final bool suppressedByQuietHours;

  /// 通知总开关/类别/免打扰规则的确定序列化哈希。
  final String settingsHash;

  bool get canDeliver => enabled && taskStartEnabled;
}

abstract interface class ExecutionNotificationSettingsPort {
  /// [targetAtUtc] 用来判定目标时刻是否落在免打扰里。
  Future<ExecutionNotificationSettingsSnapshot> snapshot({
    required DateTime targetAtUtc,
  });
}

/// 没有通知装配时的保守实现：明确回答"不能发送"，而不是假装已设置。
final class DisabledExecutionNotifications
    implements ExecutionNotificationSettingsPort {
  const DisabledExecutionNotifications();

  @override
  Future<ExecutionNotificationSettingsSnapshot> snapshot({
    required DateTime targetAtUtc,
  }) async => const ExecutionNotificationSettingsSnapshot(
    enabled: false,
    taskStartEnabled: false,
    suppressedByQuietHours: false,
    settingsHash: 'disabled',
  );
}
