import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// 生成的 Drift 表类与领域模型同名（`RecurringTaskTemplate` 既是表也是模型），因此这里
// 给数据库加别名。**刻意不重命名任何一边**：表名就是 SQL 表名，领域模型名就是产品词，
// 让其中一个迁就另一个的冲突会一直留在代码里。
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';

/// 周期目标的持久化用例。
///
/// 这个文件守护的是**唯一约束**与**事务性**这两件事——它们没法靠纯 Dart 用例覆盖，
/// 而"连续启动十次只有一个实例"（§7.2 第一条）恰恰只能由数据库来保证。
void main() {
  late db.AppDatabase database;
  late RecurringTaskDao dao;
  late RecurringTaskRepository repository;

  final instant = DateTime.utc(2026, 10, 5, 1);

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    dao = RecurringTaskDao(database);
    repository = DriftRecurringTaskRepository(database, dao);
  });

  tearDown(() => database.close());

  RecurringTaskTemplate buildTemplate({
    String id = 'template-1',
    String title = '每周英语',
    int targetMinutes = 180,
    int mask = recurringAllWeekdaysMask,
    RecurringPace pace = RecurringPace.even,
    bool carryOver = false,
    DateTime? startsOn,
    DateTime? endsOn,
    DateTime? pausedUntil,
    RecurringTemplateStatus status = RecurringTemplateStatus.active,
    int createdOffsetMinutes = 0,
  }) => RecurringTaskTemplate(
    id: id,
    title: title,
    notes: '每天 30 分钟',
    targetMinutes: targetMinutes,
    priority: TaskPriority.high,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 25,
    maxChunkMinutes: 60,
    preferredStartMinute: 20 * 60,
    preferredEndMinute: 22 * 60,
    pace: pace,
    allowedWeekdaysMask: mask,
    carryOverUnfinished: carryOver,
    startsOnLocalDate: startsOn ?? DateTime(2026, 10, 5),
    endsOnLocalDate: endsOn,
    pausedUntilLocalDate: pausedUntil,
    timeZoneId: 'Asia/Shanghai',
    status: status,
    createdAtUtc: instant.add(Duration(minutes: createdOffsetMinutes)),
    updatedAtUtc: instant.add(Duration(minutes: createdOffsetMinutes)),
  );

  PlannerTask buildTask({
    String id = 'task-1',
    String title = '每周英语',
    int remaining = 180,
  }) => PlannerTask(
    id: id,
    title: title,
    priority: TaskPriority.high,
    estimatedMinutes: 180,
    remainingMinutes: remaining,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 25,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: instant,
    updatedAtUtc: instant,
  );

  RecurringTaskCycle buildCycle({
    String templateId = 'template-1',
    DateTime? periodStart,
    String taskId = 'task-1',
    int baseTarget = 180,
    int carryIn = 0,
    RecurringCycleStatus status = RecurringCycleStatus.open,
  }) => RecurringTaskCycle(
    templateId: templateId,
    periodStartLocalDate: periodStart ?? DateTime(2026, 10, 5),
    taskId: taskId,
    baseTargetMinutes: baseTarget,
    carryInMinutes: carryIn,
    status: status,
    createdAtUtc: instant,
    updatedAtUtc: instant,
  );

  /// 直接落一条时间记录（模拟专注计时或手动补记写进同一张表）。
  ///
  /// `time_entries.task_id` 有外键约束，因此先把那个普通任务补上。**刻意不走
  /// `createCycleIfAbsent`**：本组用例测的是"分钟从哪里汇总"，顺带建一条周期实例会让
  /// 别的断言莫名其妙多出一行；这里要的只是"任务存在"。
  Future<void> insertTimeEntry({
    required String id,
    String taskId = 'task-1',
    required DateTime startedAtUtc,
    DateTime? endedAtUtc,
    int pausedMinutes = 0,
    String recoveryState = 'confirmed',
  }) async {
    if (!await dao.taskExists(taskId)) {
      await database.customInsert(
        'INSERT INTO tasks ('
        'id, title, notes, priority, estimated_minutes, remaining_minutes, '
        'energy_level, split_mode, min_chunk_minutes, max_chunk_minutes, '
        'status, created_at_utc, updated_at_utc'
        ") VALUES (?, ?, '', 'medium', 180, 180, 'medium', 'splittable', "
        '25, 60, ?, ?, ?)',
        variables: [
          Variable<String>(taskId),
          Variable<String>(taskId),
          const Variable<String>('open'),
          Variable<int>(instant.microsecondsSinceEpoch),
          Variable<int>(instant.microsecondsSinceEpoch),
        ],
      );
    }
    await database.customInsert(
      'INSERT INTO time_entries ('
      'id, task_id, started_at_utc, ended_at_utc, paused_minutes, source, '
      'recovery_state, created_at_utc, updated_at_utc'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<String>(id),
        Variable<String>(taskId),
        Variable<int>(startedAtUtc.microsecondsSinceEpoch),
        Variable<int>(endedAtUtc?.microsecondsSinceEpoch),
        Variable<int>(pausedMinutes),
        const Variable<String>('user'),
        Variable<String>(recoveryState),
        Variable<int>(startedAtUtc.microsecondsSinceEpoch),
        Variable<int>(startedAtUtc.microsecondsSinceEpoch),
      ],
    );
  }

  group('模板往返', () {
    test('保存后逐字段读回', () async {
      await repository.saveTemplate(
        buildTemplate(carryOver: true, mask: weekdayMaskOf([1, 3, 5])),
      );

      final loaded = await repository.findTemplate('template-1');
      expect(loaded, isNotNull);
      expect(loaded!.title, '每周英语');
      expect(loaded.notes, '每天 30 分钟');
      expect(loaded.targetMinutes, 180);
      expect(loaded.priority, TaskPriority.high);
      expect(loaded.energyLevel, TaskEnergyLevel.high);
      expect(loaded.splitMode, TaskSplitMode.splittable);
      expect(loaded.minChunkMinutes, 25);
      expect(loaded.maxChunkMinutes, 60);
      expect(loaded.preferredWindow, isNotNull);
      expect(loaded.preferredWindow!.startMinute, 20 * 60);
      expect(loaded.preferredWindow!.endMinute, 22 * 60);
      expect(loaded.pace, RecurringPace.even);
      expect(loaded.allowedWeekdaysMask, weekdayMaskOf([1, 3, 5]));
      expect(loaded.carryOverUnfinished, isTrue);
      expect(loaded.startsOnLocalDate, DateTime(2026, 10, 5));
      expect(loaded.timeZoneId, 'Asia/Shanghai');
      expect(loaded.status, RecurringTemplateStatus.active);
      expect(loaded.createdAtUtc, instant);
    });

    test('日期以 YYYY-MM-DD 文本落库，不受时区解释影响', () async {
      await repository.saveTemplate(
        buildTemplate(
          startsOn: DateTime(2026, 10, 5),
          endsOn: DateTime(2026, 12, 28),
          pausedUntil: DateTime(2026, 10, 20),
        ),
      );
      final row = await database
          .customSelect(
            'SELECT starts_on_local_date, ends_on_local_date, '
            'paused_until_local_date FROM recurring_task_templates '
            "WHERE id = 'template-1'",
          )
          .getSingle();
      expect(row.read<String>('starts_on_local_date'), '2026-10-05');
      expect(row.read<String>('ends_on_local_date'), '2026-12-28');
      expect(row.read<String>('paused_until_local_date'), '2026-10-20');
    });

    test('同 id 再保存是覆盖而不是新增', () async {
      await repository.saveTemplate(buildTemplate(targetMinutes: 180));
      await repository.saveTemplate(buildTemplate(targetMinutes: 240));
      final all = await repository.listTemplates();
      expect(all, hasLength(1));
      expect(all.single.targetMinutes, 240);
    });

    test('列表顺序由仓储定死，不依赖数据库返回顺序', () async {
      await repository.saveTemplate(
        buildTemplate(id: 'template-b', createdOffsetMinutes: 2),
      );
      await repository.saveTemplate(
        buildTemplate(id: 'template-a', createdOffsetMinutes: 1),
      );
      await repository.saveTemplate(
        buildTemplate(id: 'template-c', createdOffsetMinutes: 1),
      );
      final all = await repository.listTemplates();
      expect(all.map((item) => item.id), [
        'template-a',
        'template-c',
        'template-b',
      ]);
    });

    test('默认包含归档模板，显式排除时不含', () async {
      await repository.saveTemplate(buildTemplate(id: 'active-1'));
      await repository.saveTemplate(
        buildTemplate(
          id: 'archived-1',
          createdOffsetMinutes: 1,
          status: RecurringTemplateStatus.archived,
        ),
      );
      expect((await repository.listTemplates()).length, 2);
      expect(
        (await repository.listTemplates(includeArchived: false)).length,
        1,
      );
    });
  });

  group('生成候选模板', () {
    test('排除未开始与已过结束日的模板', () async {
      await repository.saveTemplate(
        buildTemplate(id: 'future', startsOn: DateTime(2026, 10, 12)),
      );
      await repository.saveTemplate(
        buildTemplate(
          id: 'ended',
          createdOffsetMinutes: 1,
          startsOn: DateTime(2026, 8, 3),
          endsOn: DateTime(2026, 9, 28),
        ),
      );
      await repository.saveTemplate(
        buildTemplate(id: 'live', createdOffsetMinutes: 2),
      );

      final candidates = await repository.listGeneratableTemplates(
        DateTime(2026, 10, 5),
      );
      expect(candidates.map((item) => item.id), ['live']);
    });

    test('结束日当天仍然生成，次日不再生成', () async {
      await repository.saveTemplate(
        buildTemplate(endsOn: DateTime(2026, 10, 5)),
      );
      expect(
        await repository.listGeneratableTemplates(DateTime(2026, 10, 5)),
        hasLength(1),
      );
      expect(
        await repository.listGeneratableTemplates(DateTime(2026, 10, 12)),
        isEmpty,
      );
    });

    test('归档模板不出现在候选里', () async {
      await repository.saveTemplate(
        buildTemplate(status: RecurringTemplateStatus.archived),
      );
      expect(
        await repository.listGeneratableTemplates(DateTime(2026, 10, 5)),
        isEmpty,
      );
    });
  });

  group('事务性 createCycleIfAbsent', () {
    test('同一模板同一周只创建一个周期（连续十次）', () async {
      await repository.saveTemplate(buildTemplate());
      for (var attempt = 0; attempt < 10; attempt++) {
        await repository.createCycleIfAbsent(
          cycle: buildCycle(taskId: 'task-$attempt'),
          task: buildTask(id: 'task-$attempt'),
        );
      }
      final cycles = await repository.listCyclesInRange(
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 11),
      );
      expect(cycles, hasLength(1));
      // **先到的那一个留下**：后续九次不得把 task_id 换成新任务。
      expect(cycles.single.taskId, 'task-0');
      final rows = await database
          .customSelect('SELECT COUNT(*) AS total FROM recurring_task_cycles')
          .getSingle();
      expect(rows.read<int>('total'), 1);
    });

    test('并发的两次调用也只能创建一个', () async {
      await repository.saveTemplate(buildTemplate());
      final results = await Future.wait([
        repository.createCycleIfAbsent(
          cycle: buildCycle(taskId: 'task-a'),
          task: buildTask(id: 'task-a'),
        ),
        repository.createCycleIfAbsent(
          cycle: buildCycle(taskId: 'task-b'),
          task: buildTask(id: 'task-b'),
        ),
      ]);
      expect(results.map((item) => item.taskId).toSet(), hasLength(1));
      final rows = await database
          .customSelect('SELECT COUNT(*) AS total FROM recurring_task_cycles')
          .getSingle();
      expect(rows.read<int>('total'), 1);
    });

    test('不同周期的同一模板各自创建', () async {
      await repository.saveTemplate(buildTemplate());
      await repository.createCycleIfAbsent(
        cycle: buildCycle(taskId: 'task-w1'),
        task: buildTask(id: 'task-w1'),
      );
      await repository.createCycleIfAbsent(
        cycle: buildCycle(
          periodStart: DateTime(2026, 10, 12),
          taskId: 'task-w2',
        ),
        task: buildTask(id: 'task-w2'),
      );
      expect(
        await repository.listCyclesForTemplate('template-1'),
        hasLength(2),
      );
    });

    test('一个普通任务只能属于一个周期实例（task_id UNIQUE）', () async {
      await repository.saveTemplate(
        buildTemplate(id: 'template-1', createdOffsetMinutes: 0),
      );
      await repository.saveTemplate(
        buildTemplate(id: 'template-2', createdOffsetMinutes: 1),
      );
      await repository.createCycleIfAbsent(
        cycle: buildCycle(templateId: 'template-1', taskId: 'shared-task'),
        task: buildTask(id: 'shared-task'),
      );
      // 第二个模板想复用同一个任务：UNIQUE(task_id) 拒绝，仓储回读不到
      // (template-2, 本周) 这行，于是如实抛出——这正是"一个任务只属于一周"的硬保证。
      await expectLater(
        repository.createCycleIfAbsent(
          cycle: buildCycle(templateId: 'template-2', taskId: 'shared-task'),
          task: buildTask(id: 'shared-task'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        await repository.listCyclesInRange(
          DateTime(2026, 10, 5),
          DateTime(2026, 10, 11),
        ),
        hasLength(1),
      );
    });

    test('任务写入失败时周期行一起回滚', () async {
      await repository.saveTemplate(buildTemplate());
      // 未知领域会触发 tasks.area_id 的外键失败，从而让整个事务回滚。
      await expectLater(
        repository.createCycleIfAbsent(
          cycle: buildCycle(taskId: 'task-broken'),
          task: PlannerTask(
            id: 'task-broken',
            areaId: 'missing-area',
            title: '坏任务',
            priority: TaskPriority.medium,
            estimatedMinutes: 60,
            remainingMinutes: 60,
            energyLevel: TaskEnergyLevel.medium,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 25,
            maxChunkMinutes: 60,
            status: TaskStatus.open,
            createdAtUtc: instant,
            updatedAtUtc: instant,
          ),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        await repository.listCyclesInRange(
          DateTime(2026, 10, 5),
          DateTime(2026, 10, 11),
        ),
        isEmpty,
      );
      expect(await database.select(database.tasks).get(), isEmpty);
    });

    test('外键指向不存在的模板时被拒绝', () async {
      await expectLater(
        repository.createCycleIfAbsent(
          cycle: buildCycle(templateId: 'missing-template', taskId: 'task-x'),
          task: buildTask(id: 'task-x'),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('周期查询', () {
    test('按范围查询含两端并保持稳定顺序', () async {
      await repository.saveTemplate(buildTemplate());
      for (final week in [
        DateTime(2026, 9, 28),
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
      ]) {
        await repository.createCycleIfAbsent(
          cycle: buildCycle(
            periodStart: week,
            taskId: 'task-${week.month}-${week.day}',
          ),
          task: buildTask(id: 'task-${week.month}-${week.day}'),
        );
      }
      final range = await repository.listCyclesInRange(
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
      );
      expect(range.map((item) => item.periodStartLocalDate), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
      ]);
    });

    test('模板历史按周倒序，limit 取到最近几周', () async {
      await repository.saveTemplate(buildTemplate());
      for (final week in [
        DateTime(2026, 9, 28),
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
      ]) {
        final taskId = 'task-${week.year}-${week.month}-${week.day}';
        await repository.createCycleIfAbsent(
          cycle: buildCycle(periodStart: week, taskId: taskId),
          task: buildTask(id: taskId),
        );
      }
      final recent = await repository.listCyclesForTemplate(
        'template-1',
        limit: 2,
      );
      expect(recent.map((item) => item.periodStartLocalDate), [
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 5),
      ]);
    });

    test('保存状态与结转后读回', () async {
      await repository.saveTemplate(buildTemplate());
      await repository.createCycleIfAbsent(
        cycle: buildCycle(taskId: 'task-1'),
        task: buildTask(),
      );
      await repository.saveCycle(
        buildCycle(
          taskId: 'task-1',
          carryIn: 40,
          status: RecurringCycleStatus.met,
        ),
      );
      final loaded = await repository.findCycle(
        'template-1',
        DateTime(2026, 10, 5),
      );
      expect(loaded!.carryInMinutes, 40);
      expect(loaded.status, RecurringCycleStatus.met);
      expect(loaded.effectiveTargetMinutes, 220);
    });

    test('findCycle 对不存在的组合返回 null', () async {
      expect(
        await repository.findCycle('nobody', DateTime(2026, 10, 5)),
        isNull,
      );
    });
  });

  group('完成分钟汇总', () {
    final weekStart = DateTime.utc(2026, 10, 4, 16); // 本地 2026-10-05 00:00
    final weekEnd = DateTime.utc(2026, 10, 11, 16);

    test('已确认且已结束的记录才计入', () async {
      await insertTimeEntry(
        id: 'entry-1',
        startedAtUtc: DateTime.utc(2026, 10, 5, 2),
        endedAtUtc: DateTime.utc(2026, 10, 5, 2, 45),
      );
      // 还在跑的专注不算完成。
      await insertTimeEntry(
        id: 'entry-2',
        startedAtUtc: DateTime.utc(2026, 10, 6, 2),
      );
      // 崩溃恢复后未确认的不算。
      await insertTimeEntry(
        id: 'entry-3',
        startedAtUtc: DateTime.utc(2026, 10, 7, 2),
        endedAtUtc: DateTime.utc(2026, 10, 7, 3),
        recoveryState: 'needsConfirmation',
      );

      expect(
        await repository.recordedMinutesForTask('task-1', weekStart, weekEnd),
        45,
      );
    });

    test('扣除暂停分钟，暂停超过跨度时按 0 计', () async {
      await insertTimeEntry(
        id: 'entry-1',
        startedAtUtc: DateTime.utc(2026, 10, 5, 2),
        endedAtUtc: DateTime.utc(2026, 10, 5, 3),
        pausedMinutes: 20,
      );
      await insertTimeEntry(
        id: 'entry-2',
        startedAtUtc: DateTime.utc(2026, 10, 6, 2),
        endedAtUtc: DateTime.utc(2026, 10, 6, 2, 10),
        pausedMinutes: 99,
      );
      expect(
        await repository.recordedMinutesForTask('task-1', weekStart, weekEnd),
        40,
      );
    });

    test('窗口外的记录不计入，跨周记录只计入本周重叠的30分钟', () async {
      // 上周日结束的记录。
      await insertTimeEntry(
        id: 'entry-before',
        startedAtUtc: DateTime.utc(2026, 10, 4, 10),
        endedAtUtc: DateTime.utc(2026, 10, 4, 11),
      );
      // 本地周日 23:30 开始、跨到周一 00:30：本周只保留 23:30–24:00 的 30 分钟。
      await insertTimeEntry(
        id: 'entry-span',
        startedAtUtc: DateTime.utc(2026, 10, 11, 15, 30),
        endedAtUtc: DateTime.utc(2026, 10, 11, 16, 30),
      );
      expect(
        await repository.recordedMinutesForTask('task-1', weekStart, weekEnd),
        30,
      );
    });

    test('别人任务的记录不计入', () async {
      await insertTimeEntry(
        id: 'entry-1',
        taskId: 'task-other',
        startedAtUtc: DateTime.utc(2026, 10, 5, 2),
        endedAtUtc: DateTime.utc(2026, 10, 5, 3),
      );
      expect(
        await repository.recordedMinutesForTask('task-1', weekStart, weekEnd),
        0,
      );
    });

    test('手动补记写进同一张表，与专注记录一起计入', () async {
      await insertTimeEntry(
        id: 'timer',
        startedAtUtc: DateTime.utc(2026, 10, 5, 2),
        endedAtUtc: DateTime.utc(2026, 10, 5, 2, 30),
      );
      // 手动补记就是一条普通的已确认时间记录——**没有第二张表**（§4.2）。
      await insertTimeEntry(
        id: 'manual',
        startedAtUtc: DateTime.utc(2026, 10, 6, 2),
        endedAtUtc: DateTime.utc(2026, 10, 6, 3),
      );
      expect(
        await repository.recordedMinutesForTask('task-1', weekStart, weekEnd),
        90,
      );
    });
  });
}
