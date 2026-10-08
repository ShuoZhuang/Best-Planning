import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final _windowStart = DateTime.utc(2026, 10, 4, 16);
final _windowEnd = DateTime.utc(2026, 10, 5, 16);

TimeRange _range(int localHour) => TimeRange(
  startUtc: _windowStart.add(Duration(hours: localHour)),
  endUtc: _windowStart.add(Duration(hours: localHour + 1)),
);

/// 与 [_range] 同宽（1 小时），但可以再叠加分钟偏移——用来表达"重排把块挪了几分钟"。
TimeRange _shiftedRange({required int hours, required int minutes}) =>
    TimeRange(
      startUtc: _windowStart.add(Duration(hours: hours, minutes: minutes)),
      endUtc: _windowStart.add(Duration(hours: hours + 1, minutes: minutes)),
    );

PlannerTask _task(String id, String title, {String? areaId}) => PlannerTask(
  id: id,
  areaId: areaId,
  title: title,
  priority: TaskPriority.medium,
  estimatedMinutes: 60,
  remainingMinutes: 60,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026),
  updatedAtUtc: DateTime.utc(2026),
);

CalendarOccurrence _fixed(
  String id,
  String title,
  int hour, {
  String? areaId,
}) => CalendarOccurrence(
  eventId: id,
  title: title,
  range: _range(hour),
  locked: true,
  areaId: areaId,
);

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

final class _Tasks implements TaskRepository {
  const _Tasks(this.values);
  final List<PlannerTask> values;

  @override
  Future<PlannerTask?> getById(String id) async =>
      values.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {}

  /// 与生产 DAO 的 `watchAll` 一致：**不做任何状态过滤**，已完成与已取消都在其中。
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(values);

  /// 与生产 DAO 的 `watchOpen` 一致：**已结束的任务不在其中**。
  ///
  /// 夹具必须照实模拟这一点，否则"勾完完成后计划块查不到标题与领域"那条回归根本测不出来——
  /// 之前的夹具把全部任务都当成未结束的，于是这个缺陷在测试里是隐形的。
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(
    values
        .where(
          (task) =>
              task.status != TaskStatus.completed &&
              task.status != TaskStatus.cancelled,
        )
        .toList(),
  );
}

final class _Calendar implements CalendarRepository {
  const _Calendar(this.values);
  final List<CalendarOccurrence> values;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => values;

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _Plans implements PlanRepository {
  const _Plans(this.value);
  final ConfirmedPlan value;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();

  @override
  Future<ConfirmedPlan?> current() async => value;
}

/// 构造一条历史块。默认版本 `v1`、生成于窗口之前——绝大多数用例不必关心版本与时刻。
HistoricalPlanBlock _historical(
  PlannedBlock block, {
  String version = 'v1',
  DateTime? createdAtUtc,
}) => HistoricalPlanBlock(
  block: block,
  versionId: version,
  versionCreatedAtUtc:
      createdAtUtc ?? _windowStart.subtract(const Duration(days: 1)),
);

/// 历史计划块（含已被取代的版本）。默认空——既有用例不关心历史，行为与从前一致。
final class _History implements PlanBlockHistory {
  _History([this.entries = const []]);
  final List<HistoricalPlanBlock> entries;

  @override
  Future<List<HistoricalPlanBlock>> blocksInWindow(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [
    for (final entry in entries)
      if (entry.block.range.startUtc.isBefore(endUtc) &&
          entry.block.range.endUtc.isAfter(startUtc))
        entry,
  ];
}

final class _Workspace implements WorkspaceRepository {
  const _Workspace(this.areas);
  final List<PlannerArea> areas;

  @override
  Future<List<PlannerArea>> listAreas() async => areas;

  @override
  Future<List<PlannerProject>> listProjects() async => const [];

  @override
  Future<void> saveArea(PlannerArea area) async {}

  @override
  Future<void> saveProject(PlannerProject project) async {}
}

PlannerArea _area(String id, String name) => PlannerArea(
  id: id,
  name: name,
  color: 0xff456789,
  sortOrder: id == 'study' ? 0 : 1,
  createdAtUtc: DateTime.utc(2026),
  updatedAtUtc: DateTime.utc(2026),
);

void main() {
  test('数据源为领域、无领域、失效领域和保护时间统一解析分类', () async {
    final tasks = <PlannerTask>[
      _task('task-study', '领域任务', areaId: 'study'),
      _task('task-none', '无领域任务'),
      _task('task-deleted', '失效领域任务', areaId: 'deleted'),
      _task('task-research', '同色科研任务', areaId: 'research'),
    ];
    final plan = ConfirmedPlan(
      id: 'plan',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        for (var index = 0; index < tasks.length; index++)
          PlannedBlock(
            id: 'block-$index',
            taskId: tasks[index].id,
            range: _range(7 + index),
          ),
      ],
    );
    final settings = MemorySettingsRepository();
    final colors = ScheduleColorService(
      settings: settings,
      workspace: _Workspace([_area('study', '学业'), _area('research', '科研')]),
    );
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar([
        _fixed('fixed-study', '领域固定日程', 1, areaId: 'study'),
        _fixed('fixed-none', '无领域固定日程', 2),
        _fixed('fixed-deleted', '失效领域固定日程', 3, areaId: 'deleted'),
      ]),
      plans: _Plans(plan),
      history: _History(),
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: colors,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      // 显式给"现在"：否则 `isCompleted` 会取真实系统时间，测试就变成跟挂钟走的了。
      clock: _FixedClock(_windowStart),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    ScheduleViewItem named(String title) =>
        items.firstWhere((item) => item.title == title);

    expect(named('领域任务').categoryKey, 'area:study');
    expect(named('领域任务').categoryLabel, '学业');
    expect(named('领域固定日程').categoryKey, 'area:study');
    expect(named('领域固定日程').categoryColorArgb, named('领域任务').categoryColorArgb);

    expect(named('无领域任务').categoryKey, 'special:unassigned-task');
    expect(named('失效领域任务').categoryKey, 'special:unassigned-task');
    expect(named('无领域固定日程').categoryKey, 'special:unassigned-fixed');
    expect(named('失效领域固定日程').categoryKey, 'special:unassigned-fixed');

    final protected = items.where(
      (item) => item.kind == ScheduleItemKind.protectedTime,
    );
    expect(protected, isNotEmpty);
    expect(
      protected.every((item) => item.categoryKey == 'special:protected'),
      isTrue,
    );

    expect(named('同色科研任务').categoryKey, 'area:research');
    expect(named('同色科研任务').categoryColorArgb, named('领域任务').categoryColorArgb);
  });

  test('已完成任务的计划块仍显示真实标题与领域，并标记为已完成', () async {
    // 计划块不会因为勾选完成而消失（只有重排才会去掉），但任务已经离开"未结束"集合。
    // 此前这里会退化成标题「已安排任务」+ 分类「无领域任务」，用户看到的是"勾完之后
    // 卡片变成了另一个分类"，而且颜色也跟着变。
    final tasks = <PlannerTask>[
      _task('task-open', '还在做的事', areaId: 'study'),
      _task(
        'task-done',
        '已经做完的事',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
    ];
    final plan = ConfirmedPlan(
      id: 'plan',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        for (var index = 0; index < tasks.length; index++)
          PlannedBlock(
            id: 'block-$index',
            taskId: tasks[index].id,
            range: _range(7 + index),
          ),
      ],
    );
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: _History(),
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: _FixedClock(_windowStart),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    final done = items.firstWhere((item) => item.id == 'block:block-1');
    final open = items.firstWhere((item) => item.id == 'block:block-0');

    expect(done.title, '已经做完的事', reason: '不该回退成「已安排任务」');
    expect(done.categoryKey, 'area:study', reason: '不该退化成「无领域任务」');
    expect(done.categoryLabel, '学业');
    expect(done.areaId, 'study');
    expect(done.isCompleted, isTrue);

    expect(open.title, '还在做的事');
    expect(open.isCompleted, isFalse);

    // M4（路线图 §8）：视图条目必须能指回**任务**，今日页才能就地开始专注／完成／查看详情。
    // 此前任务 id 只藏在 `id` 的 `'block:'` 前缀之后（那是**计划块 id**，不是任务 id），
    // 页面要用它就得拆字符串或反过来查计划——两种都会让视图层重新认识领域结构。
    expect(open.taskId, 'task-open');
    expect(done.taskId, 'task-done');
    // 计划块 id 与任务 id 是两件事，这里刻意断言它们不同，免得以后有人把它们混成一个。
    expect(open.id, 'block:block-0');
    expect(open.taskId, isNot(open.id));

    // 两者同领域 → 同色：完成不该改变分类色。
    expect(done.categoryColorArgb, open.categoryColorArgb);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // M9 收口后修：**今天做完的事不能消失**（用户 2026-10-07 实测报告）。
  //
  // 用户原话："我今天完成的算法作业为什么在今日和日历界面不见了"。
  //
  // 用他的真实数据核对出的机制：勾选完成 → 重排；**已完成的任务不再参与排程**，
  // 因此新版本计划里不再有它的块（他库里 `算法作业` 只在 03:51 与 01:49 两版里，
  // 而当前版是 21:18 生成的）。而"当天有当前版的块就只用当前版"这条规则让今天
  // 正好命中——于是那条**已经做完的记录整天消失**。
  // ─────────────────────────────────────────────────────────────────────────────

  test('今天做完的事：当前版不再排它时，仍然显示在做它的那个时间', () async {
    final tasks = <PlannerTask>[
      _task(
        'task-done',
        '算法作业',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
      // 另一个**还在做**的任务：它让"今天有当前版的块"，从而命中那条规则。
      _task('task-open', '整理新生成长营文件', areaId: 'study'),
    ];
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        // 当前版只给未完成的任务排了位置；已完成的那个已经不在里面了。
        PlannedBlock(id: 'open-block', taskId: 'task-open', range: _range(14)),
      ],
    );
    final history = _History([
      // 旧版（当时在用的那一版）里有那条已经做完的块。
      _historical(
        PlannedBlock(id: 'done-1000', taskId: 'task-done', range: _range(10)),
        version: 'v-old',
        // 那一版是**当天已经开工之后**生成的（`_windowStart` 是本地 00:00，注入的现在是它）。
        createdAtUtc: _windowStart.add(const Duration(hours: 8)),
      ),
    ]);
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: history,
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      // **“现在”必须晚于那块：注入 00:00 的话 10:00 的块还在未来，
      // 本用例的前提（已经做完了）就不成立——第一版正是这么写错的。
      clock: _FixedClock(_windowStart.add(const Duration(hours: 12))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;

    final done = items.where((item) => item.taskId == 'task-done').toList();
    expect(
      done,
      hasLength(1),
      reason:
          '今天做完的那条必须**正好出现一次**：出现零次就是用户报的"不见了"，'
          '出现两次就是此前修过的"已完成待办重复"。实际：'
          '${items.map((i) => '${i.title}@${i.range.startUtc}').toList()}',
    );
    expect(done.single.title, '算法作业', reason: '标题不能回退成「已安排任务」');
    expect(done.single.categoryLabel, '学业', reason: '领域不能退化成「无领域任务」');
    expect(done.single.isCompleted, isTrue, reason: '任务已完成，卡片应当带完成标记');
    // **还在做的那条照常在**：补历史不能把它挤掉。
    expect(items.where((item) => item.taskId == 'task-open'), hasLength(1));
  });

  test('今天做完的事：当前版**仍然**排着它时，不会因此多出一条', () async {
    // 反面：如果重排后当前版里还有这个任务的块，就不能再从旧版补一条——
    // 那正是"已完成待办重复"。判据必须按**任务**，不能按块 id。
    final tasks = <PlannerTask>[
      _task(
        'task-done',
        '算法作业',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
    ];
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        PlannedBlock(id: 'now-1000', taskId: 'task-done', range: _range(10)),
      ],
    );
    final history = _History([
      _historical(
        PlannedBlock(id: 'old-0730', taskId: 'task-done', range: _range(7)),
        version: 'v-old',
        // 那一版是**当天已经开工之后**生成的（`_windowStart` 是本地 00:00，注入的现在是它）。
        createdAtUtc: _windowStart.add(const Duration(hours: 8)),
      ),
    ]);
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: history,
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      // **“现在”必须晚于那块：注入 00:00 的话 10:00 的块还在未来，
      // 本用例的前提（已经做完了）就不成立——第一版正是这么写错的。
      clock: _FixedClock(_windowStart.add(const Duration(hours: 12))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    expect(
      items.where((item) => item.taskId == 'task-done'),
      hasLength(1),
      reason: '当前版说了它在 10:00，就不该再把旧版的 07:30 也捞回来',
    );
  });

  test('今天做完的事：只补**整段已经过去**的块，未来时间上的不补', () async {
    // 未来的时间不存在"做完了"。若把未来块也补进来，会出现"同一件事在将来还有一次"。
    final tasks = <PlannerTask>[
      _task(
        'task-done',
        '算法作业',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
      _task('task-open', '整理新生成长营文件', areaId: 'study'),
    ];
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        PlannedBlock(id: 'open-block', taskId: 'task-open', range: _range(14)),
      ],
    );
    final history = _History([
      _historical(
        // `_windowStart` 是本地 00:00；`_range(20)` 落在**当天晚上 20:00**，
        // 而注入的时钟就是 `_windowStart`（即"现在是当天 00:00"）——因此那一段在未来。
        PlannedBlock(id: 'future-done', taskId: 'task-done', range: _range(20)),
        version: 'v-old',
        // 那一版是**当天已经开工之后**生成的（`_windowStart` 是本地 00:00，注入的现在是它）。
        createdAtUtc: _windowStart.add(const Duration(hours: 8)),
      ),
    ]);
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: history,
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      // **“现在”必须晚于那块：注入 00:00 的话 10:00 的块还在未来，
      // 本用例的前提（已经做完了）就不成立——第一版正是这么写错的。
      clock: _FixedClock(_windowStart.add(const Duration(hours: 12))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    expect(
      items.where((item) => item.taskId == 'task-done'),
      isEmpty,
      reason: '那一段还没到，不可能是"做完的记录"',
    );
  });

  test('固定日程与保护时间没有任务 id（它们不是任务）', () async {
    // M4：`taskId` 为空是"这一条不该出现任务动作"的依据——今日页据此不渲染
    // 「完成／延后／开始专注」，否则用户会对一条保护时间点"完成"，而那个动作无处落地。
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(const []),
      calendar: _Calendar([
        CalendarOccurrence(
          eventId: 'event-1',
          title: '线性代数',
          range: _range(9),
          areaId: 'study',
          // 字段确实叫 `locked`；不是我记的名字。
          locked: false,
        ),
      ]),
      // `_Plans` 要一个非空 `ConfirmedPlan`（它是既有替身的签名），
      // 因此给一份**没有块**的计划——本条用例只关心固定日程与保护时间。
      plans: _Plans(
        ConfirmedPlan(
          id: 'plan-empty',
          inputHash: 'hash',
          algorithmVersion: '1',
          blocks: const [],
        ),
      ),
      history: _History(),
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: _FixedClock(_windowStart),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    final fixed = items.firstWhere(
      (item) => item.kind == ScheduleItemKind.fixed,
    );
    expect(fixed.taskId, isNull, reason: '固定日程没有所属任务');

    for (final item in items.where(
      (item) => item.kind == ScheduleItemKind.protectedTime,
    )) {
      expect(item.taskId, isNull, reason: '保护时间是按规则算出来的区间，不是任务');
    }
  });

  test('固定日程在时间过去之后才标记为已完成', () async {
    final settings = MemorySettingsRepository();
    final colors = ScheduleColorService(
      settings: settings,
      workspace: _Workspace([_area('study', '学业')]),
    );
    RepositoryScheduleViewSource sourceAt(DateTime nowUtc) =>
        RepositoryScheduleViewSource(
          tasks: _Tasks(const []),
          // 1 点、2 点各一场，窗口从 `_windowStart` 起算。
          calendar: _Calendar([
            _fixed('early', '早场', 1, areaId: 'study'),
            _fixed('late', '晚场', 5, areaId: 'study'),
          ]),
          plans: _Plans(
            ConfirmedPlan(
              id: 'plan',
              inputHash: 'hash',
              algorithmVersion: '1',
              blocks: const [],
            ),
          ),
          history: _History(),
          rules: PlanningRuleResolver(SettingsService(repository: settings)),
          colors: colors,
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
          clock: _FixedClock(nowUtc),
        );

    // "现在"在窗口开始：两场都还没到 → 都不标记。
    final beforeAll = await sourceAt(_windowStart)
        .watch(_windowStart, _windowEnd)
        .first;
    expect(
      beforeAll.where((item) => item.kind == ScheduleItemKind.fixed).length,
      2,
    );
    expect(beforeAll.every((item) => !item.isCompleted), isTrue);

    // "现在"在第一场结束之后、第二场结束之前：只有早场被标记。
    final between = await sourceAt(_range(2).endUtc)
        .watch(_windowStart, _windowEnd)
        .first;
    final early = between.firstWhere((item) => item.id == 'fixed:early');
    final late = between.firstWhere((item) => item.id == 'fixed:late');
    expect(early.isCompleted, isTrue, reason: '结束时间已过 → 标记已完成');
    expect(late.isCompleted, isFalse, reason: '还没结束 → 不标记');

    // 保护时间不参与这个标记：它不是待办。
    expect(
      between
          .where((item) => item.kind == ScheduleItemKind.protectedTime)
          .every((item) => !item.isCompleted),
      isTrue,
    );
  });

  test('已经完整过去的那一天，用"当时在用的那一版"还原——历史不被后来的计划改写', () async {
    // 用户 2026-10-07 的原话："如果我后续的计划需要进行重排，已完成的计划在视图里就不需要
    // 改变了啊，像昨天已经完成计划在我刚才调整计划后就都不见了"。
    //
    // 成因：日程数据源只读 `plans.current()`（最新一版），而重排会生成新版本；昨天那几个块只
    // 存在于**已被取代**的版本里。因此这里把"现在"设在窗口那一日**结束之后**，当前计划里
    // 也不再有那一天的块（新计划只覆盖之后几天）。
    final tasks = <PlannerTask>[
      _task('task-open', '今天要做的事', areaId: 'study'),
      _task(
        'task-done',
        '昨天做完的事',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
    ];
    // 当前计划只覆盖窗口之后的时间（真实情形：今天重新生成计划，昨天已不在其中）。
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        PlannedBlock(
          id: 'future',
          taskId: 'task-open',
          // 窗口是 `_windowStart` 起的一天，+30 小时落在窗口之外。
          range: _shiftedRange(hours: 30, minutes: 0),
        ),
      ],
    );
    final history = _History([
      _historical(
        PlannedBlock(id: 'past', taskId: 'task-done', range: _range(1)),
        version: 'v-old',
        createdAtUtc: _windowStart.add(const Duration(hours: 8)),
      ),
    ]);
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: history,
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      // "现在"在窗口那一日结束之后 → 那一天已经完整过去。
      clock: _FixedClock(_windowEnd.add(const Duration(hours: 12))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    final ids = items.map((item) => item.id).toList();

    expect(ids, contains('block:past'), reason: '那一天当时排了什么，必须留在视图里');

    // 而且历史块仍然带着**真实标题与领域**：它指向的任务早就完成了，补查那一步不能漏。
    final past = items.firstWhere((item) => item.id == 'block:past');
    expect(past.title, '昨天做完的事');
    expect(past.categoryKey, 'area:study');
    expect(past.isCompleted, isTrue);
  });

  test('今天：当前版本说过的时间只算一次，不把旧版的同一件事再捞回来', () async {
    // 用户 2026-10-07 的数据里就有这一例：`算法作业` 在当前版是今天 10:00、在旧版是今天 07:30。
    // 把两版并起来 → **今天出现两次**，这正是他说的"已完成待办重复"。
    final tasks = <PlannerTask>[
      _task(
        'task-a',
        '算法作业',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
    ];
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        PlannedBlock(
          id: 'now-1000',
          taskId: 'task-a',
          range: _shiftedRange(hours: 10, minutes: 0),
        ),
      ],
    );
    final history = _History([
      _historical(
        PlannedBlock(
          id: 'old-0730',
          taskId: 'task-a',
          range: _shiftedRange(hours: 7, minutes: 30),
        ),
        version: 'v-old',
        createdAtUtc: _windowStart.subtract(const Duration(hours: 12)),
      ),
    ]);
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: history,
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      // "现在"落在同一天的 20:00：这一天还没结束，因此以当前为准。
      clock: _FixedClock(_windowStart.add(const Duration(hours: 20))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    final taskItems = items
        .where((item) => item.kind == ScheduleItemKind.task)
        .toList();

    expect(taskItems, hasLength(1), reason: '当前版本已经就今天说过一次，旧版的同一件事不能再显示一遍');
    expect(taskItems.single.id, 'block:now-1000');
  });

  test('已经过去的那一天在两版里各有一套块时，只显示当时在用的那一版', () async {
    // 用户 2026-10-07 数据里的另一例：`大物预习课`（已完成）在旧版是 50+90 分钟、在新版是
    // 90+50 分钟——两版的起止都被挪过。**一版计划是对那段时间的完整声明**，所以那一天只该由
    // 一版决定；求并集就会出现三四次同一件事。
    final tasks = <PlannerTask>[
      _task(
        'task-b',
        '大物预习课',
        areaId: 'study',
      ).copyWith(status: TaskStatus.completed),
    ];
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: const [],
    );
    final history = _History([
      _historical(
        PlannedBlock(id: 'v1-x', taskId: 'task-b', range: _range(1)),
        version: 'v1',
        createdAtUtc: _windowStart.add(const Duration(hours: 6)),
      ),
      _historical(
        PlannedBlock(id: 'v1-y', taskId: 'task-b', range: _range(6)),
        version: 'v1',
        createdAtUtc: _windowStart.add(const Duration(hours: 6)),
      ),
      _historical(
        PlannedBlock(id: 'v2-y', taskId: 'task-b', range: _range(6)),
        version: 'v2',
        createdAtUtc: _windowStart.add(const Duration(hours: 9)),
      ),
      _historical(
        PlannedBlock(id: 'v2-z', taskId: 'task-b', range: _range(11)),
        version: 'v2',
        createdAtUtc: _windowStart.add(const Duration(hours: 9)),
      ),
    ]);
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: history,
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: _FixedClock(_windowEnd.add(const Duration(hours: 12))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    final ids = items.map((item) => item.id).toList();

    expect(
      ids,
      containsAll(<String>['block:v2-y', 'block:v2-z']),
      reason: '取"当天结束时在用的那一版"（v2）',
    );
    expect(
      ids,
      isNot(anyOf(contains('block:v1-x'), contains('block:v1-y'))),
      reason: '旧版 (v1) 那一天的整套安排已经被 v2 取代，不能并进来',
    );
  });

  test('同一天把一件事拆成不重叠的两段时，两段都保留', () async {
    // 去重不能用力过猛：上午一段、下午一段是**两件不同的安排**，不是重复。
    final tasks = <PlannerTask>[_task('task-split', '分两段做的事', areaId: 'study')];
    final plan = ConfirmedPlan(
      id: 'plan-new',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: [
        PlannedBlock(id: 'seg-1', taskId: 'task-split', range: _range(1)),
        PlannedBlock(id: 'seg-2', taskId: 'task-split', range: _range(6)),
      ],
    );
    final settings = MemorySettingsRepository();
    final source = RepositoryScheduleViewSource(
      tasks: _Tasks(tasks),
      calendar: _Calendar(const []),
      plans: _Plans(plan),
      history: _History(),
      rules: PlanningRuleResolver(SettingsService(repository: settings)),
      colors: ScheduleColorService(
        settings: settings,
        workspace: _Workspace([_area('study', '学业')]),
      ),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: _FixedClock(_windowStart.add(const Duration(hours: 10))),
    );

    final items = await source.watch(_windowStart, _windowEnd).first;
    final taskItems = items
        .where((item) => item.kind == ScheduleItemKind.task)
        .toList();

    expect(taskItems, hasLength(2), reason: '不重叠的两段是两件安排，都要在');
  });
}
