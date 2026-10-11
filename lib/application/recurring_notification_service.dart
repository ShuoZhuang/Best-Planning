// 周期目标提醒（路线图 §3.5、§11 Task 9）。
//
// **这个文件解决的是"提醒要么准时且只来一次，要么干脆别来"**。提醒的价值全在这一点上：
// 早一天没用，重复三次会让用户关掉通知——那之后就再也收不到任何提醒了。因此实现里有两件
// 事是刻意的：
//
// 1. **去重键是 `(templateId, periodStart, kind)`**（§11 Task 9 Step 3 给定的形状）。
//    程序每次启动都会评估一遍，去掉重就会每次启动都通知一次。
// 2. **免打扰是"推迟"而不是"丢弃"**（§3.5 最后一句）。丢了这条提醒，用户就永远不知道
//    这一周还差多少；推两个小时则是可以接受的代价。
//
// 四条规则（§3.5）分别对应三个 [RecurringReminderKind]：
//   · 周四结束前低于 50%      → [RecurringReminderKind.thursdayProgress]
//   · 距结束不足 24 小时有缺口 → [RecurringReminderKind.deadlineGap]
//   · 排程容量不足            → [RecurringReminderKind.capacityShortfall]
//
// **为什么容量不足单独一类而不是并进上面两类**：它的紧迫性与周期进度无关（周三就可能发现），
// 而且它是一个"可处理"的问题——用户可以调低目标、放宽时段。并进"低于 50%"会让一条本该立刻
// 出现的提示被压到周四。
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';

/// 一次评估里，某个模板本周的情况。
///
/// **刻意只带提醒需要的那几个数**，而不是直接吃 `RecurringProgress`：提醒层不该认识模板的
/// 全部字段（拆分方式、片段长度、期望时段都与提醒无关），只认识"目标、已记录、状态、缺口"。
/// 这样它的输入可以来自任何地方（服务、离线快照、测试），而不必先装配完整模板。
final class RecurringNotificationCandidate {
  const RecurringNotificationCandidate({
    required this.templateId,
    required this.title,
    required this.targetMinutes,
    required this.recordedMinutes,
    required this.remainingMinutes,
    required this.status,
    this.schedulingShortfallMinutes = 0,
  });

  final String templateId;
  final String title;
  final int targetMinutes;
  final int recordedMinutes;

  /// 还差多少分钟（超额时为 0，与 `RecurringProgress` 同一口径）。
  final int remainingMinutes;

  final RecurringCycleStatus status;

  /// 排程算出来的容量缺口（分钟）。为 0 表示容量够。
  ///
  /// 由 Task 8 的 `CapacityShortfall` 提供；这条提醒不自己算容量——那需要排程输入，
  /// 而提醒层不该为了发一条通知去跑一遍排程。
  final int schedulingShortfallMinutes;

  double get completionRatio =>
      targetMinutes <= 0 ? 1 : recordedMinutes / targetMinutes;

  RecurringNotificationCandidate copyWith({
    int? recordedMinutes,
    int? remainingMinutes,
    RecurringCycleStatus? status,
    int? schedulingShortfallMinutes,
  }) => RecurringNotificationCandidate(
    templateId: templateId,
    title: title,
    targetMinutes: targetMinutes,
    recordedMinutes: recordedMinutes ?? this.recordedMinutes,
    remainingMinutes: remainingMinutes ?? this.remainingMinutes,
    status: status ?? this.status,
    schedulingShortfallMinutes:
        schedulingShortfallMinutes ?? this.schedulingShortfallMinutes,
  );
}

/// 提醒层需要的周期来源。
///
/// **只读两个东西**：现在属于哪一周，以及那一周里各模板的情况。生成、结算、跳过都不经过
/// 这里——那是 `RecurringTaskService` 的事。分开的后果是提醒层可以在**不写任何数据**的前提下
/// 被测试驱动，这一点在"重复评估只发一次"的断言里很关键。
abstract interface class RecurringCycleReader {
  /// 包含 [nowUtc] 的那一周。
  WeeklyPeriod periodContaining(DateTime nowUtc);

  /// 那一周里**需要被提醒考虑**的模板。暂停与已归档的模板不在这里面。
  Future<List<RecurringNotificationCandidate>> candidatesForWeek(
    WeeklyPeriod period,
  );
}

/// 三类提醒。**这是去重键的一部分**，因此名字与取值范围要稳定。
enum RecurringReminderKind { thursdayProgress, deadlineGap, capacityShortfall }

final class RecurringNotificationService {
  RecurringNotificationService({
    required this.cycles,
    required this.notifications,
    required this.clock,
    required this.zones,
    required this.timeZoneId,
    this.quietHoursFor,
    this.enabledFor,
  });

  final RecurringCycleReader cycles;
  final NotificationPort notifications;
  final Clock clock;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  /// 读取某个本地日期生效的免打扰时段；为空（或返回 `null`）表示没有免打扰。
  ///
  /// 注入成回调而不是直接吃 `SettingsService`：免打扰是**按日生效**的
  /// （`settings.resolveForDate`），提醒层只需要"这一天有没有、是哪一段"。
  final Future<LocalTimeRange?> Function(DateTime localDate)? quietHoursFor;

  /// 周期目标提醒的开关来源（§3.5、§11 Task 9）。
  ///
  /// 为空时视为**开启**：这个服务被放进组合根就意味着有人要用它，而"没注入开关"不该
  /// 悄悄变成"用户收不到提醒"。真实值由设置页写进 `NotificationPreferences`。
  final Future<bool> Function()? enabledFor;

  /// 已经通知过的去重键。**只增不减**：一个进程内的评估次数是有限的，而"新的一周"
  /// 自然会带新的 `periodStart`，因此不需要清理策略。
  final Set<String> _sent = {};

  /// 这个服务排入的提醒 id 前缀。
  ///
  /// **公开**：总开关关闭时，`NotificationService.reconcile` 必须能按前缀把这一类
  /// 已经排进系统的待处理项也取消掉（设计规范 §5.2："周期目标提醒与其他四类走同一保存、
  /// 加载和取消链"）。写死两份字符串迟早会漂。
  static const managedPrefix = 'planner.recurring.';

  static const _managedPrefix = managedPrefix;

  /// 评估一次：该提醒的都发出去，已经发过的不再发。
  ///
  /// 每次启动、每次周期数据变化后调用都可以——去重保证了它不会重复打扰用户。
  Future<void> evaluate() async {
    final capability = await notifications.capability();
    if (!capability.canSchedule) return;
    // 用户在设置里关掉之后**一次都不该评估**：评估本身要读周期数据，而"关掉提醒"
    // 在用户心里的意思是"别再为这件事打扰我"，不是一个"算了但不显示"的开关。
    if (enabledFor case final enabled?) {
      if (!await enabled()) return;
    }

    final now = clock.nowUtc();
    final period = cycles.periodContaining(now);
    final candidates = await cycles.candidatesForWeek(period);
    for (final candidate in candidates) {
      await _evaluateCandidate(candidate, period, now);
    }
  }

  Future<void> _evaluateCandidate(
    RecurringNotificationCandidate candidate,
    WeeklyPeriod period,
    DateTime nowUtc,
  ) async {
    final kind = _reminderFor(candidate, period, nowUtc);
    if (kind == null) return;

    final key = _dedupeKey(candidate, period, kind);
    if (!_sent.add(key)) return;

    var scheduledAt = nowUtc;
    final quiet = await _quietHoursAt(nowUtc);
    if (quiet != null) {
      scheduledAt = _delayPastQuietHours(scheduledAt, quiet);
    }

    await notifications.scheduleOneShot(
      NotificationRequest(
        id:
            '$_managedPrefix${kind.name}.${candidate.templateId}.'
            '${_localKey(period.startLocalDate)}',
        scheduledAtUtc: scheduledAt,
        title: _title(candidate, kind),
        body: _body(candidate, kind),
        payload: NotificationPayload(
          notificationId: '$_managedPrefix${kind.name}.${candidate.templateId}',
          kind: NotificationKind.recurringGoal,
          entityId: candidate.templateId,
          // 落到那个周期的详情：用户看到"还差 108 分钟"之后，下一步就是打开它。
          route: '/tasks/recurring/${candidate.templateId}',
        ).encode(),
      ),
    );
  }

  /// 这一条候选**现在**该发哪一类提醒；不该发时返回 `null`。
  ///
  /// 判定顺序是刻意的：容量不足最急（而且它是一个可处理的动作），其次"快到期"，
  /// 最后才是"周四了还不到一半"。同一次评估里三类不会同时发——用户不需要一次收三条。
  RecurringReminderKind? _reminderFor(
    RecurringNotificationCandidate candidate,
    WeeklyPeriod period,
    DateTime nowUtc,
  ) {
    // 达标、跳过、未达标（已结算）都不再提醒（§3.5 第 4 条）。
    // `missed` 是"这一周已经结束且没做到"——提醒它已经没有意义。
    if (candidate.status != RecurringCycleStatus.open) return null;

    if (candidate.schedulingShortfallMinutes > 0) {
      return RecurringReminderKind.capacityShortfall;
    }

    final remaining = period.endUtc.difference(nowUtc);
    final hasGap = candidate.remainingMinutes > 0;
    if (hasGap && remaining <= const Duration(hours: 24)) {
      return RecurringReminderKind.deadlineGap;
    }

    // "周四结束前"：本地时间周四整天都算，到周五 00:00 为止。
    // 用本地日期判断而不是 UTC——周界本身就是本地口径，混用会让东八区用户在周四深夜
    // 收到一条本该在周五出现的提醒。
    final local = zones.toLocal(nowUtc, timeZoneId);
    if (local.weekday == DateTime.thursday && candidate.completionRatio < 0.5) {
      return RecurringReminderKind.thursdayProgress;
    }
    return null;
  }

  String _dedupeKey(
    RecurringNotificationCandidate candidate,
    WeeklyPeriod period,
    RecurringReminderKind kind,
  ) =>
      '${candidate.templateId}|${_localKey(period.startLocalDate)}|'
      '${kind.name}';

  String _localKey(DateTime localDate) =>
      '${localDate.year}-${localDate.month}-${localDate.day}';

  String _title(
    RecurringNotificationCandidate candidate,
    RecurringReminderKind kind,
  ) => switch (kind) {
    RecurringReminderKind.thursdayProgress => '「${candidate.title}」这周还差得多',
    RecurringReminderKind.deadlineGap => '「${candidate.title}」这周快结束了',
    RecurringReminderKind.capacityShortfall => '「${candidate.title}」排不下',
  };

  String _body(
    RecurringNotificationCandidate candidate,
    RecurringReminderKind kind,
  ) => switch (kind) {
    RecurringReminderKind.thursdayProgress =>
      '本周已完成 ${candidate.recordedMinutes} / ${candidate.targetMinutes} 分钟，'
          '还差 ${candidate.remainingMinutes} 分钟。',
    RecurringReminderKind.deadlineGap =>
      '本周还剩不到一天，还差 ${candidate.remainingMinutes} 分钟。',
    RecurringReminderKind.capacityShortfall =>
      '本周可安排的时间比目标少 ${candidate.schedulingShortfallMinutes} 分钟。'
          '可以调低本周目标、放宽期望时段，或允许本周不完全安排。',
  };

  Future<LocalTimeRange?> _quietHoursAt(DateTime instantUtc) async {
    final resolver = quietHoursFor;
    if (resolver == null) return null;
    final local = zones.toLocal(instantUtc, timeZoneId);
    return resolver(DateTime(local.year, local.month, local.day));
  }

  /// 把一个落在免打扰里的时刻推到窗口之外。
  ///
  /// 跨午夜的窗口（22:00–07:00）必须先判断"现在在不在里面"：`LocalTimeRange`
  /// 的 `start < end` 不成立时不能直接拿 `endMinute` 当"今天几点结束"。
  DateTime _delayPastQuietHours(DateTime instantUtc, LocalTimeRange quiet) {
    final local = zones.toLocal(instantUtc, timeZoneId);
    final minute = local.hour * 60 + local.minute;
    if (!_contains(quiet, minute)) return instantUtc;

    // 推到窗口结束的那一分钟：今天若已经过了结束点，就是明天。
    final crossesMidnight = quiet.startMinute > quiet.endMinute;
    final endsToday = crossesMidnight ? minute < quiet.endMinute : false;
    final targetDate = endsToday || !crossesMidnight
        ? DateTime(local.year, local.month, local.day)
        : DateTime(local.year, local.month, local.day + 1);
    final targetMinute = quiet.endMinute;
    return zones.localDateTimeToUtc(
      DateTime(targetDate.year, targetDate.month, targetDate.day),
      targetMinute,
      timeZoneId,
    );
  }

  static bool _contains(LocalTimeRange range, int minute) {
    if (range.startMinute == range.endMinute) return false;
    if (range.startMinute < range.endMinute) {
      return minute >= range.startMinute && minute < range.endMinute;
    }
    // 跨午夜：22:00–07:00 意味着 [22:00, 24:00) ∪ [00:00, 07:00)。
    return minute >= range.startMinute || minute < range.endMinute;
  }
}
