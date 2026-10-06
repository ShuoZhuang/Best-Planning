import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/data/database/app_database.dart';

final class DriftExportDataSource implements ExportDataSource {
  const DriftExportDataSource(this.database);

  final AppDatabase database;

  @override
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts() async => {
    'areas': _sorted(
      (await database.select(database.areas).get()).map((row) => row.toJson()),
    ),
    'projects': _sorted(
      (await database.select(database.projects).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'tasks': _sorted(
      (await database.select(database.tasks).get()).map((row) => row.toJson()),
    ),
    'recurrenceRules': _sorted(
      (await database.select(database.recurrenceRules).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'calendarEvents': _sorted(
      (await database.select(database.calendarEvents).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'academicTerms': _sorted(
      (await database.select(database.academicTerms).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'periodTemplates': _sorted(
      (await database.select(database.periodTemplates).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'periodTemplateEntries': _sorted(
      (await database.select(database.periodTemplateEntries).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'timetableImportBatches': _sorted(
      (await database.select(database.timetableImportBatches).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'energyWindows': _sorted(
      (await database.select(database.energyWindows).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'settings': _sorted(
      (await database.select(database.settings).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'planVersions': _sorted(
      (await database.select(database.planVersions).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'scheduleBlocks': _sorted(
      (await database.select(database.scheduleBlocks).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'timeEntries': _sorted(
      (await database.select(database.timeEntries).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'preferenceEvidence': _sorted(
      (await database.select(database.preferenceEvidence).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'preferenceRules': _sorted(
      (await database.select(database.preferenceRules).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'changeLog': _sorted(
      (await database.select(database.changeLog).get()).map(
        (row) => row.toJson(),
      ),
    ),
  };
}

List<Map<String, Object?>> _sorted(Iterable<Map<String, Object?>> records) {
  final result = records.toList(growable: false);
  result.sort(
    (left, right) => ((left['id'] ?? left['key']) as String? ?? '').compareTo(
      (right['id'] ?? right['key']) as String? ?? '',
    ),
  );
  return result;
}
