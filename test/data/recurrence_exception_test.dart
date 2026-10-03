// R4 的**替换型例外**（"改这一次"）：把例外行交给展开器。
//
// 此前这条数据路径是**静默丢弃**的：锚点查询排除了 `exceptionOfId` 非空的行，而展开器收到
// 的是空表，于是"改这一次"既不生效、那条例外行也从日历上消失（见 §13.0 的 R4）。本文件钉住
// 修好之后的两件事：**被改的那一次显示为新时间**，且**不会因此多出或漏掉一条**。
//
// 用真实 drift 仓储：被验证的是 SQL 读取与展开的配合，替身证明不了。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// drift 生成物里也有 `CalendarEvent` 与 `RecurrenceRule`（表行类），而本文件要的是**领域模型**。
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';

/// 2026-10-05 是周一，因此"每周一 09:00（UTC）"的规则会在 10-05 与 10-12 各出一条。
final _weekStart = DateTime.utc(2026, 10, 5, 9);

DriftCalendarRepository _repository(AppDatabase database) =>
    DriftCalendarRepository(database);

CalendarEvent _anchorEvent() => CalendarEvent(
  id: 'anchor-1',
  title: '数据结构课',
  startAtUtc: _weekStart,
  endAtUtc: _weekStart.add(const Duration(hours: 1)),
  timeZoneId: 'UTC',
  recurrenceRuleId: 'rule-1',
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

RecurrenceRule _weeklyRule() => RecurrenceRule(
  id: 'rule-1',
  weekdays: const {1},
  localStartMinute: 9 * 60,
  durationMinutes: 60,
  validFromLocalDate: DateTime(2026, 10, 5),
  timeZoneId: 'UTC',
);

/// 只改 **10-12 那一次**：改到当天 14:00。
CalendarEvent _replacement() => CalendarEvent(
  id: 'exception-1',
  title: '数据结构课',
  startAtUtc: DateTime.utc(2026, 10, 12, 14),
  endAtUtc: DateTime.utc(2026, 10, 12, 15),
  timeZoneId: 'UTC',
  exceptionOfId: 'anchor-1',
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  late AppDatabase database;
  late DriftCalendarRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = _repository(database);
  });

  tearDown(() => database.close());

  Future<List<DateTime>> startsOverTwoWeeks() async {
    final occurrences = await repository.occurrencesBetween(
      DateTime.utc(2026, 10, 5),
      DateTime.utc(2026, 10, 19),
    );
    return [for (final occurrence in occurrences) occurrence.range.startUtc];
  }

  test('没有例外时，规则在两周内展开两次', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());

    // 先立"没有例外时是什么样"，否则下面那条用例无法区分"替换生效"与"本来就少一条"。
    expect(await startsOverTwoWeeks(), <DateTime>[
      DateTime.utc(2026, 10, 5, 9),
      DateTime.utc(2026, 10, 12, 9),
    ]);
  });

  test('例外行把**那一次**改到新时间，其余各次不动，且不多出条目', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());
    await repository.save(_replacement());

    final starts = await startsOverTwoWeeks();

    // 恰好两条：被改的那次换成 14:00，另一条仍是 09:00。
    // 只断言"14:00 在里面"是不够的——那无法区分"替换"与"又多排了一条"。
    expect(starts, <DateTime>[
      DateTime.utc(2026, 10, 5, 9),
      DateTime.utc(2026, 10, 12, 14),
    ]);
  });

  test('例外划在窗口之外时不改变窗口内的各次', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());
    // 11 月 2 日（周一）在窗口之外：例外只影响它自己那一天。
    await repository.save(
      CalendarEvent(
        id: 'exception-outside',
        title: '数据结构课',
        startAtUtc: DateTime.utc(2026, 11, 2, 14),
        endAtUtc: DateTime.utc(2026, 11, 2, 15),
        timeZoneId: 'UTC',
        exceptionOfId: 'anchor-1',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    );

    expect(await startsOverTwoWeeks(), <DateTime>[
      DateTime.utc(2026, 10, 5, 9),
      DateTime.utc(2026, 10, 12, 9),
    ]);
  });
}
