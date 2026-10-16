// 1.8.0（规范 §9.1／§9.3；课程与保护时间管理修复计划 Task 6／Task 8）：
// 「管理保护时间」是一份**能看、能改、能删的系列清单**。
//
// ## 本轮改掉了什么
//
// 页面此前读的是"未来 180 天的**展开结果**"，于是
//
// - 一条"每周二健身"按发生次数出现 26 行（用户以为建了 26 条）；
// - 180 天之外的系列**根本读不到**（用户看不到，于是又建一条重复的）；
// - 只能删、不能改（改名完全没有入口）。
//
// 计划 §3 明确禁止从展开结果反推系列。现在读的是**锚点行**：一行 = 一条系列。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/protected_time_series.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/protected_time_series_repository.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_list_page.dart';

/// 哨兵：区分"没传 `validUntil`"（默认 2026-12-20）与"明确传 `null`"（永不结束）。
final class _Unset {
  const _Unset();
}

void main() {
  final zones = TimeZoneDatabase();

  /// 造一条**系列**（Task 6 之后清单读的就是它，而不是展开结果）。
  ProtectedTimeSeries series({
    String id = 'p1',
    String title = '保护时间',
    int startMinute = 4 * 60,
    int endMinute = 5 * 60,
    Set<int> weekdays = const {},
    int intervalWeeks = 1,
    DateTime? validFrom,
    Object? validUntil = const _Unset(),
  }) => ProtectedTimeSeries(
    anchorId: id,
    title: title,
    timeZoneId: 'Asia/Shanghai',
    startMinute: startMinute,
    endMinute: endMinute,
    weekdays: weekdays,
    intervalWeeks: intervalWeeks,
    validFromLocalDate: validFrom ?? DateTime(2026, 10, 12),
    validUntilLocalDate: validUntil is _Unset
        ? DateTime(2026, 12, 20)
        : validUntil as DateTime?,
    updatedAtUtc: DateTime.utc(2026, 10, 1),
  );

  /// 一条**每周重复**的系列。它在清单里天然只有一行——旧实现读展开结果时，
  /// 同一条规则会按发生次数出现几十行。
  ProtectedTimeSeries weekly() =>
      series(id: 'p1', title: '健身', weekdays: const {DateTime.tuesday});

  Future<void> pump(
    WidgetTester tester, {
    List<ProtectedTimeSeries> items = const [],
    CalendarEventDeletion? deletion,
    void Function(String anchorId)? onEditSeries,
    bool withCalendar = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _NoopCalendar();
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeListPage(
            reader: _Series(items),
            calendar: withCalendar
                ? CalendarService(
                    repository: repository,
                    deletion: deletion ?? repository,
                    clock: const _Clock(),
                    idGenerator: const _Ids(),
                    zones: zones,
                  )
                : null,
            timeZoneId: 'Asia/Shanghai',
            zones: zones,
            onManaged: () {},
            onEditSeries: onEditSeries,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('**列出保护时间**，每一条都能看出是什么时候', (tester) async {
    await pump(
      tester,
      items: [
        series(id: 'p1', title: '午休保护'),
        series(id: 'p2', startMinute: 6 * 60, endMinute: 7 * 60),
      ],
    );

    expect(find.text('管理保护时间'), findsOneWidget);
    expect(find.byKey(const Key('protected-series-p1')), findsOneWidget);
    expect(find.byKey(const Key('protected-series-p2')), findsOneWidget);
    expect(find.textContaining('午休保护'), findsWidgets);
  });

  testWidgets('空清单给出说明与**新建入口**（不留白屏）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('protected-list-empty')), findsOneWidget);
    expect(
      find.textContaining('还没有'),
      findsOneWidget,
      reason: '空状态要说清"这里该有什么"',
    );
    expect(find.byKey(const Key('protected-list-new')), findsOneWidget);
  });

  testWidgets('未注入新建回调时**不给**新建按钮（不给点了没反应的入口）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeListPage(
            reader: _Series(const []),
            timeZoneId: 'Asia/Shanghai',
            zones: zones,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('protected-list-new')), findsNothing);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 6：**一行 = 一条系列**、能改、能删
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**同一个重复锚点只显示一行**（不按发生次数重复）', (tester) async {
    await pump(tester, items: [weekly()]);

    expect(
      find.byKey(const Key('protected-series-p1')),
      findsOneWidget,
      reason:
          '按展开结果列出的后果是这里出现 26 行（真实数据里的样子）。'
          '用户看到的"保护时间"应该是一条规则，不是它未来的每一次发生',
    );
    expect(
      find.byKey(const Key('protected-list-p1')),
      findsNothing,
      reason: '旧的"按发生列行"的 key 不该再存在——两套命名并存会让点击落到另一行上',
    );
  });

  testWidgets('每行有**带标题的「编辑」入口**（能重新打开并改名）', (tester) async {
    String? edited;
    await pump(tester, items: [weekly()], onEditSeries: (id) => edited = id);

    final edit = find.byKey(const Key('protected-edit-p1'));
    expect(edit, findsOneWidget, reason: '管理页必须能重新打开并修改，而不是只能删');

    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(edited, 'p1', reason: '入参必须是锚点 id：按标题找会把两条同名的混成一条');
  });

  testWidgets('未注入编辑回调时**不给**编辑按钮', (tester) async {
    await pump(tester, items: [weekly()]);

    expect(
      find.byKey(const Key('protected-edit-p1')),
      findsNothing,
      reason: '与新建按钮同一条口径：没有去处就不留按钮',
    );
  });

  testWidgets('**能删**：二次确认后调用删除，且不假装成功', (tester) async {
    final deletion = _RecordingDeletion();
    await pump(tester, items: [weekly()], deletion: deletion);

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
    await pump(tester, items: [weekly()], deletion: deletion);

    await tester.tap(find.byKey(const Key('protected-delete-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('protected-delete-cancel')));
    await tester.pumpAndSettle();

    expect(deletion.deleted, isEmpty);
  });

  testWidgets('删除失败时**不假装成功**（如实提示）', (tester) async {
    final deletion = _RecordingDeletion(succeed: false);
    await pump(tester, items: [weekly()], deletion: deletion);

    await tester.tap(find.byKey(const Key('protected-delete-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('protected-delete-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有成功'), findsOneWidget);
    expect(
      find.byKey(const Key('protected-series-p1')),
      findsOneWidget,
      reason: '删除失败就还在，不能把它从列表里抹掉',
    );
  });

  testWidgets('**规则来源的保护时间不出现**（它们没有锚点，要去设置里改）', (tester) async {
    // 读模型的类型保证：它只返回 `CalendarEvent` 锚点，而睡眠／早餐／午餐／晚餐／
    // 固定休息来自 `PlanningRules.protectedTimes`，根本没有锚点行。
    await pump(tester, items: [weekly()]);

    expect(
      find.textContaining('早餐'),
      findsNothing,
      reason:
          '规则生成的保护时间没有 `CalendarEvent` 锚点（计划 §2.3 末段），'
          '因此这份清单里不该出现它们，更不该显示删除',
    );
    expect(find.textContaining('睡眠'), findsNothing);
  });
  // ─────────────────────────────────────────────────────────────────────────────
  // Task 8 Step 2：**「显示已结束」开关，默认关闭**
  //
  // 假期里打开管理页时，上学期那几十条规则会把当前要改的挤到屏幕外；但它们不能
  // 被直接丢掉——那是真实存在的记录，用户有时正是要去删掉它。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**已结束的系列默认不显示**（假期里打开管理页不该满屏旧规则）', (tester) async {
    await pump(
      tester,
      items: [
        series(id: 'active', title: '进行中'),
        series(
          id: 'ended',
          title: '上学期那条',
          validFrom: DateTime(2026, 9, 1),
          // 页面时钟是 2026-10-12；这条在 09-30 就结束了。
          validUntil: DateTime(2026, 9, 30),
        ),
      ],
    );

    expect(find.byKey(const Key('protected-series-active')), findsOneWidget);
    expect(
      find.byKey(const Key('protected-series-ended')),
      findsNothing,
      reason: '默认视图只放当前还在生效的规则',
    );
  });

  testWidgets('**打开开关后已结束的系列出现**（不能被丢掉）', (tester) async {
    await pump(
      tester,
      items: [
        series(id: 'active', title: '进行中'),
        series(
          id: 'ended',
          title: '上学期那条',
          validFrom: DateTime(2026, 9, 1),
          validUntil: DateTime(2026, 9, 30),
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('protected-show-ended')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('protected-series-ended')),
      findsOneWidget,
      reason: '已结束是**筛选**而不是删除：用户可能正要去改或删掉它',
    );
    expect(find.byKey(const Key('protected-series-active')), findsOneWidget);
  });

  testWidgets('**全部已结束时说明"东西去哪了"**，而不是说"还没有"', (tester) async {
    await pump(
      tester,
      items: [
        series(
          id: 'ended',
          title: '上学期那条',
          validFrom: DateTime(2026, 9, 1),
          validUntil: DateTime(2026, 9, 30),
        ),
      ],
    );

    expect(find.byKey(const Key('protected-list-all-ended')), findsOneWidget);
    expect(
      find.byKey(const Key('protected-list-empty')),
      findsNothing,
      reason: '说"还没有自定义保护时间"会让用户以为规则被删了——而它们只是都结束了',
    );
    expect(find.textContaining('显示已结束'), findsWidgets);
  });

  testWidgets('**没有结束日期的重复系列永不算已结束**', (tester) async {
    // 判据必须是规则的结束日期，不是"我看到的那一次已经过去"：一条 08-03 起、
    // 每周一重复且没有结束日期的规则，在 10-12 依然在生效。
    await pump(
      tester,
      items: [
        series(
          id: 'ongoing',
          title: '长期规则',
          weekdays: const {DateTime.monday},
          validFrom: DateTime(2026, 8, 3),
          validUntil: null,
        ),
      ],
    );

    expect(
      find.byKey(const Key('protected-series-ongoing')),
      findsOneWidget,
      reason:
          '拿"已过去的那一次"当判据会把所有重复系列都判成已结束，'
          '于是默认视图里一条都不剩——那比不提供这个开关更糟',
    );
  });

  testWidgets('**一次性事项过了那天算已结束**', (tester) async {
    await pump(
      tester,
      items: [
        series(
          id: 'once',
          title: '一次性的',
          weekdays: const {},
          validFrom: DateTime(2026, 10, 1),
          validUntil: null,
        ),
      ],
    );

    expect(
      find.byKey(const Key('protected-series-once')),
      findsNothing,
      reason: '单次事项没有规则可言，用它自己那一天判断',
    );
  });
}

/// 系列读模型的替身：按"一条锚点一行"给出清单。
final class _Series implements ProtectedTimeSeriesReader {
  const _Series(this.items);
  final List<ProtectedTimeSeries> items;

  @override
  Future<List<ProtectedTimeSeries>> listProtectedSeries() async => items;

  @override
  Future<ProtectedTimeSeries?> findProtectedSeries(String anchorId) async {
    for (final item in items) {
      if (item.anchorId == anchorId) return item;
    }
    return null;
  }
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
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
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

final class _RecordingDeletion implements CalendarEventDeletion {
  _RecordingDeletion({this.succeed = true});
  final bool succeed;
  final List<String> deleted = [];

  @override
  Future<void> deleteEvent(String eventId) async {
    if (!succeed) throw StateError('数据库拒绝删除');
    deleted.add(eventId);
  }

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
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
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
