// 导航可达性：点击通知，以及从任务清单进入详情。
//
// FR-NOTIFY-04 的一半是"平台点击 → 端口"，上一轮已打通；这里验证最后一环：端口交回
// payload 之后应用按 payload 指定的去处导航。同一文件底部另验证任务清单上的详情入口，
// 因为两者指向同一个页，且都需要一个装配完整的外壳。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';

final class _Taps implements NotificationPort {
  void Function(NotificationPayload payload)? handler;

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
  energyLevel: TaskEnergyLevel.high,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  Future<void> pumpApp(WidgetTester tester, {NotificationPort? notifications}) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
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

  testWidgets('未装配通知端口时照常启动', (tester) async {
    await pumpApp(tester);

    // 没有端口就意味着没有点击来源；不应因此启动失败或缺少导航。
    expect(find.text('今日'), findsWidgets);
  });
}
