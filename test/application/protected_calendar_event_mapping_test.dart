// 1.8.0（设计规范 §9.1，计划 Task 8 Step 2）：protected occurrence 的**排程映射**。
//
// 这一组钉的是一件事：同一条日历记录**只能进一类占用**，而且保护时间进的是
// `protectedIntervals`（硬禁区），**不是** `fixedIntervals`（被占用的时间）。
//
// 为什么这两者必须分开：固定日程与保护时间在数据里同形，混进 fixed 的后果不是"排错位置"，
// 而是**它会被当成固定日程投入进统计**——用户会看到"固定日程 8 小时/周"里有一半是
// "不许安排"的时间。规范 §9.1 因此逐条列了保护时间"不参与什么"。
//
// **本文件走的是真实装配链**（`RepositoryScheduleProblemSource.load()`），不是手工把
// occurrence 拆成两份再断言——那样测的是测试自己写的拆分逻辑。第一版就是那么写的，
// 已删掉重做。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/domain/models/task.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  final clock = _FixedClock(DateTime.utc(2026, 10, 5, 2));

  DateTime utc(int hour, [int minute = 0]) => zones.localDateTimeToUtc(
    DateTime(2026, 10, 5),
    hour * 60 + minute,
    zoneId,
  );

  CalendarOccurrence occurrence({
    required String id,
    required CalendarEventKind kind,
    required int startHour,
    required int endHour,
  }) => CalendarOccurrence(
    eventId: id,
    title: kind == CalendarEventKind.protected ? '保护时间' : '例会',
    range: TimeRange(startUtc: utc(startHour), endUtc: utc(endHour)),
    locked: true,
    kind: kind,
  );

  Future<ScheduleProblem> load(List<CalendarOccurrence> occurrences) =>
      RepositoryScheduleProblemSource(
        tasks: _EmptyTasks(),
        lifeAreas: _NoLifeAreas(),
        calendar: _FakeCalendar(occurrences),
        settings: SettingsService(repository: MemorySettingsRepository()),
        plans: _NoPlan(),
        clock: clock,
        timeZoneId: zoneId,
        zones: zones,
      ).load();

  test('保护时间只进 protectedIntervals，固定日程只进 fixedIntervals', () async {
    final problem = await load([
      occurrence(
        id: 'evt-fixed',
        kind: CalendarEventKind.fixed,
        startHour: 9,
        endHour: 10,
      ),
      occurrence(
        id: 'evt-protected',
        kind: CalendarEventKind.protected,
        startHour: 14,
        endHour: 15,
      ),
    ]);

    expect(
      problem.fixedIntervals.map((i) => i.id),
      contains('evt-fixed'),
      reason: '固定日程照旧进 fixedIntervals',
    );
    expect(
      problem.fixedIntervals.map((i) => i.id),
      isNot(contains('evt-protected')),
      reason: '保护时间进 fixedIntervals 会被当成"固定日程投入"进统计（规范 §9.1）',
    );
    expect(
      problem.protectedIntervals.map((i) => i.id),
      contains('evt-protected'),
      reason: '保护时间必须成为硬禁区，否则排程会把任务排进用户明确保护的时段',
    );
    expect(
      problem.protectedIntervals.map((i) => i.id),
      isNot(contains('evt-fixed')),
      reason: '固定日程不该变成硬禁区（它是"被占用"，不是"不许安排"）',
    );

    // **同一条记录两边都不得出现**（规范 §9 审查问题 4）。
    final fixedIds = problem.fixedIntervals.map((i) => i.id).toSet();
    final protectedIds = problem.protectedIntervals.map((i) => i.id).toSet();
    expect(
      fixedIds.intersection(protectedIds),
      isEmpty,
      reason: '两份互为补集：同一条记录同时成为 fixed event 与 protected window 是错的',
    );
  });

  test('保护时间的区间原样保留，不被课表缓冲改动', () async {
    final problem = await load([
      occurrence(
        id: 'evt-protected',
        kind: CalendarEventKind.protected,
        startHour: 14,
        endHour: 15,
      ),
    ]);

    final window = problem.protectedIntervals.singleWhere(
      (i) => i.id == 'evt-protected',
    );
    expect(window.range.startUtc, utc(14));
    expect(window.range.endUtc, utc(15));
    expect(
      window.range.durationMinutes,
      60,
      reason: '课后缓冲只作用于 timetableImport 的固定日程；保护时间是硬禁区，不该被改动',
    );
  });

  test('固定日程与保护时间可以落在同一时刻，且互不覆盖', () async {
    // 这是**允许**的：用户可以把"14:00–15:00 的保护时间"和一场"14:00–15:00 的会"
    // 同时建出来。排程层面两者都是不可用时段，引擎只需要知道这段时间不可用；
    // 真正要报冲突的是"计划块与保护时间重叠"，那是 `PlanValidator` 的事。
    final problem = await load([
      occurrence(
        id: 'evt-fixed',
        kind: CalendarEventKind.fixed,
        startHour: 14,
        endHour: 15,
      ),
      occurrence(
        id: 'evt-protected',
        kind: CalendarEventKind.protected,
        startHour: 14,
        endHour: 15,
      ),
    ]);

    expect(problem.fixedIntervals.map((i) => i.id), contains('evt-fixed'));
    expect(
      problem.protectedIntervals.map((i) => i.id),
      contains('evt-protected'),
    );
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _EmptyTasks implements TaskRepository {
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);
  @override
  Future<PlannerTask?> getById(String id) async => null;
  @override
  Future<void> save(PlannerTask task) async {}
}

final class _NoLifeAreas implements LifeAreaLookup {
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

final class _FakeCalendar implements CalendarRepository {
  _FakeCalendar(this.items);
  final List<CalendarOccurrence> items;
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => items
      .where(
        (item) =>
            item.range.overlaps(TimeRange(startUtc: startUtc, endUtc: endUtc)),
      )
      .toList();
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoPlan implements PlanRepository {
  @override
  Future<ConfirmedPlan?> current() async => null;
  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}
