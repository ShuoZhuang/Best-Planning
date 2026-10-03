import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/repositories/preference_evidence_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

/// `PreferenceEvidenceRepository` 的 drift 实现。
///
/// `metadata` 存成 JSON 列：分析器要读 `timeBucket`、`direction` 这类键，而键的集合会随
/// 证据种类增长，为它单独建列会让每加一种证据都要一次 schema 迁移。
final class DriftPreferenceEvidenceRepository
    implements PreferenceEvidenceRepository {
  const DriftPreferenceEvidenceRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<void> save(PreferenceEvidence evidence) => _database
      .into(_database.preferenceEvidence)
      .insert(
        db.PreferenceEvidenceCompanion(
          id: Value(evidence.id),
          kind: Value(evidence.kind.name),
          subjectKey: Value(evidence.subjectKey),
          observedAtUtc: Value(evidence.observedAtUtc.microsecondsSinceEpoch),
          numericValue: Value(evidence.numericValue),
          specialDay: Value(evidence.specialDay),
          metadataJson: Value(jsonEncode(evidence.metadata)),
        ),
      );

  @override
  Future<List<PreferenceEvidence>> since(DateTime sinceUtc) async {
    if (!sinceUtc.isUtc) {
      throw ArgumentError.value(sinceUtc, 'sinceUtc', 'Must be UTC.');
    }
    final query = _database.select(_database.preferenceEvidence)
      ..where(
        (row) => row.observedAtUtc.isBiggerOrEqualValue(
          sinceUtc.microsecondsSinceEpoch,
        ),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.observedAtUtc)]);
    return (await query.get()).map(_toEvidence).toList(growable: false);
  }

  PreferenceEvidence _toEvidence(db.PreferenceEvidenceData row) =>
      PreferenceEvidence(
        id: row.id,
        // 未知种类说明这行来自更新的版本；忽略它比抛错好——一条读不懂的证据不该让
        // 整个偏好页打不开。
        kind: PreferenceEvidenceKind.values
            .where((value) => value.name == row.kind)
            .firstOrNull ??
            PreferenceEvidenceKind.focusCompletion,
        subjectKey: row.subjectKey,
        observedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.observedAtUtc,
          isUtc: true,
        ),
        numericValue: row.numericValue,
        specialDay: row.specialDay,
        metadata: _decodeMetadata(row.metadataJson),
      );

  Map<String, Object?> _decodeMetadata(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
