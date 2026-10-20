import 'package:personal_planner/application/execution/execution_notification_settings.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart' as d;
import 'package:personal_planner/domain/repositories/notification_port.dart';

/// 执行提醒的对账（规范 §13、§21）。
///
/// **不承诺外部通知恰好一次**：数据库提交和 Windows 调度不在同一事务里。第一轮采用稳定
/// 通知 ID 与保守防重——派发前持久化 claim，调度返回后保存结果；调度后、结果提交前崩溃时
/// 恢复只查询，不自动重发。应用内卡片始终可见，不依赖系统通知。
final class ExecutionReminderCoordinator {
  ExecutionReminderCoordinator({
    required this.repository,
    required this.notifications,
    required this.clock,
    this.settings,
  });

  final DriftExecutionRepository repository;
  final NotificationPort notifications;
  final Clock clock;

  /// 通知设置快照；为空时不做类别/免打扰复核（测试与最小装配）。
  final ExecutionNotificationSettingsPort? settings;

  /// 对账全部执行提醒。返回 (scheduled, cancelled, suppressed, expired) 计数。
  Future<ExecutionReminderReconcileResult> reconcile() async {
    final capability = await notifications.capability();
    final pendingSystem = {
      for (final item in await notifications.pendingNotifications()) item.id,
    };
    final now = clock.nowUtc();
    final runtime = await repository.ensureRuntimeState();
    var scheduled = 0;
    var cancelled = 0;
    var suppressed = 0;
    var expired = 0;

    for (final intent in await repository.allReminders()) {
      if (!intent.isActive) {
        if (intent.state == d.ExecutionReminderState.cancelled ||
            intent.state == d.ExecutionReminderState.handled) {
          if (pendingSystem.contains(intent.notificationId)) {
            await notifications.cancel(intent.notificationId);
            cancelled++;
          }
        }
        continue;
      }
      if (intent.state == d.ExecutionReminderState.suppressed) {
        suppressed++;
        continue;
      }
      // 恢复备份/清除后 `dataEpoch` 变化：旧外部通知一律作废，绝不按旧实例补记。
      if (intent.dataEpoch != runtime.dataEpoch) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.cancelled,
          dispatchResult: 'staleDataEpoch',
        );
        if (pendingSystem.contains(intent.notificationId)) {
          await notifications.cancel(intent.notificationId);
          cancelled++;
        }
        continue;
      }
      final settingsSnapshot = settings == null
          ? null
          : await settings!.snapshot(targetAtUtc: intent.targetAtUtc);
      if (settingsSnapshot != null && !settingsSnapshot.canDeliver) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.cancelled,
          dispatchResult: 'notificationsDisabled',
        );
        if (pendingSystem.contains(intent.notificationId)) {
          await notifications.cancel(intent.notificationId);
          cancelled++;
        }
        continue;
      }
      if (settingsSnapshot?.suppressedByQuietHours == true &&
          !intent.targetAtUtc.isBefore(now)) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.suppressed,
          dispatchResult: 'suppressedByQuietHours',
        );
        if (pendingSystem.contains(intent.notificationId)) {
          await notifications.cancel(intent.notificationId);
          cancelled++;
        }
        suppressed++;
        continue;
      }
      if (intent.targetAtUtc.isBefore(now)) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.expired,
          dispatchResult: 'expiredBeforeDispatch',
        );
        if (pendingSystem.contains(intent.notificationId)) {
          await notifications.cancel(intent.notificationId);
          cancelled++;
        }
        expired++;
        continue;
      }

      if (intent.state == d.ExecutionReminderState.scheduled ||
          intent.state == d.ExecutionReminderState.unknown) {
        // 已经派发或派发状态未知：不自动重发，只保留应用内状态。
        continue;
      }

      // 派发前先持久化 claim（规范 §21.1）。
      await repository.updateReminderState(
        occurrenceId: intent.occurrenceId,
        revision: intent.revision,
        dataEpoch: intent.dataEpoch,
        state: d.ExecutionReminderState.claimed,
        claimedAtUtc: now,
      );
      if (!capability.canSchedule) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.unknown,
          dispatchResult: 'capabilityUnavailable',
        );
        continue;
      }
      if (pendingSystem.contains(intent.notificationId)) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.scheduled,
          scheduledAtUtc: now,
          dispatchResult: 'alreadyPending',
        );
        continue;
      }
      try {
        await notifications.scheduleOneShot(
          NotificationRequest(
            id: intent.notificationId,
            scheduledAtUtc: intent.targetAtUtc,
            // 锁屏不额外暴露任务标题（规范 §21.3）。
            title: '有一项安排待处理',
            body: '点击查看今日安排',
            payload: NotificationPayload(
              notificationId: intent.notificationId,
              kind: NotificationKind.taskStart,
              entityId: intent.occurrenceId,
              route: '/today',
            ).encode(),
          ),
        );
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.scheduled,
          scheduledAtUtc: now,
          dispatchResult: 'queued',
        );
        scheduled++;
      } on Object catch (error) {
        await repository.updateReminderState(
          occurrenceId: intent.occurrenceId,
          revision: intent.revision,
          dataEpoch: intent.dataEpoch,
          state: d.ExecutionReminderState.unknown,
          dispatchResult: 'scheduleFailed:${error.runtimeType}',
        );
      }
    }
    return ExecutionReminderReconcileResult(
      scheduledCount: scheduled,
      cancelledCount: cancelled,
      suppressedCount: suppressed,
      expiredCount: expired,
      capability: capability,
    );
  }
}

final class ExecutionReminderReconcileResult {
  const ExecutionReminderReconcileResult({
    required this.scheduledCount,
    required this.cancelledCount,
    required this.suppressedCount,
    required this.expiredCount,
    required this.capability,
  });

  final int scheduledCount;
  final int cancelledCount;
  final int suppressedCount;
  final int expiredCount;
  final NotificationCapability capability;
}
