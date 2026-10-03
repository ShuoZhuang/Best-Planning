// FR-CAL-01 的"删除"。用**真实 drift 仓储**而不是替身：这条链路的价值在于"删掉之后
// 区间查询里不再出现"，而那是 SQL 行为，替身证明不了。
//
// 端口是单独的一个（`CalendarEventDeletion`），因为 `CalendarRepository` 有 5 个测试替身；
// 本文件因此只需要一个真实数据库，不需要任何替身。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// drift 生成物里也有一个 `CalendarEvent`（表行类），而本文件要的是**领域模型**，因此把它藏掉。
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';

final _start = DateTime.utc(2026, 10, 5, 9);

CalendarEvent _event(String id, String title, {int hour = 9}) => CalendarEvent(
  id: id,
  title: title,
  startAtUtc: DateTime.utc(2026, 10, 5, hour),
  endAtUtc: DateTime.utc(2026, 10, 5, hour + 1),
  timeZoneId: 'UTC',
  updatedAtUtc: DateTime.utc(2026, 10, 1),
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
}
