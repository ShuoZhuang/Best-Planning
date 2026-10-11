import 'package:personal_planner/application/recurring_notification_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

final class NotificationSyncResult {
  const NotificationSyncResult({
    required this.scheduledCount,
    required this.cancelledCount,
    required this.capability,
  });

  final int scheduledCount;
  final int cancelledCount;
  final NotificationCapability capability;
}

final class NotificationService {
  NotificationService({
    required this.plans,
    required this.settings,
    required this.notifications,
    required this.clock,
    required this.zones,
    // 必填：此前默认 'Asia/Shanghai'，忘记传就会把提醒按东八区解释，而在别的时区只表现为
    // "时间算错"、不报错（R11）。改为必填后"忘记传"是编译错误。
    required this.timeZoneId,
    this.calendar,
    this.tasks,
    this.pendingConflicts,
  });

  static const _managedPrefix = 'planner.';
  static const _taskStartPrefix = 'planner.task_start.';
  static const _calendarStartPrefix = 'planner.calendar_start.';
  static const _deadlinePrefix = 'planner.deadline.';
  static const _conflictPrefix = 'planner.conflict.';
  static const _recurringPrefix = RecurringNotificationService.managedPrefix;
  static const _window = Duration(days: 7);

  /// 本应用会自己排队的所有通知 id 前缀。
  ///
  /// **顺序即"取消的全集"**：总开关关闭或某一类关闭时，判断"这条待处理项该不该被取消"
  /// 用的就是这份清单（见 [reconcile]）。此前只有 `_managedPrefix` 一个粗粒度前缀，
  /// 于是"关掉截止提醒"只能靠"重新生成一遍期望集合"来间接实现——而那条路径在
  /// 总开关关闭时**仍然会去读计划**，正是设计规范 §5.2 明令禁止的。
  static const managedPrefixes = <String>[
    _managedPrefix,
    _taskStartPrefix,
    _calendarStartPrefix,
    _deadlinePrefix,
    _conflictPrefix,
    _recurringPrefix,
  ];

  /// 这条通知 id 属于哪一类；`null` 表示它**不是本应用排入的**。
  ///
  /// 用"枚举已知前缀"而不是"看它是否以 `planner.` 开头"：后者会把旧版本留下的、
  /// 或者将来新增的未知前缀也算成本应用的，于是对账可能误伤它们。返回枚举值而不是
  /// 字符串，是为了让"该不该取消"只在一处判断（见 [reconcile]）。
  static NotificationKind? _categoryOf(String id) {
    if (id.startsWith(_taskStartPrefix)) return NotificationKind.taskStart;
    if (id.startsWith(_calendarStartPrefix)) {
      return NotificationKind.calendarStart;
    }
    if (id.startsWith(_deadlinePrefix)) return NotificationKind.deadline;
    if (id.startsWith(_conflictPrefix)) return NotificationKind.conflict;
    if (id.startsWith(_recurringPrefix)) return NotificationKind.recurringGoal;
    return null;
  }

  /// 这一类现在是否开启。
  static bool _categoryEnabled(
    NotificationPreferences preferences,
    NotificationKind kind,
  ) => switch (kind) {
    NotificationKind.taskStart => preferences.taskStartEnabled,
    NotificationKind.calendarStart => preferences.calendarStartEnabled,
    NotificationKind.deadline => preferences.deadlineEnabled,
    NotificationKind.conflict => preferences.conflictEnabled,
    NotificationKind.recurringGoal => preferences.recurringGoalEnabled,
  };

  final PlanRepository plans;
  final SettingsService settings;
  final NotificationPort notifications;
  final Clock clock;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  /// 固定日程来源，用于"固定日程即将开始"通知（FR-NOTIFY-01）。
  /// 为空时跳过该类通知，而不是伪造一条。
  final CalendarRepository? calendar;

  /// 开放任务来源，用于"截止临近"通知（FR-NOTIFY-01）。
  final TaskRepository? tasks;

  /// 当前待处理冲突的来源，用于"冲突待处理"通知（FR-NOTIFY-01）。
  ///
  /// 冲突不属于持久事实，而是每次排程的产物，因此由调用方提供读取方式。
  final Future<List<PlanningConflict>> Function()? pendingConflicts;

  /// 把"当前计划 + 当前设置"对账成一组应当存在的提醒。
  ///
  /// 抽成独立方法是为了让 [reconcile] 能**在总开关关闭时完全不调它**——那正是规范 §5.2
  /// 的要求："总开关关闭时不读取计划来重新排通知"。分成两个入口的话，"找那个算期望集合的
  /// 函数"就会有两份，而规范第 4 条不变量恰恰是"只能有一个 proposal/一条链"。
  Future<Map<String, NotificationRequest>> _desiredNotifications({
    required NotificationCapability capability,
    required NotificationPreferences preferences,
    required DateTime now,
    required DateTime horizon,
  }) async {
    final desired = <String, NotificationRequest>{};
    if (!capability.canSchedule) return desired;
    // 总开关关闭时调用方不该走到这里；这一步是防御而不是主路径。
    if (!preferences.enabled) return desired;

    if (preferences.taskStartEnabled) {
      final plan = await plans.current();
      if (plan != null) {
        for (final block in plan.blocks) {
          if (!block.startUtc.isAfter(now) || block.startUtc.isAfter(horizon)) {
            continue;
          }
          var scheduledAt = block.startUtc.subtract(
            Duration(minutes: preferences.taskStartLeadMinutes),
          );
          scheduledAt = _clampToFuture(scheduledAt, now);
          scheduledAt = _delayPastQuietHours(
            scheduledAt,
            preferences.quietHours,
          );
          if (scheduledAt.isAfter(horizon)) continue;

          final id = '$_taskStartPrefix${block.id}';
          desired[id] = NotificationRequest(
            id: id,
            scheduledAtUtc: scheduledAt,
            title: '日程提醒',
            body: '有一项安排即将开始',
            payload: NotificationPayload(
              notificationId: id,
              kind: NotificationKind.taskStart,
              entityId: block.taskId,
              route: '/tasks/${block.taskId}',
            ).encode(),
          );
        }
      }
    }

    if (preferences.calendarStartEnabled) {
      final source = calendar;
      if (source != null) {
        for (final occurrence in await source.occurrencesBetween(
          now,
          horizon,
        )) {
          // 已经开始的事件不再提醒"即将开始"。
          if (!occurrence.range.startUtc.isAfter(now)) continue;
          var scheduledAt = occurrence.range.startUtc.subtract(
            Duration(minutes: preferences.calendarStartLeadMinutes),
          );
          scheduledAt = _clampToFuture(scheduledAt, now);
          scheduledAt = _delayPastQuietHours(
            scheduledAt,
            preferences.quietHours,
          );
          if (scheduledAt.isAfter(horizon)) continue;
          final id = '$_calendarStartPrefix${occurrence.eventId}';
          desired[id] = NotificationRequest(
            id: id,
            scheduledAtUtc: scheduledAt,
            title: '日程提醒',
            body: '有一项固定日程即将开始',
            payload: NotificationPayload(
              notificationId: id,
              kind: NotificationKind.calendarStart,
              entityId: occurrence.eventId,
              route: '/calendar',
            ).encode(),
          );
        }
      }
    }

    if (preferences.deadlineEnabled) {
      final source = tasks;
      if (source != null) {
        for (final task in await source.watchOpenTasks().first) {
          final due = task.dueAtUtc;
          if (due == null) continue;
          // 已经超过截止时间的任务不再提醒"临近截止"。
          if (!due.isAfter(now)) continue;
          var scheduledAt = due.subtract(
            Duration(minutes: preferences.deadlineLeadMinutes),
          );
          scheduledAt = _clampToFuture(scheduledAt, now);
          if (scheduledAt.isAfter(horizon)) continue;
          scheduledAt = _delayPastQuietHours(
            scheduledAt,
            preferences.quietHours,
          );
          if (scheduledAt.isAfter(horizon)) continue;
          final id = '$_deadlinePrefix${task.id}';
          desired[id] = NotificationRequest(
            id: id,
            scheduledAtUtc: scheduledAt,
            title: '截止提醒',
            body: '有任务临近截止时间',
            payload: NotificationPayload(
              notificationId: id,
              kind: NotificationKind.deadline,
              entityId: task.id,
              route: '/tasks/${task.id}',
            ).encode(),
          );
        }
      }
    }

    if (preferences.conflictEnabled) {
      final source = pendingConflicts;
      if (source != null) {
        final conflicts = await source();
        if (conflicts.isNotEmpty) {
          // **冲突提醒不套免打扰延后（C12，2026-10-04 产品侧确认）。**
          //
          // 界面上写的是「普通通知在免打扰期间延后；**冲突待处理提醒仍会保留**」
          // （`notification_preferences_section.dart`），而代码此前对它**同样**调了
          // `_delayPastQuietHours`——文案承诺了、代码没兑现。产品侧确认按**文案**为准：
          // 冲突是"计划已经排不下、等你决定"的状态，**夜里压到早上**会让用户在最需要知道的
          // 时候看不到它，而它并不像"某任务即将开始"那样具有时效性。
          //
          // 因此这里**刻意只保留 `now + conflictLeadMinutes`**，不加免打扰处理。三条普通提醒
          // （任务开始／固定日程／截止）**仍然延后**，这一行为不变。
          final scheduledAt = now.add(
            Duration(minutes: preferences.conflictLeadMinutes),
          );
          if (!scheduledAt.isAfter(horizon)) {
            final id = '${_conflictPrefix}pending';
            desired[id] = NotificationRequest(
              id: id,
              scheduledAtUtc: scheduledAt,
              title: '有冲突待处理',
              body: '当前计划中有 ${conflicts.length} 项冲突需要确认',
              payload: NotificationPayload(
                notificationId: id,
                kind: NotificationKind.conflict,
                entityId: conflicts.first.taskId ?? '',
                route: '/calendar',
              ).encode(),
            );
          }
        }
      }
    }

    return desired;
  }

  /// 按**当前设置**重新对账一次：取消不该留的，排出该有的。
  ///
  /// **这是通知侧唯一的对账入口**（设计规范 §5.2）：启动、唤醒、计划应用、任务状态变化
  /// 与设置保存全部走它。此前设置页保存开关只落库、不调用任何同步，于是已排进 Windows 的
  /// `planner.*` 通知继续存在，"关掉通知"只关掉了界面上的一个勾（§2.2）。
  ///
  /// 四条规则，顺序不能换：
  ///
  /// 1. **总开关关闭 ⇒ 不读计划**。只按 id 前缀取消全部本应用待处理通知。§5.2 明确
  ///    "总开关关闭时不读取计划来重新排通知"——那既浪费一次数据库查询，又会把"关掉通知"
  ///    变成一次隐式的计划读取（用户以为自己只是关了提醒）。
  /// 2. **某一类关闭 ⇒ 只取消那一类**。`planner.` 之外的通知（别的应用）永不触碰；
  ///    同类但由别的来源排入的（例如周期目标走 `planner.recurring.`）也各归各的开关。
  /// 3. **幂等**。第二次调用不会重复取消（第一次已经把它们从待处理里拿掉了），
  ///    也不会抛错——启动、计划应用与保存会各自调它一次。
  /// 4. **重新排入之前先取消**。顺序反过来会先排一遍再取消掉刚排的（如果 id 恰好一致）。
  ///
  /// [preferences] 为空时从设置读当前值。
  Future<NotificationSyncResult> reconcile({
    NotificationPreferences? preferences,
    Future<void> Function()? evaluateRecurringGoal,
  }) async {
    final resolved =
        preferences ?? await settings.loadNotificationPreferences();
    final capability = await notifications.capability();
    final now = clock.nowUtc();
    final horizon = now.add(_window);

    // 规则 1：总开关关闭 ⇒ 不读计划，直接按前缀清干净。
    if (!resolved.enabled) {
      final cancelled = await _cancelPending(
        (id) => id.startsWith(_managedPrefix),
      );
      return NotificationSyncResult(
        scheduledCount: 0,
        cancelledCount: cancelled,
        capability: capability,
      );
    }

    final desired = await _desiredNotifications(
      capability: capability,
      preferences: resolved,
      now: now,
      horizon: horizon,
    );

    // 规则 2：逐类判断。被关掉的那一类按前缀取消，**不依赖"它是否出现在期望集合里"**——
    // 关闭的类别本来就不会生成期望项，用"差值"实现等于把两件事混成一件：只要任何一个
    // 生成分支忘了判开关，那条通知就会被当成"计划里没有它"而漏取消。
    //
    // 反过来也要小心：**不能**把"不在期望集合里"直接当成"该取消"。计划读不到（尚未生成）、
    // 或者某条固定日程刚好不在窗口里时，期望集合本来就不含它——那不是用户关了通知，
    // 而把它取消掉会让用户"关掉截止提醒"时顺手丢掉任务开始提醒。因此：
    //   · 类别关闭           → 取消（用户明确要求）
    //   · 类别开启但已不在期望集合 → 取消（它是过期事实：计划已改，这条提醒已无意义）
    //   · 类别开启且在期望集合   → 保留
    final cancelledCount = await _cancelPending((id) {
      final category = _categoryOf(id);
      if (category == null) return false;
      if (!_categoryEnabled(resolved, category)) return true;
      return !desired.containsKey(id);
    });

    for (final request in desired.values) {
      await notifications.scheduleOneShot(request);
    }

    // 周期目标提醒与另外四类走**同一次对账**（§5.2 最后一条）。它自己带内存去重，
    // 因此重复调用不会重复打扰；但它同样要在总开关关闭时一次都不评估。
    if (resolved.recurringGoalEnabled) {
      await evaluateRecurringGoal?.call();
    }

    return NotificationSyncResult(
      scheduledCount: desired.length,
      cancelledCount: cancelledCount,
      capability: capability,
    );
  }

  /// 取消当前待处理项里所有满足 [shouldCancel] 的通知，返回取消条数。
  Future<int> _cancelPending(bool Function(String id) shouldCancel) async {
    var cancelled = 0;
    for (final item in await notifications.pendingNotifications()) {
      if (!shouldCancel(item.id)) continue;
      await notifications.cancel(item.id);
      cancelled++;
    }
    return cancelled;
  }

  /// 向后兼容的别名：等价于 [reconcile]。
  ///
  /// 保留它是因为 `notification_kinds_test` 等既有用例按这个名字驱动同一条链，而那条链
  /// 现在只有 `reconcile` 一个实现——改名不该让测试去测"另一个函数"。**新代码不要再调用
  /// 它**：设置保存、启动、计划应用都走 `reconcile`，那是规范 §5.2 指定的唯一入口。
  @Deprecated('Use reconcile() instead. Kept only for existing call sites.')
  Future<NotificationSyncResult> syncNextSevenDays() => reconcile();

  /// 提醒时刻若已过去，改为"尽快提醒"，而不是静默丢弃。
  ///
  /// 提前时间可能已经过去：默认的截止提前时间是 24 小时，因此一个 20 小时后到期
  /// 的任务，其提醒时刻落在过去；程序一段时间未运行也会造成同样情况。此时直接跳过
  /// 会让用户完全收不到提醒，与 FR-NOTIFY-01 相悖。
  ///
  /// 加一分钟是为了让时刻确实落在未来——不接受过去时刻的调度器会拒收。
  DateTime _clampToFuture(DateTime scheduledAtUtc, DateTime nowUtc) =>
      scheduledAtUtc.isBefore(nowUtc)
      ? nowUtc.add(const Duration(minutes: 1))
      : scheduledAtUtc;

  DateTime _delayPastQuietHours(
    DateTime instantUtc,
    LocalTimeRange quietHours,
  ) {
    final local = zones.toLocal(instantUtc, timeZoneId);
    final minute = local.hour * 60 + local.minute;
    final isQuiet = quietHours.crossesMidnight
        ? minute >= quietHours.startMinute || minute < quietHours.endMinute
        : minute >= quietHours.startMinute && minute < quietHours.endMinute;
    if (!isQuiet) return instantUtc;

    var dayOffset = 0;
    if (quietHours.crossesMidnight && minute >= quietHours.startMinute) {
      dayOffset = 1;
    }
    var endMinute = quietHours.endMinute;
    if (endMinute == LocalTimeRange.minutesPerDay) {
      dayOffset++;
      endMinute = 0;
    }
    final endDate = DateTime(local.year, local.month, local.day + dayOffset);
    return zones.localDateTimeToUtc(endDate, endMinute, timeZoneId);
  }
}
