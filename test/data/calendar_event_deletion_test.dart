// FR-CAL-01 的"删除"。用**真实 drift 仓储**而不是替身：这条链路的价值在于"删掉之后
// 区间查询里不再出现"，而那是 SQL 行为，替身证明不了。
//
// 端口是单独的一个（`CalendarEventDeletion`），因为 `CalendarRepository` 有 5 个测试替身；
// 本文件因此只需要一个真实数据库，不需要任何替身。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// drift 生成物里也有一个 `CalendarEvent`（表行类），而本文件要的是**领域模型**，因此把它藏掉。
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final _start = DateTime.utc(2026, 10, 5, 9);

CalendarEvent _event(String id, String title, {int hour = 9}) => CalendarEvent(
  id: id,
  title: title,
  startAtUtc: DateTime.utc(2026, 10, 5, hour),
  endAtUtc: DateTime.utc(2026, 10, 5, hour + 1),
  timeZoneId: 'UTC',
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

CalendarEvent _recurringEvent() => CalendarEvent(
  id: 'anchor-1',
  title: '数据结构课',
  startAtUtc: DateTime.utc(2026, 10, 5, 9),
  endAtUtc: DateTime.utc(2026, 10, 5, 10),
  timeZoneId: 'UTC',
  recurrenceRuleId: 'rule-1',
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

RecurrenceRule _recurringRule() => RecurrenceRule(
  id: 'rule-1',
  weekdays: const {DateTime.monday},
  localStartMinute: 9 * 60,
  durationMinutes: 60,
  validFromLocalDate: DateTime(2026, 10, 5),
  validUntilLocalDate: DateTime(2026, 10, 26),
  timeZoneId: 'UTC',
);

void main() {
  late AppDatabase database;
  late DriftCalendarRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database);
  });

  tearDown(() => database.close());

  Future<List<String>> titlesInWindow() async {
    final occurrences = await repository.occurrencesBetween(
      _start,
      _start.add(const Duration(days: 1)),
    );
    return [for (final occurrence in occurrences) occurrence.title];
  }

  test('删除后不再出现在区间查询里，其余日程不受影响', () async {
    await repository.save(_event('event-1', '数据结构课'));
    await repository.save(_event('event-2', '社团会议', hour: 14));
    expect(await titlesInWindow(), containsAll(<String>['数据结构课', '社团会议']));

    await repository.deleteEvent('event-1');

    // 断言"剩下的那一份仍在"：只断言"被删的没了"，一个把所有行都删掉的实现也能通过。
    expect(await titlesInWindow(), <String>['社团会议']);
  });

  test('重复删除是幂等的，不抛异常', () async {
    await repository.save(_event('event-1', '数据结构课'));
    await repository.deleteEvent('event-1');

    // 调用方拿到的 id 可能来自一次已过期的视图；把"记录不在"当异常会让界面在一次
    // 无关的竞态后报错，因此第二次删除必须安静地成功。
    await expectLater(repository.deleteEvent('event-1'), completes);
    await expectLater(repository.deleteEvent('never-existed'), completes);
  });

  test('从周/日视图条目 id 解出的**领域 id** 才删得掉那一行', () async {
    // 这是把两段各自正确的代码接起来的那条断言：仓储按领域 id 删除是对的，视图按自己的
    // 命名空间发 id 也是对的，但把 `fixed:<uuid>` 直接交给仓储会执行
    // `DELETE ... WHERE id = 'fixed:<uuid>'`——匹配 0 行、不报错，于是"删不掉"却看不出错。
    await repository.saveRecurring(_recurringEvent(), _recurringRule());

    final item = ScheduleViewItem(
      id: scheduleFixedItemId('anchor-1'),
      title: '数据结构课',
      kind: ScheduleItemKind.fixed,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 9),
        endUtc: DateTime.utc(2026, 10, 5, 10),
      ),
    );

    // 条目 id 本身不是领域 id，直接拿去删等于删空气。
    await repository.deleteEvent(item.id);
    expect(await titlesInWindow(), <String>['数据结构课']);

    // 取用必须先解出领域 id。
    final eventId = fixedEventId(item);
    expect(eventId, 'anchor-1');
    await repository.deleteEvent(eventId!);
    expect(await titlesInWindow(), isEmpty);
  });

  test('改本次及以后会截断旧规则并从选中日期建立新系列', () async {
    await repository.saveRecurring(_recurringEvent(), _recurringRule());

    await repository.replaceFollowingOccurrences(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      newStartUtc: DateTime.utc(2026, 10, 12, 14),
      newEndUtc: DateTime.utc(2026, 10, 12, 15),
      newRuleId: 'rule-following',
      newEventId: 'anchor-following',
      updatedAtUtc: DateTime.utc(2026, 10, 2),
    );

    final occurrences = await repository.occurrencesBetween(
      DateTime.utc(2026, 10, 5),
      DateTime.utc(2026, 10, 27),
    );
    expect(occurrences.map((item) => item.range.startUtc), [
      DateTime.utc(2026, 10, 5, 9),
      DateTime.utc(2026, 10, 12, 14),
      DateTime.utc(2026, 10, 19, 14),
      DateTime.utc(2026, 10, 26, 14),
    ]);
    final rules = await database.select(database.recurrenceRules).get();
    final old = rules.singleWhere((row) => row.id == 'rule-1');
    final following = rules.singleWhere((row) => row.id == 'rule-following');
    expect(old.validUntilLocalDate, '2026-10-11');
    expect(following.validFromLocalDate, '2026-10-12');
    expect(following.validUntilLocalDate, '2026-10-26');
  });

  test('删本次及以后只截断旧规则，选中日期不再出现', () async {
    await repository.saveRecurring(_recurringEvent(), _recurringRule());

    await repository.deleteFollowingOccurrences(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      updatedAtUtc: DateTime.utc(2026, 10, 2),
    );

    final occurrences = await repository.occurrencesBetween(
      DateTime.utc(2026, 10, 5),
      DateTime.utc(2026, 10, 27),
    );
    expect(occurrences.map((item) => item.range.startUtc), [
      DateTime.utc(2026, 10, 5, 9),
    ]);
    expect(
      (await database.select(database.recurrenceRules).getSingle())
          .validUntilLocalDate,
      '2026-10-11',
    );
  });

  test('拆分系列不会复制选中实例，较早例外仍只属于旧锚点', () async {
    await repository.saveRecurring(_recurringEvent(), _recurringRule());
    await repository.replaceOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 5, 9),
      newStartUtc: DateTime.utc(2026, 10, 5, 11),
      newEndUtc: DateTime.utc(2026, 10, 5, 12),
      title: '数据结构课',
      exceptionId: 'exception-before',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    await repository.replaceFollowingOccurrences(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      newStartUtc: DateTime.utc(2026, 10, 12, 14),
      newEndUtc: DateTime.utc(2026, 10, 12, 15),
      newRuleId: 'rule-following',
      newEventId: 'anchor-following',
      updatedAtUtc: DateTime.utc(2026, 10, 2),
    );

    final rows = await database.select(database.calendarEvents).get();
    expect(
      rows.singleWhere((row) => row.id == 'exception-before').exceptionOfId,
      'anchor-1',
    );
    final occurrences = await repository.occurrencesBetween(
      DateTime.utc(2026, 10, 12),
      DateTime.utc(2026, 10, 13),
    );
    expect(occurrences, hasLength(1));
    expect(occurrences.single.range.startUtc, DateTime.utc(2026, 10, 12, 14));
  });
}
