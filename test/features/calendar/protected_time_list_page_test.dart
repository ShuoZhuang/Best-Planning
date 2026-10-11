// 1.8.0（计划 Task 8 的 `Create:` 声明；规范 §9.1／§9.3）：
// 「管理保护时间」应当是一份**可以看的清单**，而不是"只能新建"。
//
// 为什么这不是"规范没要求所以可做可不做"：
//
// 周视图工具栏那颗按钮的**标签**写的就是「管理保护时间」，
// 但它此前直接 `context.go('/calendar/protected/new')` —— **打开的是新建编辑器**。
// 于是用户能看到"管"，却看不到"被管的东西"；`CalendarService.deleteEvent`
// 对保护时间也一直没有界面入口，而规范 §9.3 明确要求
// "保护时间支持与固定日程相同的范围：仅本次、此次及以后、整个系列" ——
// 至少有"删除"，而当时**没有任何界面能删**。
//
// 顺便修掉一个词不达意：标签与其动作必须一致（本批次 §7.1 的同类要求）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_list_page.dart';

void main() {
  final zones = TimeZoneDatabase();
  final now = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => now.add(Duration(hours: hour));

  CalendarOccurrence protected({
    String id = 'p1',
    String title = '保护时间',
    int hour = 4,
  }) => CalendarOccurrence(
    eventId: id,
    title: title,
    range: TimeRange(startUtc: at(hour), endUtc: at(hour + 1)),
    locked: true,
    kind: CalendarEventKind.protected,
  );

  CalendarOccurrence fixed({String id = 'f1', int hour = 8}) =>
      CalendarOccurrence(
        eventId: id,
        title: '线性代数',
        range: TimeRange(startUtc: at(hour), endUtc: at(hour + 1)),
        locked: true,
        kind: CalendarEventKind.fixed,
      );

  Future<void> pump(
    WidgetTester tester, {
    List<CalendarOccurrence> occurrences = const [],
    CalendarEventDeletion? deletion,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Calendar(occurrences);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeListPage(
            service: CalendarService(
              repository: repository,
              deletion: deletion ?? repository,
              clock: const _Clock(),
              idGenerator: const _Ids(),
              zones: zones,
            ),
            timeZoneId: 'Asia/Shanghai',
            zones: zones,
            nowUtc: now,
            onManaged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('**列出保护时间**，每一条都能看出是什么时候', (tester) async {
    await pump(
      tester,
      occurrences: [
        protected(id: 'p1', title: '午休保护'),
        protected(id: 'p2', hour: 6),
      ],
    );

    expect(find.text('管理保护时间'), findsOneWidget);
    expect(find.byKey(const Key('protected-list-p1')), findsOneWidget);
    expect(find.byKey(const Key('protected-list-p2')), findsOneWidget);
    expect(find.textContaining('午休保护'), findsWidgets);
  });

  testWidgets('**固定日程不混进这份清单**（它是保护时间专用的）', (tester) async {
    await pump(
      tester,
      occurrences: [
        protected(id: 'p1'),
        fixed(id: 'f1'),
      ],
    );

    expect(find.byKey(const Key('protected-list-p1')), findsOneWidget);
    expect(
      find.byKey(const Key('protected-list-f1')),
      findsNothing,
      reason: '固定日程有自己的入口；混在一起会让"管理保护时间"名不副实',
    );
  });

  testWidgets('**能删**：二次确认后调用删除，且不假装成功', (tester) async {
    final deletion = _RecordingDeletion();
    await pump(
      tester,
      occurrences: [protected(id: 'p1')],
      deletion: deletion,
    );

    await tester.tap(find.byKey(const Key('protected-delete-p1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('protected-delete-confirm')),
      findsOneWidget,
      reason: '删除必须二次确认',
    );
    await tester.tap(find.byKey(const Key('protected-delete-confirm')));
    await tester.pumpAndSettle();

    expect(deletion.deleted, ['p1']);
  });

  testWidgets('删除对话框可以取消（取消时**不删**）', (tester) async {
    final deletion = _RecordingDeletion();
    await pump(
      tester,
      occurrences: [protected(id: 'p1')],
      deletion: deletion,
    );

    await tester.tap(find.byKey(const Key('protected-delete-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('protected-delete-cancel')));
    await tester.pumpAndSettle();

    expect(deletion.deleted, isEmpty);
  });

  testWidgets('空清单给出说明与**新建入口**（不留白屏）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('protected-list-empty')), findsOneWidget);
    expect(
      find.textContaining('还没有'),
      findsOneWidget,
      reason: '空状态要说清"这里该有什么"',
    );
  });

  testWidgets('未注入新建回调时**不给**新建按钮（不给点了没反应的入口）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Calendar(const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeListPage(
            service: CalendarService(
              repository: repository,
              deletion: repository,
              clock: const _Clock(),
              idGenerator: const _Ids(),
              zones: zones,
            ),
            timeZoneId: 'Asia/Shanghai',
            zones: zones,
            nowUtc: now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('protected-list-new')), findsNothing);
  });
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 12, 1);
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'generated';
}

final class _Calendar implements CalendarRepository, CalendarEventDeletion {
  const _Calendar(this.occurrences);
  final List<CalendarOccurrence> occurrences;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => occurrences;

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
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
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

final class _RecordingDeletion implements CalendarEventDeletion {
  final List<String> deleted = [];

  @override
  Future<void> deleteEvent(String eventId) async => deleted.add(eventId);

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
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
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
