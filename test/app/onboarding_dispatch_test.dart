// M8 操作式引导：**启动分派**（用户 2026-10-07 定案）。
//
// 规格：`docs/superpowers/specs/2026-10-08-m8-guided-onboarding.md` §2.2
//
// 四个状态各自的启动表现：
// | 状态        | 应当看到 |
// | ---         | --- |
// | notStarted  | 直接进引导首页（**不该**先问"要不要继续"） |
// | inProgress  | 「上次的新手引导还没有完成」+ 三颗按钮 |
// | completed   | 主界面（没有引导首页、没有询问框） |
// | skipped     | 主界面，**不再自动弹出** |
//
// **本文件守的是用户那句话**："退出不会冒充完成，跳过不会反复打扰。"
// 这两件事都只在**分派**这一层才能验——状态机的单元测试证明不了"启动时真的这么走"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/onboarding_progress.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_home_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/today/today_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';

final class _Settings implements SettingsRepository {
  _Settings([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// 只回放固定任务列表的仓储：本文件只关心"有没有任务"这个布尔。
final class _Tasks implements TaskRepository {
  _Tasks([this.tasks = const []]);
  final List<PlannerTask> tasks;
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(tasks);
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(tasks);
  @override
  Future<PlannerTask?> getById(String id) async => null;
  @override
  Future<void> save(PlannerTask task) async {}
}

PlannerTask _task(String id, TaskStatus status) => PlannerTask(
  id: id,
  title: '任务 $id',
  estimatedMinutes: 30,
  remainingMinutes: 30,
  priority: TaskPriority.medium,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 30,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 7),
  updatedAtUtc: DateTime.utc(2026, 10, 7),
);

/// 装好"默认值已确认、教程已看过"的基线，只让引导状态成为唯一变量。
Map<String, String> _baseline() => {
  OnboardingPage.schemaVersionKey: '${OnboardingPage.currentSchemaVersion}',
  TutorialPage.seenKey: '${TutorialPage.currentVersion}',
};

Future<void> _pump(
  WidgetTester tester,
  _Settings settings, {
  List<PlannerTask> tasks = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: PlannerApp(
        timeZoneId: 'Asia/Shanghai',
        settingsRepository: settings,
        taskRepository: _Tasks(tasks),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('M8 全新安装：先给关键默认值页（首页排在它之后）', (tester) async {
    // **全新安装的真相是"schema 键还不存在"**——即使进度是 notStarted，
    // 也得先把默认值确认掉：用户的顺序是"先定值，再讲用法"，首页不能越过它。
    //
    // **我第一版夹具给的是 `notStarted` + 已确认的 schema**，那是个自相矛盾的状态；
    // 它当场暴露了一个真缺陷——`notStarted` 会跳过默认值页直奔主界面。
    final settings = _Settings(); // 什么都没有＝全新安装
    await _pump(tester, settings);

    expect(
      find.byType(OnboardingPage),
      findsOneWidget,
      reason: '全新安装必须先看到关键默认值',
    );
    expect(
      find.byType(OnboardingHomePage),
      findsNothing,
      reason: '默认值还没确认时不该先给引导首页',
    );
  });

  testWidgets('M8 默认值已确认 + 进行中：进引导首页（不是直奔主界面）', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
      OnboardingProgressStore.stepKey: 'guidedHome',
    });
    await _pump(tester, settings);

    expect(
      find.byKey(const Key('onboarding-create-task')),
      findsOneWidget,
      reason: '默认值确认之后，引导首页才是用户该看到的下一步',
    );
  });

  testWidgets('M8 notStarted + 默认值已确认：不弹"继续引导"，也不再问默认值', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'notStarted',
    });
    await _pump(tester, settings);

    expect(
      find.byKey(const Key('onboarding-resume')),
      findsNothing,
      reason: 'notStarted 不该出现"继续引导"询问',
    );
    expect(
      find.byType(OnboardingPage),
      findsNothing,
      reason: '默认值已经确认过，不该再问一次',
    );
    expect(
      find.byType(OnboardingHomePage),
      findsNothing,
      reason: '进度是 notStarted 时首页不该出现——它属于"进行中"',
    );
  });

  testWidgets('M8 inProgress：出现「上次的新手引导还没有完成」与三颗按钮', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
    });
    await _pump(tester, settings);

    expect(find.text('上次的新手引导还没有完成'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-resume')), findsOneWidget);
    expect(find.byKey(const Key('onboarding-restart')), findsOneWidget);
    expect(find.byKey(const Key('onboarding-snooze')), findsOneWidget);
  });

  testWidgets('M8 completed：直接进主界面，没有引导首页也没有询问框', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'completed',
    });
    await _pump(tester, settings);

    expect(find.byType(OnboardingHomePage), findsNothing);
    expect(find.byKey(const Key('onboarding-resume')), findsNothing);
    // **"落到主界面"的判据用"引导不再挡路"**，而不是某个具体页面：
    // 初始路由是 `/today`（今日页），断言 `TaskListPage` 会把"主界面"错当成"任务页"。
    expect(
      find.byType(TodayPage),
      findsWidgets,
      reason: '引导不再挡路时应当落到主界面（初始路由是今日页）',
    );
  });

  testWidgets('M8 skipped：不再自动弹出（跳过不会反复打扰）', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'skipped',
    });
    await _pump(tester, settings);

    expect(find.byType(OnboardingHomePage), findsNothing);
    expect(
      find.byKey(const Key('onboarding-resume')),
      findsNothing,
      reason: '跳过之后不该再问"要不要继续"',
    );
  });

  testWidgets('M8「暂时跳过」保持进行中：落库后状态不变、且本次不再显示询问框', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
    });
    await _pump(tester, settings);

    await tester.tap(find.byKey(const Key('onboarding-snooze')));
    await tester.pumpAndSettle();

    expect(
      await settings.read(OnboardingProgressStore.stateKey),
      'inProgress',
      reason: '「暂时跳过」只跳过本次；状态必须仍是进行中，下次启动还会问',
    );
    expect(
      find.byKey(const Key('onboarding-resume')),
      findsNothing,
      reason: '本次已经处理过，屏幕上不该还挂着询问框',
    );
  });

  testWidgets('M8「重新开始」只重置进度：不删已创建的任务', (tester) async {
    // 用户原话："「重新开始」只重置引导进度，不能删除已经创建的真实任务、课程或已确认计划。"
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
      OnboardingProgressStore.stepKey: 'reviewPlan',
    });
    // 放一条**已完成**的任务：既证明"任务还在"，也证明判据不是"未完成任务"。
    await _pump(tester, settings, tasks: [_task('t1', TaskStatus.completed)]);

    await tester.tap(find.byKey(const Key('onboarding-restart')));
    await tester.pumpAndSettle();

    expect(
      await settings.read(OnboardingProgressStore.stateKey),
      'inProgress',
      reason: '重新开始＝回到第一步，仍是进行中',
    );
    expect(
      await settings.read(OnboardingProgressStore.stepKey),
      isNull,
      reason: '重新开始要把"上次走到哪一步"清掉',
    );
    // 任务在另一个仓储里（不是 SettingsRepository），这里能验的是**引导没越界写别的键**：
    // 基线里的两个键必须原样保留。
    expect(
      settings.values[OnboardingPage.schemaVersionKey],
      '${OnboardingPage.currentSchemaVersion}',
      reason: '重新开始不该碰关键默认值的确认版本',
    );
    expect(
      settings.values[TutorialPage.seenKey],
      '${TutorialPage.currentVersion}',
      reason: '重新开始不该把"教程看过了"抹掉',
    );
  });

  testWidgets('M8 首页文案：已有任务时是「再创建一个任务」而不是「创建第一个任务」', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
      OnboardingProgressStore.stepKey: 'guidedHome',
    });
    // **已完成**的任务也算"用过"：它让 hasExistingTasks 为真。
    await _pump(tester, settings, tasks: [_task('t1', TaskStatus.completed)]);

    expect(
      find.text('再创建一个任务'),
      findsOneWidget,
      reason: '只用过、已全部完成的用户同样是老用户，不该被告知"第一个任务"',
    );
    expect(find.text('创建第一个任务'), findsNothing);
  });

  testWidgets('M8 首页文案：完全没有任务时是「创建第一个任务」', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
      OnboardingProgressStore.stepKey: 'guidedHome',
    });
    await _pump(tester, settings);

    expect(find.text('创建第一个任务'), findsOneWidget);
    expect(find.text('再创建一个任务'), findsNothing);
  });

  testWidgets('M8「跳过引导」记成已跳过，并落到主界面', (tester) async {
    final settings = _Settings({
      ..._baseline(),
      OnboardingProgressStore.stateKey: 'inProgress',
      OnboardingProgressStore.stepKey: 'guidedHome',
    });
    await _pump(tester, settings);

    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();

    expect(
      await settings.read(OnboardingProgressStore.stateKey),
      'skipped',
      reason: '点了跳过引导就要记成已跳过，否则下次还会弹',
    );
    expect(find.byType(OnboardingHomePage), findsNothing);
  });
}
