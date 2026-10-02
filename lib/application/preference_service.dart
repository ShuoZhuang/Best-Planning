import 'dart:convert';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

abstract interface class PreferenceStore {
  Future<PreferenceProfile> loadProfile();
  Future<void> saveProfile(PreferenceProfile profile);
  Future<List<PreferenceSuggestion>> loadSuggestions();
  Future<void> saveSuggestion(PreferenceSuggestion suggestion);
  Future<void> clearLearned();
  Future<void> rememberAutoApply(PreferenceProfile previous);
  Future<PreferenceProfile?> takeLastAutoApply();
}

final class MemoryPreferenceStore implements PreferenceStore {
  PreferenceProfile _profile = const PreferenceProfile();
  final Map<String, PreferenceSuggestion> _suggestions = {};
  final List<PreferenceProfile> _autoHistory = [];

  @override
  Future<PreferenceProfile> loadProfile() async => _profile;

  @override
  Future<void> saveProfile(PreferenceProfile profile) async {
    _profile = profile;
  }

  @override
  Future<List<PreferenceSuggestion>> loadSuggestions() async {
    final result = _suggestions.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return result;
  }

  @override
  Future<void> saveSuggestion(PreferenceSuggestion suggestion) async {
    _suggestions[suggestion.id] = suggestion;
  }

  @override
  Future<void> clearLearned() async {
    _profile = const PreferenceProfile(enabled: false);
    _suggestions.clear();
    _autoHistory.clear();
  }

  @override
  Future<void> rememberAutoApply(PreferenceProfile previous) async {
    _autoHistory.add(previous);
  }

  @override
  Future<PreferenceProfile?> takeLastAutoApply() async =>
      _autoHistory.isEmpty ? null : _autoHistory.removeLast();
}

final class SettingsPreferenceStore implements PreferenceStore {
  const SettingsPreferenceStore(this.repository);

  static const _key = 'planning.preferenceState.v1';
  final SettingsRepository repository;

  @override
  Future<PreferenceProfile> loadProfile() async {
    final state = await _load();
    final value = state['profile'];
    return value is Map<String, Object?>
        ? _profileFromJson(value)
        : const PreferenceProfile();
  }

  @override
  Future<void> saveProfile(PreferenceProfile profile) async {
    final state = await _load();
    state['profile'] = _profileToJson(profile);
    await _save(state);
  }

  @override
  Future<List<PreferenceSuggestion>> loadSuggestions() async {
    final state = await _load();
    final raw = state['suggestions'] as List<Object?>? ?? const [];
    final values = raw
        .map((item) => _suggestionFromJson(item! as Map<String, Object?>))
        .toList();
    values.sort((a, b) => a.id.compareTo(b.id));
    return values;
  }

  @override
  Future<void> saveSuggestion(PreferenceSuggestion suggestion) async {
    final state = await _load();
    final raw = state['suggestions'] as List<Object?>? ?? const [];
    final values = raw
        .map((item) => Map<String, Object?>.from(item! as Map))
        .where((item) => item['id'] != suggestion.id)
        .toList();
    values.add(_suggestionToJson(suggestion));
    state['suggestions'] = values;
    await _save(state);
  }

  @override
  Future<void> clearLearned() => _save({
    'profile': _profileToJson(const PreferenceProfile(enabled: false)),
    'suggestions': <Object?>[],
    'autoHistory': <Object?>[],
  });

  @override
  Future<void> rememberAutoApply(PreferenceProfile previous) async {
    final state = await _load();
    final history = List<Object?>.from(
      state['autoHistory'] as List<Object?>? ?? const [],
    )..add(_profileToJson(previous));
    state['autoHistory'] = history;
    await _save(state);
  }

  @override
  Future<PreferenceProfile?> takeLastAutoApply() async {
    final state = await _load();
    final history = List<Object?>.from(
      state['autoHistory'] as List<Object?>? ?? const [],
    );
    if (history.isEmpty) return null;
    final previous = _profileFromJson(
      history.removeLast()! as Map<String, Object?>,
    );
    state['autoHistory'] = history;
    await _save(state);
    return previous;
  }

  Future<Map<String, Object?>> _load() async {
    final raw = await repository.read(_key);
    if (raw == null) return <String, Object?>{};
    return Map<String, Object?>.from(jsonDecode(raw) as Map);
  }

  Future<void> _save(Map<String, Object?> value) =>
      repository.write(_key, jsonEncode(value));
}

final class PreferenceService {
  const PreferenceService({required this.analyzer, required this.store});

  final PreferenceAnalyzer analyzer;
  final PreferenceStore store;

  Future<List<PreferenceSuggestion>> refresh(
    List<PreferenceEvidence> evidence, {
    bool autoApply = false,
  }) async {
    final current = await store.loadProfile();
    final suggestions = analyzer.analyze(evidence, current);
    for (final suggestion in suggestions) {
      var value = suggestion;
      if (autoApply) {
        await store.rememberAutoApply(await store.loadProfile());
        await store.saveProfile(_apply(await store.loadProfile(), suggestion));
        value = suggestion.copyWith(
          status: PreferenceSuggestionStatus.autoApplied,
        );
      }
      await store.saveSuggestion(value);
    }
    return [
      for (final suggestion in suggestions)
        (await list()).singleWhere((item) => item.id == suggestion.id),
    ];
  }

  Future<List<PreferenceSuggestion>> list() => store.loadSuggestions();

  Future<void> confirm(String id) =>
      _change(id, PreferenceSuggestionStatus.confirmed, apply: true);

  Future<void> reject(String id) =>
      _change(id, PreferenceSuggestionStatus.rejected);

  Future<void> disable(String id) async {
    await _change(id, PreferenceSuggestionStatus.disabled);
    final current = await store.loadProfile();
    await store.saveProfile(current.copyWith(enabled: false));
  }

  Future<void> clearLearned() => store.clearLearned();

  Future<bool> undoLastAutoApply() async {
    final previous = await store.takeLastAutoApply();
    if (previous == null) return false;
    await store.saveProfile(previous);
    return true;
  }

  Future<void> _change(
    String id,
    PreferenceSuggestionStatus status, {
    bool apply = false,
  }) async {
    final suggestion = (await list()).singleWhere((item) => item.id == id);
    if (apply) {
      await store.saveProfile(_apply(await store.loadProfile(), suggestion));
    }
    await store.saveSuggestion(suggestion.copyWith(status: status));
  }

  PreferenceProfile _apply(
    PreferenceProfile current,
    PreferenceSuggestion suggestion,
  ) => switch (suggestion.kind) {
    PreferenceSuggestionKind.preferredFocusMinutes => current.copyWith(
      preferredFocusMinutes: suggestion.suggestedFocusMinutes,
      enabled: true,
    ),
    PreferenceSuggestionKind.preferredTimeWindow => current.copyWith(
      preferredEnergyWindows: [
        EnergyWindow(
          range: LocalTimeRange(
            startMinute: suggestion.suggestedStartMinute!,
            endMinute: suggestion.suggestedEndMinute!,
          ),
          level: EnergyLevel.high,
        ),
      ],
      enabled: true,
    ),
  };
}

Map<String, Object?> _profileToJson(PreferenceProfile profile) => {
  'enabled': profile.enabled,
  'preferredFocusMinutes': profile.preferredFocusMinutes,
  'preferredEnergyWindows': profile.preferredEnergyWindows
      ?.map(
        (window) => {
          'startMinute': window.range.startMinute,
          'endMinute': window.range.endMinute,
          'level': window.level.name,
          'dayKind': window.dayKind.name,
        },
      )
      .toList(),
};

PreferenceProfile _profileFromJson(Map<String, Object?> value) {
  final rawWindows = value['preferredEnergyWindows'] as List<Object?>?;
  return PreferenceProfile(
    enabled: value['enabled'] as bool? ?? true,
    preferredFocusMinutes: value['preferredFocusMinutes'] as int?,
    preferredEnergyWindows: rawWindows
        ?.map((raw) {
          final window = raw! as Map<String, Object?>;
          return EnergyWindow(
            range: LocalTimeRange(
              startMinute: window['startMinute']! as int,
              endMinute: window['endMinute']! as int,
            ),
            level: EnergyLevel.values.byName(window['level']! as String),
            dayKind: DayKind.values.byName(window['dayKind']! as String),
          );
        })
        .toList(growable: false),
  );
}

Map<String, Object?> _suggestionToJson(PreferenceSuggestion value) => {
  'id': value.id,
  'kind': value.kind.name,
  'subjectKey': value.subjectKey,
  'evidenceCount': value.evidenceCount,
  'activeDayCount': value.activeDayCount,
  'observedFromUtc': value.observedFromUtc.toIso8601String(),
  'observedToUtc': value.observedToUtc.toIso8601String(),
  'effectDifference': value.effectDifference,
  'suggestedStartMinute': value.suggestedStartMinute,
  'suggestedEndMinute': value.suggestedEndMinute,
  'suggestedFocusMinutes': value.suggestedFocusMinutes,
  'explanationCode': value.explanationCode,
  'status': value.status.name,
};

PreferenceSuggestion _suggestionFromJson(Map<String, Object?> value) =>
    PreferenceSuggestion(
      id: value['id']! as String,
      kind: PreferenceSuggestionKind.values.byName(value['kind']! as String),
      subjectKey: value['subjectKey']! as String,
      evidenceCount: value['evidenceCount']! as int,
      activeDayCount: value['activeDayCount']! as int,
      observedFromUtc: DateTime.parse(value['observedFromUtc']! as String)
          .toUtc(),
      observedToUtc: DateTime.parse(value['observedToUtc']! as String).toUtc(),
      effectDifference: (value['effectDifference']! as num).toDouble(),
      suggestedStartMinute: value['suggestedStartMinute'] as int?,
      suggestedEndMinute: value['suggestedEndMinute'] as int?,
      suggestedFocusMinutes: value['suggestedFocusMinutes'] as int?,
      explanationCode: value['explanationCode']! as String,
      status: PreferenceSuggestionStatus.values.byName(
        value['status']! as String,
      ),
    );
