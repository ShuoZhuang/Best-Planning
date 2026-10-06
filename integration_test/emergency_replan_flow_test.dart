import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

/// 端到端流程：临时事件（晚归）占用原有时间后重新排程。
///
/// 断言的是硬约束在重排之后仍然成立：不占用固定日程、不占用保护时间（含午餐、
/// 晚餐这些需要逐日展开的规则）、不占用睡眠区间；若确实排不下，必须如实报告
/// 缺口而不是静默少排。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const timeZoneId = 'Asia/Shanghai';

  test('临时晚归后重排不会占用固定安排、保护时间或睡眠', () async {
    final zones = TimeZoneDatabase();
    const clock = SystemClock();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final taskRepository = DriftTaskRepository(database.taskDao);
    final calendarRepository = DriftCalendarRepository(database);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final settingsService = SettingsService(repository: settingsRepository);
    final source = RepositoryScheduleProblemSource(
      tasks: taskRepository,
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendarRepository,
      settings: settingsService,
      plans: planRepository,
      clock: clock,
      timeZoneId: timeZoneId,
      zones: zones,
    );
    final engine = DeterministicScheduleEngine(zones);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final workspaceService = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );
    await workspaceService.ensureDefaultAreas();
    final researchArea = (await workspaceService.listAreas()).firstWhere(
      (area) => area.name == '科研',
    );
    final taskService = TaskService(
      repository: taskRepository,
      workspace: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );

    await taskService.saveDraft(
      TaskDraft(title: '科研', estimatedMinutes: 240, areaId: researchArea.id),
    );
    final before = engine.generate(await source.load());
    expect(before.blocks, isNotEmpty);

    // 临时外出到次日凌晨：这是单日例外，不应改写长期作息规则。
    final today = _dateOnly(zones.toLocal(clock.nowUtc(), timeZoneId));
    await calendarRepository.save(
      CalendarEvent(
        id: 'late-night-out',
        title: '临时外出',
        startAtUtc: zones.localDateTimeToUtc(today, 20 * 60, timeZoneId),
        endAtUtc: zones.localDateTimeToUtc(
          today.add(const Duration(days: 1)),
          2 * 60,
          timeZoneId,
        ),
        timeZoneId: timeZoneId,
        updatedAtUtc: clock.nowUtc(),
      ),
    );

    final problem = await source.load();
    final proposal = engine.generate(problem);

    for (final block in proposal.blocks) {
      expect(
        problem.planningWindow.contains(block.startUtc),
        isTrue,
        reason: '时间块必须落在规划窗口内',
      );
      for (final busy in [
        ...problem.fixedIntervals,
        ...problem.protectedIntervals,
      ]) {
        expect(
          busy.range.overlaps(block.range),
          isFalse,
          reason: '不得占用固定日程或保护时间（${busy.id}）',
        );
      }
    }

    // 睡眠区间（默认 23:30–07:30）必须逐日避开。
    for (var day = 0; day < 7; day++) {
      final date = today.add(Duration(days: day));
      final sleep = TimeRange(
        startUtc: zones.localDateTimeToUtc(date, 23 * 60 + 30, timeZoneId),
        endUtc: zones.localDateTimeToUtc(
          date.add(const Duration(days: 1)),
          7 * 60 + 30,
          timeZoneId,
        ),
      );
      for (final block in proposal.blocks) {
        expect(
          sleep.overlaps(block.range),
          isFalse,
          reason: '不得占用睡眠时间（${sleep.startUtc}）',
        );
      }
    }

    // 排不下时必须如实报告，不得静默少排。
    expect(
      proposal.metrics.isFullyFeasible || proposal.unscheduled.isNotEmpty,
      isTrue,
      reason: '不可行时必须在 unscheduled 中给出缺口',
    );

    // 长期作息规则不被临时事件改写。
    final resolved = await PlanningRuleResolver(settingsService)
        .resolveForWindow(today);
    expect(resolved.sleepRange.startMinute, 23 * 60 + 30);
  });
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
