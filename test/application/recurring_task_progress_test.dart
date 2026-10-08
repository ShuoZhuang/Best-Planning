import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_focus_entry_store.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

final class _FixedClock implements Clock {
  _FixedClock(this.instant);
  DateTime instant;
  @override
  DateTime nowUtc() => instant;
}

/// 周期进度口径（路线图 §3.3、§7.2）。
///
/// **两条不变量**：
/// - 完成分钟**只有一个来源**（现有 `time_entries`）。专注计时与手动补记必须得到同一个
///   数字，否则"计时器说 45 分钟、进度说 0 分钟"会同时出现在屏幕上。
/// - 180 目标 ＋ 80 已记录 ⇒ 剩余 100；超额保留记录但剩余为 0。
void main() {
  late db.AppDatabase database;
  late _FixedClock clock;
  late RecurringTaskService service;
  late FocusService focus;
  late DriftRecurringTaskRepository repository;

  const timeZoneId = 'Asia/Shanghai';
  final monday = DateTime(2026, 10, 5);
  // 本地 2026-10-05（周一）12:00。
  final now = DateTime.utc(2026, 10, 5, 4);

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    clock = _FixedClock(now);
    repository = DriftRecurringTaskRepository(
      database,
      RecurringTaskDao(database),
    );
    service = RecurringTaskService(
      repository: repository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      zones: TimeZoneDatabase(),
      timeZoneId: timeZoneId,
      tasks: DriftTaskRepository(database.taskDao),
    );
    focus = FocusService(
      store: DriftFocusEntryStore(database),
      clock: clock,
      monotonicClock: StopwatchMonotonicClock(),
      idGenerator: UuidIdGenerator(),
    );
  });

  tearDown(() => database.close());

  Future<RecurringTaskTemplate> seedTemplate({
    int targetMinutes = 180,
    bool carryOver = false,
  }) async {
    final template = RecurringTaskTemplate(
      id: 'template-1',
      title: '每周英语',
      targetMinutes: targetMinutes,
      carryOverUnfinished: carryOver,
      startsOnLocalDate: DateTime(2026, 9, 28),
      timeZoneId: timeZoneId,
      createdAtUtc: DateTime.utc(2026, 9, 28),
      updatedAtUtc: DateTime.utc(2026, 9, 28),
    );
    await repository.saveTemplate(template);
    await service.ensureCycles(
      TimeRange(startUtc: now, endUtc: now.add(const Duration(days: 7))),
      now,
    );
    return template;
  }

  Future<String> cycleTaskId() async =>
      (await repository.findCycle('template-1', monday))!.taskId;

  test('180 目标、80 已记录 ⇒ 剩余 100（路线图 §7.2 第二条）', () async {
    await seedTemplate();
    await service.recordManualMinutes('template-1', monday, 80);
    final progress = await service.progressForCycle('template-1', monday);
    expect(progress.targetMinutes, 180);
    expect(progress.recordedMinutes, 80);
    expect(progress.remainingMinutes, 100);
  });

  test('超额记录：进度保留 200 分钟，剩余钳到 0（不出现负数）', () async {
    await seedTemplate();
    final progress = await service.recordManualMinutes(
      'template-1',
      monday,
      200,
    );
    expect(progress.recordedMinutes, 200);
    expect(progress.remainingMinutes, 0);
    expect(progress.overTargetMinutes, 20);
    expect(progress.completionRatio, greaterThan(1));
  });

  test('专注计时与手动补记汇总到同一个数字', () async {
    await seedTemplate();
    final taskId = await cycleTaskId();

    // ① 计时器路径：开始 → 结束，落一条 confirmed 的时间记录。
    await focus.start(taskId);
    clock.instant = now.add(const Duration(minutes: 45));
    await focus.finish();

    // ② 手动补记路径：直接写同一张表。
    await service.recordManualMinutes('template-1', monday, 30);

    final progress = await service.progressForCycle('template-1', monday);
    expect(
      progress.recordedMinutes,
      75,
      reason: '45（专注）＋ 30（补记）必须来自同一张 time_entries，而不是两套事实',
    );
    expect(progress.remainingMinutes, 105);
  });

  test('未确认的恢复记录与仍在进行的专注都不计入进度', () async {
    await seedTemplate();
    final taskId = await cycleTaskId();

    // 一次进行中的专注：不结束就不算完成。
    await focus.start(taskId);
    expect(
      (await service.progressForCycle('template-1', monday)).recordedMinutes,
      0,
    );

    // 崩溃恢复后待确认：同样不算完成（recovery_state = needsConfirmation）。
    clock.instant = now.add(const Duration(minutes: 30));
    await focus.pause();
    clock.instant = now.add(const Duration(hours: 2));
    await focus.recoverOpenEntry();
    expect(
      (await service.progressForCycle('template-1', monday)).recordedMinutes,
      0,
    );

    // 用户确认后才计入。**计入的是确认的时长（30 分钟）**，而 `activeMicroseconds`
    // 在 `confirmRecovery` 里按"结束时刻 − 开始时刻"重算，因此这里先确认 30 分钟，
    // 再断言汇总数字与之一致。
    await focus.confirmRecovery(
      endedAtUtc: now.add(const Duration(minutes: 30)),
      actualMinutes: 30,
    );
    expect(
      (await service.progressForCycle('template-1', monday)).recordedMinutes,
      30,
    );
  });

  test('上周的记录不计入本周', () async {
    await seedTemplate();
    final taskId = await cycleTaskId();
    // 上周日（本地 2026-10-04）的一条记录。
    await database.customInsert(
      'INSERT INTO time_entries ('
      'id, task_id, started_at_utc, ended_at_utc, paused_minutes, source, '
      'recovery_state, created_at_utc, updated_at_utc'
      ") VALUES ('old', ?, ?, ?, 0, 'user', 'confirmed', 1, 1)",
      variables: [
        Variable<String>(taskId),
        Variable<int>(DateTime.utc(2026, 10, 4, 2).microsecondsSinceEpoch),
        Variable<int>(DateTime.utc(2026, 10, 4, 3).microsecondsSinceEpoch),
      ],
    );
    expect(
      (await service.progressForCycle('template-1', monday)).recordedMinutes,
      0,
    );
  });

  test('达标判定与状态：未达标保持 open，达标变 met 且任务完成', () async {
    await seedTemplate();
    expect(
      (await service.progressForCycle('template-1', monday)).isMet,
      isFalse,
    );

    await service.recordManualMinutes('template-1', monday, 179);
    var progress = await service.progressForCycle('template-1', monday);
    expect(progress.isMet, isFalse);
    expect(progress.remainingMinutes, 1);
    expect(progress.status, RecurringCycleStatus.open);

    await service.recordManualMinutes('template-1', monday, 1);
    progress = await service.progressForCycle('template-1', monday);
    expect(progress.isMet, isTrue);
    expect(progress.remainingMinutes, 0);
    expect(progress.status, RecurringCycleStatus.met);
  });

  test('结转把上周缺口计入本周有效目标', () async {
    await seedTemplate(carryOver: true);
    await service.recordManualMinutes('template-1', monday, 80);

    final nextMonday = DateTime(2026, 10, 12);
    final nextNow = DateTime.utc(2026, 10, 12, 4);
    clock.instant = nextNow;
    await service.ensureCycles(
      TimeRange(startUtc: nextNow, endUtc: nextNow.add(const Duration(days: 7))),
      nextNow,
    );

    final progress = await service.progressForCycle('template-1', nextMonday);
    expect(progress.carryInMinutes, 100);
    expect(progress.targetMinutes, 280);
    expect(progress.recordedMinutes, 0);
    expect(progress.remainingMinutes, 280);
  });

  test('不结转时下周目标恢复 180，上周未达标记录保留（§7.2 第三条）', () async {
    await seedTemplate();
    await service.recordManualMinutes('template-1', monday, 80);

    final nextMonday = DateTime(2026, 10, 12);
    final nextNow = DateTime.utc(2026, 10, 12, 4);
    clock.instant = nextNow;
    await service.ensureCycles(
      TimeRange(startUtc: nextNow, endUtc: nextNow.add(const Duration(days: 7))),
      nextNow,
    );

    final next = await service.progressForCycle('template-1', nextMonday);
    expect(next.targetMinutes, 180);
    expect(next.carryInMinutes, 0);

    final previous = await service.progressForCycle('template-1', monday);
    expect(previous.status, RecurringCycleStatus.missed);
    expect(previous.recordedMinutes, 80, reason: '上周的记录必须保留，不被新一周覆盖');
  });

  test('跳过的一周不产生排程剩余，也不接受补记', () async {
    await seedTemplate();
    await service.skipCycle('template-1', monday);
    final progress = await service.progressForCycle('template-1', monday);
    expect(progress.status, RecurringCycleStatus.skipped);
    await expectLater(
      service.recordManualMinutes('template-1', monday, 30),
      throwsA(isA<StateError>()),
    );
  });

  test('补记的分钟会同步到排程输入（任务的剩余时长）', () async {
    await seedTemplate();
    await service.recordManualMinutes('template-1', monday, 80);
    final taskId = await cycleTaskId();
    final task = await DriftTaskRepository(database.taskDao).getById(taskId);
    expect(task!.remainingMinutes, 100);
    expect(task.status, TaskStatus.open);
  });
}
