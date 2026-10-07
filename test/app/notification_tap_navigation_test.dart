// 导航可达性：点击通知，以及从任务清单进入详情。
//
// FR-NOTIFY-04 的一半是"平台点击 → 端口"，上一轮已打通；这里验证最后一环：端口交回
// payload 之后应用按 payload 指定的去处导航。同一文件底部另验证任务清单上的详情入口，
// 因为两者指向同一个页，且都需要一个装配完整的外壳。
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class _NoDelay implements AppLockDelayPort {
  const _NoDelay();
  @override
  Future<void> wait(Duration duration) async {}
}

final class _Taps implements NotificationPort {
  _Taps({this.launch});
  void Function(NotificationPayload payload)? handler;
  SchedulerPhase? launchPhase;

  /// 模拟"应用是被这条通知拉起来的"；null 表示普通启动。
  final NotificationPayload? launch;

  @override
  Future<NotificationPayload?> launchPayload() async {
    launchPhase = SchedulerBinding.instance.schedulerPhase;
    return launch;
  }

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {
    this.handler = handler;
  }

  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability.available();

  @override
  Future<List<PendingNotification>> pendingNotifications() async => const [];

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {}

  @override
  Future<void> cancel(String id) async {}
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);

  final Map<String, PlannerTask> tasks;

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield tasks.values.where((task) => !task.status.isClosed).toList();
  }
}

PlannerTask _task() => PlannerTask(
  id: 'task-1',
  title: '写方案',
  priority: TaskPriority.high,
  estimatedMinutes: 120,
  remainingMinutes: 90,
  // 远早于任何合理的运行时刻，因此派生状态必然为"已逾期"（R12）。
  dueAtUtc: DateTime.utc(2020, 1, 1),
  energyLevel: TaskEnergyLevel.high,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    NotificationPort? notifications,
  }) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    // 首次教程闸门与首次引导是同一条套路（设置键 + 版本比较）。不喂这一条，
    // 整应用 pump 出来的会是教程页而不是主界面——教程自身的用例在 test/features/tutorial/。
    // ignore: unused_local_variable
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          taskRepository: _Tasks({'task-1': _task()}),
          notifications: notifications,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('点击通知按 payload 指定的去处导航到任务详情', (tester) async {
    final taps = _Taps();
    await pumpApp(tester, notifications: taps);

    // 装配了端口就必须注册处理器，否则点击无从送达。
    expect(taps.handler, isNotNull);

    taps.handler!(
      const NotificationPayload(
        notificationId: 'planner.notify.deadline.task-1',
        kind: NotificationKind.deadline,
        entityId: 'task-1',
        route: '/tasks/task-1',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TaskDetailPage), findsOneWidget);
    expect(find.text('写方案'), findsOneWidget);
  });

  testWidgets('点击指向固定日程的通知回到日历', (tester) async {
    final taps = _Taps();
    await pumpApp(tester, notifications: taps);

    taps.handler!(
      const NotificationPayload(
        notificationId: 'planner.notify.calendar_start.event-1',
        kind: NotificationKind.calendarStart,
        entityId: 'event-1',
        route: '/calendar',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('七日日历'), findsOneWidget);
  });

  testWidgets('任务清单提供进入详情的入口', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(find.text('任务清单'), findsOneWidget);

    await tester.tap(find.byTooltip('查看详情'));
    await tester.pumpAndSettle();

    expect(find.byType(TaskDetailPage), findsOneWidget);
    expect(find.text('写方案'), findsOneWidget);
  });

  testWidgets('任务清单展示派生的已逾期状态', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();

    // 截止时间已过且任务未结束，该状态不落库、由事实派生，此前清单上看不到（R12）。
    expect(find.textContaining('已逾期'), findsOneWidget);
    expect(find.text('任务清单'), findsOneWidget);
  });

  testWidgets('未装配通知端口时照常启动', (tester) async {
    await pumpApp(tester);

    // 没有端口就意味着没有点击来源；不应因此启动失败或缺少导航。
    expect(find.text('今日'), findsWidgets);
  });

  testWidgets('冷启动时按启动详情导航到通知的落点', (tester) async {
    // 应用被点击通知拉起时，平台的点击回调不会到达，只能读启动详情。
    // 此前没有任何代码读它，因此这种情况会停在首屏（R8 ①）。
    await pumpApp(
      tester,
      notifications: _Taps(
        launch: const NotificationPayload(
          notificationId: 'planner.notify.deadline.task-1',
          kind: NotificationKind.deadline,
          entityId: 'task-1',
          route: '/tasks/task-1',
        ),
      ),
    );

    expect(find.byType(TaskDetailPage), findsOneWidget);
    expect(find.text('写方案'), findsOneWidget);
  });

  testWidgets('普通启动（无启动详情）停在首屏，不伪造导航', (tester) async {
    await pumpApp(tester, notifications: _Taps());

    expect(find.byType(TaskDetailPage), findsNothing);
    expect(find.text('今日'), findsWidgets);
  });

  testWidgets('启动详情在首帧结束回调阶段读取，避免原生通知回调重入渲染', (tester) async {
    final taps = _Taps();

    await pumpApp(tester, notifications: taps);

    expect(taps.launchPhase, SchedulerPhase.postFrameCallbacks);
  });

  testWidgets('冷启动导航不绕过应用锁：先解锁，再落在通知指定的去处', (tester) async {
    // 门控包住整个界面，因此导航发生在"看不见"的地方，解锁后才显示目标页。
    // 若把门控放在路由之内，这条通知就会变成应用锁的后门。
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lock = AppLockService(
      store: InMemoryAppLockCredentialStore(),
      delays: const _NoDelay(),
      algorithm: Pbkdf2.hmacSha256(iterations: 1, bits: 256),
    );
    await lock.enable('pw');
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    // 首次教程闸门（同一条套路）：不喂这一条，pump 出来的会是教程页而不是主界面。
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          taskRepository: _Tasks({'task-1': _task()}),
          appLock: lock,
          notifications: _Taps(
            launch: const NotificationPayload(
              notificationId: 'planner.notify.deadline.task-1',
              kind: NotificationKind.deadline,
              entityId: 'task-1',
              route: '/tasks/task-1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 锁着的时候看不到通知的落点。
    expect(find.text('应用锁定'), findsOneWidget);
    expect(find.byType(TaskDetailPage), findsNothing);

    await tester.enterText(find.byKey(const Key('app-lock-password')), 'pw');
    await tester.tap(find.byKey(const Key('app-lock-unlock')));
    await tester.pumpAndSettle();

    expect(find.byType(TaskDetailPage), findsOneWidget);
    expect(find.text('写方案'), findsOneWidget);
  });
}
