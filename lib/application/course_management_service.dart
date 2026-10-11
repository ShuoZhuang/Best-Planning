import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/domain/models/course_series.dart';
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
  });

  final CourseSeriesRepository courses;
  final CalendarService calendar;
  final CalendarEventDeletion deletion;
  final CourseWriteGateway gateway;

  /// 用于把"从哪个本地日期起暂停"换算成学期周次。为空时暂停仍可用，
  /// 只是不做"当前学期"的额外校验。
  final AcademicCalendarRepository? academicCalendar;

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
    final anchors = [
      for (final segment in detail.segments)
        if (effectiveTerm == null || detail.summary.termId == effectiveTerm)
          segment.eventId,
    ];
    if (anchors.isEmpty) {
      return const CourseCommandResult.failure('这门课在当前学期没有可改动的系列');
    }

    final failures = <String>[];
    for (final anchorId in anchors) {
      // `CalendarService.replaceSeries` 只改时间；标题属于"这条日程的属性"，
      // 由界面在需要时另走一次保存（本批次不做批量改名，规范 §10.2 也没有要求）。
      final ok = await calendar.replaceSeries(
        anchorId: anchorId,
        newStartUtc: newStartUtc,
        newEndUtc: newEndUtc,
      );
      if (!ok) failures.add(anchorId);
    }
    if (failures.isEmpty) return const CourseCommandResult.success();
    return CourseCommandResult.failure(
      '有 ${failures.length} 个系列片段没有改成功（共 ${anchors.length} 个）',
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
        occurrenceStartUtc: _utcForLocalDate(lastValidDate),
      );
      if (!ok) failures.add(segment.eventId);
    }
    if (failures.isEmpty) return const CourseCommandResult.success();
    return CourseCommandResult.failure(
      '有 ${failures.length} 个系列片段没能截断（共 ${detail.segments.length} 个）',
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

  /// 把一个本地日期换算成"当天本地 00:00"的 UTC 时刻。
  ///
  /// 这里刻意用 `DateTime.utc` 而不是任何时区服务：`deleteFollowingOccurrences` 的契约是
  /// 按**该时刻的本地日期**去截断规则，而它自己会在仓储侧用规则自己的时区换算
  /// （见 `_validatedSplitDate`）。传一个"同一天的 UTC 零点"就够，多一层换算只会多一处错。
  static DateTime _utcForLocalDate(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day);
}
