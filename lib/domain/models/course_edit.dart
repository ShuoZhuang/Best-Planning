import 'dart:collection';

import 'package:personal_planner/domain/models/timetable_import.dart';

/// 整门课程资料的编辑草稿（课程与保护时间管理修复计划 Task 4）。
///
/// **它只装"整门课的属性"**：名称、教师、地点、领域、项目、上课安排列表。
/// "仅本次／此次及以后"不在这里——那两种范围的入口在日历上的具体课次
/// （那里才有真实发生时间，见计划 §2.2），而把它们混进这一页就会出现
/// "选了『仅本次』却改了整门课"这种说了但没做的状态（计划 §1.1 的实际偏差）。
///
/// **教师存在 `notes` 列里**（计划 Global Constraints）：本批次不引入"课程备注"
/// 这个新概念，避免把教师和备注混成两个含义。因此这里叫 [teacher]，
/// 落库时写进 `notes`。
final class CourseProfileDraft {
  CourseProfileDraft({
    required this.logicalCourseId,
    required String title,
    this.teacher = '',
    this.location = '',
    this.areaId,
    this.projectId,
    required List<CourseScheduleDraft> schedule,
  }) : title = title.trim(),
       schedule = UnmodifiableListView(List.of(schedule));

  /// 这门课的逻辑 id（同一门课的多个片段共享它）。
  ///
  /// **仓储按它找出既有的全部片段**，因此它是整体替换的必要输入，不是可选元数据。
  final String logicalCourseId;

  final String title;
  final String teacher;
  final String location;
  final String? areaId;
  final String? projectId;

  /// 上课安排列表。**允许为空**：用户在编辑页上删光全部片段是合法意图
  /// （"这门课这学期不上了"），而空列表的落库结果是删除全部锚点——
  /// 与"至少保留一行"的界面约束不同：界面拦的是手滑，不是用户的明确选择。
  final List<CourseScheduleDraft> schedule;
}

/// 一条上课安排的草稿。
final class CourseScheduleDraft {
  CourseScheduleDraft({
    required this.startMinute,
    required this.endMinute,
    required Set<int> weekdays,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    this.intervalWeeks = 1,
    this.parity = WeekParity.every,
    this.startWeek = 1,
  }) : weekdays = UnmodifiableSetView(Set.of(weekdays));

  /// 本地起止分钟（0..1440）。
  final int startMinute;
  final int endMinute;

  /// 这条安排覆盖的星期集合（计划 §2.1："星期集合"）。
  final Set<int> weekdays;
  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;

  /// 频率：1 每周、2 单／双周。值域 1–2（计划 §2.1："频率只允许每周、单周、双周"）。
  final int intervalWeeks;

  /// 单双周里的**哪一周**（`odd` = 单周）。
  ///
  /// **只有 `intervalWeeks == 2` 时才有意义**。计划 §2.1 明确："起始周与单双周不相符时，
  /// 保存前明确报错，**不自动把第 2 周改成第 3 周**"——因此它必须由用户显式选，
  /// 而不是从 `validFromLocalDate` 推。
  final WeekParity parity;

  /// **用户填的起始周**（学期坐标，从 1 开始）。
  ///
  /// 它与 [parity] 一起构成"单双周"的完整表达：`parity: odd` 且 `startWeek: 5`
  /// 表示"从第 5 周开始的单周"。`validateParityAgainstStartWeek` 负责判定两者是否相符。
  final int startWeek;
}

/// 整体替换时的一行：**最终形态**，外加"如果匹配上既有片段就沿用它的 id"。
///
/// [reuseAnchorId] 是保住用户逐次调整的唯一办法：换一个 id 等于删一条加一条，
/// 而被删掉的那条锚点名下的**例外行**会随之全部消失——用户之前一个个改过的内容就没了。
final class CourseWriteRow {
  const CourseWriteRow({
    required this.schedule,
    required this.index,
    this.reuseAnchorId,
  });

  final CourseScheduleDraft schedule;

  /// 这一行在草稿里的序号。用于生成稳定且可读的新 id（`<logicalCourseId>-<index>`），
  /// 而不是让仓储自己造——仓储造 id 会让"同一份草稿重试"产生两套锚点。
  final int index;

  final String? reuseAnchorId;
}

/// 一次保存请求（计划 Task 4 Step 1）。
final class CourseSaveRequest {
  CourseSaveRequest({
    required this.logicalCourseId,
    required this.profile,
    required this.expectedRevisions,
    required this.expectedFingerprint,
    this.termId,
  });

  final String logicalCourseId;
  final CourseProfileDraft profile;

  /// 打开编辑页时读到的每个锚点的 `updated_at_utc`。
  final Map<String, DateTime> expectedRevisions;

  /// 打开编辑页时读到的整门课指纹（见 `CourseSeriesDetail.revisionFingerprint`）。
  final String expectedFingerprint;

  final String? termId;
}

/// 保存前的**影响预览**（计划 §2.1："预览必须明确列出新增/删除片段数、受影响课次数
/// 和会删除的例外数，用户二次确认后才能应用"）。
///
/// **这四项缺一不可**：只报"会删除 1 段"没有意义——用户要知道的是"
/// **这学期会少上几次课**"。例外数单独列，是因为删除一段会把它名下的例外一起删掉，
/// 那些例外是用户之前逐次调整过的内容。
final class CourseEditPreview {
  const CourseEditPreview({
    required this.addedSegments,
    required this.removedSegments,
    required this.updatedSegments,
    required this.affectedOccurrenceDelta,
    required this.removedExceptionCount,
  });

  final int addedSegments;
  final int removedSegments;
  final int updatedSegments;

  /// 课次数的**变化量**（新增的减删除的）。可以为负。
  final int affectedOccurrenceDelta;

  /// 会被连带删除的例外数。
  final int removedExceptionCount;

  bool get hasChanges =>
      addedSegments > 0 || removedSegments > 0 || updatedSegments > 0;
}

/// 保存的结果（计划 §5 的失败表）。
enum CourseSaveStatus {
  saved,
  stale,
  invalid,
  unsupported,

  /// 写入失败（事务已回滚，原数据不变）。
  failed,
}

final class CourseSaveResult {
  const CourseSaveResult._(this.status, this.error, this.fieldErrors);

  factory CourseSaveResult.saved() =>
      const CourseSaveResult._(CourseSaveStatus.saved, null, null);

  factory CourseSaveResult.failed(CourseSaveStatus status, String error) =>
      CourseSaveResult._(status, error, null);

  factory CourseSaveResult.invalid(Map<String, String> fieldErrors) =>
      CourseSaveResult._(
        CourseSaveStatus.invalid,
        null,
        UnmodifiableMapView(Map.of(fieldErrors)),
      );

  final CourseSaveStatus status;
  final String? error;
  final Map<String, String>? fieldErrors;

  bool get isSuccess => status == CourseSaveStatus.saved;
}

/// 课程编辑草稿的字段级校验（课程与保护时间管理修复计划 Task 4 Step 3）。
///
/// **纯函数**：不读数据库、不看时钟，因此"哪些输入非法"可以逐条断言。
///
/// 计划 Task 4 Step 1 点名的非法情况：空名称、空星期、星期越界、起止非法、
/// 单双周与起始周不相符、项目不属于所选领域、频率不是 1–2、结束日期早于开始日期。
Map<String, String> validateCourseProfile(
  CourseProfileDraft profile, {
  Set<String> projectIdsInArea = const {},
  Set<String> knownProjectIds = const {},
  DateTime? termFirstWeekMonday,
}) {
  final errors = <String, String>{};
  if (profile.title.isEmpty) {
    errors['title'] = '课程名称不能为空';
  }
  // 项目必须属于所选领域（计划 §2.1）。
  final projectId = profile.projectId;
  if (projectId != null && projectId.isNotEmpty) {
    if (profile.areaId == null) {
      errors['projectId'] = '选择了项目就必须同时选择所属领域';
    } else if (knownProjectIds.isNotEmpty &&
        !projectIdsInArea.contains(projectId)) {
      errors['projectId'] = '所选项目不属于这个领域';
    }
  }

  for (var index = 0; index < profile.schedule.length; index++) {
    final row = profile.schedule[index];
    final prefix = 'schedule.$index';
    if (row.weekdays.isEmpty) {
      errors['$prefix.weekdays'] = '至少要选一个星期';
    } else if (row.weekdays.any(
      (day) => day < DateTime.monday || day > DateTime.sunday,
    )) {
      errors['$prefix.weekdays'] = '星期取值必须在周一到周日之间';
    }
    if (row.endMinute <= row.startMinute) {
      errors['$prefix.time'] = '结束时间必须晚于开始时间';
    }
    if (row.startMinute < 0 || row.endMinute > 1440) {
      errors['$prefix.time'] = '时间必须在 00:00 到 24:00 之间';
    }
    if (row.intervalWeeks < 1 || row.intervalWeeks > 2) {
      errors['$prefix.intervalWeeks'] = '频率只能是每周、单周或双周';
    }
    // **单双周必须与起始周相符**（计划 §2.1）。不相符时报错，**不自动改用户的输入**：
    // 自动把"第 2 周"改成"第 3 周"会静默把用户选的周次挪走一周，而那一周是有课的。
    if (row.intervalWeeks == 2 && termFirstWeekMonday != null) {
      final mismatch = validateParityAgainstStartWeek(
        intervalWeeks: row.intervalWeeks,
        startWeek: row.startWeek,
        termFirstWeekMonday: termFirstWeekMonday,
        validFromLocalDate: row.validFromLocalDate,
      );
      if (mismatch != null) errors['$prefix.parity'] = mismatch;
    }
    final until = row.validUntilLocalDate;
    if (until != null && until.isBefore(row.validFromLocalDate)) {
      errors['$prefix.validUntil'] = '结束日期不能早于开始日期';
    }
  }
  return errors;
}

/// 单双周与起始周是否相符（计划 §2.1）。
///
/// **不自动改用户的输入**：用户在"单周"下把起始周填成第 2 周（偶数周）时，
/// 计划明确要求"保存前明确报错，不自动把第 2 周改成第 3 周"。
/// 自动改会静默把用户选的周次挪走一周，而那一周是有课的。
///
/// [termFirstWeekMonday] 为空（不知道学期）时**不做判定**：
/// 没有基准就算不出奇偶，硬报错会让没有学期归属的手工课程无法保存。
String? validateParityAgainstStartWeek({
  required int intervalWeeks,
  required int startWeek,
  required DateTime termFirstWeekMonday,
  required DateTime validFromLocalDate,
}) {
  if (intervalWeeks != 2) return null;
  final offsetDays = _dateOnly(validFromLocalDate)
      .difference(_dateOnly(termFirstWeekMonday))
      .inDays;
  final offsetWeeks = offsetDays ~/ DateTime.daysPerWeek;
  // 单周是学期里的第 1、3、5…周 ⇒ 偏移为偶数。
  final isOddWeek = offsetWeeks.isEven;
  final wantsOdd = startWeek.isOdd;
  if (isOddWeek == wantsOdd) return null;
  return '第 $startWeek 周是${wantsOdd ? '单' : '双'}周，'
      '但所选日期落在${isOddWeek ? '单' : '双'}周，两者不相符';
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
