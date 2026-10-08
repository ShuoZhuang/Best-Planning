// M2（路线图 §6）第一组强制测试：主导航、筛选、卡片与表单的**语义标签与选中状态**。
//
// 这些断言来自**实跑语义树**得到的缺陷，不是推测（见
// `docs/superpowers/specs/2026-10-07-m2-accessibility-baseline.md` §3）：
//   A2-1 任务卡片的"查看详情"图标按钮语义标签为空；
//   A2-2 任务页筛选栏每个分段各产生两个同名 button 节点（会被念两遍）；
//   A2-3 未选中的主导航项没有可激活角色。
//
// 为什么必须写这种测试：`IconButton(tooltip: …)` 看起来"已经有名字了"，但**语义树里的 label
// 是空串**——只看源码会以为合格，只有把语义树读出来才知道不合格。
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

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

  @override
  Stream<List<PlannerTask>> watchAllTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Stream<List<PlannerTask>> watchOpenTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;
}

final class _Plans implements PlanRepository {
  _Plans(this.plan);
  final ConfirmedPlan? plan;

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
}) => PlannerTask(
  id: id,
  title: title,
  notes: '',
  priority: TaskPriority.medium,
  estimatedMinutes: 30,
  remainingMinutes: 30,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

/// 递归收集语义树里所有"有内容"的节点（label／value／hint 非空，或有标志位）。
///
/// 用真实语义节点而不是 `matchesSemantics` 的子树匹配：后者在"同一名称出现两次"这种
/// 缺陷上会给出含糊结果，而这组断言要的恰恰是**节点个数**是否唯一。
List<({Set<SemanticsFlag> flags, String label, String value, String hint})>
_collect(WidgetTester tester) {
  // `binding.pipelineOwner` 在 3.10 之后被标记为弃用，但它**仍然是此处唯一能拿到
  // 当前测试树语义根的入口**：改用 `rootPipelineOwner` 之后遍历拿不到节点（实测三条
  // 断言全部变红）。因此这里保留旧入口，并用 ignore 说明原因，而不是为了消警告而
  // 换成一个不工作的 API。
  // ignore: deprecated_member_use
  final owner = tester.binding.pipelineOwner.semanticsOwner;
  final root = owner?.rootSemanticsNode;
  final result =
      <({Set<SemanticsFlag> flags, String label, String value, String hint})>[];
  if (root == null) return result;

  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    // 新版 Flutter 用 `flagsCollection` 表达标志，且**不是所有标志都是 bool**：
    // `isSelected`／`isEnabled` 是 `Tristate`（`none` 表示"节点没声明这一项"，
    // 不等于 false），因此三态的要跟 `Tristate.isTrue` 比，其余的直接用 bool。
    final flags = data.flagsCollection;
    final isButton = flags.isButton;
    final isSelected = flags.isSelected == Tristate.isTrue;
    final isTextField = flags.isTextField;
    final isEnabled = flags.isEnabled == Tristate.isTrue;
    if (data.label.isNotEmpty ||
        data.value.isNotEmpty ||
        data.hint.isNotEmpty ||
        isButton ||
        isTextField ||
        isSelected) {
      result.add((
        flags: {
          if (isButton) SemanticsFlag.isButton,
          if (isSelected) SemanticsFlag.isSelected,
          if (isTextField) SemanticsFlag.isTextField,
          if (isEnabled) SemanticsFlag.isEnabled,
        },
        label: data.label,
        value: data.value,
        hint: data.hint,
      ));
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return result;
}

void main() {
  late _Tasks tasks;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({
      'u1': _task('u1', '算法作业'),
      'c1': _task('c1', '竞赛报名', status: TaskStatus.completed),
    });
    service = TaskService(
      repository: tasks,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  Future<void> pumpTaskList(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(),
        home: Scaffold(
          body: TaskListPage(
            service: service,
            nowUtc: _now,
            plans: _Plans(
              ConfirmedPlan(
                id: 'plan-1',
                inputHash: 'hash',
                algorithmVersion: 'v1',
                blocks: [
                  PlannedBlock(
                    id: 'b1',
                    taskId: 'u1',
                    range: TimeRange(
                      startUtc: DateTime.utc(2026, 10, 7, 13),
                      endUtc: DateTime.utc(2026, 10, 7, 14),
                    ),
                  ),
                ],
              ),
            ),
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('A2-1 任务卡片的操作必须有可读名称', () {
    testWidgets('详情入口是一个带任务名的可激活控件', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTaskList(tester);

      final nodes = _collect(tester);
      final detailButtons = nodes
          .where((node) => node.flags.contains(SemanticsFlag.isButton))
          .where((node) => node.label.contains('详情'))
          .toList();

      // 名称必须**点名任务**，否则一屏两张卡片会有两个一模一样的"查看详情"，
      // 屏幕阅读器用户无法区分要在哪一个上面按回车。
      expect(
        detailButtons.map((node) => node.label),
        containsAll(<String>['查看「算法作业」详情', '查看「竞赛报名」详情']),
        reason: '详情入口应当是可激活控件，且名称里带上任务标题',
      );

      handle.dispose();
    });

    testWidgets('语义树里没有"没有名称的按钮"', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTaskList(tester);

      // 兜底断言：把"有按钮角色却没有名称"这个形状整体禁掉。它比逐条点名更能防回归——
      // 以后任何人新加一个只有图标、只给 tooltip 的按钮，这里都会红。
      final unnamedButtons = _collect(tester)
          .where((node) => node.flags.contains(SemanticsFlag.isButton))
          .where((node) => node.label.trim().isEmpty)
          .toList();

      expect(
        unnamedButtons.map((node) => node.hint),
        isEmpty,
        reason:
            '语义树里有 ${unnamedButtons.length} 个没有名称的按钮——屏幕阅读器只会读"按钮"。'
            '`tooltip` 不会自动成为语义 label。',
      );

      handle.dispose();
    });
  });

  group('A2-2 每个筛选项在语义树里只出现一次', () {
    testWidgets('四个筛选项各只有一个节点，且名称带数量', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTaskList(tester);

      final nodes = _collect(tester);
      for (final label in ['全部 2', '待安排 0', '已安排 1', '已完成 1']) {
        final matches = nodes.where((node) => node.label == label).toList();
        expect(
          matches,
          hasLength(1),
          reason:
              '筛选项"$label"在语义树里出现 ${matches.length} 次；'
              '重复的节点会被屏幕阅读器念两遍，也会让自动化工具里出现重复控件。',
        );
      }

      handle.dispose();
    });

    testWidgets('当前筛选项带选中状态', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTaskList(tester);

      final selected = _collect(tester)
          .where((node) => node.flags.contains(SemanticsFlag.isSelected))
          .toList();
      expect(
        selected.map((node) => node.label),
        contains('全部 2'),
        reason: '默认选中"全部"，它必须带选中态，否则屏幕阅读器读不出"当前在哪一栏"',
      );

      handle.dispose();
    });
  });

  group('A2-3（更正后）主导航的语义契约', () {
    // **这条断言的性质与 A2-1／A2-2 不同**：它守的是"本来就是对的行为不要被改坏"。
    // 第一版规格曾把"未选中项没有 isButton"当成缺陷，复核后撤回——Flutter 给导航项用的
    // 是**正确的 `tab` 角色**（带组内位置"Tab n of m"与选中态），而已有的
    // `app_smoke_test.dart` 一直用 `find.descendant(of: NavigationRail, …)` 点导航项，
    // 因此这里刻意**不断言 widget 类型**，避免把"将来换个容器"变成红。
    testWidgets('每个导航项都有名称与组内位置，选中项带选中态', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: PlannerTheme.dark(),
          home: Scaffold(
            // 不用 `const`：`destinations` 里含 `Icon`／`Text`，整体 const 化会让
            // `NavigationRail` 内部的 `destinations.length` 落进常量求值而报错。
            body: NavigationRail(
              extended: true,
              selectedIndex: 0,
              onDestinationSelected: (int _) {},
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.today_outlined),
                  label: Text('今日'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.checklist_outlined),
                  label: Text('任务'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nodes = _collect(tester);
      // 名称必须能区分两项，并且**两项形状一致**（这正是 A2-3 撤回的依据）。
      final today = nodes.where((node) => node.label.startsWith('今日')).toList();
      final tasks = nodes.where((node) => node.label.startsWith('任务')).toList();
      expect(today, hasLength(1), reason: '"今日"应当恰好一个语义节点');
      expect(tasks, hasLength(1), reason: '"任务"应当恰好一个语义节点');

      // 选中态只属于当前项。
      expect(today.single.flags, contains(SemanticsFlag.isSelected));
      expect(tasks.single.flags, isNot(contains(SemanticsFlag.isSelected)));

      handle.dispose();
    });
  });
}
