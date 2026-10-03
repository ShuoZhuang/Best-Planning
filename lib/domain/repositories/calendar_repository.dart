import 'package:personal_planner/domain/models/calendar_event.dart';

abstract interface class CalendarRepository {
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  );
  Future<void> save(CalendarEvent event);
}

/// 能把重复规则与其模板日程作为一个原子操作保存的日历仓储。
abstract interface class RecurringCalendarRepository {
  Future<void> saveRecurring(CalendarEvent event, RecurrenceRule rule);
}
