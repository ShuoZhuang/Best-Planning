import 'package:personal_planner/domain/models/preference_snapshot.dart';

/// 学习建议与已确认规则的状态（规范 §9.4，固定六态）。
enum LearnedPreferenceStatus {
  suggested,
  edited,
  confirmed,
  rejected,
  disabled,
  superseded,
}

/// 学习偏好的种类。与旧 `PreferenceSuggestionKind` 的语义一一对应，但**按领域**
/// 保存，因此不再有"一个全局档案覆盖所有任务"的第二事实源。
enum LearnedPreferenceKind { preferredTimeWindow, preferredFocusMinutes }

/// 一条学习偏好规则（建议或已确认事实）。
///
/// **持久化唯一事实源是现有的 `preference_rules` 表**（规范 §9.4 / ALG20-064）：
/// `id/kind/subjectKey/status/source/updatedAtUtc` 各占一列，建议值、证据版本、
/// 置信区间与 `supersedesId` 放进版本化 `valueJson`。
final class LearnedPreferenceRule {
  const LearnedPreferenceRule({
    required this.id,
    required this.kind,
    required this.subjectKey,
    required this.status,
    required this.confidencePermille,
    required this.source,
    required this.evidenceVersion,
    required this.updatedAtUtc,
    this.preferredStartMinute,
    this.preferredEndMinute,
    this.preferredFocusMinutes,
    this.supersedesId,
  }) : assert(confidencePermille >= 0 && confidencePermille <= 1000);

  final String id;
  final LearnedPreferenceKind kind;

  /// `global` 或 `area:<id>`。
  final String subjectKey;
  final LearnedPreferenceStatus status;

  /// 无量纲置信度，千分比（`0..1000`）。**不是分钟数，也不是百分比字符串**。
  final int confidencePermille;
  final String source;
  final String evidenceVersion;
  final DateTime updatedAtUtc;
  final int? preferredStartMinute;
  final int? preferredEndMinute;
  final int? preferredFocusMinutes;
  final String? supersedesId;

  bool get isConfirmed => status == LearnedPreferenceStatus.confirmed;

  LearnedPreferenceRule copyWith({
    LearnedPreferenceStatus? status,
    int? confidencePermille,
    String? source,
    String? evidenceVersion,
    DateTime? updatedAtUtc,
    int? preferredStartMinute,
    int? preferredEndMinute,
    int? preferredFocusMinutes,
    String? supersedesId,
  }) => LearnedPreferenceRule(
    id: id,
    kind: kind,
    subjectKey: subjectKey,
    status: status ?? this.status,
    confidencePermille: confidencePermille ?? this.confidencePermille,
    source: source ?? this.source,
    evidenceVersion: evidenceVersion ?? this.evidenceVersion,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    preferredStartMinute: preferredStartMinute ?? this.preferredStartMinute,
    preferredEndMinute: preferredEndMinute ?? this.preferredEndMinute,
    preferredFocusMinutes: preferredFocusMinutes ?? this.preferredFocusMinutes,
    supersedesId: supersedesId ?? this.supersedesId,
  );

  @override
  bool operator ==(Object other) =>
      other is LearnedPreferenceRule &&
      other.id == id &&
      other.kind == kind &&
      other.subjectKey == subjectKey &&
      other.status == status &&
      other.confidencePermille == confidencePermille &&
      other.source == source &&
      other.evidenceVersion == evidenceVersion &&
      other.updatedAtUtc == updatedAtUtc &&
      other.preferredStartMinute == preferredStartMinute &&
      other.preferredEndMinute == preferredEndMinute &&
      other.preferredFocusMinutes == preferredFocusMinutes &&
      other.supersedesId == supersedesId;

  @override
  int get hashCode => Object.hashAll([
    id,
    kind,
    subjectKey,
    status,
    confidencePermille,
    source,
    evidenceVersion,
    updatedAtUtc,
    preferredStartMinute,
    preferredEndMinute,
    preferredFocusMinutes,
    supersedesId,
  ]);
}

/// 规则仓储端口（规范 §9.4）。
abstract interface class PreferenceRuleRepository {
  Future<List<LearnedPreferenceRule>> listAll();

  Future<List<LearnedPreferenceRule>> listForSubject(String subjectKey);

  Future<void> save(LearnedPreferenceRule value);

  Future<void> saveAllAtomically(List<LearnedPreferenceRule> values);

  Future<void> clearLearnedRules();
}

/// 把已确认规则装配成不可变排程快照（规范 §9.5）。
///
/// 规则已按 `subjectKey/kind/updatedAtUtc/id` 排序；同一 subject 同一 kind 只取
/// 最新一条 confirmed 规则。`evidenceVersion` 由规则内容派生，因此确认、撤销或
/// 停用任何一条规则都会改变输入哈希。
PreferenceSnapshot buildPreferenceSnapshot({
  required bool enabled,
  required List<LearnedPreferenceRule> rules,
}) => PreferenceSnapshot.fromRules(enabled: enabled, rules: rules);
