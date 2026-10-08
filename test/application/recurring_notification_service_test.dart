// M7（路线图 §3.5、§11 Task 9）：周期目标提醒。
//
// §3.5 的四条规则，逐条钉在这里：
// 1. 周四结束前进度低于 50% 时提醒一次；
// 2. 距周期结束不足 24 小时且仍有缺口时提醒一次；
// 3. 发现排程容量不足时**立即**生成一条可处理提示；
// 4. 本周达标、跳过或暂停后停止本周提醒。
//
// 另有两条容易漏掉的约束：**提醒必须去重**（重启程序不能重复通知，§11 Task 9 Step 3 给了
// 去重键 `(templateId, periodStart, kind)`），以及**遵守已有免打扰时段**（§3.5 最后一句）。
//
// 提醒的价值全在"准时且不重复"上：早一小时没用，重复三次会让用户关掉通知——那之后就再也
// 收不到任何提醒了。因此这个文件里"只发一次"的断言比"发了内容对不对"更关键。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_notification_service.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';

/// 固定时钟：所有场景都由测试指定"现在"。
final class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

/// 记录收到的提醒。`scheduled` 是**已经排出去**的，`cancelled` 是被撤回的。
final class _Port implements NotificationPort {
  final List<NotificationRequest> scheduled = [];
  final List<String> cancelled = [];
  NotificationCapability capabilityResult = const NotificationCapability(
    canSchedule: true,
    canCancelReliably: true,
  );
  List<PendingNotification> pending = const [];
  void Function(NotificationPayload payload)? _handler;
  NotificationPayload? launchResult;

  @override
  Future<NotificationCapability> capability() async => capabilityResult;

  @override
  Future<List<PendingNotification>> pendingNotifications() async => pending;

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {
    scheduled.add(request);
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
    scheduled.removeWhere((request) => request.id == id);
  }

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {
    _handler = handler;
  }

  @override
  Future<NotificationPayload?> launchPayload() async => launchResult;

  /// 供测试驱动"用户点了通知"。
  void tap(NotificationPayload payload) => _handler?.call(payload);
}

/// 一个可编程的周期来源：测试直接给出"现在这一周每个模板的进度与状态"。
///
/// **刻意不自己拼 `WeeklyPeriod`**：它要求 `startLocalDate` 是本地周一，还要一对一致的
/// UTC 边界与时区（构造器会逐项校验）。测试自己拼一个，等于在测试里重造一遍周界算法——
/// 而那个口径已经有 `recurring_period_test.dart` 专门守着。这里改成让真正的
/// `weeklyPeriodFor` 算出来，测试只提供"现在是哪一刻"。
final class _Cycles implements RecurringCycleReader {
  _Cycles({
    required this.cycles,
    required this.zones,
    required this.timeZoneId,
  });

  List<RecurringNotificationCandidate> cycles;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  @override
  Future<List<RecurringNotificationCandidate>> candidatesForWeek(
    WeeklyPeriod period,
  ) async => [...cycles];

  @override
  WeeklyPeriod periodContaining(DateTime nowUtc) =>
      weeklyPeriodFor(nowUtc, timeZoneId, zones: zones);
}

/// 周三 20:00（本地）——"周四结束前"这条规则还没到期。
final _wednesdayEvening = DateTime.utc(2026, 10, 7, 12);

/// 周四 21:00（本地）——已经进入"周四结束前"的判定窗口。
final _thursdayNight = DateTime.utc(2026, 10, 8, 13);

/// 周日 12:00（本地）——距下周一 00:00 不足 24 小时。
final _sundayNoon = DateTime.utc(2026, 10, 11, 4);

RecurringNotificationCandidate _candidate({
  String templateId = 'template-1',
  String title = '每周英语',
  int target = 180,
  int recorded = 0,
  RecurringCycleStatus status = RecurringCycleStatus.open,
}) => RecurringNotificationCandidate(
  templateId: templateId,
  title: title,
  targetMinutes: target,
  recordedMinutes: recorded,
  remainingMinutes: target - recorded <= 0 ? 0 : target - recorded,
  status: status,
);

({
  RecurringNotificationService service,
  _Port port,
  _Clock clock,
  _Cycles cycles,
})
_build({
  required _Clock clock,
  required List<RecurringNotificationCandidate> cycles,
  TimeZoneDatabase? zones,
  LocalTimeRange? quietHours,
}) {
  final port = _Port();
  final resolvedZones = zones ?? TimeZoneDatabase();
  final cycleSource = _Cycles(
    cycles: cycles,
    zones: resolvedZones,
    timeZoneId: 'Asia/Shanghai',
  );
  final service = RecurringNotificationService(
    cycles: cycleSource,
    notifications: port,
    clock: clock,
    zones: resolvedZones,
    timeZoneId: 'Asia/Shanghai',
    quietHoursFor: (_) async => quietHours,
  );
  return (service: service, port: port, clock: clock, cycles: cycleSource);
}

void main() {
  group('§3.5 第 1 条：周四结束前低于 50% 提醒一次', () {
    test('周四晚上进度 40% ⇒ 提醒一次', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)], // 40%
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(1));
      final request = harness.port.scheduled.single;
      expect(request.title, contains('每周英语'));
      // 正文要说清"差多少"，否则用户还得自己算。
      expect(request.body, contains('108'));
    });

    test('周四晚上已经 50% 或以上 ⇒ 不提醒（阈值是"低于"，不是"不高于"）', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 90)], // 正好 50%
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
    });

    test('还没到周四 ⇒ 不因为"低于 50%"提醒（早提醒没有用）', () async {
      final clock = _Clock(_wednesdayEvening);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 10)],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
    });
  });

  group('§3.5 第 2 条：距结束不足 24 小时且仍有缺口', () {
    test('周日中午仍有缺口 ⇒ 提醒一次', () async {
      final clock = _Clock(_sundayNoon);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 120)],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(1));
      expect(harness.port.scheduled.single.body, contains('60'));
    });

    test('周日中午已达标 ⇒ 不提醒', () async {
      final clock = _Clock(_sundayNoon);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 180)],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
    });

    test('距结束还早 ⇒ 不按"不足 24 小时"提醒', () async {
      final clock = _Clock(DateTime.utc(2026, 10, 9, 4)); // 周五 12:00 本地
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 0)],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
    });
  });

  group('§3.5 第 3 条：容量不足立即提示', () {
    test('候选自带容量缺口时立刻发一条可处理提示（不等周四）', () async {
      final clock = _Clock(_wednesdayEvening);
      final harness = _build(
        clock: clock,
        cycles: [
          _candidate(
            target: 180,
            recorded: 0,
          ).copyWith(schedulingShortfallMinutes: 60),
        ],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(1));
      final request = harness.port.scheduled.single;
      expect(request.body, contains('60'), reason: '缺口分钟数要写出来，用户才知道要处理多少');
    });

    test('容量够时不发这条提示', () async {
      final clock = _Clock(_wednesdayEvening);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 0)],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
    });
  });

  group('§3.5 第 4 条：达标、跳过、暂停后停止本周提醒', () {
    for (final status in [
      RecurringCycleStatus.met,
      RecurringCycleStatus.skipped,
      RecurringCycleStatus.missed,
    ]) {
      test('状态是 ${status.name} ⇒ 不再提醒', () async {
        final clock = _Clock(_thursdayNight);
        final harness = _build(
          clock: clock,
          cycles: [_candidate(target: 180, recorded: 10, status: status)],
        );

        await harness.service.evaluate();

        expect(
          harness.port.scheduled,
          isEmpty,
          reason: '${status.name} 的周期不该再收到提醒',
        );
      });
    }

    test('暂停中的模板不出现在候选里，因此不会被提醒', () async {
      // 暂停由服务层负责过滤（`candidatesForWeek` 不返回暂停的模板）。
      // 这里钉住"候选为空 ⇒ 无提醒"，免得提醒层自己再造一套暂停判断。
      final clock = _Clock(_thursdayNight);
      final harness = _build(clock: clock, cycles: const []);

      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
    });
  });

  group('§11 Task 9 Step 3：去重键 (templateId, periodStart, kind)', () {
    test('同一周内重复评估只发一次（重启程序也不重复）', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)],
      );

      await harness.service.evaluate();
      await harness.service.evaluate();
      await harness.service.evaluate();

      expect(
        harness.port.scheduled,
        hasLength(1),
        reason: '去重键存在的唯一理由：每次启动都评估，但只通知一次',
      );
    });

    test('新的一周可以再次提醒（去重不能把下周也堵掉）', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)],
      );
      await harness.service.evaluate();
      expect(harness.port.scheduled, hasLength(1));

      // 进入下一周：只推进时钟即可，周界由生产实现自己算出来。
      clock.now = DateTime.utc(2026, 10, 15, 13); // 下周四 21:00 本地
      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(2), reason: '新的一周必须能再提醒');
    });

    test('两类提醒各自的去重键独立（"低于 50%"不妨碍"到期缺口"）', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)],
      );
      await harness.service.evaluate();
      expect(harness.port.scheduled, hasLength(1));

      // 同一周内推进到"距结束不足 24 小时"，第二条提醒应当还能发。
      clock.now = _sundayNoon;
      await harness.service.evaluate();

      expect(
        harness.port.scheduled,
        hasLength(2),
        reason: '两条规则的 kind 不同，去重键必须区分开',
      );
    });

    test('多个模板互不影响，各自去重', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [
          _candidate(templateId: 't1', title: '每周英语', recorded: 10),
          _candidate(templateId: 't2', title: '每周跑步', recorded: 10),
        ],
      );

      await harness.service.evaluate();
      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(2));
    });
  });

  group('§3.5 最后一句：遵守已有免打扰时段', () {
    test('落在免打扰里 ⇒ 推迟到结束时刻，而不是丢弃', () async {
      // 免打扰 22:00–07:00；周四评估时刻**本身**是安全的（21:00 本地），
      // 但提醒被排到 23:00 也会落在窗口里——这里让服务把时间推到次日 07:00。
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)],
        quietHours: LocalTimeRange(startMinute: 22 * 60, endMinute: 7 * 60),
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(1), reason: '推延不是丢弃');
      final scheduledAt = harness.port.scheduled.single.scheduledAtUtc;
      final local = TimeZoneDatabase().toLocal(scheduledAt, 'Asia/Shanghai');
      final minute = local.hour * 60 + local.minute;
      expect(
        minute >= 7 * 60 && minute < 22 * 60,
        isTrue,
        reason: '提醒必须落在免打扰之外，实际是 ${local.hour}:${local.minute}',
      );
    });
  });

  group('通知内容与去向', () {
    test('提醒带 payload，点击能回到该周期的详情', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)],
      );

      await harness.service.evaluate();

      final payload = NotificationPayload.decode(
        harness.port.scheduled.single.payload,
      );
      expect(payload, isNotNull);
      expect(payload!.entityId, 'template-1');
      expect(
        payload.route,
        '/tasks/recurring/template-1',
        reason: '点击提醒要落到那个周期的详情，而不是任务列表',
      );
    });

    test('通知 id 带 planner 前缀，便于与其它提醒一起管理', () async {
      final clock = _Clock(_thursdayNight);
      final harness = _build(
        clock: clock,
        cycles: [_candidate(target: 180, recorded: 72)],
      );

      await harness.service.evaluate();

      expect(harness.port.scheduled.single.id, startsWith('planner.'));
    });
  });
}
