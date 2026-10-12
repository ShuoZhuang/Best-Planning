import 'dart:collection';

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
  CourseSeriesDetail({
    required this.summary,
    required List<CourseSeriesSegment> segments,
  }) : segments = UnmodifiableListView(List.of(segments));

  final CourseSeriesSummary summary;
  final List<CourseSeriesSegment> segments;

  /// 每个锚点保存时读到的 `updated_at_utc`（计划 Task 3 Interfaces）。
  ///
  /// **它是"页面数据过期"检测的唯一依据**：用户打开编辑页之后，别处（另一个窗口、
  /// 课表重新导入）可能已经改过这门课。保存前拿它和数据库里的现值比一次，
  /// 不一致就返回 `stale` 让用户重新打开——而不是覆盖掉别人的改动。
  Map<EntityId, DateTime> get sourceRevisions => {
    for (final segment in segments) segment.eventId: segment.updatedAtUtc,
  };
}

/// 一个系列片段：一条锚点事件 ＋ 它的重复规则。
final class CourseSeriesSegment {
  CourseSeriesSegment({
    required this.eventId,
    required this.title,
    Set<int>? weekdays,
    int? weekday,
    required this.startMinute,
    required this.endMinute,
    required this.intervalWeeks,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    this.location = '',
    this.areaId,
    this.projectId,
    this.weekSpan = const WeekSpan(startWeek: 1, endWeek: 1),
    this.outsideTerm = false,
    required this.updatedAtUtc,
  }) : weekdays = UnmodifiableSetView(
         Set.of(weekdays ?? {weekday ?? DateTime.monday}),
       ) {
    if (this.weekdays.isEmpty) {
      throw ArgumentError('一个系列片段至少要有一个星期');
    }
  }

  final EntityId eventId;
  final String title;

  /// 这条规则**实际覆盖的星期集合**（计划 Task 3 Step 2）。
  ///
  /// **为什么不再用一个代表 weekday**：一条规则可以同时是"周一与周四"
  /// （`recurrence_rules.weekdays_mask` 本来就能表达多个位），而只取一个代表
  /// 会让编辑页把另一天**静默丢掉**——用户改一次时间，周四那节课就没了。
  final Set<int> weekdays;

  /// 代表星期（取最小的那个），保留给"按星期排序""显示成周X"这类单值用途。
  ///
  /// **它不是数据的全部**：需要判断"这条规则覆盖哪些天"时必须读 [weekdays]。
  int get weekday => weekdays.reduce((a, b) => a < b ? a : b);

  final int startMinute;
  final int endMinute;

  /// 每隔几周（`2` 就是单双周那两条规则各自的间隔）。
  final int intervalWeeks;
  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;

  /// 这条规则在**学期周次坐标**里的范围（计划 Task 3 Interfaces）。
  ///
  /// 它由学期第一周周一算出，因此 `startWeek = 5` 表示"从学期第 5 周开始"。
  /// 修复前读模型把 `startWeek` 写死为 1、`endWeek` 写成"跨了几周"——
  /// 于是"第 5 周到第 12 周"显示成"第 1 周到第 8 周"，编辑页保存时会把课挪到开学那几周。
  final WeekSpan weekSpan;

  /// 规则有效期**超出了学期总周数**（计划 Task 3 Step 4）。
  ///
  /// **读取时不夹紧**：夹紧会让"这门课其实排到了学期外"这件事在编辑页上完全看不见，
  /// 而用户保存时就会把它永久改成学期内。因此保留原日期并置起这个标志，
  /// 由编辑页提示用户修正。
  final bool outsideTerm;

  final String location;
  final EntityId? areaId;
  final EntityId? projectId;

  /// 锚点行的 `updated_at_utc`，供保存时发现**过期页面**（乐观并发）。
  final DateTime updatedAtUtc;
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
