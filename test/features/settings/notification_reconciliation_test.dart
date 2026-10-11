// 1.8.0（设计规范 §5.2／§5.3，计划 Task 3）：「保存即生效」的对账链。
//
// 修复前的缺陷（§2.2）：设置页保存开关只落库、不调用任何同步。已排进 Windows 的
// `planner.*` 通知于是继续存在——"关掉通知"只关掉了界面上的一个勾。
//
// 这里钉四件事，每一件都对应规范里的一句话：
// 1. 总开关关闭 ⇒ 五类 `planner.*` 全部取消，**别的应用的通知不碰**；
// 2. 总开关关闭 ⇒ **不读计划**（§5.2 明确要求）；
// 3. 单类关闭 ⇒ 只取消那一类，其他类别保留；
// 4. 幂等：再对账一次不重复取消、不抛错；重启后不会因为一次普通生成而复活。
import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../../fixtures/core_workflow_repair_scenarios.dart';

void main() {
  late DateTime now;
  late _CountingPlanRepository plans;
  late MemorySettingsRepository settingsRepository;
  late SettingsService settings;
  late _ReconcilePort notifications;
  setUp(() {
    now = DateTime.utc(2026, 10, 2, 8);
    plans = _CountingPlanRepository();
    settingsRepository = MemorySettingsRepository();
    settings = SettingsService(repository: settingsRepository);
    notifications = _ReconcilePort();
  });

  /// 装配**全部五类来源**，否则"保留的类别不会被顺手取消"这条断言测不到东西：
  /// 没有日历来源时固定日程提醒本来就不在期望集合里，它会被当作过期事实取消，
  /// 于是用例失败的原因看起来像"关掉截止提醒波及了日历"，其实只是环境缺一半。
  NotificationService service() => NotificationService(
    plans: plans,
    settings: settings,
    notifications: notifications,
    clock: _FixedClock(now),
    zones: TimeZoneDatabase(),
    timeZoneId: 'Asia/Shanghai',
    calendar: _FixedCalendar([
      CalendarOccurrence(
        eventId: 'evt-lunch-shanghai',
        title: '午餐',
        range: TimeRange(
          startUtc: now.add(const Duration(hours: 4)),
          endUtc: now.add(const Duration(hours: 5)),
        ),
        locked: true,
      ),
    ]),
    pendingConflicts: () async => [
      PlanningConflict(
        code: ConflictCode.fixedEventOverlap,
        taskId: 'task-deep-work',
        relatedEntityIds: const ['block-deep-work-1510'],
      ),
    ],
    // 「截止临近」那一类也要有来源：它在期望集合里出现过，"保留的类别一条都没被动"
    // 这句话才覆盖到五类里的每一类。
    tasks: _FixedTasks([
      PlannerTask(
        id: 'task-deep-work',
        title: '深工作',
        priority: TaskPriority.medium,
        estimatedMinutes: 60,
        remainingMinutes: 60,
        dueAtUtc: now.add(const Duration(hours: 6)),
        energyLevel: TaskEnergyLevel.medium,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 15,
        maxChunkMinutes: 30,
        status: TaskStatus.open,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    ]),
  );

  /// 五类期望项共用的排程计划：一条落在窗口内的计划块，id 与夹具里的通知 id 对齐。
  ConfirmedPlan planCoveringAllCategories() => _plan([
    PlannedBlock(
      id: 'block-deep-work-1510',
      taskId: 'task-deep-work',
      range: TimeRange(
        startUtc: now.add(const Duration(hours: 2)),
        endUtc: now.add(const Duration(hours: 3)),
      ),
    ),
  ]);

  /// 预置夹具里那六条待处理通知：五类 `planner.*` 加一条外部应用的。
  void seedPendingFromFixture() {
    for (final scenario
        in CoreWorkflowRepairScenarios().notificationCategories()) {
      notifications.pending.add(
        PendingNotification(id: scenario.id, payload: '{}'),
      );
    }
  }

  final plannerIds = CoreWorkflowRepairScenarios()
      .notificationCategories()
      .where((scenario) => scenario.isManagedByPlanner)
      .map((scenario) => scenario.id)
      .toList();

  group('总开关', () {
    test('关闭后五类 planner.* 全部取消，外部应用的通知一条不碰', () async {
      seedPendingFromFixture();
      plans.plan = _plan([_block('task', now.add(const Duration(hours: 2)))]);

      await service().reconcile(
        preferences: NotificationPreferences(enabled: false),
      );

      expect(
        notifications.cancelled.toSet(),
        plannerIds.toSet(),
        reason: '五类本应用通知全部取消；多一条或少一条都说明前缀判断错了',
      );
      expect(
        notifications.cancelled,
        isNot(contains(RepairIds.foreignNotification)),
        reason: '别的应用的通知不属于本应用的开关管辖范围',
      );
      expect(notifications.scheduled, isEmpty);
      // 取消之后待处理里只剩那条外部通知。
      expect(notifications.pending.map((item) => item.id), [
        RepairIds.foreignNotification,
      ]);
    });

    test('总开关关闭时**不读计划**（§5.2）', () async {
      seedPendingFromFixture();
      plans.plan = _plan([_block('task', now.add(const Duration(hours: 2)))]);

      await service().reconcile(
        preferences: NotificationPreferences(enabled: false),
      );

      expect(
        plans.currentCalls,
        0,
        reason: '"关掉通知"不该顺手把计划读一遍——那既浪费查询，也把一次设置动作变成一次数据访问',
      );
    });

    test('对账两次不重复取消、不抛错（幂等）', () async {
      seedPendingFromFixture();
      final subject = service();
      final off = NotificationPreferences(enabled: false);

      final first = await subject.reconcile(preferences: off);
      final second = await subject.reconcile(preferences: off);

      expect(first.cancelledCount, plannerIds.length);
      expect(
        second.cancelledCount,
        0,
        reason: '第一次已经把它们从待处理里拿掉了，第二次无东西可取消；重复取消会报错并让启动路径失败',
      );
    });

    test('关闭后重启（新服务实例）再生成计划，五类通知不会复活', () async {
      seedPendingFromFixture();
      await settings.saveNotificationPreferences(
        NotificationPreferences(enabled: false),
      );

      // 重启等价于"新实例 + 从设置读偏好"（不显式传 preferences）。
      final afterRestart = service();
      await afterRestart.reconcile();
      expect(notifications.scheduled, isEmpty);

      // 再走一次普通"计划变了"的路径：仍然一条都不排。
      plans.plan = _plan([_block('task', now.add(const Duration(hours: 2)))]);
      await afterRestart.reconcile();
      expect(
        notifications.scheduled,
        isEmpty,
        reason: '关闭通知后不得因下一次计划生成而重新排入（规范 §5.2 最后一句）',
      );
    });

    test('各分类的取值在总开关关闭后**保留**', () async {
      await settings.saveNotificationPreferences(
        NotificationPreferences(
          enabled: false,
          taskStartEnabled: false,
          conflictEnabled: false,
        ),
      );

      final reloaded = await settings.loadNotificationPreferences();
      expect(reloaded.enabled, isFalse);
      expect(
        reloaded.taskStartEnabled,
        isFalse,
        reason: '关掉总开关不该把用户的分类选择重置成默认——再打开时要恢复原样',
      );
      expect(reloaded.conflictEnabled, isFalse);
    });

    test('缺 enabled 键的老设置读成"开启"', () async {
      // 1.7.1 及以前存下的 JSON：没有 `enabled` 这个键。
      await settingsRepository.write(
        'notifications.v1',
        '{"taskStartEnabled":true,"taskStartLeadMinutes":10,'
            '"calendarStartEnabled":true,"calendarStartLeadMinutes":10,'
            '"deadlineEnabled":true,"deadlineLeadMinutes":1440,'
            '"conflictEnabled":true,"conflictLeadMinutes":30,'
            '"quietHours":{"startMinute":1410,"endMinute":450}}',
      );

      final loaded = await settings.loadNotificationPreferences();
      expect(
        loaded.enabled,
        isTrue,
        reason: '强转会抛在启动路径上；"老用户升级后再也收不到提醒"是更坏的默认',
      );
    });
  });

  group('分类开关', () {
    test('只关周期目标 ⇒ 只取消周期目标那一类', () async {
      seedPendingFromFixture();
      // 同上：给一份计划，这样"其他四类保留"才有意义。
      plans.plan = planCoveringAllCategories();

      await service().reconcile(
        preferences: NotificationPreferences(recurringGoalEnabled: false),
        evaluateRecurringGoal: () async {},
      );

      expect(notifications.cancelled, [
        'planner.recurring.weeklyProgress.tpl-weekly-goal.2026-10-12',
      ], reason: '关掉周期目标只该取消它自己那一类；另外三类有期望项，因此不能被动');
      expect(
        notifications.pending.map((item) => item.id),
        isNot(
          contains(
            'planner.recurring.weeklyProgress.tpl-weekly-goal.2026-10-12',
          ),
        ),
        reason: '关掉的那一类必须真的从系统待处理里消失',
      );
    });

    test('只关截止提醒 ⇒ 只取消截止那一类', () async {
      seedPendingFromFixture();
      // **周期目标那一条先拿掉**：它由 `RecurringNotificationService` 自己在评估时排入，
      // 而这条用例不接那个服务，于是它在期望集合里必然为空、会被当作过期事实取消——
      // 那是对的行为（确实没人再排它），但会让"关掉截止提醒"的断言多出一条无关的取消。
      notifications.pending.removeWhere(
        (item) => item.id.startsWith('planner.recurring.'),
      );
      // **必须给一份计划**：没有计划时"任务开始提醒"在期望集合里本来就不存在，
      // 于是它会因为"过期事实"被取消——那条路径是对的，但会让这条用例测到两件事。
      // 这里要钉的是"关掉某一类不会波及别的类"，因此让其他三类都有期望项。
      plans.plan = planCoveringAllCategories();

      await service().reconcile(
        preferences: NotificationPreferences(deadlineEnabled: false),
      );

      expect(notifications.cancelled, [
        'planner.deadline.task-deep-work',
      ], reason: '只该取消被关掉的那一类，别的类别一条都不能动');
    });

    test('保留的类别不会被"顺手"取消掉', () async {
      seedPendingFromFixture();
      notifications.pending.removeWhere(
        (item) => item.id.endsWith('tpl-weekly-goal.2026-10-12'),
      );
      // 与上一条同样的理由：给一份计划，让"没被关掉的类别"在期望集合里真的存在，
      // 否则它们会因为"计划里没有"而被当作过期事实取消，掩盖掉这条用例要测的东西。
      plans.plan = planCoveringAllCategories();

      await service().reconcile(
        preferences: NotificationPreferences(deadlineEnabled: false),
        evaluateRecurringGoal: () async {},
      );

      expect(notifications.cancelled, ['planner.deadline.task-deep-work']);
      expect(notifications.pending.map((item) => item.id).toSet(), {
        RepairIds.foreignNotification,
        'planner.task_start.block-deep-work-1510',
        'planner.calendar_start.evt-lunch-shanghai',
        'planner.conflict.pending',
      }, reason: '没被关掉的三类本应用通知与那条外部通知都必须留着');
    });

    test('**五类的 id、payload 与类别三者互相对得上**（结构不变量）', () async {
      // 这条是所有取消逻辑的地基，且**跨五个生成分支**：
      //   · `reconcile` 取消时按 `id` 判断类别（`_categoryOf(id)`）；
      //   · 平台点击回调按 payload 里的 `notificationId` / `kind` 决定去哪一页；
      //   · 两者的键必须是**同一个字符串**，否则"取消"与"点击"认的不是同一条。
      //
      // 任何一条生成分支把 prefix、payload 或 kind 写歪，都只有这条跨分支的用例看得见——
      // 单看某一类的用例会各自通过。
      // **必须先把计划放进去**：`_CountingPlanRepository.plan` 默认是 `null`，
      // 而「任务即将开始」那一类的生成分支在 `plan == null` 时什么都不产出。
      // 第一版我忘了这一行，于是"四类都在"红了——**缺的是我的夹具，不是代码**。
      plans.plan = planCoveringAllCategories();
      await service().reconcile();

      expect(notifications.scheduled, isNotEmpty, reason: '前置条件：五类来源齐全时必须排出通知');

      final kindsSeen = <NotificationKind>{};
      for (final request in notifications.scheduled) {
        final payload = NotificationPayload.decode(request.payload);
        expect(
          payload,
          isNotNull,
          reason: '${request.id} 的 payload 必须能解出来；解不出来点击回调就不知道该去哪',
        );
        expect(
          payload!.notificationId,
          request.id,
          reason:
              '${request.id} 的 payload.notificationId 是 ${payload.notificationId}——'
              '两者不同意味着"按 id 取消"与"按 payload 跳转"认的不是同一条通知',
        );
        final category = NotificationService.categoryOf(request.id);
        expect(
          category,
          payload.kind,
          reason:
              '${request.id} 按前缀属于 $category，但 payload 声明的是 ${payload.kind}；'
              '不一致时"关掉这一类"会取消掉另一类的通知',
        );
        kindsSeen.add(payload.kind);
      }

      expect(
        kindsSeen,
        containsAll(const [
          NotificationKind.taskStart,
          NotificationKind.calendarStart,
          NotificationKind.deadline,
          NotificationKind.conflict,
        ]),
        reason:
            '夹具装配了四类来源（周期目标那一类由它自己的服务产出，不在这里）；'
            '少一类说明有一条生成分支没进期望集合——而那一类会被当成"过期事实"取消掉',
      );
    });

    test('周期目标关闭时**一次都不评估**（规范 §5.2 最后一条）', () async {
      var evaluated = 0;

      await service().reconcile(
        preferences: NotificationPreferences(recurringGoalEnabled: false),
        evaluateRecurringGoal: () async => evaluated++,
      );

      expect(evaluated, 0);
    });

    test('周期目标开启时走同一次对账（评估被调用一次）', () async {
      var evaluated = 0;

      await service().reconcile(
        preferences: NotificationPreferences(),
        evaluateRecurringGoal: () async => evaluated++,
      );

      expect(evaluated, 1, reason: '周期目标提醒必须与其他四类共用同一次保存／加载／取消链');
    });
  });

  // 页面编排（计划 Task 3 Step 3）：保存必须**等对账完成**才显示成功；
  // 对账抛错时必须显示部分失败与「重新同步」，不能静默显示成功。
  group('设置页的保存编排', () {
    Future<void> pumpPage(
      WidgetTester tester, {
      required Future<void> Function()? reconcile,
      ValueChanged<int>? onReconcile,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanningRulesPage(
              service: settings,
              localDate: DateTime(2026, 10, 5, 9),
              reconcileNotifications: reconcile == null
                  ? null
                  : () async {
                      onReconcile?.call(1);
                      await reconcile();
                    },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('保存会先落库再对账，且成功文案只在两者都完成之后出现', (tester) async {
      var reconcileStarted = false;
      var reconcileFinished = false;
      final gate = Completer<void>();

      await pumpPage(
        tester,
        reconcile: () async {
          reconcileStarted = true;
          await gate.future;
          reconcileFinished = true;
        },
      );

      await tester.tap(find.byKey(const Key('notifications-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存设置'));
      await tester.pump();

      expect(reconcileStarted, isTrue, reason: '保存必须真的触发对账；只落库不对账等于"关掉通知"没生效');
      expect(
        find.text('设置已保存'),
        findsNothing,
        reason: '对账还没返回就显示"已保存"，用户会以为通知已经清掉了',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(reconcileFinished, isTrue);
      expect(find.text('设置已保存'), findsOneWidget);
    });

    testWidgets('对账失败时显示部分失败与「重新同步」，不显示"设置已保存"', (tester) async {
      var attempts = 0;
      await pumpPage(
        tester,
        reconcile: () async {
          attempts++;
          if (attempts == 1) {
            throw StateError('windows notification api failed');
          }
        },
      );

      await tester.tap(find.byKey(const Key('notifications-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('notifications-sync-error')),
        findsOneWidget,
        reason: '§5.3：不能静默显示成功',
      );
      expect(find.textContaining('系统通知清理失败'), findsOneWidget);
      expect(
        find.text('设置已保存'),
        findsNothing,
        reason: '偏好存下来了但通知没清掉——这两件事必须分开说',
      );

      // 「重新同步」只重跑对账，不重复落库。
      final before = await settings.loadNotificationPreferences();
      await tester.tap(find.byKey(const Key('notifications-resync')));
      await tester.pumpAndSettle();
      final after = await settings.loadNotificationPreferences();

      expect(attempts, 2, reason: '重试必须真的再对账一次');
      expect(after.enabled, before.enabled, reason: '「重新同步」不该把页面上的当前值再写一遍库');
      expect(find.byKey(const Key('notifications-sync-error')), findsNothing);
    });

    testWidgets('未装配对账入口时保存照常成功，但不假装同步过', (tester) async {
      await pumpPage(tester, reconcile: null);

      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(find.text('设置已保存'), findsOneWidget);
      expect(find.byKey(const Key('notifications-sync-error')), findsNothing);
    });

    testWidgets('总开关的当前值来自设置，且保存后写入库', (tester) async {
      await settings.saveNotificationPreferences(
        NotificationPreferences(enabled: false),
      );
      await pumpPage(tester, reconcile: () async {});

      final toggle = tester.widget<Switch>(
        find.descendant(
          of: find.byKey(const Key('notifications-enabled')),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle.value, isFalse, reason: '页面必须加载总开关的当前值，否则用户看到的与库里不一致');

      await tester.tap(find.byKey(const Key('notifications-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final saved = await settings.loadNotificationPreferences();
      expect(saved.enabled, isTrue);
    });

    testWidgets('总开关关闭时分类开关可见但不可改（值保留）', (tester) async {
      await settings.saveNotificationPreferences(
        NotificationPreferences(enabled: false, calendarStartEnabled: false),
      );
      await pumpPage(tester, reconcile: () async {});

      final calendarSwitch = tester.widget<Switch>(
        find.descendant(
          of: find.ancestor(
            of: find.text('固定日程提醒'),
            matching: find.byType(SwitchListTile),
          ),
          matching: find.byType(Switch),
        ),
      );
      expect(
        calendarSwitch.value,
        isFalse,
        reason: '分类取值必须仍然显示出来，"值还在、只是不生效"才是诚实的表达',
      );
      expect(
        calendarSwitch.onChanged,
        isNull,
        reason: '总开关关闭时改分类没有意义，应当不可操作而不是点了没反应',
      );
    });
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

/// 只读的任务替身：「截止临近」那一类要有来源。
final class _FixedTasks implements TaskRepository {
  const _FixedTasks(this.items);
  final List<PlannerTask> items;

  @override
  Future<PlannerTask?> getById(String id) async =>
      items.where((item) => item.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {}

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(items);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() =>
      Stream.value(items.where((task) => !task.status.isClosed).toList());
}

/// 只读的日历替身：五类期望项里"固定日程"那一类要有来源，否则对账会把它的待处理项
/// 当成过期事实取消掉（那条路径是对的，但会让"关掉某一类不波及别的类"测不准）。
final class _FixedCalendar implements CalendarRepository {
  const _FixedCalendar(this.items);
  final List<CalendarOccurrence> items;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => items
      .where(
        (item) =>
            item.range.overlaps(TimeRange(startUtc: startUtc, endUtc: endUtc)),
      )
      .toList();

  @override
  Future<void> save(CalendarEvent event) async {}
}

/// 计划仓储：**数读取次数**。总开关关闭时"不读计划"这条断言只能靠计数器证明。
final class _CountingPlanRepository implements PlanRepository {
  ConfirmedPlan? plan;
  int currentCalls = 0;

  @override
  Future<ConfirmedPlan?> current() async {
    currentCalls++;
    return plan;
  }

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) => throw UnimplementedError();
}

final class _ReconcilePort implements NotificationPort {
  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}

  @override
  Future<NotificationPayload?> launchPayload() async => null;

  final List<NotificationRequest> scheduled = [];
  final List<String> cancelled = [];
  final List<PendingNotification> pending = [];

  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability.available();

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
