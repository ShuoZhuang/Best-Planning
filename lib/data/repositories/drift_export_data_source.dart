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
    // 1.11.0 周期与执行事实：导出必须能还原周实例、片段、证据与预排链。
    'recurringTaskTemplates': _sorted(
      (await database.select(database.recurringTaskTemplates).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'recurringTaskCycles': _sorted(
      (await database.select(database.recurringTaskCycles).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'recurringCycleSnapshots': _sorted(
      (await database.select(database.recurringCycleSnapshots).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'recurringCompletionEvidence': _sorted(
      (await database.select(database.recurringCompletionEvidence).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionOccurrences': _sorted(
      (await database.select(database.executionOccurrences).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionFragments': _sorted(
      (await database.select(database.executionFragments).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionBlockLinks': _sorted(
      (await database.select(database.executionBlockLinks).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionEvents': _sorted(
      (await database.select(database.executionEvents).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionSessionLinks': _sorted(
      (await database.select(database.executionSessionLinks).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionActivitySegments': _sorted(
      (await database.select(database.executionActivitySegments).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionCreditAllocations': _sorted(
      (await database.select(database.executionCreditAllocations).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'executionReminderIntents': _sorted(
      (await database.select(database.executionReminderIntents).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'pendingPlanPreviews': _sorted(
      (await database.select(database.pendingPlanPreviews).get()).map(
        (row) => row.toJson(),
      ),
    ),
    'pendingPlanPreviewBlocks': _sorted(
      (await database.select(database.pendingPlanPreviewBlocks).get()).map(
        (row) => row.toJson(),
      ),
    ),
  };
}

List<Map<String, Object?>> _sorted(Iterable<Map<String, Object?>> records) {
  final result = records.toList(growable: false);
  String keyOf(Map<String, Object?> row) {
    for (final key in const [
      'id',
      'key',
      'cycle_id',
      'fragment_id',
      'evidence_id',
      'preview_id',
      'block_id',
      'event_id',
      'session_id',
      'segment_id',
      'occurrence_id',
    ]) {
      final value = row[key];
      if (value != null) return value.toString();
    }
    return row.values.isEmpty ? '' : row.values.first.toString();
  }

  result.sort((left, right) => keyOf(left).compareTo(keyOf(right)));
  return result;
}
