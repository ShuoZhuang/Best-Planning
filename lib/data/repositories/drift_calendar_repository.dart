import 'package:drift/drift.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart' as domain;
import 'package:personal_planner/domain/models/calendar_event_edit.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/domain/services/recurrence_expander.dart';
import 'package:personal_planner/domain/services/recurrence_membership.dart';

final class DriftCalendarRepository
    implements
        CalendarRepository,
        RecurringCalendarRepository,
        CalendarEventDeletion,
        CourseWriteGateway {
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
          projectId: row.projectId,
          location: row.location,
          notes: row.notes,
          sourceKind: domain.CalendarEventSourceKind.fromStorage(
            row.sourceKind,
          ),
          kind: domain.CalendarEventKind.fromStorage(row.kind),
          importBatchId: row.importBatchId,
          logicalCourseId: row.logicalCourseId,
          updatedAtUtc: _instant(row.updatedAtUtc),
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

    /// 锚点 id → 它的 `updated_at_utc`（Task 7 Step 4 的乐观并发依据）。
    final anchorUpdatedAt = <String, DateTime>{};
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
                // **例外行自己的标题与备注**（Task 7 Step 1）：这就是"仅本次改名"
                // 唯一可能的落点——锚点标题套给每一次，例外只能覆盖它自己那一次。
                //
                // 例外行的标题由写入端从草稿复制，因此它总是有值；这里仍按可空传，
                // 因为"空标题"在数据上非法，而"没有覆盖"必须能表达。
                title: row.title.isEmpty ? null : row.title,
                notes: row.notes.isEmpty ? null : row.notes,
              ),
      );
    }

    for (final joined in await recurring.get()) {
      final event = joined.readTable(_database.calendarEvents);
      final stored = joined.readTable(_database.recurrenceRules);
      // **锚点的修订号要带出去**：编辑页拿到的每一个占用都要能回答
      // "我读到它时它是第几版"（Task 7 Step 4 的乐观并发）。
      anchorUpdatedAt[event.id] = _instant(event.updatedAtUtc);
      final rule = domain.RecurrenceRule(
        id: stored.id,
        weekdays: _weekdays(stored.weekdaysMask),
        localStartMinute: stored.localStartMinute,
        durationMinutes: stored.durationMinutes,
        intervalWeeks: stored.intervalWeeks,
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
            // **例外可以带自己的标题与备注**（Task 7 Step 1）："仅本次改名"就落在这里。
            // 没有覆盖时沿用锚点的值——这正是"改一次不该影响其它各次"的实现方式。
            title: occurrence.title ?? event.title,
            range: occurrence.range,
            locked: event.locked,
            areaId: event.areaId,
            projectId: event.projectId,
            location: event.location,
            notes: occurrence.notes ?? event.notes,
            sourceKind: domain.CalendarEventSourceKind.fromStorage(
              event.sourceKind,
            ),
            kind: domain.CalendarEventKind.fromStorage(event.kind),
            importBatchId: event.importBatchId,
            logicalCourseId: event.logicalCourseId,
            updatedAtUtc: anchorUpdatedAt[event.id],
            // 展开出来的：背后**一定有**一条规则。
            repeats: true,
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
  /// 改写整个系列（FR-CAL-02），见端口的文档说明。
  ///
  /// **草稿里的资料字段（标题、备注、地点、领域、项目、类别）逐项写下去**：
  /// 其中 `notes` 此前**根本没有写入路径**，而课表导入正用它存教师名——
  /// 于是"改一次系列"会把教师名原样保留，但用户想改它却也没地方改。
  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    RecurrenceEditDraft? recurrence,
    required DateTime updatedAtUtc,
    DateTime? updateExceptionsFromUtc,
    DateTime? expectedUpdatedAtUtc,
  }) async {
    if (!patch.endAtUtc.isAfter(patch.startAtUtc)) {
      throw ArgumentError('替换后的结束时刻必须晚于开始时刻');
    }
    // **读、核对、合并、写全在同一个事务里**（计划 Task 2 Step 3）：先读后写之间
    // 隔着一次 await，那段时间里别处完全可能改过这一条，而写入端会静默覆盖它。
    await _database.transaction(() async {
      final anchor = await _anchorRow(anchorId);
      _assertExpectedRevision(anchor, expectedUpdatedAtUtc);
      if (anchor == null) return;

      final ruleId = anchor.recurrenceRuleId;
      final stored = ruleId == null ? null : await _ruleRow(ruleId);

      final updatedEvent = _appliedTo(
        anchor: anchor,
        patch: patch,
        updatedAtUtc: updatedAtUtc,
        recurrenceRuleId: ruleId,
        // **事件时区与规则时区必须一致**（§3.0）。有规则时以规则为准：它才是展开器
        // 解释"本地钟点"的依据。
        timeZoneIdOverride: stored?.timeZoneId,
      );

      if (stored == null) {
        // 单次日程没有"系列"可言：改那一行即可；规则行缺失（正常路径由
        // `saveRecurring` 的事务保证）时同样只改锚点，不凭空造规则。
        await save(updatedEvent);
        return;
      }

      // **规则里的本地钟点必须跟着一起改**：否则锚点换了时间，展开器仍按旧钟点生成各次，
      // 结果是"第一次是新的、后面还是旧的"。
      //
      // 传了 [recurrence] 时连星期、间隔、有效期一起换（管理页改的就是整个系列）；
      // 没传时只换钟点，其余规则字段原样保留。
      final localStart = _zones.toLocal(patch.startAtUtc, stored.timeZoneId);
      final rule = domain.RecurrenceRule(
        id: stored.id,
        weekdays: recurrence?.weekdays ?? _weekdays(stored.weekdaysMask),
        localStartMinute: localStart.hour * 60 + localStart.minute,
        durationMinutes: patch.endAtUtc.difference(patch.startAtUtc).inMinutes,
        intervalWeeks: recurrence?.intervalWeeks ?? stored.intervalWeeks,
        validFromLocalDate:
            recurrence?.validFromLocalDate ??
            DateTime.parse(stored.validFromLocalDate),
        validUntilLocalDate:
            recurrence?.validUntilLocalDate ??
            (stored.validUntilLocalDate == null
                ? null
                : DateTime.parse(stored.validUntilLocalDate!)),
        timeZoneId: stored.timeZoneId,
      );

      await _saveRecurringRows(updatedEvent, rule);

      // **先清理不再属于新规则的例外**（§3.3），再给仍有效的未来例外级联改名。
      // 顺序不能反：先改名会把一条即将失效的例外也改名，然后才删掉它——多一次无谓写入。
      await _pruneInvalidatedExceptions(
        anchorId: anchorId,
        rule: rule,
        updatedAtUtc: updatedAtUtc,
      );

      final cutoff = updateExceptionsFromUtc;
      if (cutoff == null) return;
      final exceptions = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.equals(anchorId))).get();
      for (final row in exceptions) {
        final startUtc = _instant(row.startAtUtc);
        // 过去的例外不动。
        if (startUtc.isBefore(cutoff)) continue;
        // **删除例外（零长度行）不动**：跟着改标题会让它变成一条正常长度的行，
        // 用户单独删掉的那一次就凭空复活了。
        if (row.endAtUtc == row.startAtUtc) continue;
        await (_database.update(
          _database.calendarEvents,
        )..where((r) => r.id.equals(row.id))).write(
          db.CalendarEventsCompanion(
            title: Value(patch.title),
            notes: Value(patch.notes),
            updatedAtUtc: Value(updatedAtUtc.microsecondsSinceEpoch),
          ),
        );
      }
    });
  }

  /// 把一份**显式 patch** 套到既有锚点行上，得到要写下去的事件。
  ///
  /// ## 只有 patch 里出现的字段会被改写
  ///
  /// | 字段 | 来源 |
  /// | --- | --- |
  /// | `title`／`notes`／起止 | patch（用户明确提交的值） |
  /// | `location` | [FieldPatch.resolve]：patch 没给就保留锚点原值，`SetField('')` 才是清空 |
  /// | `areaId`／`projectId`／`kind`／`locked` | **锚点原值** |
  /// | `sourceKind`／`importBatchId`／`logicalCourseId` | **锚点原值**（课程身份） |
  /// | `timeZoneId` | 规则时区（有规则时）／锚点原值 |
  ///
  /// **它此前是一份"完整草稿"的套用**：草稿的每个字段都必须给值，于是日视图没有展示
  /// 的地点被写成空串、领域与项目被写成 `null`、类别被写成 `fixed`，而时区在缓存里
  /// 找不到时被写成 `UTC`。用户只改了一次钟点，课程就变成"未命名事项／无领域固定日程"
  /// 并且事件时区与规则时区不一致（计划 §1.1／C02–C06）。
  ///
  /// **[exceptionOfId] 传空串表示"清掉例外归属"**：`exception_of_id` 是指向
  /// `calendar_events.id` 的**外键**，写空串会直接违反约束（实测
  /// `SqliteException(787): FOREIGN KEY constraint failed`）。而"清掉"这个意图是真实存在的：
  /// 对单次日程执行"只改这一次"时，那一行会让它既是锚点又是别人的例外——
  /// 读取端两个方向都会把它算进去。因此空串在这里被翻译成 `null`。
  domain.CalendarEvent _appliedTo({
    required db.CalendarEvent anchor,
    required CalendarEventPatch patch,
    required DateTime updatedAtUtc,
    required String? recurrenceRuleId,
    String? id,
    String? exceptionOfId,
    String? timeZoneIdOverride,
  }) => domain.CalendarEvent(
    id: id ?? anchor.id,
    title: patch.title,
    startAtUtc: patch.startAtUtc,
    endAtUtc: patch.endAtUtc,
    // 时区取**权威值**：例外与系列改写用规则自己的时区（下方三条路径都传了覆盖值），
    // 单次日程用锚点自身的。patch 里没有时区字段，因此 C03 那条"UTC 兜底"在
    // 类型层面就不可能再发生。
    timeZoneId: timeZoneIdOverride ?? anchor.timeZoneId,
    recurrenceRuleId: recurrenceRuleId,
    exceptionOfId: (exceptionOfId == null || exceptionOfId.isEmpty)
        ? (exceptionOfId == null ? anchor.exceptionOfId : null)
        : exceptionOfId,
    locked: anchor.locked,
    // 以下四项**一律保留锚点原值**：日视图既没有展示也没有提交它们。
    areaId: anchor.areaId,
    projectId: anchor.projectId,
    location: patch.location.resolve(anchor.location),
    notes: patch.notes,
    sourceKind: domain.CalendarEventSourceKind.fromStorage(anchor.sourceKind),
    kind: domain.CalendarEventKind.fromStorage(anchor.kind),
    importBatchId: anchor.importBatchId,
    logicalCourseId: anchor.logicalCourseId,
    updatedAtUtc: updatedAtUtc,
  );

  /// 按 id 读锚点行（事务内用）。
  Future<db.CalendarEvent?> _anchorRow(String anchorId) =>
      (_database.select(_database.calendarEvents)
            ..where((row) => row.id.equals(anchorId))
            ..limit(1))
          .getSingleOrNull();

  Future<db.RecurrenceRule?> _ruleRow(String ruleId) =>
      (_database.select(_database.recurrenceRules)
            ..where((row) => row.id.equals(ruleId))
            ..limit(1))
          .getSingleOrNull();

  /// **事务内的乐观并发核对**（计划 Task 2 Step 3）。
  ///
  /// [expectedUpdatedAtUtc] 为空表示调用方没有读到过这一条（例如"撤销导入"这类
  /// 内部动作），此时保留既有的幂等语义：锚点不在了就当已经处理。
  void _assertExpectedRevision(
    db.CalendarEvent? anchor,
    DateTime? expectedUpdatedAtUtc,
  ) {
    if (expectedUpdatedAtUtc == null) return;
    if (anchor == null) throw const CalendarEditMissingException();
    if (anchor.updatedAtUtc != expectedUpdatedAtUtc.microsecondsSinceEpoch) {
      // **在任何写入之前抛出**：因此"别处已经改过"不会被这一次覆盖。
      throw const CalendarEditStaleException();
    }
  }

  /// 删除锚点名下**已经不再属于 [rule] 的逐次例外**（计划 §3.3／Task 8 Step 5）。
  ///
  /// **为什么必须在这里而不是保存之后**：缩短周次或改星期时，锚点往往会被
  /// `_matchSegment` 复用（它按星期集合与频率匹配）。旧规则下的例外留在库里，
  /// 而它们**不会**随着某一段的删除被清掉——下一次把周次扩回去，它们就“复活”成
  /// 用户没有预期的课次（C22／C23）。
  ///
  /// 判定用**目标规则自己的时区**把例外 `startAtUtc` 换算成本地日期，再交给
  /// [recurrenceIncludesLocalDate]。这与展开器读例外时用的是同一个函数、同一条换算，
  /// 因此"预览报的数字"与"这里删的行数"必然一致（§2.5）。
  Future<int> _pruneInvalidatedExceptions({
    required String anchorId,
    required domain.RecurrenceRule rule,
    required DateTime updatedAtUtc,
  }) async {
    final rows = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.equals(anchorId))).get();
    final doomed = <String>[
      for (final row in rows)
        if (!recurrenceIncludesLocalDate(
          rule,
          _zones.toLocal(_instant(row.startAtUtc), rule.timeZoneId),
        ))
          row.id,
    ];
    if (doomed.isEmpty) return 0;
    await (_database.delete(
      _database.calendarEvents,
    )..where((row) => row.id.isIn(doomed))).go();
    return doomed.length;
  }

  /// [countExceptionsInvalidatedBy] 的仓储实现（计划 Task 8 Step 3）。
  ///
  /// 只读：预览**不得**执行删除。锚点不存在时返回 0（与端口其它方法的幂等口径一致）。
  @override
  Future<int> countExceptionsInvalidatedBy({
    required String anchorEventId,
    required CourseScheduleDraft replacement,
    required String zoneId,
  }) async {
    final anchor = await _anchorRow(anchorEventId);
    if (anchor == null) return 0;
    final rule = domain.RecurrenceRule(
      id: anchor.recurrenceRuleId ?? '$anchorEventId-rule',
      weekdays: replacement.weekdays,
      localStartMinute: replacement.startMinute,
      durationMinutes: replacement.endMinute - replacement.startMinute,
      intervalWeeks: replacement.intervalWeeks,
      validFromLocalDate: replacement.validFromLocalDate,
      validUntilLocalDate: replacement.validUntilLocalDate,
      timeZoneId: zoneId,
    );
    final rows = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.equals(anchorEventId))).get();
    var count = 0;
    for (final row in rows) {
      if (!recurrenceIncludesLocalDate(
        rule,
        _zones.toLocal(_instant(row.startAtUtc), zoneId),
      )) {
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    RecurrenceEditDraft? recurrence,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
    DateTime? expectedUpdatedAtUtc,
  }) async {
    if (!patch.endAtUtc.isAfter(patch.startAtUtc)) {
      throw ArgumentError('替换后的结束时刻必须晚于开始时刻');
    }
    // **拆分也必须整体在一个事务里**（§3.0）：新系列写进去了、旧规则没截断，
    // 或者例外改归属失败，都会留下两段互相重叠的课。
    await _database.transaction(() async {
      final anchor = await _anchorRow(anchorId);
      _assertExpectedRevision(anchor, expectedUpdatedAtUtc);
      if (anchor == null) return;
      final ruleId = anchor.recurrenceRuleId;
      if (ruleId == null) {
        // 单次日程没有"从这一次起拆分"可言：等价于改整条。
        await _replaceSeriesInCurrentTransaction(
          anchorId: anchorId,
          anchor: anchor,
          patch: patch,
          recurrence: recurrence,
          updatedAtUtc: updatedAtUtc,
        );
        return;
      }
      final stored = await _ruleRow(ruleId);
      if (stored == null) return;
      final splitDate = _validatedSplitDate(stored, occurrenceStartUtc);
      final originalFrom = DateTime.parse(stored.validFromLocalDate);
      final originalUntil = stored.validUntilLocalDate == null
          ? null
          : DateTime.parse(stored.validUntilLocalDate!);
      final newLocalStart = _zones.toLocal(patch.startAtUtc, stored.timeZoneId);
      final newRule = domain.RecurrenceRule(
        id: newRuleId,
        weekdays: recurrence?.weekdays ?? _weekdays(stored.weekdaysMask),
        localStartMinute: newLocalStart.hour * 60 + newLocalStart.minute,
        durationMinutes: patch.endAtUtc.difference(patch.startAtUtc).inMinutes,
        intervalWeeks: recurrence?.intervalWeeks ?? stored.intervalWeeks,
        // **从所选的本地日期开始**，而不是沿用原规则的起点——否则新系列会把
        // 拆分日之前的各次再生成一遍。
        validFromLocalDate: splitDate,
        // 有效期沿用原规则的结束日（没传 recurrence 时）；传了就按新的，
        // 但**不得早于拆分日**（草稿校验已经挡过，这里再夹一次会因为静默夹紧而违规，
        // 因此直接采用草稿值，让上层报错）。
        validUntilLocalDate: recurrence?.validUntilLocalDate ?? originalUntil,
        timeZoneId: stored.timeZoneId,
      );
      final newEvent = _appliedTo(
        anchor: anchor,
        patch: patch,
        updatedAtUtc: updatedAtUtc,
        recurrenceRuleId: newRuleId,
        id: newEventId,
        exceptionOfId: null,
        // 新系列的锚点用**规则自己的时区**：展开器按它把起点换算成本地日期。
        timeZoneIdOverride: stored.timeZoneId,
      );
      final exceptions = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.equals(anchorId))).get();
      // **例外按规则自己的时区换算本地日期**，且必须在同一个事务里读：
      // 这次拆分之后，落在拆分日及以后的例外改挂到新锚点名下。
      final followingExceptionIds = <String>[
        for (final row in exceptions)
          if (!_dateOnly(
            _zones.toLocal(_instant(row.startAtUtc), stored.timeZoneId),
          ).isBefore(splitDate))
            row.id,
      ];

      await _saveRecurringRows(newEvent, newRule);
      for (final id in followingExceptionIds) {
        await (_database.update(
          _database.calendarEvents,
        )..where((row) => row.id.equals(id))).write(
          db.CalendarEventsCompanion(
            exceptionOfId: Value(newEventId),
            updatedAtUtc: Value(updatedAtUtc.microsecondsSinceEpoch),
          ),
        );
      }
      if (splitDate == originalFrom) {
        await (_database.delete(
          _database.calendarEvents,
        )..where((row) => row.id.equals(anchorId))).go();
        await (_database.delete(
          _database.recurrenceRules,
        )..where((row) => row.id.equals(ruleId))).go();
      } else {
        await (_database.update(
          _database.recurrenceRules,
        )..where((row) => row.id.equals(ruleId))).write(
          db.RecurrenceRulesCompanion(
            validUntilLocalDate: Value(
              _date(splitDate.subtract(const Duration(days: 1))),
            ),
            updatedAtUtc: Value(updatedAtUtc.microsecondsSinceEpoch),
          ),
        );
      }
    });
  }

  /// [replaceSeries] 的主体，供已经处在事务里的调用方复用。
  ///
  /// **不能直接调 `replaceSeries`**：Drift 的 `transaction()` 可以嵌套，但嵌套会让
  /// "锚点是从哪一层读到的"变得含糊，而这里要的恰恰是"在**同一个**事务里读、核对、写"。
  Future<void> _replaceSeriesInCurrentTransaction({
    required String anchorId,
    required db.CalendarEvent anchor,
    required CalendarEventPatch patch,
    RecurrenceEditDraft? recurrence,
    required DateTime updatedAtUtc,
  }) async {
    final ruleId = anchor.recurrenceRuleId;
    final stored = ruleId == null ? null : await _ruleRow(ruleId);
    final updatedEvent = _appliedTo(
      anchor: anchor,
      patch: patch,
      updatedAtUtc: updatedAtUtc,
      recurrenceRuleId: ruleId,
      timeZoneIdOverride: stored?.timeZoneId,
    );
    if (stored == null) {
      await save(updatedEvent);
      return;
    }
    final localStart = _zones.toLocal(patch.startAtUtc, stored.timeZoneId);
    final rule = domain.RecurrenceRule(
      id: stored.id,
      weekdays: recurrence?.weekdays ?? _weekdays(stored.weekdaysMask),
      localStartMinute: localStart.hour * 60 + localStart.minute,
      durationMinutes: patch.endAtUtc.difference(patch.startAtUtc).inMinutes,
      intervalWeeks: recurrence?.intervalWeeks ?? stored.intervalWeeks,
      validFromLocalDate:
          recurrence?.validFromLocalDate ??
          DateTime.parse(stored.validFromLocalDate),
      validUntilLocalDate:
          recurrence?.validUntilLocalDate ??
          (stored.validUntilLocalDate == null
              ? null
              : DateTime.parse(stored.validUntilLocalDate!)),
      timeZoneId: stored.timeZoneId,
    );
    await _saveRecurringRows(updatedEvent, rule);
    await _pruneInvalidatedExceptions(
      anchorId: anchorId,
      rule: rule,
      updatedAtUtc: updatedAtUtc,
    );
  }

  @override
  Future<void> setEventArea({
    required String eventId,
    required String? areaId,
    required DateTime updatedAtUtc,
  }) async {
    final anchor =
        await (_database.select(_database.calendarEvents)
              ..where((row) => row.id.equals(eventId))
              ..limit(1))
            .getSingleOrNull();
    // 与删除同一条幂等约定：行不在了就当已经处理。
    if (anchor == null) return;
    await save(
      domain.CalendarEvent(
        id: anchor.id,
        title: anchor.title,
        startAtUtc: _instant(anchor.startAtUtc),
        endAtUtc: _instant(anchor.endAtUtc),
        timeZoneId: anchor.timeZoneId,
        recurrenceRuleId: anchor.recurrenceRuleId,
        exceptionOfId: anchor.exceptionOfId,
        locked: anchor.locked,
        // 只改归属：其余字段原样带回，避免"改领域"顺带丢掉位置、备注或导入批次。
        areaId: areaId,
        projectId: anchor.projectId,
        location: anchor.location,
        notes: anchor.notes,
        sourceKind: domain.CalendarEventSourceKind.fromStorage(
          anchor.sourceKind,
        ),
        kind: domain.CalendarEventKind.fromStorage(anchor.kind),
        importBatchId: anchor.importBatchId,
        logicalCourseId: anchor.logicalCourseId,
        updatedAtUtc: updatedAtUtc,
      ),
    );
  }

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async {
    final anchor =
        await (_database.select(_database.calendarEvents)
              ..where((row) => row.id.equals(anchorId))
              ..limit(1))
            .getSingleOrNull();
    if (anchor == null) return;
    final ruleId = anchor.recurrenceRuleId;
    if (ruleId == null) {
      await deleteEvent(anchorId);
      return;
    }
    final stored =
        await (_database.select(_database.recurrenceRules)
              ..where((row) => row.id.equals(ruleId))
              ..limit(1))
            .getSingleOrNull();
    if (stored == null) return;
    final splitDate = _validatedSplitDate(stored, occurrenceStartUtc);
    final originalFrom = DateTime.parse(stored.validFromLocalDate);
    final exceptions = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.exceptionOfId.equals(anchorId))).get();
    final followingExceptionIds = <String>[
      for (final row in exceptions)
        if (!_dateOnly(
          _zones.toLocal(_instant(row.startAtUtc), stored.timeZoneId),
        ).isBefore(splitDate))
          row.id,
    ];

    await _database.transaction(() async {
      for (final id in followingExceptionIds) {
        await (_database.delete(
          _database.calendarEvents,
        )..where((row) => row.id.equals(id))).go();
      }
      if (splitDate == originalFrom) {
        await (_database.delete(
          _database.calendarEvents,
        )..where((row) => row.id.equals(anchorId))).go();
        await (_database.delete(
          _database.recurrenceRules,
        )..where((row) => row.id.equals(ruleId))).go();
      } else {
        await (_database.update(
          _database.recurrenceRules,
        )..where((row) => row.id.equals(ruleId))).write(
          db.RecurrenceRulesCompanion(
            validUntilLocalDate: Value(
              _date(splitDate.subtract(const Duration(days: 1))),
            ),
            updatedAtUtc: Value(updatedAtUtc.microsecondsSinceEpoch),
          ),
        );
      }
    });
  }

  /// 改写重复日程里的某一次（FR-CAL-02），见端口的文档说明。
  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    required String exceptionId,
    required DateTime updatedAtUtc,
    DateTime? expectedUpdatedAtUtc,
  }) async {
    if (!patch.endAtUtc.isAfter(patch.startAtUtc)) {
      throw ArgumentError('替换后的结束时刻必须晚于开始时刻');
    }
    await _database.transaction(() async {
      final anchor = await _anchorRow(anchorId);
      _assertExpectedRevision(anchor, expectedUpdatedAtUtc);
      // 锚点已经不在了：与删除同样按幂等处理（没有期望值时）。
      if (anchor == null) return;

      final ruleId = anchor.recurrenceRuleId;
      if (ruleId == null) {
        // 单次日程：直接改它自己那一行。"只改这一次"与"改整条"在单次日程上是同一件事，
        // 因此不必（也不该）留下一条替换例外——那会让这条日程变成"系列的一次"。
        //
        // **例外归属也要清掉**：这一行本身就是锚点，留着 `exceptionOfId` 会让它
        // "既是锚点又是别人的例外"，读取端两个方向都会把它算进去。
        await save(
          _appliedTo(
            anchor: anchor,
            patch: patch,
            updatedAtUtc: updatedAtUtc,
            recurrenceRuleId: null,
            exceptionOfId: '',
          ),
        );
        return;
      }

      final rule = await _ruleRow(ruleId);
      if (rule == null) return;

      // 同一天已有例外就**复用那一行的 id**：再写一条会让展开器按遍历顺序二选一，结果不确定。
      final localDate = _zones.toLocal(occurrenceStartUtc, rule.timeZoneId);
      var targetId = exceptionId;
      final existing = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.equals(anchorId))).get();
      for (final row in existing) {
        final rowDate = _zones.toLocal(
          _instant(row.startAtUtc),
          row.timeZoneId,
        );
        if (rowDate.year == localDate.year &&
            rowDate.month == localDate.month &&
            rowDate.day == localDate.day) {
          targetId = row.id;
          break;
        }
      }

      await save(
        _appliedTo(
          anchor: anchor,
          patch: patch,
          updatedAtUtc: updatedAtUtc,
          // 例外**不带规则**：它的语义就是"只这一次"。
          recurrenceRuleId: null,
          id: targetId,
          exceptionOfId: anchorId,
          // 用**规则自己的时区**：读取端按该时区把起点换算成本地日期来对齐例外。
          timeZoneIdOverride: rule.timeZoneId,
        ),
      );
    });
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
    final anchor =
        await (_database.select(_database.calendarEvents)
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

    final rule =
        await (_database.select(_database.recurrenceRules)
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
  Future<CourseDeletionResult> deleteSeriesWithExceptions({
    required Set<String> anchorEventIds,
    required DateTime deletedAtUtc,
  }) async {
    if (!deletedAtUtc.isUtc) {
      throw ArgumentError.value(deletedAtUtc, 'deletedAtUtc', 'Must be UTC.');
    }
    if (anchorEventIds.isEmpty) return CourseDeletionResult.empty;
    // **一个事务**（规范 §10.2：事务中任一写入失败时全部回滚）。事务内的顺序见端口文档：
    // 先读真实锚点 → 删例外 → 删锚点 → 只删已无引用的规则 → 标记批次状态。
    //
    // **顺序是刻意的**：`exception_of_id` 是指向 `calendar_events(id)` 的外键，
    // 先删锚点会让例外行立刻变成孤儿，而 `PRAGMA foreign_keys = ON` 会让那次删除整个失败。
    return _database.transaction(() async {
      // ① 读取目标锚点：只认库里**真实存在**的行。
      final anchors =
          await (_database.select(_database.calendarEvents)..where(
                (row) =>
                    row.id.isIn(anchorEventIds) &
                    // 只删系列锚点，不把某一次的例外当锚点删。
                    row.exceptionOfId.isNull(),
              ))
              .get();
      if (anchors.isEmpty) return CourseDeletionResult.empty;
      final realAnchorIds = {for (final anchor in anchors) anchor.id};
      final candidateRuleIds = {
        for (final anchor in anchors)
          if (anchor.recurrenceRuleId != null) anchor.recurrenceRuleId!,
      };
      final batchIds = {
        for (final anchor in anchors)
          if (anchor.importBatchId != null && anchor.importBatchId!.isNotEmpty)
            anchor.importBatchId!,
      };

      // ② 例外先删。
      final exceptions = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.isIn(realAnchorIds))).get();
      final exceptionIds = {for (final row in exceptions) row.id};
      if (exceptionIds.isNotEmpty) {
        await (_database.delete(
          _database.calendarEvents,
        )..where((row) => row.id.isIn(exceptionIds))).go();
      }

      // ③ 锚点后删。
      await (_database.delete(
        _database.calendarEvents,
      )..where((row) => row.id.isIn(realAnchorIds))).go();

      // ④ **逐个确认已无引用**再删规则：规则可以被多条锚点共享，
      //    "目标锚点引用过它"不等于"它只被目标锚点引用"。
      final deletedRuleIds = <String>{};
      for (final ruleId in candidateRuleIds) {
        final stillReferenced =
            await (_database.selectOnly(_database.calendarEvents)
                  ..addColumns([_database.calendarEvents.id.count()])
                  ..where(
                    _database.calendarEvents.recurrenceRuleId.equals(ruleId),
                  ))
                .getSingle();
        final references =
            stillReferenced.read(_database.calendarEvents.id.count()) ?? 0;
        if (references != 0) continue;
        await (_database.delete(
          _database.recurrenceRules,
        )..where((row) => row.id.equals(ruleId))).go();
        deletedRuleIds.add(ruleId);
      }

      // ⑤ **只转移允许的状态**：`committed → partiallyDeleted`；
      //    `partiallyDeleted` 保持；`rolledBack` 与 `draft` 不动（计划 Task 7 Step 4）。
      //    时间戳与课程删除同事务：不可能出现"课删了、批次还说完整"的中间态。
      var affectedBatches = 0;
      if (batchIds.isNotEmpty) {
        affectedBatches =
            await (_database.update(_database.timetableImportBatches)..where(
                  (row) =>
                      row.id.isIn(batchIds) &
                      row.status.equals(
                        TimetableImportBatchStatus.committed.storageValue,
                      ),
                ))
                .write(
                  db.TimetableImportBatchesCompanion(
                    status: Value(
                      TimetableImportBatchStatus.partiallyDeleted.storageValue,
                    ),
                    updatedAtUtc: Value(deletedAtUtc.microsecondsSinceEpoch),
                  ),
                );
      }

      return CourseDeletionResult(
        deletedAnchorIds: realAnchorIds,
        deletedExceptionIds: exceptionIds,
        deletedRuleIds: deletedRuleIds,
        affectedImportBatchIds: affectedBatches == 0 ? const {} : batchIds,
      );
    });
  }

  @override
  Future<int> countExceptions(String anchorEventId) async {
    final rows =
        await (_database.selectOnly(_database.calendarEvents)
              ..addColumns([_database.calendarEvents.id.count()])
              ..where(
                _database.calendarEvents.exceptionOfId.equals(anchorEventId),
              ))
            .getSingle();
    return rows.read(_database.calendarEvents.id.count()) ?? 0;
  }

  @override
  Future<void> replaceCourseSeries({
    required List<CourseWriteRow> rows,
    required CourseProfileDraft profile,
    required String zoneId,
    required DateTime updatedAtUtc,
    required CourseSeriesProvenance provenance,
    required String expectedFingerprint,
  }) async {
    // **非法组合在进入事务之前就拒绝**（Task 6 Step 4）：`timetableImport` 必须带批次，
    // `manual` 必须不带。放宽任何一条都会让 §3.1 的来源不变量在库里悄悄失效。
    if (!provenance.isConsistent) {
      throw ArgumentError.value(
        provenance.importBatchId,
        'provenance',
        'sourceKind 与 importBatchId 的组合非法',
      );
    }
    final courseLogicalId = profile.logicalCourseId;
    // **一个事务覆盖全部四种写入**：删旧片段、删旧规则、写新锚点、写新规则。
    // 拆成多次调用会留下"旧的删了、新的没建起来"的中间态——而排程按 drift 的 watch
    // 重算，用户会在他"只点了一下保存"的时候看到计划里少了几次课。
    await _database.transaction(() async {
      // **指纹在事务开始之后重算**（计划 Task 8 Step 6）：服务层在提交前比过一次，
      // 但那一次与真正开始写之间隔着界面确认，中间完全可能有人增删了一条逐次调整。
      // 重算的判据与读模型共用 `courseSeriesRevisionFingerprint()`，因此两处不可能漂开。
      final currentFingerprint = await _currentCourseFingerprint(
        courseLogicalId,
      );
      if (currentFingerprint != expectedFingerprint) {
        // 写第一行之前抛出 ⇒ **零写入**。
        throw const CourseSeriesStaleException();
      }

      // 既有锚点（本课程名下的全部片段）。要删的是**没有出现在最终形态里**的那些。
      final existing =
          await (_database.select(_database.calendarEvents)..where(
                (row) =>
                    row.logicalCourseId.equals(courseLogicalId) &
                    row.exceptionOfId.isNull(),
              ))
              .get();
      final keep = {
        for (final row in rows)
          if (row.reuseAnchorId != null) row.reuseAnchorId!,
      };
      final removed = {
        for (final row in existing)
          if (!keep.contains(row.id)) row.id,
      };
      if (removed.isNotEmpty) {
        // 先删例外行再删锚点行：`exception_of_id` 是外键，反过来会让孤儿行触发约束失败。
        await (_database.delete(
          _database.calendarEvents,
        )..where((row) => row.exceptionOfId.isIn(removed))).go();
        final removedRules = {
          for (final row in existing)
            if (removed.contains(row.id) && row.recurrenceRuleId != null)
              row.recurrenceRuleId!,
        };
        await (_database.delete(
          _database.calendarEvents,
        )..where((row) => row.id.isIn(removed))).go();
        if (removedRules.isNotEmpty) {
          // **只删已经没有任何锚点引用的规则**（Task 8 Step 5／§3.2 的同一条口径）：
          // 规则可以被多条锚点共享，无条件删除会打断别的片段。
          final stillReferenced =
              await (_database.selectOnly(_database.calendarEvents)
                    ..addColumns([_database.calendarEvents.recurrenceRuleId])
                    ..where(
                      _database.calendarEvents.recurrenceRuleId.isIn(
                        removedRules,
                      ),
                    ))
                  .get();
          final referenced = {
            for (final row in stillReferenced)
              row.read(_database.calendarEvents.recurrenceRuleId),
          };
          final orphaned = removedRules.difference(referenced);
          if (orphaned.isNotEmpty) {
            await (_database.delete(
              _database.recurrenceRules,
            )..where((row) => row.id.isIn(orphaned))).go();
          }
        }
      }

      for (final row in rows) {
        final draft = row.schedule;
        final anchorId = row.reuseAnchorId ?? '$courseLogicalId-${row.index}';
        // **规则 id 与锚点绑定**：沿用时保持既有的（展开器按它分组例外），
        // 新建时按锚点派生。两者都由这里决定，调用方不传——它没有足够信息。
        final existingRow = existing
            .where((candidate) => candidate.id == anchorId)
            .firstOrNull;
        final ruleId = existingRow?.recurrenceRuleId ?? '$anchorId-rule';

        final startUtc = _zones.localDateTimeToUtc(
          draft.validFromLocalDate,
          draft.startMinute,
          zoneId,
        );
        // **起止两端各按自己的分钟换算**，不用"起点 + 时长"相加：
        // 相加得到的是一个正确的绝对时刻，看起来对，但它与同一行的 `endMinute`
        // 表达的不是同一件事（后者是当天的分钟，跨午夜时会小于起点）。
        final endUtc = _zones.localDateTimeToUtc(
          draft.validFromLocalDate,
          draft.endMinute,
          zoneId,
        );

        await _saveRecurringRows(
          domain.CalendarEvent(
            id: anchorId,
            title: profile.title,
            startAtUtc: startUtc,
            endAtUtc: endUtc,
            timeZoneId: zoneId,
            recurrenceRuleId: ruleId,
            // **来源对全部最终锚点统一写入**（§2.1／Task 6 Step 5）：不再按
            // `existingRow == null` 决定，因此新增片段不会变成"手工来源"、
            // 也不会丢掉批次（C16、C17）。它同时保证课表导入的课在"撤销导入"里
            // 仍然找得到——那个功能按 `importBatchId` 回滚。
            sourceKind: provenance.sourceKind,
            importBatchId: provenance.importBatchId,
            logicalCourseId: courseLogicalId,
            location: profile.location,
            // **教师存在 `notes` 列**：本批次不引入"课程备注"这个新概念。
            notes: profile.teacher,
            areaId: profile.areaId,
            projectId: profile.projectId,
            updatedAtUtc: updatedAtUtc,
          ),
          domain.RecurrenceRule(
            id: ruleId,
            weekdays: draft.weekdays,
            localStartMinute: draft.startMinute,
            durationMinutes: draft.endMinute - draft.startMinute,
            intervalWeeks: draft.intervalWeeks,
            validFromLocalDate: draft.validFromLocalDate,
            validUntilLocalDate: draft.validUntilLocalDate,
            timeZoneId: zoneId,
          ),
        );
      }
    });
  }

  /// 当前库里这门课的**规范化指纹**（计划 Task 8 Step 6）。
  ///
  /// 它与 `DriftCourseSeriesRepository` 读出来的 `CourseSeriesDetail.revisionFingerprint`
  /// 必须是逐字节相同的字符串：两处都调用
  /// `courseSeriesRevisionFingerprint()` ＋ `exceptionRevisionFingerprint()`，
  /// 因此"预览时报的数字"与"保存时判的过期"用的是同一条判据。
  ///
  /// 只读、无副作用；在写事务里调用，因此它看到的就是即将被改写的那一版。
  Future<String> _currentCourseFingerprint(String logicalCourseId) async {
    final anchors =
        await (_database.select(_database.calendarEvents).join([
              innerJoin(
                _database.recurrenceRules,
                _database.recurrenceRules.id.equalsExp(
                  _database.calendarEvents.recurrenceRuleId,
                ),
              ),
            ])..where(
              _database.calendarEvents.logicalCourseId.equals(logicalCourseId) &
                  _database.calendarEvents.exceptionOfId.isNull(),
            ))
            .get();
    final exceptionLists =
        <
          String,
          List<
            ({
              String id,
              int startAtUtc,
              int endAtUtc,
              String timeZoneId,
              int updatedAtUtc,
            })
          >
        >{};
    if (anchors.isNotEmpty) {
      final anchorIds = {
        for (final row in anchors) row.readTable(_database.calendarEvents).id,
      };
      final exceptions = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.isIn(anchorIds))).get();
      for (final row in exceptions) {
        (exceptionLists[row.exceptionOfId!] ??= []).add((
          id: row.id,
          startAtUtc: row.startAtUtc,
          endAtUtc: row.endAtUtc,
          timeZoneId: row.timeZoneId,
          updatedAtUtc: row.updatedAtUtc,
        ));
      }
    }
    return courseSeriesRevisionFingerprint([
      for (final joined in anchors)
        CourseSeriesSegment(
          eventId: joined.readTable(_database.calendarEvents).id,
          title: joined.readTable(_database.calendarEvents).title,
          timeZoneId: joined.readTable(_database.recurrenceRules).timeZoneId,
          weekdays: _weekdays(
            joined.readTable(_database.recurrenceRules).weekdaysMask,
          ),
          startMinute: joined
              .readTable(_database.recurrenceRules)
              .localStartMinute,
          endMinute:
              joined.readTable(_database.recurrenceRules).localStartMinute +
              joined.readTable(_database.recurrenceRules).durationMinutes,
          intervalWeeks: joined
              .readTable(_database.recurrenceRules)
              .intervalWeeks,
          validFromLocalDate: DateTime.parse(
            joined.readTable(_database.recurrenceRules).validFromLocalDate,
          ),
          validUntilLocalDate: switch (joined
              .readTable(_database.recurrenceRules)
              .validUntilLocalDate) {
            null => null,
            final value => DateTime.parse(value),
          },
          updatedAtUtc: _instant(
            joined.readTable(_database.calendarEvents).updatedAtUtc,
          ),
          exceptionRevisionFingerprint: exceptionRevisionFingerprint(
            exceptionLists[joined.readTable(_database.calendarEvents).id] ??
                const [],
          ),
        ),
    ]);
  }

  @override
  Future<void> saveRecurring(
    domain.CalendarEvent event,
    domain.RecurrenceRule rule,
  ) {
    if (event.recurrenceRuleId != rule.id) {
      throw ArgumentError('Event and recurrence rule ids must match.');
    }
    return _database.transaction(() => _saveRecurringRows(event, rule));
  }

  Future<void> _saveRecurringRows(
    domain.CalendarEvent event,
    domain.RecurrenceRule rule,
  ) async {
    final modifiedAt = event.updatedAtUtc.microsecondsSinceEpoch;
    await _database
        .into(_database.recurrenceRules)
        .insert(
          db.RecurrenceRulesCompanion(
            id: Value(rule.id),
            weekdaysMask: Value(_weekdaysMask(rule.weekdays)),
            localStartMinute: Value(rule.localStartMinute),
            durationMinutes: Value(rule.durationMinutes),
            intervalWeeks: Value(rule.intervalWeeks),
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
              intervalWeeks: Value(rule.intervalWeeks),
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
  }

  DateTime _validatedSplitDate(
    db.RecurrenceRule rule,
    DateTime occurrenceStartUtc,
  ) {
    if (!occurrenceStartUtc.isUtc) {
      throw ArgumentError.value(
        occurrenceStartUtc,
        'occurrenceStartUtc',
        'Must be UTC.',
      );
    }
    final splitDate = _dateOnly(
      _zones.toLocal(occurrenceStartUtc, rule.timeZoneId),
    );
    final first = DateTime.parse(rule.validFromLocalDate);
    final last = rule.validUntilLocalDate == null
        ? null
        : DateTime.parse(rule.validUntilLocalDate!);
    final weekOffset =
        _weekMonday(splitDate).difference(_weekMonday(first)).inDays ~/ 7;
    final valid =
        !splitDate.isBefore(first) &&
        (last == null || !splitDate.isAfter(last)) &&
        _weekdays(rule.weekdaysMask).contains(splitDate.weekday) &&
        weekOffset >= 0 &&
        weekOffset % rule.intervalWeeks == 0;
    if (!valid) {
      throw ArgumentError.value(
        occurrenceStartUtc,
        'occurrenceStartUtc',
        'The selected instant is not an occurrence of this series.',
      );
    }
    return splitDate;
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
            projectId: Value(event.projectId),
            location: Value(event.location),
            notes: Value(event.notes),
            kind: Value(event.kind.storageValue),
            sourceKind: Value(event.sourceKind.storageValue),
            importBatchId: Value(event.importBatchId),
            logicalCourseId: Value(event.logicalCourseId),
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
              projectId: Value(event.projectId),
              location: Value(event.location),
              notes: Value(event.notes),
              kind: Value(event.kind.storageValue),
              sourceKind: Value(event.sourceKind.storageValue),
              importBatchId: Value(event.importBatchId),
              logicalCourseId: Value(event.logicalCourseId),
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

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _weekMonday(DateTime value) {
  final date = _dateOnly(value);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}
