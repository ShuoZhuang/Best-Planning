import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

final class DriftTimetableImportRepository
    implements TimetableImportRepository {
  DriftTimetableImportRepository(this._database, {DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc());

  final db.AppDatabase _database;
  final DateTime Function() _now;

  @override
  Future<TimetableImportBatch> commit(TimetableImportCommit request) async {
    final timestamp = request.createdAtUtc.microsecondsSinceEpoch;
    final fileName = request.sourceFileName.split(RegExp(r'[\\/]')).last;
    await _database.transaction(() async {
      // **同图重复判定在同一个事务里**（计划 Task 9 Step 1）：此前它在事务之外，
      // 于是"检查通过"与"真正落库"之间另一个提交可以先写进去，两个完整课表同时入库
      // （R4）。放进事务之后，同一连接上的并发提交只有一个能成功。
      //
      // **只拦截 `committed`**（Task 9 Step 2）：
      // - `partiallyDeleted` 表示"这个批次里至少有一门课被用户删掉了"，
      //   而用户接下来想做的正是**用原图把那门课补回来**；
      // - `rolledBack` 是用户主动撤销过的批次；
      // - `draft` 是保留的兼容值，从来不是"完整导入"的意思。
      // 用"当前还剩几条锚点"去猜状态是错的：删除事务已经写下了明确状态（§2.2）。
      final duplicate =
          await (_database.select(_database.timetableImportBatches)
                ..where(
                  (row) =>
                      row.termId.equals(request.termId) &
                      row.sourceImageHash.equals(request.sourceImageHash) &
                      row.status.equals(
                        TimetableImportBatchStatus.committed.storageValue,
                      ),
                )
                ..limit(1))
              .getSingleOrNull();
      if (duplicate != null) {
        throw DuplicateTimetableImportException(duplicate.id);
      }

      await _database
          .into(_database.timetableImportBatches)
          .insert(
            db.TimetableImportBatchesCompanion.insert(
              id: request.batchId,
              termId: request.termId,
              sourceImageHash: request.sourceImageHash,
              sourceFileName: fileName,
              status: TimetableImportBatchStatus.committed.storageValue,
              createdEventCount: request.series.length,
              createdAtUtc: timestamp,
              updatedAtUtc: timestamp,
            ),
          );
      for (final series in request.series) {
        if (series.event.recurrenceRuleId != series.rule.id) {
          throw ArgumentError('Event and recurrence rule ids must match.');
        }
        await _database
            .into(_database.recurrenceRules)
            .insert(
              db.RecurrenceRulesCompanion.insert(
                id: series.rule.id,
                weekdaysMask: _weekdaysMask(series.rule.weekdays),
                localStartMinute: series.rule.localStartMinute,
                durationMinutes: series.rule.durationMinutes,
                intervalWeeks: Value(series.rule.intervalWeeks),
                validFromLocalDate: _date(series.rule.validFromLocalDate),
                validUntilLocalDate: Value(
                  series.rule.validUntilLocalDate == null
                      ? null
                      : _date(series.rule.validUntilLocalDate!),
                ),
                timeZoneId: series.rule.timeZoneId,
                createdAtUtc: Value(timestamp),
                updatedAtUtc: Value(timestamp),
              ),
            );
        final event = series.event;
        await _database
            .into(_database.calendarEvents)
            .insert(
              db.CalendarEventsCompanion.insert(
                id: event.id,
                title: event.title,
                startAtUtc: event.startAtUtc.microsecondsSinceEpoch,
                endAtUtc: event.endAtUtc.microsecondsSinceEpoch,
                timeZoneId: event.timeZoneId,
                recurrenceRuleId: Value(event.recurrenceRuleId),
                exceptionOfId: Value(event.exceptionOfId),
                locked: const Value(true),
                areaId: Value(event.areaId),
                projectId: Value(event.projectId),
                location: Value(event.location),
                notes: Value(event.notes),
                sourceKind: Value(
                  CalendarEventSourceKind.timetableImport.storageValue,
                ),
                importBatchId: Value(request.batchId),
                logicalCourseId: Value(event.logicalCourseId),
                createdAtUtc: Value(timestamp),
                updatedAtUtc: timestamp,
              ),
            );
        for (final exclusion in series.exclusions) {
          await _database
              .into(_database.calendarEvents)
              .insert(
                db.CalendarEventsCompanion(
                  id: Value(exclusion.id),
                  title: Value(event.title),
                  startAtUtc: Value(
                    exclusion.occurrenceStartUtc.microsecondsSinceEpoch,
                  ),
                  endAtUtc: Value(
                    exclusion.occurrenceStartUtc.microsecondsSinceEpoch,
                  ),
                  timeZoneId: Value(event.timeZoneId),
                  exceptionOfId: Value(event.id),
                  locked: const Value(true),
                  sourceKind: Value(
                    CalendarEventSourceKind.timetableImport.storageValue,
                  ),
                  importBatchId: Value(request.batchId),
                  logicalCourseId: Value(event.logicalCourseId),
                  createdAtUtc: Value(timestamp),
                  updatedAtUtc: Value(timestamp),
                ),
              );
        }
      }
    });
    return TimetableImportBatch(
      id: request.batchId,
      termId: request.termId,
      sourceImageHash: request.sourceImageHash,
      sourceFileName: fileName,
      status: TimetableImportBatchStatus.committed,
      createdEventCount: request.series.length,
      createdAtUtc: request.createdAtUtc,
      updatedAtUtc: request.createdAtUtc,
    );
  }

  @override
  Future<List<TimetableImportHistoryItem>> listHistory({
    String? termId,
    bool includeRolledBack = true,
  }) async {
    // **固定四次查询**（计划 Task 10 Step 2），不是一个批次一次：
    // ① 批次（顺带学期名称）② 与本批次相关的全部锚点 ③ 这些锚点的例外
    // ④ 学期清单。N+1 会在导入记录变多之后拖慢整页，而那段代码在每次打开都要跑。
    final batchQuery = _database.select(_database.timetableImportBatches);
    if (termId != null) {
      batchQuery.where((row) => row.termId.equals(termId));
    }
    final batches = await batchQuery.get();
    if (batches.isEmpty) return const [];

    final terms = {
      for (final row in await _database.select(_database.academicTerms).get())
        row.id: row.name,
    };

    final batchIds = {for (final batch in batches) batch.id};
    final anchors =
        await (_database.select(_database.calendarEvents)..where(
              (row) =>
                  row.importBatchId.isIn(batchIds) & row.exceptionOfId.isNull(),
            ))
            .get();
    final anchorIds = {for (final anchor in anchors) anchor.id};
    final exceptions = anchorIds.isEmpty
        ? const <db.CalendarEvent>[]
        : await (_database.select(_database.calendarEvents)..where(
                (row) =>
                    row.exceptionOfId.isIn(anchorIds) &
                    // **手工加的例外不算"受保护"**：它不该阻止用户撤销一次导入；
                    // 真正要拦的是"这条锚点本身被改过"或"它名下的例外来自别的批次"。
                    row.importBatchId.isNotIn(batchIds),
              ))
              .get();

    final anchorsByBatch = <String, List<db.CalendarEvent>>{};
    for (final anchor in anchors) {
      (anchorsByBatch[anchor.importBatchId ?? ''] ??= []).add(anchor);
    }
    final foreignExceptionAnchors = {
      for (final exception in exceptions) exception.exceptionOfId,
    };

    final items = <TimetableImportHistoryItem>[];
    for (final batch in batches) {
      final status = TimetableImportBatchStatus.fromStorage(batch.status);
      if (!includeRolledBack &&
          status == TimetableImportBatchStatus.rolledBack) {
        continue;
      }
      final owned = anchorsByBatch[batch.id] ?? const <db.CalendarEvent>[];
      // "受保护"的判据与 `inspectRollback` **完全一致**：锚点被改过（`updated_at_utc`
      // 已不是批次创建时间），或者它名下挂着一条属于别处的例外。
      final protectedCount = owned
          .where(
            (anchor) =>
                anchor.updatedAtUtc != batch.createdAtUtc ||
                foreignExceptionAnchors.contains(anchor.id),
          )
          .length;
      final canRollback = switch (status) {
        TimetableImportBatchStatus.committed => true,
        // 还有剩余系列时才能撤销；已经一条不剩的批次没有可撤销的东西，
        // 但它的历史仍然要看得见（§2.6）。
        TimetableImportBatchStatus.partiallyDeleted => owned.isNotEmpty,
        TimetableImportBatchStatus.rolledBack => false,
        TimetableImportBatchStatus.draft => false,
      };
      items.add(
        TimetableImportHistoryItem(
          batchId: batch.id,
          sourceFileName: batch.sourceFileName,
          termId: batch.termId,
          termName: terms[batch.termId],
          createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            batch.createdAtUtc,
            isUtc: true,
          ),
          createdSeriesCount: batch.createdEventCount,
          remainingSeriesCount: owned.length,
          protectedSeriesCount: protectedCount,
          status: status,
          canRollback: canRollback,
          requiresForceConfirmation: protectedCount > 0,
        ),
      );
    }

    // **顺序在 Dart 侧定死**：不依赖数据库返回顺序；时间相同时按 batch id
    // 保证两次查询给出同一个列表。
    items.sort((a, b) {
      final byTime = b.createdAtUtc.compareTo(a.createdAtUtc);
      if (byTime != 0) return byTime;
      return a.batchId.compareTo(b.batchId);
    });
    return List.unmodifiable(items);
  }

  @override
  Future<RollbackPreview> inspectRollback(String batchId) async {
    final batch =
        await (_database.select(_database.timetableImportBatches)
              ..where((row) => row.id.equals(batchId))
              ..limit(1))
            .getSingleOrNull();
    if (batch == null) {
      return RollbackPreview(
        batchId: batchId,
        eventIds: const {},
        protectedEventIds: const {},
      );
    }
    final events =
        await (_database.select(_database.calendarEvents)..where(
              (row) =>
                  row.importBatchId.equals(batchId) &
                  row.exceptionOfId.isNull(),
            ))
            .get();
    final ids = {for (final event in events) event.id};
    final exceptionAnchors = <String>{};
    if (ids.isNotEmpty) {
      final exceptions = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.isIn(ids))).get();
      exceptionAnchors.addAll(
        exceptions
            .where((event) => event.importBatchId != batchId)
            .map((event) => event.exceptionOfId)
            .whereType<String>(),
      );
    }
    final protected = {
      for (final event in events)
        if (event.updatedAtUtc != batch.createdAtUtc ||
            exceptionAnchors.contains(event.id))
          event.id,
    };
    return RollbackPreview(
      batchId: batchId,
      eventIds: Set.unmodifiable(ids),
      protectedEventIds: Set.unmodifiable(protected),
    );
  }

  @override
  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  }) async {
    final preview = await inspectRollback(batchId);
    final unapproved = preview.protectedEventIds.difference(forceEventIds);
    if (unapproved.isNotEmpty) {
      throw ProtectedTimetableEventsException(Set.unmodifiable(unapproved));
    }
    if (preview.eventIds.isEmpty) {
      await (_database.update(
        _database.timetableImportBatches,
      )..where((row) => row.id.equals(batchId))).write(
        db.TimetableImportBatchesCompanion(
          status: Value(TimetableImportBatchStatus.rolledBack.storageValue),
          updatedAtUtc: Value(_now().toUtc().microsecondsSinceEpoch),
        ),
      );
      return RollbackResult(batchId: batchId, deletedEventCount: 0);
    }
    final events = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.id.isIn(preview.eventIds))).get();
    final ruleIds = events
        .map((event) => event.recurrenceRuleId)
        .whereType<String>()
        .toSet();
    await _database.transaction(() async {
      await (_database.delete(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.isIn(preview.eventIds))).go();
      await (_database.delete(
        _database.calendarEvents,
      )..where((row) => row.id.isIn(preview.eventIds))).go();
      if (ruleIds.isNotEmpty) {
        await (_database.delete(
          _database.recurrenceRules,
        )..where((row) => row.id.isIn(ruleIds))).go();
      }
      await (_database.update(
        _database.timetableImportBatches,
      )..where((row) => row.id.equals(batchId))).write(
        db.TimetableImportBatchesCompanion(
          status: Value(TimetableImportBatchStatus.rolledBack.storageValue),
          updatedAtUtc: Value(_now().toUtc().microsecondsSinceEpoch),
        ),
      );
    });
    return RollbackResult(
      batchId: batchId,
      deletedEventCount: preview.eventIds.length,
    );
  }
}

int _weekdaysMask(Set<int> weekdays) =>
    weekdays.fold(0, (mask, day) => mask | (1 << (day - 1)));

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
