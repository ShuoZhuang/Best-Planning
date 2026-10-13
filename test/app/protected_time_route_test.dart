// 1.8.0（规范 §9.1／§9.3）：保护时间的**路由接线**。
//
// 这条用例存在的理由很具体：周视图工具栏那颗按钮的标签是「管理保护时间」，
// 而它此前直接 `context.go('/calendar/protected/new')` —— **打开的是新建编辑器**，
// 不是清单。标签与动作不一致（本批次 §7.1 对"新建"入口纠过一次同类问题）。
//
// 页面本身由 `protected_time_list_page_test.dart` 验（6 条）；
// 本文件验的是**路由与入口**：`/calendar/protected` 能到清单页，
// 而新建仍然走 `/calendar/protected/new`。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/models/protected_time_series.dart';
import 'package:personal_planner/domain/repositories/protected_time_series_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

final _now = DateTime.utc(2026, 10, 12, 1);

void main() {
  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    String initialLocation = '/calendar/protected',
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final calendar = _NoopCalendar();
    final router = createPlannerRouter(
      taskService: TaskService(
        repository: _EmptyTasks(),
        clock: const _FixedClock(),
        idGenerator: _Ids(),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: _now,
      nowUtc: _now,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      protectedTimeSeries: _NoSeries(),
      calendarService: CalendarService(
        repository: calendar,
        deletion: calendar,
        clock: const _FixedClock(),
        idGenerator: _Ids(),
        zones: TimeZoneDatabase(),
      ),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go(initialLocation);
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('**`/calendar/protected` 到的是清单页**，不是新建编辑器', (tester) async {
    await pumpRouter(tester);

    expect(
      find.byKey(const Key('protected-list-title')),
      findsOneWidget,
      reason:
          '「管理保护时间」必须打开清单。此前它直接开到新建编辑器，'
          '于是用户看得到"管"，看不到"被管的东西"',
    );
    expect(
      find.byKey(const Key('protected-list-empty')),
      findsOneWidget,
      reason: '夹具里没有保护时间 ⇒ 空状态；空状态要说清这里该有什么',
    );
  });

  testWidgets('**`/calendar/protected/new` 仍然是新建编辑器**（清单页的入口指向它）', (
    tester,
  ) async {
    await pumpRouter(tester, initialLocation: '/calendar/protected/new');

    expect(
      find.byKey(const Key('protected-title')),
      findsOneWidget,
      reason: '新建走原来的编辑器，没有被清单页取代',
    );
    expect(
      find.text('新建保护时间'),
      findsWidgets,
      reason: 'create 模式要有自己的标题，不能与"编辑「标题」"混用同一个文案',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 1（课程与保护时间管理修复计划 §2.3／Task 8 Step 4）：**编辑深链与返回路径**
  //
  // 管理页一行一个系列，点进去编辑的路由是
  // `/calendar/protected/<anchorId>/edit`。保存与取消都回**管理页**。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**`/calendar/protected/<anchorId>/edit` 到的是编辑模式**', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      initialLocation: '/calendar/protected/anchor-1/edit',
    );

    expect(
      find.byKey(const Key('protected-title')),
      findsOneWidget,
      reason: '编辑模式与新建共用同一个表单',
    );
    expect(
      find.textContaining('编辑'),
      findsWidgets,
      reason:
          '计划 Task 8 Step 1：edit 模式用「编辑「标题」」作为标题。'
          '与 create 模式共用一个标题会让用户分不清自己在新建还是在改',
    );
  });

  testWidgets('未装配日历服务时保护时间深链给出装配说明', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = createPlannerRouter(
      taskService: TaskService(
        repository: _EmptyTasks(),
        clock: const _FixedClock(),
        idGenerator: _Ids(),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: _now,
      nowUtc: _now,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/calendar/protected/anchor-1/edit');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('未装配'),
      findsOneWidget,
      reason: '与既有的"未装配即说明"同一条口径，不留白屏也不假装能编辑',
    );
  });
}

/// 保护时间系列读模型的替身：路由测试只关心"到了哪一页"。
///
/// **它仍要能返回一条系列**（不是永远 `null`）：编辑路由到的是
/// `ProtectedTimeSeriesEditorPage`，而它在"读不到系列"时显示的是
/// `protected-series-missing` 那一屏——永远返回 `null` 会让"编辑模式渲染出表单"
/// 这条断言失败，而失败的原因与路由本身无关。
final class _NoSeries implements ProtectedTimeSeriesReader {
  @override
  Future<List<ProtectedTimeSeries>> listProtectedSeries() async => const [];

  @override
  Future<ProtectedTimeSeries?> findProtectedSeries(String anchorId) async =>
      ProtectedTimeSeries(
        anchorId: anchorId,
        title: '午休',
        timeZoneId: 'Asia/Shanghai',
        startMinute: 14 * 60,
        endMinute: 15 * 60,
        weekdays: const {DateTime.tuesday},
        validFromLocalDate: DateTime(2026, 10, 6),
        validUntilLocalDate: DateTime(2026, 12, 20),
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      );
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'id-${++_count}';
}

final class _EmptyTasks implements TaskRepository {
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);

  @override
  Future<PlannerTask?> getById(String id) async => null;

  @override
  Future<void> save(PlannerTask task) async {}
}

final class _NoopCalendar implements CalendarRepository, CalendarEventDeletion {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}

  @override
  Future<void> deleteEvent(String eventId) async {}

  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventEditDraft event,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> setEventArea({
    required String eventId,
    required String? areaId,
    required DateTime updatedAtUtc,
  }) async {}
}
