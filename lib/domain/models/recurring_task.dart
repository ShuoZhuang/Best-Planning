import 'dart:math' as math;

import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 周期目标的**安排节奏**（路线图 §3.3）。
///
/// 四个值不是"四种排程算法"，而是**同一个排程器收到的四种不同输入**（见 §3.4：
/// 不写第二个排程器）。它们的差别最终只落在两处：
/// - **截止时间**：`even`／`early`／`deadlineWeighted` 只改实例的 `dueAtUtc`，
///   让引擎自带的"截止压力"（`PressureCalculator`）算出不同的本周推进量；
/// - **允许星期**：`selectedWeekdays` 只把候选限制在模板的星期掩码里。
enum RecurringPace {
  /// 均匀分布（默认）：按"本周剩余容量"摊平，不允许一次把 180 分钟堆到周日。
  even,

  /// 尽早完成：把截止时间提前，让推进量在窗口前段就吃满。
  early,

  /// 临近截止：把截止时间放到周期末尾，推进量往后压。
  deadlineWeighted,

  /// 仅指定星期：只允许落在 [RecurringTaskTemplate.allowedWeekdaysMask] 指定的星期。
  selectedWeekdays,
}

/// 某一周的周期实例状态（路线图 §4.2）。
///
/// **只有用户或结算能写入这四个值**：完成分钟是**算出来的**（从 `time_entries`
/// 汇总），没有一个"进度"字段——否则同一件事会有两个事实来源。
enum RecurringCycleStatus {
  open,
  met,
  missed,
  skipped;

  /// 已定案：达标、未达标或已跳过。
  ///
  /// 与 `TaskStatus.isClosed` 同型。**逐周结算之后就不该再被改动**：详情页据此隐藏
  /// "跳过这一周""手动补记"这类只对进行中的一周有意义的入口；服务层也据此保证
  /// "上周的结果保留"（Global Constraints）。
  bool get isSettled => this != RecurringCycleStatus.open;
}

/// 模板状态。`archived` 是"停止以后生成"（路线图 §3.3），不是删除：
/// 已经生成过的周期实例仍要能从历史里读回来，因此模板必须留下。
enum RecurringTemplateStatus { active, archived }

/// 删除与编辑的作用范围（路线图 §3.3 最后一条）。
enum RecurringEditScope {
  /// 仅本周：只动当前周期实例，模板不变。
  thisCycle,

  /// 从下周开始：动模板，当前周期实例保持原样。
  fromNextWeek,

  /// 整个周期：模板与当前周期实例一起动。
  entireSeries,
}

const int recurringAllWeekdaysMask = 0x7F;

/// 内部排程载体的稳定 id 前缀；普通任务列表/搜索必须排除，深链应转向周期详情。
const String recurringTransportTaskPrefix = 'recurring:';

bool isRecurringTransportTaskId(String id) =>
    id.startsWith(recurringTransportTaskPrefix);

/// 七个星期全部允许的掩码，按 `DateTime.monday`（1）到 `DateTime.sunday`（7）编号。
bool isWeekdayAllowed(int mask, int weekday) {
  if (weekday < DateTime.monday || weekday > DateTime.sunday) {
    throw ArgumentError.value(weekday, 'weekday', 'Must be 1..7.');
  }
  return mask & (1 << (weekday - 1)) != 0;
}

int weekdayMaskOf(Iterable<int> weekdays) {
  var mask = 0;
  for (final weekday in weekdays) {
    if (weekday < DateTime.monday || weekday > DateTime.sunday) {
      throw ArgumentError.value(weekday, 'weekday', 'Must be 1..7.');
    }
    mask |= 1 << (weekday - 1);
  }
  return mask;
}

/// 把一个 `DateTime` 截成**本地日期**（时分秒归零）。
///
/// 周期目标的所有日期字段都用它：`YYYY-MM-DD` 语义的日期**不能**用
/// `add(Duration(days: 1))` 推进（本仓库已被夏令时咬过一次，见
/// `scheduling/protected_time_expander.dart` 的 `_shiftDate`）。
DateTime localDateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 按日历日位移，而不是绝对时间加法。
DateTime shiftLocalDate(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

String formatLocalDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime parseLocalDate(String value) {
  final parts = value.split('-');
  if (parts.length != 3) {
    throw ArgumentError.value(value, 'value', 'Expected YYYY-MM-DD.');
  }
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) {
    throw ArgumentError.value(value, 'value', 'Expected YYYY-MM-DD.');
  }
  final parsed = DateTime(year, month, day);
  // 拒绝 2026-02-30 这类"能被 DateTime 悄悄归一化"的输入：日期是周期主键的一部分，
  // 归一化会让两条不同的键指向同一天，唯一约束就守不住了。
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    throw ArgumentError.value(value, 'value', 'Not a real calendar date.');
  }
  return parsed;
}

/// 周期目标模板（路线图 §4.1）。
///
/// 它只描述"每周要做多少、什么时候可以做"，**不描述某一个具体星期**；具体某一周的
/// 事实落在 [RecurringTaskCycle] 与那个普通任务上。这样"改模板"与"改这一周"是两个
/// 互不干扰的动作，正是 §3.3 要求的"仅本周 / 从下周开始 / 整个周期"三种范围的根基。
final class RecurringTaskTemplate {
  RecurringTaskTemplate({
    required this.id,
    required String title,
    String notes = '',
    this.areaId,
    this.projectId,
    required this.targetMinutes,
    this.priority = TaskPriority.medium,
    this.energyLevel = TaskEnergyLevel.medium,
    this.splitMode = TaskSplitMode.splittable,
    this.minChunkMinutes = 25,
    this.maxChunkMinutes = 90,
    this.preferredStartMinute,
    this.preferredEndMinute,
    this.pace = RecurringPace.even,
    this.allowedWeekdaysMask = recurringAllWeekdaysMask,
    this.carryOverUnfinished = false,
    required DateTime startsOnLocalDate,
    DateTime? endsOnLocalDate,
    DateTime? pausedUntilLocalDate,
    required this.timeZoneId,
    this.status = RecurringTemplateStatus.active,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : title = title.trim(),
       notes = notes.trim(),
       startsOnLocalDate = localDateOnly(startsOnLocalDate),
       endsOnLocalDate = endsOnLocalDate == null
           ? null
           : localDateOnly(endsOnLocalDate),
       pausedUntilLocalDate = pausedUntilLocalDate == null
           ? null
           : localDateOnly(pausedUntilLocalDate) {
    if (this.title.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Cannot be empty.');
    }
    if (targetMinutes <= 0) {
      throw ArgumentError.value(
        targetMinutes,
        'targetMinutes',
        'Must be positive.',
      );
    }
    if (minChunkMinutes <= 0) {
      throw ArgumentError.value(
        minChunkMinutes,
        'minChunkMinutes',
        'Must be positive.',
      );
    }
    if (maxChunkMinutes < minChunkMinutes) {
      throw ArgumentError('minChunkMinutes cannot exceed maxChunkMinutes.');
    }
    // 期望时段**成对出现**（§4.1）。只给一端意味着"每天从 20:00 到 ???"，
    // 排程器只能猜另一端；宁可在这里拒绝，也不要在排程里编一个钟点。
    if ((preferredStartMinute == null) != (preferredEndMinute == null)) {
      throw ArgumentError(
        'preferredStartMinute and preferredEndMinute must be set together.',
      );
    }
    if (preferredStartMinute != null) {
      LocalTimeRange(
        startMinute: preferredStartMinute!,
        endMinute: preferredEndMinute!,
      );
    }
    if (allowedWeekdaysMask <= 0 ||
        allowedWeekdaysMask & ~recurringAllWeekdaysMask != 0) {
      throw ArgumentError.value(
        allowedWeekdaysMask,
        'allowedWeekdaysMask',
        'Must be a non-empty 7-bit weekday mask.',
      );
    }
    final end = this.endsOnLocalDate;
    if (end != null && end.isBefore(this.startsOnLocalDate)) {
      throw ArgumentError.value(
        endsOnLocalDate,
        'endsOnLocalDate',
        'Must not precede startsOnLocalDate.',
      );
    }
    if (timeZoneId.trim().isEmpty) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId', 'Cannot be empty.');
    }
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  static const Object _unset = Object();

  final EntityId id;
  final String title;
  final String notes;
  final EntityId? areaId;
  final EntityId? projectId;
  final int targetMinutes;
  final TaskPriority priority;
  final TaskEnergyLevel energyLevel;
  final TaskSplitMode splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;
  final int? preferredStartMinute;
  final int? preferredEndMinute;
  final RecurringPace pace;
  final int allowedWeekdaysMask;
  final bool carryOverUnfinished;
  final DateTime startsOnLocalDate;
  final DateTime? endsOnLocalDate;
  final DateTime? pausedUntilLocalDate;
  final String timeZoneId;
  final RecurringTemplateStatus status;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  /// 期望时段的领域表示；两列都为空时返回 `null`（即"没有表达偏好"）。
  LocalTimeRange? get preferredWindow =>
      preferredStartMinute == null || preferredEndMinute == null
      ? null
      : LocalTimeRange(
          startMinute: preferredStartMinute!,
          endMinute: preferredEndMinute!,
        );

  List<int> get allowedWeekdays => [
    for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++)
      if (isWeekdayAllowed(allowedWeekdaysMask, weekday)) weekday,
  ];

  /// 该模板在 [periodStartLocalDate] 这一周是否应当生成实例。
  ///
  /// 三条都不满足即"不生成"：**已归档**（用户点了"停止以后生成"）、**还没到开始日**、
  /// **已过结束日**。暂停单独用 [isPausedOn] 判断——暂停有到期日，是**可恢复**的，
  /// 与"结束"不是同一件事（§3.3）。
  bool isActiveOn(DateTime periodStartLocalDate) {
    if (status != RecurringTemplateStatus.active) return false;
    final start = startsOnLocalDate;
    if (periodStartLocalDate.isBefore(start)) return false;
    final end = endsOnLocalDate;
    if (end != null && periodStartLocalDate.isAfter(end)) return false;
    return true;
  }

  /// 暂停是否在 [localDate]（通常是周期开始日）仍然生效。
  ///
  /// 口径：**暂停到某日**表示"这一天（含）之前都不生成"，因此暂停到 10-19 时，
  /// 10-19 那一周不生成，10-12 那一周也不生成；10-20 是周四、仍属于 10-19 那一周，
  /// 要到 **10-26 那一周**才恢复。这看起来"多停了一周"，但它是唯一自洽的读法：周期目标
  /// 的生成单位是**整周**，若只看周一那一天，"暂停到周三"就没有任何意义——那一周要么整体
  /// 生成、要么整体不生成，不存在"停半周"。用户要精确到天控制时，用「仅指定星期」。
  bool isPausedOn(DateTime localDate) {
    final until = pausedUntilLocalDate;
    if (until == null) return false;
    return !localDate.isAfter(until);
  }

  RecurringTaskTemplate copyWith({
    EntityId? id,
    String? title,
    String? notes,
    Object? areaId = _unset,
    Object? projectId = _unset,
    int? targetMinutes,
    TaskPriority? priority,
    TaskEnergyLevel? energyLevel,
    TaskSplitMode? splitMode,
    int? minChunkMinutes,
    int? maxChunkMinutes,
    Object? preferredStartMinute = _unset,
    Object? preferredEndMinute = _unset,
    RecurringPace? pace,
    int? allowedWeekdaysMask,
    bool? carryOverUnfinished,
    DateTime? startsOnLocalDate,
    Object? endsOnLocalDate = _unset,
    Object? pausedUntilLocalDate = _unset,
    String? timeZoneId,
    RecurringTemplateStatus? status,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
  }) => RecurringTaskTemplate(
    id: id ?? this.id,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    areaId: identical(areaId, _unset) ? this.areaId : areaId as EntityId?,
    projectId: identical(projectId, _unset)
        ? this.projectId
        : projectId as EntityId?,
    targetMinutes: targetMinutes ?? this.targetMinutes,
    priority: priority ?? this.priority,
    energyLevel: energyLevel ?? this.energyLevel,
    splitMode: splitMode ?? this.splitMode,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
    preferredStartMinute: identical(preferredStartMinute, _unset)
        ? this.preferredStartMinute
        : preferredStartMinute as int?,
    preferredEndMinute: identical(preferredEndMinute, _unset)
        ? this.preferredEndMinute
        : preferredEndMinute as int?,
    pace: pace ?? this.pace,
    allowedWeekdaysMask: allowedWeekdaysMask ?? this.allowedWeekdaysMask,
    carryOverUnfinished: carryOverUnfinished ?? this.carryOverUnfinished,
    startsOnLocalDate: startsOnLocalDate ?? this.startsOnLocalDate,
    endsOnLocalDate: identical(endsOnLocalDate, _unset)
        ? this.endsOnLocalDate
        : endsOnLocalDate as DateTime?,
    pausedUntilLocalDate: identical(pausedUntilLocalDate, _unset)
        ? this.pausedUntilLocalDate
        : pausedUntilLocalDate as DateTime?,
    timeZoneId: timeZoneId ?? this.timeZoneId,
    status: status ?? this.status,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

/// 某一周的周期实例（路线图 §4.2）。
///
/// 唯一键是 `(templateId, periodStartLocalDate)`——**这就是"连续启动十次只有一个实例"
/// 的实现依据**：让数据库而不是让某一段启动代码去保证唯一性。
final class RecurringTaskCycle {
  RecurringTaskCycle({
    required this.templateId,
    required DateTime periodStartLocalDate,
    required this.taskId,
    required this.baseTargetMinutes,
    this.carryInMinutes = 0,
    this.status = RecurringCycleStatus.open,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : periodStartLocalDate = localDateOnly(periodStartLocalDate) {
    if (baseTargetMinutes <= 0) {
      throw ArgumentError.value(
        baseTargetMinutes,
        'baseTargetMinutes',
        'Must be positive.',
      );
    }
    if (carryInMinutes < 0) {
      throw ArgumentError.value(
        carryInMinutes,
        'carryInMinutes',
        'Must not be negative.',
      );
    }
    // 周期开始日必须是**本地周一**。主键是 `(模板, 这一周)`，若允许任意日期，
    // 同一周就能被写成两个不同的键，"一周一个实例"立刻失效。
    if (periodStartLocalDate.weekday != DateTime.monday) {
      throw ArgumentError.value(
        periodStartLocalDate,
        'periodStartLocalDate',
        'Must be a Monday.',
      );
    }
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final EntityId templateId;
  final DateTime periodStartLocalDate;
  final EntityId taskId;
  final int baseTargetMinutes;
  final int carryInMinutes;
  final RecurringCycleStatus status;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  /// 本周的有效目标＝模板目标快照 ＋ 上周结转。
  int get effectiveTargetMinutes => baseTargetMinutes + carryInMinutes;

  RecurringTaskCycle copyWith({
    EntityId? templateId,
    DateTime? periodStartLocalDate,
    EntityId? taskId,
    int? baseTargetMinutes,
    int? carryInMinutes,
    RecurringCycleStatus? status,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
  }) => RecurringTaskCycle(
    templateId: templateId ?? this.templateId,
    periodStartLocalDate: periodStartLocalDate ?? this.periodStartLocalDate,
    taskId: taskId ?? this.taskId,
    baseTargetMinutes: baseTargetMinutes ?? this.baseTargetMinutes,
    carryInMinutes: carryInMinutes ?? this.carryInMinutes,
    status: status ?? this.status,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

/// 某一周的进度快照（路线图 §3.3）。
///
/// **完成分钟只有一个来源**：现有 `time_entries` 表。专注计时与手动补记写的是
/// **同一张表**，因此这里不需要（也刻意没有）第二套分钟事实——§4.2 的最后一句
/// 明确禁止那样做。
final class RecurringProgress {
  const RecurringProgress({
    required this.templateId,
    required this.periodStartLocalDate,
    required this.targetMinutes,
    required this.recordedMinutes,
    required this.remainingMinutes,
    required this.status,
    required this.carryInMinutes,
  });

  final EntityId templateId;
  final DateTime periodStartLocalDate;

  /// 本周有效目标（含结转）。合同：**永远不为 0**，因为模板目标必须为正。
  final int targetMinutes;

  /// 本周已记录分钟（专注 ＋ 手动补记）。
  final int recordedMinutes;

  /// 还差多少分钟。**超额时刻意落在 0 而不是负数**（§3.3："超过目标可以保留记录，
  /// 但排程剩余量最低为 0"）：排程器要拿它当"还需要安排多少"，负数会让推进量算错。
  /// 超额的那部分仍然如实留在 [recordedMinutes] 里，因此记录没有被抹掉。
  final int remainingMinutes;

  final RecurringCycleStatus status;
  final int carryInMinutes;

  bool get isMet => recordedMinutes >= targetMinutes;

  double get completionRatio => recordedMinutes / targetMinutes;

  int get overTargetMinutes => math.max(0, recordedMinutes - targetMinutes);
}

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) throw ArgumentError.value(value, name, 'Must be UTC.');
}
