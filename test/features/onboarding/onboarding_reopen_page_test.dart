// M8「从设置重新打开首次引导」（用户 2026-10-08 反馈后补）。
//
// 用户的原话："我怎么从引导首页点进去啊，这个的前提是我没有装软件吧"——
// 他说得对：引导首页只在**首次启动**那条路径上出现，走完（或跳过）之后
// **设置里没有任何入口**能再看到它。而新手教程一直有"随时重看"入口，
// 这条不一致本身就是缺口。
//
// 本文件钉住三件事：
// ① 这一页真的能用两种文案之一渲染出来；
// ② **进来就会把进度记成"进行中"**——否则从设置进来、中途返回、再重启时，
//    启动不会问"要不要继续"，而他明明正在走；
// ③ **不越界**：只写引导进度那两个键，别的一律不碰。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/onboarding_progress.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_reopen_page.dart';

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

Future<void> _pump(
  WidgetTester tester,
  MemorySettingsRepository settings, {
  List<PlannerTask> tasks = const [],
  VoidCallback? onLearnUi,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: OnboardingReopenPage(
        settings: settings,
        tasks: _Tasks(tasks),
        onCreateTask: () {},
        onImportTimetable: () {},
        onLearnUi: onLearnUi ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('M8 重开页能渲染出三个入口（没有任何任务时写「创建第一个任务」）', (tester) async {
    final settings = MemorySettingsRepository();
    await _pump(tester, settings);

    expect(find.text('创建第一个任务'), findsOneWidget);
    expect(find.text('导入课表'), findsOneWidget);
    expect(find.text('了解主要界面'), findsOneWidget);
  });

  testWidgets('M8 已经用过时写「再创建一个任务」（已完成的任务也算用过）', (tester) async {
    final settings = MemorySettingsRepository();
    await _pump(tester, settings, tasks: [_task('t1', TaskStatus.completed)]);

    expect(
      find.text('再创建一个任务'),
      findsOneWidget,
      reason: '把任务都做完的老用户同样是老用户，不该被告知"第一个任务"',
    );
    expect(find.text('创建第一个任务'), findsNothing);
  });

  testWidgets('M8 进来就把进度记成「进行中」+ guidedHome', (tester) async {
    final settings = MemorySettingsRepository();
    // 前置：用户之前"已跳过"过引导。
    await settings.write(OnboardingProgressStore.stateKey, 'skipped');

    await _pump(tester, settings);

    expect(
      await settings.read(OnboardingProgressStore.stateKey),
      'inProgress',
      reason:
          '用户主动点了"首次引导"，他就确实在走引导。'
          '不写这一步的话，他从中途返回、再重启时启动不会问"要不要继续"',
    );
    expect(
      await settings.read(OnboardingProgressStore.stepKey),
      'guidedHome',
      reason: '停在首页那一步——这样启动分派不会对他弹"继续引导"询问',
    );
  });

  testWidgets('M8 重开页**不显示「跳过引导」**（主动重看不该产生跳过副作用）', (tester) async {
    final settings = MemorySettingsRepository();
    await _pump(tester, settings);

    expect(
      find.text('跳过引导'),
      findsNothing,
      reason: '用户是想重看，给他"跳过"既没意义、又可能把状态改成 skipped',
    );
  });

  testWidgets('M8 重开页只写引导进度两个键，不碰别的设置', (tester) async {
    final settings = MemorySettingsRepository();
    await settings.write('规划规则', '用户改过的值');
    await settings.write('appearance.glass-mode', 'liquid');
    await settings.write('onboarding.schemaVersion', '1');

    await _pump(tester, settings);

    expect(await settings.read('规划规则'), '用户改过的值');
    expect(await settings.read('appearance.glass-mode'), 'liquid');
    expect(
      await settings.read('onboarding.schemaVersion'),
      '1',
      reason: '不该碰关键默认值的确认版本',
    );
  });

  testWidgets('M8「了解主要界面」触发注入的回调', (tester) async {
    var learned = 0;
    await _pump(tester, MemorySettingsRepository(), onLearnUi: () => learned++);

    await tester.tap(find.text('了解主要界面'));
    await tester.pumpAndSettle();
    expect(learned, 1);
  });
}
