import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/execution/execution_models.dart' as d;
import 'package:personal_planner/domain/execution/execution_result.dart';

/// 命令结果账本中的一条已提交记录。
final class StoredExecutionOperation {
  const StoredExecutionOperation({
    required this.requestHash,
    required this.result,
  });

  final String requestHash;
  final ExecutionCommandResult result;
}

/// 有效首次启动证据（规范 §14）。
final class ExecutionStartEvidence {
  const ExecutionStartEvidence({
    required this.occurredAtUtc,
    required this.source,
    required this.clockAnomaly,
  });

  final DateTime occurredAtUtc;
  final d.ExecutionActivitySource source;
  final bool clockAnomaly;
}

/// 执行事实的事务仓储（规范 §19.2）。
///
/// 所有方法都假定调用方已经处在 [transaction] 里；仓储自己不嵌套事务。
/// 这一点是刻意的：开始、结束、计划应用都必须"业务写入 + 结果账本 + 事件"一次提交，
/// 若仓储方法各自开事务，失败时就只能留下半条事实。
final class DriftExecutionRepository {
  DriftExecutionRepository(
    this.database, {
    this.clock = const SystemClock(),
    required this.idGenerator,
  });

  final db.AppDatabase database;
  final Clock clock;
  final IdGenerator idGenerator;

  Future<T> transaction<T>(Future<T> Function() action) =>
      database.transaction(action);

  // ── 运行时状态与序号 ─────────────────────────────────────────────────────

  Future<d.ExecutionRuntimeState> ensureRuntimeState() async {
    final query = database.select(database.executionRuntimeState)
      ..where((table) => table.id.equals(1));
    final existing = await query.getSingleOrNull();
    final now = clock.nowUtc();
    if (existing != null) {
      return _runtimeState(existing);
    }
    final epoch = idGenerator.next();
    await database
        .into(database.executionRuntimeState)
        .insert(
          db.ExecutionRuntimeStateCompanion.insert(
            id: const Value(1),
            dataEpoch: epoch,
            featureEnabledAtUtc: now.microsecondsSinceEpoch,
            updatedAtUtc: now.microsecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await database
        .into(database.executionWriteSequence)
        .insert(
          db.ExecutionWriteSequenceCompanion.insert(
            id: const Value(1),
            updatedAtUtc: now.microsecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final created = await query.getSingleOrNull();
    if (created == null) {
      throw StateError('execution_runtime_state 无法建立');
    }
    return _runtimeState(created);
  }

  Future<d.ExecutionRuntimeState?> runtimeState() async {
    final query = database.select(database.executionRuntimeState)
      ..where((table) => table.id.equals(1));
    final row = await query.getSingleOrNull();
    return row == null ? null : _runtimeState(row);
  }

  Future<void> writeRuntimeState(d.ExecutionRuntimeState state) async {
    await (database.update(
      database.executionRuntimeState,
    )..where((table) => table.id.equals(1))).write(
      db.ExecutionRuntimeStateCompanion(
        dataEpoch: Value(state.dataEpoch),
        activeSessionId: Value(state.activeSessionId),
        revision: Value(state.revision),
        featureEnabledAtUtc: Value(
          state.featureEnabledAtUtc.microsecondsSinceEpoch,
        ),
        updatedAtUtc: Value(state.updatedAtUtc.microsecondsSinceEpoch),
      ),
    );
  }

  /// 分配一个已提交执行事实的序号；返回本次分配到的值（从 1 开始）。
  Future<int> allocateSequence() async {
    final now = clock.nowUtc().microsecondsSinceEpoch;
    await database
        .into(database.executionWriteSequence)
        .insert(
          db.ExecutionWriteSequenceCompanion.insert(
            id: const Value(1),
            updatedAtUtc: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await database.customUpdate(
      'UPDATE execution_write_sequence '
      'SET next_value = next_value + 1, updated_at_utc = ? WHERE id = 1',
      variables: [Variable.withInt(now)],
      updates: {database.executionWriteSequence},
    );
    final row = await (database.select(
      database.executionWriteSequence,
    )..where((table) => table.id.equals(1))).getSingle();
    return row.nextValue - 1;
  }

  Future<int> currentSequence() async {
    final row = await (database.select(
      database.executionWriteSequence,
    )..where((table) => table.id.equals(1))).getSingleOrNull();
    if (row == null) return 0;
    return row.nextValue - 1;
  }

  // ── 操作结果账本 ─────────────────────────────────────────────────────────

  Future<StoredExecutionOperation?> findOperation({
    required String dataEpoch,
    required String operationId,
  }) async {
    final query = database.select(database.executionOperations)
      ..where(
        (table) =>
            table.dataEpoch.equals(dataEpoch) &
            table.operationId.equals(operationId),
      );
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return StoredExecutionOperation(
      requestHash: row.requestHash,
      result: ExecutionCommandResult.decode(row.resultJson),
    );
  }

  Future<void> recordOperation({
    required String dataEpoch,
    required String operationId,
    required String requestHash,
    required String commandType,
    required String subjectKind,
    required String? subjectId,
    required ExecutionCommandResult result,
  }) async {
    await database
        .into(database.executionOperations)
        .insert(
          db.ExecutionOperationsCompanion.insert(
            dataEpoch: dataEpoch,
            operationId: operationId,
            requestHash: requestHash,
            commandType: commandType,
            subjectKind: subjectKind,
            subjectId: Value(subjectId),
            resultJson: result.encode(),
            createdAtUtc: clock.nowUtc().microsecondsSinceEpoch,
          ),
        );
  }

  // ── 执行实例 ─────────────────────────────────────────────────────────────

  Future<d.ExecutionOccurrence?> findOccurrence(String id) async {
    final query = database.select(database.executionOccurrences)
      ..where((table) => table.id.equals(id));
    final row = await query.getSingleOrNull();
    return row == null ? null : _occurrence(row);
  }

  Future<List<d.ExecutionOccurrence>> occurrencesForTask(String taskId) async {
    final query = database.select(database.executionOccurrences)
      ..where((table) => table.taskId.equals(taskId))
      ..orderBy([(table) => OrderingTerm.asc(table.baselineStartUtc)]);
    return [for (final row in await query.get()) _occurrence(row)];
  }

  Future<List<d.ExecutionOccurrence>> occurrencesInWindow({
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    final query = database.select(database.executionOccurrences)
      ..where(
        (table) =>
            table.baselineStartUtc.isSmallerThanValue(
              endUtc.microsecondsSinceEpoch,
            ) &
            table.baselineEndUtc.isBiggerThanValue(
              startUtc.microsecondsSinceEpoch,
            ),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.baselineStartUtc)]);
    return [for (final row in await query.get()) _occurrence(row)];
  }

  Future<void> insertOccurrence(d.ExecutionOccurrence occurrence) async {
    await database
        .into(database.executionOccurrences)
        .insert(
          db.ExecutionOccurrencesCompanion.insert(
            id: occurrence.id,
            taskId: Value(occurrence.taskId),
            originPlanVersionId: Value(occurrence.originPlanVersionId),
            originBlockId: Value(occurrence.originBlockId),
            baselineStartUtc:
                occurrence.baselineStartUtc.microsecondsSinceEpoch,
            baselineEndUtc: occurrence.baselineEndUtc.microsecondsSinceEpoch,
            baselineTimeZoneId: occurrence.baselineTimeZoneId,
            baselineLocalDate: occurrence.baselineLocalDate,
            baselinePlannedDurationMicros:
                occurrence.baselinePlannedDurationMicros,
            currentPlanVersionId: Value(occurrence.currentPlanVersionId),
            allocatedMicros: occurrence.allocatedMicros,
            remainingAllocationMicros: occurrence.remainingAllocationMicros,
            firstStartEvidenceId: Value(occurrence.firstStartEvidenceId),
            withdrawalReason: Value(occurrence.withdrawalReason),
            withdrawnAtUtc: Value(
              occurrence.withdrawnAtUtc?.microsecondsSinceEpoch,
            ),
            lifecycleState: occurrence.lifecycleState.name,
            privacyState: occurrence.privacyState.name,
            createdAtUtc: occurrence.createdAtUtc.microsecondsSinceEpoch,
            revision: Value(occurrence.revision),
          ),
        );
  }

  Future<void> updateOccurrence(d.ExecutionOccurrence occurrence) async {
    await (database.update(
      database.executionOccurrences,
    )..where((table) => table.id.equals(occurrence.id))).write(
      db.ExecutionOccurrencesCompanion(
        taskId: Value(occurrence.taskId),
        originPlanVersionId: Value(occurrence.originPlanVersionId),
        originBlockId: Value(occurrence.originBlockId),
        baselineStartUtc: Value(
          occurrence.baselineStartUtc.microsecondsSinceEpoch,
        ),
        baselineEndUtc: Value(occurrence.baselineEndUtc.microsecondsSinceEpoch),
        baselineTimeZoneId: Value(occurrence.baselineTimeZoneId),
        baselineLocalDate: Value(occurrence.baselineLocalDate),
        baselinePlannedDurationMicros: Value(
          occurrence.baselinePlannedDurationMicros,
        ),
        currentPlanVersionId: Value(occurrence.currentPlanVersionId),
        allocatedMicros: Value(occurrence.allocatedMicros),
        remainingAllocationMicros: Value(occurrence.remainingAllocationMicros),
        firstStartEvidenceId: Value(occurrence.firstStartEvidenceId),
        withdrawalReason: Value(occurrence.withdrawalReason),
        withdrawnAtUtc: Value(
          occurrence.withdrawnAtUtc?.microsecondsSinceEpoch,
        ),
        lifecycleState: Value(occurrence.lifecycleState.name),
        privacyState: Value(occurrence.privacyState.name),
        revision: Value(occurrence.revision),
      ),
    );
  }

  // ── 计划块关联 ───────────────────────────────────────────────────────────

  /// 最近一版被取代的计划版本。用于判断"上一版安排里哪些实例没有延续"。
  Future<String?> previousPlanVersionId() async {
    final query = database.select(database.planVersions)
      ..where((table) => table.status.equals('superseded'))
      ..orderBy([
        (table) => OrderingTerm.desc(table.createdAtUtc),
        (table) => OrderingTerm.desc(table.id),
      ])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.id;
  }

  Future<Map<String, String>> blockLinksForVersion(String planVersionId) async {
    final query = database.select(database.executionBlockLinks)
      ..where((table) => table.planVersionId.equals(planVersionId));
    return {for (final row in await query.get()) row.blockId: row.occurrenceId};
  }

  /// 计划版本中的块时间与任务投影；用于 v11→v12 fragment 回填。
  Future<
    List<({String blockId, String taskId, DateTime startUtc, DateTime endUtc})>
  >
  blockTimingsForVersion(String planVersionId) async {
    final query = database.select(database.scheduleBlocks)
      ..where((table) => table.planVersionId.equals(planVersionId));
    return [
      for (final row in await query.get())
        (
          blockId: row.id,
          taskId: row.taskId,
          startUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.startAtUtc,
            isUtc: true,
          ),
          endUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.endAtUtc,
            isUtc: true,
          ),
        ),
    ];
  }

  Future<void> insertBlockLink({
    required String dataEpoch,
    required String planVersionId,
    required String blockId,
    required String occurrenceId,
    required String? sourceBlockId,
    required int reservedMicros,
    String? fragmentId,
  }) async {
    await database
        .into(database.executionBlockLinks)
        .insert(
          db.ExecutionBlockLinksCompanion.insert(
            dataEpoch: dataEpoch,
            planVersionId: planVersionId,
            blockId: blockId,
            occurrenceId: occurrenceId,
            sourceBlockId: Value(sourceBlockId),
            reservedMicros: reservedMicros,
            createdAtUtc: clock.nowUtc().microsecondsSinceEpoch,
            fragmentId: Value(fragmentId),
          ),
        );
  }

  Future<String?> fragmentIdForBlock({
    required String planVersionId,
    required String blockId,
  }) async {
    final row =
        await (database.select(database.executionBlockLinks)
              ..where(
                (table) =>
                    table.planVersionId.equals(planVersionId) &
                    table.blockId.equals(blockId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.fragmentId;
  }

  Future<void> setBlockLinkFragment({
    required String planVersionId,
    required String blockId,
    required String fragmentId,
  }) async {
    await (database.update(database.executionBlockLinks)..where(
          (table) =>
              table.planVersionId.equals(planVersionId) &
              table.blockId.equals(blockId),
        ))
        .write(db.ExecutionBlockLinksCompanion(fragmentId: Value(fragmentId)));
  }

  Future<void> deleteBlockLinksForOccurrence(String occurrenceId) async {
    await (database.delete(
      database.executionBlockLinks,
    )..where((table) => table.occurrenceId.equals(occurrenceId))).go();
  }

  /// 某个块在**所有**计划版本里的实例关联；用于恢复时定位来源（规范 §19.5）。
  Future<String?> occurrenceForAnyBlock(String blockId) async {
    final query = database.select(database.executionBlockLinks)
      ..where((table) => table.blockId.equals(blockId))
      ..orderBy([(table) => OrderingTerm.desc(table.createdAtUtc)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.occurrenceId;
  }

  // ── 事件 ─────────────────────────────────────────────────────────────────

  Future<void> insertEvent(d.ExecutionEvent event) async {
    await database
        .into(database.executionEvents)
        .insert(
          db.ExecutionEventsCompanion.insert(
            eventId: event.eventId,
            dataEpoch: event.dataEpoch,
            operationId: event.operationId,
            subEventIndex: event.subEventIndex,
            occurrenceId: Value(event.occurrenceId),
            eventType: event.eventType.name,
            occurredAtUtc: event.occurredAtUtc.microsecondsSinceEpoch,
            recordedAtUtc: event.recordedAtUtc.microsecondsSinceEpoch,
            source: event.source.name,
            payloadJson: Value(jsonEncode(event.payload)),
            correctedEventId: Value(event.correctedEventId),
            sequence: event.sequence,
            revision: Value(event.revision),
          ),
        );
  }

  Future<String?> firstStartEvidenceForOccurrence(String occurrenceId) async {
    final query = database.select(database.executionEvents)
      ..where(
        (table) =>
            table.occurrenceId.equals(occurrenceId) &
            table.eventType.equals(d.ExecutionEventType.started.name),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.occurredAtUtc)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.eventId;
  }

  /// 批量读取有效首次启动证据（规范 §14、§22.1）。
  ///
  /// 同一实例可能有多个 `started` 事件（补记、恢复后再次启动）；取**最早**的一条。
  Future<Map<String, ExecutionStartEvidence>> startEvidenceFor(
    Iterable<String> occurrenceIds,
  ) async {
    final ids = occurrenceIds.toList(growable: false);
    if (ids.isEmpty) return const {};
    final query = database.select(database.executionEvents)
      ..where(
        (table) =>
            table.occurrenceId.isIn(ids) &
            table.eventType.equals(d.ExecutionEventType.started.name),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.occurredAtUtc)]);
    final result = <String, ExecutionStartEvidence>{};
    for (final row in await query.get()) {
      final occurrenceId = row.occurrenceId;
      if (occurrenceId == null || result.containsKey(occurrenceId)) continue;
      final payload = _decodeJsonMap(row.payloadJson);
      result[occurrenceId] = ExecutionStartEvidence(
        occurredAtUtc: _utc(row.occurredAtUtc),
        source: _sourceOf(row.source),
        clockAnomaly: payload['clockAnomaly'] == true,
      );
    }
    return result;
  }

  T _parseEnum<T extends Enum>(List<T> values, String raw, T fallback) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    // 损坏或未知枚举隔离为保守值，不让整个今日页/统计页崩溃（EXE-68）。
    return fallback;
  }

  d.ExecutionActivitySource _sourceOf(String raw) {
    for (final value in d.ExecutionActivitySource.values) {
      if (value.name == raw) return value;
    }
    // 未知枚举按"无法关联的历史"隔离，不猜成实时来源（EXE-68）。
    return d.ExecutionActivitySource.legacyUnlinked;
  }

  // ── 会话 ─────────────────────────────────────────────────────────────────

  Future<d.ExecutionSessionLink?> findSessionLink(String sessionId) async {
    final query = database.select(database.executionSessionLinks)
      ..where((table) => table.sessionId.equals(sessionId));
    final row = await query.getSingleOrNull();
    return row == null ? null : _sessionLink(row);
  }

  Future<void> insertSessionLink(d.ExecutionSessionLink link) async {
    await database
        .into(database.executionSessionLinks)
        .insert(
          db.ExecutionSessionLinksCompanion.insert(
            sessionId: link.sessionId,
            dataEpoch: link.dataEpoch,
            occurrenceId: Value(link.occurrenceId),
            source: link.source.name,
            mode: link.mode.name,
            firstAcceptedSequence: Value(link.firstAcceptedSequence),
            revision: Value(link.revision),
            createdAtUtc: link.createdAtUtc.microsecondsSinceEpoch,
            updatedAtUtc: link.updatedAtUtc.microsecondsSinceEpoch,
          ),
        );
  }

  Future<void> updateSessionLink(d.ExecutionSessionLink link) async {
    await (database.update(
      database.executionSessionLinks,
    )..where((table) => table.sessionId.equals(link.sessionId))).write(
      db.ExecutionSessionLinksCompanion(
        occurrenceId: Value(link.occurrenceId),
        source: Value(link.source.name),
        mode: Value(link.mode.name),
        firstAcceptedSequence: Value(link.firstAcceptedSequence),
        revision: Value(link.revision),
        updatedAtUtc: Value(link.updatedAtUtc.microsecondsSinceEpoch),
      ),
    );
  }

  Future<d.ExecutionSessionSnapshot?> sessionSnapshot(
    String sessionId, {
    int runtimeRevision = 0,
  }) async {
    final entry = await findTimeEntry(sessionId);
    final link = await findSessionLink(sessionId);
    if (entry == null || link == null) return null;
    final meta = _entryMetadata(entry.source);
    final phaseName = meta['phase'] as String?;
    final state = d.ExecutionSessionState.values
        .where((value) => value.name == phaseName)
        .firstOrNull;
    if (state == null) return null;
    return d.ExecutionSessionSnapshot(
      sessionId: entry.id,
      occurrenceId: link.occurrenceId,
      taskId: entry.taskId,
      state: state,
      source: link.source,
      mode: link.mode,
      startedAtUtc: _utc(entry.startedAtUtc),
      activeMicros: (meta['activeMicroseconds'] as int?) ?? 0,
      revision: link.revision,
      lastReliableAtUtc: _utc(
        (meta['lastWallAtUtc'] as int?) ?? entry.startedAtUtc,
      ),
      runtimeRevision: runtimeRevision,
    );
  }

  Future<d.ExecutionSessionSnapshot?> activeSessionSnapshot() async {
    final runtime = await runtimeState();
    final id = runtime?.activeSessionId;
    if (id == null) return null;
    return sessionSnapshot(id, runtimeRevision: runtime!.revision);
  }

  // ── time_entries（既有计时账本）─────────────────────────────────────────

  Future<db.TimeEntry?> findTimeEntry(String id) async {
    final query = database.select(database.timeEntries)
      ..where((table) => table.id.equals(id));
    return query.getSingleOrNull();
  }

  Future<void> insertTimeEntry({
    required String id,
    required String taskId,
    required DateTime startedAtUtc,
    required d.ExecutionSessionState phase,
    required int activeMicros,
    required DateTime lastReliableAtUtc,
    required String note,
  }) async {
    final now = clock.nowUtc();
    await database
        .into(database.timeEntries)
        .insert(
          db.TimeEntriesCompanion.insert(
            id: id,
            taskId: taskId,
            startedAtUtc: startedAtUtc.microsecondsSinceEpoch,
            pausedMinutes: const Value(0),
            source: _encodeEntryMetadata(
              phase: phase,
              activeMicros: activeMicros,
              lastWallAtUtc: lastReliableAtUtc,
              note: note,
            ),
            recoveryState: 'confirmed',
            createdAtUtc: Value(startedAtUtc.microsecondsSinceEpoch),
            updatedAtUtc: Value(now.microsecondsSinceEpoch),
          ),
        );
  }

  Future<void> updateTimeEntry({
    required String id,
    required d.ExecutionSessionState phase,
    required int activeMicros,
    required DateTime lastReliableAtUtc,
    String? note,
    DateTime? endedAtUtc,
    int? pausedMinutes,
  }) async {
    final existing = await findTimeEntry(id);
    if (existing == null) return;
    final previous = _entryMetadata(existing.source);
    final effectiveNote = note ?? (previous['note'] as String?) ?? '';
    final now = clock.nowUtc();
    await (database.update(
      database.timeEntries,
    )..where((table) => table.id.equals(id))).write(
      db.TimeEntriesCompanion(
        endedAtUtc: Value(endedAtUtc?.microsecondsSinceEpoch),
        pausedMinutes: Value(pausedMinutes ?? 0),
        source: Value(
          _encodeEntryMetadata(
            phase: phase,
            activeMicros: activeMicros,
            lastWallAtUtc: lastReliableAtUtc,
            note: effectiveNote,
          ),
        ),
        recoveryState: const Value('confirmed'),
        updatedAtUtc: Value(now.microsecondsSinceEpoch),
      ),
    );
  }

  Future<String> entryNote(String id) async {
    final existing = await findTimeEntry(id);
    if (existing == null) return '';
    return _entryMetadata(existing.source)['note'] as String? ?? '';
  }

  /// 未结束会话。用于启动恢复确认与"最多一个实时会话"的诊断。
  Future<List<db.TimeEntry>> openTimeEntries() async {
    final query = database.select(database.timeEntries)
      ..where((table) => table.endedAtUtc.isNull())
      ..orderBy([(table) => OrderingTerm.desc(table.startedAtUtc)]);
    return query.get();
  }

  // ── 活动段与分配 ─────────────────────────────────────────────────────────

  Future<void> insertActivitySegment(d.ExecutionActivitySegment segment) async {
    await database
        .into(database.executionActivitySegments)
        .insert(
          db.ExecutionActivitySegmentsCompanion.insert(
            segmentId: segment.segmentId,
            dataEpoch: segment.dataEpoch,
            sessionId: segment.sessionId,
            sequence: segment.sequence,
            startUtc: segment.startUtc.microsecondsSinceEpoch,
            endUtc: segment.endUtc.microsecondsSinceEpoch,
            source: segment.source.name,
            invalidatedReason: Value(segment.invalidatedReason),
            createdAtUtc: segment.createdAtUtc.microsecondsSinceEpoch,
          ),
        );
  }

  Future<void> invalidateSegment(String segmentId, String reason) async {
    await (database.update(
      database.executionActivitySegments,
    )..where((table) => table.segmentId.equals(segmentId))).write(
      db.ExecutionActivitySegmentsCompanion(invalidatedReason: Value(reason)),
    );
  }

  Future<int> nextSegmentSequence(String sessionId) async {
    final query = database.selectOnly(database.executionActivitySegments)
      ..addColumns([database.executionActivitySegments.sequence.max()])
      ..where(database.executionActivitySegments.sessionId.equals(sessionId));
    final row = await query.getSingle();
    final max = row.read(database.executionActivitySegments.sequence.max());
    return (max ?? 0) + 1;
  }

  Future<List<d.ExecutionActivitySegment>> segmentsForSession(
    String sessionId,
  ) async {
    final query = database.select(database.executionActivitySegments)
      ..where((table) => table.sessionId.equals(sessionId))
      ..orderBy([(table) => OrderingTerm.asc(table.sequence)]);
    return [for (final row in await query.get()) _segment(row)];
  }

  /// 与给定区间重叠的有效活动段（可限定任务），用于补记冲突检查（规范 §12.1）。
  Future<List<d.ExecutionActivitySegment>> overlappingSegments({
    required DateTime startUtc,
    required DateTime endUtc,
    required String taskId,
  }) async {
    final rows = await database
        .customSelect(
          'SELECT s.segment_id, s.data_epoch, s.session_id, s.sequence, '
          's.start_utc, s.end_utc, s.source, s.invalidated_reason, '
          's.created_at_utc '
          'FROM execution_activity_segments s '
          'JOIN time_entries te ON te.id = s.session_id '
          'LEFT JOIN execution_session_links l ON l.session_id = s.session_id '
          'LEFT JOIN execution_occurrences o ON o.id = l.occurrence_id '
          'WHERE s.invalidated_reason IS NULL '
          'AND s.start_utc < ? AND s.end_utc > ? '
          'AND (te.task_id = ? OR o.task_id = ?)',
          variables: [
            Variable.withInt(endUtc.microsecondsSinceEpoch),
            Variable.withInt(startUtc.microsecondsSinceEpoch),
            Variable.withString(taskId),
            Variable.withString(taskId),
          ],
          readsFrom: {
            database.executionActivitySegments,
            database.timeEntries,
            database.executionSessionLinks,
            database.executionOccurrences,
          },
        )
        .get();
    return [for (final row in rows) _segmentFromRow(row)];
  }

  Future<void> insertCredit(d.ExecutionCreditAllocation credit) async {
    await database
        .into(database.executionCreditAllocations)
        .insert(
          db.ExecutionCreditAllocationsCompanion.insert(
            dataEpoch: credit.dataEpoch,
            segmentId: credit.segmentId,
            targetKind: credit.targetKind.name,
            targetId: credit.targetId,
            allocationIndex: credit.allocationIndex,
            recordRevision: credit.recordRevision,
            amountMicros: credit.amountMicros,
            firstAcceptedSequence: credit.firstAcceptedSequence,
            createdAtUtc: credit.createdAtUtc.microsecondsSinceEpoch,
          ),
        );
  }

  Future<int> nextCreditRecordRevision({
    required String segmentId,
    required d.ExecutionTargetKind targetKind,
    required String targetId,
  }) async {
    final query = database.selectOnly(database.executionCreditAllocations)
      ..addColumns([database.executionCreditAllocations.recordRevision.max()])
      ..where(
        database.executionCreditAllocations.segmentId.equals(segmentId) &
            database.executionCreditAllocations.targetKind.equals(
              targetKind.name,
            ) &
            database.executionCreditAllocations.targetId.equals(targetId),
      );
    final row = await query.getSingle();
    final max = row.read(
      database.executionCreditAllocations.recordRevision.max(),
    );
    return (max ?? 0) + 1;
  }

  /// 某个进度目标的全部有效投入（已排除被更正失效的活动段）。
  Future<List<d.ExecutionCreditAllocation>> activeCreditsForTarget({
    required d.ExecutionTargetKind targetKind,
    required String targetId,
  }) async {
    final allocations = database.executionCreditAllocations;
    final segments = database.executionActivitySegments;
    final query =
        database.select(allocations).join([
            innerJoin(
              segments,
              segments.segmentId.equalsExp(allocations.segmentId),
            ),
          ])
          ..where(
            allocations.targetKind.equals(targetKind.name) &
                allocations.targetId.equals(targetId) &
                segments.invalidatedReason.isNull(),
          )
          ..orderBy([OrderingTerm.asc(allocations.firstAcceptedSequence)]);
    final rows = await query.get();
    return [
      for (final row in rows)
        if (row.readTableOrNull(allocations) case final credit?)
          _credit(credit),
    ];
  }

  Future<void> deleteCreditsForSegment(String segmentId) async {
    await (database.delete(
      database.executionCreditAllocations,
    )..where((table) => table.segmentId.equals(segmentId))).go();
  }

  Future<List<d.ExecutionCreditAllocation>> creditsForSegment(
    String segmentId,
  ) async {
    final query = database.select(database.executionCreditAllocations)
      ..where((table) => table.segmentId.equals(segmentId));
    return [for (final row in await query.get()) _credit(row)];
  }

  // ── 进度检查点 ───────────────────────────────────────────────────────────

  Future<d.ExecutionProgressAnchor?> currentAnchor(String taskId) async {
    final query = database.select(database.executionProgressAnchors)
      ..where(
        (table) => table.taskId.equals(taskId) & table.isCurrent.equals(true),
      )
      ..orderBy([(table) => OrderingTerm.desc(table.revision)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _anchor(row);
  }

  Future<void> appendAnchor({
    required String taskId,
    required int anchorRemainingMicros,
    required int anchorSequence,
    required String reason,
  }) async {
    final nextRevision = await _nextAnchorRevision(taskId);
    await (database.update(database.executionProgressAnchors)..where(
          (table) => table.taskId.equals(taskId) & table.isCurrent.equals(true),
        ))
        .write(
          const db.ExecutionProgressAnchorsCompanion(isCurrent: Value(false)),
        );
    await database
        .into(database.executionProgressAnchors)
        .insert(
          db.ExecutionProgressAnchorsCompanion.insert(
            taskId: taskId,
            revision: nextRevision,
            anchorRemainingMicros: anchorRemainingMicros,
            anchorSequence: anchorSequence,
            reason: reason,
            createdAtUtc: clock.nowUtc().microsecondsSinceEpoch,
          ),
        );
  }

  Future<int> _nextAnchorRevision(String taskId) async {
    final query = database.selectOnly(database.executionProgressAnchors)
      ..addColumns([database.executionProgressAnchors.revision.max()])
      ..where(database.executionProgressAnchors.taskId.equals(taskId));
    final row = await query.getSingle();
    final max = row.read(database.executionProgressAnchors.revision.max());
    return (max ?? 0) + 1;
  }

  Future<List<int>> allocatedSequenceNumbers() async {
    final query = database.selectOnly(database.executionWriteSequence)
      ..addColumns([database.executionWriteSequence.nextValue]);
    final row = await query.getSingleOrNull();
    return [row?.read(database.executionWriteSequence.nextValue) ?? 1];
  }

  // ── 提醒 ─────────────────────────────────────────────────────────────────

  Future<d.ExecutionReminderIntent?> currentReminder(
    String occurrenceId,
  ) async {
    final query = database.select(database.executionReminderIntents)
      ..where((table) => table.occurrenceId.equals(occurrenceId))
      ..orderBy([(table) => OrderingTerm.desc(table.revision)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _reminder(row);
  }

  Future<List<d.ExecutionReminderIntent>> allReminders() async {
    final query = database.select(database.executionReminderIntents)
      ..orderBy([
        (table) => OrderingTerm.asc(table.occurrenceId),
        (table) => OrderingTerm.desc(table.revision),
      ]);
    return [for (final row in await query.get()) _reminder(row)];
  }

  Future<void> insertReminder(d.ExecutionReminderIntent intent) async {
    await database
        .into(database.executionReminderIntents)
        .insert(
          db.ExecutionReminderIntentsCompanion.insert(
            dataEpoch: intent.dataEpoch,
            occurrenceId: intent.occurrenceId,
            revision: intent.revision,
            targetAtUtc: intent.targetAtUtc.microsecondsSinceEpoch,
            notificationId: intent.notificationId,
            state: intent.state.name,
            claimedAtUtc: Value(intent.claimedAtUtc?.microsecondsSinceEpoch),
            scheduledAtUtc: Value(
              intent.scheduledAtUtc?.microsecondsSinceEpoch,
            ),
            dispatchResult: Value(intent.dispatchResult),
            createdAtUtc: intent.createdAtUtc.microsecondsSinceEpoch,
            updatedAtUtc: intent.updatedAtUtc.microsecondsSinceEpoch,
          ),
        );
  }

  Future<void> updateReminderState({
    required String occurrenceId,
    required int revision,
    required String dataEpoch,
    required d.ExecutionReminderState state,
    DateTime? claimedAtUtc,
    DateTime? scheduledAtUtc,
    String? dispatchResult,
  }) async {
    await (database.update(database.executionReminderIntents)..where(
          (table) =>
              table.occurrenceId.equals(occurrenceId) &
              table.revision.equals(revision) &
              table.dataEpoch.equals(dataEpoch),
        ))
        .write(
          db.ExecutionReminderIntentsCompanion(
            state: Value(state.name),
            claimedAtUtc: Value(claimedAtUtc?.microsecondsSinceEpoch),
            scheduledAtUtc: Value(scheduledAtUtc?.microsecondsSinceEpoch),
            dispatchResult: Value(dispatchResult),
            updatedAtUtc: Value(clock.nowUtc().microsecondsSinceEpoch),
          ),
        );
  }

  // ── dayHold ──────────────────────────────────────────────────────────────

  Future<void> upsertDayHold(d.ExecutionDayHold hold) async {
    await database
        .into(database.executionDayHolds)
        .insertOnConflictUpdate(
          db.ExecutionDayHoldsCompanion.insert(
            taskId: hold.taskId,
            localDate: hold.localDate,
            timeZoneId: hold.timeZoneId,
            invalidAfterUtc: hold.invalidAfterUtc.microsecondsSinceEpoch,
            sourceProposalId: Value(hold.sourceProposalId),
            createdAtUtc: hold.createdAtUtc.microsecondsSinceEpoch,
          ),
        );
  }

  Future<void> deleteDayHoldsForTask(String taskId) async {
    await (database.delete(
      database.executionDayHolds,
    )..where((table) => table.taskId.equals(taskId))).go();
  }

  Future<List<d.ExecutionDayHold>> activeDayHolds({
    required String taskId,
    required String localDate,
    required String timeZoneId,
    required DateTime nowUtc,
  }) async {
    final query = database.select(database.executionDayHolds)
      ..where(
        (table) =>
            table.taskId.equals(taskId) &
            table.localDate.equals(localDate) &
            table.timeZoneId.equals(timeZoneId) &
            table.invalidAfterUtc.isBiggerThanValue(
              nowUtc.microsecondsSinceEpoch,
            ),
      );
    return [for (final row in await query.get()) _dayHold(row)];
  }

  Future<List<String>> creditOverAllocations() async {
    final rows = await database
        .customSelect(
          'SELECT s.segment_id FROM execution_activity_segments s '
          'LEFT JOIN execution_credit_allocations c '
          'ON c.segment_id = s.segment_id '
          'GROUP BY s.segment_id '
          'HAVING COALESCE(SUM(c.amount_micros), 0) > '
          '(s.end_utc - s.start_utc)',
        )
        .get();
    return [for (final row in rows) row.read<String>('segment_id')];
  }

  // ── outbox ───────────────────────────────────────────────────────────────

  Future<void> insertOutbox(d.ExecutionOutboxEntry entry) async {
    await database
        .into(database.executionOutbox)
        .insert(
          db.ExecutionOutboxCompanion.insert(
            effectId: entry.effectId,
            dataEpoch: entry.dataEpoch,
            sourceTransaction: entry.sourceTransaction,
            targetRevision: entry.targetRevision,
            effectType: entry.effectType,
            payloadJson: Value(jsonEncode(entry.payload)),
            attempts: Value(entry.attempts),
            createdAtUtc: entry.createdAtUtc.microsecondsSinceEpoch,
            nextAttemptAtUtc: entry.nextAttemptAtUtc.microsecondsSinceEpoch,
            processedAtUtc: Value(entry.processedAtUtc?.microsecondsSinceEpoch),
          ),
        );
  }

  Future<List<d.ExecutionOutboxEntry>> pendingOutbox({int limit = 50}) async {
    final query = database.select(database.executionOutbox)
      ..where((table) => table.processedAtUtc.isNull())
      ..orderBy([(table) => OrderingTerm.asc(table.nextAttemptAtUtc)])
      ..limit(limit);
    return [for (final row in await query.get()) _outbox(row)];
  }

  Future<void> markOutboxProcessed(String effectId) async {
    await (database.update(
      database.executionOutbox,
    )..where((table) => table.effectId.equals(effectId))).write(
      db.ExecutionOutboxCompanion(
        processedAtUtc: Value(clock.nowUtc().microsecondsSinceEpoch),
      ),
    );
  }

  // ── 任务进度投影 ─────────────────────────────────────────────────────────

  Future<int> taskRemainingMicros(String taskId) async {
    // 精确剩余来自检查点 + 投入，任务行的 remaining_minutes 只是排程快照。
    final task = await (database.select(
      database.tasks,
    )..where((table) => table.id.equals(taskId))).getSingleOrNull();
    if (task == null) return 0;
    return task.remainingMinutes * Duration.microsecondsPerMinute;
  }

  Future<void> writeTaskRemaining({
    required String taskId,
    required int remainingMicros,
  }) async {
    final minutes = remainingMicros <= 0
        ? 0
        : (remainingMicros + Duration.microsecondsPerMinute - 1) ~/
              Duration.microsecondsPerMinute;
    await database.customUpdate(
      'UPDATE tasks SET remaining_minutes = ?, updated_at_utc = ? '
      'WHERE id = ?',
      variables: [
        Variable.withInt(minutes),
        Variable.withInt(clock.nowUtc().microsecondsSinceEpoch),
        Variable.withString(taskId),
      ],
      updates: {database.tasks},
    );
  }

  // ── 数据控制 ─────────────────────────────────────────────────────────────

  /// 显式清除执行历史（规范 §15）。
  ///
  /// **必须能在统计、审计或外键限制下完成**：按依赖顺序删除本模块的行，并在同一事务里
  /// 生成新的 `dataEpoch`，使旧通知回调、旧恢复草案、旧操作 ID 与异步 outbox 全部失效。
  /// `time_entries` 是否一起删除由 [deleteTimeEntries] 决定：默认只解除关联并标成
  /// `legacyUnlinked`，绝不暗中删除用户原有专注记录。
  Future<void> clearExecutionData({required bool deleteTimeEntries}) async {
    await database.transaction(() async {
      final sessionIds = [
        for (final row
            in await database.select(database.executionSessionLinks).get())
          row.sessionId,
      ];
      await database.delete(database.executionCreditAllocations).go();
      await database.delete(database.executionActivitySegments).go();
      await database.delete(database.executionSessionLinks).go();
      if (deleteTimeEntries && sessionIds.isNotEmpty) {
        await (database.delete(
          database.timeEntries,
        )..where((table) => table.id.isIn(sessionIds))).go();
      } else if (sessionIds.isNotEmpty) {
        await (database.update(
          database.timeEntries,
        )..where((table) => table.id.isIn(sessionIds))).write(
          const db.TimeEntriesCompanion(recoveryState: Value('legacyUnlinked')),
        );
      }
      await database.delete(database.executionBlockLinks).go();
      await database.delete(database.executionEvents).go();
      await database.delete(database.executionOperations).go();
      await database.delete(database.executionReminderIntents).go();
      await database.delete(database.executionDayHolds).go();
      await database.delete(database.executionOutbox).go();
      await database.delete(database.executionProgressAnchors).go();
      await database.delete(database.executionOccurrences).go();

      final runtime = await ensureRuntimeState();
      await writeRuntimeState(
        runtime.copyWith(
          dataEpoch: idGenerator.next(),
          clearActiveSessionId: true,
          revision: runtime.revision + 1,
          updatedAtUtc: clock.nowUtc(),
        ),
      );
    });
  }

  /// 普通删除任务时的匿名墓碑（规范 §15、§19.2）。
  ///
  /// 保留无个人文本的承诺样本；删除块链接、dayHold 和提醒，解除会话到实例的直接链接，
  /// 并把事件裁剪为指标所需的聚合事实。显式"清除执行历史"才删除行。
  Future<void> anonymizeTask(String taskId) async {
    final now = clock.nowUtc().microsecondsSinceEpoch;
    final occurrenceRows = await (database.select(
      database.executionOccurrences,
    )..where((table) => table.taskId.equals(taskId))).get();
    for (final row in occurrenceRows) {
      await (database.update(
        database.executionOccurrences,
      )..where((table) => table.id.equals(row.id))).write(
        db.ExecutionOccurrencesCompanion(
          taskId: const Value(null),
          originPlanVersionId: const Value(null),
          originBlockId: const Value(null),
          currentPlanVersionId: const Value(null),
          privacyState: Value(d.ExecutionPrivacyState.anonymized.name),
          revision: Value(row.revision + 1),
        ),
      );
      await deleteBlockLinksForOccurrence(row.id);
      await (database.delete(
        database.executionDayHolds,
      )..where((table) => table.taskId.equals(taskId))).go();
      await (database.delete(
        database.executionReminderIntents,
      )..where((table) => table.occurrenceId.equals(row.id))).go();
      await (database.update(
        database.executionSessionLinks,
      )..where((table) => table.occurrenceId.equals(row.id))).write(
        db.ExecutionSessionLinksCompanion(
          occurrenceId: const Value(null),
          source: Value(d.ExecutionActivitySource.legacyUnlinked.name),
          revision: Value(row.revision + 1),
        ),
      );
      await (database.update(
        database.executionEvents,
      )..where((table) => table.occurrenceId.equals(row.id))).write(
        db.ExecutionEventsCompanion(
          payloadJson: const Value('{}'),
          operationId: Value('anonymized-${row.id}'),
          recordedAtUtc: Value(now),
        ),
      );
    }
  }

  // ── 映射 ─────────────────────────────────────────────────────────────────

  static DateTime _utc(int micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

  d.ExecutionRuntimeState _runtimeState(db.ExecutionRuntimeStateData row) =>
      d.ExecutionRuntimeState(
        id: row.id,
        dataEpoch: row.dataEpoch,
        activeSessionId: row.activeSessionId,
        revision: row.revision,
        featureEnabledAtUtc: _utc(row.featureEnabledAtUtc),
        updatedAtUtc: _utc(row.updatedAtUtc),
      );

  d.ExecutionOccurrence _occurrence(db.ExecutionOccurrence row) =>
      d.ExecutionOccurrence(
        id: row.id,
        taskId: row.taskId,
        originPlanVersionId: row.originPlanVersionId,
        originBlockId: row.originBlockId,
        baselineStartUtc: _utc(row.baselineStartUtc),
        baselineEndUtc: _utc(row.baselineEndUtc),
        baselineTimeZoneId: row.baselineTimeZoneId,
        baselineLocalDate: row.baselineLocalDate,
        baselinePlannedDurationMicros: row.baselinePlannedDurationMicros,
        currentPlanVersionId: row.currentPlanVersionId,
        allocatedMicros: row.allocatedMicros,
        remainingAllocationMicros: row.remainingAllocationMicros,
        firstStartEvidenceId: row.firstStartEvidenceId,
        withdrawalReason: row.withdrawalReason,
        withdrawnAtUtc: row.withdrawnAtUtc == null
            ? null
            : _utc(row.withdrawnAtUtc!),
        lifecycleState: _parseEnum(
          d.ExecutionLifecycleState.values,
          row.lifecycleState,
          d.ExecutionLifecycleState.planned,
        ),
        privacyState: _parseEnum(
          d.ExecutionPrivacyState.values,
          row.privacyState,
          d.ExecutionPrivacyState.linked,
        ),
        createdAtUtc: _utc(row.createdAtUtc),
        revision: row.revision,
      );

  d.ExecutionSessionLink _sessionLink(db.ExecutionSessionLink row) =>
      d.ExecutionSessionLink(
        sessionId: row.sessionId,
        dataEpoch: row.dataEpoch,
        occurrenceId: row.occurrenceId,
        source: _sourceOf(row.source),
        mode: _parseEnum(
          d.ExecutionMode.values,
          row.mode,
          d.ExecutionMode.planned,
        ),
        firstAcceptedSequence: row.firstAcceptedSequence,
        revision: row.revision,
        createdAtUtc: _utc(row.createdAtUtc),
        updatedAtUtc: _utc(row.updatedAtUtc),
      );

  d.ExecutionActivitySegment _segment(db.ExecutionActivitySegment row) =>
      d.ExecutionActivitySegment(
        segmentId: row.segmentId,
        dataEpoch: row.dataEpoch,
        sessionId: row.sessionId,
        sequence: row.sequence,
        startUtc: _utc(row.startUtc),
        endUtc: _utc(row.endUtc),
        source: _sourceOf(row.source),
        invalidatedReason: row.invalidatedReason,
        createdAtUtc: _utc(row.createdAtUtc),
      );

  d.ExecutionActivitySegment _segmentFromRow(QueryRow row) =>
      d.ExecutionActivitySegment(
        segmentId: row.read<String>('segment_id'),
        dataEpoch: row.read<String>('data_epoch'),
        sessionId: row.read<String>('session_id'),
        sequence: row.read<int>('sequence'),
        startUtc: _utc(row.read<int>('start_utc')),
        endUtc: _utc(row.read<int>('end_utc')),
        source: _sourceOf(row.read<String>('source')),
        invalidatedReason: row.read<String?>('invalidated_reason'),
        createdAtUtc: _utc(row.read<int>('created_at_utc')),
      );

  d.ExecutionCreditAllocation _credit(db.ExecutionCreditAllocation row) =>
      d.ExecutionCreditAllocation(
        dataEpoch: row.dataEpoch,
        segmentId: row.segmentId,
        targetKind: _parseEnum(
          d.ExecutionTargetKind.values,
          row.targetKind,
          d.ExecutionTargetKind.task,
        ),
        targetId: row.targetId,
        allocationIndex: row.allocationIndex,
        recordRevision: row.recordRevision,
        amountMicros: row.amountMicros,
        firstAcceptedSequence: row.firstAcceptedSequence,
        createdAtUtc: _utc(row.createdAtUtc),
      );

  d.ExecutionProgressAnchor _anchor(db.ExecutionProgressAnchor row) =>
      d.ExecutionProgressAnchor(
        taskId: row.taskId,
        revision: row.revision,
        anchorRemainingMicros: row.anchorRemainingMicros,
        anchorSequence: row.anchorSequence,
        reason: row.reason,
        createdAtUtc: _utc(row.createdAtUtc),
        isCurrent: row.isCurrent,
      );

  d.ExecutionReminderIntent _reminder(db.ExecutionReminderIntent row) =>
      d.ExecutionReminderIntent(
        dataEpoch: row.dataEpoch,
        occurrenceId: row.occurrenceId,
        revision: row.revision,
        targetAtUtc: _utc(row.targetAtUtc),
        notificationId: row.notificationId,
        state: _parseEnum(
          d.ExecutionReminderState.values,
          row.state,
          d.ExecutionReminderState.unknown,
        ),
        claimedAtUtc: row.claimedAtUtc == null ? null : _utc(row.claimedAtUtc!),
        scheduledAtUtc: row.scheduledAtUtc == null
            ? null
            : _utc(row.scheduledAtUtc!),
        dispatchResult: row.dispatchResult,
        createdAtUtc: _utc(row.createdAtUtc),
        updatedAtUtc: _utc(row.updatedAtUtc),
      );

  d.ExecutionDayHold _dayHold(db.ExecutionDayHold row) => d.ExecutionDayHold(
    taskId: row.taskId,
    localDate: row.localDate,
    timeZoneId: row.timeZoneId,
    invalidAfterUtc: _utc(row.invalidAfterUtc),
    sourceProposalId: row.sourceProposalId,
    createdAtUtc: _utc(row.createdAtUtc),
  );

  d.ExecutionOutboxEntry _outbox(db.ExecutionOutboxData row) =>
      d.ExecutionOutboxEntry(
        effectId: row.effectId,
        dataEpoch: row.dataEpoch,
        sourceTransaction: row.sourceTransaction,
        targetRevision: row.targetRevision,
        effectType: row.effectType,
        payload: _decodeJsonMap(row.payloadJson),
        attempts: row.attempts,
        createdAtUtc: _utc(row.createdAtUtc),
        nextAttemptAtUtc: _utc(row.nextAttemptAtUtc),
        processedAtUtc: row.processedAtUtc == null
            ? null
            : _utc(row.processedAtUtc!),
      );

  Map<String, Object?> _entryMetadata(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // 旧记录或损坏的元数据：下面对缺失键给保守默认值。
    }
    return const {};
  }

  Map<String, Object?> _decodeJsonMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // 损坏的附加效果参数：保留一条空负载，由 outbox 隔离而不是让启动崩溃。
    }
    return const {};
  }

  String _encodeEntryMetadata({
    required d.ExecutionSessionState phase,
    required int activeMicros,
    required DateTime lastWallAtUtc,
    required String note,
  }) => jsonEncode({
    'schemaVersion': 1,
    'phase': phase.name,
    'activeMicroseconds': activeMicros,
    'lastWallAtUtc': lastWallAtUtc.microsecondsSinceEpoch,
    'note': note,
  });
}
