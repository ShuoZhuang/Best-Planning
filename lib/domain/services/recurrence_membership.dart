import 'package:personal_planner/domain/models/calendar_event.dart';

/// **一个本地日历日是否属于这条规则**（计划 §2.4，C22／C23）。
///
/// ## 为什么必须只有一个实现
///
/// 这个判据此前**存在两份**，而且不同步：
///
/// - `RecurrenceExpander._matchesIntervalWeek()` 决定"这一次到底会不会出现"；
/// - 课程编辑的例外清理按**另一套**条件决定"这条逐次调整还该不该留着"。
///
/// 两套公式一旦漂开，用户就会看到"预览说会删 2 条、保存删了 1 条"，或者更糟：
/// 预览说保留、保存真删了——而预览是他按下确认**唯一**的依据（计划 §2.5）。
/// 因此本函数是唯一实现，展开器与例外清理都必须调用它。
///
/// ## 判定顺序（不可重排）
///
/// 1. 取 date-only：`localDate` 可能带时刻，而规则只按日历日生效；
/// 2. 不早于 `validFromLocalDate`；
/// 3. 不晚于非空 `validUntilLocalDate`（闭区间 `[from, until]`）；
/// 4. 星期属于 `rule.weekdays`；
/// 5. `candidateMonday - anchorMonday` 的**周偏移非负且能被 `intervalWeeks` 整除**。
///
/// ## 它**不做**时区换算
///
/// [localDate] 必须已经是**规则自己时区里的本地日期**。把 `utcDate` 传进来会在
/// Asia/Shanghai 的 00:00–07:59 把课程落到前一天（计划 §1.4／C10），
/// 而那种错误只在清晨的课上显形。调用方在传入之前用 `TimeZoneDatabase.toLocal()`
/// 完成换算——见 `DriftCalendarRepository` 的例外清理与
/// `DriftTimetableImportRepository`。
///
/// ## 周偏移用 UTC 零点做算术，不用本地时刻相减
///
/// 两个本地零点之间在夏令时切换那一周只有 167 或 169 小时，`difference().inDays`
/// 会得到 6 或 7——整除判定于是随机地把那一周算进／算错一个间隔（TZ2）。
/// 把两个日历日映射到 `DateTime.utc` 再相减，差值恒为整数天。
bool recurrenceIncludesLocalDate(RecurrenceRule rule, DateTime localDate) {
  final candidate = DateTime.utc(localDate.year, localDate.month, localDate.day);
  final first = DateTime.utc(
    rule.validFromLocalDate.year,
    rule.validFromLocalDate.month,
    rule.validFromLocalDate.day,
  );
  if (candidate.isBefore(first)) return false;

  final until = rule.validUntilLocalDate;
  if (until != null) {
    final last = DateTime.utc(until.year, until.month, until.day);
    if (candidate.isAfter(last)) return false;
  }

  if (!rule.weekdays.contains(candidate.weekday)) return false;

  final weekOffset =
      weekMondayUtc(candidate).difference(weekMondayUtc(first)).inDays ~/
      DateTime.daysPerWeek;
  return weekOffset >= 0 && weekOffset % rule.intervalWeeks == 0;
}

/// [value] 所在那一周的周一（**UTC 零点形式**，只用于周偏移算术）。
///
/// 公开它是为了让"周次成员"的判据在测试与展开器里可以逐值对照，而不是各自再写一份
/// `subtract(Duration(days: weekday - monday))`。
DateTime weekMondayUtc(DateTime value) {
  final date = DateTime.utc(value.year, value.month, value.day);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}
