import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/extension_day_service.dart';
import 'package:personal_planner/application/preference_evidence_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_day_exception_repository.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/preference_evidence_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

final _zones = TimeZoneDatabase();
const _zone = 'Asia/Shanghai';
final _date = DateTime(2026, 10, 17);

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

ScheduleProblem _problem(String hash) {
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
      for (var index = 0; index < 2; index++)
        DateTime(2026, 10, 17 + index): DailySchedulingPolicy(
          localDate: DateTime(2026, 10, 17 + index),
          resolvedRules: rules,
          softReserveTargetMinutes: 0,
        ),
    },
    weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
    preferences: const PreferenceProfile(),
    inputHash: hash,
  );
}

ScheduleProposal _proposal(String hash) => ScheduleProposal(
  proposalId: 'proposal-$hash',
  inputHash: hash,
  algorithmVersion: '20',
  planningWindow: TimeRange(
    startUtc: _zones.localMidnightToUtc(_date, _zone),
    endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 19), _zone),
  ),
  blocks: const [],
  unscheduled: [
    UnscheduledTask(
      taskId: 'trigger',
      shortageMinutes: 60,
      primaryReason: const UnscheduledReason(
        code: UnscheduledReasonCode.insufficientCapacity,
        placementRemainingMinutes: 60,
      ),
    ),
  ],
  conflicts: const [],
  explanations: const [],
  metrics: const ProposalMetrics(
    isFullyFeasible: false,
    scheduledMinutes: 0,
    unscheduledMinutes: 60,
  ),
  outcome: SearchOutcomeKind.hardInfeasible,
);

void main() {
  late AppDatabase database;
  late ExtensionDayService service;
  late MemoryExtensionRejectionStore rejectionStore;
  late _MemoryEvidence evidence;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = SettingsService(repository: MemorySettingsRepository());
    final dayService = DayExceptionService(
      repository: DriftDayExceptionRepository(database),
      settings: settings,
      clock: const _Clock(),
      zones: _zones,
      timeZoneId: _zone,
    );
    rejectionStore = MemoryExtensionRejectionStore();
    evidence = _MemoryEvidence();
    service = ExtensionDayService(
      settings: settings,
      dayExceptions: dayService,
      zones: _zones,
      clock: const _Clock(),
      rejectionStore: rejectionStore,
      evidence: PreferenceEvidenceService(
        evidence: evidence,
        clock: const _Clock(),
        zones: _zones,
        timeZoneId: _zone,
        idGenerator: _Ids(),
      ),
    );
  });

  tearDown(() => database.close());

  test('拒绝后相同输入不再提出，输入哈希变化后重新允许', () async {
    final first = await service.propose(
      problem: _problem('hash-a'),
      proposal: _proposal('hash-a'),
    );
    expect(first, isNotEmpty);

    await service.reject(inputHash: 'hash-a', candidates: first);
    expect(
      evidence.rows.where(
        (row) =>
            row.kind == PreferenceEvidenceKind.suggestionAction &&
            row.metadata['action'] == 'rejected',
      ),
      isNotEmpty,
    );
    expect(
      await service.propose(
        problem: _problem('hash-a'),
        proposal: _proposal('hash-a'),
      ),
      isEmpty,
    );

    // 任务/规则/日程变化 ⇒ inputHash 变化 ⇒ 允许重新建议。
    final changed = await service.propose(
      problem: _problem('hash-b'),
      proposal: _proposal('hash-b'),
    );
    expect(changed, isNotEmpty);
    // 记忆键与候选键都带哈希，旧拒绝不会误伤新输入。
    expect(changed.first.stableKey, first.first.stableKey);
  });

  test('预算耗尽与结构异常不提出延长日', () async {
    final budget = ScheduleProposal(
      proposalId: 'budget',
      inputHash: 'hash-a',
      algorithmVersion: '20',
      planningWindow: _problem('hash-a').planningWindow,
      blocks: const [],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: false,
        scheduledMinutes: 0,
        unscheduledMinutes: 0,
      ),
      outcome: SearchOutcomeKind.budgetExhausted,
    );
    expect(
      await service.propose(problem: _problem('hash-a'), proposal: budget),
      isEmpty,
    );
  });
}
