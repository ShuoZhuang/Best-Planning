import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

void main() {
  test('successful commit emits exactly one scheduling-input change', () async {
    final repository = _FakeImportRepository();
    final changes = <ScheduleInputChange>[];
    final service = TimetableImportService(
      calendarRepository: _NoCalendar(),
      zones: TimeZoneDatabase(),
      importRepository: repository,
      onScheduleInputChanged: changes.add,
    );
    final request = TimetableImportCommit(
      batchId: 'batch',
      termId: 'term',
      sourceImageHash: 'hash',
      sourceFileName: 'schedule.png',
      createdAtUtc: DateTime.utc(2026, 10, 5),
      series: const [],
    );

    await service.commit(request);

    expect(repository.commitCalls, 1);
    expect(changes, hasLength(1));
    expect(changes.single.kind, DomainChangeKind.fixedEventCreated);
  });
}

final class _FakeImportRepository implements TimetableImportRepository {
  int commitCalls = 0;

  @override
  Future<TimetableImportBatch> commit(TimetableImportCommit request) async {
    commitCalls++;
    return request.batch;
  }

  @override
  Future<RollbackPreview> inspectRollback(String batchId) =>
      throw UnimplementedError();

  @override
  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  }) => throw UnimplementedError();
}

final class _NoCalendar implements CalendarRepository {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [];

  @override
  Future<void> save(CalendarEvent event) async {}
}
