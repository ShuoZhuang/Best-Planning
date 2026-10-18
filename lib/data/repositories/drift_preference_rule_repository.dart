import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/repositories/preference_rule_repository.dart';

/// `preference_rules` 的 Drift 适配器（算法 20，规范 §9.4）。
///
/// **复用既有表，不为偏好再升 schema**：`valueJson` 只保存建议值与版本信息，
/// `confidence` 存无量纲千分比折算后的 0..1 数值。
final class DriftPreferenceRuleRepository implements PreferenceRuleRepository {
  const DriftPreferenceRuleRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<List<LearnedPreferenceRule>> listAll() async {
    final query = _database.select(_database.preferenceRules)
      ..orderBy([
        (row) => OrderingTerm.asc(row.subjectKey),
        (row) => OrderingTerm.asc(row.kind),
        (row) => OrderingTerm.asc(row.updatedAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return (await query.get()).map(_toDomain).toList(growable: false);
  }

  @override
  Future<List<LearnedPreferenceRule>> listForSubject(String subjectKey) async {
    final query = _database.select(_database.preferenceRules)
      ..where((row) => row.subjectKey.equals(subjectKey))
      ..orderBy([
        (row) => OrderingTerm.asc(row.kind),
        (row) => OrderingTerm.asc(row.updatedAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return (await query.get()).map(_toDomain).toList(growable: false);
  }

  @override
  Future<void> save(LearnedPreferenceRule value) async {
    await _database
        .into(_database.preferenceRules)
        .insertOnConflictUpdate(_toCompanion(value));
  }

  @override
  Future<void> saveAllAtomically(List<LearnedPreferenceRule> values) =>
      _database.transaction(() async {
        for (final value in values) {
          await _database
              .into(_database.preferenceRules)
              .insertOnConflictUpdate(_toCompanion(value));
        }
      });

  @override
  Future<void> clearLearnedRules() =>
      _database.delete(_database.preferenceRules).go();

  db.PreferenceRulesCompanion _toCompanion(LearnedPreferenceRule value) =>
      db.PreferenceRulesCompanion(
        id: Value(value.id),
        kind: Value(value.kind.name),
        subjectKey: Value(value.subjectKey),
        valueJson: Value(
          jsonEncode({
            'preferredStartMinute': value.preferredStartMinute,
            'preferredEndMinute': value.preferredEndMinute,
            'preferredFocusMinutes': value.preferredFocusMinutes,
            'evidenceVersion': value.evidenceVersion,
            'supersedesId': value.supersedesId,
          }),
        ),
        // 数据库的 `confidence` 是 REAL；存 0..1 的无量纲置信度，读取时再折算千分比。
        confidence: Value(value.confidencePermille / 1000),
        status: Value(value.status.name),
        source: Value(value.source),
        updatedAtUtc: Value(value.updatedAtUtc.microsecondsSinceEpoch),
      );

  LearnedPreferenceRule _toDomain(db.PreferenceRule row) {
    final json = _decode(row.valueJson);
    return LearnedPreferenceRule(
      id: row.id,
      kind: _enumByName(
        LearnedPreferenceKind.values,
        row.kind,
        LearnedPreferenceKind.preferredTimeWindow,
      ),
      subjectKey: row.subjectKey,
      status: _enumByName(
        LearnedPreferenceStatus.values,
        row.status,
        LearnedPreferenceStatus.suggested,
      ),
      confidencePermille: (row.confidence * 1000).round().clamp(0, 1000),
      source: row.source,
      evidenceVersion: json['evidenceVersion'] as String? ?? 'legacy',
      updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.updatedAtUtc,
        isUtc: true,
      ),
      preferredStartMinute: json['preferredStartMinute'] as int?,
      preferredEndMinute: json['preferredEndMinute'] as int?,
      preferredFocusMinutes: json['preferredFocusMinutes'] as int?,
      supersedesId: json['supersedesId'] as String?,
    );
  }

  Map<String, Object?> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    String name,
    T fallback,
  ) => values.where((value) => value.name == name).firstOrNull ?? fallback;
}
