// 1.8.0（规范 §9.3）：「保护时间支持与固定日程相同的范围：仅本次、此次及以后、整个系列。
// **删除或改写后触发重排原因记录和通知重新对账。**」
//
// `calendar_replan_events_test.dart` 把固定日程的六条写入路径都钉住了，但**一条保护时间的
// 用例也没有**——而 §9.3 特意点名了保护时间。本文件补这一段。
//
// 为什么"原因文案"值得逐字断言：它 **直接显示给用户**（统计页的"重排原因"）。
// 保护时间不是固定日程，若写成"固定日程创建"，用户会在统计里看到一件他没做过的事。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

void main() {
  late List<ScheduleInputChange> changes;
  late _MemoryCalendar calendar;

  setUp(() {
    changes = [];
    calendar = _MemoryCalendar();
  });

  CalendarService service({CalendarEventDeletion? deletion}) => CalendarService(
    repository: calendar,
    recurringRepository: calendar,
    deletion: deletion ?? calendar,
    clock: const _Clock(),
    idGenerator: _Ids(),
    zones: TimeZoneDatabase(),
    onScheduleInputChanged: changes.add,
  );

  EventDraft protectedDraft({Set<int> weekdays = const {}}) => EventDraft(
    title: '保护时间',
    startAtUtc: DateTime.utc(2026, 10, 6, 4),
    endAtUtc: DateTime.utc(2026, 10, 6, 5),
    timeZoneId: 'Asia/Shanghai',
    kind: CalendarEventKind.protected,
    recurrenceWeekdays: weekdays,
    recurrenceIntervalWeeks: 1,
  );

  test('新建保护时间记一条原因，且文案说的是**保护时间**而不是固定日程', () async {
    final result = await service().save(protectedDraft());

    expect(result.isSuccess, isTrue, reason: '前置条件：这一条草稿必须能保存成功');
    expect(changes, hasLength(1), reason: '规范 §9.3：保护时间的写入要触发重排原因记录');
    expect(
      changes.single.label,
      contains('保护时间'),
      reason:
          '原因是给用户看的。保存的是保护时间却写"固定日程创建"，'
          '用户会在统计页看到一件自己没做过的事',
    );
    expect(
      changes.single.label,
      isNot(contains('固定日程')),
      reason: '保护时间不是固定日程（§9.1：它不作为"固定日程投入"统计）',
    );
  });

  test('按周重复的保护时间也只记一条原因（一次用户动作＝一条原因）', () async {
    await service().save(protectedDraft(weekdays: const {DateTime.tuesday}));

    expect(changes, hasLength(1));
    expect(changes.single.label, contains('保护时间'));
  });

  test('删除保护时间记一条原因，文案说的是保护时间', () async {
    final saveResult = await service().save(protectedDraft());
    expect(saveResult.isSuccess, isTrue);
    changes.clear();

    final saved = calendar.saved.single;
    await service().deleteEvent(saved.id);

    expect(changes, hasLength(1), reason: '规范 §9.3：删除后同样触发重排原因记录');
    expect(changes.single.label, contains('保护时间'));
    expect(changes.single.label, isNot(contains('固定日程')));
  });

  test('保存失败时不记原因（改不动就没有重排）', () async {
    final result = await service().save(
      EventDraft(
        title: '',
        startAtUtc: DateTime.utc(2026, 10, 6, 4),
        endAtUtc: DateTime.utc(2026, 10, 6, 5),
        timeZoneId: 'Asia/Shanghai',
        kind: CalendarEventKind.protected,
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(changes, isEmpty, reason: '与固定日程侧同口径：只有成功的写入才留下原因');
  });

  // ---- 其余五条写入路径（§9.3 说保护时间支持"与固定日程相同的范围"）---------
  //
  // 上一轮我只修了 `save` 与 `deleteEvent` 两处，而**一共六条路径**都写死了"固定日程"。
  // 这一组用例把剩下的五条逐条钉住 —— "只修了最显眼的那一条"是这类缺陷最常见的残余形态。

  /// 先把一条保护时间存进去，再执行 [action]，返回它记下的原因。
  Future<String> reasonFor(
    Future<void> Function(CalendarService service, CalendarEvent event) action,
  ) async {
    final svc = service();
    final saveResult = await svc.save(protectedDraft());
    expect(saveResult.isSuccess, isTrue, reason: '前置条件：保护时间必须能存进去');
    changes.clear();
    await action(svc, calendar.saved.single);
    expect(changes, hasLength(1), reason: '一次用户动作＝一条原因');
    return changes.single.label;
  }

  test('改写整个系列：文案说的是保护时间', () async {
    final label = await reasonFor(
      (svc, event) => svc.updateEvent(
        target: CalendarEditTarget(
          anchorId: event.id,
          scope: EventEditScope.entireSeries,
        ),
        patch: CalendarEventPatch(
          title: '保护时间',
          startAtUtc: DateTime.utc(2026, 10, 6, 5),
          endAtUtc: DateTime.utc(2026, 10, 6, 6),
        ),
      ),
    );

    expect(label, contains('保护时间'));
    expect(label, isNot(contains('固定日程')));
  });

  test('改写此次及以后：文案说的是保护时间', () async {
    final label = await reasonFor(
      (svc, event) => svc.updateEvent(
        target: CalendarEditTarget(
          anchorId: event.id,
          scope: EventEditScope.followingOccurrences,
          occurrenceStartUtc: DateTime.utc(2026, 10, 6, 4),
        ),
        patch: CalendarEventPatch(
          title: '保护时间',
          startAtUtc: DateTime.utc(2026, 10, 6, 5),
          endAtUtc: DateTime.utc(2026, 10, 6, 6),
        ),
      ),
    );

    expect(label, contains('保护时间'));
    expect(label, isNot(contains('固定日程')));
  });

  test('删除此次及以后：文案说的是保护时间', () async {
    final label = await reasonFor(
      (svc, event) => svc.deleteFollowingOccurrences(
        anchorId: event.id,
        occurrenceStartUtc: DateTime.utc(2026, 10, 6, 4),
      ),
    );

    expect(label, contains('保护时间'));
    expect(label, isNot(contains('固定日程')));
  });

  test('改写单次：文案说的是保护时间', () async {
    final label = await reasonFor(
      (svc, event) => svc.updateEvent(
        target: CalendarEditTarget(
          anchorId: event.id,
          scope: EventEditScope.singleOccurrence,
          occurrenceStartUtc: DateTime.utc(2026, 10, 6, 4),
        ),
        patch: CalendarEventPatch(
          title: '保护时间',
          startAtUtc: DateTime.utc(2026, 10, 6, 5),
          endAtUtc: DateTime.utc(2026, 10, 6, 6),
        ),
      ),
    );

    expect(label, contains('保护时间'));
    expect(label, isNot(contains('固定日程')));
  });

  test('删除单次：文案说的是保护时间', () async {
    final label = await reasonFor(
      (svc, event) => svc.deleteOccurrence(
        anchorId: event.id,
        occurrenceStartUtc: DateTime.utc(2026, 10, 6, 4),
        title: '保护时间',
      ),
    );

    expect(label, contains('保护时间'));
    expect(label, isNot(contains('固定日程')));
  });
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 9);
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'id-${++_count}';
}

final class _MemoryCalendar
    implements
        CalendarRepository,
        RecurringCalendarRepository,
        CalendarEventDeletion {
  final List<CalendarEvent> saved = [];

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [
    // 替身也要**如实回报它存了什么**：`deleteEvent` 靠读回这条事件来判断该写
    // "保护时间删除"还是"固定日程删除"。若这里永远返回空表，那条判断就永远走不到，
    // 用例看到的会是"删除路径没实现"，而实际是**替身没实现读取**。
    for (final event in saved)
      CalendarOccurrence(
        eventId: event.id,
        title: event.title,
        range: TimeRange(startUtc: event.startAtUtc, endUtc: event.endAtUtc),
        locked: event.locked,
        kind: event.kind,
      ),
  ];

  @override
  Future<void> save(CalendarEvent event) async => saved.add(event);

  @override
  Future<void> saveRecurring(CalendarEvent event, RecurrenceRule rule) async =>
      saved.add(event);

  @override
  Future<void> deleteEvent(String eventId) async =>
      saved.removeWhere((event) => event.id == eventId);

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
