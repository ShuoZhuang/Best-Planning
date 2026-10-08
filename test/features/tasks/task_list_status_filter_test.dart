// §12.2：任务清单**状态筛选**的 Widget 测试。
//
// 这个文件回答的是"用户在界面上能不能真的做到"这一类问题，因此它不重复纯逻辑测试
// 已经钉住的分组口径，而是钉住界面这一层的五件事：
//   1. 筛选栏的**数量**与点击结果；
//   2. 搜索**不改变**筛选栏数量（数量在搜索之前算，§5）；
//   3. 各筛选的**空状态文案**互不混用（§7）；
//   4. 多选与筛选的交互：切筛选退多选、"已完成"里没有多选按钮、取消完成立即生效（§6）；
//   5. 没有计划仓库时页面照常可用（§11）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tasks/task_list_filter.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/domain/models/time_range.dart';

final _now = DateTime.utc(2026, 10, 7, 12);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'generated';
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);

  final Map<String, PlannerTask> tasks;

  /// 与生产 `DriftTaskRepository` 同型：**每次保存都推一次全量**。
  ///
  /// 这一点必须照实模拟，否则"取消完成后任务立即从已完成里消失"这类断言是**假通过**：
  /// 一个只 `Stream.value(...)` 的替身在页面重建时会**重放同一个快照**，
  /// 于是状态改了、界面却看起来没变，或者反过来看起来变了。
  final StreamController<List<PlannerTask>> _changes =
      StreamController.broadcast();

  /// 全量监听；这个替身没有数据库，因此"全部"与"未结束"共用一份数据。
  @override
  Stream<List<PlannerTask>> watchAllTasks() async* {
    yield tasks.values.toList();
    yield* _changes.stream;
  }

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => watchAllTasks();

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async {
    tasks[task.id] = task;
    _changes.add(tasks.values.toList());
  }
}

/// 只回答"当前确认计划是什么"的替身，与生产 `DriftPlanRepository.current()` 同型。
final class _Plans implements PlanRepository {
  _Plans(this.plan);
  ConfirmedPlan? plan;

  @override
  Future<ConfirmedPlan?> current() async => plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

PlannerTask _task(
  String id,
  String title, {
  TaskStatus status = TaskStatus.open,
  int estimatedMinutes = 30,
  int? remainingMinutes,
  DateTime? dueAtUtc,
}) => PlannerTask(
  id: id,
  title: title,
  notes: '',
  priority: TaskPriority.medium,
  estimatedMinutes: estimatedMinutes,
  remainingMinutes: remainingMinutes ?? estimatedMinutes,
  dueAtUtc: dueAtUtc,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

DateTime _at(int hour, int minute) => DateTime.utc(2026, 10, 7, hour, minute);

ConfirmedPlan _plan(List<PlannedBlock> blocks) => ConfirmedPlan(
  id: 'plan-1',
  inputHash: 'hash',
  algorithmVersion: 'v1',
  blocks: blocks,
);

PlannedBlock _block(String taskId, DateTime startUtc, DateTime endUtc) =>
    PlannedBlock(
      id: '$taskId-block',
      taskId: taskId,
      range: TimeRange(startUtc: startUtc, endUtc: endUtc),
    );

void main() {
  /// "已安排为空"用例里记录"生成计划"按钮被按下的次数。
  var generated = 0;
  late _Tasks tasks;
  late TaskService service;

  /// 8 条任务的固定夹具，与需求 §1 的例子同量级：
  /// 待安排 2、已安排 4、已完成 2，另有 1 条取消、1 条跳过（两者都不出现在"全部"里）。
  void seed() {
    tasks = _Tasks({
      'u1': _task('u1', '算法作业', estimatedMinutes: 50),
      'u2': _task('u2', '大物作业', dueAtUtc: DateTime.utc(2026, 10, 6, 15, 59)),
      's1': _task('s1', '大物预习课', estimatedMinutes: 90),
      's2': _task('s2', '英语听力'),
      's3': _task('s3', '线代刷题'),
      's4': _task('s4', '实验报告'),
      'c1': _task(
        'c1',
        '竞赛报名',
        status: TaskStatus.completed,
        estimatedMinutes: 40,
        remainingMinutes: 15,
      ),
      'c2': _task('c2', '体检预约', status: TaskStatus.completed),
      'x1': _task('x1', '旧草稿', status: TaskStatus.cancelled),
      'x2': _task('x2', '放弃的想法', status: TaskStatus.skipped),
    });
    service = TaskService(
      repository: tasks,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  }

  /// 当前确认计划：四条任务各有一个**尚未结束**的块。
  _Plans scheduledPlans() => _Plans(
    _plan([
      _block('s1', _at(13, 0), _at(14, 30)),
      _block('s2', _at(15, 0), _at(16, 0)),
      _block('s3', _at(17, 0), _at(18, 0)),
      _block('s4', _at(19, 0), _at(20, 0)),
    ]),
  );

  setUp(seed);

  Future<void> pump(
    WidgetTester tester, {
    PlanRepository? plans,
    VoidCallback? onGeneratePlan,
  }) async {
    // 默认的 800×600 测试视口装不下 10 条任务，而 `ListView` 只构建可见项——
    // 于是"已完成"那几条根本不在树里，查找它们会以"找不到"的形式失败，
    // 看起来像筛选坏了，其实只是没滚到。宽度取真实初始窗口的 1280（见
    // `windows/runner/main.cpp`），高度放大到足以容纳整份夹具。
    const surface = Size(1280, 1600);
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListPage(
            service: service,
            nowUtc: _now,
            plans: plans,
            // **显式注入 UTC 而不是让页面退回系统时区**：`DateTime.toLocal()` 走的是
            // 跑测试这台机器的时区，同一个断言会在不同机器上得到不同钟点。注入之后
            // "13:00–14:30"这条断言在任何机器上都成立。
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onGeneratePlan: onGeneratePlan,
          ),
        ),
      ),
    );
    // 计划是异步读的，因此必须 pumpAndSettle 而不是 pump：只 pump 一帧会看到
    // "还没算出已安排"的中间态，那正是这个页面最容易被误判的地方。
    await tester.pumpAndSettle();
  }

  /// 点筛选项。用 `ChoiceChip` 的 `onSelected` 直接驱动，而不是去点那段文字：
  /// 窄窗口下筛选栏会横向滚动，段可能落在可视区之外，那样测试会因为"点不到"而红，
  /// 而失败原因与筛选逻辑毫无关系。
  ///
  /// （M2 把筛选控件从 `SegmentedButton` 换成了 `ChoiceChip`——前者每个分段会在语义树里
  /// 产生两个同名节点，屏幕阅读器会把每个筛选项念两遍。这里跟着换驱动方式。）
  Future<void> tapFilter(WidgetTester tester, TaskListFilter filter) async {
    final chip = tester.widget<ChoiceChip>(
      find.byKey(Key('task-filter-${filter.name}')),
    );
    chip.onSelected?.call(true);
    await tester.pumpAndSettle();
  }

  /// 当前选中的筛选项（由 chip 的 `selected` 读出，而不是从页面私有状态猜）。
  Set<TaskListFilter> selectedFilters(WidgetTester tester) => {
    for (final filter in TaskListFilter.values)
      if (tester
          .widget<ChoiceChip>(find.byKey(Key('task-filter-${filter.name}')))
          .selected)
        filter,
  };

  String filterLabel(WidgetTester tester, TaskListFilter filter) => tester
      .widget<Text>(find.byKey(Key('task-filter-${filter.name}-label')))
      .data!;

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(SearchBar), query);
    await tester.pumpAndSettle();
  }

  group('筛选栏', () {
    testWidgets('默认选择"全部"', (tester) async {
      await pump(tester, plans: scheduledPlans());
      expect(selectedFilters(tester), {TaskListFilter.all});
    });

    testWidgets('四个筛选项的数量正确，且满足加和关系', (tester) async {
      await pump(tester, plans: scheduledPlans());
      expect(filterLabel(tester, TaskListFilter.all), '全部 8');
      expect(filterLabel(tester, TaskListFilter.unscheduled), '待安排 2');
      expect(filterLabel(tester, TaskListFilter.scheduled), '已安排 4');
      expect(filterLabel(tester, TaskListFilter.completed), '已完成 2');
    });

    testWidgets('点击筛选后只显示对应任务', (tester) async {
      await pump(tester, plans: scheduledPlans());

      await tapFilter(tester, TaskListFilter.unscheduled);
      expect(find.text('算法作业'), findsOneWidget);
      expect(find.text('大物作业'), findsOneWidget);
      expect(find.text('大物预习课'), findsNothing);
      expect(find.text('竞赛报名'), findsNothing);

      await tapFilter(tester, TaskListFilter.scheduled);
      expect(find.text('大物预习课'), findsOneWidget);
      expect(find.text('英语听力'), findsOneWidget);
      expect(find.text('线代刷题'), findsOneWidget);
      expect(find.text('实验报告'), findsOneWidget);
      expect(find.text('算法作业'), findsNothing);

      await tapFilter(tester, TaskListFilter.completed);
      expect(find.text('竞赛报名'), findsOneWidget);
      expect(find.text('体检预约'), findsOneWidget);
      expect(find.text('大物预习课'), findsNothing);
    });

    testWidgets('skipped 与 cancelled 不出现在"全部"里，但数据没有被删除', (tester) async {
      await pump(tester, plans: scheduledPlans());
      expect(find.text('旧草稿'), findsNothing);
      expect(find.text('放弃的想法'), findsNothing);
      // 只是不出现，不是被删掉——取消与跳过的历史必须留着。
      expect(tasks.tasks['x1']!.status, TaskStatus.cancelled);
      expect(tasks.tasks['x2']!.status, TaskStatus.skipped);
    });

    testWidgets('已安排的任务显示真实时间区间，待安排显示预计时长', (tester) async {
      await pump(tester, plans: scheduledPlans());
      expect(find.text('已安排 · 13:00–14:30'), findsOneWidget);
      expect(find.text('待安排 · 预计 50 分钟'), findsOneWidget);
      expect(find.text('已完成 · 实际投入 25 分钟'), findsOneWidget);
    });

    testWidgets('逾期但已补排的任务同时提示"已逾期"与"已安排"', (tester) async {
      await pump(
        tester,
        plans: _Plans(
          _plan([
            // u2 有截止时间已过，这里给它一个未来的补排块。
            _block('u2', _at(21, 0), _at(22, 0)),
          ]),
        ),
      );
      // 这里注入的是 **UTC**，因此 15:59 UTC 就显示成 15:59——种子与断言一起写 UTC，
      // 是为了让这条用例不依赖跑测试那台机器的系统时区。
      // "时区换算真的发生了"由 `task_list_time_format.dart` 的两个格式化函数，
      // 以及 `task_list_filter_test.dart` 里注入格式器的那几条文案用例负责钉住。
      expect(
        find.text('已逾期 · 已安排 · 21:00–22:00 · 截止于 10月6日 15:59'),
        findsOneWidget,
      );
    });
  });

  group('搜索与排序', () {
    testWidgets('搜索与筛选可以组合使用', (tester) async {
      await pump(tester, plans: scheduledPlans());
      await search(tester, '大物');

      // "全部"里两条都匹配。
      expect(find.text('大物作业'), findsOneWidget);
      expect(find.text('大物预习课'), findsOneWidget);

      await tapFilter(tester, TaskListFilter.scheduled);
      expect(find.text('大物预习课'), findsOneWidget);
      expect(find.text('大物作业'), findsNothing);
    });

    testWidgets('搜索不会改变筛选栏的原始数量', (tester) async {
      await pump(tester, plans: scheduledPlans());
      await search(tester, '算法');

      // 列表只剩一条，但筛选栏仍是全量口径（§5 明确要求）。
      expect(find.text('大物预习课'), findsNothing);
      expect(filterLabel(tester, TaskListFilter.all), '全部 8');
      expect(filterLabel(tester, TaskListFilter.unscheduled), '待安排 2');
      expect(filterLabel(tester, TaskListFilter.scheduled), '已安排 4');
      expect(filterLabel(tester, TaskListFilter.completed), '已完成 2');
    });

    testWidgets('排序只作用于当前筛选结果', (tester) async {
      await pump(tester, plans: scheduledPlans());
      double y(String title) => tester.getTopLeft(find.text(title)).dy;

      // 默认是仓储顺序：u1（算法作业）在 u2（大物作业）之前。
      expect(y('算法作业'), lessThan(y('大物作业')));

      // 让两条的预计时长形成明确反转，"按预计时长"才有可断言的方向。
      tasks.tasks['u1'] = _task('u1', '算法作业', estimatedMinutes: 90);
      tasks.tasks['u2'] = _task('u2', '大物作业', estimatedMinutes: 10);
      await tapFilter(tester, TaskListFilter.unscheduled);

      await tester.tap(find.byKey(const Key('task-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按预计时长').last);
      await tester.pumpAndSettle();

      expect(y('大物作业'), lessThan(y('算法作业')));
      // 排序只影响当前筛选：已安排的任务没有因此混进来。
      expect(find.text('大物预习课'), findsNothing);
    });
  });

  group('空状态', () {
    testWidgets('全部为空显示"还没有任务"与新建入口', (tester) async {
      tasks = _Tasks({});
      service = TaskService(
        repository: tasks,
        clock: const _Clock(),
        idGenerator: _Ids(),
      );
      await pump(tester, plans: scheduledPlans());

      expect(find.text('还没有任务'), findsOneWidget);
      expect(find.byKey(const Key('empty-new-task')), findsOneWidget);
    });

    testWidgets('待安排为空显示解释与"生成计划"以外的信息', (tester) async {
      // 只留已安排与已完成：待安排为空。
      tasks = _Tasks({
        's1': _task('s1', '大物预习课'),
        'c1': _task('c1', '竞赛报名', status: TaskStatus.completed),
      });
      service = TaskService(
        repository: tasks,
        clock: const _Clock(),
        idGenerator: _Ids(),
      );
      await pump(
        tester,
        plans: _Plans(_plan([_block('s1', _at(13, 0), _at(14, 0))])),
      );
      await tapFilter(tester, TaskListFilter.unscheduled);

      expect(find.text('没有待安排任务'), findsOneWidget);
      expect(find.text('当前所有进行中的任务都已经进入计划'), findsOneWidget);
    });

    testWidgets('已安排为空显示"生成计划"按钮', (tester) async {
      await pump(
        tester,
        plans: _Plans(null),
        onGeneratePlan: () => generated++,
      );
      await tapFilter(tester, TaskListFilter.scheduled);

      expect(find.text('没有已安排任务'), findsOneWidget);
      await tester.tap(find.byKey(const Key('empty-generate-plan')));
      await tester.pumpAndSettle();
      expect(generated, 1);
    });

    testWidgets('已完成为空显示"还没有已完成任务"', (tester) async {
      tasks = _Tasks({'u1': _task('u1', '算法作业')});
      service = TaskService(
        repository: tasks,
        clock: const _Clock(),
        idGenerator: _Ids(),
      );
      await pump(tester, plans: _Plans(null));
      await tapFilter(tester, TaskListFilter.completed);

      expect(find.text('还没有已完成任务'), findsOneWidget);
    });

    testWidgets('搜索无结果显示关键词与清除入口，而不是"暂无匹配任务"', (tester) async {
      await pump(tester, plans: scheduledPlans());
      await search(tester, '不存在的任务');

      expect(find.text('没有找到"不存在的任务"'), findsOneWidget);
      expect(find.text('暂无匹配任务'), findsNothing);

      await tester.tap(find.byKey(const Key('clear-search')));
      await tester.pumpAndSettle();
      expect(find.text('算法作业'), findsOneWidget);
    });
  });

  group('多选与筛选的交互', () {
    testWidgets('切换筛选会退出多选并清空已选择任务', (tester) async {
      await pump(tester, plans: scheduledPlans());
      await tester.tap(find.byKey(const Key('toggle-batch-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('算法作业'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);

      await tapFilter(tester, TaskListFilter.scheduled);

      // 多选已退出、选择已清空：否则"已选 1"会指向一个当前列表里看不见的任务。
      expect(find.text('已选 1'), findsNothing);
      expect(find.text('多选'), findsOneWidget);
    });

    testWidgets('"已完成"筛选中不显示多选按钮', (tester) async {
      await pump(tester, plans: scheduledPlans());
      await tapFilter(tester, TaskListFilter.completed);
      expect(find.byKey(const Key('toggle-batch-mode')), findsNothing);
    });

    testWidgets('"待安排"与"已安排"都可以正常进入多选', (tester) async {
      await pump(tester, plans: scheduledPlans());
      for (final filter in [
        TaskListFilter.unscheduled,
        TaskListFilter.scheduled,
      ]) {
        await tapFilter(tester, filter);
        expect(
          find.byKey(const Key('toggle-batch-mode')),
          findsOneWidget,
          reason: '${filter.name} 里应当有多选入口',
        );
      }
    });

    testWidgets('"全部"里已完成任务不可勾选', (tester) async {
      await pump(tester, plans: scheduledPlans());
      // 卡片结构在 M2 从 `CheckboxListTile` 改成 `ListTile` + 独立 `Checkbox`
      // （`CheckboxListTile` 会把"查看详情"入口并进整行的语义节点，那是个无障碍缺陷）。
      // 因此这里改读该行的 `Checkbox` 与 `ListTile` 两个控件。
      final closedBox = tester.widget<Checkbox>(
        find.descendant(
          of: find.ancestor(
            of: find.text('竞赛报名'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(Checkbox),
        ),
      );
      expect(closedBox.onChanged, isNull);

      // 未完成的那条照旧可以勾选完成。
      final openBox = tester.widget<Checkbox>(
        find.descendant(
          of: find.ancestor(
            of: find.text('算法作业'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(Checkbox),
        ),
      );
      expect(openBox.onChanged, isNotNull);
    });

    testWidgets('取消完成后任务立即从"已完成"中消失', (tester) async {
      await pump(tester, plans: scheduledPlans());
      await tapFilter(tester, TaskListFilter.completed);
      expect(find.text('竞赛报名'), findsOneWidget);

      final row = tester.widget<ListTile>(
        find.ancestor(of: find.text('竞赛报名'), matching: find.byType(ListTile)),
      );
      // 点整行 = 切换完成（多选关闭时的既有语义），因此用行的 onTap 驱动。
      row.onTap!();
      await tester.pumpAndSettle();

      expect(find.text('竞赛报名'), findsNothing);
      expect(tasks.tasks['c1']!.status, TaskStatus.open);
      // 数量也跟着变了：已完成 2 → 1，待安排 2 → 3。
      expect(filterLabel(tester, TaskListFilter.completed), '已完成 1');
      expect(filterLabel(tester, TaskListFilter.unscheduled), '待安排 3');
    });
  });

  group('计划缺失时的降级', () {
    testWidgets('没有计划仓库时页面仍可使用，未完成任务全部归入待安排', (tester) async {
      await pump(tester);

      expect(find.text('还没有已完成任务'), findsNothing);
      expect(filterLabel(tester, TaskListFilter.all), '全部 8');
      expect(filterLabel(tester, TaskListFilter.unscheduled), '待安排 6');
      expect(filterLabel(tester, TaskListFilter.scheduled), '已安排 0');
      expect(filterLabel(tester, TaskListFilter.completed), '已完成 2');
      // 卡片退回"预计时长"，不会显示一个空白的时间区间。
      expect(find.text('待安排 · 预计 50 分钟'), findsOneWidget);
    });

    testWidgets('计划仓库没有当前计划时同样降级而不是崩溃', (tester) async {
      await pump(tester, plans: _Plans(null));
      expect(filterLabel(tester, TaskListFilter.scheduled), '已安排 0');
      expect(find.text('算法作业'), findsOneWidget);
    });
  });

  group('计划时刻的作用域', () {
    testWidgets('已经结束的时间块不会让任务继续显示为"已安排"', (tester) async {
      // 两个块都在"现在"（12:00）之前结束：任务必须回到"待安排"。
      await pump(
        tester,
        plans: _Plans(
          _plan([
            _block('s1', _at(8, 0), _at(9, 0)),
            _block('s2', _at(10, 0), _at(11, 0)),
          ]),
        ),
      );
      expect(filterLabel(tester, TaskListFilter.scheduled), '已安排 0');
      expect(filterLabel(tester, TaskListFilter.unscheduled), '待安排 6');
      expect(find.text('待安排 · 预计 90 分钟'), findsOneWidget);
    });
  });
}

/// "已安排为空"用例里记录"生成计划"按钮被按下的次数。
