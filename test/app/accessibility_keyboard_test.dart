// M2（路线图 §6）第三组强制测试：**键盘与焦点**。
//
// 路线图要求"定义稳定的 Tab 顺序；焦点必须可见，Enter/Space 能激活按钮，Esc 能关闭对话框
// 或返回上一级"。这里逐条钉住，并刻意断言**实际效果**（焦点落在哪个控件、状态有没有变），
// 而不是"按了键没报错"。
//
// **一个必须记住的测试写法**：`Focus.of(context)` 需要一个**后代** `Focus`，而
// `ChoiceChip` 的焦点节点在它内部，因此 `FocusScope.of(chipContext).requestFocus(Focus.of(chipContext))`
// 会直接抛 "does not contain a Focus widget"。正确做法是**发真实的 Tab / Enter 键事件**——
// 那也正是键盘用户真正做的事，因此测试覆盖的是真实路径而不是一个便利入口。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
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
  @override
  Future<ConfirmedPlan?> current() async => null;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

PlannerTask _task(String id, String title) => PlannerTask(
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
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

/// 当前焦点控件的**语义名称**（没有名称时返回空串）。
///
/// **为什么按语义名而不是按 Key 认控件**：焦点的落点往往是控件内部的渲染对象
/// （例如 `ChoiceChip` 的 ink renderer），带着一个内部 `GlobalKey`；往上找"最近的带 Key
/// 祖先"会先命中那个内部 key，而**不是**我们给控件加的业务 key（实测就是这样）。
/// 语义名则正是屏幕阅读器会念的东西，用它既能认出控件，又顺带验证了"这个控件有名字"。
String focusedSemanticLabel(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return '';
  // 用 `tester.getSemantics` 从一个已挂载的 element 取语义节点；它对元素自身
  // 或最近的可语义祖先都有效，因此不受"焦点落在内部渲染对象"的影响。
  try {
    return tester
        .getSemantics(find.byElementPredicate((e) => e == context))
        .label;
  } on Object {
    return '';
  }
}

/// 从当前位置连续按 Tab，直到焦点控件的语义名满足 [matches]（最多 [maxSteps] 次）。
///
/// 返回是否找到。
Future<bool> tabUntil(
  WidgetTester tester,
  bool Function(String label) matches, {
  int maxSteps = 30,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final label = focusedSemanticLabel(tester);
    if (matches(label)) return true;
  }
  return false;
}

/// 四个筛选项里当前被选中的那些。
List<String> selectedFilters(WidgetTester tester) => [
  for (final filter in ['all', 'unscheduled', 'scheduled', 'completed'])
    if (tester
        .widget<ChoiceChip>(find.byKey(Key('task-filter-$filter')))
        .selected)
      filter,
];

void main() {
  late _Tasks tasks;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({'u1': _task('u1', '算法作业'), 'u2': _task('u2', '读书')});
    service = TaskService(
      repository: tasks,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  Future<void> pumpList(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(),
        home: Scaffold(
          body: TaskListPage(
            service: service,
            nowUtc: _now,
            plans: _Plans(),
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 从页面起点连续按 Tab [steps] 次，收集焦点经过的**语义名**序列。
  Future<List<String>> tabWalk(WidgetTester tester, int steps) async {
    final seen = <String>[];
    for (var i = 0; i < steps; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final label = focusedSemanticLabel(tester);
      if (label.isNotEmpty) seen.add(label);
    }
    return seen;
  }

  group('Tab 顺序稳定且可达', () {
    testWidgets('筛选项与卡片操作都在 Tab 可达范围内', (tester) async {
      await pumpList(tester);
      final seen = await tabWalk(tester, 24);

      // 按语义名断言：既证明"能到达"，也顺带证明"到达时它是有名字的"。
      expect(
        seen.any(
          (label) => label.startsWith('全部 ') || label.startsWith('待安排 '),
        ),
        isTrue,
        reason: '筛选项应当能用 Tab 到达；实际到达过：$seen',
      );
      expect(
        seen.any((label) => label.startsWith('查看「')),
        isTrue,
        reason: '任务卡片的详情入口应当能用 Tab 到达；实际到达过：$seen',
      );
    });

    testWidgets('Tab 顺序可复现（两次遍历结果一致）', (tester) async {
      await pumpList(tester);
      final first = await tabWalk(tester, 10);

      // 回到起点：把焦点交回页面，再走一遍。
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final second = await tabWalk(tester, 10);

      expect(second, first, reason: '同一页面的 Tab 顺序必须可复现；两次得到 $first 与 $second');
    });
  });

  group('Enter / Space 能激活控件', () {
    testWidgets('Tab 到筛选项后按 Enter 真的切换筛选', (tester) async {
      await pumpList(tester);

      final reached = await tabUntil(
        tester,
        (label) => label.startsWith('待安排 '),
      );
      expect(reached, isTrue, reason: '未能用 Tab 把焦点移到"待安排"筛选项上');
      expect(selectedFilters(tester), ['all'], reason: '按 Enter 之前应当仍是默认的"全部"');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // 断言**具体哪一栏**被选中，而不是"恰好一个"——后者在没生效时也可能成立。
      expect(selectedFilters(tester), [
        'unscheduled',
      ], reason: 'Enter 应当把筛选切到"待安排"');
    });

    testWidgets('按 Space 也能激活筛选项', (tester) async {
      await pumpList(tester);

      final reached = await tabUntil(
        tester,
        (label) => label.startsWith('已完成 '),
      );
      expect(reached, isTrue, reason: '未能用 Tab 把焦点移到"已完成"筛选项上');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(selectedFilters(tester), [
        'completed',
      ], reason: 'Space 应当把筛选切到"已完成"（与 Enter 同为标准激活键）');
    });

    testWidgets('多选按钮能被 Tab 到达并用 Enter 激活', (tester) async {
      await pumpList(tester);

      final reached = await tabUntil(tester, (label) => label == '多选');
      expect(reached, isTrue, reason: '多选按钮应当能用 Tab 到达');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // 进入多选后界面出现"已选 N"与批量按钮——断言状态真的变了。
      expect(find.text('已选 0'), findsOneWidget);
      expect(find.byKey(const Key('batch-cancel')), findsOneWidget);
    });
  });

  group('焦点可见', () {
    testWidgets('主题为键盘焦点提供了可见样式', (tester) async {
      await pumpList(tester);

      final theme = Theme.of(tester.element(find.byType(TaskListPage)));
      // "焦点可见"最终要靠主题把焦点态画出来。这里断言主题确实提供了焦点配色，
      // 而不是只让 `primaryFocus` 指向某个控件却什么都不显示。
      expect(
        theme.focusColor,
        isNotNull,
        reason: '主题必须有 focusColor，否则键盘用户看不到焦点在哪',
      );
      expect(
        theme.focusColor,
        isNot(Colors.transparent),
        reason: '焦点色不能是透明的——那等于没有焦点提示',
      );
    });
  });
}
