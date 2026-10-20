// Review Focus 第 9 条（计划 `2026-10-13-calendar-preview-and-scheduling-integrity-repair.md`）：
//
// > 应用计划、撤销计划、编辑/删除日程、编辑课程、修改保护规则和完成任务后，
// > 日视图、近期日历和今日页必须在同一进程内自动刷新。
//
// 这条要求由**两半**组成，各自已有门禁：
//   · **"信号发了吗"** —— `test/application/schedule_view_invalidation_test.dart`
//     对六个写入点逐个断言"成功发一次、失败/stale/取消发零次"；
//   · **"三个页面真的会跟着刷新吗"** —— `test/features/calendar/week_view_test.dart`
//     的跨页面用例（真实数据源 + 真实总线 + 三个页面同挂一棵树）。
//
// 但两半拼起来仍有一个**真空档**：跨页面用例只驱动了"应用计划 / 编辑固定日程 / 完成任务"
// 三条路径。也就是说，"信号发了"与"页面刷新了"从没在**撤销计划、删除日程、修改保护规则、
// 改配色、改领域名**这几条路径上被同一条链验证过——而"信号发了但数据源读回来还是旧的"
// 正是这类改动最容易出的错（例如某个目录没被重新读取）。
//
// 本文件补的就是这个真空档：**每一条列出的写入路径**都要让**真实生产数据源**
// （`RepositoryScheduleViewSource` + 真实 drift 仓储 + 真实总线）重新发一份**不同**的列表。
// "不同"是关键——只断言"又发了一份"会被"原样重发"蒙过去。
//
// 课程的保存／删除（`CourseManagementService.saveCourse` / `deleteCourse`）不走这里：
// 它需要学期与课表导入批次夹具，已由 `schedule_view_invalidation_test.dart` 在**真实
// drift 库**上断言"恰好发一次"，而"发信号 ⇒ 数据源重载"这条链与路径无关（见下面每条
// 用例末尾的同一条断言），因此不重复搭一套学期夹具。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/plan_undo_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/schedule_view_invalidation.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/schedule_colors.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();

void main() {
  const timeZoneId = 'UTC';
  final zones = TimeZoneDatabase();
  final windowStart = DateTime.utc(2026, 10, 5);
  final windowEnd = DateTime.utc(2026, 10, 12);
  final clock = _FixedClock(windowStart);

  late AppDatabase database;
  late ScheduleViewInvalidationBus bus;
  late CalendarService calendar;
  late PlanUndoService undo;
  late PlanApplicationService apply;
  late SettingsService settings;
  late WorkspaceService workspace;
  late ScheduleColorService colors;
  late RepositoryScheduleViewSource source;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    bus = ScheduleViewInvalidationBus();
    final invalidation = ScheduleViewInvalidationWiring(bus);
    final calendarRepository = DriftCalendarRepository(database);
    final taskRepository = DriftTaskRepository(database.taskDao);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final workspaceRepository = DriftWorkspaceRepository(database);

    // **撤销计划那一条必须有一件真的任务**：`schedule_blocks.task_id` 是指向 `tasks` 的
    // 外键，只在 `ScheduleProblem` 里造一件"任务"会让落库时外键失败（实测
    // `SqliteException(787) FOREIGN KEY constraint failed`）——那说明的是夹具缺一行，
    // 不是产品坏了。这里直接写入一行，id 与 `_problem()`／提案里的 taskId 对齐。
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-1',
            title: '匿名任务',
            priority: 'medium',
            estimatedMinutes: 60,
            remainingMinutes: 60,
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            status: 'inbox',
            createdAtUtc: 1,
            updatedAtUtc: 1,
          ),
        );

    settings = SettingsService(
      repository: settingsRepository,
      onPlanningRulesChanged: invalidation.planningRules,
    );
    workspace = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      onWorkspaceChanged: invalidation.workspace,
    );
    colors = ScheduleColorService(
      settings: settingsRepository,
      workspace: workspaceRepository,
      onColorsChanged: invalidation.colors,
    );
    calendar = CalendarService(
      repository: calendarRepository,
      deletion: calendarRepository,
      recurringRepository: calendarRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      zones: zones,
      onScheduleInputChanged: invalidation.calendarAfter((change) {}),
    );
    apply = PlanApplicationService(
      source: _NoProblemSource(),
      repository: planRepository,
      zones: zones,
      onPlanChanged: invalidation.planAfter(() async {}),
    );
    undo = PlanUndoService(
      repository: planRepository,
      onPlanChanged: invalidation.planAfter(() async {}),
    );
    source = RepositoryScheduleViewSource(
      tasks: taskRepository,
      calendar: calendarRepository,
      plans: planRepository,
      history: planRepository,
      rules: PlanningRuleResolver(settings),
      colors: colors,
      zones: zones,
      timeZoneId: timeZoneId,
      clock: clock,
      // 生产装配必传：不传就没有任何写入路径能刷新（R9 的形态）。
      invalidation: bus,
    );
  });

  tearDown(() async {
    await bus.dispose();
    await database.close();
  });

  /// 条目的**可见内容**签名。
  ///
  /// 只用 id 比会漏掉"标题／分类／颜色／时间变了"这一类改动，而它们正是本文件要钉的东西。
  List<String> signatureOf(List<ScheduleViewItem> items) => [
    for (final item in items)
      '${item.id}|${item.title}|${item.categoryKey}|${item.categoryLabel}|'
          '${item.categoryColorArgb}|${item.range.startUtc.toIso8601String()}|'
          '${item.range.endUtc.toIso8601String()}|${item.isCompleted}',
  ];

  /// 订阅一次 → 等首份稳定 → 执行 [write] → 断言"又发了一份**不同**的"。
  /// 订阅一次 → 等首份稳定 → 执行 [write] → 断言"又发了一份**不同**的"。
  Future<({List<ScheduleViewItem> before, List<ScheduleViewItem> after})>
  refreshedAfter(
    Future<void> Function() write, {
    required String reason,
  }) async {
    final emissions = <List<ScheduleViewItem>>[];
    final subscription = source
        .watch(windowStart, windowEnd)
        .listen(emissions.add);
    addTearDown(subscription.cancel);

    // 首份可能在几次微任务之后才到；任务流订阅也会各推一份。
    for (var attempt = 0; attempt < 20 && emissions.isEmpty; attempt++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await pumpEventQueue();
    expect(emissions, isNotEmpty, reason: '订阅后必须立即加载一次');
    final before = emissions.last;
    final baseline = signatureOf(before);
    final countBefore = emissions.length;

    await write();
    for (var attempt = 0; attempt < 20; attempt++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await pumpEventQueue();

    expect(
      emissions.length,
      greaterThan(countBefore),
      reason: '$reason：成功写入之后数据源必须**重新发值**（旧结果是"改完看不见"）',
    );
    final after = emissions.last;
    expect(
      signatureOf(after),
      isNot(baseline),
      reason:
          '$reason：重新发的那一份必须是**重新读取**的结果。'
          '只断言"又发了一份"会被"把上一份原样重发"蒙过去',
    );
    return (before: before, after: after);
  }

  test('删除固定日程 ⇒ 数据源重新发值，且那一条真的消失', () async {
    final saved = await calendar.save(
      EventDraft(
        title: '数据结构课',
        startAtUtc: windowStart.add(const Duration(hours: 9)),
        endAtUtc: windowStart.add(const Duration(hours: 10)),
        timeZoneId: timeZoneId,
      ),
    );
    final eventId = saved.event!.id;

    final result = await refreshedAfter(
      () => calendar.deleteEvent(eventId),
      reason: '删除固定日程',
    );

    expect(
      result.after.any((item) => item.id == 'fixed:$eventId'),
      isFalse,
      reason: '删掉的日程不能再出现在列表里',
    );
  });

  test('修改保护规则（按日例外）⇒ 数据源重新发值，且那一天的受保护区间换了', () async {
    // **覆盖必须落在窗口首日**：`PlanningRuleResolver.resolveForWindow()` 只探测"窗口首日"
    // 与"下一个周末日"这两个日期（`ScheduleProblem.rules` 是单一对象，表达不了逐日不同），
    // 因此对 2026-10-06 的覆盖根本不会进入这份窗口规则。这不是缺陷，是 `resolveForWindow`
    // 的既有契约；本用例按它写，否则测到的是夹具挑错了日期。
    final result = await refreshedAfter(
      () => settings.saveDateOverride(
        DateTime(2026, 10, 5),
        PlanningRulesPatch(
          protectedTimes: [
            ProtectedTimeRule(
              kind: ProtectedTimeKind.lunch,
              range: LocalTimeRange(startMinute: 14 * 60, endMinute: 15 * 60),
            ),
          ],
        ),
      ),
      reason: '修改保护规则',
    );

    // 正面的内容断言：覆盖之后首日确实多出**那一段**受保护区间，而不是"规则没生效、
    // 列表只是因为别的字段变了才看起来不同"。
    bool isOverridden(ScheduleViewItem item) =>
        item.kind == ScheduleItemKind.protectedTime &&
        item.range.startUtc == DateTime.utc(2026, 10, 5, 14) &&
        item.range.endUtc == DateTime.utc(2026, 10, 5, 15);

    expect(
      result.after.where(isOverridden),
      isNotEmpty,
      reason: '按日例外把首日的保护时间换成 14:00–15:00（本地时间＝UTC，本用例时区为 UTC）',
    );
    expect(
      result.before.where(isOverridden),
      isEmpty,
      reason: '那一段**只有**在覆盖生效之后才存在——否则这条用例证明不了规则真的被读回来了',
    );
  });

  test('保存配色 ⇒ 数据源重新发值，且受保护时间换成新颜色', () async {
    const newColor = 0xff112233;
    final result = await refreshedAfter(
      () => colors.setSpecialColor(
        ScheduleSpecialCategory.protectedTime,
        newColor,
      ),
      reason: '保存配色',
    );

    final protectedItems = result.after
        .where((item) => item.kind == ScheduleItemKind.protectedTime)
        .toList();
    expect(protectedItems, isNotEmpty, reason: '前置条件：默认规则会展开出保护时间');
    expect(
      protectedItems.every((item) => item.categoryColorArgb == newColor),
      isTrue,
      reason: '配色是"同一份数据换一种画法"：写完必须读回新颜色，否则用户改了颜色而日历不变',
    );
  });

  test('领域改名 ⇒ 数据源重新发值，且卡片的分类名换成新名字', () async {
    await workspace.ensureDefaultAreas();
    final area = (await workspace.listAreas()).firstWhere(
      (item) => item.name == '学业',
    );
    await calendar.save(
      EventDraft(
        title: '数据结构课',
        startAtUtc: windowStart.add(const Duration(hours: 9)),
        endAtUtc: windowStart.add(const Duration(hours: 10)),
        timeZoneId: timeZoneId,
        areaId: area.id,
      ),
    );

    final result = await refreshedAfter(
      () => workspace.renameArea(area, '学业（改）'),
      reason: '领域改名',
    );

    expect(
      result.after.any((item) => item.categoryLabel == '学业（改）'),
      isTrue,
      reason: '领域名就是日历卡片上的分类名：改完必须读回新名字',
    );
    expect(
      result.after.any((item) => item.categoryLabel == '学业'),
      isFalse,
      reason: '旧分类名不得同时留着',
    );
  });

  test('撤销计划 ⇒ 数据源重新发值，且计划块回到上一版的位置', () async {
    // 两版计划：A 在 09:00，B 在 10:00。应用两次之后 B 是当前版、A 是上一版。
    //
    // `PlanApplicationService.apply` 会**重放输入并重算哈希**，因此提案的 `inputHash`
    // 必须等于用同一份 `ScheduleProblem` 算出来的那一个——否则它（正确地）判为过期。
    final problem = _problem();
    final hash = const InputSnapshotBuilder().hash(
      InputSnapshot(problem: problem),
    );
    final first = await apply.apply(_proposal(hours: 9, hash: hash));
    expect(first.status, ApplyPlanStatus.applied, reason: '前置条件：第一版必须真的落库');
    final second = await apply.apply(_proposal(hours: 10, hash: hash));
    expect(second.status, ApplyPlanStatus.applied, reason: '前置条件：第二版必须真的落库');

    final result = await refreshedAfter(
      undo.undoLastAppliedPlan,
      reason: '撤销计划',
    );

    final blocks = result.after.where(
      (item) => item.kind == ScheduleItemKind.task,
    );
    expect(blocks, isNotEmpty, reason: '撤销之后必须还能看到恢复出来的计划块');
    expect(
      blocks.every(
        (item) =>
            item.range.startUtc == windowStart.add(const Duration(hours: 9)),
      ),
      isTrue,
      reason: '撤销把当前计划换成上一版：块必须回到 09:00 那一版的位置',
    );
  });
}

/// 撤销／应用路径都不需要真的排程，但 `PlanApplicationService` 要求一个来源，
/// 而它的重放校验会真的跑一遍 `PlanValidator`——因此这里必须给出一件**合法**的任务，
/// 否则块的 `taskId` 会被判 `unknownTask`，`apply` 会在 Task 5 新增的
/// "冲突先于 validator"那条闸门处直接返回 invalid。
ScheduleProblem _problem() {
  final window = TimeRange(
    startUtc: DateTime.utc(2026, 10, 5),
    endUtc: DateTime.utc(2026, 10, 12),
  );
  final zoneId = 'UTC';
  final rules = DefaultSettings.v1();
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: zoneId,
    tasks: const [
      SchedulableTask(
        id: 'task-1',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      ),
    ],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'ignored',
  );
}

final class _NoProblemSource implements ScheduleProblemSource {
  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async => _problem();
}

/// 一份只有一个块的提案。`hash` 必须与仓储当前期望的输入哈希一致，
/// 否则应用服务会（正确地）判它过期。
ScheduleProposal _proposal({required int hours, required String hash}) =>
    ScheduleProposal(
      proposalId: 'proposal-$hours',
      inputHash: hash,
      algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5),
        endUtc: DateTime.utc(2026, 10, 12),
      ),
      blocks: [
        PlannedBlock(
          id: 'block-$hours',
          taskId: 'task-1',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, hours),
            endUtc: DateTime.utc(2026, 10, 5, hours + 1),
          ),
        ),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 60,
        unscheduledMinutes: 0,
      ),
    );

final class _FixedClock implements Clock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime nowUtc() => value;
}
