import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/recurrence_membership.dart';

final class RecurrenceException {
  RecurrenceException.deleted({required this.localDate})
    : deleted = true,
      replacement = null,
      title = null,
      notes = null;

  RecurrenceException.replaced({
    required this.localDate,
    required TimeRange this.replacement,
    this.title,
    this.notes,
  }) : deleted = false;

  final DateTime localDate;
  final bool deleted;
  final TimeRange? replacement;

  /// 这一次的**标题覆盖**（课程与保护时间管理修复计划 Task 7 Step 1）。
  ///
  /// **为什么必须在这里**：改一次时间与改一次名字是两件独立的事。这个类此前只能换
  /// `TimeRange`，于是"仅本次改名"在结构上做不到——展开器只能拿锚点的标题套给每一次，
  /// 用户改了名之后看到的是"这一次还是旧名字"。日视图那个对话框因此只能把
  /// `item.title` 原样传回（计划 §1.2 记录的实际偏差）。
  ///
  /// 为空表示"沿用锚点标题"，与 `notes` 同一条约定。
  final String? title;

  /// 这一次的**备注覆盖**。为空表示沿用锚点备注。
  final String? notes;
}

final class RecurrenceOccurrence {
  const RecurrenceOccurrence({
    required this.ruleId,
    required this.localDate,
    required this.range,
    required this.isException,
    this.title,
    this.notes,
  });

  final String ruleId;
  final DateTime localDate;
  final TimeRange range;
  final bool isException;

  /// 这一次自己的标题；为空表示用锚点标题。
  final String? title;

  /// 这一次自己的备注；为空表示用锚点备注。
  final String? notes;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class RecurrenceExpander {
  const RecurrenceExpander(this._zones);

  final TimeZoneDatabase _zones;

  List<RecurrenceOccurrence> expand(
    RecurrenceRule rule,
    TimeRange window,
    List<RecurrenceException> exceptions,
  ) {
    final startLocal = _zones.toLocal(window.startUtc, rule.timeZoneId);
    final endLocal = _zones.toLocal(window.endUtc, rule.timeZoneId);
    var cursor = _dateOnly(startLocal).subtract(const Duration(days: 1));
    final firstValid = _dateOnly(rule.validFromLocalDate);
    if (cursor.isBefore(firstValid)) cursor = firstValid;
    final lastWindowDate = _dateOnly(endLocal).add(const Duration(days: 1));
    final lastValid = rule.validUntilLocalDate == null
        ? lastWindowDate
        : _dateOnly(rule.validUntilLocalDate!);
    final effectiveEnd = lastValid.isBefore(lastWindowDate)
        ? lastValid
        : lastWindowDate;

    final exceptionsByDate = <String, RecurrenceException>{
      for (final exception in exceptions)
        _dateKey(exception.localDate): exception,
    };
    final occurrences = <RecurrenceOccurrence>[];

    while (!cursor.isAfter(effectiveEnd)) {
      // **成员判定只有一个实现**（计划 §2.4）：星期、有效期与单双周全部由
      // `recurrenceIncludesLocalDate()` 回答。这里此前内联着一份等价的
      // `_matchesIntervalWeek`，而课程编辑的例外清理又写了第三份——两份公式一旦漂开，
      // 用户就会看到"预览说保留、保存却删了"（E1–E4）。
      if (recurrenceIncludesLocalDate(rule, cursor)) {
        final exception = exceptionsByDate[_dateKey(cursor)];
        if (exception?.deleted == true) {
          cursor = cursor.add(const Duration(days: 1));
          continue;
        }

        final range = exception?.replacement ?? _regularRange(rule, cursor);
        if (range.overlaps(window)) {
          occurrences.add(
            RecurrenceOccurrence(
              ruleId: rule.id,
              localDate: cursor,
              range: range,
              isException: exception != null,
              // **这一次自己的标题与备注**（Task 7 Step 1）：为空时调用方沿用锚点的。
              title: exception?.title,
              notes: exception?.notes,
            ),
          );
        }
      }
      cursor = cursor.add(const Duration(days: 1));
    }

    occurrences.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    return List.unmodifiable(occurrences);
  }

  TimeRange _regularRange(RecurrenceRule rule, DateTime localDate) {
    final startUtc = _zones.localDateTimeToUtc(
      localDate,
      rule.localStartMinute,
      rule.timeZoneId,
    );
    return TimeRange(
      startUtc: startUtc,
      endUtc: startUtc.add(Duration(minutes: rule.durationMinutes)),
    );
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
