import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/domain/update/update_safety.dart';

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

  test('课表导入与回滚运行期间阻塞更新，结束或异常后解除（UPD-029）', () async {
    final repository = _FakeImportRepository();
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    final service = TimetableImportService(
      calendarRepository: _NoCalendar(),
      zones: TimeZoneDatabase(),
      importRepository: repository,
      updateSafety: safety,
    );
    final request = TimetableImportCommit(
      batchId: 'batch',
      termId: 'term',
      sourceImageHash: 'hash',
      sourceFileName: 'schedule.png',
      createdAtUtc: DateTime.utc(2026, 10, 5),
      series: const [],
    );

    final commit = service.commit(request);
    expect(safety.status.blockers, contains(UpdateBlocker.importRunning));
    await commit;
    expect(safety.status.canInstall, isTrue);

    final rollback = service.rollback('batch');
    expect(safety.status.blockers, contains(UpdateBlocker.importRunning));
    await rollback;
    expect(safety.status.canInstall, isTrue);

    repository.failCommit = true;
    await expectLater(service.commit(request), throwsStateError);
    expect(safety.status.canInstall, isTrue, reason: '异常也必须解除阻塞');
  });

  test('两个重叠导入：第一个结束不会提前解除第二个的阻塞（UPD-029）', () async {
    final repository = _FakeImportRepository();
    final gates = <Completer<void>>[];
    repository.beforeCommit = () {
      final gate = Completer<void>();
      gates.add(gate);
      return gate.future;
    };
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    final service = TimetableImportService(
      calendarRepository: _NoCalendar(),
      zones: TimeZoneDatabase(),
      importRepository: repository,
      updateSafety: safety,
    );
    final request = TimetableImportCommit(
      batchId: 'batch',
      termId: 'term',
      sourceImageHash: 'hash',
      sourceFileName: 'schedule.png',
      createdAtUtc: DateTime.utc(2026, 10, 5),
      series: const [],
    );

    final first = service.commit(request);
    final second = service.commit(request);
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(2));
    gates[0].complete();
    await first;
    expect(
      safety.status.blockers,
      contains(UpdateBlocker.importRunning),
      reason: '第二个导入还在运行',
    );
    gates[1].complete();
    await second;
    expect(safety.status.canInstall, isTrue);
  });

  test('用户取消导入时同样解除阻塞（UPD-029）', () async {
    final repository = _FakeImportRepository()
      ..beforeCommit = (() async => throw StateError('用户取消'));
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    final service = TimetableImportService(
      calendarRepository: _NoCalendar(),
      zones: TimeZoneDatabase(),
      importRepository: repository,
      updateSafety: safety,
    );
    final request = TimetableImportCommit(
      batchId: 'batch',
      termId: 'term',
      sourceImageHash: 'hash',
      sourceFileName: 'schedule.png',
      createdAtUtc: DateTime.utc(2026, 10, 5),
      series: const [],
    );

    final pending = service.commit(request);
    expect(safety.status.blockers, contains(UpdateBlocker.importRunning));
    await expectLater(pending, throwsStateError);
    expect(safety.status.canInstall, isTrue);
  });
}

final class _FakeImportRepository implements TimetableImportRepository {
  int commitCalls = 0;
  int rollbackCalls = 0;
  bool failCommit = false;
  Future<void> Function()? beforeCommit;

  @override
  Future<TimetableImportBatch> commit(TimetableImportCommit request) async {
    commitCalls++;
    if (beforeCommit != null) await beforeCommit!();
    if (failCommit) throw StateError('commit failed');
    return request.batch;
  }

  @override
  Future<List<TimetableImportHistoryItem>> listHistory({
    String? termId,
    bool includeRolledBack = true,
  }) async => const [];

  @override
  Future<RollbackPreview> inspectRollback(String batchId) =>
      throw UnimplementedError();

  @override
  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  }) async {
    rollbackCalls++;
    return RollbackResult(batchId: batchId, deletedEventCount: 0);
  }
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
