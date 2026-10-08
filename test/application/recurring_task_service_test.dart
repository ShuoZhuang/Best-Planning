import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';

final class _FixedClock implements Clock {
  _FixedClock(this.instant);
  DateTime instant;
  @override
  DateTime nowUtc() => instant;
}

/// 生成、结算与进度（路线图 §11 Task 6 / §3.3 / §7.2）。
///
/// 用**真实的内存 Drift 库**而不是内存假仓储：本组要证明的恰好是"唯一约束与事务真的
/// 生效"（重复启动、重复调用、恢复备份后重跑），而这些约束只存在于数据库里。
void main() {
  late db.AppDatabase database;
  late RecurringTaskRepository repository;
  late DriftTaskRepository tasks;
  late _FixedClock clock;
  late RecurringTaskService service;
  late List<ScheduleInputChange> changes;

  const timeZoneId = 'Asia/Shanghai';

  // 2026-10-07 是周三，本地时间（UTC+8）。启动窗口＝本周三到下周三。
  final wednesday = DateTime.utc(2026, 10, 7, 4);
  final weekStart = DateTime(2026, 10, 5);
  final nextWeekStart = DateTime(2026, 10, 12);

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftRecurringTaskRepository(
      database,
      RecurringTaskDao(database),
    );
    tasks = DriftTaskRepository(database.taskDao);
    clock = _FixedClock(wednesday);
    changes = <ScheduleInputChange>[];
    service = RecurringTaskService(
      repository: repository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      zones: TimeZoneDatabase(),
      timeZoneId: timeZoneId,
      tasks: tasks,
      onScheduleInputChanged: changes.add,
    );
  });

  tearDown(() => database.close());

  RecurringTaskTemplate template({
    String id = 'template-1',
    String title = '每周英语',
    int targetMinutes = 180,
    RecurringTemplateStatus status = RecurringTemplateStatus.active,
    bool carryOver = false,
    RecurringPace pace = RecurringPace.even,
    DateTime? startsOn,
    DateTime? endsOn,
    DateTime? pausedUntil,
  }) => RecurringTaskTemplate(
    id: id,
    title: title,
    areaId: null,
    targetMinutes: targetMinutes,
    priority: TaskPriority.medium,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 25,
    maxChunkMinutes: 90,
    pace: pace,
    carryOverUnfinished: carryOver,
    startsOnLocalDate: startsOn ?? DateTime(2026, 9, 28),
    endsOnLocalDate: endsOn,
    pausedUntilLocalDate: pausedUntil,
    timeZoneId: timeZoneId,
    status: status,
    createdAtUtc: DateTime.utc(2026, 9, 28),
    updatedAtUtc: DateTime.utc(2026, 9, 28),
  );

  /// 本周三到下周三的滚动窗口（与生产里的七天窗口同形）。
  TimeRange windowFrom(DateTime nowUtc) =>
      TimeRange(startUtc: nowUtc, endUtc: nowUtc.add(const Duration(days: 7)));

  Future<RecurringCycleRun> ensure([DateTime? nowUtc]) {
    final now = nowUtc ?? clock.nowUtc();
    return service.ensureCycles(windowFrom(now), now);
  }

  group('幂等生成', () {
    test('连续启动十次：同一模板同一周只有一个实例，且不重复写入任务', () async {
      await repository.saveTemplate(template());
      for (var attempt = 0; attempt < 10; attempt++) {
        await ensure();
      }
      final cycles = await repository.listCyclesInRange(
        weekStart,
        nextWeekStart.add(const Duration(days: 6)),
      );
      expect(cycles, hasLength(2), reason: '本周与下周各一个，不多不少');
      expect(
        cycles.where((c) => c.periodStartLocalDate == weekStart),
        hasLength(1),
      );
      final taskRows = await database.select(database.tasks).get();
      expect(taskRows, hasLength(2));
    });

    test('只有第一次回报 createdCount，之后是 0', () async {
      await repository.saveTemplate(template());
      final first = await ensure();
      // 滚动七天窗口覆盖本周与下周两个周期，因此第一次是 2。
      expect(first.createdCount, 2);
      final second = await ensure();
      expect(second.createdCount, 0);
      expect(second.cycles, hasLength(first.cycles.length));
    });

    test('恢复备份后重跑：按相同 (模板, 周) 命中已有实例', () async {
      await repository.saveTemplate(template());
      await ensure();
      final before = await repository.findCycle('template-1', weekStart);

      // "恢复备份后重跑"＝把同一份数据再喂一遍完全相同的生成流程。
      final again = await ensure();
      final after = await repository.findCycle('template-1', weekStart);
      expect(again.createdCount, 0);
      expect(after!.taskId, before!.taskId);
      expect(after.createdAtUtc, before.createdAtUtc);
    });

    test('同一周重复调用 ensureCycles 不会改变已完成分钟的归属', () async {
      await repository.saveTemplate(template());
      await ensure();
      final firstCycle = (await repository.findCycle('template-1', weekStart))!;
      await service.recordManualMinutes('template-1', weekStart, 80);
      await ensure();
      final progress = await service.progressForCycle('template-1', weekStart);
      expect(progress.recordedMinutes, 80);

      // **幂等的强形式**：重复调用不仅"不新增一行"，还**不改动已有那一行指向的任务**。
      // 若实现每次重新生成一个任务并换掉 `task_id`，已记录的 80 分钟会留在旧任务上，
      // 进度于是突然掉回 0——而只断言"只有一个周期实例"是发现不了的（行数与主键都没变）。
      final secondCycle = (await repository.findCycle(
        'template-1',
        weekStart,
      ))!;
      expect(
        secondCycle.taskId,
        firstCycle.taskId,
        reason: '重复生成不得换掉这一周的任务，否则已记录的分钟会与新任务脱钩',
      );
      expect(secondCycle.baseTargetMinutes, firstCycle.baseTargetMinutes);
    });
  });

  group('周期实例与它生成的普通任务', () {
    test('任务是普通任务：标题、领域、优先级、片段范围、期望时段都从模板继承', () async {
      await repository.saveTemplate(
        RecurringTaskTemplate(
          id: 'template-1',
          title: '每周英语',
          notes: '每天 30 分钟',
          targetMinutes: 180,
          priority: TaskPriority.high,
          energyLevel: TaskEnergyLevel.high,
          splitMode: TaskSplitMode.continuous,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          preferredStartMinute: 20 * 60,
          preferredEndMinute: 22 * 60,
          startsOnLocalDate: DateTime(2026, 9, 28),
          timeZoneId: timeZoneId,
          createdAtUtc: DateTime.utc(2026, 9, 28),
          updatedAtUtc: DateTime.utc(2026, 9, 28),
        ),
      );
      final run = await ensure();
      final cycle = run.cycles.firstWhere(
        (item) => item.periodStartLocalDate == weekStart,
      );
      final task = (await tasks.getById(cycle.taskId))!;
      expect(task.title, '每周英语');
      expect(task.notes, '每天 30 分钟');
      expect(task.priority, TaskPriority.high);
      expect(task.energyLevel, TaskEnergyLevel.high);
      expect(task.splitMode, TaskSplitMode.continuous);
      expect(task.minChunkMinutes, 30);
      expect(task.maxChunkMinutes, 60);
      expect(task.estimatedMinutes, 180);
      expect(task.remainingMinutes, 180);
      expect(task.preferredWindow?.startMinute, 20 * 60);
      expect(task.status, TaskStatus.open);
      // 截止时间＝本周结束（下周一本地 00:00）。排程器的"周期剩余时间"就是它。
      final period = WeeklyPeriod.startingAt(
        weekStart,
        timeZoneId,
        TimeZoneDatabase(),
      );
      expect(task.dueAtUtc, period.endUtc);
    });

    test('任务 id 由 (模板, 周) 推导，因此并发生成会算出同一个 id', () async {
      await repository.saveTemplate(template());
      final run = await ensure();
      final cycle = run.cycles.firstWhere(
        (item) => item.periodStartLocalDate == weekStart,
      );
      expect(cycle.taskId, 'recurring:template-1:2026-10-05');
    });
  });

  group('进度', () {
    test('180 目标、80 已记录 ⇒ 剩余 100（§7.2）', () async {
      await repository.saveTemplate(template());
      await ensure();
      final progress = await service.recordManualMinutes(
        'template-1',
        weekStart,
        80,
      );
      expect(progress.targetMinutes, 180);
      expect(progress.recordedMinutes, 80);
      expect(progress.remainingMinutes, 100);
    });

    test('超额记录保留真实分钟，剩余为 0，并自动判为达标', () async {
      await repository.saveTemplate(template());
      await ensure();
      final progress = await service.recordManualMinutes(
        'template-1',
        weekStart,
        200,
      );
      expect(progress.recordedMinutes, 200);
      expect(progress.remainingMinutes, 0);
      expect(progress.overTargetMinutes, 20);
      // 达标即完成本周：周期状态与任务状态都要跟上，否则它会继续占着排程输入。
      final cycle = (await repository.findCycle('template-1', weekStart))!;
      expect(cycle.status, RecurringCycleStatus.met);
      expect((await tasks.getById(cycle.taskId))!.status, TaskStatus.completed);
    });

    test('补记之后任务的剩余时长同步更新（排程输入只剩 100 分钟）', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 80);
      final cycle = (await repository.findCycle('template-1', weekStart))!;
      final task = (await tasks.getById(cycle.taskId))!;
      expect(task.remainingMinutes, 100);
      expect(task.estimatedMinutes, 180);
    });

    test('多段补记累加，来源只是既有 time_entries 一张表', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 30);
      await service.recordManualMinutes('template-1', weekStart, 50);
      final progress = await service.progressForCycle('template-1', weekStart);
      expect(progress.recordedMinutes, 80);
      final rows = await database.select(database.timeEntries).get();
      expect(rows, hasLength(2), reason: '两次补记就是两条时间记录，没有第二张表');
      expect(rows.every((row) => row.recoveryState == 'confirmed'), isTrue);
    });

    test('不存在的周期返回 StateError，而不是伪造一个 0 分钟进度', () async {
      await expectLater(
        service.progressForCycle('missing', weekStart),
        throwsA(isA<StateError>()),
      );
    });

    test('补记必须为正数', () async {
      await repository.saveTemplate(template());
      await ensure();
      await expectLater(
        service.recordManualMinutes('template-1', weekStart, 0),
        throwsArgumentError,
      );
    });
  });

  group('结算与结转', () {
    test('未达标保留 missed，默认下周目标恢复 180（§7.2）', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 80);

      // 跨到下一周：本周一启动，窗口覆盖下周。
      clock.instant = DateTime.utc(2026, 10, 12, 4);
      final run = await ensure();
      expect(run.settledCount, greaterThanOrEqualTo(1));

      final previous = (await repository.findCycle('template-1', weekStart))!;
      expect(previous.status, RecurringCycleStatus.missed);
      expect(previous.carryInMinutes, 0);

      final next = (await repository.findCycle('template-1', nextWeekStart))!;
      expect(next.baseTargetMinutes, 180);
      expect(next.carryInMinutes, 0);
      expect(next.effectiveTargetMinutes, 180);
    });

    test('达标则结算为 met，且不结转任何东西', () async {
      await repository.saveTemplate(template(carryOver: true));
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 180);

      clock.instant = DateTime.utc(2026, 10, 12, 4);
      await ensure();

      final previous = (await repository.findCycle('template-1', weekStart))!;
      expect(previous.status, RecurringCycleStatus.met);
      final next = (await repository.findCycle('template-1', nextWeekStart))!;
      expect(next.carryInMinutes, 0, reason: '达标不倒扣也不结转');
    });

    test('开启结转时把缺口写进下周的 carryInMinutes', () async {
      await repository.saveTemplate(template(carryOver: true));
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 80);

      clock.instant = DateTime.utc(2026, 10, 12, 4);
      await ensure();

      final next = (await repository.findCycle('template-1', nextWeekStart))!;
      expect(next.carryInMinutes, 100);
      expect(next.effectiveTargetMinutes, 280);
      // 结转之后本周任务的目标也要跟上，否则排程仍按 180 分钟安排。
      expect((await tasks.getById(next.taskId))!.remainingMinutes, 280);
    });

    test('超额完成不会把下周目标变小（只结转缺口，不倒扣）', () async {
      await repository.saveTemplate(template(carryOver: true));
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 250);

      clock.instant = DateTime.utc(2026, 10, 12, 4);
      await ensure();

      final next = (await repository.findCycle('template-1', nextWeekStart))!;
      expect(next.carryInMinutes, 0);
    });

    test('周中不结算：本周仍在进行，不能提前判未达标', () async {
      await repository.saveTemplate(template());
      await ensure();
      await ensure();
      final cycle = (await repository.findCycle('template-1', weekStart))!;
      expect(cycle.status, RecurringCycleStatus.open);
    });

    test('已结算的历史周期不会被后续调用改写', () async {
      await repository.saveTemplate(template());
      await ensure();
      clock.instant = DateTime.utc(2026, 10, 12, 4);
      await ensure();
      final settledAt = (await repository.findCycle('template-1', weekStart))!;

      // 之后再补记（例如用户事后补记上周的分钟）也不得把已定案的结果翻回去。
      await ensure(DateTime.utc(2026, 10, 14, 4));
      final again = (await repository.findCycle('template-1', weekStart))!;
      expect(again.status, settledAt.status);
      expect(again.updatedAtUtc, settledAt.updatedAtUtc);
    });
  });

  group('跳过、暂停与停止生成', () {
    test('跳过本周：只标记这一周，模板保持 active，下周照常生成', () async {
      await repository.saveTemplate(template());
      await ensure();
      final skipped = await service.skipCycle('template-1', weekStart);
      expect(skipped.status, RecurringCycleStatus.skipped);

      final stored = await repository.findTemplate('template-1');
      expect(stored!.status, RecurringTemplateStatus.active);

      clock.instant = DateTime.utc(2026, 10, 12, 4);
      await ensure();
      final next = await repository.findCycle('template-1', nextWeekStart);
      expect(next, isNotNull, reason: '跳过不是归档，下周必须照常生成');
    });

    test('跳过之后不再生成同一周的第二个实例', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.skipCycle('template-1', weekStart);
      final run = await ensure();
      final cycles = run.cycles
          .where((item) => item.periodStartLocalDate == weekStart)
          .toList();
      expect(cycles, hasLength(1));
      expect(cycles.single.status, RecurringCycleStatus.skipped);
    });

    test('暂停到某日期间不生成，到期后自动恢复（§7.2）', () async {
      await repository.saveTemplate(
        template(pausedUntil: DateTime(2026, 10, 20)),
      );
      final paused = await ensure();
      // 窗口覆盖 10-05 与 10-12 两周，而暂停到 10-20（含）之前——两周都不生成。
      expect(paused.cycles, isEmpty, reason: '暂停到 10-20（含）之前不生成');

      // 10-19 那一周仍然在暂停期内（10-19 <= 10-20），恢复从 10-26 开始。
      clock.instant = DateTime.utc(2026, 10, 19, 4);
      final stillPaused = await ensure();
      expect(
        stillPaused.cycles.where(
          (item) => item.periodStartLocalDate == DateTime(2026, 10, 19),
        ),
        isEmpty,
      );

      clock.instant = DateTime.utc(2026, 10, 26, 4);
      final resumed = await ensure();
      expect(
        resumed.cycles.where(
          (item) => item.periodStartLocalDate == DateTime(2026, 10, 26),
        ),
        hasLength(1),
      );
    });

    test('暂停不归档：取消暂停后立即恢复生成', () async {
      await repository.saveTemplate(template());
      await service.pauseTemplate('template-1', until: DateTime(2026, 11, 2));
      expect(
        (await repository.findTemplate('template-1'))!.status,
        RecurringTemplateStatus.active,
      );
      await service.pauseTemplate('template-1');
      final run = await ensure();
      expect(run.createdCount, 2);
    });

    test('停止以后生成：归档后不再新建，已有实例原样保留', () async {
      await repository.saveTemplate(template());
      await ensure();
      final before = await repository.findCycle('template-1', weekStart);
      await service.stopGenerating('template-1');

      // 跨到下一周再跑（本周窗口只覆盖到 10-12，看不到 10-19 那一周）。
      clock.instant = DateTime.utc(2026, 10, 19, 4);
      final run = await ensure();
      expect(
        run.cycles.where(
          (item) => item.periodStartLocalDate == DateTime(2026, 10, 19),
        ),
        isEmpty,
      );
      expect(
        (await repository.findCycle('template-1', weekStart))!.taskId,
        before!.taskId,
      );

      await service.resumeGenerating('template-1');
      final resumed = await ensure();
      expect(
        resumed.cycles.where(
          (item) => item.periodStartLocalDate == DateTime(2026, 10, 19),
        ),
        hasLength(1),
      );
    });
  });

  group('编辑作用范围（§3.3）', () {
    test('thisCycle 只改本周实例，模板不动', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.updateTemplate(
        'template-1',
        (current) => current.copyWith(targetMinutes: 240),
        scope: RecurringEditScope.thisCycle,
      );

      expect((await repository.findTemplate('template-1'))!.targetMinutes, 180);
      final cycle = (await repository.findCycle('template-1', weekStart))!;
      expect(cycle.baseTargetMinutes, 240);
      expect((await tasks.getById(cycle.taskId))!.remainingMinutes, 240);
    });

    test('fromNextWeek 只改模板，本周实例保持原样', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.updateTemplate(
        'template-1',
        (current) => current.copyWith(targetMinutes: 240),
        scope: RecurringEditScope.fromNextWeek,
      );

      expect((await repository.findTemplate('template-1'))!.targetMinutes, 240);
      final cycle = (await repository.findCycle('template-1', weekStart))!;
      expect(cycle.baseTargetMinutes, 180);
      expect((await tasks.getById(cycle.taskId))!.remainingMinutes, 180);
    });

    test('entireSeries 同时改模板与本周实例', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.updateTemplate(
        'template-1',
        (current) => current.copyWith(targetMinutes: 240),
        scope: RecurringEditScope.entireSeries,
      );

      expect((await repository.findTemplate('template-1'))!.targetMinutes, 240);
      final cycle = (await repository.findCycle('template-1', weekStart))!;
      expect(cycle.baseTargetMinutes, 240);
      expect(cycle.effectiveTargetMinutes, 240);
    });

    test('已经结算过的历史周期在任何范围下都不被改写', () async {
      await repository.saveTemplate(template());
      await ensure();
      clock.instant = DateTime.utc(2026, 10, 12, 4);
      await ensure();
      final settled = (await repository.findCycle('template-1', weekStart))!;

      await service.updateTemplate(
        'template-1',
        (current) => current.copyWith(targetMinutes: 300),
        scope: RecurringEditScope.entireSeries,
      );

      final after = (await repository.findCycle('template-1', weekStart))!;
      expect(after.baseTargetMinutes, settled.baseTargetMinutes);
      expect(after.updatedAtUtc, settled.updatedAtUtc);
    });
  });

  group('完成本周', () {
    test('completeCycle 把本周标记为 met 并收尾任务', () async {
      await repository.saveTemplate(template());
      await ensure();
      final cycle = await service.completeCycle('template-1', weekStart);
      expect(cycle.status, RecurringCycleStatus.met);
      expect((await tasks.getById(cycle.taskId))!.status, TaskStatus.completed);
    });
  });

  group('排程输入变化回调', () {
    test('生成、补记、跳过、完成都会发出原因', () async {
      await repository.saveTemplate(template());
      await ensure();
      await service.recordManualMinutes('template-1', weekStart, 30);
      await service.completeCycle('template-1', weekStart);
      expect(
        changes.map((change) => change.kind),
        containsAll(<DomainChangeKind>[
          DomainChangeKind.taskCreated,
          DomainChangeKind.focusActualChanged,
          DomainChangeKind.taskCompleted,
        ]),
      );
    });
  });

  // 用户 2026-10-08 报告："为什么周期目标我点击删除这个周期目标无效啊"
  //
  // 根因不是界面：`router.dart` 的 `onDelete` 只写了 `context.go('/tasks')`——**只导航、不删除**。
  // 而服务层与仓储层**根本没有删除模板的能力**（仓储只有 `deleteCycleAndTask`，删一周）。
  // 也就是说那个按钮是个**渲染了却没有动作的死入口**。
  //
  // 下面钉住"真的删干净"这件事，以及它与"归档"的分工。
  group('删除周期目标（用户 2026-10-08）', () {
    test('已经排进计划的周期任务也能删除，且对应计划块一起消失', () async {
      await repository.saveTemplate(template());
      await ensure();
      final cycles = await repository.listCyclesForTemplate('template-1');
      final taskId = cycles.first.taskId;
      await database
          .into(database.planVersions)
          .insert(
            db.PlanVersionsCompanion.insert(
              id: 'confirmed-plan',
              createdAtUtc: 1,
              inputHash: 'input',
              algorithmVersion: 'test',
              status: 'confirmed',
              summaryJson: '{}',
            ),
          );
      await database
          .into(database.scheduleBlocks)
          .insert(
            db.ScheduleBlocksCompanion.insert(
              id: 'scheduled-recurring-task',
              planVersionId: 'confirmed-plan',
              taskId: taskId,
              startAtUtc: DateTime.utc(2026, 10, 8, 2).microsecondsSinceEpoch,
              endAtUtc: DateTime.utc(2026, 10, 8, 3).microsecondsSinceEpoch,
              explanationCode: 'recurring_goal',
            ),
          );

      await service.deleteTemplate('template-1');

      expect(await repository.findTemplate('template-1'), isNull);
      expect(
        await (database.select(
          database.scheduleBlocks,
        )..where((row) => row.taskId.equals(taskId))).get(),
        isEmpty,
        reason: '真实数据里的周期任务已经排进计划；不先删计划块，任务外键会让整笔删除回滚',
      );
    });

    test('带标签的周期任务也能删除，且任务标签关系一起消失', () async {
      await repository.saveTemplate(template());
      await ensure();
      final cycles = await repository.listCyclesForTemplate('template-1');
      final taskId = cycles.first.taskId;
      await database
          .into(database.tags)
          .insert(db.TagsCompanion.insert(id: 'tag-1', name: '算法'));
      await database
          .into(database.taskTags)
          .insert(db.TaskTagsCompanion.insert(taskId: taskId, tagId: 'tag-1'));

      await service.deleteTemplate('template-1');

      expect(await repository.findTemplate('template-1'), isNull);
      expect(
        await (database.select(
          database.taskTags,
        )..where((row) => row.taskId.equals(taskId))).get(),
        isEmpty,
        reason: '永久删除任务时不能留下任务与标签的关联行',
      );
    });

    test('删掉模板：模板、全部周期、以及它们的普通任务一起消失', () async {
      await repository.saveTemplate(template());
      await ensure();
      // 再补一次生成，让第二周也有实例。
      await ensure(wednesday.add(const Duration(days: 7)));

      final before = await repository.listCyclesForTemplate('template-1');
      expect(before, isNotEmpty, reason: '前置条件：先生成出周期实例');
      final taskIds = before.map((cycle) => cycle.taskId).toList();
      for (final taskId in taskIds) {
        expect(
          await database.taskDao.findById(taskId),
          isNotNull,
          reason: '前置条件：周期对应的普通任务存在',
        );
      }

      await service.deleteTemplate('template-1');

      expect(
        await repository.findTemplate('template-1'),
        isNull,
        reason: '模板必须真的没了；此前"删除"只做了导航，什么都没删',
      );
      expect(await repository.listCyclesForTemplate('template-1'), isEmpty);
      for (final taskId in taskIds) {
        expect(
          await database.taskDao.findById(taskId),
          isNull,
          reason: '周期对应的普通任务也要删（否则任务列表里会留下一堆孤儿待办）',
        );
      }
    });

    test('**连专注记录一起删**：外键不允许留下孤儿行', () async {
      await repository.saveTemplate(template());
      await ensure();
      // `ensure()` 会同时生成本周与下周，因此这里有**两个**周期——取本周那一个。
      // （第一版写 `.single`，当场被 "Too many elements" 抓住。）
      final cycle = (await repository.listCyclesForTemplate('template-1'))
          .firstWhere((item) => item.periodStartLocalDate == weekStart);
      await service.recordManualMinutes('template-1', weekStart, 30);
      // 用仓储自己的汇总，而不是裸 SQL：这样断言的是"用户可见的分钟数归零"，
      // 而不是某个表的行数——后者会在实现换表时安静地变成另一件事。
      expect(
        await repository.recordedMinutesForTask(
          cycle.taskId,
          weekStart,
          nextWeekStart,
        ),
        greaterThan(0),
        reason: '前置条件：有专注记录',
      );

      await service.deleteTemplate('template-1');

      expect(
        await repository.recordedMinutesForTask(
          cycle.taskId,
          weekStart,
          nextWeekStart,
        ),
        0,
        reason: '留下孤儿行会让外键检查失败，且那些分钟会被统计读到',
      );
    });

    test('**还没生成任何周期也要能删**（刚建完就改主意）', () async {
      await repository.saveTemplate(template());

      await service.deleteTemplate('template-1');

      expect(
        await repository.findTemplate('template-1'),
        isNull,
        reason:
            '刚建完、还没到开始日就删，正是这种形状；'
            '少了这条兜底，界面上会表现为"删除无效"',
      );
    });

    test('删一个不影响另一个（只删这个模板的东西）', () async {
      await repository.saveTemplate(template(id: 'a', title: '每周英语'));
      await repository.saveTemplate(template(id: 'b', title: '每周跑步'));
      await ensure();
      final bCycles = await repository.listCyclesForTemplate('b');
      expect(bCycles, isNotEmpty);

      await service.deleteTemplate('a');

      expect(await repository.findTemplate('a'), isNull);
      expect(await repository.findTemplate('b'), isNotNull, reason: 'b 不该被牵连');
      expect(
        await repository.listCyclesForTemplate('b'),
        hasLength(bCycles.length),
      );
      expect(await database.taskDao.findById(bCycles.first.taskId), isNotNull);
    });

    test('删一个不存在的模板不抛（重复点击/已删除）', () async {
      await expectLater(
        service.deleteTemplate('never-existed'),
        completes,
        reason: '用户连点两次、或另一个页面刚删过，都不该让界面报错',
      );
    });

    test('**删除与归档是两件事**：归档保留周期与任务，删除清掉它们', () async {
      await repository.saveTemplate(template());
      await ensure();
      final cycles = await repository.listCyclesForTemplate('template-1');
      final taskId = cycles.first.taskId;

      await service.stopGenerating('template-1');

      expect(
        await repository.listCyclesForTemplate('template-1'),
        isNotEmpty,
        reason: '归档是"以后都不做了"，已生成的周期与任务原样保留，统计里仍看得到历史',
      );
      expect(await database.taskDao.findById(taskId), isNotNull);

      await service.deleteTemplate('template-1');

      expect(await repository.findTemplate('template-1'), isNull);
      expect(await database.taskDao.findById(taskId), isNull);
    });
  });
}
