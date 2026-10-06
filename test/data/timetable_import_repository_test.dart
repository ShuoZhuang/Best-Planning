import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart' as domain;
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

void main() {
  late AppDatabase database;
  late DriftTimetableImportRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftTimetableImportRepository(database);
    await database.customInsert('''
      INSERT INTO areas
        (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc)
      VALUES ('area-study', '学业', 17, 0, 0, 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term', '秋季学期', '2026-09-07', 16, 'Asia/Shanghai', 1, 1)
    ''');
  });

  tearDown(() => database.close());

  test(
    'commit atomically creates one batch with locked imported series',
    () async {
      final batch = await repository.commit(timetableTestCommit());

      expect(batch.createdEventCount, 1);
      expect(
        await database.select(database.timetableImportBatches).get(),
        hasLength(1),
      );
      final events = await database.select(database.calendarEvents).get();
      expect(events, hasLength(1));
      expect(events.single.locked, isTrue);
      expect(events.single.sourceKind, 'timetableImport');
      expect(events.single.importBatchId, batch.id);
      expect(
        await database.select(database.recurrenceRules).get(),
        hasLength(1),
      );
    },
  );

  test(
    'commit rolls back all rows when a later event violates a foreign key',
    () async {
      final valid = _series('event-1', 'rule-1');
      final invalid = _series('event-2', 'rule-2').copyWith(
        event: _series(
          'event-2',
          'rule-2',
        ).event.copyWith(areaId: 'missing-area'),
      );

      await expectLater(
        repository.commit(timetableTestCommit(series: [valid, invalid])),
        throwsA(isA<Exception>()),
      );

      expect(
        await database.select(database.timetableImportBatches).get(),
        isEmpty,
      );
      expect(await database.select(database.calendarEvents).get(), isEmpty);
      expect(await database.select(database.recurrenceRules).get(), isEmpty);
    },
  );

  test('same image hash and term is surfaced as a duplicate batch', () async {
    await repository.commit(timetableTestCommit());

    await expectLater(
      repository.commit(timetableTestCommit(batchId: 'batch-2')),
      throwsA(isA<DuplicateTimetableImportException>()),
    );
  });

  test(
    'conflicting occurrence exclusion is stored atomically with the batch',
    () async {
      final series = _series('event-1', 'rule-1').copyWith(
        exclusions: [
          TimetableImportExclusion(
            id: 'exception-1',
            occurrenceStartUtc: DateTime.utc(2026, 9, 14),
          ),
        ],
      );

      await repository.commit(timetableTestCommit(series: [series]));

      final rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(2));
      final exception = rows.singleWhere((row) => row.id == 'exception-1');
      expect(exception.exceptionOfId, 'event-1');
      expect(exception.startAtUtc, exception.endAtUtc);
      expect(exception.importBatchId, 'batch-1');
      expect(
        (await repository.inspectRollback('batch-1')).protectedEventIds,
        isEmpty,
      );

      await repository.rollback('batch-1');
      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );
}

TimetableImportCommit timetableTestCommit({
  String batchId = 'batch-1',
  List<TimetableImportSeriesWrite>? series,
}) => TimetableImportCommit(
  batchId: batchId,
  termId: 'term',
  sourceImageHash: 'sha256:test',
  sourceFileName: r'G:\private\schedule.png',
  createdAtUtc: DateTime.utc(2026, 10, 5),
  series: series ?? [_series('event-1', 'rule-1')],
);

TimetableImportSeriesWrite _series(String eventId, String ruleId) {
  final start = DateTime.utc(2026, 9, 7);
  return TimetableImportSeriesWrite(
    event: domain.CalendarEvent(
      id: eventId,
      title: '大学物理',
      startAtUtc: start,
      endAtUtc: start.add(const Duration(minutes: 100)),
      timeZoneId: 'Asia/Shanghai',
      recurrenceRuleId: ruleId,
      areaId: 'area-study',
      sourceKind: domain.CalendarEventSourceKind.timetableImport,
      importBatchId: 'batch-1',
      logicalCourseId: 'course-physics',
      updatedAtUtc: DateTime.utc(2026, 10, 5),
    ),
    rule: domain.RecurrenceRule(
      id: ruleId,
      weekdays: const {DateTime.monday},
      localStartMinute: 8 * 60,
      durationMinutes: 100,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 12, 21),
      timeZoneId: 'Asia/Shanghai',
    ),
  );
}
