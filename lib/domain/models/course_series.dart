import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';

/// 一门**逻辑课程**在某个学期里的聚合视图（1.8.0，设计规范 §10.1）。
///
/// **为什么是"聚合"而不是一行**：一门课在库里往往是**多个系列片段**——单双周会被拆成
/// 两条重复规则（单周一条、双周一条），改过时间的课还可能留下第三段。它们在数据里各有
/// 自己的 `calendar_events` 锚点与 `recurrence_rules` 行，但用户眼里就是**一门课**。
/// 管理页要按 `logicalCourseId` 把它们聚起来，否则用户会看到"高等数学"出现三次。
///
/// **同名不同 `logicalCourseId` 必须分开**：两个班的"高等数学(上)"是两门课，聚合的键是
/// `logicalCourseId` 而**不是标题**（规范 §10.3 与 Task 9 Step 1）。
final class CourseSeriesSummary {
  const CourseSeriesSummary({
    required this.logicalCourseId,
    required this.title,
    required this.termId,
    required this.anchorEventIds,
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
    required this.weekSpans,
    this.areaId,
    this.projectId,
    this.location = '',
    this.teacher = '',
    this.importBatchId,
    this.enabled = true,
  });

  final EntityId logicalCourseId;
  final String title;

  /// 所属学期。`null` 表示这条课程没有学期归属（手工建的、或导入时没选学期）。
  final EntityId? termId;

  /// 组成这门课的**全部系列片段**的锚点事件 id。
  ///
  /// 这是"整个课程"这一类操作真正要落到的东西：按 id 逐个改写／删除，
  /// **而不是**按标题批量更新（那会误伤同名的另一门课）。
  final List<EntityId> anchorEventIds;

  /// 星期（`DateTime.monday`…`DateTime.sunday`）。多片段课程取**第一段**的星期，
  /// 详情页会逐段列出。
  final int weekday;

  /// 本地起止分钟（0..1440）。
  final int startMinute;
  final int endMinute;

  /// 周次范围（含单双周）。
  final List<WeekSpan> weekSpans;

  final EntityId? areaId;
  final EntityId? projectId;
  final String location;
  final String teacher;
  final EntityId? importBatchId;

  /// 是否仍在生成实例。暂停与归档都为 `false`。
  final bool enabled;

  int get durationMinutes => endMinute - startMinute;
}

/// 一门课的详情：聚合摘要 ＋ 逐个系列片段。
///
/// 分成两层是因为两者的**用途不同**：列表页只需要摘要（一门课一行），
/// 而"改整个课程"必须知道每一个片段锚点。把片段清单塞进摘要会让列表页拿到一堆用不上的数据。
final class CourseSeriesDetail {
  const CourseSeriesDetail({required this.summary, required this.segments});

  final CourseSeriesSummary summary;
  final List<CourseSeriesSegment> segments;
}

/// 一个系列片段：一条锚点事件 ＋ 它的重复规则。
final class CourseSeriesSegment {
  const CourseSeriesSegment({
    required this.eventId,
    required this.title,
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
    required this.intervalWeeks,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    this.location = '',
    this.areaId,
    this.projectId,
  });

  final EntityId eventId;
  final String title;
  final int weekday;
  final int startMinute;
  final int endMinute;

  /// 每隔几周（`2` 就是单双周那两条规则各自的间隔）。
  final int intervalWeeks;
  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;
  final String location;
  final EntityId? areaId;
  final EntityId? projectId;
}

/// 删除课程前的影响预览（规范 §10.2："删除：先预览受影响次数，再二次确认"）。
final class CourseDeletionPreview {
  const CourseDeletionPreview({
    required this.logicalCourseId,
    required this.title,
    required this.termId,
    required this.affectedSeriesCount,
    required this.affectedOccurrenceCount,
    required this.firstOccurrenceLocalDate,
    required this.lastOccurrenceLocalDate,
  });

  final EntityId logicalCourseId;
  final String title;
  final EntityId? termId;

  /// 会被删掉的系列片段数。
  final int affectedSeriesCount;

  /// 会被删掉的**具体次数**（把每条规则的周次范围展开后求和）。
  ///
  /// 这是用户真正要看懂的数字："这门课还剩 8 次，删掉就没了"。
  /// 只报"1 条系列"没有意义——一条单周规则背后的次数取决于它还剩几周。
  final int affectedOccurrenceCount;

  final DateTime? firstOccurrenceLocalDate;
  final DateTime? lastOccurrenceLocalDate;
}
