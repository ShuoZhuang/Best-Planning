import 'package:personal_planner/domain/models/calendar_event.dart';

abstract interface class CalendarRepository {
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  );
  Future<void> save(CalendarEvent event);
}
