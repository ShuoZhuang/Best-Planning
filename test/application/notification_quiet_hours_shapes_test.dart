// 1.8.0：免打扰（quiet hours）的**形状覆盖**。
//
// `notification_kinds_test.dart` 已钉住一条产品确认过的规则：**冲突提醒在免打扰期间
// 不延后，其余三类延后**（C12），用的是默认时段（23:30–07:30，**跨午夜**）。
//
// 本文件补的是那一条没覆盖的**形状**：`_delayPastQuietHours` 里有三处按形状分支的判断
// （是否跨午夜、落在前半段还是后半段、`endMinute == 1440` 的次日零点特例），
// 而默认时段只走其中一条路径。形状写错的表现是"提醒被推到次日"或"半夜还是响"——
// 都是用户直接感受得到的错误。
//
// **夹具的锚点是"提醒原时刻"而不是"计划块开始时刻"**：
// `_desiredNotifications` 会跳过 `startUtc <= now` 的块（已经开始的块不再提醒"即将开始"），
// 因此让"块开始 == now"会一条通知都排不出来（第一版就是这么写的，五条用例全报
// `Bad state: No element`）。现在把块放在"提醒时刻"，而"现在"取它前一天。
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
  const zoneId = 'Asia/Shanghai';

  /// 把"东八区本地某日的某时刻"写成 UTC 时刻；[dayOffset] 用于跨日。
  DateTime shanghai(int hour, int minute, {int dayOffset = 0}) =>
      TimeZoneDatabase().localDateTimeToUtc(
        DateTime(2026, 10, 5 + dayOffset),
        hour * 60 + minute,
        zoneId,
      );

  /// 问：一个原定在 [notificationTargetUtc] 的任务开始提醒会被排到什么时候。
  Future<DateTime> scheduledTaskStartAt({
    required LocalTimeRange quietHours,
    required DateTime notificationTargetUtc,
  }) async {
    final port = _RecordingPort();
    // 提前量为 0 ⇒ 提醒时刻 == 计划块开始时刻。
    final service = NotificationService(
      plans: _FixedPlans(notificationTargetUtc),
      settings: SettingsService(repository: MemorySettingsRepository()),
      notifications: port,
      clock: _FixedClock(
        notificationTargetUtc.subtract(const Duration(days: 1)),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
    );

    await service.reconcile(
      preferences: NotificationPreferences(
        taskStartEnabled: true,
        calendarStartEnabled: false,
        deadlineEnabled: false,
        conflictEnabled: false,
        recurringGoalEnabled: false,
        taskStartLeadMinutes: 0,
        quietHours: quietHours,
      ),
    );

    return port.scheduled
        .singleWhere((item) => item.id.startsWith('planner.task_start.'))
        .scheduledAtUtc;
  }

  test('跨午夜：落在**后半夜**时推到当天免打扰结束，不推到次日', () async {
    // 免打扰 23:30–07:30；提醒原定本地 02:00（落在**后半夜**）。
    final at = await scheduledTaskStartAt(
      quietHours: LocalTimeRange(startMinute: 1410, endMinute: 450),
      notificationTargetUtc: shanghai(2, 0),
    );

    expect(
      at,
      shanghai(7, 30),
      reason:
          '后半夜（00:00–07:30 之间）应当推到**当天**的结束时刻；'
          '推到次日会让用户晚一整天收到提醒',
    );
  });

  test('跨午夜：落在**前半夜**时推到次日免打扰结束', () async {
    // 提醒原定本地 23:45（落在**前半夜**）。期望次日 07:30。
    final at = await scheduledTaskStartAt(
      quietHours: LocalTimeRange(startMinute: 1410, endMinute: 450),
      notificationTargetUtc: shanghai(23, 45),
    );

    expect(
      at,
      shanghai(7, 30, dayOffset: 1),
      reason: '前半夜（23:30 之后）当天已经没有"结束时刻"了，必须推到次日',
    );
  });

  test('**不跨午夜**的午休时段：推到当天该时段结束', () async {
    // 免打扰 12:00–13:00（不跨午夜）；提醒原定本地 12:30。
    final at = await scheduledTaskStartAt(
      quietHours: LocalTimeRange(startMinute: 720, endMinute: 780),
      notificationTargetUtc: shanghai(12, 30),
    );

    expect(
      at,
      shanghai(13, 0),
      reason: '不跨午夜的时段里 `dayOffset` 必须保持 0——多加一天会让提醒晚一天',
    );
  });

  test('免打扰**结束于 24:00** 时推到次日零点，而不是当天零点', () async {
    // 免打扰 22:00–24:00；提醒原定本地 23:00。
    //
    // 这是 `endMinute == minutesPerDay` 那个特例：`localDateTimeToUtc` 只接受
    // [0, 1439]，因此 1440 必须改成"次日 00:00"。写错的表现是**提醒被排到当天 00:00**
    // ——一个已经过去的时刻，用户永远收不到。
    final target = shanghai(23, 0);
    final at = await scheduledTaskStartAt(
      quietHours: LocalTimeRange(startMinute: 1320, endMinute: 1440),
      notificationTargetUtc: target,
    );

    expect(
      at,
      shanghai(0, 0, dayOffset: 1),
      reason: '结束于 24:00 就是次日零点；排到当天零点等于排到过去，提醒永远不到',
    );
    expect(at.isAfter(target), isTrue, reason: '推迟之后的时刻必须在原时刻之后，否则它是一条排不出去的通知');
  });

  test('免打扰**之外**的时刻原样保留', () async {
    // 免打扰 23:30–07:30；提醒原定本地 12:00，完全不在其中。
    final target = shanghai(12, 0);

    final at = await scheduledTaskStartAt(
      quietHours: LocalTimeRange(startMinute: 1410, endMinute: 450),
      notificationTargetUtc: target,
    );

    expect(at, target, reason: '不在免打扰里就不该被推迟');
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _FixedPlans implements PlanRepository {
  _FixedPlans(this.blockStartUtc);
  final DateTime blockStartUtc;

  @override
  Future<ConfirmedPlan?> current() async => ConfirmedPlan(
    id: 'plan-1',
    inputHash: 'h',
    algorithmVersion: '11',
    blocks: [
      PlannedBlock(
        id: 'block-1',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: blockStartUtc,
          endUtc: blockStartUtc.add(const Duration(hours: 1)),
        ),
      ),
    ],
  );

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) => throw UnimplementedError();
}

final class _RecordingPort implements NotificationPort {
  final List<NotificationRequest> scheduled = [];

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}

  @override
  Future<NotificationPayload?> launchPayload() async => null;

  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability.available();

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<List<PendingNotification>> pendingNotifications() async => const [];

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {
    scheduled.add(request);
  }
}
