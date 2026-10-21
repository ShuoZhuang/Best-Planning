import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_reminder_coordinator.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';

import 'execution_test_support.dart';

final class _FakeNotificationPort implements NotificationPort {
  final List<NotificationRequest> scheduled = [];
  final Map<String, String> pending = {};
  bool canSchedule = true;
  bool failSchedule = false;
  int cancelCalls = 0;

  @override
  Future<NotificationCapability> capability() async => canSchedule
      ? const NotificationCapability.available()
      : const NotificationCapability(
          canSchedule: false,
          canCancelReliably: true,
          diagnostic: 'test',
        );

  @override
  Future<List<PendingNotification>> pendingNotifications() async => [
    for (final entry in pending.entries)
      PendingNotification(id: entry.key, payload: entry.value),
  ];

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {
    if (failSchedule) throw StateError('schedule failed');
    scheduled.add(request);
    pending[request.id] = request.payload;
  }

  @override
  Future<void> cancel(String id) async {
    cancelCalls++;
    pending.remove(id);
  }

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}

  @override
  Future<NotificationPayload?> launchPayload() async => null;
}

void main() {
  late ExecutionTestHarness harness;
  late _FakeNotificationPort notifications;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    notifications = _FakeNotificationPort();
  });

  tearDown(() => harness.close());

  Future<void> seedReminder({
    String occurrenceId = 'occurrence-1',
    required DateTime targetAtUtc,
    ExecutionReminderState state = ExecutionReminderState.pending,
  }) async {
    final runtime = await harness.repository.ensureRuntimeState();
    await harness.repository.insertReminder(
      ExecutionReminderIntent(
        dataEpoch: runtime.dataEpoch,
        occurrenceId: occurrenceId,
        revision: 1,
        targetAtUtc: targetAtUtc,
        notificationId: 'planner.task_start.exec.$occurrenceId.1',
        state: state,
        claimedAtUtc: null,
        scheduledAtUtc: null,
        dispatchResult: null,
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
  }

  test('pending 意图先 claim 再调度一次，重复对账不重发', () async {
    await harness.seedOccurrence();
    await seedReminder(
      targetAtUtc: harness.clock.nowUtc().add(const Duration(minutes: 10)),
    );
    final coordinator = ExecutionReminderCoordinator(
      repository: harness.repository,
      notifications: notifications,
      clock: harness.clock,
    );

    final first = await coordinator.reconcile();
    expect(first.scheduledCount, 1);
    expect(notifications.scheduled, hasLength(1));
    expect(
      notifications.scheduled.single.id,
      'planner.task_start.exec.occurrence-1.1',
    );
    expect(notifications.scheduled.single.title, '有一项安排待处理');
    expect(
      notifications.scheduled.single.payload,
      contains('"route":"/today"'),
    );
    final current = await harness.repository.currentReminder('occurrence-1');
    expect(current!.state, ExecutionReminderState.scheduled);

    final second = await coordinator.reconcile();
    expect(second.scheduledCount, 0);
    expect(notifications.scheduled, hasLength(1));
  });

  test('目标已过期只标记 expired 并撤销待发项', () async {
    await harness.seedOccurrence();
    await seedReminder(
      targetAtUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 1)),
    );
    notifications.pending['planner.task_start.exec.occurrence-1.1'] = '{}';
    final coordinator = ExecutionReminderCoordinator(
      repository: harness.repository,
      notifications: notifications,
      clock: harness.clock,
    );

    final result = await coordinator.reconcile();
    expect(result.expiredCount, 1);
    expect(result.cancelledCount, 1);
    expect(notifications.scheduled, isEmpty);
    final current = await harness.repository.currentReminder('occurrence-1');
    expect(current!.state, ExecutionReminderState.expired);
  });

  test('系统能力不可用时记为 unknown，不谎报已排入', () async {
    await harness.seedOccurrence();
    await seedReminder(
      targetAtUtc: harness.clock.nowUtc().add(const Duration(minutes: 10)),
    );
    notifications.canSchedule = false;
    final coordinator = ExecutionReminderCoordinator(
      repository: harness.repository,
      notifications: notifications,
      clock: harness.clock,
    );

    await coordinator.reconcile();
    expect(notifications.scheduled, isEmpty);
    final current = await harness.repository.currentReminder('occurrence-1');
    expect(current!.state, ExecutionReminderState.unknown);
    expect(current.dispatchResult, 'capabilityUnavailable');
  });

  test('关闭通知后已存在的意图被取消，不发送也不再排入', () async {
    await harness.seedOccurrence();
    await seedReminder(
      targetAtUtc: harness.clock.nowUtc().add(const Duration(minutes: 10)),
    );
    final coordinator = ExecutionReminderCoordinator(
      repository: harness.repository,
      notifications: notifications,
      clock: harness.clock,
      settings: const AlwaysEnabledNotifications(enabled: false),
    );

    await coordinator.reconcile();
    expect(notifications.scheduled, isEmpty);
    final current = await harness.repository.currentReminder('occurrence-1');
    expect(current!.state, ExecutionReminderState.cancelled);
    expect(current.dispatchResult, 'notificationsDisabled');
  });

  test('调度后结果未知时记为 unknown，不在下一次对账重发', () async {
    await harness.seedOccurrence();
    await seedReminder(
      targetAtUtc: harness.clock.nowUtc().add(const Duration(minutes: 10)),
    );
    notifications.failSchedule = true;
    final coordinator = ExecutionReminderCoordinator(
      repository: harness.repository,
      notifications: notifications,
      clock: harness.clock,
    );

    await coordinator.reconcile();
    final afterFailure = await harness.repository.currentReminder(
      'occurrence-1',
    );
    expect(afterFailure!.state, ExecutionReminderState.unknown);
    expect(afterFailure.dispatchResult, startsWith('scheduleFailed'));

    notifications.failSchedule = false;
    final second = await coordinator.reconcile();
    expect(second.scheduledCount, 0);
    expect(notifications.scheduled, isEmpty);
  });

  test('恢复备份后旧 dataEpoch 的提醒被作废，不再按旧实例补发', () async {
    await harness.seedOccurrence();
    await seedReminder(
      targetAtUtc: harness.clock.nowUtc().add(const Duration(minutes: 10)),
    );
    final runtime = await harness.repository.ensureRuntimeState();
    await harness.repository.writeRuntimeState(
      runtime.copyWith(
        dataEpoch: 'restored-epoch',
        revision: runtime.revision + 1,
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    final coordinator = ExecutionReminderCoordinator(
      repository: harness.repository,
      notifications: notifications,
      clock: harness.clock,
    );
    await coordinator.reconcile();
    final current = await harness.repository.currentReminder('occurrence-1');
    expect(current!.state, ExecutionReminderState.cancelled);
    expect(current.dispatchResult, 'staleDataEpoch');
    expect(notifications.scheduled, isEmpty);
  });
}
