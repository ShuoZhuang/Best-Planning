// FR-STAT-06 的"重排原因"的第二类来源：**固定日程的增删改**。
//
// 任务侧的四类变化早就有发出者（见 `replan_events_test.dart`），而固定日程占用的时间是排程的
// 硬约束，因此日历的写入同样会改变排程输入——这条路径此前登记为"未覆盖"（§13.0 W9 的 (a)），
// 于是统计页的"重排原因"看起来像一份完整分布，实际整整缺了日历这一类。
//
// 本文件钉住三件事：
// 1. 五条写入路径各自的原因码——原因码会**直接显示给用户**，所以必须是人话而不是枚举名；
// 2. **只记成功的写入**：非法草稿、以及未装配删除／改写端口时的 `false` 都不该留下原因
//    （改不动就没有重排，与任务侧同口径）；
// 3. 未装配回调时照常写入，只是不留原因——日历服务不该依赖统计是否可用。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 9);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'id-${++_count}';
}

final class _Calendar
    implements CalendarRepository, RecurringCalendarRepository {
  final List<CalendarEvent> saved = [];
  final List<RecurrenceRule> rules = [];

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [];

  @override
  Future<void> save(CalendarEvent event) async => saved.add(event);

  @override
  Future<void> saveRecurring(CalendarEvent event, RecurrenceRule rule) async {
    saved.add(event);
    rules.add(rule);
  }
}

final class _Deletion implements CalendarEventDeletion {
  final List<String> calls = [];

  @override
  Future<void> deleteEvent(String eventId) async =>
      calls.add('deleteEvent:$eventId');

  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async => calls.add('deleteOccurrence:$anchorId');

  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async => calls.add('replaceOccurrence:$anchorId');

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required DateTime updatedAtUtc,
  }) async => calls.add('replaceSeries:$anchorId');
}

void main() {
  late _Calendar calendar;
  late _Deletion deletion;
  late List<String> reasons;

  CalendarService build({
    bool withCallback = true,
    bool withDeletion = true,
  }) => CalendarService(
    repository: calendar,
    recurringRepository: calendar,
    deletion: withDeletion ? deletion : null,
    clock: const _Clock(),
    idGenerator: _Ids(),
    zones: TimeZoneDatabase(),
    onScheduleInputChanged: withCallback ? reasons.add : null,
  );

  EventDraft draft({Set<int> weekdays = const {}, String title = '社团会议'}) =>
      EventDraft(
        title: title,
        startAtUtc: DateTime.utc(2026, 10, 5, 1),
        endAtUtc: DateTime.utc(2026, 10, 5, 3),
        timeZoneId: 'Asia/Shanghai',
        recurrenceWeekdays: weekdays,
      );

  setUp(() {
    calendar = _Calendar();
    deletion = _Deletion();
    reasons = [];
  });

  test('新建固定日程记一条"固定日程创建"', () async {
    final result = await build().save(draft());

    expect(result.isSuccess, isTrue);
    expect(reasons, <String>['固定日程创建']);
  });

  test('按周重复的日程也只记一条创建（一次用户动作＝一条原因）', () async {
    await build().save(draft(weekdays: {DateTime.monday}));

    expect(calendar.rules, hasLength(1));
    expect(reasons, <String>['固定日程创建']);
  });

  test('删除固定日程记一条"固定日程删除"', () async {
    final removed = await build().deleteEvent('event-1');

    expect(removed, isTrue);
    expect(reasons, <String>['固定日程删除']);
  });

  test('只删这一次记一条"固定日程单次删除"', () async {
    final removed = await build().deleteOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 1),
      title: '每周课程',
    );

    expect(removed, isTrue);
    expect(reasons, <String>['固定日程单次删除']);
  });

  test('改写某一次记一条"固定日程单次改写"', () async {
    final changed = await build().replaceOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 1),
      newStartUtc: DateTime.utc(2026, 10, 12, 6),
      newEndUtc: DateTime.utc(2026, 10, 12, 8),
      title: '每周课程',
    );

    expect(changed, isTrue);
    expect(reasons, <String>['固定日程单次改写']);
  });

  test('改写整个系列记一条"固定日程系列改写"', () async {
    final changed = await build().replaceSeries(
      anchorId: 'anchor-1',
      newStartUtc: DateTime.utc(2026, 10, 12, 6),
      newEndUtc: DateTime.utc(2026, 10, 12, 8),
    );

    expect(changed, isTrue);
    expect(reasons, <String>['固定日程系列改写']);
  });

  test('非法草稿不记原因，也不落库（改不动就没有重排）', () async {
    final result = await build().save(draft(title: '   '));

    expect(result.isSuccess, isFalse);
    expect(calendar.saved, isEmpty);
    expect(reasons, isEmpty);
  });

  test('已装配的写入端口失败时返回值是 false，因此也不记原因', () async {
    // 未装配删除／改写端口时服务返回 `false` 而不是抛错——界面据此区分"已删除／未装配"。
    // 那种 `false` **不是**一次真实的日程变化，因此不能留下重排原因。
    final service = build(withDeletion: false);

    expect(await service.deleteEvent('event-1'), isFalse);
    expect(
      await service.replaceSeries(
        anchorId: 'anchor-1',
        newStartUtc: DateTime.utc(2026, 10, 12, 6),
        newEndUtc: DateTime.utc(2026, 10, 12, 8),
      ),
      isFalse,
    );

    expect(reasons, isEmpty);
  });

  test('未装配回调时照常写入，只是不留原因', () async {
    final service = build(withCallback: false);

    await service.save(draft());
    await service.deleteEvent('event-1');

    expect(calendar.saved, hasLength(1));
    expect(deletion.calls, <String>['deleteEvent:event-1']);
    expect(reasons, isEmpty);
  });
}
