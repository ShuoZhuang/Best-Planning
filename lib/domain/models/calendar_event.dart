import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/time_range.dart';

enum CalendarEventSourceKind {
  manual('manual'),
  timetableImport('timetableImport');

  const CalendarEventSourceKind(this.storageValue);

  final String storageValue;

  static CalendarEventSourceKind fromStorage(String value) =>
      CalendarEventSourceKind.values.firstWhere(
        (kind) => kind.storageValue == value,
        orElse: () => CalendarEventSourceKind.manual,
      );
}

/// 日历事项的种类（1.8.0，设计规范 §9.1）。
///
/// **为什么不另建一套保护时间模型**：保护时间与固定日程在数据形状上完全一致——一个标题、
/// 一段本地时间、可选按周重复。规范的裁定是"复用固定日程及重复规则，不另建平行时间模型"，
/// 因为平行的第二套时间模型意味着第二套展开、第二套例外、第二套冲突检测。
///
/// 差别只落在**语义**上，因此只需一个判别字段：
/// - 不参与任务完成统计；
/// - 不作为"固定日程投入"统计；
/// - 在排程输入里映射为 `protectedIntervals`（硬禁区），**不是** `fixedIntervals`；
/// - 日历上用统一配色，且不能标记完成。
enum CalendarEventKind {
  /// 固定日程：时间钉死的安排（会议、课程）。排程不会占用它，但它算"固定日程投入"。
  fixed('fixed'),

  /// 保护时间：**不安排任何事**的时段。排程绝不占用它，且它不计入任何投入。
  protected('protected');

  const CalendarEventKind(this.storageValue);

  /// 存进数据库的字符串。**与枚举名分开**：名字将来可能改，而库里已有的值不能跟着变。
  final String storageValue;

  /// 从存储值还原。
  ///
  /// **未知值回落到 `fixed`，绝不回落到 `protected`**：这是保守方向。把一个认不出的值当成
  /// 保护时间，会让一段本该可以排任务的时段突然变成硬禁区——用户看到的是"计划排不进去了"
  /// 而没有任何线索。当成固定日程则最多是"这段时间被占着"，仍然可见、可编辑、可删除。
  static CalendarEventKind fromStorage(String? value) =>
      CalendarEventKind.values.firstWhere(
        (kind) => kind.storageValue == value,
        orElse: () => CalendarEventKind.fixed,
      );
}

final class CalendarEvent {
  CalendarEvent({
    required this.id,
    required String title,
    required this.startAtUtc,
    required this.endAtUtc,
    required this.timeZoneId,
    this.recurrenceRuleId,
    this.exceptionOfId,
    this.locked = true,
    this.areaId,
    this.projectId,
    String location = '',
    String notes = '',
    this.sourceKind = CalendarEventSourceKind.manual,
    this.kind = CalendarEventKind.fixed,
    this.importBatchId,
    this.logicalCourseId,
    required this.updatedAtUtc,
  }) : title = title.trim(),
       location = location.trim(),
       notes = notes.trim() {
    if (this.title.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Cannot be empty.');
    }
    TimeRange(startUtc: startAtUtc, endUtc: endAtUtc);
    if (!updatedAtUtc.isUtc) {
      throw ArgumentError.value(updatedAtUtc, 'updatedAtUtc', 'Must be UTC.');
    }
    if (timeZoneId.trim().isEmpty) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId', 'Cannot be empty.');
    }
  }

  static const Object _unset = Object();

  final EntityId id;
  final String title;
  final DateTime startAtUtc;
  final DateTime endAtUtc;
  final String timeZoneId;
  final EntityId? recurrenceRuleId;
  final EntityId? exceptionOfId;
  final bool locked;
  final EntityId? areaId;
  final EntityId? projectId;
  final String location;
  final String notes;
  final CalendarEventSourceKind sourceKind;

  /// 这条事项是固定日程还是保护时间（1.8.0，规范 §9.1）。
  ///
  /// 带默认值 `fixed`：旧数据迁移后全部是固定日程，而源码层面既有的每一个构造点
  /// 也都不需要改——它们的语义本来就都是"固定日程"。
  final CalendarEventKind kind;

  final EntityId? importBatchId;
  final EntityId? logicalCourseId;
  final DateTime updatedAtUtc;

  TimeRange get range => TimeRange(startUtc: startAtUtc, endUtc: endAtUtc);

  CalendarEvent copyWith({
    EntityId? id,
    String? title,
    DateTime? startAtUtc,
    DateTime? endAtUtc,
    String? timeZoneId,
    Object? recurrenceRuleId = _unset,
    Object? exceptionOfId = _unset,
    bool? locked,
    Object? areaId = _unset,
    Object? projectId = _unset,
    String? location,
    String? notes,
    CalendarEventSourceKind? sourceKind,
    CalendarEventKind? kind,
    Object? importBatchId = _unset,
    Object? logicalCourseId = _unset,
    DateTime? updatedAtUtc,
  }) => CalendarEvent(
    id: id ?? this.id,
    title: title ?? this.title,
    startAtUtc: startAtUtc ?? this.startAtUtc,
    endAtUtc: endAtUtc ?? this.endAtUtc,
    timeZoneId: timeZoneId ?? this.timeZoneId,
    recurrenceRuleId: identical(recurrenceRuleId, _unset)
        ? this.recurrenceRuleId
        : recurrenceRuleId as EntityId?,
    exceptionOfId: identical(exceptionOfId, _unset)
        ? this.exceptionOfId
        : exceptionOfId as EntityId?,
    locked: locked ?? this.locked,
    areaId: identical(areaId, _unset) ? this.areaId : areaId as EntityId?,
    projectId: identical(projectId, _unset)
        ? this.projectId
        : projectId as EntityId?,
    location: location ?? this.location,
    notes: notes ?? this.notes,
    sourceKind: sourceKind ?? this.sourceKind,
    kind: kind ?? this.kind,
    importBatchId: identical(importBatchId, _unset)
        ? this.importBatchId
        : importBatchId as EntityId?,
    logicalCourseId: identical(logicalCourseId, _unset)
        ? this.logicalCourseId
        : logicalCourseId as EntityId?,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

final class RecurrenceRule {
  RecurrenceRule({
    required this.id,
    required Set<int> weekdays,
    required this.localStartMinute,
    required this.durationMinutes,
    this.intervalWeeks = 1,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    required this.timeZoneId,
  }) : weekdays = Set.unmodifiable(weekdays) {
    if (weekdays.isEmpty || weekdays.any((day) => day < 1 || day > 7)) {
      throw ArgumentError.value(weekdays, 'weekdays');
    }
    if (localStartMinute < 0 || localStartMinute >= 24 * 60) {
      throw ArgumentError.value(localStartMinute, 'localStartMinute');
    }
    if (durationMinutes <= 0) {
      throw ArgumentError.value(durationMinutes, 'durationMinutes');
    }
    if (intervalWeeks < 1 || intervalWeeks > 52) {
      throw ArgumentError.value(
        intervalWeeks,
        'intervalWeeks',
        'Must be between 1 and 52.',
      );
    }
    if (validUntilLocalDate != null &&
        validUntilLocalDate!.isBefore(validFromLocalDate)) {
      throw ArgumentError(
        'validUntilLocalDate cannot precede validFromLocalDate.',
      );
    }
  }

  final EntityId id;
  final Set<int> weekdays;
  final int localStartMinute;
  final int durationMinutes;
  final int intervalWeeks;
  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;
  final String timeZoneId;
}

final class CalendarOccurrence {
  CalendarOccurrence({
    required this.eventId,
    required this.title,
    required this.range,
    required this.locked,
    this.areaId,
    this.projectId,
    this.location = '',
    this.notes = '',
    this.sourceKind = CalendarEventSourceKind.manual,
    this.kind = CalendarEventKind.fixed,
    this.importBatchId,
    this.logicalCourseId,
    this.updatedAtUtc,
  });

  final EntityId eventId;
  final String title;
  final TimeRange range;
  final bool locked;
  final EntityId? areaId;
  final EntityId? projectId;
  final String location;
  final String notes;
  final CalendarEventSourceKind sourceKind;

  /// 固定日程还是保护时间。
  ///
  /// **展开（`RecurrenceExpander`）必须把这一项带下来**：判断"这条占用是硬禁区还是
  /// 固定投入"要读的是**每一次展开出来的占用**，而不是锚点行。丢了它，重复保护时间
  /// 会被当成固定日程进入统计，而规范 §9.1 明确它不计入任何投入。
  final CalendarEventKind kind;

  /// 锚点行的 `updated_at_utc`（课程与保护时间管理修复计划 Task 7 Step 4）。
  ///
  /// **为什么必须带到每一次展开上**：编辑页的"数据是否过期"判定要拿它和用户打开页面时
  /// 读到的值比。只在锚点行上有这个字段不够——编辑页拿到的是一批 `CalendarOccurrence`，
  /// 如果每一份都不带，页面就只能再查一次库，于是"页面看到的"与"判定的依据"
  /// 变成两份不同的数据。
  ///
  /// 可空：手工构造的占用（测试、`course_transition` 之类）没有这个概念，
  /// 而"不知道修订号"与"修订号是某个值"必须能区分。
  final DateTime? updatedAtUtc;

  final EntityId? importBatchId;
  final EntityId? logicalCourseId;
}
