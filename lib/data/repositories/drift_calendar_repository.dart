import 'package:drift/drift.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart' as domain;
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/services/recurrence_expander.dart';

final class DriftCalendarRepository
    implements
        CalendarRepository,
        RecurringCalendarRepository,
        CalendarEventDeletion {
  DriftCalendarRepository(this._database, {TimeZoneDatabase? zones})
    : _zones = zones ?? TimeZoneDatabase(),
      _recurrence = RecurrenceExpander(zones ?? TimeZoneDatabase());

  final db.AppDatabase _database;

  /// 例外行的 `startAtUtc` 要换算成**规则时区里的本地日期**才能与展开器对齐，
  /// 因此除了展开器本身，仓储也要持有同一份时区数据库。
  final TimeZoneDatabase _zones;
  final RecurrenceExpander _recurrence;

  @override
  Future<List<domain.CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    if (!startUtc.isUtc || !endUtc.isUtc || !endUtc.isAfter(startUtc)) {
      throw ArgumentError('A valid UTC query range is required.');
    }
    final query = _database.select(_database.calendarEvents)
      ..where(
        (row) =>
            row.recurrenceRuleId.isNull() &
            // **例外行不是独立事件**：它只通过展开器生效（见下方 `replacedByAnchor`）。
            // 不排除它，同一次就会既作为"独立事件"出现、又作为"替换结果"出现——实测重复。
            row.exceptionOfId.isNull() &
            row.startAtUtc.isSmallerThanValue(endUtc.microsecondsSinceEpoch) &
            row.endAtUtc.isBiggerThanValue(startUtc.microsecondsSinceEpoch),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.startAtUtc)]);
    final result = [
      for (final row in await query.get())
        domain.CalendarOccurrence(
          eventId: row.id,
          title: row.title,
          range: TimeRange(
            startUtc: _instant(row.startAtUtc),
            endUtc: _instant(row.endAtUtc),
          ),
          locked: row.locked,
          areaId: row.areaId,
        ),
    ];

    final recurring = _database.select(_database.calendarEvents).join([
      innerJoin(
        _database.recurrenceRules,
        _database.recurrenceRules.id.equalsExp(
          _database.calendarEvents.recurrenceRuleId,
        ),
      ),
    ])..where(_database.calendarEvents.exceptionOfId.isNull());
    final window = TimeRange(startUtc: startUtc, endUtc: endUtc);

    // **例外必须被读出来并交给展开器**，否则它们会被静默丢弃：下面的锚点查询排除了
    // `exceptionOfId` 非空的行，而展开器此前收到的是空表，于是"改这一次"既不生效、那行
    // 也消失（见 §13.0 的 R4）。这里一次取出全部例外并按锚点分组，避免每个锚点一次查询。
    //
    // 本次只处理**替换型**例外（改到别的时间）。"删掉这一次"在库里没有表示——没有任何列
    // 能表达它，那需要产品与数据模型决策（同行的三条出路）。
    final exceptionRows = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.isNotNull())).get();
    final replacedByAnchor = <String, List<RecurrenceException>>{};
    for (final row in exceptionRows) {
      final anchorId = row.exceptionOfId!;
      final startUtc = _instant(row.startAtUtc);
      // 展开器按**本地日期**对齐例外，因此这里要用规则时区换算，而不是直接取 UTC 日期。
      final localDate = _zones.toLocal(startUtc, row.timeZoneId);
      (replacedByAnchor[anchorId] ??= <RecurrenceException>[]).add(
        // **起止相同的零长度行表示"这一次被删除"**：`calendar_events` 没有任何能表达"删除"的
        // 列，而一条起止相同的日程本身没有任何意义，因此用它当哨兵值，并把这条约定写进规格
        // （见 §13.0 的 R4 行）。比"新增一列走 schema v4 迁移"便宜得多，代价是需要知道它。
        row.startAtUtc == row.endAtUtc
            ? RecurrenceException.deleted(localDate: localDate)
            : RecurrenceException.replaced(
                localDate: localDate,
                replacement: TimeRange(
                  startUtc: startUtc,
                  endUtc: _instant(row.endAtUtc),
                ),
              ),
      );
    }

    for (final joined in await recurring.get()) {
      final event = joined.readTable(_database.calendarEvents);
      final stored = joined.readTable(_database.recurrenceRules);
      final rule = domain.RecurrenceRule(
        id: stored.id,
        weekdays: _weekdays(stored.weekdaysMask),
        localStartMinute: stored.localStartMinute,
        durationMinutes: stored.durationMinutes,
        validFromLocalDate: DateTime.parse(stored.validFromLocalDate),
        validUntilLocalDate: stored.validUntilLocalDate == null
            ? null
            : DateTime.parse(stored.validUntilLocalDate!),
        timeZoneId: stored.timeZoneId,
      );
      for (final occurrence in _recurrence.expand(
        rule,
        window,
        replacedByAnchor[event.id] ?? const <RecurrenceException>[],
      )) {
        result.add(
          domain.CalendarOccurrence(
            eventId: event.id,
            title: event.title,
            range: occurrence.range,
            locked: event.locked,
            areaId: event.areaId,
          ),
        );
      }
    }
    result.sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    return List.unmodifiable(result);
  }

  @override
  /// 删除固定日程（FR-CAL-01）。
  ///
  /// **幂等**：删不到就当作已经删掉——调用方拿到的 id 可能来自一次已过期的视图，把"记录不在"
  /// 当异常会让界面在一次无关的竞态后报错（见端口的文档说明）。
  ///
  /// **本次只删这一条事件行**：若它是某条重复规则的锚点，规则行本身仍然留着，而展开又依赖
  /// 锚点才发生，因此"整串消失"。**逐次例外与"改整个系列"仍属后续**（`EventEditScope` 目前
  /// 只被采集、未被使用），这一点在 §13.0 的 R4 行里写明，不在实现里假装已经支持。
  /// 改写重复日程里的某一次（FR-CAL-02），见端口的文档说明。
  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {
    if (!newEndUtc.isAfter(newStartUtc)) {
      throw ArgumentError('替换后的结束时刻必须晚于开始时刻');
    }
    final anchor = await (_database.select(_database.calendarEvents)
          ..where((row) => row.id.equals(anchorId))
          ..limit(1))
        .getSingleOrNull();
    // 锚点已经不在了：与删除同样按幂等处理。
    if (anchor == null) return;

    final ruleId = anchor.recurrenceRuleId;
    if (ruleId == null) {
      // 单次日程：直接改它自己那一行。"只改这一次"与"改整条"在单次日程上是同一件事，
      // 因此不必（也不该）留下一条替换例外——那会让这条日程变成"系列的一次"。
      await save(
        domain.CalendarEvent(
          id: anchor.id,
          title: title,
          startAtUtc: newStartUtc,
          endAtUtc: newEndUtc,
          timeZoneId: anchor.timeZoneId,
          exceptionOfId: anchor.exceptionOfId,
          locked: anchor.locked,
          areaId: anchor.areaId,
          updatedAtUtc: updatedAtUtc,
        ),
      );
      return;
    }

    final rule = await (_database.select(_database.recurrenceRules)
          ..where((row) => row.id.equals(ruleId))
          ..limit(1))
        .getSingleOrNull();
    if (rule == null) return;

    // 同一天已有例外就**复用那一行的 id**：再写一条会让展开器按遍历顺序二选一，结果不确定。
    final localDate = _zones.toLocal(occurrenceStartUtc, rule.timeZoneId);
    var targetId = exceptionId;
    final existing = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.equals(anchorId))).get();
    for (final row in existing) {
      final rowDate = _zones.toLocal(_instant(row.startAtUtc), row.timeZoneId);
      if (rowDate.year == localDate.year &&
          rowDate.month == localDate.month &&
          rowDate.day == localDate.day) {
        targetId = row.id;
        break;
      }
    }

    await save(
      domain.CalendarEvent(
        id: targetId,
        title: title,
        startAtUtc: newStartUtc,
        endAtUtc: newEndUtc,
        // 用**规则自己的时区**：读取端按该时区把起点换算成本地日期来对齐例外。
        timeZoneId: rule.timeZoneId,
        exceptionOfId: anchorId,
        updatedAtUtc: updatedAtUtc,
      ),
    );
  }

  /// 只删除重复日程里的某一次（FR-CAL-02），见端口的文档说明。
  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {
    final anchor = await (_database.select(_database.calendarEvents)
          ..where((row) => row.id.equals(anchorId))
          ..limit(1))
        .getSingleOrNull();
    // 锚点已经不在了：这次删除的目的已经达到（幂等）。
    if (anchor == null) return;

    final ruleId = anchor.recurrenceRuleId;
    // 不是重复日程：它就是一条单次日程，"只删这一次"与"删整条"本就等价。若仍写一条
    // `exceptionOfId` 非空的零长度行，那行**既不出现在单次查询里、也不会被展开**，
    // 等于把这条日程悄悄藏起来一半——因此这里直接删掉这一行。
    if (ruleId == null) {
      await deleteEvent(anchorId);
      return;
    }

    final rule = await (_database.select(_database.recurrenceRules)
          ..where((row) => row.id.equals(ruleId))
          ..limit(1))
        .getSingleOrNull();
    // 规则行缺失（正常路径由 `saveRecurring` 的事务保证）：退化为删除锚点，而不是留下例外。
    if (rule == null) {
      await deleteEvent(anchorId);
      return;
    }

    // 同一天已有例外就不再写：重复点击（或来自过期视图的删除）不该让例外行不断堆积。
    final localDate = _zones.toLocal(occurrenceStartUtc, rule.timeZoneId);
    final existing = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.equals(anchorId))).get();
    for (final row in existing) {
      final rowDate = _zones.toLocal(_instant(row.startAtUtc), row.timeZoneId);
      if (rowDate.year == localDate.year &&
          rowDate.month == localDate.month &&
          rowDate.day == localDate.day) {
        return;
      }
    }

    // 用**底层 companion** 写这行，而不是走领域模型：`CalendarEvent` 的构造会校验
    // `endUtc > startUtc`（`TimeRange` 的域不变量），而这里恰恰要写一行**起止相同**的标记行。
    // 这行不是"一条日程"，而是"这一次被删除"的标记；读取端也只把它当标记（见
    // `occurrencesBetween`），因此不构造领域模型。
    final now = updatedAtUtc.microsecondsSinceEpoch;
    await _database
        .into(_database.calendarEvents)
        .insert(
          db.CalendarEventsCompanion(
            id: Value(exceptionId),
            title: Value(title),
            startAtUtc: Value(occurrenceStartUtc.microsecondsSinceEpoch),
            endAtUtc: Value(occurrenceStartUtc.microsecondsSinceEpoch),
            timeZoneId: Value(rule.timeZoneId),
            exceptionOfId: Value(anchorId),
            // R10 要求时间戳一并写入：标记行同样不该留哨兵值 0。
            createdAtUtc: Value(now),
            updatedAtUtc: Value(now),
          ),
          onConflict: DoUpdate(
            (old) => db.CalendarEventsCompanion(
              startAtUtc: Value(occurrenceStartUtc.microsecondsSinceEpoch),
              endAtUtc: Value(occurrenceStartUtc.microsecondsSinceEpoch),
              updatedAtUtc: Value(now),
            ),
          ),
        );
  }

  @override
  Future<void> deleteEvent(String eventId) async {
    await (_database.delete(
      _database.calendarEvents,
    )..where((row) => row.id.equals(eventId))).go();
  }

  @override
  Future<void> saveRecurring(
    domain.CalendarEvent event,
    domain.RecurrenceRule rule,
  ) {
    if (event.recurrenceRuleId != rule.id) {
      throw ArgumentError('Event and recurrence rule ids must match.');
    }
    final modifiedAt = event.updatedAtUtc.microsecondsSinceEpoch;
    return _database.transaction(() async {
      await _database
          .into(_database.recurrenceRules)
          .insert(
            db.RecurrenceRulesCompanion(
              id: Value(rule.id),
              weekdaysMask: Value(_weekdaysMask(rule.weekdays)),
              localStartMinute: Value(rule.localStartMinute),
              durationMinutes: Value(rule.durationMinutes),
              validFromLocalDate: Value(_date(rule.validFromLocalDate)),
              validUntilLocalDate: Value(
                rule.validUntilLocalDate == null
                    ? null
                    : _date(rule.validUntilLocalDate!),
              ),
              timeZoneId: Value(rule.timeZoneId),
              createdAtUtc: Value(modifiedAt),
              updatedAtUtc: Value(modifiedAt),
            ),
            onConflict: DoUpdate(
              (old) => db.RecurrenceRulesCompanion(
                weekdaysMask: Value(_weekdaysMask(rule.weekdays)),
                localStartMinute: Value(rule.localStartMinute),
                durationMinutes: Value(rule.durationMinutes),
                validFromLocalDate: Value(_date(rule.validFromLocalDate)),
                validUntilLocalDate: Value(
                  rule.validUntilLocalDate == null
                      ? null
                      : _date(rule.validUntilLocalDate!),
                ),
                timeZoneId: Value(rule.timeZoneId),
                updatedAtUtc: Value(modifiedAt),
              ),
            ),
          );
      await save(event);
    });
  }

  @override
  Future<void> save(domain.CalendarEvent event) {
    final modifiedAt = event.updatedAtUtc.microsecondsSinceEpoch;
    return _database
        .into(_database.calendarEvents)
        .insert(
          db.CalendarEventsCompanion(
            id: Value(event.id),
            title: Value(event.title),
            startAtUtc: Value(event.startAtUtc.microsecondsSinceEpoch),
            endAtUtc: Value(event.endAtUtc.microsecondsSinceEpoch),
            timeZoneId: Value(event.timeZoneId),
            recurrenceRuleId: Value(event.recurrenceRuleId),
            exceptionOfId: Value(event.exceptionOfId),
            locked: Value(event.locked),
            areaId: Value(event.areaId),
            createdAtUtc: Value(modifiedAt),
            updatedAtUtc: Value(modifiedAt),
          ),
          // A brand new event is created and modified at the same instant. For an
          // existing one the conflict branch preserves the recorded creation time
          // and only advances the modification time (FR-DATA-08).
          onConflict: DoUpdate(
            (old) => db.CalendarEventsCompanion(
              title: Value(event.title),
              startAtUtc: Value(event.startAtUtc.microsecondsSinceEpoch),
              endAtUtc: Value(event.endAtUtc.microsecondsSinceEpoch),
              timeZoneId: Value(event.timeZoneId),
              recurrenceRuleId: Value(event.recurrenceRuleId),
              exceptionOfId: Value(event.exceptionOfId),
              locked: Value(event.locked),
              areaId: Value(event.areaId),
              updatedAtUtc: Value(modifiedAt),
            ),
          ),
        );
  }

  static DateTime _instant(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
}

Set<int> _weekdays(int mask) => {
  for (var day = DateTime.monday; day <= DateTime.sunday; day++)
    if (mask & (1 << (day - 1)) != 0) day,
};

int _weekdaysMask(Set<int> weekdays) =>
    weekdays.fold(0, (mask, day) => mask | (1 << (day - 1)));

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
