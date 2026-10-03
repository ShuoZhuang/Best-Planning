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

  test('删除某一次会隐藏那一次，其余各次保留；重复删除不堆积例外行', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());
    expect(await startsOverTwoWeeks(), hasLength(2));

    // 只删 10-12 那一次。
    await repository.deleteOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      title: '数据结构课',
      exceptionId: 'exception-delete-1',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // 那一次消失，10-05 仍在——只断言"少了一条"无法区分"删对了哪一条"。
    expect(await startsOverTwoWeeks(), <DateTime>[DateTime.utc(2026, 10, 5, 9)]);

    // 再删一次（过期视图会这样）：结果不变，且**不新增例外行**。
    await repository.deleteOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      title: '数据结构课',
      exceptionId: 'exception-delete-2',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );
    expect(await startsOverTwoWeeks(), <DateTime>[DateTime.utc(2026, 10, 5, 9)]);
    final exceptions = await database
        .select(database.calendarEvents)
        .get();
    final exceptionRows = exceptions
        .where((row) => row.exceptionOfId == 'anchor-1')
        .toList();
    expect(exceptionRows, hasLength(1));
    // 零长度是"这一次被删除"的约定（见读取端），行长度本身必须为 0。
    expect(exceptionRows.single.startAtUtc, exceptionRows.single.endAtUtc);
  });

  test('对单次日程调用"只删这一次"会删掉该行，而不是留下孤儿例外', () async {
    // 一条**真正独立**的单次日程（不带 `exceptionOfId`）：夹具若复用替换行，会因为那条
    // 锚点并不存在而撞上外键约束——本文件第一版正是这样，被用例当场顶了出来。
    await repository.save(
      CalendarEvent(
        id: 'single-1',
        title: '一次性讲座',
        startAtUtc: DateTime.utc(2026, 10, 12, 14),
        endAtUtc: DateTime.utc(2026, 10, 12, 15),
        timeZoneId: 'UTC',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    );
    expect(await startsOverTwoWeeks(), hasLength(1));

    await repository.deleteOccurrence(
      anchorId: 'single-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 14),
      title: '一次性讲座',
      exceptionId: 'exception-delete-3',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // 若这里留下一条 `exceptionOfId` 非空的零长度行，该行既不出现在单次查询里、也不会被
    // 展开，等于把这条日程悄悄藏起来一半。
    expect(await startsOverTwoWeeks(), isEmpty);
  });

  test('对不存在的锚点删除是幂等的', () async {
    await expectLater(
      repository.deleteOccurrence(
        anchorId: 'never-existed',
        occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
        title: '不存在',
        exceptionId: 'exception-delete-4',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      completes,
    );
  });

  Future<int> exceptionRowCount() async {
    final rows = await database.select(database.calendarEvents).get();
    return rows.where((row) => row.exceptionOfId == 'anchor-1').length;
  }

  test('改写某一次会把那一次移到新时间，其余各次不动', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());

    await repository.replaceOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      newStartUtc: DateTime.utc(2026, 10, 12, 16),
      newEndUtc: DateTime.utc(2026, 10, 12, 17),
      title: '数据结构课',
      exceptionId: 'exception-replace-1',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // 只有 10-12 换了时间：断言整串而不是"某个时间出现过"，否则无法区分改对了哪一次。
    expect(await startsOverTwoWeeks(), <DateTime>[
      DateTime.utc(2026, 10, 5, 9),
      DateTime.utc(2026, 10, 12, 16),
    ]);
    expect(await exceptionRowCount(), 1);
  });

  test('同一天重复改写**复用同一条例外行**，不会堆积', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());

    await repository.replaceOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      newStartUtc: DateTime.utc(2026, 10, 12, 16),
      newEndUtc: DateTime.utc(2026, 10, 12, 17),
      title: '数据结构课',
      exceptionId: 'exception-replace-1',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );
    await repository.replaceOccurrence(
      anchorId: 'anchor-1',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 9),
      newStartUtc: DateTime.utc(2026, 10, 12, 18),
      newEndUtc: DateTime.utc(2026, 10, 12, 19),
      title: '数据结构课',
      exceptionId: 'exception-replace-2',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // 写第二条会让展开器按遍历顺序二选一——那是一种"有时生效有时不生效"的缺陷。
    expect(await exceptionRowCount(), 1);
    // 而且第二次的值必须胜出。
    expect(await startsOverTwoWeeks(), <DateTime>[
      DateTime.utc(2026, 10, 5, 9),
      DateTime.utc(2026, 10, 12, 18),
    ]);
  });

  test('对单次日程"改这一次"直接改那一行，不产生例外行', () async {
    await repository.save(
      CalendarEvent(
        id: 'single-2',
        title: '一次性讲座',
        startAtUtc: DateTime.utc(2026, 10, 12, 14),
        endAtUtc: DateTime.utc(2026, 10, 12, 15),
        timeZoneId: 'UTC',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    );

    await repository.replaceOccurrence(
      anchorId: 'single-2',
      occurrenceStartUtc: DateTime.utc(2026, 10, 12, 14),
      newStartUtc: DateTime.utc(2026, 10, 12, 16),
      newEndUtc: DateTime.utc(2026, 10, 12, 17),
      title: '一次性讲座',
      exceptionId: 'exception-replace-3',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    expect(await startsOverTwoWeeks(), <DateTime>[DateTime.utc(2026, 10, 12, 16)]);
    final rows = await database.select(database.calendarEvents).get();
    // 单次日程若被写成"系列的一次"，它从此必须依赖规则才可见——那会把一条独立日程绑死。
    expect(rows.where((row) => row.exceptionOfId != null), isEmpty);
  });

  test('改写整个系列会把**所有各次**一起换到新时间', () async {
    await repository.saveRecurring(_anchorEvent(), _weeklyRule());

    await repository.replaceSeries(
      anchorId: 'anchor-1',
      newStartUtc: DateTime.utc(2026, 10, 5, 14),
      newEndUtc: DateTime.utc(2026, 10, 5, 15),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // **两次都要变**：只断言第一次会让"改了锚点、忘了改规则"的实现通过——那种实现里第二次
    // 仍是 09:00，正是这条断言要挡的半成品。
    expect(await startsOverTwoWeeks(), <DateTime>[
      DateTime.utc(2026, 10, 5, 14),
      DateTime.utc(2026, 10, 12, 14),
    ]);
    // 时长存在规则里，也必须跟着变。
    final occurrences = await repository.occurrencesBetween(
      DateTime.utc(2026, 10, 5),
      DateTime.utc(2026, 10, 19),
    );
    expect(
      occurrences.first.range.endUtc
          .difference(occurrences.first.range.startUtc)
          .inMinutes,
      60,
    );
  });

  test('对单次日程"改整个系列"退化为改那一行', () async {
    await repository.save(
      CalendarEvent(
        id: 'single-3',
        title: '一次性讲座',
        startAtUtc: DateTime.utc(2026, 10, 12, 14),
        endAtUtc: DateTime.utc(2026, 10, 12, 15),
        timeZoneId: 'UTC',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    );

    await repository.replaceSeries(
      anchorId: 'single-3',
      newStartUtc: DateTime.utc(2026, 10, 12, 18),
      newEndUtc: DateTime.utc(2026, 10, 12, 19),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // 单次日程没有"系列"可言：既不能报错，也不能凭空造一条规则。
    expect(await startsOverTwoWeeks(), <DateTime>[
      DateTime.utc(2026, 10, 12, 18),
    ]);
  });
}
