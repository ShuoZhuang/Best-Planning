import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

import '../data/timetable_import_repository_test.dart' show timetableTestCommit;

void main() {
  late AppDatabase database;
  late DriftTimetableImportRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftTimetableImportRepository(database);
    await database.customInsert(
      "INSERT INTO areas (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc) VALUES ('area-study', '学业', 17, 0, 0, 1, 1)",
    );
    await database.customInsert(
      "INSERT INTO academic_terms (id, name, first_week_monday_local_date, total_weeks, time_zone_id, created_at_utc, updated_at_utc) VALUES ('term', '秋季学期', '2026-09-07', 16, 'Asia/Shanghai', 1, 1)",
    );
    await repository.commit(timetableTestCommit());
  });

  tearDown(() => database.close());

  test(
    'rollback deletes untouched import and marks batch rolled back',
    () async {
      final preview = await repository.inspectRollback('batch-1');
      expect(preview.protectedEventIds, isEmpty);

      final result = await repository.rollback('batch-1');

      expect(result.deletedEventCount, 1);
      expect(await database.select(database.calendarEvents).get(), isEmpty);
      expect(
        (await database.select(database.timetableImportBatches).getSingle())
            .status,
        'rolledBack',
      );
    },
  );

  test('rollback protects edited events unless explicitly forced', () async {
    await database.customUpdate(
      "UPDATE calendar_events SET updated_at_utc = updated_at_utc + 1 WHERE id = 'event-1'",
    );

    expect((await repository.inspectRollback('batch-1')).protectedEventIds, {
      'event-1',
    });
    await expectLater(
      repository.rollback('batch-1'),
      throwsA(isA<ProtectedTimetableEventsException>()),
    );
    expect(await database.select(database.calendarEvents).get(), hasLength(1));

    await repository.rollback('batch-1', forceEventIds: {'event-1'});
    expect(await database.select(database.calendarEvents).get(), isEmpty);
  });

  test('rollback treats a gained recurrence exception as protected', () async {
    await database.customInsert('''
      INSERT INTO calendar_events
        (id, title, start_at_utc, end_at_utc, time_zone_id, exception_of_id,
         locked, location, notes, source_kind, created_at_utc, updated_at_utc)
      VALUES ('exception-1', '调课', 2, 3, 'Asia/Shanghai', 'event-1',
              1, '', '', 'manual', 2, 2)
    ''');

    expect((await repository.inspectRollback('batch-1')).protectedEventIds, {
      'event-1',
    });
  });
}
