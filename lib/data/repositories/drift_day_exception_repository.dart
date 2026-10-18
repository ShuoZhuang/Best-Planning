import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/repositories/day_exception_repository.dart';

/// `day_exceptions` 的 Drift 适配器（算法 20，规范 §8.1）。
///
/// 所有查询都带**显式稳定排序**（本地日期 → 更新时间 → ID），因此同一份数据
/// 在任意设备、任意插入顺序下都给出相同列表（ALG20-004/040）。
final class DriftDayExceptionRepository implements DayExceptionRepository {
  const DriftDayExceptionRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<DayException?> findConfirmed(DateTime localDate) async {
    final query = _database.select(_database.dayExceptions)
      ..where(
        (row) =>
            row.localDate.equals(formatLocalDate(localDate)) &
            row.status.equals(DayExceptionStatus.confirmed.name),
      )
      ..orderBy([
        (row) => OrderingTerm.desc(row.updatedAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ])
      ..limit(1);
    final rows = await query.get();
    return rows.isEmpty ? null : _toDomain(rows.first);
  }

  @override
  Future<List<DayException>> listAffecting(DateTime localDate) async {
    final key = formatLocalDate(localDate);
    final query = _database.select(_database.dayExceptions)
      ..where(
        (row) =>
            row.status.equals(DayExceptionStatus.confirmed.name) &
            (row.localDate.equals(key) | row.recoveryLocalDate.equals(key)),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.localDate),
        (row) => OrderingTerm.asc(row.updatedAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return (await query.get()).map(_toDomain).toList(growable: false);
  }

  @override
  Future<List<DayException>> listBetween(DateTime first, DateTime last) async {
    final query = _database.select(_database.dayExceptions)
      ..where(
        (row) =>
            row.localDate.isBiggerOrEqualValue(formatLocalDate(first)) &
            row.localDate.isSmallerOrEqualValue(formatLocalDate(last)),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.localDate),
        (row) => OrderingTerm.asc(row.updatedAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return (await query.get()).map(_toDomain).toList(growable: false);
  }

  @override
  Future<void> save(DayException value) async {
    await _database
        .into(_database.dayExceptions)
        .insertOnConflictUpdate(_toCompanion(value));
  }

  @override
  Future<void> revoke(String id, DateTime revokedAtUtc) async {
    if (!revokedAtUtc.isUtc) {
      throw ArgumentError.value(revokedAtUtc, 'revokedAtUtc', 'Must be UTC.');
    }
    await (_database.update(
      _database.dayExceptions,
    )..where((row) => row.id.equals(id))).write(
      db.DayExceptionsCompanion(
        status: Value(DayExceptionStatus.revoked.name),
        revokedAtUtc: Value(revokedAtUtc.microsecondsSinceEpoch),
        updatedAtUtc: Value(revokedAtUtc.microsecondsSinceEpoch),
      ),
    );
  }

  db.DayExceptionsCompanion _toCompanion(DayException value) =>
      db.DayExceptionsCompanion(
        id: Value(value.id),
        localDate: Value(formatLocalDate(value.localDate)),
        kind: Value(value.kind.name),
        status: Value(value.status.name),
        originalSleepStartOffsetMinutes: Value(
          value.originalSleepStartOffsetMinutes,
        ),
        temporarySleepStartOffsetMinutes: Value(
          value.temporarySleepStartOffsetMinutes,
        ),
        fixedWakeOffsetMinutes: Value(value.fixedWakeOffsetMinutes),
        absoluteMinimumSleepMinutes: Value(value.absoluteMinimumSleepMinutes),
        recoveryChoice: Value(value.recoveryChoice.name),
        recoveryLocalDate: Value(
          value.recoveryLocalDate == null
              ? null
              : formatLocalDate(value.recoveryLocalDate!),
        ),
        source: Value(value.source),
        triggeringProposalId: Value(value.triggeringProposalId),
        auditNote: Value(value.auditNote),
        createdAtUtc: Value(value.createdAtUtc.microsecondsSinceEpoch),
        updatedAtUtc: Value(value.updatedAtUtc.microsecondsSinceEpoch),
        revokedAtUtc: Value(value.revokedAtUtc?.microsecondsSinceEpoch),
      );

  DayException _toDomain(db.DayException row) => DayException(
    id: row.id,
    localDate: parseLocalDate(row.localDate),
    kind: _enumByName(
      DayExceptionKind.values,
      row.kind,
      DayExceptionKind.userSpecialDay,
    ),
    status: _enumByName(
      DayExceptionStatus.values,
      row.status,
      DayExceptionStatus.draft,
    ),
    originalSleepStartOffsetMinutes: row.originalSleepStartOffsetMinutes,
    temporarySleepStartOffsetMinutes: row.temporarySleepStartOffsetMinutes,
    fixedWakeOffsetMinutes: row.fixedWakeOffsetMinutes,
    absoluteMinimumSleepMinutes: row.absoluteMinimumSleepMinutes,
    recoveryChoice: _enumByName(
      RecoveryChoice.values,
      row.recoveryChoice,
      RecoveryChoice.none,
    ),
    source: row.source,
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.createdAtUtc,
      isUtc: true,
    ),
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.updatedAtUtc,
      isUtc: true,
    ),
    triggeringProposalId: row.triggeringProposalId,
    recoveryLocalDate: row.recoveryLocalDate == null
        ? null
        : parseLocalDate(row.recoveryLocalDate!),
    revokedAtUtc: row.revokedAtUtc == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(row.revokedAtUtc!, isUtc: true),
    auditNote: row.auditNote,
  );

  static T _enumByName<T extends Enum>(
    List<T> values,
    String name,
    T fallback,
  ) => values.where((value) => value.name == name).firstOrNull ?? fallback;
}
