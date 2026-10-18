import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/preference_rule_repository.dart';

/// 某个 subject（领域或 `global`）的不可变软偏好。
final class SubjectPreference {
  SubjectPreference({
    required this.subjectKey,
    this.preferredWindow,
    this.preferredFocusMinutes,
    this.confidencePermille = 0,
    List<String> sourceRuleIds = const [],
  }) : sourceRuleIds = UnmodifiableListView([...sourceRuleIds]..sort());

  final String subjectKey;

  /// 期望的本地时段；`null` 表示该 subject 没有时段偏好。
  final LocalTimeRange? preferredWindow;
  final int? preferredFocusMinutes;
  final int confidencePermille;
  final List<String> sourceRuleIds;

  bool get isEmpty => preferredWindow == null && preferredFocusMinutes == null;
}

/// 交给 `ScheduleProblem` 的**不可变**学习偏好快照（规范 §9.5 / ALG20-065）。
///
/// 排程内核只读这个对象，不再从设置仓储或页面读偏好；因此"确认了偏好却影响
/// 了另一个领域"在类型上就不可能发生。
final class PreferenceSnapshot {
  PreferenceSnapshot({
    required this.enabled,
    required Map<String, SubjectPreference> bySubject,
    this.global,
    required this.evidenceVersion,
  }) : bySubject = UnmodifiableMapView(
         Map<String, SubjectPreference>.of(bySubject),
       );

  factory PreferenceSnapshot.empty({bool enabled = true}) => PreferenceSnapshot(
    enabled: enabled,
    bySubject: const {},
    evidenceVersion: enabled ? 'empty' : 'disabled',
  );

  /// 从规则表装配。**只消费 confirmed**：`edited` 还没确认、`suggested` 只是建议。
  factory PreferenceSnapshot.fromRules({
    required bool enabled,
    required List<LearnedPreferenceRule> rules,
  }) {
    final confirmed = rules.where((rule) => rule.isConfirmed).toList()
      ..sort((a, b) {
        final subject = a.subjectKey.compareTo(b.subjectKey);
        if (subject != 0) return subject;
        final kind = a.kind.index.compareTo(b.kind.index);
        if (kind != 0) return kind;
        final updated = a.updatedAtUtc.compareTo(b.updatedAtUtc);
        return updated != 0 ? updated : a.id.compareTo(b.id);
      });

    final latest =
        <String, Map<LearnedPreferenceKind, LearnedPreferenceRule>>{};
    for (final rule in confirmed) {
      latest.putIfAbsent(rule.subjectKey, () => {})[rule.kind] = rule;
    }

    final bySubject = <String, SubjectPreference>{};
    for (final entry in latest.entries) {
      final timeRule = entry.value[LearnedPreferenceKind.preferredTimeWindow];
      final focusRule =
          entry.value[LearnedPreferenceKind.preferredFocusMinutes];
      final start = timeRule?.preferredStartMinute;
      final end = timeRule?.preferredEndMinute;
      final preference = SubjectPreference(
        subjectKey: entry.key,
        preferredWindow: start == null || end == null || start == end
            ? null
            : LocalTimeRange(startMinute: start, endMinute: end),
        preferredFocusMinutes: focusRule?.preferredFocusMinutes,
        confidencePermille: [
          timeRule?.confidencePermille ?? 0,
          focusRule?.confidencePermille ?? 0,
        ].reduce((a, b) => a > b ? a : b),
        sourceRuleIds: [
          if (timeRule != null) timeRule.id,
          if (focusRule != null) focusRule.id,
        ],
      );
      if (!preference.isEmpty) {
        bySubject[entry.key] = preference;
      }
    }

    final version = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'enabled': enabled,
              'rules': [
                for (final rule in confirmed)
                  {
                    'id': rule.id,
                    'kind': rule.kind.name,
                    'subject': rule.subjectKey,
                    'status': rule.status.name,
                    'confidence': rule.confidencePermille,
                    'value': [
                      rule.preferredStartMinute,
                      rule.preferredEndMinute,
                      rule.preferredFocusMinutes,
                    ],
                    'evidenceVersion': rule.evidenceVersion,
                    'supersedes': rule.supersedesId,
                  },
              ],
            }),
          ),
        )
        .toString();

    return PreferenceSnapshot(
      enabled: enabled,
      bySubject: bySubject,
      global: bySubject['global'],
      evidenceVersion: version,
    );
  }

  final bool enabled;
  final Map<String, SubjectPreference> bySubject;

  /// `global` 样本人群对应的回退偏好；它**不能反推**任何领域偏好。
  final SubjectPreference? global;
  final String evidenceVersion;

  bool get hasAny => bySubject.isNotEmpty;

  /// 某件任务实际可用的偏好。
  ///
  /// - 无领域任务：只用 `global`；
  /// - 有领域任务：先找 `area:<id>`，缺失时才回退 `global`；
  /// - 学习总开关关闭时：一律 `null`。
  SubjectPreference? forTask({required String? areaId}) {
    if (!enabled) return null;
    if (areaId == null || areaId.isEmpty) return global;
    return bySubject['area:$areaId'] ?? global;
  }

  /// 某个 subject 的偏好（不应用回退）；测试与页面进度用。
  SubjectPreference? forSubject(String subjectKey) => bySubject[subjectKey];
}
