import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/extension_day_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_evidence_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/special_day_planning_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/preference_evidence_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final _zones = TimeZoneDatabase();
const _zone = 'Asia/Shanghai';
final _date = DateTime(2026, 10, 17);

ExtensionDayCandidate _candidate() => ExtensionDayCandidate(
  localDate: _date,
  originalSleepStartOffsetMinutes: 1410,
  temporarySleepStartOffsetMinutes: 1500,
  fixedWakeOffsetMinutes: 1890,
  addedPlaceableMinutes: 60,
  sleepLossMinutes: 90,
  triggeringTaskIds: const ['trigger'],
  stableKey: '2026-10-17|1500|1890|trigger',
);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _zones.localDateTimeToUtc(_date, 12 * 60, _zone);
}

final class _Ids implements IdGenerator {
  int _next = 0;
  @override
  String next() => 'ev-${_next++}';
}

final class _MemoryEvidence implements PreferenceEvidenceRepository {
  final List<PreferenceEvidence> rows = [];

  @override
  Future<void> save(PreferenceEvidence evidence) async => rows.add(evidence);

  @override
  Future<List<PreferenceEvidence>> since(DateTime sinceUtc) async => rows;
}

/// 不经过 Isolate 的提案生成器：widget 测试的 fake async 会卡住 `Isolate.run`。
final class _ImmediateCreator implements ProposalCreator {
  _ImmediateCreator(this.source);
  final _Source source;

  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
  }) async {
    final problem = await source.load(override: override);
    final hash = const InputSnapshotBuilder().hash(
      InputSnapshot(problem: problem),
    );
    return ScheduleProposal(
      proposalId: 'immediate-$hash',
      inputHash: hash,
      algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
      planningWindow: problem.planningWindow,
      blocks: const [],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 0,
        unscheduledMinutes: 0,
      ),
      ruleOverride: override,
    );
  }
}

final class _Source implements ScheduleProblemSource {
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async {
    final rules = DefaultSettings.v1().copyWith(
      sleepRange: LocalTimeRange(
        startMinute: 23 * 60 + 30,
        endMinute: 7 * 60 + 30,
      ),
    );
    final window = TimeRange(
      startUtc: _zones.localMidnightToUtc(_date, _zone),
      endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 19), _zone),
    );
    final exception = override?.dayException;
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: _zone,
      tasks: [
        SchedulableTask(
          id: 'trigger',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          dueAtUtc: _zones.localDateTimeToUtc(
            DateTime(2026, 10, 18),
            2 * 60,
            _zone,
          ),
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: {
        for (final entry in {
          DateTime(2026, 10, 17): null,
          DateTime(2026, 10, 18): null,
        }.entries)
          entry.key: DailySchedulingPolicy(
            localDate: entry.key,
            resolvedRules: rules,
            softReserveTargetMinutes: 0,
            dayException: exception != null && exception.localDate == entry.key
                ? exception
                : null,
          ),
      },
      weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
      preferences: const PreferenceProfile(),
      inputHash: '',
      dayExceptions: [?exception],
    );
  }
}

void main() {
  test('自定义延长日先生成预览提案、零写入；确认后原子落库', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'trigger', 'Trigger', '', 'medium', 60, 60,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
    final settings = SettingsService(repository: MemorySettingsRepository());
    final dayRepository = DriftDayExceptionRepository(database);
    final dayService = DayExceptionService(
      repository: dayRepository,
      settings: settings,
      clock: const _Clock(),
      zones: _zones,
      timeZoneId: _zone,
    );
    final extensionDays = ExtensionDayService(
      settings: settings,
      dayExceptions: dayService,
      zones: _zones,
      clock: const _Clock(),
    );
    final planning = _ImmediateCreator(_Source());
    final evidence = _MemoryEvidence();
    final application = PlanApplicationService(
      source: _Source(),
      repository: DriftPlanRepository(database, clock: const _Clock()),
      zones: _zones,
      preferenceEvidence: PreferenceEvidenceService(
        evidence: evidence,
        clock: const _Clock(),
        zones: _zones,
        timeZoneId: _zone,
        idGenerator: _Ids(),
      ),
    );
    final service = SpecialDayPlanningService(
      planning: planning,
      application: application,
      settings: settings,
      zones: _zones,
      timeZoneId: _zone,
      clock: const _Clock(),
      dayExceptionService: dayService,
      problemSource: _Source(),
      extensionDays: extensionDays,
    );

    final preview = await service.prepareCustom(
      localDate: _date,
      endMinute: 60,
      triggeringTaskIds: const ['trigger'],
    );

    expect(preview.confirmedDayException, isNotNull);
    expect(
      preview.confirmedDayException!.temporarySleepStartOffsetMinutes,
      1500,
    );
    expect(await database.select(database.dayExceptions).get(), isEmpty);
    expect(await database.select(database.planVersions).get(), isEmpty);

    final result = await application.apply(preview);
    expect(result.status, ApplyPlanStatus.applied);
    final saved = await dayRepository.findConfirmed(_date);
    expect(saved?.temporarySleepStartOffsetMinutes, 1500);
    expect(saved?.source, 'extensionCustom');
    expect(await database.select(database.planVersions).get(), hasLength(1));
    final accepted = evidence.rows.where(
      (row) =>
          row.kind == PreferenceEvidenceKind.suggestionAction &&
          row.metadata['action'] == 'accepted',
    );
    expect(accepted, isNotEmpty);
  });

  testWidgets('页面确认经路由回调原子应用，接受证据只写一次且重载仍在', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'trigger', 'Trigger', '', 'medium', 60, 60,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
    final settings = SettingsService(repository: MemorySettingsRepository());
    final dayRepository = DriftDayExceptionRepository(database);
    final dayService = DayExceptionService(
      repository: dayRepository,
      settings: settings,
      clock: const _Clock(),
      zones: _zones,
      timeZoneId: _zone,
    );
    final extensionDays = ExtensionDayService(
      settings: settings,
      dayExceptions: dayService,
      zones: _zones,
      clock: const _Clock(),
    );
    final planning = _ImmediateCreator(_Source());
    final evidence = _MemoryEvidence();
    final application = PlanApplicationService(
      source: _Source(),
      repository: DriftPlanRepository(database, clock: const _Clock()),
      zones: _zones,
      preferenceEvidence: PreferenceEvidenceService(
        evidence: evidence,
        clock: const _Clock(),
        zones: _zones,
        timeZoneId: _zone,
        idGenerator: _Ids(),
      ),
    );
    final service = SpecialDayPlanningService(
      planning: planning,
      application: application,
      settings: settings,
      zones: _zones,
      timeZoneId: _zone,
      clock: const _Clock(),
      dayExceptionService: dayService,
      problemSource: _Source(),
      extensionDays: extensionDays,
    );
    final preview = await service.prepareCustom(
      localDate: _date,
      endMinute: 60,
      triggeringTaskIds: const ['trigger'],
    );
    var confirmCalls = 0;
    final router = GoRouter(
      initialLocation: '/preview',
      routes: [
        GoRoute(
          path: '/preview',
          builder: (context, state) => PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: preview.proposalId,
              changes: const [],
              issues: const [],
              isStale: false,
            ),
            autoAdjustStore: MemoryAutoAdjustStore(),
            zones: _zones,
            timeZoneId: _zone,
            onConfirm: (mode) async {
              confirmCalls++;
              return application.apply(preview, mode: mode);
            },
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(await database.select(database.planVersions).get(), isEmpty);
    expect(await database.select(database.dayExceptions).get(), isEmpty);
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();

    expect(confirmCalls, 1);
    expect(await database.select(database.planVersions).get(), hasLength(1));
    expect(await database.select(database.dayExceptions).get(), hasLength(1));
    final accepted = evidence.rows.where(
      (row) =>
          row.kind == PreferenceEvidenceKind.suggestionAction &&
          row.metadata['action'] == 'accepted',
    );
    expect(accepted, hasLength(1));

    // 页面重载后仍读得到已落库的事实。
    await tester.pumpWidget(const MaterialApp(home: Text('reloaded')));
    expect(await dayRepository.findConfirmed(_date), isNotNull);
    expect(await database.select(database.planVersions).get(), hasLength(1));
    expect(accepted, hasLength(1));
  });

  testWidgets('自定义日期/时间经路由生成预览，确认后证据与计划各写一次', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'trigger', 'Trigger', '', 'medium', 60, 60,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
    final settings = SettingsService(repository: MemorySettingsRepository());
    final dayRepository = DriftDayExceptionRepository(database);
    final dayService = DayExceptionService(
      repository: dayRepository,
      settings: settings,
      clock: const _Clock(),
      zones: _zones,
      timeZoneId: _zone,
    );
    final extensionDays = ExtensionDayService(
      settings: settings,
      dayExceptions: dayService,
      zones: _zones,
      clock: const _Clock(),
    );
    final evidence = _MemoryEvidence();
    final application = PlanApplicationService(
      source: _Source(),
      repository: DriftPlanRepository(database, clock: const _Clock()),
      zones: _zones,
      preferenceEvidence: PreferenceEvidenceService(
        evidence: evidence,
        clock: const _Clock(),
        zones: _zones,
        timeZoneId: _zone,
        idGenerator: _Ids(),
      ),
    );
    final service = SpecialDayPlanningService(
      planning: _ImmediateCreator(_Source()),
      application: application,
      settings: settings,
      zones: _zones,
      timeZoneId: _zone,
      clock: const _Clock(),
      dayExceptionService: dayService,
      problemSource: _Source(),
      extensionDays: extensionDays,
    );
    ScheduleProposal? prepared;
    late GoRouter router;
    router = GoRouter(
      initialLocation: '/custom',
      routes: [
        GoRoute(
          path: '/custom',
          builder: (context, state) => PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: 'initial',
              changes: const [],
              issues: const [],
              isStale: false,
              extensionCandidates: [_candidate()],
            ),
            autoAdjustStore: MemoryAutoAdjustStore(),
            zones: _zones,
            timeZoneId: _zone,
            onConfirm: (mode) async => ApplyPlanResult.stale(),
            onCustomExtension: (date, endMinute) async {
              prepared = await service.prepareCustom(
                localDate: date,
                endMinute: endMinute,
                triggeringTaskIds: const ['trigger'],
              );
              router.go('/preview');
            },
          ),
        ),
        GoRoute(
          path: '/preview',
          builder: (context, state) => PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: prepared!.proposalId,
              changes: const [],
              issues: const [],
              isStale: false,
            ),
            autoAdjustStore: MemoryAutoAdjustStore(),
            zones: _zones,
            timeZoneId: _zone,
            onConfirm: (mode) async => application.apply(prepared!, mode: mode),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('custom-extension-day')));
    await tester.pumpAndSettle();

    // 日期选择器保持初始日期（10 月 17 日），直接确定。
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    // 时间选择器保持候选的 01:00，直接确定。
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(prepared, isNotNull);
    expect(await database.select(database.planVersions).get(), isEmpty);
    expect(find.text('确认应用'), findsOneWidget);
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();

    expect(await database.select(database.planVersions).get(), hasLength(1));
    final saved = await dayRepository.findConfirmed(_date);
    expect(saved?.source, 'extensionCustom');
    final accepted = evidence.rows.where(
      (row) =>
          row.kind == PreferenceEvidenceKind.suggestionAction &&
          row.metadata['action'] == 'accepted',
    );
    expect(accepted, hasLength(1));

    await tester.pumpWidget(const MaterialApp(home: Text('reloaded')));
    expect(await dayRepository.findConfirmed(_date), isNotNull);
  });
}
