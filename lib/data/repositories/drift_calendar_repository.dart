import 'package:drift/drift.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart' as domain;
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/services/recurrence_expander.dart';

final class DriftCalendarRepository
    implements CalendarRepository, RecurringCalendarRepository {
  DriftCalendarRepository(this._database, {TimeZoneDatabase? zones})
    : _recurrence = RecurrenceExpander(zones ?? TimeZoneDatabase());

  final db.AppDatabase _database;
  final RecurrenceExpander _recurrence;

  @override
  Future<List<domain.CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    if (!startUtc.isUtc || !endUtc.isUtc || !endUtc.isAfter(startUtc)) {
      throw ArgumentError('A valid UTC query range is required.');
    }
    final query = _database.select(_database.calendarEvents)
      ..where(
        (row) =>
            row.recurrenceRuleId.isNull() &
            row.startAtUtc.isSmallerThanValue(endUtc.microsecondsSinceEpoch) &
            row.endAtUtc.isBiggerThanValue(startUtc.microsecondsSinceEpoch),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.startAtUtc)]);
    final result = [
      for (final row in await query.get())
        domain.CalendarOccurrence(
          eventId: row.id,
          title: row.title,
          range: TimeRange(
            startUtc: _instant(row.startAtUtc),
            endUtc: _instant(row.endAtUtc),
          ),
          locked: row.locked,
          areaId: row.areaId,
        ),
    ];

    final recurring = _database.select(_database.calendarEvents).join([
      innerJoin(
        _database.recurrenceRules,
        _database.recurrenceRules.id.equalsExp(
          _database.calendarEvents.recurrenceRuleId,
        ),
      ),
    ])..where(_database.calendarEvents.exceptionOfId.isNull());
    final window = TimeRange(startUtc: startUtc, endUtc: endUtc);
    for (final joined in await recurring.get()) {
      final event = joined.readTable(_database.calendarEvents);
      final stored = joined.readTable(_database.recurrenceRules);
      final rule = domain.RecurrenceRule(
        id: stored.id,
        weekdays: _weekdays(stored.weekdaysMask),
        localStartMinute: stored.localStartMinute,
        durationMinutes: stored.durationMinutes,
        validFromLocalDate: DateTime.parse(stored.validFromLocalDate),
        validUntilLocalDate: stored.validUntilLocalDate == null
            ? null
            : DateTime.parse(stored.validUntilLocalDate!),
        timeZoneId: stored.timeZoneId,
      );
      for (final occurrence in _recurrence.expand(rule, window, const [])) {
        result.add(
          domain.CalendarOccurrence(
            eventId: event.id,
            title: event.title,
            range: occurrence.range,
            locked: event.locked,
            areaId: event.areaId,
          ),
        );
      }
    }
    result.sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    return List.unmodifiable(result);
  }

  @override
  Future<void> saveRecurring(
    domain.CalendarEvent event,
    domain.RecurrenceRule rule,
  ) {
    if (event.recurrenceRuleId != rule.id) {
      throw ArgumentError('Event and recurrence rule ids must match.');
    }
    final modifiedAt = event.updatedAtUtc.microsecondsSinceEpoch;
    return _database.transaction(() async {
      await _database
          .into(_database.recurrenceRules)
          .insert(
            db.RecurrenceRulesCompanion(
              id: Value(rule.id),
              weekdaysMask: Value(_weekdaysMask(rule.weekdays)),
              localStartMinute: Value(rule.localStartMinute),
              durationMinutes: Value(rule.durationMinutes),
              validFromLocalDate: Value(_date(rule.validFromLocalDate)),
              validUntilLocalDate: Value(
                rule.validUntilLocalDate == null
                    ? null
                    : _date(rule.validUntilLocalDate!),
              ),
              timeZoneId: Value(rule.timeZoneId),
              createdAtUtc: Value(modifiedAt),
              updatedAtUtc: Value(modifiedAt),
            ),
            onConflict: DoUpdate(
              (old) => db.RecurrenceRulesCompanion(
                weekdaysMask: Value(_weekdaysMask(rule.weekdays)),
                localStartMinute: Value(rule.localStartMinute),
                durationMinutes: Value(rule.durationMinutes),
                validFromLocalDate: Value(_date(rule.validFromLocalDate)),
                validUntilLocalDate: Value(
                  rule.validUntilLocalDate == null
                      ? null
                      : _date(rule.validUntilLocalDate!),
                ),
                timeZoneId: Value(rule.timeZoneId),
                updatedAtUtc: Value(modifiedAt),
              ),
            ),
          );
      await save(event);
    });
  }

  @override
  Future<void> save(domain.CalendarEvent event) {
    final modifiedAt = event.updatedAtUtc.microsecondsSinceEpoch;
    return _database
        .into(_database.calendarEvents)
        .insert(
          db.CalendarEventsCompanion(
            id: Value(event.id),
            title: Value(event.title),
            startAtUtc: Value(event.startAtUtc.microsecondsSinceEpoch),
            endAtUtc: Value(event.endAtUtc.microsecondsSinceEpoch),
            timeZoneId: Value(event.timeZoneId),
            recurrenceRuleId: Value(event.recurrenceRuleId),
            exceptionOfId: Value(event.exceptionOfId),
            locked: Value(event.locked),
            areaId: Value(event.areaId),
            createdAtUtc: Value(modifiedAt),
            updatedAtUtc: Value(modifiedAt),
          ),
          // A brand new event is created and modified at the same instant. For an
          // existing one the conflict branch preserves the recorded creation time
          // and only advances the modification time (FR-DATA-08).
          onConflict: DoUpdate(
            (old) => db.CalendarEventsCompanion(
              title: Value(event.title),
              startAtUtc: Value(event.startAtUtc.microsecondsSinceEpoch),
              endAtUtc: Value(event.endAtUtc.microsecondsSinceEpoch),
              timeZoneId: Value(event.timeZoneId),
              recurrenceRuleId: Value(event.recurrenceRuleId),
              exceptionOfId: Value(event.exceptionOfId),
              locked: Value(event.locked),
              areaId: Value(event.areaId),
              updatedAtUtc: Value(modifiedAt),
            ),
          ),
        );
  }

  static DateTime _instant(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
}

Set<int> _weekdays(int mask) => {
  for (var day = DateTime.monday; day <= DateTime.sunday; day++)
    if (mask & (1 << (day - 1)) != 0) day,
};

int _weekdaysMask(Set<int> weekdays) =>
    weekdays.fold(0, (mask, day) => mask | (1 << (day - 1)));

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
