import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
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

/// 把"新的本地钟点"套到某一个片段**自己那一周的那一天**上。
///
/// 规范 §10.2 第三条要的是"改这门课的时间"，而不是"把所有片段压到同一时刻"：
/// 单双周课程的每一段各有自己的星期，改完之后必须**仍然是那一天**。
///
/// 实现方式刻意选"锚点日 `+ (目标星期 - 锚点星期)` 天"：
/// - `newStartUtc` 的**本地钟点**由调用方给定，这里只搬日期；
/// - 用**日历日加法**（`DateTime(y, m, d + n)`）而不是 `add(Duration(days: n))`——
///   后者在夏令时切换日会漂一小时（与 `deferNotBeforeUtc` 同一条理由）；
/// - `Duration` 在这里**只用于"加多少天"**，不会被加到时刻上。
///
/// 单片段课程因此逐值不变：目标星期等于锚点星期时偏移为 0。
(DateTime, DateTime) _mapToSegmentDay({
  required CourseSeriesSegment segment,
  required DateTime newStartUtc,
  required DateTime newEndUtc,
}) {
  final anchorWeekday = newStartUtc.weekday;
  final offsetDays = segment.weekday - anchorWeekday;
  final duration = newEndUtc.difference(newStartUtc);
  final targetStart = _addLocalDays(newStartUtc, offsetDays);
  return (targetStart, targetStart.add(duration));
}

/// 在一个 UTC 时刻上**加减日历日**（不改变钟点，不受夏令时影响）。
///
/// **为什么不用 `add(Duration(days: n))`**：那加的是**绝对时长**。对 UTC 时刻本身而言
/// 24 小时就是 24 小时，但这里的语义是"换到另一天"，而下游的
/// `replaceSeries` 会按**规则自己的时区**重新解释这个时刻的本地日期——
/// 因此必须保证"本地日期确实前进/后退了 n 天"，而不是"绝对时刻前进了 n×24 小时"。
/// 用日历加法表达这个意图，读代码的人也不会误以为它在算时长。
DateTime _addLocalDays(DateTime instantUtc, int days) =>
    DateTime.utc(instantUtc.year, instantUtc.month, instantUtc.day + days).add(
      Duration(
        hours: instantUtc.hour,
        minutes: instantUtc.minute,
        seconds: instantUtc.second,
        milliseconds: instantUtc.millisecond,
        microseconds: instantUtc.microsecond,
      ),
    );

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
  });

  final CourseSeriesRepository courses;
  final CalendarService calendar;
  final CalendarEventDeletion deletion;
  final CourseWriteGateway gateway;

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

  /// 当前学期；没有可判定的学期时为 `null`。
  Future<String?> currentTermId() => courses.currentTermId();

  /// 按学期列出课程；[termId] 为空时列出全部。
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) =>
      courses.listCourses(termId: termId);

  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) =>
      courses.findCourse(logicalCourseId);

  /// 编辑**单次**：写一条例外，不动系列（规范 §10.2 第一条）。
  Future<CourseCommandResult> editOccurrence({
    required String logicalCourseId,
    required String anchorEventId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
  }) async {
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) {
      return const CourseCommandResult.failure('找不到这门课程');
    }
    if (!detail.summary.anchorEventIds.contains(anchorEventId)) {
      // **防串台**：锚点必须属于这门课。同名但不同 `logicalCourseId` 的课
      // 如果只按标题匹配，这一次改写会落到另一门课上（规范 §10 Review Focus）。
      return const CourseCommandResult.failure('这次改动不属于该课程');
    }
    final ok = await calendar.replaceOccurrence(
      anchorId: anchorEventId,
      occurrenceStartUtc: occurrenceStartUtc,
      newStartUtc: newStartUtc,
      newEndUtc: newEndUtc,
      title: title,
    );
    return ok
        ? const CourseCommandResult.success()
        : const CourseCommandResult.failure('日历写入服务未装配，改动未生效');
  }

  /// 编辑**此次及以后**：截断旧规则并创建新系列（规范 §10.2 第二条）。
  Future<CourseCommandResult> editFollowing({
    required String logicalCourseId,
    required String anchorEventId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
  }) async {
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) {
      return const CourseCommandResult.failure('找不到这门课程');
    }
    if (!detail.summary.anchorEventIds.contains(anchorEventId)) {
      return const CourseCommandResult.failure('这次改动不属于该课程');
    }
    // **新系列的 id 由 `CalendarService` 生成**，不从外面传进来：
    // 服务自己持有 `IdGenerator`，而"调用方随手造两个 id"是让两次拆分撞车的捷径。
    final ok = await calendar.replaceFollowingOccurrences(
      anchorId: anchorEventId,
      occurrenceStartUtc: occurrenceStartUtc,
      newStartUtc: newStartUtc,
      newEndUtc: newEndUtc,
    );
    return ok
        ? const CourseCommandResult.success()
        : const CourseCommandResult.failure('日历写入服务未装配，改动未生效');
  }

  /// 编辑**整个课程**：修改该逻辑课程在**当前学期内**的全部系列片段
  /// （规范 §10.2 第三条）。
  ///
  /// **限定 `logicalCourseId` 就够，不需要再限定 `termId` 的理由**：一个
  /// `logicalCourseId` 只属于一门课，而这门课的全部片段本来就在同一个学期里
  /// （学期是导入批次上的属性，同一门课来自同一次导入）。`termId` 的校验仍然做，
  /// 是为了挡住"同一门课在两个学期各导了一次"这种数据——那时只该改当前学期那一批。
  Future<CourseCommandResult> editWholeCourse({
    required String logicalCourseId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    String? termId,
  }) async {
    final detail = await courses.findCourse(logicalCourseId);
    if (detail == null) {
      return const CourseCommandResult.failure('找不到这门课程');
    }
    final effectiveTerm = termId ?? detail.summary.termId;
    // **同一份清单既用于"有没有可改的"判断，也用于循环**（第一版分开算，
    // 两处的过滤条件还写得不一致：一处是 `effectiveTerm == null || 相等`，
    // 另一处是 `effectiveTerm != null && 不等`——在 `termId: null` 且课程有学期时，
    // 前者认为"全部可改"而后者把每一段都跳过，于是**报告成功却什么都没改**）。
    final targets = [
      for (final segment in detail.segments)
        if (effectiveTerm == null || detail.summary.termId == effectiveTerm)
          segment,
    ];
    if (targets.isEmpty) {
      return const CourseCommandResult.failure('这门课在当前学期没有可改动的系列');
    }

    final failures = <String>[];
    for (final segment in targets) {
      // **每一段保留自己的星期与日期，只换钟点**（规范 §10.2 第三条）。
      //
      // 修复前的写法把 `newStartUtc` 原样传给**每一段**，于是一门
      // "周一 08:00 ＋ 周四 10:00" 的课改完之后**两段都落在周一**——每周少上一次课。
      // 这条路径当时没有用例：旧用例只断言"调用了两次 `replaceSeries`"，
      // **不断言两者落在哪里**，因此缺陷一直没被发现。
      final mapped = _mapToSegmentDay(
        segment: segment,
        newStartUtc: newStartUtc,
        newEndUtc: newEndUtc,
      );
      final ok = await calendar.replaceSeries(
        anchorId: segment.eventId,
        newStartUtc: mapped.$1,
        newEndUtc: mapped.$2,
      );
      if (!ok) failures.add(segment.eventId);
    }
    if (failures.isEmpty) return const CourseCommandResult.success();
    return CourseCommandResult.failure(
      '有 ${failures.length} 个系列片段没有改成功（共 ${targets.length} 个）',
    );
  }

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
    await gateway.deleteSeriesWithExceptions(anchors);
    return const CourseCommandResult.success();
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
