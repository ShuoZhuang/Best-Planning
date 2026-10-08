// M7（§3.5、§11 Task 9）设置侧：周期目标提醒的开关，以及它的持久化。
//
// 两件事一起钉在这里，因为它们必须同时成立才有意义：
// 1. 设置页里**看得见**这个开关，且能改；
// 2. 关掉之后提醒服务**一次都不评估**（§3.5 的提醒是周期目标功能的一部分，关掉就该真的停）。
//
// 另外一条是升级兼容：1.7 之前存下的通知设置里**没有** `recurringGoalEnabled` 这个键，
// 读的时候必须回落到 `true`。直接强转会抛在启动路径上，而"静默变成关闭"则会让老用户
// 升级后再也收不到周期目标提醒——两种都比这里写的默认值差。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_notification_service.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/settings/notifications/notification_preferences_section.dart';

final class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

final class _Port implements NotificationPort {
  final List<NotificationRequest> scheduled = [];
  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability(canSchedule: true, canCancelReliably: true);
  @override
  Future<List<PendingNotification>> pendingNotifications() async => const [];
  @override
  Future<void> scheduleOneShot(NotificationRequest request) async =>
      scheduled.add(request);
  @override
  Future<void> cancel(String id) async {}
  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}
  @override
  Future<NotificationPayload?> launchPayload() async => null;
}

final class _Cycles implements RecurringCycleReader {
  _Cycles(this.now, this.candidates);
  final DateTime now;
  final List<RecurringNotificationCandidate> candidates;
  int periodsAsked = 0;
  @override
  WeeklyPeriod periodContaining(DateTime nowUtc) {
    periodsAsked++;
    return weeklyPeriodFor(nowUtc, 'Asia/Shanghai');
  }

  @override
  Future<List<RecurringNotificationCandidate>> candidatesForWeek(
    WeeklyPeriod period,
  ) async => candidates;
}

Widget _section({bool enabled = true, ValueChanged<bool>? onChanged}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NotificationPreferencesSection(
            taskLeadController: TextEditingController(text: '10'),
            calendarLeadController: TextEditingController(text: '10'),
            deadlineLeadController: TextEditingController(text: '1440'),
            quietStartController: TextEditingController(text: '23:30'),
            quietEndController: TextEditingController(text: '07:30'),
            taskStartEnabled: true,
            calendarStartEnabled: true,
            deadlineEnabled: true,
            conflictEnabled: true,
            onTaskStartChanged: (_) {},
            onCalendarStartChanged: (_) {},
            onDeadlineChanged: (_) {},
            onConflictChanged: (_) {},
            recurringGoalEnabled: enabled,
            onRecurringGoalChanged: onChanged,
            errors: const {},
          ),
        ),
      ),
    );

void main() {
  group('§11 Task 9：设置页的周期目标提醒开关', () {
    testWidgets('开关在页面上，且能改', (tester) async {
      bool? changed;
      await tester.pumpWidget(_section(onChanged: (value) => changed = value));
      await tester.pumpAndSettle();

      expect(find.text('周期目标提醒'), findsOneWidget);
      // **点 Switch 本身，不是标题文字**：`SwitchListTile` 的 `title` 只是标签，点它不会
      // 切换开关——第一版就是这么写的，回调始终为 null，看起来像开关没接上。
      final row = find.ancestor(
        of: find.text('周期目标提醒'),
        matching: find.byType(SwitchListTile),
      );
      expect(row, findsOneWidget);
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pumpAndSettle();

      expect(changed, isFalse, reason: '当前是开（true），点一下应当请求关掉（false）');
    });

    testWidgets('端口为空时**不渲染**这个开关（不给点了没反应的开关）', (tester) async {
      await tester.pumpWidget(_section(onChanged: null));
      await tester.pumpAndSettle();

      expect(find.text('周期目标提醒'), findsNothing);
      // 其余四类照旧。
      expect(find.text('任务开始提醒'), findsOneWidget);
      expect(find.text('冲突待处理提醒'), findsOneWidget);
    });
  });

  group('§11 Task 9：开关落到提醒服务上', () {
    Future<({_Port port, _Cycles cycles, RecurringNotificationService service})>
    build({required bool enabled}) async {
      final clock = _Clock(DateTime.utc(2026, 10, 8, 13)); // 周四 21:00 本地
      final port = _Port();
      final cycles = _Cycles(clock.now, [
        const RecurringNotificationCandidate(
          templateId: 't1',
          title: '每周英语',
          targetMinutes: 180,
          recordedMinutes: 10,
          remainingMinutes: 170,
          status: RecurringCycleStatus.open,
        ),
      ]);
      final service = RecurringNotificationService(
        cycles: cycles,
        notifications: port,
        clock: clock,
        zones: TimeZoneDatabase(),
        timeZoneId: 'Asia/Shanghai',
        enabledFor: () async => enabled,
      );
      return (port: port, cycles: cycles, service: service);
    }

    test('开关开着 ⇒ 正常提醒', () async {
      final harness = await build(enabled: true);
      await harness.service.evaluate();

      expect(harness.port.scheduled, hasLength(1));
    });

    test('开关关掉 ⇒ 一次都不评估（连周期数据都不读）', () async {
      final harness = await build(enabled: false);
      await harness.service.evaluate();

      expect(harness.port.scheduled, isEmpty);
      expect(
        harness.cycles.periodsAsked,
        0,
        reason: '"别再提醒我"是"别做这件事"，不是"做了但不显示"',
      );
    });
  });

  group('§11 Task 9：设置的持久化与升级兼容', () {
    test('默认开启（新装用户不会静默漏掉提醒）', () {
      expect(NotificationPreferences().recurringGoalEnabled, isTrue);
    });

    test('存读往返保持取值', () async {
      final repository = MemorySettingsRepository();
      final service = SettingsService(repository: repository);

      await service.saveNotificationPreferences(
        NotificationPreferences(recurringGoalEnabled: false),
      );
      final loaded = await service.loadNotificationPreferences();

      expect(loaded.recurringGoalEnabled, isFalse);
    });

    test('**升级兼容**：1.7 之前存下的设置没有这个键，读出来默认开启', () async {
      final repository = MemorySettingsRepository();
      // 故意写一份"1.6 时代"的通知设置：没有 recurringGoalEnabled。
      await repository.write(
        'notifications.v1',
        '{"taskStartEnabled":true,"taskStartLeadMinutes":10,'
            '"calendarStartEnabled":true,"calendarStartLeadMinutes":10,'
            '"deadlineEnabled":true,"deadlineLeadMinutes":1440,'
            '"conflictEnabled":true,"conflictLeadMinutes":30,'
            '"quietHours":{"startMinute":1410,"endMinute":450}}',
      );
      final service = SettingsService(repository: repository);

      final loaded = await service.loadNotificationPreferences();

      expect(
        loaded.recurringGoalEnabled,
        isTrue,
        reason: '老用户升级后不该静默失去周期目标提醒；也不该在这里抛异常',
      );
    });
  });
}
