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

  /// 用户改过建议值，但还没确认；刷新不得把它降回待确认。
  edited,
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
    final v2 = evidence.where(_isVersion2).toList(growable: false);
    if (v2.isNotEmpty) {
      final suggestions = <PreferenceSuggestion>[
        ..._v2TimeSuggestions(v2),
        ..._v2FocusSuggestions(v2),
      ]..sort((a, b) => a.id.compareTo(b.id));
      return List.unmodifiable(suggestions);
    }
    // 旧证据只走旧口径；它们不得与新分数混算（规范 §9.3）。
    final valid = evidence.where((item) => !item.specialDay).toList();
    final suggestions = <PreferenceSuggestion>[
      ..._completionSuggestions(valid),
      ..._manualMoveSuggestions(valid),
    ];
    suggestions.sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(suggestions);
  }

  static bool _isVersion2(PreferenceEvidence item) =>
      item.metadata['evidenceVersion'] == 2;

  Iterable<PreferenceSuggestion> _v2TimeSuggestions(
    List<PreferenceEvidence> evidence,
  ) sync* {
    final bySubject = <String, List<PreferenceEvidence>>{};
    for (final item in evidence.where(
      (item) =>
          item.kind == PreferenceEvidenceKind.focusCompletion &&
          item.metadata['effectScorePermille'] is int &&
          item.metadata['timeBucket'] is String &&
          item.metadata['excludedReason'] == null &&
          !item.specialDay,
    )) {
      bySubject.putIfAbsent(item.subjectKey, () => []).add(item);
    }
    for (final entry in bySubject.entries) {
      final items = entry.value;
      final days = items.map(_observedLocalDate).toSet();
      if (items.length < 20 || days.length < 14) continue;
      final buckets = <String, List<int>>{};
      for (final item in items) {
        final bucket = item.metadata['timeBucket']! as String;
        buckets
            .putIfAbsent(bucket, () => [])
            .add(item.metadata['effectScorePermille']! as int);
      }
      final eligible =
          buckets.entries.where((bucket) => bucket.value.length >= 5).toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      if (eligible.length < 2) continue;
      final medianByBucket = {
        for (final bucket in eligible) bucket.key: _median(bucket.value),
      };
      final ordered = eligible.toList()
        ..sort((a, b) {
          final byMedian = medianByBucket[b.key]!.compareTo(
            medianByBucket[a.key]!,
          );
          return byMedian != 0 ? byMedian : a.key.compareTo(b.key);
        });
      final bestBucket = ordered[0].key;
      final secondBucket = ordered[1].key;
      final difference =
          medianByBucket[bestBucket]! - medianByBucket[secondBucket]!;
      if (difference < 150) continue;
      if (_bootstrapLowerBound(buckets[bestBucket]!, buckets[secondBucket]!) <
          100) {
        continue;
      }
      final range = _v2BucketRange(bestBucket);
      final sortedInstants = items.map((item) => item.observedAtUtc).toList()
        ..sort();
      yield PreferenceSuggestion(
        id: 'time:${entry.key}:$bestBucket:${range.$1}-${range.$2}:v2',
        kind: PreferenceSuggestionKind.preferredTimeWindow,
        subjectKey: entry.key,
        evidenceCount: items.length,
        activeDayCount: days.length,
        observedFromUtc: sortedInstants.first,
        observedToUtc: sortedInstants.last,
        // 对外仍以 0..1 表示（页面只显示无量纲比例），内部阈值是 150/1000。
        effectDifference: difference / 1000,
        suggestedStartMinute: range.$1,
        suggestedEndMinute: range.$2,
        explanationCode: 'v2_time_bucket_median_difference',
      );
    }
  }

  Iterable<PreferenceSuggestion> _v2FocusSuggestions(
    List<PreferenceEvidence> evidence,
  ) sync* {
    final bySubject = <String, List<PreferenceEvidence>>{};
    for (final item in evidence.where(
      (item) =>
          item.kind == PreferenceEvidenceKind.focusCompletion &&
          item.metadata['actualFocusMinutes'] is int &&
          (item.metadata['actualFocusMinutes']! as int) > 0 &&
          item.metadata['excludedReason'] == null &&
          !item.specialDay,
    )) {
      bySubject.putIfAbsent(item.subjectKey, () => []).add(item);
    }
    for (final entry in bySubject.entries) {
      final items = entry.value;
      final days = items.map(_observedLocalDate).toSet();
      if (items.length < 20 || days.length < 14) continue;
      final minutes =
          items
              .map((item) => item.metadata['actualFocusMinutes']! as int)
              .toList()
            ..sort();
      // 五分钟粒度的稳健中位数（取较低中位数，再四舍五入到 5 分钟）。
      final median = minutes[(minutes.length - 1) ~/ 2];
      final rounded = ((median + 2) ~/ 5) * 5;
      final value = rounded.clamp(15, 180);
      final sortedInstants = items.map((item) => item.observedAtUtc).toList()
        ..sort();
      yield PreferenceSuggestion(
        id: 'focus:${entry.key}:$value:v2',
        kind: PreferenceSuggestionKind.preferredFocusMinutes,
        subjectKey: entry.key,
        evidenceCount: items.length,
        activeDayCount: days.length,
        observedFromUtc: sortedInstants.first,
        observedToUtc: sortedInstants.last,
        effectDifference: 0,
        suggestedFocusMinutes: value,
        explanationCode: 'v2_focus_length_median',
      );
    }
  }

  static DateTime _observedLocalDate(PreferenceEvidence item) {
    final raw = item.metadata['observedLocalDate'];
    if (raw is String) {
      final parts = raw.split('-');
      if (parts.length == 3) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year != null && month != null && day != null) {
          return DateTime(year, month, day);
        }
      }
    }
    return DateTime(
      item.observedAtUtc.year,
      item.observedAtUtc.month,
      item.observedAtUtc.day,
    );
  }

  static int _median(List<int> values) {
    final sorted = [...values]..sort();
    return sorted[(sorted.length - 1) ~/ 2];
  }

  /// 固定种子、固定重采样次数的确定性自助法下界。
  static int _bootstrapLowerBound(List<int> best, List<int> second) {
    const samples = 200;
    const seed = 0x5EED1234;
    var state = seed;
    int nextInt(int max) {
      state ^= (state << 13) & 0xFFFFFFFF;
      state ^= state >> 17;
      state ^= (state << 5) & 0xFFFFFFFF;
      return (state & 0x7FFFFFFF) % max;
    }

    final differences = <int>[];
    for (var sample = 0; sample < samples; sample++) {
      final a = <int>[
        for (var index = 0; index < best.length; index++)
          best[nextInt(best.length)],
      ];
      final b = <int>[
        for (var index = 0; index < second.length; index++)
          second[nextInt(second.length)],
      ];
      differences.add(_median(a) - _median(b));
    }
    differences.sort();
    return differences[(differences.length * 5) ~/ 100];
  }

  static (int, int) _v2BucketRange(String bucket) => switch (bucket) {
    'morning' => (5 * 60, 12 * 60),
    'afternoon' => (12 * 60, 18 * 60),
    'evening' => (18 * 60, 23 * 60),
    'night' => (23 * 60, 5 * 60),
    _ => (9 * 60, 12 * 60),
  };

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
