import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/academic_calendar_repository.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';

/// 课程管理的作用范围（规范 §10.2）。
///
/// **与 `EventEditScope` 分开而不是复用**：那个枚举的第三个值是 `entireSeries`
/// （"整个系列"＝一个锚点与它的重复规则），而这里需要的是 `entireCourse`
/// （"整个课程"＝**当前学期内该 `logicalCourseId` 的全部系列片段**）。
/// 两者在单片段课程上恰好等价，在多片段课程（单双周被拆成两条规则）上完全不同——
/// 复用会让"改整个课程"只改到单周那一半。
enum CourseEditScope { thisOccurrence, followingOccurrences, entireCourse }

/// 改课程时间时会撞上的**既有占用**属于哪一类（1.8.0，规范 §10.2 最后一条）。
///
/// **为什么要分类而不是只报"有冲突"**：四类的处置方式完全不同——
/// 固定日程要让路、保护时间根本不能碰、同一门课自己的片段是**必须**修的数据问题、
/// 别的课则可以协商。混成一句"有冲突"等于没告诉用户该做什么。
enum CourseTimeConflictKind {
  /// 撞上固定日程。
  fixedEvent,

  /// 撞上保护时间。**这一类最严重**：它的语义是"这段时间不许安排"。
  protectedTime,

  /// 撞上**同一门课自己的**另一个片段（改完之后这门课和自己撞了）。
  sameCourse,

  /// 撞上别的课程。
  otherCourse,
}

/// 这条冲突是否**硬阻断保存**（设计规范 §10.2 末条／计划 Task 10 Step 3）。
///
/// 计划原文："修改时间后先显示冲突，再允许返回修改；**硬冲突不能直接保存**。"
///
/// 划分依据是**语义**而不是严重程度的主观排序：
///
/// - `protectedTime` 与 `fixedEvent` 是**用户已经确定的其他安排**。让"确认一次"就覆盖
///   它们，等于把保护时间降级成建议——而它的语义正是"这段时间不许安排"。
/// - `otherCourse` 与 `sameCourse` 是**课表内部的拥挤**。两门课在同一时段、或同一门课的
///   两段相接，在真实课表里是常态（不同周次、单双周、用户就是要这样排）。
///   做成硬阻断会让用户**根本无法保存自己真实的课表**，那比冲突本身更严重。
bool isBlockingCourseTimeConflict(CourseTimeConflict? conflict) =>
    switch (conflict?.kind) {
      CourseTimeConflictKind.protectedTime => true,
      CourseTimeConflictKind.fixedEvent => true,
      CourseTimeConflictKind.sameCourse => false,
      CourseTimeConflictKind.otherCourse => false,
      null => false,
    };

/// 一条"改课程时间会撞上谁"的记录。
final class CourseTimeConflict {
  const CourseTimeConflict({
    required this.kind,
    required this.title,
    required this.range,
    required this.otherEventId,
    required this.proposedEventId,
  });

  final CourseTimeConflictKind kind;

  /// 对方事项的**标题**。
  ///
  /// **绝不放 id**（规范全局不变量第 7 条）：用户不认识 uuid，而他要做的是去改那一项。
  final String title;

  /// 对方占用的时间区间。
  final TimeRange range;

  final String otherEventId;

  /// 我方哪一段改动撞上了它——多片段课程要能指出是哪一个。
  final String proposedEventId;
}

/// 检测"把课程改到这些新时段"会撞上哪些既有占用（1.8.0，规范 §10.2 最后一条）。
///
/// 纯函数：给定**提议的新时段**与**库里的既有占用**，返回冲突清单。
/// 界面只负责把它显示出来——因此这条规则可以脱离界面逐值验证。
///
/// **三个参数的分工**（第一版把它们混成一个 `ownEventIds`，结果 `sameCourse` **永远不可能**
/// 触发——因为"属于本课程"的既有一律被提前跳过了）：
/// - [editingEventId]：**被编辑的那一个锚点**。它自己的旧位置必须排除，
///   否则"把课往后挪"会永远与"它自己原来的位置"冲突，于是任何改动都不可能通过；
/// - [sameCourseEventIds]：这门课**其它片段**的 id。它们**不能**排除——
///   "改完之后这门课和自己撞了"正是最该拦下的一种改动（§10.2 要求报出它）；
/// - 其余既有占用：固定日程、保护时间、别的课，一律参与判定。
///
/// **还必须排除的两条**：
/// - 首尾相接（半开区间）：10:00–11:00 与 11:00–12:00 不重叠。
///   把它算冲突会让相邻两节课无法保存；
/// - 重复：同一条既有占用只提醒一次——一段新时段横跨对方一个长块时报两条，
///   会让用户以为有两处冲突。
List<CourseTimeConflict> detectCourseTimeConflicts({
  required List<({String eventId, TimeRange range})> proposed,
  required List<CalendarOccurrence> existing,
  required String editingEventId,
  Set<String> sameCourseEventIds = const {},
}) {
  final found = <String, CourseTimeConflict>{};
  for (final candidate in proposed) {
    for (final other in existing) {
      // 只排除**被编辑的那一个锚点**自己。
      if (other.eventId == editingEventId) continue;
      if (!candidate.range.overlaps(other.range)) continue;
      found.putIfAbsent(
        other.eventId,
        () => CourseTimeConflict(
          kind: _conflictKindOf(other, sameCourseEventIds),
          title: other.title,
          range: other.range,
          otherEventId: other.eventId,
          proposedEventId: candidate.eventId,
        ),
      );
    }
  }
  return found.values.toList()..sort((a, b) {
    final byStart = a.range.startUtc.compareTo(b.range.startUtc);
    if (byStart != 0) return byStart;
    return a.otherEventId.compareTo(b.otherEventId);
  });
}

/// 判断一条既有占用属于哪一类。///
/// **判据有意避开"读课表元数据"**：
/// - 是保护时间 ⇒ `protectedTime`；
/// - 属于本课程的**其它片段**（id 在 [sameCourseEventIds] 里）⇒ `sameCourse`；
/// - 带 `logicalCourseId`（＝课表导入来的）⇒ 是**别的课**；
/// - 其余 ⇒ 手工固定日程。
///
/// 不用"比较 `logicalCourseId` 是否相等"来判 `sameCourse`：最要紧的那一类冲突
/// 恰恰是**同一门课的两个片段**撞在一起，而它由调用方按 id 集合给出更准确。
CourseTimeConflictKind _conflictKindOf(
  CalendarOccurrence other,
  Set<String> sameCourseEventIds,
) {
  if (other.kind == CalendarEventKind.protected) {
    return CourseTimeConflictKind.protectedTime;
  }
  if (sameCourseEventIds.contains(other.eventId)) {
    return CourseTimeConflictKind.sameCourse;
  }
  return other.logicalCourseId == null
      ? CourseTimeConflictKind.fixedEvent
      : CourseTimeConflictKind.otherCourse;
}

/// 课程管理命令的结果。**失败时带原因**，而不是一个裸 `false`：
/// 界面要说清"为什么没改成"，而"操作失败"什么也没告诉用户（规范 §3 第 7 条）。
final class CourseCommandResult {
  const CourseCommandResult.success() : error = null;
  const CourseCommandResult.failure(this.error);

  final String? error;

  bool get isSuccess => error == null;
}

/// 课程管理的**编排层**（1.8.0，设计规范 §10.2／§10.3）。
///
/// 页面不认识数据库对象：它只调用这里的命令，范围解析、事务与重排触发都在这一层。
/// 底层复用既有的日历系列改写（`CalendarService`）与事务性删除（`CourseWriteGateway`），
/// 因此**不存在第二套重复规则实现**。
final class CourseManagementService {
  const CourseManagementService({
    required this.courses,
    required this.calendar,
    required this.deletion,
    required this.gateway,
    this.academicCalendar,
    this.zones,
    this.timeZoneId,
    this.clock,
    this.onCalendarChanged,
  });

  final CourseSeriesRepository courses;
  final CalendarService calendar;
  final CalendarEventDeletion deletion;
  final CourseWriteGateway gateway;

  /// 课程被成功写入之后的日历失效信号（计划 §2.6）。
  ///
  /// **只给"未经过 `CalendarService`"的那两条事务发信号**：[saveCourse] 与
  /// [deleteCourse] 直接走 [gateway]，因此 `CalendarService.onScheduleInputChanged`
  /// 那条统一落点看不到它们——不发信号就是"改了课，日历不变"。
  /// 而 [editOccurrence]／[editFollowing]／[editWholeCourse]／[pauseFrom] 都经
  /// [calendar]（`CalendarService`）写入，那一条路径已经发过 `calendar` 信号，
  /// 这里**再发一次就是同一次写入触发两次刷新**。
  ///
  /// 允许为空：只读端口与测试替身不必持有它；为空时只是不刷新展示。
  final void Function()? onCalendarChanged;

  /// 用于把"从哪个本地日期起暂停"换算成学期周次。为空时暂停仍可用，
  /// 只是不做"当前学期"的额外校验。
  final AcademicCalendarRepository? academicCalendar;

  /// 时区服务与**事项所在时区**（1.8.0）。
  ///
  /// [pauseFrom] 收的是"用户说的那一天"（本地日历日），而它要交给
  /// `deleteFollowingOccurrences` 的是一个**时刻**——后者按该时刻在规则自己时区里的
  /// **本地日期**去截断。因此"那一天"必须用**同一个时区**换算成时刻。
  ///
  /// **为空时的兜底**是 `DateTime.utc(y, m, d)`（UTC 零点）。那个兜底在**负偏移**时区下
  /// 会让本地日期退到前一天（`2026-10-18T00:00Z` 在 America/New_York 是 10-17 20:00），
  /// 于是截断早一天、该停的那一周还留着一次课。生产组合根必须传这两个值。
  final TimeZoneDatabase? zones;
  final String? timeZoneId;

  /// 时钟。整体替换时所有新写入行共用它给出的**同一个** `updated_at_utc`。
  ///
  /// **不由仓储自己取时间**：同一次保存里两行差几毫秒，会让"这一批是同一版"这件事
  /// 在数据上无法表达，而乐观并发判的正是版本。为空时退回系统时间（仅测试会用）。
  final Clock? clock;

  DateTime _nowUtc() => clock?.nowUtc() ?? DateTime.now().toUtc();

  /// 当前学期；没有可判定的学期时为 `null`。
  Future<String?> currentTermId() => courses.currentTermId();

  /// 按学期列出课程；[termId] 为空时列出全部。
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) =>
      courses.listCourses(termId: termId);

  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) =>
      courses.findCourse(logicalCourseId);

  /// ## 单次与"此次及以后"为什么不在这里（计划 §2.0）
  ///
  /// 这两个范围**必须有真实发生时间**才能表达"从哪一次开始"，而那个时间只存在于
  /// 日历上的具体课次（日视图）。它们已经统一走
  /// `CalendarService.updateEvent()` ＋ `CalendarEventPatch`："
  /// `singleOccurrence` 只写所选发生的一条例外，`followingOccurrences` 从真实发生日期
  /// 拆分当前锚点"。
  ///
  /// 此处的 `editOccurrence`／`editFollowing`／`editWholeCourse` 三个方法**已被删除**：
  /// 它们只接受"新起止"（整门课程那条还用一个固定日期载体 `2026-01-05` 承载钟点），
  /// 逐个片段调用 `replaceSeries`，第一段提交后第二段失败就留下半完成的课程。
  /// 留着它们等于留一个"以后可能会用"的后门——而那个后门正是本计划要封住的事故入口
  /// （Task 3 Step 6：若应用层已无合法调用就删除，不做兼容保留）。

  /// 从某个本地日期起**停止生成**，但保留历史（规范 §10.2 第四条）。
  ///
  /// 实现方式是**按周截断**：把每条规则与它的锚点截到该日期所在周的上一周周日。
  /// 这不是"暂停"一个可恢复的状态位——`calendar_events` 与 `recurrence_rules` 都没有
  /// 那样的列（那需要一次 schema 变更），而"从某天起不再出现"用截断表达既准确又
  /// 与展开器天然一致：截断之后展开器就再也产不出那之后的每一次。
  ///
  /// **历史保留**：已经发生过的次数落在被保留的周次里，因此它们照常出现在日历与统计里。
  Future<CourseCommandResult> pauseFrom({
    required String logicalCourseId,
    required DateTime fromLocalDate,
  }) async {
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) {
      return const CourseCommandResult.failure('找不到这门课程');
    }
    final cutoff = _dateOnly(fromLocalDate);
    // 截到"该日期所在周的上一周周日"：用户说"从 10-20 起停"，10-20 那一周就不该再排。
    final lastValidDate = cutoff.subtract(
      Duration(days: cutoff.weekday - DateTime.monday + 1),
    );

    final failures = <String>[];
    for (final segment in detail.segments) {
      // **只有确实需要截断的才动**：`validUntil` 已经早于停用日的片段保持原样，
      // 再截一次会让"这一次改写"被记成一次无谓的重排原因（统计里会凭空多一条）。
      final alreadyEnded =
          segment.validUntilLocalDate != null &&
          segment.validUntilLocalDate!.isBefore(lastValidDate);
      if (alreadyEnded) continue;
      // 切点取"停用日所在周的上一周周日"：用户说"从 10-20 起停"，10-20 那一周就不该再排。
      final ok = await calendar.deleteFollowingOccurrences(
        anchorId: segment.eventId,
        occurrenceStartUtc: _instantForLocalDate(lastValidDate),
      );
      if (!ok) failures.add(segment.eventId);
    }
    if (failures.isEmpty) return const CourseCommandResult.success();
    return CourseCommandResult.failure(
      '有 ${failures.length} 个系列片段没能截断（共 ${detail.segments.length} 个）',
    );
  }

  /// 改课程时间前的**冲突预览**（1.8.0，规范 §10.2 最后一条）。
  ///
  /// 规范原文："修改课程时间、周次、地点或归属后必须重新检测冲突并预览。"
  ///
  /// [proposed] 是**改完之后每一段会落在哪里**，由界面按用户选的本地时间算出来。
  /// 本方法负责读既有占用、判断谁被撞上，并排除这门课自己的其它片段与**被编辑的锚点**。
  ///
  /// **"被编辑的锚点"必须排除**：它的旧位置当然会与"它自己将要去的时段"相同或相邻
  /// （没移动时就是完全相同），不排除的话"把课挪一下"永远报冲突，功能等于不可用。
  Future<List<CourseTimeConflict>> previewTimeChange({
    required String logicalCourseId,
    required List<({String eventId, TimeRange range})> proposed,
  }) async {
    if (proposed.isEmpty) return const [];
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) return const [];

    // 读窗口取"提议时段整体范围"，前后各留一天：与提议时段相交的既有占用必然落在
    // 提议范围之内，留一天是为了让跨日的重复块也被读到（展开器按窗口裁剪）。
    var earliest = proposed.first.range.startUtc;
    var latest = proposed.first.range.endUtc;
    for (final item in proposed) {
      if (item.range.startUtc.isBefore(earliest)) {
        earliest = item.range.startUtc;
      }
      if (item.range.endUtc.isAfter(latest)) latest = item.range.endUtc;
    }
    final existing = await calendar.occurrencesBetween(
      earliest.subtract(const Duration(days: 1)),
      latest.add(const Duration(days: 1)),
    );

    // **被编辑的锚点**：`proposed` 的 `eventId` 就是要改的那一段。
    // "整个课程"会一次改全部片段，因此用集合。
    final editingIds = {for (final item in proposed) item.eventId};
    final sameCourseIds = {
      for (final segment in detail.segments)
        if (!editingIds.contains(segment.eventId)) segment.eventId,
    };

    return detectCourseTimeConflicts(
      proposed: proposed,
      // 被编辑的那些锚点的**旧位置**不是障碍，因此不进"既有占用"。
      existing: [
        for (final occurrence in existing)
          if (!editingIds.contains(occurrence.eventId)) occurrence,
      ],
      editingEventId: proposed.first.eventId,
      sameCourseEventIds: sameCourseIds,
    );
  }

  /// 删除前的**影响预览**（规范 §10.2 第六条：先预览受影响次数，再二次确认）。
  Future<CourseDeletionPreview?> previewDelete(
    String logicalCourseId, {
    String? termId,
  }) async {
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) return null;
    final effectiveTerm = termId ?? detail.summary.termId;
    final segments = [
      for (final segment in detail.segments)
        if (effectiveTerm == null || detail.summary.termId == effectiveTerm)
          segment,
    ];
    if (segments.isEmpty) return null;

    var occurrences = 0;
    DateTime? first;
    DateTime? last;
    for (final segment in segments) {
      final count = _occurrenceCount(segment);
      occurrences += count;
      final segmentFirst = _firstOccurrenceOnOrAfter(
        segment,
        segment.validFromLocalDate,
      );
      final segmentLast = segment.validUntilLocalDate;
      if (first == null || segmentFirst.isBefore(first)) first = segmentFirst;
      if (segmentLast != null && (last == null || segmentLast.isAfter(last))) {
        last = segmentLast;
      }
    }

    return CourseDeletionPreview(
      logicalCourseId: logicalCourseId,
      title: detail.summary.title,
      termId: detail.summary.termId,
      affectedSeriesCount: segments.length,
      affectedOccurrenceCount: occurrences,
      firstOccurrenceLocalDate: first,
      lastOccurrenceLocalDate: last,
    );
  }

  /// 删除整个课程在当前学期内的系列与例外（规范 §10.2 第六条）。
  ///
  /// **与"撤销导入"分开**：那个按 `importBatchId` 整体回滚（本批次的一条批次可能含多门课），
  /// 这个只删一门课。两者混用会让"删掉一门课"顺手清掉同批次导入的其它课。
  Future<CourseCommandResult> deleteCourse(
    String logicalCourseId, {
    String? termId,
  }) async {
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) {
      return const CourseCommandResult.failure('找不到这门课程');
    }
    final effectiveTerm = termId ?? detail.summary.termId;
    final anchors = {
      for (final segment in detail.segments)
        if (effectiveTerm == null || detail.summary.termId == effectiveTerm)
          segment.eventId,
    };
    if (anchors.isEmpty) {
      return const CourseCommandResult.failure('这门课在当前学期没有可删除的系列');
    }
    // **单一 UTC 时间由服务层给一次**（Task 7 Step 2）：仓储不得在循环里多次读系统时钟，
    // 否则"同一次删除"在数据上会留下几个不同的时间戳。
    await gateway.deleteSeriesWithExceptions(
      anchorEventIds: anchors,
      deletedAtUtc: _nowUtc(),
    );
    // **成功之后**才发（§2.6 最后一段）：上面任何一步抛错都保持数据不变，
    // 那时发信号只会让页面白读一次库。
    onCalendarChanged?.call();
    return const CourseCommandResult.success();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 4（课程与保护时间管理修复计划）：**整门课程资料的事务性编辑**
  //
  // 与上面 `editWholeCourse`（只换钟点）的区别：这里换的是**整门课的资料与安排**
  // ——名称、教师、地点、领域、项目，以及"哪些星期、哪些周次、每周还是单双周"。
  // 因此它必须能**新增与删除锚点**，而不只是改锚点的时间。
  // ─────────────────────────────────────────────────────────────────────────────

  /// 保存前的**影响预览**（计划 §2.1：用户二次确认前必须看到这四项）。
  ///
  /// 匹配规则见 [_matchSegment]。**新增与删除都要报出来**：只报"会删除 1 段"没有意义，
  /// 用户要知道的是"**这学期会少上几次课**"。
  Future<CourseEditPreview?> previewCourseEdit(
    CourseSaveRequest request,
  ) async {
    final detail = await courses.findCourse(request.logicalCourseId);
    if (detail == null) return null;
    final targets = _termScopedSegments(detail, request.termId);

    final claimed = <String>{};
    final addedRows = <CourseScheduleDraft>[];
    var updated = 0;
    for (final row in request.profile.schedule) {
      final segment = _matchSegment(row, targets, claimed);
      if (segment == null) {
        addedRows.add(row);
        continue;
      }
      claimed.add(segment.eventId);
      updated++;
    }

    var addedOccurrences = 0;
    for (final row in addedRows) {
      addedOccurrences += _draftOccurrenceCount(row);
    }

    var removedOccurrences = 0;
    var removedExceptions = 0;
    for (final segment in targets) {
      if (claimed.contains(segment.eventId)) continue;
      removedOccurrences += _occurrenceCount(segment);
      removedExceptions += await gateway.countExceptions(segment.eventId);
    }

    return CourseEditPreview(
      addedSegments: addedRows.length,
      removedSegments: targets.length - claimed.length,
      updatedSegments: updated,
      affectedOccurrenceDelta: addedOccurrences - removedOccurrences,
      removedExceptionCount: removedExceptions,
    );
  }

  /// 保存整门课程的资料（计划 Task 4 Step 4）。
  ///
  /// **顺序不可改变**：
  /// ① 读当前详情 → ② 指纹与修订比对（过期就返回 `stale`，**不写任何东西**）
  /// → ③ 字段校验 → ④ 一个事务里整体替换。
  ///
  /// 把 ② 放到 ③ 之后会有一个坏结果：用户基于**过期数据**填的表单先收到"字段错误"，
  /// 修完再保存才发现"其实早该重新打开"——白改一遍。
  ///
  /// **任何一步失败都保持原数据不变**：校验在写之前，替换本身在事务里。
  Future<CourseSaveResult> saveCourse(CourseSaveRequest request) async {
    final detail = await courses.findCourse(request.logicalCourseId);
    if (detail == null) {
      return CourseSaveResult.failed(
        CourseSaveStatus.stale,
        '这门课程已删除或链接过期，请返回课程列表重新打开',
      );
    }
    final targets = _termScopedSegments(detail, request.termId);
    if (targets.isEmpty && request.profile.schedule.isNotEmpty) {
      return CourseSaveResult.failed(
        CourseSaveStatus.stale,
        '这门课在当前学期没有可改动的系列，请重新打开',
      );
    }

    // ② 过期检测：**先比指纹，再逐锚点比修订号**。
    //
    // 两级都要：指纹能发现"锚点被增删了"，逐锚点能发现"同一批锚点里有哪一个被改了"。
    // 只比指纹会在"别处改完又改回来、时间戳变了但形态一样"时漏判；
    // 只比逐锚点会在"别处删掉一段又加了一段"时漏判（新锚点在预期集合里不存在）。
    if (detail.revisionFingerprint != request.expectedFingerprint) {
      return CourseSaveResult.failed(
        CourseSaveStatus.stale,
        '这门课在别处已被修改，请重新打开后再编辑',
      );
    }
    for (final segment in targets) {
      final expected = request.expectedRevisions[segment.eventId];
      if (expected == null ||
          expected.microsecondsSinceEpoch !=
              segment.updatedAtUtc.microsecondsSinceEpoch) {
        return CourseSaveResult.failed(
          CourseSaveStatus.stale,
          '这门课在别处已被修改，请重新打开后再编辑',
        );
      }
    }

    // ③ 字段校验（纯函数，逐条可断言）。
    final errors = validateCourseProfile(
      request.profile,
      termFirstWeekMonday: _termFirstWeekMondayOf(detail),
    );
    if (errors.isNotEmpty) return CourseSaveResult.invalid(errors);

    // ③′ **来源解析**（计划 §2.1／Task 6 Step 3）。
    //
    // 位置是刻意的：**过期检查之后、字段校验之后、写网关之前**。
    // - 放在过期检查之前，用户会基于一份过期的清单得到来源结论；
    // - 用页面打开时缓存的批次 id 更糟：那个值可能已经被别处改过（规范 Global
    //   Constraints 明确"页面与请求体不得伪造 `importBatchId`"）。
    //
    // 因此解析的输入只有一个来源：**刚刚从库里读到的 `targets`**。
    final lineage = resolveCourseLineage([
      for (final segment in targets) segment.importBatchId,
    ]);
    if (!lineage.canSave) {
      return CourseSaveResult.failed(
        CourseSaveStatus.integrityConflict,
        '这门课程关联了多个导入批次，未保存。请先备份并从导入记录检查来源。',
      );
    }

    if (timeZoneId == null) {
      return CourseSaveResult.failed(
        CourseSaveStatus.unsupported,
        '时区未装配，暂无法保存课程安排',
      );
    }

    // ④ 一个事务里整体替换。`replaceCourseSeries` 自己保证原子性：
    // 删除、写入、规则更新三条路径共用一个事务，任何一步抛错都整体回滚。
    final claimed = <String>{};
    final rows = <CourseWriteRow>[];
    for (var index = 0; index < request.profile.schedule.length; index++) {
      final row = request.profile.schedule[index];
      final matched = _matchSegment(row, targets, claimed);
      if (matched != null) claimed.add(matched.eventId);
      rows.add(
        CourseWriteRow(
          schedule: row,
          index: index,
          // **保留匹配上的既有锚点 id**：换一个 id 等于删一条加一条，
          // 而那条锚点名下的**逐次例外**会随之全部丢失。
          reuseAnchorId: matched?.eventId,
        ),
      );
    }

    try {
      await gateway.replaceCourseSeries(
        rows: rows,
        profile: request.profile,
        zoneId: timeZoneId!,
        updatedAtUtc: _nowUtc(),
        // **全部最终锚点统一写同一个来源**（§3.1）：新增片段、复用片段与只改资料的
        // 片段因此遵守同一条规则。`recoverableMixed` 的成功保存会把它统一成
        // `imported`；事务中任一行失败则混合来源原样保留。
        provenance: lineage.provenance,
      );
    } on Object catch (error) {
      // **事务已回滚，原内容未改变**——文案必须说这一句，否则用户会以为改了一半。
      return CourseSaveResult.failed(
        CourseSaveStatus.failed,
        '保存失败，原内容未改变：$error',
      );
    }
    // **只在事务提交成功之后**发日历失效信号（§2.6）：这条路径绕过 `CalendarService`，
    // 因此课程改了名或改了时间而这里不发信号的话，日历会继续显示旧课名。
    onCalendarChanged?.call();
    return CourseSaveResult.saved();
  }

  /// 当前学期的系列片段（与既有 `editWholeCourse` 用同一条过滤）。
  List<CourseSeriesSegment> _termScopedSegments(
    CourseSeriesDetail detail,
    String? termId,
  ) {
    final effectiveTerm = termId ?? detail.summary.termId;
    return [
      for (final segment in detail.segments)
        if (effectiveTerm == null || detail.summary.termId == effectiveTerm)
          segment,
    ];
  }

  /// 把一条草稿匹配到一个**尚未被认领**的既有片段；匹配不上返回 `null`。
  ///
  /// ## 匹配键是"这条安排是哪几天、多久一次"，**时间不是键**
  ///
  /// 第一版把 `startMinute` 与 `endMinute` 也算进键里。那看起来更精确，实际是错的：
  /// **改时间正是这个功能最主要的用途**，而把它算进键会让一次"周一 08:00 改到 14:00"
  /// 被识别成"删掉旧片段、新增一个片段"——于是
  ///
  /// - 预览报出"删 1 段、加 1 段"（用户会以为要重排整门课）；
  /// - 既有锚点被删掉，**它名下逐次调整过的例外全部消失**。
  ///
  /// 一个学期同一门课在同一组星期上排两段不同时间的**极少见**，而"改时间"是每次编辑
  /// 都在做的事。因此匹配按这个优先级：
  ///
  /// 1. **星期集合相同 ＋ 频率相同**（最强的"这是同一段课"信号）；
  /// 2. 在候选里优先取**开始时间相同**的（多条同星期安排时挑最像的那条）；
  /// 3. 其余按开始时间升序，逐条认领。
  ///
  /// 剩下的配对是确定的：同一次保存里同样的输入必然得到同样的匹配，
  /// 因此"预览说会删 1 段"与"保存真的删 1 段"一致。
  CourseSeriesSegment? _matchSegment(
    CourseScheduleDraft row,
    List<CourseSeriesSegment> targets,
    Set<String> claimed,
  ) {
    final candidates = [
      for (final segment in targets)
        if (!claimed.contains(segment.eventId) &&
            segment.intervalWeeks == row.intervalWeeks &&
            _sameWeekdays(segment.weekdays, row.weekdays))
          segment,
    ]..sort((a, b) => a.startMinute.compareTo(b.startMinute));
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      if (candidate.startMinute == row.startMinute) return candidate;
    }
    return candidates.first;
  }

  static bool _sameWeekdays(Set<int> a, Set<int> b) =>
      a.length == b.length && a.every(b.contains);

  /// 一条草稿会展开出多少次（与 `_occurrenceCount` 同一算法，只是输入是草稿）。
  static int _draftOccurrenceCount(CourseScheduleDraft row) {
    final last = row.validUntilLocalDate ?? row.validFromLocalDate;
    final spanWeeks = last.difference(row.validFromLocalDate).inDays ~/ 7 + 1;
    final weeks = spanWeeks < 1 ? 1 : spanWeeks;
    final interval = row.intervalWeeks < 1 ? 1 : row.intervalWeeks;
    return (weeks / interval).ceil();
  }

  /// 这门课所属学期「第一周周一」的等价日期；拿不到时为 `null`。
  ///
  /// **不需要 `AcademicCalendarRepository`**：`CourseSeriesSegment.weekSpan` 是读模型
  /// 已经按学期坐标算好的周次，因此「第 1 周的周一」可以反推出来——
  /// `validFrom − (startWeek − 1) 周`。为此再注入一个学期仓储，等于让同一件事有
  /// **两个来源**，而它们完全可能给出不同的答案（一个按学期表、一个按规则起止）。
  ///
  /// 它只服务一件事：单双周校验（「第 5 周是单周吗」要靠基准算奇偶）。
  /// 拿不到就不做那一条判定，而不是硬报错——没有学期归属的手工课程也要能保存。
  DateTime? _termFirstWeekMondayOf(CourseSeriesDetail detail) {
    final first = detail.segments.firstOrNull;
    if (first == null) return null;
    final startWeek = first.weekSpan.startWeek;
    if (startWeek <= 1) return first.validFromLocalDate;
    return first.validFromLocalDate.subtract(
      Duration(days: (startWeek - 1) * DateTime.daysPerWeek),
    );
  }

  /// 一条系列片段会展开出多少次。
  ///
  /// **按 ISO 周计数**：`validFrom` 与 `validUntil` 之间的周数除以 `intervalWeeks`。
  /// 单双周的规则里 `intervalWeeks == 2`，因此它的次数是周数的一半——只报"1 条系列"
  /// 会让用户以为删掉它只影响一次。
  static int _occurrenceCount(CourseSeriesSegment segment) {
    final last = segment.validUntilLocalDate ?? segment.validFromLocalDate;
    final spanWeeks =
        last.difference(segment.validFromLocalDate).inDays ~/ 7 + 1;
    final weeks = spanWeeks < 1 ? 1 : spanWeeks;
    final interval = segment.intervalWeeks < 1 ? 1 : segment.intervalWeeks;
    return (weeks / interval).ceil();
  }

  static DateTime _firstOccurrenceOnOrAfter(
    CourseSeriesSegment segment,
    DateTime from,
  ) => _dateOnly(from);

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// 把一个**本地日历日**换算成"当天本地 00:00"的时刻。
  ///
  /// **必须用事项自己的时区**。`deleteFollowingOccurrences` 的契约是按该时刻在
  /// 规则自己时区里的**本地日期**去截断（见 `_validateSplitDate`），因此"那一天"
  /// 必须用**同一个时区**换算。
  ///
  /// **第一版写的是 `DateTime.utc(y, m, d)`（UTC 零点）**，理由是"多一层换算只会多一处错"。
  /// 那个理由在**正偏移**时区下恰好成立（东八区：`00:00Z` 是同日 `08:00`），
  /// 于是本机与主用例全绿；但在**负偏移**时区下它会把本地日期退到**前一天**：
  /// `2026-10-18T00:00Z` 在 America/New_York 是 `10-17 20:00`，
  /// 截断因此早一天——该停的那一周还留着一次课，而且不报错。
  ///
  /// 未装配时区服务时退回 UTC 零点（与旧行为一致），并把这件事写在字段注释里。
  DateTime _instantForLocalDate(DateTime date) {
    final service = zones;
    final zone = timeZoneId;
    if (service == null || zone == null) {
      return DateTime.utc(date.year, date.month, date.day);
    }
    return service.localMidnightToUtc(
      DateTime.utc(date.year, date.month, date.day),
      zone,
    );
  }
}
