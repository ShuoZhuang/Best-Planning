import 'package:drift/drift.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart'
    show CalendarEventKind;
import 'package:personal_planner/domain/models/protected_time_series.dart';
import 'package:personal_planner/domain/repositories/protected_time_series_repository.dart';

/// `ProtectedTimeSeriesReader` 的 Drift 实现（课程与保护时间管理修复计划 Task 6）。
///
/// ## 为什么必须"先按锚点聚合、再逐条数例外"
///
/// 一键三连的错法是从展开结果反推（计划 §3 明确禁止）：
///
/// - 一条每周重复的保护时间会按发生次数返回几十行；
/// - 超出读取窗口的那些系列**根本读不到**，于是用户以为没建，又建一条重复的。
///
/// 正确做法是读**锚点行本身**：一行 = 一条用户建的系列。重复规则在
/// `recurrence_rules` 里，例外在"`exception_of_id` 指向本锚点"的行里。
final class DriftProtectedTimeSeriesRepository
    implements ProtectedTimeSeriesReader {
  // **不用 `this._zones` 那种初始化形参**：这些字段全是**私有**的，而 `this._x`
  // 会让形参名变成 `_x`——调用方就得写 `_zones: …`，把一个实现细节漏进公开 API。
  // 与 `DriftCourseSeriesRepository`、`RecurringTaskService` 同一条约定。
  // ignore_for_file: prefer_initializing_formals
  DriftProtectedTimeSeriesRepository(
    this._database, {
    required TimeZoneDatabase zones,
  }) : _zones = zones;

  final db.AppDatabase _database;
  // 保留 `zones` 依赖：范围内的本地日换算要用它，而"用哪个时区"必须来自事项自己。
  // ignore: unused_field
  final TimeZoneDatabase _zones;

  @override
  Future<List<ProtectedTimeSeries>> listProtectedSeries() async {
    final anchors =
        await (_database.select(_database.calendarEvents)
              ..where(
                (row) =>
                    row.kind.equals(CalendarEventKind.protected.storageValue) &
                    // **例外行不是系列**：它是"某一次被改过"的记录，
                    // 混进来会让管理页为每一次调整都显示一行。
                    row.exceptionOfId.isNull(),
              )
              // 排序定死在 SQL 之外会失去确定性，因此这里按标题与 id 排：
              // 同一标题的两条系列按 id 排，与创建顺序一致。
              ..orderBy([
                (row) => OrderingTerm.asc(row.title),
                (row) => OrderingTerm.asc(row.startAtUtc),
                (row) => OrderingTerm.asc(row.id),
              ]))
            .get();

    final result = <ProtectedTimeSeries>[];
    for (final anchor in anchors) {
      result.add(await _toSeries(anchor));
    }
    return result;
  }

  @override
  Future<ProtectedTimeSeries?> findProtectedSeries(String anchorId) async {
    final anchor =
        await (_database.select(_database.calendarEvents)
              ..where((row) => row.id.equals(anchorId))
              ..limit(1))
            .getSingleOrNull();
    if (anchor == null) return null;
    // **不接受例外行**：拿一个例外 id 当系列打开会让编辑页改到错误的规则上。
    if (anchor.exceptionOfId != null) return null;
    if (anchor.kind != CalendarEventKind.protected.storageValue) return null;
    return _toSeries(anchor);
  }

  Future<ProtectedTimeSeries> _toSeries(db.CalendarEvent anchor) async {
    final ruleId = anchor.recurrenceRuleId;
    db.RecurrenceRule? rule;
    if (ruleId != null) {
      rule =
          await (_database.select(_database.recurrenceRules)
                ..where((row) => row.id.equals(ruleId))
                ..limit(1))
              .getSingleOrNull();
    }

    final localStart = _zones.toLocal(
      DateTime.fromMicrosecondsSinceEpoch(anchor.startAtUtc, isUtc: true),
      anchor.timeZoneId,
    );
    final duration =
        (anchor.endAtUtc - anchor.startAtUtc) ~/ Duration.microsecondsPerMinute;

    final series = ProtectedTimeSeries(
      anchorId: anchor.id,
      title: anchor.title,
      timeZoneId: anchor.timeZoneId,
      startMinute:
          rule?.localStartMinute ?? (localStart.hour * 60 + localStart.minute),
      endMinute: rule?.localStartMinute != null
          ? rule!.localStartMinute + rule.durationMinutes
          : localStart.hour * 60 + localStart.minute + duration,
      weekdays: rule == null ? const {} : _weekdays(rule.weekdaysMask),
      intervalWeeks: rule?.intervalWeeks ?? 1,
      validFromLocalDate: rule == null
          ? DateTime(localStart.year, localStart.month, localStart.day)
          : DateTime.parse(rule.validFromLocalDate),
      validUntilLocalDate: rule?.validUntilLocalDate == null
          ? null
          : DateTime.parse(rule!.validUntilLocalDate!),
      notes: anchor.notes,
      updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        anchor.updatedAtUtc,
        isUtc: true,
      ),
    );

    // 例外日期：管理页要能说"其中有 M 次是你单独调过的"。
    final exceptions = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.equals(anchor.id))).get();
    final zoneId = rule?.timeZoneId ?? anchor.timeZoneId;
    series.exceptionDates = [
      for (final row in exceptions)
        _dateOnly(
          _zones.toLocal(
            DateTime.fromMicrosecondsSinceEpoch(row.startAtUtc, isUtc: true),
            zoneId,
          ),
        ),
    ];
    return series;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

/// 把 `weekdays_mask` 还原成 `DateTime.monday`…`sunday` 的集合。
Set<int> _weekdays(int mask) => {
  for (var day = DateTime.monday; day <= DateTime.sunday; day++)
    if (mask & (1 << (day - 1)) != 0) day,
};
