import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

void main() {
  test('自动采用只写入软偏好并可撤销，硬规则保持默认', () async {
    final store = MemoryPreferenceStore();
    final service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: store,
    );
    final suggestions = await service.refresh(
      _strongEvidence(),
      autoApply: true,
    );

    expect(suggestions.single.status, PreferenceSuggestionStatus.autoApplied);
    final applied = await store.loadProfile();
    expect(applied.preferredEnergyWindows, isNotEmpty);
    var resolved = DefaultSettings.resolve(confirmedPreferences: applied);
    expect(resolved.minimumSleepMinutes, 420);
    expect(resolved.dailyMovableTaskLimitMinutes, 360);
    expect(resolved.protectedTimes, hasLength(2));

    final undone = await service.undoLastAutoApply();
    expect(undone, isTrue);
    expect((await store.loadProfile()).preferredEnergyWindows, isNull);
  });

  test('临时例外和用户设置优先于已确认偏好', () async {
    final store = MemoryPreferenceStore();
    final service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: store,
    );
    final suggestion = PreferenceSuggestion(
      id: 'focus-50',
      kind: PreferenceSuggestionKind.preferredFocusMinutes,
      subjectKey: 'global',
      evidenceCount: 20,
      activeDayCount: 14,
      observedFromUtc: DateTime.utc(2026, 9, 1),
      observedToUtc: DateTime.utc(2026, 9, 20),
      effectDifference: 0.2,
      suggestedFocusMinutes: 50,
      explanationCode: 'focus_length_effect',
    );
    await store.saveSuggestion(suggestion);
    await service.confirm(suggestion.id);

    final learned = await store.loadProfile();
    final resolved = DefaultSettings.resolve(
      confirmedPreferences: learned,
      userRules: const PlanningRulesPatch(defaultFocusMinutes: 70),
      dateOverride: const PlanningRulesPatch(defaultFocusMinutes: 80),
    );

    expect(learned.preferredFocusMinutes, 50);
    expect(resolved.defaultFocusMinutes, 80);
    expect(resolved.minimumSleepMinutes, 420);
    expect(resolved.sleepRange, isA<LocalTimeRange>());
  });

  test('拒绝、停用和清除均保留明确状态并可移除学习结果', () async {
    final store = MemoryPreferenceStore();
    final service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: store,
    );
    final suggestions = await service.refresh(_strongEvidence());
    final id = suggestions.single.id;

    await service.reject(id);
    expect(
      (await service.list()).single.status,
      PreferenceSuggestionStatus.rejected,
    );
    await service.confirm(id);
    await service.disable(id);
    expect(
      (await service.list()).single.status,
      PreferenceSuggestionStatus.disabled,
    );
    await service.clearLearned();
    expect(await service.list(), isEmpty);
    expect((await store.loadProfile()).enabled, isFalse);
  });

  test('设置存储在服务重建后保留建议、偏好和自动采用撤销历史', () async {
    final repository = MemorySettingsRepository();
    final first = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: SettingsPreferenceStore(repository),
    );
    await first.refresh(_strongEvidence(), autoApply: true);

    final restoredStore = SettingsPreferenceStore(repository);
    final restored = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: restoredStore,
    );

    expect(
      (await restored.list()).single.status,
      PreferenceSuggestionStatus.autoApplied,
    );
    expect(
      (await restoredStore.loadProfile()).preferredEnergyWindows,
      isNotEmpty,
    );
    expect(await restored.undoLastAutoApply(), isTrue);
    expect((await restoredStore.loadProfile()).preferredEnergyWindows, isNull);
  });
}

List<PreferenceEvidence> _strongEvidence() => [
  for (var index = 0; index < 20; index++)
    PreferenceEvidence(
      id: 'e-$index',
      kind: PreferenceEvidenceKind.focusCompletion,
      subjectKey: 'area:study',
      observedAtUtc: DateTime.utc(
        2026,
        9,
        index % 14 + 1,
        index.isEven ? 9 : 19,
      ),
      numericValue: index.isEven ? 0.9 : 0.6,
      metadata: {'timeBucket': index.isEven ? 'morning' : 'evening'},
    ),
];
