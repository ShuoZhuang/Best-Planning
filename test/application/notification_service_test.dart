import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/notification_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  late DateTime now;
  late _MemoryPlanRepository plans;
  late MemorySettingsRepository settingsRepository;
  late SettingsService settings;
  late _RecordingNotificationPort notifications;

  setUp(() {
    now = DateTime.utc(2026, 10, 2, 8);
    plans = _MemoryPlanRepository();
    settingsRepository = MemorySettingsRepository();
    settings = SettingsService(repository: settingsRepository);
    notifications = _RecordingNotificationPort();
  });

  NotificationService service({String timeZoneId = 'UTC'}) =>
      NotificationService(
        plans: plans,
        settings: settings,
        notifications: notifications,
        clock: _FixedClock(now),
        zones: TimeZoneDatabase(),
        timeZoneId: timeZoneId,
      );

  test('只安排当前时刻之后七天内的一次性提醒', () async {
    plans.plan = _plan([
      _block('past', now.subtract(const Duration(minutes: 10))),
      _block('inside', now.add(const Duration(hours: 2))),
      _block('outside', now.add(const Duration(days: 8))),
    ]);
    await settings.saveNotificationPreferences(
      NotificationPreferences(taskStartLeadMinutes: 15),
    );

    await service().syncNextSevenDays();

    expect(notifications.scheduled, hasLength(1));
    expect(notifications.scheduled.single.id, 'planner.task_start.inside');
    expect(
      notifications.scheduled.single.scheduledAtUtc,
      now.add(const Duration(hours: 1, minutes: 45)),
    );
    expect(notifications.scheduled.single.repeats, isFalse);
  });

  test('普通任务提醒落入免打扰时段时推迟到结束时刻', () async {
    plans.plan = _plan([
      _block('late-study', DateTime.utc(2026, 10, 2, 16, 45)),
    ]);
    await settings.saveNotificationPreferences(
      NotificationPreferences(
        taskStartLeadMinutes: 15,
        quietHours: LocalTimeRange(
          startMinute: 23 * 60 + 30,
          endMinute: 7 * 60 + 30,
        ),
      ),
    );

    await service(timeZoneId: 'Asia/Shanghai').syncNextSevenDays();

    expect(
      notifications.scheduled.single.scheduledAtUtc,
      DateTime.utc(2026, 10, 2, 23, 30),
    );
  });

  test('payload 仅含导航标识，不包含任务标题或备注', () async {
    plans.plan = _plan([
      _block('private-task', now.add(const Duration(hours: 2))),
    ]);

    await service().syncNextSevenDays();

    final request = notifications.scheduled.single;
    final payload = jsonDecode(request.payload) as Map<String, Object?>;
    expect(payload.keys, {
      'schema',
      'notificationId',
      'kind',
      'entityId',
      'route',
    });
    expect(request.payload, isNot(contains('线性代数作业')));
    expect(request.payload, isNot(contains('私人备注')));
    expect(request.title, '日程提醒');
    expect(request.body, '有一项安排即将开始');
  });

  test('计划变化时取消不再需要的旧提醒', () async {
    notifications.pending.add(
      const PendingNotification(
        id: 'planner.task_start.removed',
        payload: '{"kind":"taskStart"}',
      ),
    );
    plans.plan = _plan([_block('current', now.add(const Duration(hours: 2)))]);

    await service().syncNextSevenDays();

    expect(notifications.cancelled, ['planner.task_start.removed']);
    expect(notifications.scheduled.single.id, 'planner.task_start.current');
  });

  test('同步结果包含 Windows 无包身份时的取消能力诊断', () async {
    notifications.currentCapability = const NotificationCapability(
      canSchedule: true,
      canCancelReliably: false,
      diagnostic: '未使用 MSIX 包身份，系统可能无法取消已显示的通知。',
    );

    final result = await service().syncNextSevenDays();

    expect(result.capability.canSchedule, isTrue);
    expect(result.capability.canCancelReliably, isFalse);
    expect(result.capability.diagnostic, contains('MSIX'));
  });
}

PlannedBlock _block(String id, DateTime startUtc) => PlannedBlock(
  id: id,
  taskId: id,
  range: TimeRange(
    startUtc: startUtc,
    endUtc: startUtc.add(const Duration(hours: 1)),
  ),
);

ConfirmedPlan _plan(List<PlannedBlock> blocks) => ConfirmedPlan(
  id: 'plan',
  inputHash: 'hash',
  algorithmVersion: '1',
  blocks: blocks,
);

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

final class _MemoryPlanRepository implements PlanRepository {
  ConfirmedPlan? plan;

  @override
  Future<ConfirmedPlan?> current() async => plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) => throw UnimplementedError();
}

final class _RecordingNotificationPort implements NotificationPort {
  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}
  final List<NotificationRequest> scheduled = [];
  final List<String> cancelled = [];
  final List<PendingNotification> pending = [];
  NotificationCapability currentCapability =
      const NotificationCapability.available();

  @override
  Future<NotificationCapability> capability() async => currentCapability;

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
    pending.removeWhere((item) => item.id == id);
  }

  @override
  Future<List<PendingNotification>> pendingNotifications() async =>
      List.of(pending);

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {
    scheduled.add(request);
  }
}
