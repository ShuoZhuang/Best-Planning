import 'dart:collection';

import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';

/// 一门课的**来源状态**（计划 §2.1 的冻结决策表）。
///
/// 它回答的问题是"这一门课（＝同一 `logicalCourseId` 在当前学期里的全部片段）
/// 是从哪来的"，而不是"某一条锚点是从哪来的"。两者在多片段课程上完全不同：
/// 新增片段会造出 `importBatchId == null` 的锚点，而它仍然属于原来那次导入。
enum CourseLineageState {
  /// 全部片段都没有批次：手工创建的课程。
  manual,

  /// 恰好一个非空批次，且没有空批次。
  imported,

  /// **恰好一个非空批次 ＋ 至少一个空批次**：旧缺陷造成的混合来源，**可以修复**。
  ///
  /// 允许保存；成功事务把全部最终片段统一到那个批次（§2.1）。
  recoverableMixed,

  /// **两个及以上不同的非空批次**：异常数据。
  ///
  /// **禁止保存、不猜测、不写库**：任选一个都会改变另一个批次的回滚范围，
  /// 而那正是"撤销这次导入会删掉哪些课"这件事的依据（§17.3）。
  conflicting,
}

/// 一门课保存时应当写下去的**来源事实**（计划 §2.1）。
///
/// **它不由页面提供**：批次 id 是"这条数据从哪来"的事实，
/// 只能由服务层根据**当前数据库详情**解析（规范 Global Constraints：
/// 页面与请求体不得伪造 `importBatchId`）。
final class CourseSeriesProvenance {
  const CourseSeriesProvenance({
    required this.sourceKind,
    required this.importBatchId,
  });

  /// 手工来源的固定取值：`sourceKind == manual` 时批次必为 `null`。
  static const CourseSeriesProvenance manual = CourseSeriesProvenance(
    sourceKind: CalendarEventSourceKind.manual,
    importBatchId: null,
  );

  factory CourseSeriesProvenance.imported(String batchId) =>
      CourseSeriesProvenance(
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: batchId,
      );

  final CalendarEventSourceKind sourceKind;
  final String? importBatchId;

  /// 两个字段必须构成合法组合（§3.1）：
  /// `timetableImport ⇔ importBatchId != null`。
  bool get isConsistent =>
      (sourceKind == CalendarEventSourceKind.timetableImport) ==
      (importBatchId != null && importBatchId!.isNotEmpty);

  @override
  bool operator ==(Object other) =>
      other is CourseSeriesProvenance &&
      other.sourceKind == sourceKind &&
      other.importBatchId == importBatchId;

  @override
  int get hashCode => Object.hash(sourceKind, importBatchId);
}

/// [resolveCourseLineage] 的结果：状态 ＋ 要写下去的来源。
final class CourseLineageResolution {
  const CourseLineageResolution({
    required this.state,
    required this.provenance,
  });

  final CourseLineageState state;
  final CourseSeriesProvenance provenance;

  bool get canSave => state != CourseLineageState.conflicting;
}

/// **来源解析的唯一定义**（计划 §2.1）。
///
/// 纯函数：不读数据库、不看时钟，因此四格（manual／imported／recoverableMixed／
/// conflicting）可以逐格钉住。
///
/// 输入是**当前学期全部片段**的 `importBatchId`（含 `null`）。判定顺序固定：
///
/// | 非空值个数 | 是否有空值 | 结果 |
/// | --- | --- | --- |
/// | 0 | — | [CourseLineageState.manual] → 全部写 `manual`／`null` |
/// | 1 | 无 | [CourseLineageState.imported] → 全部沿用该批次 |
/// | 1 | 有 | [CourseLineageState.recoverableMixed] → 允许保存并统一来源 |
/// | ≥2 | — | [CourseLineageState.conflicting] → 禁止保存、零写入 |
CourseLineageResolution resolveCourseLineage(
  Iterable<String?> importBatchIds,
) {
  final all = List<String?>.of(importBatchIds);
  final distinct = <String>{
    for (final id in all)
      if (id != null && id.isNotEmpty) id,
  };
  if (distinct.isEmpty) {
    return const CourseLineageResolution(
      state: CourseLineageState.manual,
      provenance: CourseSeriesProvenance.manual,
    );
  }
  if (distinct.length > 1) {
    // **不猜**：返回一个"不能保存"的结果，调用方据此零写入。
    return const CourseLineageResolution(
      state: CourseLineageState.conflicting,
      provenance: CourseSeriesProvenance.manual,
    );
  }
  final hasEmpty = all.any((id) => id == null || id.isEmpty);
  return CourseLineageResolution(
    state: hasEmpty
        ? CourseLineageState.recoverableMixed
        : CourseLineageState.imported,
    provenance: CourseSeriesProvenance.imported(distinct.single),
  );
}

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

/// **旧版时间修改留下的可检测损伤**（计划 §2.0.3／Task 4）。
///
/// ## 为什么只检测、不猜测恢复
///
/// 导入批次只保存源文件名、图片哈希、计数与时间，**不保存 OCR 后的原课程资料**
/// （计划 §1.5）。一旦旧接口把课程名、教师、地点或领域覆盖掉，数据库里可能已经不
/// 存在原值。因此系统能可靠回答的只有"这条数据与旧缺陷的确定特征相符"，而不是
/// "它本来叫什么"。猜测恢复会伪造一个用户从未输入过的答案。
enum CourseIntegrityIssueKind {
  /// 导入课程的标题**精确等于**旧版占位值 `未命名事项`。
  legacyPlaceholderTitle,

  /// 锚点的 `time_zone_id` 与它自己规则的 `time_zone_id` 不一致。
  ///
  /// 旧包装器在缓存里找不到这条事项时用 `UTC` 兜底，于是事件时区与规则时区分家——
  /// 展开按规则时区、显示按事件时区，同一次课在两处落在不同的本地日。
  eventRuleTimeZoneMismatch,

  /// 同一逻辑课程出现**两个及以上不同的非空** `import_batch_id`（计划 §2.1）。
  conflictingImportLineage,
}

/// 一条结构化完整性问题。**`affectedAnchorIds` 只供内部定位，界面不显示 id**
/// （规范全局不变量第 7 条：用户不认识 uuid）。
final class CourseIntegrityIssue {
  CourseIntegrityIssue({
    required this.kind,
    required List<String> affectedAnchorIds,
  }) : affectedAnchorIds = UnmodifiableListView(
         List.of(affectedAnchorIds),
       );

  final CourseIntegrityIssueKind kind;
  final List<String> affectedAnchorIds;
}

/// **旧版占位标题**的精确值（计划 §2.0.3 的确定性判据）。
///
/// 只有**精确等于**它才触发 [CourseIntegrityIssueKind.legacyPlaceholderTitle]：
/// 用户手写的课程确实可能叫类似的名字，而"包含"式匹配会把正常课程误报成损坏。
const String legacyPlaceholderCourseTitle = '未命名事项';

/// 一门课的详情：聚合摘要 ＋ 逐个系列片段。
///
/// 分成两层是因为两者的**用途不同**：列表页只需要摘要（一门课一行），
/// 而"改整个课程"必须知道每一个片段锚点。把片段清单塞进摘要会让列表页拿到一堆用不上的数据。
final class CourseSeriesDetail {
  CourseSeriesDetail({
    required this.summary,
    required List<CourseSeriesSegment> segments,
    List<CourseIntegrityIssue> integrityIssues = const [],
  }) : segments = UnmodifiableListView(List.of(segments)),
       integrityIssues = UnmodifiableListView(List.of(integrityIssues));

  final CourseSeriesSummary summary;
  final List<CourseSeriesSegment> segments;

  /// **只读检测**的结果（计划 §2.0.3）。打开课程、运行迁移或生成计划都不得改写数据，
  /// 因此它只是一组"要显示给用户看的事实"。
  final List<CourseIntegrityIssue> integrityIssues;

  /// 有没有需要用户核对的确定性问题。
  bool get hasIntegrityIssues => integrityIssues.isNotEmpty;

  /// 是否命中"疑似旧版占位标题"。
  bool get hasLegacyPlaceholderTitle => integrityIssues.any(
    (issue) => issue.kind == CourseIntegrityIssueKind.legacyPlaceholderTitle,
  );

  /// 每个锚点保存时读到的 `updated_at_utc`（计划 Task 3 Interfaces）。
  ///
  /// **它是"页面数据过期"检测的唯一依据**：用户打开编辑页之后，别处（另一个窗口、
  /// 课表重新导入）可能已经改过这门课。保存前拿它和数据库里的现值比一次，
  /// 不一致就返回 `stale` 让用户重新打开——而不是覆盖掉别人的改动。
  Map<EntityId, DateTime> get sourceRevisions => {
    for (final segment in segments) segment.eventId: segment.updatedAtUtc,
  };

  /// 这门课当前形态的**指纹**（计划 Task 4 Interfaces／Task 8 Step 6）。
  ///
  /// **为什么不能只比 `updated_at_utc`**：改一门课会**新增与删除锚点**，
  /// 而"新增的那个锚点"在用户打开编辑页时还不存在，因此逐 id 比对会漏掉
  /// "别处删了一段、又加了一段"这种改动。指纹把"有几个锚点、每个锚点是哪一天哪一刻、
  /// 修订号是多少、**它名下有哪些例外**"一次算进来。
  ///
  /// **排序后拼接**：仓储的返回顺序虽然有定义，但把"顺序"也算进指纹会让一次纯排序变化
  /// （例如改了排序键）把用户的编辑判成过期。
  String get revisionFingerprint => courseSeriesRevisionFingerprint(segments);
}

/// 一组片段的**规范化指纹**（计划 Task 8 Step 6）。
///
/// **它是唯一实现**：读模型（`CourseSeriesDetail.revisionFingerprint`）与写事务
/// （`DriftCalendarRepository.replaceCourseSeries` 在事务开始后重算并比对）
/// 必须给出逐字节相同的结果——两份公式一旦漂开，"过期"就会变成随机判定。
///
/// 每一段的输入：
///
/// ```text
/// eventId | 排序后的星期集合 | 开始分钟 | 时长分钟 | validFrom | validUntil |
/// updatedAtUtc | 例外指纹
/// ```
///
/// 最后拼接后**整体排序**：顺序不参与指纹，因此一次纯排序变化不会把用户的编辑判成过期。
String courseSeriesRevisionFingerprint(
  Iterable<CourseSeriesSegment> segments,
) {
  final rows = [
    for (final segment in segments)
      '${segment.eventId}|'
          '${(segment.weekdays.toList()..sort()).join(',')}|'
          '${segment.startMinute}|'
          '${segment.endMinute - segment.startMinute}|'
          '${segment.validFromLocalDate.year}-'
          '${segment.validFromLocalDate.month}-'
          '${segment.validFromLocalDate.day}|'
          '${segment.validUntilLocalDate?.toIso8601String() ?? ''}|'
          '${segment.updatedAtUtc.microsecondsSinceEpoch}|'
          '${segment.exceptionRevisionFingerprint}',
  ]..sort();
  return rows.join(';');
}

/// 一个锚点名下全部例外的**修订指纹**（计划 Task 8 Step 6）。
///
/// 每条例外按 id 排序后拼接 `id | startAtUtc | endAtUtc | timeZoneId | updatedAtUtc`。
///
/// **为什么不能只比"例外条数"或"最大更新时间"**：
/// - 删一条再加一条会让**条数相同**，而用户逐次调整的内容已经换了一批；
/// - 同一微秒写入多条会让**最大更新时间相同**，而集合整体变了。
/// 逐行拼接把这两种情况都变成可见的差异，代价只是一次内存拼接。
String exceptionRevisionFingerprint(
  Iterable<
    ({String id, int startAtUtc, int endAtUtc, String timeZoneId, int updatedAtUtc})
  >
  exceptions,
) {
  final rows =
      [
        for (final row in exceptions)
          '${row.id}|${row.startAtUtc}|${row.endAtUtc}|${row.timeZoneId}|'
              '${row.updatedAtUtc}',
      ]..sort();
  return rows.join(';');
}

/// 一个系列片段：一条锚点事件 ＋ 它的重复规则。
final class CourseSeriesSegment {
  CourseSeriesSegment({
    required this.eventId,
    required this.title,
    required this.timeZoneId,
    Set<int>? weekdays,
    int? weekday,
    required this.startMinute,
    required this.endMinute,
    required this.intervalWeeks,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    this.location = '',

    /// **教师存在 `notes` 列里**（计划 Global Constraints）：本批次不引入"课程备注"
    /// 这个新概念，因此读模型也按教师来命名它。课表导入正是用这一列存教师名的。
    this.teacher = '',
    this.areaId,
    this.projectId,
    this.weekSpan = const WeekSpan(startWeek: 1, endWeek: 1),
    this.outsideTerm = false,
    required this.updatedAtUtc,
    this.importBatchId,
    this.exceptionRevisionFingerprint = '',
  }) : weekdays = UnmodifiableSetView(
         Set.of(weekdays ?? {weekday ?? DateTime.monday}),
       ) {
    if (this.weekdays.isEmpty) {
      throw ArgumentError('一个系列片段至少要有一个星期');
    }
  }

  final EntityId eventId;
  final String title;

  /// **解释这个片段的权威时区**（计划 Task 3 Step 2）。
  ///
  /// 来源是**规则行的 `time_zone_id`**（正常重复课程里它与锚点一致）。日期、星期与
  /// 分钟都以它解释：`validFromLocalDate` 是"这个时区里的本地日"，`startMinute` 是
  /// "这个时区里的本地分钟"。
  ///
  /// **不一致时不在这里静默选一个**：锚点与规则的时区不同本身就是
  /// [CourseIntegrityIssueKind.eventRuleTimeZoneMismatch]，由读仓储报出来给用户核对。
  /// 这里的值只用于"按哪个时区解释这门课的时间"，而展开器的口径是规则时区。
  final String timeZoneId;

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

  /// 教师名（读自 `calendar_events.notes`）。
  final String teacher;

  final EntityId? areaId;
  final EntityId? projectId;

  /// 锚点行的 `updated_at_utc`，供保存时发现**过期页面**（乐观并发）。
  final DateTime updatedAtUtc;

  /// 这一段的导入批次（读自锚点行）。`null` 表示"没有批次归属"。
  ///
  /// **它必须逐片段带出来**：来源解析（§2.1）要看到"这一门课的全部片段各自属于哪个
  /// 批次"，而只把摘要上那一个批次带出来会让"混合来源"永远不可见——
  /// 而那正是 C18 与 `recoverableMixed` 要处理的数据。
  final EntityId? importBatchId;

  /// 这个锚点名下**全部例外**的修订指纹（计划 Task 8 Step 6）。
  ///
  /// 它进入 [courseSeriesRevisionFingerprint]，于是"用户在预览之后到确认之前
  /// 删掉/新增了一条逐次调整"会让保存判为过期（E5）——而不是把那份调整悄悄丢掉。
  final String exceptionRevisionFingerprint;
}

/// **一次课程删除的真实结果**（计划 §2.3／Task 7 Step 1）。
///
/// 四个计数缺一不可：只报"删掉了"无法回答"到底删了什么"，
/// 而删除是用户在课程管理里最不可逆的动作。
///
/// **id 集合只供内部与测试核对，界面不得显示**（规范全局不变量第 7 条）。
/// 界面要展示的是计数与课程名，而不是 uuid。
final class CourseDeletionResult {
  const CourseDeletionResult({
    required this.deletedAnchorIds,
    required this.deletedExceptionIds,
    required this.deletedRuleIds,
    required this.affectedImportBatchIds,
  });

  /// 什么都没删（空集合、或 id 全部不存在）。
  static const CourseDeletionResult empty = CourseDeletionResult(
    deletedAnchorIds: {},
    deletedExceptionIds: {},
    deletedRuleIds: {},
    affectedImportBatchIds: {},
  );

  final Set<String> deletedAnchorIds;
  final Set<String> deletedExceptionIds;
  final Set<String> deletedRuleIds;

  /// **状态真的发生转移**的批次（`committed → partiallyDeleted`）。
  ///
  /// 不是"涉及到的批次"：一个已经是 `partiallyDeleted` 的批次被再删一门课时
  /// 不在这里——它的状态没有变，而"变更了几行"才是调用方要如实汇报的事实。
  final Set<String> affectedImportBatchIds;

  int get deletedAnchorCount => deletedAnchorIds.length;
  int get deletedExceptionCount => deletedExceptionIds.length;
  int get deletedRuleCount => deletedRuleIds.length;
  int get affectedImportBatchCount => affectedImportBatchIds.length;

  bool get isEmpty =>
      deletedAnchorIds.isEmpty &&
      deletedExceptionIds.isEmpty &&
      deletedRuleIds.isEmpty &&
      affectedImportBatchIds.isEmpty;

  int get totalDeletedRows =>
      deletedAnchorCount + deletedExceptionCount + deletedRuleCount;
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
