import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/features/execution/execution_bar.dart';
import 'package:personal_planner/features/execution/execution_card.dart';
import 'package:personal_planner/features/execution/execution_controller.dart';

import '../../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late ExecutionController controller;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    controller = ExecutionController(
      service: harness.service,
      tasks: harness.taskRepository,
      notifications: const AlwaysEnabledNotifications(),
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await controller.refresh();
  });

  tearDown(() async {
    controller.dispose();
    await harness.close();
  });

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => ExecutionCard(
              controller: controller,
              taskId: 'task-1',
              title: '蓝桥杯竞赛课',
              planStartUtc: harness.clock.nowUtc().subtract(
                const Duration(minutes: 20),
              ),
              planEndUtc: harness.clock.nowUtc().add(
                const Duration(minutes: 25),
              ),
              formatTime: (value) => '${value.hour}:${value.minute}',
              nowUtc: () => harness.clock.nowUtc(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('执行卡显示原计划与尚未记录开始，并可一键开始', (tester) async {
    await pumpCard(tester);
    expect(find.text('蓝桥杯竞赛课'), findsOneWidget);
    expect(find.textContaining('尚未记录开始'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('先做5分钟'), findsOneWidget);

    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();

    final active = await harness.service.activeSession();
    expect(active, isNotNull);
    expect(active!.taskId, 'task-1');
    expect(active.mode, ExecutionMode.planned);
  });

  testWidgets('先做5分钟把目标时长交给服务，不预先扣分钟', (tester) async {
    await pumpCard(tester);
    await tester.tap(find.text('先做5分钟'));
    await tester.pumpAndSettle();

    final active = await harness.service.activeSession();
    expect(active, isNotNull);
    expect(await harness.taskRemainingMinutes('task-1'), 45);
    final events = await harness.database
        .customSelect(
          "SELECT payload_json FROM execution_events WHERE event_type = 'started'",
        )
        .get();
    expect(events, isNotEmpty);
    expect(events.first.read<String>('payload_json'), contains('300000000'));
  });

  testWidgets('没有执行实例时提醒按钮不可用，不假装已设置', (tester) async {
    await pumpCard(tester);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '10分钟后提醒'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('达到5分钟只提示一次，计时继续运行', (tester) async {
    final started = await controller.startTask(
      'task-1',
      targetDurationMicros: 5 * 60 * 1000000,
    );
    expect(started, isTrue);
    harness.clock.advance(const Duration(minutes: 5));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExecutionBar(
            controller: controller,
            title: '蓝桥杯竞赛课',
            nowUtc: () => harness.clock.nowUtc(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('已做5分钟，可以继续或休息'), findsOneWidget);
    final active = await harness.service.activeSession();
    expect(active!.state, ExecutionSessionState.running);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已做5分钟，可以继续或休息'), findsOneWidget);
  });

  test('运行中到达硬边界自动暂停并保留已做时长', () async {
    final availability = BoundaryAvailability(DateTime.utc(2026, 10, 19, 5, 5));
    final bounded = await ExecutionTestHarness.create(
      now: DateTime.utc(2026, 10, 19, 5),
      availability: availability,
    );
    addTearDown(bounded.close);
    final boundedController = ExecutionController(
      service: bounded.service,
      tasks: bounded.taskRepository,
      notifications: const AlwaysEnabledNotifications(),
      clock: bounded.clock,
      idGenerator: bounded.ids,
      availability: availability,
    );
    addTearDown(boundedController.dispose);
    await boundedController.refresh();
    expect(await boundedController.startTask('task-1'), isTrue);

    bounded.clock.advance(const Duration(minutes: 5));
    expect(await boundedController.maybePauseAtHardBoundary(), isTrue);
    final active = await bounded.service.activeSession();
    expect(active!.state, ExecutionSessionState.paused);
    expect(await bounded.taskRemainingMinutes('task-1'), 40);
  });

  testWidgets('只剩3分钟时先说明，明确选择后才开始短会话', (tester) async {
    final limited = await ExecutionTestHarness.create(
      availability: const LimitedAvailability(Duration(minutes: 3)),
    );
    addTearDown(limited.close);
    final shortController = ExecutionController(
      service: limited.service,
      tasks: limited.taskRepository,
      notifications: const AlwaysEnabledNotifications(),
      clock: limited.clock,
      idGenerator: limited.ids,
    );
    addTearDown(shortController.dispose);
    await shortController.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: shortController,
            builder: (context, _) => ExecutionCard(
              controller: shortController,
              taskId: 'task-1',
              title: '蓝桥杯竞赛课',
              planStartUtc: limited.clock.nowUtc().subtract(
                const Duration(minutes: 20),
              ),
              planEndUtc: limited.clock.nowUtc().add(
                const Duration(minutes: 25),
              ),
              formatTime: (value) => '${value.hour}:${value.minute}',
              nowUtc: () => limited.clock.nowUtc(),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('先做5分钟'));
    await tester.pumpAndSettle();

    expect(find.textContaining('最多还能做 3 分钟'), findsWidgets);
    expect(await limited.service.activeSession(), isNull);

    await tester.tap(find.text('做这几分钟'));
    await tester.pumpAndSettle();
    final active = await limited.service.activeSession();
    expect(active, isNotNull);
    expect(active!.state, ExecutionSessionState.running);
  });

  testWidgets('200%文字缩放与窄窗下执行卡仍可操作', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpCard(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('先做5分钟'), findsOneWidget);
  });

  testWidgets('运行中另一项任务到点只显示冲突，不替换当前会话', (tester) async {
    expect(await controller.startTask('task-1'), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExecutionBar(
            controller: controller,
            title: '蓝桥杯竞赛课',
            conflictTitle: '高数作业',
            nowUtc: () => harness.clock.nowUtc(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('「高数作业」已到开始时间'), findsOneWidget);
    expect(find.textContaining('不会被替换'), findsOneWidget);
    final active = await harness.service.activeSession();
    expect(active!.taskId, 'task-1');
  });
}
