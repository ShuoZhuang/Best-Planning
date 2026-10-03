import 'dart:collection';

import 'package:personal_planner/domain/models/preferences.dart';

enum PreferenceEvidenceKind { focusCompletion, manualMove, suggestionAction }

final class PreferenceEvidence {
  PreferenceEvidence({
    required this.id,
    required this.kind,
    required this.subjectKey,
    required this.observedAtUtc,
    this.numericValue,
    this.specialDay = false,
    Map<String, Object?> metadata = const {},
  }) : metadata = UnmodifiableMapView(Map.of(metadata)) {
    if (!observedAtUtc.isUtc) {
      throw ArgumentError.value(observedAtUtc, 'observedAtUtc', 'Must be UTC.');
    }
  }

  final String id;
  final PreferenceEvidenceKind kind;
  final String subjectKey;
  final DateTime observedAtUtc;
  final double? numericValue;
  final bool specialDay;
  final Map<String, Object?> metadata;

  PreferenceEvidence copyWith({bool? specialDay}) => PreferenceEvidence(
    id: id,
    kind: kind,
    subjectKey: subjectKey,
    observedAtUtc: observedAtUtc,
    numericValue: numericValue,
    specialDay: specialDay ?? this.specialDay,
    metadata: metadata,
  );
}

enum PreferenceSuggestionKind { preferredTimeWindow, preferredFocusMinutes }

enum PreferenceSuggestionStatus {
  suggested,
  confirmed,
  rejected,
  disabled,
  autoApplied,
}

final class PreferenceSuggestion {
  const PreferenceSuggestion({
    required this.id,
    required this.kind,
    required this.subjectKey,
    required this.evidenceCount,
    required this.activeDayCount,
    required this.observedFromUtc,
    required this.observedToUtc,
    required this.effectDifference,
    required this.explanationCode,
    this.suggestedStartMinute,
    this.suggestedEndMinute,
    this.suggestedFocusMinutes,
    this.status = PreferenceSuggestionStatus.suggested,
  });

  final String id;
  final PreferenceSuggestionKind kind;
  final String subjectKey;
  final int evidenceCount;
  final int activeDayCount;
  final DateTime observedFromUtc;
  final DateTime observedToUtc;
  final double effectDifference;
  final int? suggestedStartMinute;
  final int? suggestedEndMinute;
  final int? suggestedFocusMinutes;
  final String explanationCode;
  final PreferenceSuggestionStatus status;

  PreferenceSuggestion copyWith({
    PreferenceSuggestionStatus? status,
    int? suggestedStartMinute,
    int? suggestedEndMinute,
    int? suggestedFocusMinutes,
  }) => PreferenceSuggestion(
    id: id,
    kind: kind,
    subjectKey: subjectKey,
    evidenceCount: evidenceCount,
    activeDayCount: activeDayCount,
    observedFromUtc: observedFromUtc,
    observedToUtc: observedToUtc,
    effectDifference: effectDifference,
    suggestedStartMinute: suggestedStartMinute ?? this.suggestedStartMinute,
    suggestedEndMinute: suggestedEndMinute ?? this.suggestedEndMinute,
    suggestedFocusMinutes: suggestedFocusMinutes ?? this.suggestedFocusMinutes,
    explanationCode: explanationCode,
    status: status ?? this.status,
  );
}

abstract interface class PreferenceAnalyzer {
  List<PreferenceSuggestion> analyze(
    List<PreferenceEvidence> evidence,
    PreferenceProfile current,
  );
}

final class RuleBasedPreferenceAnalyzer implements PreferenceAnalyzer {
  const RuleBasedPreferenceAnalyzer();

  @override
  List<PreferenceSuggestion> analyze(
    List<PreferenceEvidence> evidence,
    PreferenceProfile current,
  ) {
    if (!current.enabled) return const [];
    final valid = evidence.where((item) => !item.specialDay).toList();
    final suggestions = <PreferenceSuggestion>[
      ..._completionSuggestions(valid),
      ..._manualMoveSuggestions(valid),
    ];
    suggestions.sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(suggestions);
  }

  Iterable<PreferenceSuggestion> _completionSuggestions(
    List<PreferenceEvidence> evidence,
  ) sync* {
    final bySubject = <String, List<PreferenceEvidence>>{};
    for (final item in evidence.where(
      (item) =>
          item.kind == PreferenceEvidenceKind.focusCompletion &&
          item.numericValue != null &&
          item.metadata['timeBucket'] is String,
    )) {
      bySubject.putIfAbsent(item.subjectKey, () => []).add(item);
    }
    for (final entry in bySubject.entries) {
      final items = entry.value;
      final days = items.map((item) => _dateKey(item.observedAtUtc)).toSet();
      if (items.length < 20 || days.length < 14) continue;
      final buckets = <String, List<double>>{};
      for (final item in items) {
        buckets
            .putIfAbsent(item.metadata['timeBucket']! as String, () => [])
            .add(item.numericValue!);
      }
      if (buckets.length < 2) continue;
      final averages = {
        for (final bucket in buckets.entries)
          bucket.key:
              bucket.value.reduce((a, b) => a + b) / bucket.value.length,
      };
      final ordered = averages.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final difference = ordered.first.value - ordered.last.value;
      if (difference < 0.15) continue;
      final range = _bucketRange(ordered.first.key);
      final instants = items.map((item) => item.observedAtUtc).toList()..sort();
      yield PreferenceSuggestion(
        id: 'time:${entry.key}:${ordered.first.key}',
        kind: PreferenceSuggestionKind.preferredTimeWindow,
        subjectKey: entry.key,
        evidenceCount: items.length,
        activeDayCount: days.length,
        observedFromUtc: instants.first,
        observedToUtc: instants.last,
        effectDifference: difference,
        suggestedStartMinute: range.$1,
        suggestedEndMinute: range.$2,
        explanationCode: 'time_bucket_effect_difference',
      );
    }
  }

  Iterable<PreferenceSuggestion> _manualMoveSuggestions(
    List<PreferenceEvidence> evidence,
  ) sync* {
    final groups = <String, List<PreferenceEvidence>>{};
    for (final item in evidence.where(
      (item) =>
          item.kind == PreferenceEvidenceKind.manualMove &&
          item.numericValue != null &&
          item.metadata['direction'] is String,
    )) {
      final key = '${item.subjectKey}:${item.metadata['direction']}';
      groups.putIfAbsent(key, () => []).add(item);
    }
    for (final entry in groups.entries) {
      if (entry.value.length < 5) continue;
      final items = entry.value.toList()
        ..sort((a, b) => a.observedAtUtc.compareTo(b.observedAtUtc));
      final start =
          (items.fold<double>(0, (sum, item) => sum + item.numericValue!) /
                  items.length)
              .round();
      final subject = items.first.subjectKey;
      yield PreferenceSuggestion(
        id: 'move:$subject:${items.first.metadata['direction']}',
        kind: PreferenceSuggestionKind.preferredTimeWindow,
        subjectKey: subject,
        evidenceCount: items.length,
        activeDayCount: items
            .map((item) => _dateKey(item.observedAtUtc))
            .toSet()
            .length,
        observedFromUtc: items.first.observedAtUtc,
        observedToUtc: items.last.observedAtUtc,
        effectDifference: 0,
        suggestedStartMinute: start,
        suggestedEndMinute: (start + 180).clamp(1, 24 * 60),
        explanationCode: 'repeated_manual_move',
      );
    }
  }

  static String _dateKey(DateTime value) =>
      '${value.year}-${value.month}-${value.day}';

  static (int, int) _bucketRange(String bucket) => switch (bucket) {
    'morning' => (8 * 60, 12 * 60),
    'afternoon' => (12 * 60, 18 * 60),
    'evening' => (18 * 60, 23 * 60),
    'night' => (23 * 60, 24 * 60),
    _ => (9 * 60, 12 * 60),
  };
}
