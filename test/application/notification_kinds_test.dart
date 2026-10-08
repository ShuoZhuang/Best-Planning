import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/notification_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// FR-NOTIFY-01 要求四类通知：任务即将开始、固定日程即将开始、截止临近、冲突待处理。
/// 此前只实现了"任务即将开始"，而设置页对另外三类提供了开关与提前时间。
void main() {
  final now = DateTime.utc(2026, 10, 5, 2); // 东八区 10:00，非免打扰时段。
  const zoneId = 'Asia/Shanghai';

  ConfirmedPlan planWith(DateTime startUtc) => ConfirmedPlan(
    id: 'plan-1',
    inputHash: 'hash',
    algorithmVersion: '8',
    blocks: [
      PlannedBlock(
        id: 'block-1',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: startUtc,
          endUtc: startUtc.add(const Duration(hours: 1)),
        ),
      ),
    ],
  );

  PlannerTask task(String id, DateTime? due) => PlannerTask(
    id: id,
    title: id,
    priority: TaskPriority.high,
    estimatedMinutes: 60,
    remainingMinutes: 60,
    dueAtUtc: due,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 1),
  );

  test('四类通知都会被安排', () async {
    final port = _RecordingPort();
    final service = NotificationService(
      plans: _FakePlans(planWith(now.add(const Duration(hours: 1)))),
      settings: SettingsService(repository: MemorySettingsRepository()),
      notifications: port,
      clock: _FixedClock(now),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
      calendar: _FakeCalendar([
        CalendarOccurrence(
          eventId: 'class-1',
          title: '课程',
          range: TimeRange(
            startUtc: now.add(const Duration(hours: 3)),
            endUtc: now.add(const Duration(hours: 4)),
          ),
          locked: true,
        ),
      ]),
      tasks: _FakeTasks([
        task('due-soon', now.add(const Duration(hours: 20))),
        task('no-due', null),
        task('due-far', now.add(const Duration(days: 30))),
      ]),
      pendingConflicts: () async => [
        PlanningConflict(
          code: ConflictCode.insufficientCapacity,
          taskId: 'task-1',
        ),
      ],
    );

    final result = await service.syncNextSevenDays();

    final ids = port.scheduled.map((request) => request.id).toList()..sort();
    expect(ids, [
      'planner.calendar_start.class-1',
      'planner.conflict.pending',
      'planner.deadline.due-soon',
      'planner.task_start.block-1',
    ]);
    expect(result.scheduledCount, 4);
    expect(
      port.scheduled.map((request) => request.payload).join(),
      allOf(
        contains('calendarStart'),
        contains('deadline'),
        contains('conflict'),
      ),
    );
  });

  // C12（2026-10-04 产品侧确认按**文案**为准）：冲突提醒**在免打扰期间也要保留**，不延后。
  //
  // 设置页对用户写的是「普通通知在免打扰期间延后；**冲突待处理提醒仍会保留**」，而代码此前对它
  // **同样**调了 `_delayPastQuietHours`——文案承诺了、代码没兑现。这条用例把"文案与代码一致"
  // 钉住，并且**同时**守住"其余三类仍然延后"（免得为了改一类而把免打扰整体废掉）。
  test('冲突提醒在免打扰期间不延后，其余三类仍然延后', () async {
    // 东八区 00:00，正在默认免打扰时段（23:30–07:30）内。
    final inQuietHours = DateTime.utc(2026, 10, 5, 16);
    final port = _RecordingPort();
    final service = NotificationService(
      plans: _FakePlans(planWith(inQuietHours.add(const Duration(hours: 1)))),
      settings: SettingsService(repository: MemorySettingsRepository()),
      notifications: port,
      clock: _FixedClock(inQuietHours),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
      calendar: _FakeCalendar([
        CalendarOccurrence(
          eventId: 'class-1',
          title: '课程',
          range: TimeRange(
            startUtc: inQuietHours.add(const Duration(hours: 3)),
            endUtc: inQuietHours.add(const Duration(hours: 4)),
          ),
          locked: true,
        ),
      ]),
      tasks: _FakeTasks([
        task('due-soon', inQuietHours.add(const Duration(hours: 20))),
      ]),
      pendingConflicts: () async => [
        PlanningConflict(
          code: ConflictCode.insufficientCapacity,
          taskId: 'task-1',
        ),
      ],
    );

    await service.syncNextSevenDays();

    // 冲突提醒 = now + conflictLeadMinutes(30)，**不被推到免打扰结束**。
    final conflict = port.scheduled.firstWhere(
      (request) => request.id == 'planner.conflict.pending',
    );
    expect(
      conflict.scheduledAtUtc,
      inQuietHours.add(const Duration(minutes: 30)),
      reason: '冲突提醒在免打扰期间必须保留原时刻，否则界面上那句话就是空头承诺',
    );
    // 免打扰结束（东八区 07:30）= 前一日 23:30 UTC。
    expect(
      conflict.scheduledAtUtc,
      isNot(DateTime.utc(2026, 10, 5, 23, 30)),
      reason: '被推到 07:30 就是旧行为（代码没兑现文案）',
    );

    // 对照：任务开始提醒（提前 10 分钟）落在免打扰内，**仍然延后**到免打扰结束。
    final taskStart = port.scheduled.firstWhere(
      (request) => request.id == 'planner.task_start.block-1',
    );
    expect(
      taskStart.scheduledAtUtc,
      DateTime.utc(2026, 10, 5, 23, 30),
      reason: '普通提醒的免打扰延后必须保持不变',
    );
  });

  test('截止提醒：只提醒窗口内到期的任务，且不因提前时间已过而丢失', () async {
    final port = _RecordingPort();
    final service = NotificationService(
      plans: _FakePlans(null),
      settings: SettingsService(repository: MemorySettingsRepository()),
      notifications: port,
      clock: _FixedClock(now),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
      tasks: _FakeTasks([
        // 默认提前 24 小时 → 提醒时刻落在过去，此时必须改为尽快提醒而不是跳过。
        task('due-in-20h', now.add(const Duration(hours: 20))),
        task('due-in-30d', now.add(const Duration(days: 30))),
        task('already-overdue', now.subtract(const Duration(hours: 2))),
        task('no-due', null),
      ]),
    );

    await service.syncNextSevenDays();

    expect(port.scheduled, hasLength(1));
    final request = port.scheduled.single;
    expect(request.id, 'planner.deadline.due-in-20h');
    // 提醒时刻必须落在未来，否则不接受过去时刻的调度器会拒收。
    expect(request.scheduledAtUtc.isAfter(now), isTrue);
  });

  test('payload 只含标识与动作，不含任务内容', () async {
    final port = _RecordingPort();
    final service = NotificationService(
      plans: _FakePlans(null),
      settings: SettingsService(repository: MemorySettingsRepository()),
      notifications: port,
      clock: _FixedClock(now),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
      tasks: _FakeTasks([task('due-soon', now.add(const Duration(hours: 20)))]),
    );

    await service.syncNextSevenDays();

    for (final request in port.scheduled) {
      expect(request.payload, isNot(contains('title')));
      expect(request.payload, contains('route'));
    }
  });

  test('只取消本应用管理的过期提醒，不动其它应用的通知', () async {
    final port = _RecordingPort(
      pending: const [
        PendingNotification(id: 'planner.task_start.gone', payload: '{}'),
        PendingNotification(id: 'other.app', payload: '{}'),
      ],
    );
    final service = NotificationService(
      plans: _FakePlans(null),
      settings: SettingsService(repository: MemorySettingsRepository()),
      notifications: port,
      clock: _FixedClock(now),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
    );

    final result = await service.syncNextSevenDays();

    expect(port.cancelled, ['planner.task_start.gone']);
    expect(result.cancelledCount, 1);
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime nowUtc() => instant;
}

final class _RecordingPort implements NotificationPort {
  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}

  @override
  Future<NotificationPayload?> launchPayload() async => null;

  _RecordingPort({this.pending = const []});
  final List<PendingNotification> pending;
  final List<NotificationRequest> scheduled = [];
  final List<String> cancelled = [];

  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability.available();

  @override
  Future<List<PendingNotification>> pendingNotifications() async => pending;

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async =>
      scheduled.add(request);

  @override
  Future<void> cancel(String id) async => cancelled.add(id);
}

final class _FakePlans implements PlanRepository {
  _FakePlans(this.plan);
  final ConfirmedPlan? plan;
  @override
  Future<ConfirmedPlan?> current() async => plan;
  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

final class _FakeCalendar implements CalendarRepository {
  _FakeCalendar(this.items);
  final List<CalendarOccurrence> items;
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => items
      .where(
        (item) =>
            !item.range.endUtc.isBefore(startUtc) &&
            !item.range.startUtc.isAfter(endUtc),
      )
      .toList();
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _FakeTasks implements TaskRepository {
  _FakeTasks(this.items);
  final List<PlannerTask> items;
  @override
  Future<PlannerTask?> getById(String id) async =>
      items.where((item) => item.id == id).firstOrNull;
  @override
  Future<void> save(PlannerTask task) async {}
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(items);
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(items);
}
