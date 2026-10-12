import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';

/// `CourseSeriesRepository` 的 Drift 实现（1.8.0，设计规范 §10.3）。
///
/// **聚合的键是 `logicalCourseId`，不是标题**：两个班的"高等数学(上)"是两门课。
/// 用标题当键会让"管理这门课"打开错的那一门，而用户改的是另一门课的时间表。
///
/// **学期从 `timetable_import_batches.term_id` 反查**：`calendar_events` 上没有 `term_id`
/// 列（它只有 `import_batch_id`），学期是批次上的属性。这不是绕路——同一个批次里的课天然
/// 属于同一个学期，而"这门课属于哪个学期"这个问题只有批次能回答。
final class DriftCourseSeriesRepository implements CourseSeriesRepository {
  // **为什么不用 `this._clock` 那种初始化形参**：这些字段全是**私有**的，而 `this._x`
  // 会让形参名变成 `_x`——调用方就得写 `DriftCourseSeriesRepository(db, _clock: …)`，
  // 把一个实现细节漏进公开 API。与 `RecurringTaskService` 同一条约定。
  // ignore_for_file: prefer_initializing_formals
  DriftCourseSeriesRepository(
    this._database, {
    required Clock clock,
    required TimeZoneDatabase zones,
    required String timeZoneId,
  }) : _clock = clock,
       _zones = zones,
       _timeZoneId = timeZoneId;

  final AppDatabase _database;
  final Clock _clock;
  final TimeZoneDatabase _zones;
  final String _timeZoneId;

  /// 学期 id → 该学期第一周周一的本地日期字符串。
  ///
  /// 一次查全表后缓存（学期只有个位数行），避免每个片段各查一次变成 N+1。
  Map<String, String> _termFirstMondays = const {};

  /// 学期 id → 总周数。`outsideTerm` 判定要用。
  Map<String, int> _termTotalWeeks = const {};

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async {
    await _loadTerms();
    final rows = await _importedCourseRows();
    final grouped = <String, List<_CourseRow>>{};
    for (final row in rows) {
      final logicalId = row.event.logicalCourseId;
      if (logicalId == null) continue;
      (grouped[logicalId] ??= []).add(row);
    }

    final courses = <CourseSeriesSummary>[];
    for (final entry in grouped.entries) {
      final summary = _summarize(entry.key, entry.value);
      if (summary == null) continue;
      // 按学期过滤：`termId` 为空表示"全部学期"。
      if (termId != null && summary.termId != termId) continue;
      courses.add(summary);
    }
    // 排序在 SQL 之外定死：列表顺序不得依赖数据库返回顺序（与仓储层其它处同一口径）。
    courses.sort((a, b) {
      final byWeekday = a.weekday.compareTo(b.weekday);
      if (byWeekday != 0) return byWeekday;
      final byStart = a.startMinute.compareTo(b.startMinute);
      if (byStart != 0) return byStart;
      final byTitle = a.title.compareTo(b.title);
      if (byTitle != 0) return byTitle;
      return a.logicalCourseId.compareTo(b.logicalCourseId);
    });
    return courses;
  }

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async {
    await _loadTerms();
    final rows = [
      for (final row in await _importedCourseRows())
        if (row.event.logicalCourseId == logicalCourseId) row,
    ];
    if (rows.isEmpty) return null;
    final summary = _summarize(logicalCourseId, rows);
    if (summary == null) return null;
    final ordered = [...rows]..sort(_compareRows);
    return CourseSeriesDetail(
      summary: summary,
      segments: [for (final row in ordered) _toSegment(row)],
    );
  }

  @override
  Future<String?> currentTermId() async {
    final terms = await _database.select(_database.academicTerms).get();
    if (terms.isEmpty) return null;
    final now = _zones.toLocal(_clock.nowUtc(), _timeZoneId);
    final today = DateTime(now.year, now.month, now.day);
    // 先找"今天正落在其中"的学期。**多个学期同时命中时取最晚开始的**：
    // 重叠的学期数据（用户手工建的）里，正在进行的那个才是他关心的。
    final covering =
        [
          for (final row in terms)
            if (!today.isBefore(DateTime.parse(row.firstWeekMondayLocalDate)) &&
                !today.isAfter(
                  DateTime.parse(row.firstWeekMondayLocalDate)
                      .add(Duration(days: row.totalWeeks * 7 - 1)),
                ))
              row,
        ]..sort(
          (a, b) =>
              b.firstWeekMondayLocalDate.compareTo(a.firstWeekMondayLocalDate),
        );
    if (covering.isNotEmpty) return covering.first.id;

    // **落在学期之间时返回最近一个已开始的学期**，而不是 `null`：假期里打开管理页
    // 应当看到"刚过去那一学期"的课，而不是一个空页面。一个都没开始时才返回 `null`。
    final started =
        [
          for (final row in terms)
            if (!DateTime.parse(row.firstWeekMondayLocalDate).isAfter(today))
              row,
        ]..sort(
          (a, b) =>
              b.firstWeekMondayLocalDate.compareTo(a.firstWeekMondayLocalDate),
        );
    return started.isEmpty ? null : started.first.id;
  }

  Future<void> _loadTerms() async {
    final terms = await _database.select(_database.academicTerms).get();
    _termFirstMondays = {
      for (final row in terms) row.id: row.firstWeekMondayLocalDate,
    };
    _termTotalWeeks = {for (final row in terms) row.id: row.totalWeeks};
  }

  /// 全部**课表导入来的**锚点事件及其重复规则与学期。
  ///
  /// 三个过滤条件缺一不可：
  /// - `logicalCourseId IS NOT NULL`：手工固定日程没有它，不属于"课程管理"；
  /// - `exceptionOfId IS NULL`：例外行是某一次的改写，不是系列锚点（把它算成一段会让
  ///   "整个课程"删除时多删一次、或把一次改写当成独立课程）；
  /// - `recurrenceRuleId IS NOT NULL`：没有重复规则的课程就是一条单次日程，
  ///   它的次数是 1、无所谓"系列片段"。
  Future<List<_CourseRow>> _importedCourseRows() async {
    final batches = {
      for (final row
          in await _database.select(_database.timetableImportBatches).get())
        row.id: row.termId,
    };

    final query =
        _database.select(_database.calendarEvents).join([
          innerJoin(
            _database.recurrenceRules,
            _database.recurrenceRules.id.equalsExp(
              _database.calendarEvents.recurrenceRuleId,
            ),
          ),
        ])..where(
          _database.calendarEvents.logicalCourseId.isNotNull() &
              _database.calendarEvents.exceptionOfId.isNull(),
        );

    return [
      for (final row in await query.get())
        _CourseRow(
          event: row.readTable(_database.calendarEvents),
          rule: row.readTable(_database.recurrenceRules),
          termId:
              batches[row.readTable(_database.calendarEvents).importBatchId],
        ),
    ];
  }

  /// 把一组系列片段聚合成一门课。
  ///
  /// 代表片段取**排序后的第一条**（开始分钟 → 间隔周数 → 事件 id）：顺序必须确定，
  /// 否则同一次点击可能打开不同的片段，而"改整个课程"的预览数字也会跳。
  CourseSeriesSummary? _summarize(String logicalId, List<_CourseRow> rows) {
    if (rows.isEmpty) return null;
    final ordered = [...rows]..sort(_compareRows);
    final head = ordered.first;
    return CourseSeriesSummary(
      logicalCourseId: logicalId,
      title: head.event.title,
      termId: head.termId,
      anchorEventIds: [for (final row in ordered) row.event.id],
      // 代表星期取**代表片段里最小的那个**（多星期规则的代表值）。
      weekday: _weekdays(head.rule.weekdaysMask)
          .reduce((a, b) => a < b ? a : b),
      startMinute: head.rule.localStartMinute,
      endMinute: head.rule.localStartMinute + head.rule.durationMinutes,
      // **逐个片段各算一次周次**：两条规则（单周一条、双周一条）的起止周不同，
      // 若整门课只算一条，摘要里的周次范围就会漏掉一半。
      weekSpans: [
        for (final row in ordered)
          _weekSpanOf(row.rule, termFirstMonday: _termFirstMondayFor(row)),
      ],
      areaId: head.event.areaId,
      projectId: head.event.projectId,
      location: head.event.location,
      teacher: head.event.notes,
      importBatchId: head.event.importBatchId,
      // 课表导入的课没有"归档"概念（那要另加一列，本批次不做）；因此默认在生成。
      enabled: true,
    );
  }

  CourseSeriesSegment _toSegment(_CourseRow row) {
    final termFirstMonday = _termFirstMondayFor(row);
    final weekSpan = _weekSpanOf(row.rule, termFirstMonday: termFirstMonday);
    return CourseSeriesSegment(
      eventId: row.event.id,
      title: row.event.title,
      weekdays: _weekdays(row.rule.weekdaysMask),
      startMinute: row.rule.localStartMinute,
      endMinute: row.rule.localStartMinute + row.rule.durationMinutes,
      intervalWeeks: row.rule.intervalWeeks,
      validFromLocalDate: DateTime.parse(row.rule.validFromLocalDate),
      validUntilLocalDate: row.rule.validUntilLocalDate == null
          ? null
          : DateTime.parse(row.rule.validUntilLocalDate!),
      location: row.event.location,
      areaId: row.event.areaId,
      projectId: row.event.projectId,
      weekSpan: weekSpan,
      outsideTerm: _outsideTerm(row, weekSpan),
      updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.event.updatedAtUtc,
        isUtc: true,
      ),
    );
  }

  /// 这门课所属学期的第一周周一。学期未知时返回 `null`。
  ///
  /// 单双周的判定基准是它——没有基准就只能保守地报 `every`（见 [_weekSpanOf]）。
  DateTime? _termFirstMondayFor(_CourseRow row) {
    final termId = row.termId;
    if (termId == null) return null;
    final first = _termFirstMondays[termId];
    return first == null ? null : DateTime.parse(first);
  }

  static int _compareRows(_CourseRow a, _CourseRow b) {
    final byStart = a.rule.localStartMinute.compareTo(b.rule.localStartMinute);
    if (byStart != 0) return byStart;
    final byInterval = a.rule.intervalWeeks.compareTo(b.rule.intervalWeeks);
    if (byInterval != 0) return byInterval;
    return a.event.id.compareTo(b.event.id);
  }

  /// 把重复规则还原成"第几周到第几周、单双周"。
  ///
  /// **`intervalWeeks == 1` 就是"每周"**；`2` 需要区分单双——判据是**起点那一周在学期里的
  /// 奇偶**。这是导入时拆分的逆运算，读的时候必须用同一条判据，否则管理页会把单周显示成双周。
  ///
  /// ## 周次必须是**学期坐标**里的真实位置（课程与保护时间管理修复计划 Task 3）
  ///
  /// 修复前这里把 `startWeek` 写死为 1、`endWeek` 写成"跨了几周"：
  ///
  /// ```dart
  /// startWeek: 1,
  /// endWeek: spanWeeks,     // 规则自己跨了几周，不是"到学期第几周"
  /// ```
  ///
  /// 规则"第 5 周到第 12 周"因此显示成"第 1 周到第 8 周"。用户看到的课表周次是错的，
  /// 而更糟的是**编辑页会按这个错误范围保存回去**——保存一次课就被挪到开学那几周。
  ///
  /// 现在按学期第一周周一算真实 offset：
  /// - `startWeek = (validFrom - termFirstMonday) / 7 + 1`
  /// - `endWeek = (validUntil - termFirstMonday) / 7 + 1`
  ///
  /// **学期未知时（`termId == null`）只允许显示日期范围**：没有基准就报不出周次，
  /// 因此 `startWeek`／`endWeek` 都用 1、parity 用 `every`——
  /// 计划 Task 3 Step 2 明确"未知学期只允许显示日期范围，不允许伪造『第 1 周开始』"，
  /// 因此调用方必须看 [CourseSeriesSegment.outsideTerm] 与 `termId` 一起判断。
  WeekSpan _weekSpanOf(RecurrenceRule rule, {DateTime? termFirstMonday}) {
    final first = DateTime.parse(rule.validFromLocalDate);
    final last = rule.validUntilLocalDate == null
        ? first
        : DateTime.parse(rule.validUntilLocalDate!);
    if (termFirstMonday == null) {
      // 没有学期基准：报"每周"是最保守的（误报成单双周会让用户以为这周没课）。
      return const WeekSpan(startWeek: 1, endWeek: 1, parity: WeekParity.every);
    }
    final firstMonday = _dateOnly(termFirstMonday);
    // **先算原始偏移，再统一夹紧到"第 1 周之后"**。
    //
    // 顺序很重要：如果先把 `startWeek` 夹到 1、再用未夹紧的 `endWeek` 构造，
    // 那么"规则起点早于学期开始"（例如春季批次里的规则沿用了更早的日期）会得到
    // `endWeek < startWeek`，而 `WeekSpan` 的断言直接抛错——实测
    // `'endWeek >= startWeek': is not true`。夹具里这种"起点早于学期"的形状
    // 在真实数据里也会出现（导入批次与学期日期不同步时）。
    final rawStart = _weekOffset(firstMonday, first) + 1;
    final rawEnd = _weekOffset(firstMonday, last) + 1;
    final startWeek = rawStart < 1 ? 1 : rawStart;
    final endWeek = rawEnd < startWeek ? startWeek : rawEnd;
    if (rule.intervalWeeks <= 1) {
      return WeekSpan(
        startWeek: startWeek,
        endWeek: endWeek,
        parity: WeekParity.every,
      );
    }
    return WeekSpan(
      startWeek: startWeek,
      endWeek: endWeek,
      // 起点那一周在学期里的奇偶决定单双：第 1、3、5…周 = 单周。
      parity: startWeek.isOdd ? WeekParity.odd : WeekParity.even,
    );
  }

  /// 规则有效期是否**超出了学期总周数**（计划 Task 3 Step 4）。
  ///
  /// 读取时**不夹紧**：夹紧会让"这门课其实排到了学期外"在编辑页上完全看不见，
  /// 用户一保存就把它永久改成学期内。这里只置标志，由编辑页提示修正。
  bool _outsideTerm(_CourseRow row, WeekSpan span) {
    final termId = row.termId;
    if (termId == null) return false;
    final total = _termTotalWeeks[termId];
    if (total == null) return false;
    return span.startWeek < 1 || span.endWeek > total;
  }

  /// 从 [firstMonday] 到 [date] 跨了几个本地周（同周为 0）。
  ///
  /// **按本地日期算，不按 24 小时倍数算**：夏令时切换那一周只有 167 或 169 小时，
  /// 用 `inDays ~/ 7` 会把那一周算错一周，而"第几周"正是要显示给用户的东西。
  static int _weekOffset(DateTime firstMonday, DateTime date) {
    final from = _dateOnly(firstMonday);
    final to = _dateOnly(date);
    return to.difference(from).inDays ~/ DateTime.daysPerWeek;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

final class _CourseRow {
  const _CourseRow({
    required this.event,
    required this.rule,
    required this.termId,
  });
  final CalendarEvent event;
  final RecurrenceRule rule;
  final String? termId;
}

/// 把 `recurrence_rules.weekdays_mask` 还原成 `DateTime.monday`…`sunday` 的集合。
///
/// **与 `DriftCalendarRepository` 里那个同名函数读同一个约定**（周一是 bit 0）：
/// 两处各写一份会让"哪一位是哪一天"在两个方向上不一致，而那种不一致只在跨周几的
/// 课上才显形。
Set<int> _weekdays(int mask) => {
  for (var day = DateTime.monday; day <= DateTime.sunday; day++)
    if (mask & (1 << (day - 1)) != 0) day,
};
