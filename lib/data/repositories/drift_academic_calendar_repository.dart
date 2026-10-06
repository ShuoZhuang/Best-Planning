import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/repositories/academic_calendar_repository.dart';

final class DriftAcademicCalendarRepository
    implements AcademicCalendarRepository {
  const DriftAcademicCalendarRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<List<AcademicTerm>> listTerms() async {
    final query = _database.select(_database.academicTerms)
      ..orderBy([
        (row) => OrderingTerm.desc(row.firstWeekMondayLocalDate),
        (row) => OrderingTerm.asc(row.name),
      ]);
    return (await query.get()).map(_toTerm).toList(growable: false);
  }

  @override
  Future<void> saveTerm(AcademicTerm term) => _database
      .into(_database.academicTerms)
      .insert(
        db.AcademicTermsCompanion(
          id: Value(term.id),
          name: Value(term.name),
          firstWeekMondayLocalDate: Value(_date(term.firstWeekMonday)),
          totalWeeks: Value(term.totalWeeks),
          timeZoneId: Value(term.timeZoneId),
          createdAtUtc: Value(term.createdAtUtc.microsecondsSinceEpoch),
          updatedAtUtc: Value(term.updatedAtUtc.microsecondsSinceEpoch),
        ),
        onConflict: DoUpdate(
          (old) => db.AcademicTermsCompanion(
            name: Value(term.name),
            firstWeekMondayLocalDate: Value(_date(term.firstWeekMonday)),
            totalWeeks: Value(term.totalWeeks),
            timeZoneId: Value(term.timeZoneId),
            updatedAtUtc: Value(term.updatedAtUtc.microsecondsSinceEpoch),
          ),
        ),
      );

  @override
  Future<List<PeriodTemplate>> listTemplates() async {
    final templates = await (_database.select(
      _database.periodTemplates,
    )..orderBy([(row) => OrderingTerm.asc(row.name)])).get();
    final entries = await (_database.select(
      _database.periodTemplateEntries,
    )..orderBy([(row) => OrderingTerm.asc(row.periodNumber)])).get();
    final byTemplate = <String, List<PeriodEntry>>{};
    for (final row in entries) {
      (byTemplate[row.templateId] ??= []).add(
        PeriodEntry(
          periodNumber: row.periodNumber,
          startMinute: row.startMinute,
          endMinute: row.endMinute,
        ),
      );
    }
    return [
      for (final row in templates)
        PeriodTemplate(
          id: row.id,
          name: row.name,
          isDefault: row.isDefault,
          entries: byTemplate[row.id] ?? const [],
          createdAtUtc: _instant(row.createdAtUtc),
          updatedAtUtc: _instant(row.updatedAtUtc),
        ),
    ];
  }

  @override
  Future<void> saveTemplate(
    PeriodTemplate template,
  ) => _database.transaction(() async {
    await _database
        .into(_database.periodTemplates)
        .insert(
          db.PeriodTemplatesCompanion(
            id: Value(template.id),
            name: Value(template.name),
            isDefault: Value(template.isDefault),
            createdAtUtc: Value(template.createdAtUtc.microsecondsSinceEpoch),
            updatedAtUtc: Value(template.updatedAtUtc.microsecondsSinceEpoch),
          ),
          onConflict: DoUpdate(
            (old) => db.PeriodTemplatesCompanion(
              name: Value(template.name),
              isDefault: Value(template.isDefault),
              updatedAtUtc: Value(template.updatedAtUtc.microsecondsSinceEpoch),
            ),
          ),
        );
    await (_database.delete(
      _database.periodTemplateEntries,
    )..where((row) => row.templateId.equals(template.id))).go();
    await _database.batch((batch) {
      batch.insertAll(_database.periodTemplateEntries, [
        for (final entry in template.entries)
          db.PeriodTemplateEntriesCompanion.insert(
            templateId: template.id,
            periodNumber: entry.periodNumber,
            startMinute: entry.startMinute,
            endMinute: entry.endMinute,
          ),
      ]);
    });
  });

  @override
  Future<void> setDefaultTemplate(String templateId, DateTime updatedAtUtc) =>
      _database.transaction(() async {
        final target =
            await (_database.select(_database.periodTemplates)
                  ..where((row) => row.id.equals(templateId))
                  ..limit(1))
                .getSingleOrNull();
        if (target == null) {
          throw ArgumentError.value(
            templateId,
            'templateId',
            'Template not found.',
          );
        }
        final instant = updatedAtUtc.microsecondsSinceEpoch;
        await _database
            .update(_database.periodTemplates)
            .write(
              db.PeriodTemplatesCompanion(
                isDefault: const Value(false),
                updatedAtUtc: Value(instant),
              ),
            );
        await (_database.update(
          _database.periodTemplates,
        )..where((row) => row.id.equals(templateId))).write(
          db.PeriodTemplatesCompanion(
            isDefault: const Value(true),
            updatedAtUtc: Value(instant),
          ),
        );
      });

  AcademicTerm _toTerm(db.AcademicTerm row) => AcademicTerm(
    id: row.id,
    name: row.name,
    firstWeekMonday: DateTime.parse(row.firstWeekMondayLocalDate),
    totalWeeks: row.totalWeeks,
    timeZoneId: row.timeZoneId,
    createdAtUtc: _instant(row.createdAtUtc),
    updatedAtUtc: _instant(row.updatedAtUtc),
  );

  static DateTime _instant(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
